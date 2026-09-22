// Offline regression of the REAL Responses adapter, not a copy of its parser.
// deno test --cached-only --no-check --allow-env --deny-net _shared/providers/openai_responses_test.ts
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { ProviderError } from "./common.ts";
import { openaiChat, openaiJudge } from "./openai.ts";

const INPUT = [{ role: "user", content: "fixture input" }];
const PARTIAL = "fixture-private-partial-text";

/** No real fetch is reachable; every test must also prove one request happened. */
async function withResponse(
  body: unknown,
  run: () => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  const originalKey = Deno.env.get("OPENAI_API_KEY");
  let requests = 0;
  Deno.env.set("OPENAI_API_KEY", "fixture-not-a-real-key");
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    requests++;
    assertEquals(String(url), "https://api.openai.com/v1/responses");
    assertEquals(init?.method, "POST");
    assert(
      init?.signal instanceof AbortSignal,
      "the existing request timeout must remain attached",
    );
    return Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
  }) as typeof fetch;
  try {
    await run();
  } finally {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) Deno.env.delete("OPENAI_API_KEY");
    else Deno.env.set("OPENAI_API_KEY", originalKey);
    assertEquals(
      requests,
      1,
      "the adapter must run once, with no hidden retry or provider calls",
    );
  }
}

function nested(text: string) {
  return [{
    type: "message",
    role: "assistant",
    content: [{ type: "output_text", text }],
  }];
}

const rejected: {
  name: string;
  envelope: Record<string, unknown>;
  errorClass?: string;
}[] = [
  {
    name: "incomplete/max_output_tokens",
    envelope: {
      status: "incomplete",
      incomplete_details: { reason: "max_output_tokens" },
    },
  },
  {
    name: "incomplete/content_filter",
    envelope: {
      status: "incomplete",
      incomplete_details: { reason: "content_filter" },
    },
    errorClass: "nsfw", // Preserve the chain's rule against retrying a refusal with another vendor.
  },
  { name: "incomplete without details", envelope: { status: "incomplete" } },
  {
    name: "failed",
    envelope: {
      status: "failed",
      error: { code: "server_error", message: PARTIAL },
    },
  },
  { name: "cancelled", envelope: { status: "cancelled" } },
  {
    name: "error event",
    envelope: { type: "error", error: { message: PARTIAL } },
  },
  { name: "queued", envelope: { status: "queued" } },
  { name: "in_progress", envelope: { status: "in_progress" } },
  { name: "unknown status", envelope: { status: "unexpected-fixture-status" } },
  { name: "missing status", envelope: {} },
  {
    name: "completed with error",
    envelope: { status: "completed", error: { message: PARTIAL } },
  },
  {
    name: "completed with incomplete details",
    envelope: {
      status: "completed",
      incomplete_details: { reason: "max_output_tokens" },
    },
  },
];

// Both supported extraction paths must pass through the completion gate. A
// one-path fix would still accept the same partial response via the other path.
for (const fixture of rejected) {
  for (const shape of ["output_text", "output content"] as const) {
    Deno.test(`Responses rejects ${fixture.name} with ${shape}`, async () => {
      const text = shape === "output_text"
        ? { output_text: PARTIAL }
        : { output: nested(PARTIAL) };
      await withResponse({ ...fixture.envelope, ...text }, async () => {
        const err = await assertRejects(
          () => openaiChat("fixture-model", INPUT),
          ProviderError,
        );
        assertEquals(err.provider, "openai");
        assertEquals(err.error_class, fixture.errorClass ?? "upstream");
        assert(
          !err.message.includes(PARTIAL),
          "never echo partial user output or a vendor error body",
        );
      });
    });
  }
}

Deno.test("Responses accepts completed output_text unchanged", async () => {
  await withResponse({
    status: "completed",
    error: null,
    incomplete_details: null,
    output_text: "  complete answer  ",
  }, async () => {
    assertEquals(
      await openaiChat("fixture-model", INPUT),
      "  complete answer  ",
    );
  });
});

Deno.test("Responses accepts completed nested output after a reasoning item", async () => {
  await withResponse({
    status: "completed",
    output: [{ type: "reasoning", summary: [] }, ...nested("complete JSON")],
  }, async () => {
    assertEquals(await openaiChat("fixture-model", INPUT), "complete JSON");
  });
});

Deno.test("Responses still rejects completed responses with no text", async () => {
  await withResponse(
    { status: "completed", output: [], output_text: " " },
    async () => {
      const err = await assertRejects(
        () => openaiChat("fixture-model", INPUT),
        ProviderError,
      );
      assertEquals(err.error_class, "upstream");
    },
  );
});

Deno.test("Responses judge rejects incomplete output even when its JSON parses", async () => {
  await withResponse({
    status: "incomplete",
    incomplete_details: { reason: "max_output_tokens" },
    output: nested('{"flag":false,"reason":"partial verdict"}'),
  }, async () => {
    await assertRejects(
      () => openaiJudge("fixture-model", "fixture subject", "fixture rubric"),
      ProviderError,
    );
  });
});

Deno.test("Responses judge still accepts a completed JSON verdict", async () => {
  await withResponse({
    status: "completed",
    output: nested('{"flag":false,"reason":"complete verdict"}'),
  }, async () => {
    assertEquals(
      await openaiJudge("fixture-model", "fixture subject", "fixture rubric"),
      {
        flag: false,
        reason: "complete verdict",
      },
    );
  });
});

for (const body of [null, false, 7, "not an envelope"]) {
  Deno.test(`Responses rejects non-object envelope ${JSON.stringify(body)}`, async () => {
    await withResponse(body, async () => {
      const error = await assertRejects(() => openaiChat("fixture-model", INPUT), ProviderError);
      assertEquals(error.error_class, "upstream");
    });
  });
}
