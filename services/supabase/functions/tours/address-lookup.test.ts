// Actual public handler with only PostgREST transport doubled. The SQL proof
// runs separately against disposable PostgreSQL in property_address_lookup_pg.py.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

for (const [name, value] of Object.entries({
  SUPABASE_URL: "https://address-fixture.invalid",
  SUPABASE_SERVICE_ROLE_KEY: "inert-address-service",
  SUPABASE_ANON_KEY: "inert-address-public",
  ADDRESS_LOOKUP_SECRET: "b".repeat(64),
})) Deno.env.set(name, value);
let handler!: (req: Request) => Promise<Response>;
const oldServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, value: (fn: typeof handler) => {
  handler = fn;
  return {};
} });
try { await import("./index.ts"); } finally { Object.defineProperty(Deno, "serve", oldServe); }

async function invoke(value: unknown, path = "/tours/address-lookup/123-main-st", rpcError = false,
  method = "GET", secret: string | null = "b".repeat(64)) {
  const original = globalThis.fetch;
  const calls: unknown[] = [];
  globalThis.fetch = async (raw, init) => {
    const request = new Request(raw, init);
    const url = new URL(request.url);
    assertEquals(url.hostname, "address-fixture.invalid");
    if (url.pathname === "/rest/v1/renders") return Response.json(null);
    assertEquals(url.pathname, "/rest/v1/rpc/public_property_address_lookup");
    calls.push(await request.json());
    return rpcError
      ? Response.json({ message: "private SQL diagnostic: synthetic address" }, { status: 500 })
      : Response.json(value);
  };
  try {
    const response = await handler(new Request(`https://api-fixture.invalid${path}`, { method,
      headers: secret === null ? {} : { "X-Rendprop-Address-Lookup": secret } }));
    return { status: response.status, cache: response.headers.get("Cache-Control"),
      body: await response.json(), calls };
  } finally { globalThis.fetch = original; }
}

Deno.test("address route returns only a current unique slug proof, including noindex lookup", async () => {
  const result = await invoke({ status: "unique", slug: "published-main-1" });
  assertEquals(result, { status: 200, cache: "no-store",
    body: { status: "unique", slug: "published-main-1" },
    calls: [{ p_descriptor: "123-main-st" }] });
  assert(!JSON.stringify(result).includes("listing_id"));
});

Deno.test("ambiguous and missing address remain non-canonical without leaking listing IDs", async () => {
  const ambiguous = await invoke({ status: "ambiguous" });
  assertEquals(ambiguous.status, 200);
  assertEquals(ambiguous.body, { status: "ambiguous" });
  assertEquals(ambiguous.cache, "no-store");
  const missing = await invoke(null);
  assertEquals(missing.status, 404);
  assert(!JSON.stringify(missing.body).includes("slug"));
});

Deno.test("direct guessed addresses cannot enumerate noindex slugs without Worker credential", async () => {
  for (const secret of [null, "0".repeat(64)]) {
    const result = await invoke({ status: "unique", slug: "private-noindex-slug" },
      "/tours/address-lookup/123-main-st", false, "GET", secret);
    assertEquals(result.status, 403);
    assertEquals(result.calls, []);
    assert(!JSON.stringify(result.body).includes("private-noindex-slug"));
  }
});

Deno.test("malformed authority and database errors fail closed without private SQL detail", async () => {
  for (const value of ["published-main-1", {}, { status: "unique", slug: "bad/slash" },
    { status: "unique", slug: "published-main-1", listing_id: "private" },
    { status: "ambiguous", slug: "wrong" }]) {
    const result = await invoke(value);
    assertEquals(result.status, 503);
    assert(!JSON.stringify(result.body).includes("private"));
  }
  const error = await invoke(null, "/tours/address-lookup/123-main-st", true);
  assertEquals(error.status, 503);
  assert(!JSON.stringify(error.body).includes("private SQL diagnostic"));
});

Deno.test("bad paths and methods never invoke address authority", async () => {
  for (const [path, method, status] of [
    ["/tours/address-lookup/123-main-st?trace=1", "GET", 400],
    ["/tours/address-lookup/123-main-st-", "GET", 400],
    ["/tours/address-lookup/123-main-st/extra", "GET", 404],
    ["/tours/address-lookup", "GET", 404],
    ["/tours/address-lookup/location", "GET", 404],
    ["/tours/address-lookup/123-main-st", "POST", 405],
  ] as const) {
    const result = await invoke(null, path, false, method);
    assertEquals(result.status, status);
    assertEquals(result.calls, []);
  }
});
