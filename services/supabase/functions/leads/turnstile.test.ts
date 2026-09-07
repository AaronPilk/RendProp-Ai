// turnstile.test.ts — Turnstile must fail CLOSED when unconfigured.
//
//   deno test --allow-env --allow-net services/supabase/functions/leads/turnstile.test.ts
//
// `--allow-net` is only needed because a stubbed `globalThis.fetch` still
// requires net permission to be granted at the process level in Deno; the
// stub itself means no request ever leaves the process (same pattern as
// admin/funnel.test.ts).
//
// What this defends, in order of how bad it would be to get wrong:
//   1. A missing TURNSTILE_SECRET_KEY REJECTS the submission (fails closed) —
//      not the old "no secret -> return true" no-op.
//   2. TURNSTILE_OPTIONAL=1 is the ONLY way to get the old lenient behavior
//      back, and it must be read fresh per call (an operator flipping it in
//      one env should not need a redeploy of this module).
//   3. Whichever of the two above happens, a warning naming
//      TURNSTILE_SECRET_KEY is logged EVERY time — silence is exactly the
//      failure mode the audit found.
//   4. A configured secret still behaves as before: valid token -> true, bad
//      token / verify-call error -> false.

import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { verifyTurnstile } from "./turnstile.ts";

const realFetch = globalThis.fetch;
const realError = console.error;

function stubFetch(success: boolean) {
  globalThis.fetch = (() =>
    Promise.resolve(
      new Response(JSON.stringify({ success }), { status: 200, headers: { "Content-Type": "application/json" } }),
    )) as typeof fetch;
}

/** Capture every console.error call made during `fn()`, restoring it after. */
async function captureErrors(fn: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  console.error = (...args: unknown[]) => {
    lines.push(args.map((a) => String(a)).join(" "));
  };
  try {
    await fn();
  } finally {
    console.error = realError;
  }
  return lines;
}

function withEnv(vars: Record<string, string | undefined>, fn: () => Promise<void>): Promise<void> {
  const prior = new Map<string, string | undefined>();
  for (const k of Object.keys(vars)) prior.set(k, Deno.env.get(k));
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) Deno.env.delete(k);
    else Deno.env.set(k, v);
  }
  return fn().finally(() => {
    for (const [k, v] of prior) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  });
}

Deno.test("verifyTurnstile: secret set + valid token -> true", async () => {
  stubFetch(true);
  try {
    await withEnv({ TURNSTILE_SECRET_KEY: "test-secret", TURNSTILE_OPTIONAL: undefined }, async () => {
      assertEquals(await verifyTurnstile("good-token", "1.2.3.4"), true);
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("verifyTurnstile: secret set + bad token -> false", async () => {
  stubFetch(false);
  try {
    await withEnv({ TURNSTILE_SECRET_KEY: "test-secret", TURNSTILE_OPTIONAL: undefined }, async () => {
      assertEquals(await verifyTurnstile("bad-token", "1.2.3.4"), false);
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("verifyTurnstile: secret set + NO token -> false, without even calling Turnstile", async () => {
  let called = false;
  globalThis.fetch = (() => {
    called = true;
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
  try {
    await withEnv({ TURNSTILE_SECRET_KEY: "test-secret", TURNSTILE_OPTIONAL: undefined }, async () => {
      assertEquals(await verifyTurnstile(undefined, "1.2.3.4"), false);
    });
    assertEquals(called, false);
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test("verifyTurnstile: secret MISSING -> REJECTED (fails closed), and warns naming the var", async () => {
  await withEnv({ TURNSTILE_SECRET_KEY: undefined, TURNSTILE_OPTIONAL: undefined }, async () => {
    const lines = await captureErrors(async () => {
      assertEquals(await verifyTurnstile("anything", "1.2.3.4"), false);
    });
    assertEquals(lines.length, 1, "exactly one unmistakable warning, not silence");
    assertStringIncludes(lines[0], "TURNSTILE_SECRET_KEY");
  });
});

Deno.test("verifyTurnstile: secret missing + TURNSTILE_OPTIONAL=1 -> ALLOWED, but still warns", async () => {
  await withEnv({ TURNSTILE_SECRET_KEY: undefined, TURNSTILE_OPTIONAL: "1" }, async () => {
    const lines = await captureErrors(async () => {
      assertEquals(await verifyTurnstile(undefined, "1.2.3.4"), true);
    });
    // The opt-out must not go silent: this is a deliberate low-security
    // choice, and it should be visible in the logs every time, not just once.
    assertEquals(lines.length, 1);
    assertStringIncludes(lines[0], "TURNSTILE_SECRET_KEY");
    assertStringIncludes(lines[0], "TURNSTILE_OPTIONAL");
  });
});

Deno.test("verifyTurnstile: TURNSTILE_OPTIONAL set to anything but the literal '1' does NOT opt out", async () => {
  // A stray "true"/"yes"/"TRUE" must not silently disable bot protection —
  // only the exact documented value does.
  for (const value of ["true", "yes", "TRUE", "0", ""]) {
    await withEnv({ TURNSTILE_SECRET_KEY: undefined, TURNSTILE_OPTIONAL: value }, async () => {
      const lines = await captureErrors(async () => {
        assertEquals(await verifyTurnstile(undefined, "1.2.3.4"), false, `TURNSTILE_OPTIONAL=${JSON.stringify(value)} must still fail closed`);
      });
      assertEquals(lines.length, 1);
    });
  }
});

Deno.test("verifyTurnstile: a network error talking to Cloudflare fails closed, not open", async () => {
  globalThis.fetch = (() => Promise.reject(new Error("network down"))) as typeof fetch;
  try {
    await withEnv({ TURNSTILE_SECRET_KEY: "test-secret", TURNSTILE_OPTIONAL: undefined }, async () => {
      const lines = await captureErrors(async () => {
        assertEquals(await verifyTurnstile("some-token", "1.2.3.4"), false);
      });
      assertEquals(lines.length, 1);
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});
