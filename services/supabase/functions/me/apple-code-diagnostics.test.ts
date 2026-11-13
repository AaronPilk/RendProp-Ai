// Actual /me route, Apple exchange and profile-storage boundary; every transport is synthetic.
function check(value: unknown, reason: string): asserts value { if (!value) throw new Error(reason); }
function equal(actual: unknown, expected: unknown, reason: string) { check(JSON.stringify(actual) === JSON.stringify(expected), reason); }
const USER = "d1a69010-0000-4000-8000-000000000001";
const HOSTILE = "diagnostic-fixture-public-marker customer@example.invalid https://private.fixture.invalid/audio?cap=never-real /private/customer.m4a";
const key = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const exported = new Uint8Array(await crypto.subtle.exportKey("pkcs8", key.privateKey));
const pem = "-----BEGIN PRIVATE KEY-----\n" + btoa(String.fromCharCode(...exported)) + "\n-----END PRIVATE KEY-----";
const environment = { APPLE_TEAM_ID: "FIXTURETEAM", APPLE_CLIENT_ID: "com.rendprop.fixture", APPLE_KEY_ID: "FIXTUREKEY", APPLE_PRIVATE_KEY_P8: pem, SUPABASE_URL: "https://apple-diagnostic-fixture.invalid", SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_synthetic_apple_diagnostics" }), SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_synthetic_apple_diagnostics" }), RENDPROP_SECRET_KEY_NAME: "default", RENDPROP_PUBLISHABLE_KEY_NAME: "default" };
const previous = new Map(Object.keys(environment).map(name => [name, Deno.env.get(name)]));
for (const [name, value] of Object.entries(environment)) Deno.env.set(name, value);
type Handler = (req: Request) => Promise<Response>;
let handler!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (callback: Handler) => { handler = callback; return {}; } });
try { await import("./index.ts?actual-apple-diagnostic-route"); check(handler, "Actual handler was registered"); }
finally { Object.defineProperty(Deno, "serve", serve); for (const [name, value] of previous) value === undefined ? Deno.env.delete(name) : Deno.env.set(name, value); }

