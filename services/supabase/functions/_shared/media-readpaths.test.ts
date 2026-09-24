// Capture the actual deployed handlers and stub only Auth/PostgREST transport.
// No socket, provider, real account, or object-storage network call is allowed.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002";
const renderId = "30000000-0000-4000-8000-000000000003", asset = "40000000-0000-4000-8000-000000000004";
const user = "50000000-0000-4000-8000-000000000005", jobId = "60000000-0000-4000-8000-000000000006";
const galleryId = "70000000-0000-4000-8000-000000000007", resultId = "80000000-0000-4000-8000-000000000008";
const prefix = `renders/${org}/${listing}`, key = `${prefix}/finished.mp4`, altered = `${prefix}/altered.mp4`, galleryKey = `${prefix}/gallery-test.jpg`;
for (const [name, value] of Object.entries({ SUPABASE_URL: "https://media-privacy-fixture.invalid", SUPABASE_ANON_KEY: "synthetic-public", SUPABASE_SERVICE_ROLE_KEY: "synthetic-service", CLOUDFLARE_ACCOUNT_ID: "media-fixture", R2_ACCESS_KEY_ID: "synthetic-access", R2_SECRET_ACCESS_KEY: "synthetic-secret", R2_PUBLIC_BASE_URL: "https://media-fixture.invalid" })) Deno.env.set(name, value);
let captured!: (req: Request) => Promise<Response>;
const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (fn: typeof captured) => { captured = fn; return {}; } });
let tour!: typeof captured, renders!: typeof captured, portfolio!: typeof captured;
try { await import("../tours/index.ts"); tour = captured; await import("../renders/index.ts"); renders = captured; await import("../portfolio/index.ts"); portfolio = captured; }
finally { Object.defineProperty(Deno, "serve", descriptor); }
const { handleCreative } = await import("../studio/creative.ts");
const { adminClient } = await import("./supabase.ts");
const response = (value: unknown) => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
type Options = { denyRender?: boolean; denyOptional?: boolean; revokeAfterFirst?: boolean; rpcFailure?: boolean; revokeAfterTwo?: boolean; missingVisibility?: boolean; invalidVisibility?: boolean; revokeDuringProfile?: boolean };
async function invoke(handler: "tour" | "renders" | "publish" | "creative" | "history" | "portfolio", opts: Options = {}) {
  const previous = globalThis.fetch; let checks = 0, profileRead = false; const seen: Record<string, unknown>[] = [];
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "media-privacy-fixture.invalid");
    if (url.pathname === "/auth/v1/user") return response({ id: user, email: "fixture@example.invalid", is_anonymous: false });
    if (url.pathname === "/rest/v1/rpc/studio_presenter_media_visibility") {
      const args = await req.json(); seen.push(args); checks++;
      assertEquals(args.p_listing, listing);
      if (opts.rpcFailure) return new Response(JSON.stringify({ message: "permission backend unavailable" }), { status: 503, headers: { "content-type": "application/json" } });
      if (opts.missingVisibility) return response({ assets: {}, renders: {}, keys: {} });
      if (opts.invalidVisibility) return response({ assets: {}, renders: { [renderId]: "true" }, keys: {} });
      return response(Object.fromEntries(["assets", "renders", "keys"].map(kind => [kind, Object.fromEntries(args[`p_${kind}`].map((v: string) => [v,
        !(opts.revokeDuringProfile && profileRead) && !(opts.revokeAfterFirst && checks > 1) && !(opts.revokeAfterTwo && checks > 2) && !(opts.denyRender && (v === renderId || v === asset || v === key)) && !(opts.denyOptional && [galleryId, galleryKey, altered].includes(v))]))])));
    }
    if (url.pathname === "/rest/v1/rpc/publish_render") return response({ id: renderId, listing_id: listing, slug: "fixture-tour", video_key: key });
    if (url.pathname === "/rest/v1/rpc/assert_studio_edit_quality") return response(null);
    const table = url.pathname.split("/").pop();
    if (table === "renders") { const row = { id: renderId, job_id: jobId, listing_id: listing, slug: "fixture-tour", video_key: key, poster_key: `${prefix}/poster.jpg`, published_at: "2026-09-24T00:00:00Z", duration_s: 5 }; return response(handler === "portfolio" ? [row] : row); }
    if (table === "listings") { const row = { id: listing, org_id: org, agent_id: user, deleted_at: null, details: {}, address: "Synthetic listing" }; return response(handler === "portfolio" ? [row] : row); }
    if (table === "orgs") return response({ id: org, handle: "fixture", brand_kit: {} });
    if (table === "profiles") { profileRead = true; return response({ name: "Fixture Agent" }); }
    if (table === "render_jobs") return response({ id: jobId, listing_id: listing, capture_asset_id: null, status: "completed" });
    if (table === "capture_assets") return response([{ id: galleryId, storage_key: galleryKey }]);
    if (table === "media_provenance") return response([{ kind: "video.edit", disclosure: "Edited video", original_key: key, altered_key: altered }]);
    if (table === "studio_creative_results") { const row = { id: resultId, listing_id: listing, org_id: org, user_id: user, kind: "video", bucket: "renders", storage_key: key,
      metadata: { state: "completed", video_kind: "edit", asset_id: asset, source_asset_ids: [asset] } }; return response(handler === "history" ? [row] : row); }
    throw new Error(`Unmodelled fixture request ${url.pathname}`);
  };
  try {
    const req = new Request(`https://app.fixture.invalid/${handler === "tour" ? "tours/fixture-tour" : handler === "renders" ? `renders/${jobId}` : handler === "publish" ? `renders/${jobId}/publish` : handler === "history" ? `studio/creative-results?listing_id=${listing}` : handler === "portfolio" ? "portfolio/fixture" : "studio/sign-media"}`, {
      method: ["creative", "publish"].includes(handler) ? "POST" : "GET", headers: { authorization: "Bearer synthetic-user" }, ...(["creative", "publish"].includes(handler) ? { body: JSON.stringify({ result_id: resultId }) } : {}),
    });
    const result = ["creative", "history"].includes(handler) ? await handleCreative(req, { userId: user, orgId: org, db: adminClient(), admin: adminClient(), authorizeListing: () => Promise.resolve() }) : await (handler === "tour" ? tour : handler === "portfolio" ? portfolio : renders)(req);
    assert(result); return { status: result.status, body: await result.json(), checks, seen };
  } finally { globalThis.fetch = previous; }
}
Deno.test("actual public tour service handler denies revoked published render lineage", async () => {
  const r = await invoke("tour", { denyRender: true }); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});
