// Closed transport around the actual public handler and shared entry proof.
// No account, external provider, capability or production resource is used.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", render = "30000000-0000-4000-8000-000000000003";
const slug = "location-fixture", published = "2026-10-01T00:00:00Z";
for (const [key, value] of Object.entries({ SUPABASE_URL: "https://location-fixture.invalid", SUPABASE_SERVICE_ROLE_KEY: "inert-service-fixture", SUPABASE_ANON_KEY: "inert-public-fixture" })) Deno.env.set(key, value);
const {adminClient}=await import("../_shared/supabase.ts");
let handler!: (req: Request) => Promise<Response>;
const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, value: (fn: typeof handler) => { handler = fn; return {}; } });
try { await import("./index.ts"); } finally { Object.defineProperty(Deno, "serve", descriptor); }

type Options = { unpublish?: boolean; missing?: boolean; deleted?: boolean; changedCoordinates?: boolean; changedOrg?: boolean; revoked?: boolean; expired?: boolean; privateType?: boolean; noCoordinates?: boolean; failedRead?: boolean; revokedInitial?: boolean; expiredInitial?: boolean };
async function closed<T>(options: Options, run: (db: ReturnType<typeof adminClient>) => Promise<T>) {
  const original = globalThis.fetch; const calls: string[] = []; let renders = 0, listings = 0, visibility = 0, hosting = 0;
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url); assertEquals(url.hostname, "location-fixture.invalid");
    calls.push(url.pathname); const table = url.pathname.split("/").at(-1)!;
    if (table === "renders") { renders++; return Response.json(options.missing || options.unpublish && renders > 1 ? null : { id: render, listing_id: listing, slug, published_at: published }); }
    if (table === "listings") { listings++; if (options.failedRead && listings > 1) return Response.json({ message: "closed read failure" }, { status: 500 });
      return Response.json({ id: listing, org_id: options.changedOrg && listings > 1 ? render : org, space_type: options.privateType ? "venue" : "real_estate", deleted_at: options.deleted && listings > 1 ? published : null,
        lat: options.noCoordinates ? null : options.changedCoordinates && listings > 1 ? 35.228 : 35.2272499, lng: options.noCoordinates ? null : -80.8431799,
        address: "Private Address Sentinel", details: { private: "Private Details Sentinel" }, agent_id: render }); }
    if (table === "studio_presenter_media_visibility") { visibility++; const body = await req.json(); assertEquals(body.p_listing, listing);
      return Response.json(Object.fromEntries(["assets", "renders", "keys"].map(kind => [kind, Object.fromEntries(body[`p_${kind}`].map((key: string) => [key, !(options.revokedInitial || options.revoked && visibility > 1)]))]))); }
    if (table === "hosting_retention_state") { hosting++; const body = await req.json(); assertEquals(body.p_org, org);
      const expired = options.expiredInitial || options.expired && hosting > 1;
      return Response.json({ org_id: org, policy: expired ? "prospective_90_day_grace" : "preserved", protected: false, retention_ends_at: expired ? "2020-01-01T00:00:00Z" : null, hosting_available: !expired }); }
    throw new Error(`Location must not query media, contacts or identity: ${table}`);
  };
  try { return { value: await run(adminClient()), calls, renders, listings, visibility, hosting }; } finally { globalThis.fetch = original; }
}
const invoke = (options: Options = {}, suffix = "location") => closed(options, async () => {
  const response = await handler(new Request(`https://api-fixture.invalid/tours/${slug}/${suffix}`));
  return { status: response.status, cache: response.headers.get("Cache-Control"), body: await response.json() };
});
Deno.test("actual location projection returns only fresh coarsened public coordinates and performs no optional media/contact reads", async () => {
  const r = await invoke(); assertEquals(r.value, { status: 200, cache: "no-store", body: { slug, space_type: "real_estate", published_at: published, listing: { lat: 35.227, lng: -80.843 } } });
  assertEquals([r.renders, r.listings, r.visibility, r.hosting], [2, 2, 2, 2]); assert(!JSON.stringify(r.value).includes("Sentinel"));
});
Deno.test("actual location projection fails closed for initial or final publication, hosting, presenter or listing withdrawal", async () => {
  for (const options of [{ missing: true }, { unpublish: true }, { deleted: true }, { changedOrg: true }, { revoked: true }, { expired: true }, { revokedInitial: true }, { expiredInitial: true }, { privateType: true }]) {
    const r = await invoke(options); assertEquals(r.value.status, 404); assert(!Object.hasOwn(r.value.body, "listing"));
  }
  for (const options of [{ changedCoordinates: true }, { failedRead: true }]) assertEquals((await invoke(options)).value.status, 503);
});
Deno.test("actual location projection permits missing location without manufacturing coordinates and rejects unknown paths", async () => {
  assertEquals((await invoke({ noCoordinates: true })).value.body.listing, { lat: null, lng: null });
  assertEquals((await invoke({}, "private-location")).value.status, 404);
});

Deno.test("compiled shared proof controls detect initial/final authority removal, precision and stale-coordinate leaks", async () => {
  const source = await Deno.readTextFile(new URL("./published-context.ts", import.meta.url));
  const imports = source.replace(/from "(\.\.?\/[^\"]+)"/g, (_m, path) => `from ${JSON.stringify(new URL(path, new URL("./published-context.ts", import.meta.url)).href)}`);
  const controls: [string, string, string, Options, boolean][] = [
    ["initial-hosting", "assertHostingAvailable(admin, listing.org_id), assertMediaVisible", "Promise.resolve(), assertMediaVisible", { expiredInitial: true }, false],
    ["initial-visibility", "assertMediaVisible(admin, listing.id, visibleRefs)]);\n  return { render", "Promise.resolve()]);\n  return { render", { revokedInitial: true }, false],
    ["final-hosting", "assertMediaVisible(admin, listing.id, visibleRefs), assertHostingAvailable(admin, listing.org_id)", "assertMediaVisible(admin, listing.id, visibleRefs), Promise.resolve()", { expired: true }, true],
    ["final-visibility", "assertMediaVisible(admin, listing.id, visibleRefs), assertHostingAvailable(admin, listing.org_id)", "Promise.resolve(), assertHostingAvailable(admin, listing.org_id)", { revoked: true }, true],
    ["stale-coordinates", "current.lat !== listing.lat || current.lng !== listing.lng", "false", { changedCoordinates: true }, true],
    ["coarse-only", "Math.round(value * 1000) / 1000", "value", {}, true],
  ];
  for (const [name, before, after, options, final] of controls) {
    assertEquals(imports.split(before).length, 2, name + " exact mutation");
    const mutated = await import(`data:application/typescript;base64,${btoa(imports.replace(before, after))}`);
    const run = () => closed(options, async db => { const context = await mutated.publishedTourContext(db, slug, true); return final ? await mutated.publishedLocation(db, context) : context; });
    // Unchanged source refuses these withdrawals (or coarsens the valid row).
    const original = await import("./published-context.ts");
    if (name === "coarse-only") assertEquals((await closed({}, async db => original.publishedLocation(db, await original.publishedTourContext(db, slug, true)))).value.listing.lat, 35.227);
    else await assertRejects(() => closed(options, async db => { const context = await original.publishedTourContext(db, slug, true); return final ? original.publishedLocation(db, context) : context; }));
    const leaked = (await run()).value;
    if (name === "coarse-only") assertEquals(leaked.listing.lat, 35.2272499, "compiled precision removal exposes precise coordinate");
    else assert(leaked, name + " compiled removal must expose refused context");
  }
});