type Mode = "http" | "transport" | "non-error" | "custom-name" | "success" | "no-token" | "store-error" | "store-throw" | "unauthorized" | "invalid-code";
async function invoke(mode: Mode) {
  const oldFetch = globalThis.fetch, methods = ["log", "info", "warn", "error", "debug", "trace", "dir", "table", "assert"] as const;
  const descriptors = methods.map(name => [name, Object.getOwnPropertyDescriptor(console, name)!] as const);
  const logs: { method: string; args: unknown[] }[] = [], requests: { host: string; path: string; method: string }[] = [], updates: unknown[] = [];
  for (const name of methods) Object.defineProperty(console, name, { configurable: true, writable: true, value: (...args: unknown[]) => { logs.push({ method: name, args }); } });
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    requests.push({ host: url.hostname, path: url.pathname, method: req.method });
    if (url.hostname === "apple-diagnostic-fixture.invalid" && url.pathname === "/auth/v1/user")
      return mode === "unauthorized" ? Response.json({ message: "invalid fixture bearer" }, { status: 401 }) : Response.json({ id: USER, aud: "authenticated", role: "authenticated" });
    if (url.hostname === "appleid.apple.com" && url.pathname === "/auth/token") {
      const form = new URLSearchParams(await req.text());
      equal([req.method, form.get("grant_type"), form.get("code"), form.get("client_id")], ["POST", "authorization_code", "fixture-code-once", "com.rendprop.fixture"], "Original actual token exchange contract retained");
      check(!!form.get("client_secret"), "Actual helper signs synthetic client secret");
      if (mode === "http") return Response.json({ error: HOSTILE }, { status: 400 });
      if (mode === "transport") throw new TypeError(HOSTILE);
      if (mode === "non-error") throw HOSTILE;
      if (mode === "custom-name") { const error = new Error(HOSTILE); error.name = HOSTILE; throw error; }
      return Response.json(mode === "no-token" ? {} : { refresh_token: "synthetic-returned-refresh" });
    }
    if (url.hostname === "apple-diagnostic-fixture.invalid" && url.pathname === "/rest/v1/profiles") {
      equal([req.method, url.searchParams.get("id")], ["PATCH", `eq.${USER}`], "Only exact authenticated actor profile is written");
      const body = await req.json(); updates.push(body);
      equal(body, { apple_refresh_token: "synthetic-returned-refresh" }, "Original token storage payload retained");
      if (mode === "store-throw") throw new TypeError(HOSTILE);
      if (mode === "store-error") return Response.json({ message: HOSTILE, code: "23514" }, { status: 400 });
      return new Response(null, { status: 204 });
    }
    throw new Error("Unmodeled transport refused");
  };
  try {
    const response = await handler(new Request("https://edge.fixture.invalid/me/apple-code", { method: "POST", headers: { authorization: "Bearer synthetic-caller", "content-type": "application/json" }, body: JSON.stringify({ authorization_code: mode === "invalid-code" ? " " : "fixture-code-once" }) }));
    return { response, body: await response.json(), requests, logs, updates };
  } finally { globalThis.fetch = oldFetch; for (const [name, descriptor] of descriptors) Object.defineProperty(console, name, descriptor); }
}
function safe(logs: { method: string; args: unknown[] }[], errorName: string) {
  const serialized = JSON.stringify(logs, (_key, value) => value instanceof Error ? { name: value.name, message: value.message, stack: value.stack } : value);
  for (const marker of ["diagnostic-fixture-public-marker", "customer@example.invalid", "private.fixture.invalid", "/private/customer.m4a", "never-real"])
    check(!serialized.includes(marker), "Apple provider data reached console arguments");
  check(logs.length === 1 && logs[0]!.method === "error" && logs[0]!.args.length === 1 && typeof logs[0]!.args[0] === "string", "One closed Apple diagnostic survives");
  equal(JSON.parse(logs[0]!.args[0] as string), { event: "apple_code_exchange_failed", error_name: errorName }, "Exact closed Apple classification; no invented HTTP status");
}
for (const [mode, name] of [["http", "Error"], ["transport", "TypeError"], ["non-error", "Other"], ["custom-name", "Other"]] as const) {
  Deno.test(`actual authenticated Apple ${mode} failure excludes hostile echo from every console argument`, async () => {
    const result = await invoke(mode);
    equal([result.response.status, result.body], [200, { ok: true, stored: false, reason: "exchange failed" }], "Fixed best-effort client result unchanged");
    equal(result.updates, [], "Failed exchange never writes a profile token");
    equal(result.requests.map(req => req.path), ["/auth/v1/user", "/auth/token"], "One authenticated exchange; no retry");
    safe(result.logs, name);
  });
}
Deno.test("actual successful Apple exchange stores exact token on authenticated actor without diagnostic", async () => {
  const result = await invoke("success");
  equal([result.response.status, result.body], [200, { ok: true, stored: true }], "Success client result unchanged");
  equal(result.updates.length, 1, "One exact token write"); equal(result.logs, [], "No success diagnostic added");
});
Deno.test("actual missing Apple refresh token retains original best-effort response and no write", async () => {
  const result = await invoke("no-token");
  equal(result.body, { ok: true, stored: false, reason: "no refresh token returned" }, "No-token response unchanged");
  equal(result.updates, [], "No invented token write"); equal(result.logs, [], "No diagnostic added");
});
Deno.test("actual profile-store transport failure preserves SDK refusal and emits no new console data", async () => {
  const result = await invoke("store-throw");
  check(result.body.ok === true && result.body.stored === false && typeof result.body.reason === "string" && result.body.reason.includes(HOSTILE), "SDK-returned transport reason is unchanged and not newly sanitized as a client contract");
  equal(result.updates.length, 1, "Only original write attempted"); equal(result.logs, [], "SDK-returned store refusal is not newly logged");
});
Deno.test("actual profile database refusal preserves returned reason and emits no new console data", async () => {
  const result = await invoke("store-error");
  equal(result.body, { ok: true, stored: false, reason: HOSTILE }, "Existing caller-owned returned reason unchanged; not a console sanitization claim");
  equal(result.logs, [], "Returned reason is not newly logged");
});
for (const mode of ["unauthorized", "invalid-code"] as const) {
  Deno.test(`actual ${mode} refuses before Apple exchange or profile storage`, async () => {
    const result = await invoke(mode);
    equal(result.response.status, mode === "unauthorized" ? 401 : 400, "Existing admission retained");
    equal(result.requests.map(req => req.path), ["/auth/v1/user"], "No Apple call after admission refusal");
    equal(result.updates, [], "No profile write"); equal(result.logs, [], "No new diagnostic");
  });
}
