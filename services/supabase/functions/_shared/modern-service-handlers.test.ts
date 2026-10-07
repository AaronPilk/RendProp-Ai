// Actual route handlers and actual credential/user guards. Only remote network
// boundaries are closed. No production account, provider or email is contacted.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const SECRET = "sb_secret_synthetic_service_transport";
const PUBLIC = "sb_publishable_synthetic_public_transport";
Deno.env.set("SUPABASE_URL", "https://service-transport-fixture.invalid");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET }));
Deno.env.set("SUPABASE_PUBLISHABLE_KEYS", JSON.stringify({ default: PUBLIC }));
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "synthetic-legacy-service");
Deno.env.set("MEDIA_GATEWAY_SECRET", "a".repeat(64));
Deno.env.delete("RENDPROP_LEGACY_SERVICE_AUTH");
type Handler = (req: Request) => Promise<Response>;
const handlers: Record<string, Handler> = {};
for (const name of ["notify", "presenter-drain", "me", "uploads", "tours"]) {
  const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  Object.defineProperty(Deno, "serve", { configurable: true, writable: true,
    value: (handler: Handler) => { handlers[name] = handler; return {}; } });
  try { await import(`../${name}/index.ts`); }
  finally { Object.defineProperty(Deno, "serve", descriptor); }
  assert(handlers[name], "Actual route handler was not captured: " + name);
}
const routes = [["notify", ""], ["presenter-drain", ""], ["me", "/sweep-deletions"],
  ["me", "/sweep-privacy"], ["uploads", "/sweep"], ["tours", "/fixture/delivery"]];
Deno.test("each mixed/service entrypoint refuses absent, public, wrong, legacy or forged role authority before any database/provider access", async () => {
  const prior = globalThis.fetch; let calls = 0;
  globalThis.fetch = () => { calls++; throw new Error("An unauthenticated route touched transport"); };
  try {
    for (const [name, suffix] of routes) for (const headers of [{}, { apikey: PUBLIC },
      { apikey: "sb_secret_wrong_synthetic_credential" },
      { authorization: "Bearer synthetic-legacy-service" },
      { authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.unverified" }]) {
      const request = new Request(`https://edge.invalid/${name}${suffix}`, {
        method: name === "tours" ? "GET" : "POST", headers: headers as Record<string, string>, body: name === "tours" ? undefined : "{}",
      });
      assertEquals((await handlers[name](request)).status, 403, `${name}${suffix}`);
    }
    assertEquals(calls, 0);
  } finally { globalThis.fetch = prior; }
});
Deno.test("ordinary mixed-function requests require a real Auth user even with a public app key", async () => {
  const prior = globalThis.fetch; let calls = 0;
  globalThis.fetch = (input, init) => {
    const req = new Request(input, init); calls++;
    assertEquals(new URL(req.url).host, "service-transport-fixture.invalid");
    assertEquals(new URL(req.url).pathname, "/auth/v1/user");
    return Promise.resolve(Response.json({ message: "Invalid JWT" }, { status: 401 }));
  };
  try {
    for (const name of ["me", "uploads"]) {
      assertEquals((await handlers[name](new Request(`https://edge.invalid/${name}`, { headers: { apikey: PUBLIC } }))).status, 401);
      assertEquals((await handlers[name](new Request(`https://edge.invalid/${name}`, { headers: { apikey: PUBLIC, authorization: "Bearer unverified-user" } }))).status, 401);
    }
    assertEquals(calls, 2);
  } finally { globalThis.fetch = prior; }
});
Deno.test("actual modern server key admits only the service route and preserves bounded maintenance input", async () => {
  const prior = globalThis.fetch; const paths: string[] = [];
  globalThis.fetch = (input, init) => {
    const req = new Request(input, init); paths.push(new URL(req.url).pathname);
    assertEquals(req.headers.get("apikey"), SECRET);
    // supabase-js's REST adapter also emits its key as the Bearer fallback;
    // the API-key gateway recognizes the matching apikey, not a JWT claim.
    assertEquals(req.headers.get("authorization"), `Bearer ${SECRET}`);
    assertEquals(paths.at(-1), "/rest/v1/rpc/studio_presenter_execution_due");
    return Promise.resolve(Response.json({ jobs: [] }));
  };
  try {
    const request = (body: string) => new Request("https://edge.invalid/presenter-drain", { method: "POST", headers: { apikey: SECRET }, body });
    assertEquals((await handlers["presenter-drain"](request('{"limit":3}'))).status, 200);
    assertEquals((await handlers["presenter-drain"](request('{"limit":4}'))).status, 400);
    assertEquals(paths.length, 1);
  } finally { globalThis.fetch = prior; }
});