Deno.test("actual public tour filters revoked disclosure and gallery objects", async () => {
  const r = await invoke("tour", { denyOptional: true }); assertEquals(r.status, 200);
  assertEquals(r.body.gallery, []); assertEquals(r.body.altered_media, []); assert(r.body.video_url);
  assert(r.seen.some(call => (call.p_keys as string[]).includes(altered)));
});
Deno.test("actual public tour discards URLs on revocation during response assembly", async () => {
  const r = await invoke("tour", { revokeAfterFirst: true }); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});
Deno.test("actual native render status never emits fresh revoked tour links", async () => {
  for (const opts of [{ denyRender: true }, { revokeAfterFirst: true }]) {
    const r = await invoke("renders", opts); assertEquals(r.status, 404); assert(!JSON.stringify(r.body).includes("fixture-tour"));
  }
});
Deno.test("actual creative signed-link refresh suppresses revoked edit before and after signing", async () => {
  for (const opts of [{ denyRender: true }, { revokeAfterFirst: true }]) {
    const r = await invoke("creative", opts); assertEquals(r.status, 200); assertEquals(r.body.result.qc_publishable, false);
    assertEquals(r.body.result.url, undefined); assertEquals(r.body.result.source_url, undefined);
    assertEquals(r.checks, opts.denyRender ? 1 : 2);
  }
});
Deno.test("actual tour permission outages fail closed without media URLs", async () => {
  const r = await invoke("tour", { rpcFailure: true }); assertEquals(r.status, 503); assert(!JSON.stringify(r.body).includes("media-fixture.invalid"));
});

Deno.test("actual native publish replay rechecks privacy before returning object keys or share links", async () => {
  const r = await invoke("publish", { denyRender: true }); assertEquals(r.status, 404);
  assert(!JSON.stringify(r.body).includes("fixture-tour")); assert(!JSON.stringify(r.body).includes(key));
});

Deno.test("actual creative history rechecks the whole completed page before releasing any URL", async () => {
  const r = await invoke("history", { revokeAfterTwo: true }); assertEquals(r.status, 200); assertEquals(r.checks, 3);
  assertEquals(r.body.results[0].url, undefined); assertEquals(r.body.results[0].qc_publishable, false);
});

Deno.test("actual service portfolio omits revoked render posters and tour links", async () => {
  const r = await invoke("portfolio", { denyRender: true }); assertEquals(r.status, 200); assertEquals(r.body.tours, []);
  assert(!JSON.stringify(r.body).includes("fixture-tour")); assert(!JSON.stringify(r.body).includes("poster.jpg"));
});
Deno.test("actual service portfolio preserves permitted ordinary render cards", async () => {
  const r = await invoke("portfolio"); assertEquals(r.status, 200); assertEquals(r.checks, 2);
  assertEquals(r.body.tours[0].slug, "fixture-tour"); assertEquals(r.body.tours[0].poster, `https://media-fixture.invalid/${prefix}/poster.jpg`);
  assert(r.seen.every(call => (call.p_renders as string[]).includes(renderId)));
});
Deno.test("actual service portfolio rechecks permission after asynchronous profile read", async () => {
  const r = await invoke("portfolio", { revokeDuringProfile: true }); assertEquals(r.status, 200); assertEquals(r.checks, 2); assertEquals(r.body.tours, []);
});
Deno.test("actual service portfolio fails closed on unavailable or malformed visibility", async () => {
  for (const opts of [{ rpcFailure: true }, { missingVisibility: true }, { invalidVisibility: true }]) {
    const r = await invoke("portfolio", opts); assertEquals(r.status, 503); assert(!JSON.stringify(r.body).includes("fixture-tour"));
  }
});
