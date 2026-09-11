// Actual route, synthetic Auth/PostgREST only. Any unmodelled network is an error.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const SOURCE = "00000000-0000-4000-8000-000000000001";
const DEST = "00000000-0000-4000-8000-000000000002";
const ORG = "00000000-0000-4000-8000-000000000003";
const OP = "00000000-0000-4000-8000-000000000004";
const OTHER = "00000000-0000-4000-8000-000000000005";
const sourceToken = "synthetic-anonymous-session-not-a-jwt";
const destToken = "synthetic-identified-session-not-a-jwt";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
Deno.env.set("SUPABASE_URL", "https://adoption-fixture.invalid");
Deno.env.set("SUPABASE_ANON_KEY", "synthetic-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-service-key");
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
let handler!: (request: Request) => Promise<Response>;
Object.defineProperty(Deno, "serve", {
  configurable: serve.configurable,
  enumerable: serve.enumerable,
  writable: true,
  value: (fn: typeof handler) => {
    handler = fn;
    return {};
  },
});
try {
  await import("./index.ts");
} finally {
  Object.defineProperty(Deno, "serve", serve);
}
if (!handler) throw new Error("Actual adoption handler missing");

type Fixture = {
  source?: () => Response | Promise<Response>;
  destination?: () => Response | Promise<Response>;
  receipt?: unknown;
  receiptError?: boolean;
  memberships?: unknown[];
  rpcError?: boolean;
  resultPatch?: Record<string, unknown>;
};
async function invoke(
  fixture: Fixture = {},
  overrides: Record<string, unknown> = {},
) {
  const originalFetch = globalThis.fetch;
  const calls: { path: string; body?: Record<string, unknown> }[] = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.hostname !== "adoption-fixture.invalid") {
      throw new Error("Unexpected network host");
    }
    const body = request.method === "POST" ? await request.json() : undefined;
    calls.push({ path: url.pathname, body });
    if (url.pathname === "/auth/v1/user") {
      return request.headers.get("authorization") === `Bearer ${sourceToken}`
        ? fixture.source?.() ?? json({ id: SOURCE, is_anonymous: true })
        : fixture.destination?.() ?? json({ id: DEST, is_anonymous: false });
    }
    if (url.pathname === "/rest/v1/rpc/adoption_receipt") {
      return fixture.receiptError
        ? json({ message: "synthetic outage" }, 503)
        : json(fixture.receipt ?? null);
    }
    if (url.pathname === "/rest/v1/memberships") {
      return json(fixture.memberships ?? [{ org_id: ORG, role: "owner" }]);
    }
    if (url.pathname === "/rest/v1/rpc/adopt_anonymous_org") {
      return fixture.rpcError
        ? json({ message: "RP409: synthetic conflict" }, 400)
        : json({
          ok: true,
          adopted: true,
          operation_id: body.p_operation,
          source_user_id: SOURCE,
          destination_user_id: DEST,
          org_id: ORG,
          ...fixture.resultPatch,
        });
    }
    // The old route reads these before transfer; keep the baseline executable.
    if (["/rest/v1/listings", "/rest/v1/leads"].includes(url.pathname)) {
      return new Response(null, { headers: { "content-range": "0-0/1" } });
    }
    if (url.pathname.startsWith("/auth/v1/admin/users/")) return json({});
    throw new Error(`Unexpected synthetic path ${url.pathname}`);
  };
  try {
    const response = await handler(
      new Request("https://edge.invalid/adopt", {
        method: "POST",
        headers: {
          authorization: `Bearer ${destToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          anonymous_token: sourceToken,
          operation_id: OP,
          source_user_id: SOURCE,
          destination_user_id: DEST,
          ...overrides,
        }),
      }),
    );
    return { status: response.status, body: await response.json(), calls };
  } finally {
    globalThis.fetch = originalFetch;
  }
}

for (const status of [429, 500, 503]) {
  Deno.test(`source Auth ${status} is retryable, never adoption success`, async () => {
    const result = await invoke({ source: () => json({}, status) });
    assertEquals(result.status, 503);
    assertEquals(result.body.code, "upstream");
    assertEquals(
      result.calls.some((c) => c.path.endsWith("/adopt_anonymous_org")),
      false,
    );
  });
}
Deno.test("malformed source Auth 200 fails closed", async () => {
  const result = await invoke({ source: () => new Response("not-json") });
  assertEquals(result.status, 502);
});
for (const status of [401, 403]) {
  Deno.test(`expired source ${status} needs recovery, not no-op success`, async () => {
    const result = await invoke({ source: () => json({}, status) });
    assertEquals(result.status, 409);
    assertEquals(result.body.adoption_state, "source_session_expired");
  });
}
Deno.test("dropped commit reply replays bound receipt without valid source token", async () => {
  const receipt = {
    ok: true,
    adopted: true,
    operation_id: OP,
    source_user_id: SOURCE,
    destination_user_id: DEST,
    org_id: ORG,
  };
  const result = await invoke({ receipt, source: () => json({}, 401) });
  assertEquals(result.status, 200);
  assertEquals(result.body.operation_id, OP);
  assertEquals(
    result.calls.filter((c) => c.path === "/auth/v1/user").length,
    1,
  );
  assertEquals(
    result.calls.some((c) => c.path.endsWith("/adopt_anonymous_org")),
    false,
  );
});
Deno.test("destination must match envelope before receipt read", async () => {
  const result = await invoke({}, { destination_user_id: OTHER });
  assertEquals(result.status, 403);
  assertEquals(result.calls.some((c) => c.path.includes("/rpc/")), false);
});
Deno.test("source must match envelope before membership read", async () => {
  const result = await invoke({}, { source_user_id: OTHER });
  assertEquals(result.status, 403);
  assertEquals(
    result.calls.some((c) => c.path.endsWith("/memberships")),
    false,
  );
});
Deno.test("successful transfer sends all immutable bindings", async () => {
  const result = await invoke();
  assertEquals(result.status, 200);
  assertEquals(result.body.adopted, true);
  assertEquals(
    result.calls.find((c) => c.path.endsWith("/adopt_anonymous_org"))?.body,
    { p_user: DEST, p_anon_user: SOURCE, p_anon_org: ORG, p_operation: OP },
  );
  assertEquals(
    result.calls.some((c) => c.path.includes("/admin/users/")),
    false,
  );
});
Deno.test("receipt outage cannot silently fall through to new mutation", async () => {
  const result = await invoke({ receiptError: true });
  assertEquals(result.status, 503);
  assertEquals(
    result.calls.some((c) => c.path.endsWith("/memberships")),
    false,
  );
});
Deno.test("missing source membership is a conflict, not confirmation", async () => {
  const result = await invoke({ memberships: [] });
  assertEquals(result.status, 409);
  assertEquals(result.body.ok, undefined);
});
Deno.test("anonymous destination rejected before source access", async () => {
  const result = await invoke({
    destination: () => json({ id: DEST, is_anonymous: true }),
  });
  assertEquals(result.status, 403);
  assertEquals(result.calls.length, 1);
});
Deno.test("identified source cannot transfer", async () => {
  const result = await invoke({
    source: () => json({ id: SOURCE, is_anonymous: false }),
  });
  assertEquals(result.status, 403);
  assertEquals(
    result.calls.some((c) => c.path.endsWith("/memberships")),
    false,
  );
});
Deno.test("destination Auth outage is retryable, not credential expiry", async () => {
  const result = await invoke({ destination: () => json({}, 503) });
  assertEquals(result.status, 503);
});
Deno.test("source transport failure is retryable and value-free", async () => {
  const result = await invoke({
    source: () => {
      throw new TypeError("synthetic network");
    },
  });
  assertEquals(result.status, 503);
  assertEquals(JSON.stringify(result.body).includes(sourceToken), false);
});
Deno.test("database refusal is not a completed handoff", async () => {
  const result = await invoke({ rpcError: true });
  assertEquals(result.status, 409);
  assertEquals(result.body.ok, undefined);
});
for (
  const body of [null, [], {}, { id: SOURCE }, {
    id: SOURCE,
    is_anonymous: "true",
  }]
) {
  Deno.test(`invalid source user shape ${JSON.stringify(body)}`, async () => {
    assertEquals((await invoke({ source: () => json(body) })).status, 502);
  });
}
for (
  const patch of [
    { ok: false },
    { operation_id: OTHER },
    { source_user_id: OTHER },
    { destination_user_id: OTHER },
    { org_id: "not-an-id" },
  ]
) {
  Deno.test(`malformed database receipt ${Object.keys(patch)[0]} retained as failure`, async () => {
    assertEquals((await invoke({ resultPatch: patch })).status, 502);
  });
}
Deno.test("legacy payload remains valid without deleting source", async () => {
  const overrides = {
    operation_id: undefined,
    source_user_id: undefined,
    destination_user_id: undefined,
  };
  const first = await invoke({}, overrides),
    second = await invoke({}, overrides);
  assertEquals(first.status, 200);
  assertEquals(first.body.operation_id, second.body.operation_id);
  assertEquals(
    first.calls.some((c) => c.path.includes("/admin/users/")),
    false,
  );
});
Deno.test("expired legacy token is not magically recovered", async () => {
  const result = await invoke({ source: () => json({}, 401) }, {
    operation_id: undefined,
    source_user_id: undefined,
    destination_user_id: undefined,
  });
  assertEquals(result.status, 409);
  assertEquals(result.body.adoption_state, "source_session_expired");
});
Deno.test("partial binding never falls back to legacy", async () => {
  assertEquals((await invoke({}, { operation_id: undefined })).status, 400);
});
