import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

for (
  const [key, value] of Object.entries({
    SUPABASE_URL: "https://enhance-disabled-fixture.invalid",
    SUPABASE_ANON_KEY: "synthetic-public",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
  })
) Deno.env.set(key, value);
type Handler = (req: Request) => Promise<Response>;
let captured!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", {
  configurable: true,
  writable: true,
  value: (fn: Handler) => {
    captured = fn;
    return {};
  },
});
try {
  await import("./index.ts");
} finally {
  Object.defineProperty(Deno, "serve", serve);
}

async function invoke(auth: "missing" | "invalid" | "valid", method = "POST") {
  const original = globalThis.fetch, paths: string[] = [];
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "enhance-disabled-fixture.invalid");
    paths.push(url.pathname);
    assertEquals(
      url.pathname,
      "/auth/v1/user",
      "Disabled queue touched job/ledger/provider data",
    );
    return Response.json(
      auth === "valid"
        ? { id: "10000000-0000-4000-8000-000000000001", is_anonymous: false }
        : { message: "Synthetic invalid token" },
      { status: auth === "valid" ? 200 : 401 },
    );
  };
  try {
    const response = await captured(
      new Request("https://fixture.invalid/ai-enhance", {
        method,
        headers: auth === "missing"
          ? {}
          : { authorization: "Bearer synthetic-user" },
        ...(method === "POST"
          ? { body: '{"job_id":"other-private-job","frames":["private-file"]}' }
          : {}),
      }),
    );
    return { response, body: await response.text(), paths };
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("disabled actual enhancement handler authenticates before 503 and never looks up a job or queues work", async () => {
  for (const auth of ["missing", "invalid", "valid"] as const) {
    const result = await invoke(auth);
    assertEquals(result.response.status, auth === "valid" ? 503 : 401);
    assertEquals(result.paths.length, auth === "missing" ? 0 : 1);
    assert(
      !result.body.includes("other-private-job") &&
        !result.body.includes("private-file"),
    );
  }
});

Deno.test("disabled enhancement keeps preflight and rejects unsupported methods without lookup", async () => {
  assertEquals((await invoke("missing", "OPTIONS")).response.status, 200);
  assertEquals((await invoke("missing", "GET")).response.status, 405);
});
