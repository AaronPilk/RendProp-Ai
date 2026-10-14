// Build 58 — standalone (one process per file: it sets env and replaces
// globalThis.fetch for the whole module, so it must not run inside the
// functions-wide `deno test .` sweep where the first importer of a shared
// module wins). CI runs it with its own `deno test` invocation.
// POST /renders/republish-app: the ENTIRE actual renders handler
// against a closed synthetic Auth/PostgREST transport. Proves the route
// chooses republish_render (not publish_render), answers 200 with the SAME
// render id/slug the app holds, carries `republished: true`, and that the
// ordinary publish-app path is untouched. The in-place SQL behaviour is proved
// in services/supabase/tests/build58_db_controls.sql on a real cluster.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const ORG = "a0582011-0000-4000-8000-000000000001", LISTING = "a0582011-0000-4000-8000-000000000002", USER = "a0582011-0000-4000-8000-000000000003";
const ASSET = "a0582011-0000-4000-8000-000000000004", JOB = "a0582011-0000-4000-8000-000000000005", RENDER = "a0582011-0000-4000-8000-000000000006";
for (const [k, v] of Object.entries({ SUPABASE_URL: "https://republish-fixture.invalid", SUPABASE_ANON_KEY: "fixture-anon", SUPABASE_SERVICE_ROLE_KEY: "fixture-service", CLOUDFLARE_ACCOUNT_ID: "fixture", R2_ACCESS_KEY_ID: "fixture", R2_SECRET_ACCESS_KEY: "fixture", R2_BUCKET_RENDERS: "renders", R2_BUCKET_UPLOADS: "uploads", R2_PUBLIC_BASE_URL: "https://media.fixture.invalid", TOUR_HOST_BASE_URL: "https://rendprop.com" })) Deno.env.set(k, v);

type Handler = (req: Request) => Promise<Response>;
type Call = { path: string; method: string; body: Record<string, unknown> | null };
const state = { calls: [] as Call[], rpcRefusal: null as string | null };
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
const lower = (v: unknown) => typeof v === "string" ? v.toLowerCase() : v;
const renderRow = (jobId: string) => ({ id: RENDER, job_id: jobId, listing_id: LISTING, slug: "b58slug0004", duration_s: 45, speed_factor: 2, video_key: `renders/${ORG}/${LISTING}/new.mp4`, stream_uid: null, poster_key: null, staged: false, published_at: "2026-10-01T12:00:00Z", created_at: "2026-10-01T12:00:00Z", hero_key: null });

globalThis.fetch = async (input, init) => {
  const r = new Request(input, init), u = new URL(r.url);
  assert(u.hostname === "republish-fixture.invalid", "transport stays on the closed fixture origin: " + u.hostname);
  const text = r.method === "GET" || r.method === "HEAD" ? "" : await r.text();
  const body = text ? JSON.parse(text) : null;
  state.calls.push({ path: u.pathname, method: r.method, body });
  if (u.pathname === "/auth/v1/user") return response({ id: USER, is_anonymous: false });
  if (u.pathname === "/rest/v1/deletion_requests") return response(null);
  if (u.pathname === "/rest/v1/render_jobs") return response(null);                 // no prior job for this idempotency key
  if (u.pathname === "/rest/v1/capture_assets") return response({ id: ASSET, listing_id: LISTING });
  if (u.pathname === "/rest/v1/listings") return response({ org_id: ORG });
  if (u.pathname.endsWith("/rpc/listing_library_scope")) { assertEquals(lower(body!.p_listing), LISTING); return response({ actor_id: USER, listing_id: LISTING, org_id: ORG, library_org_id: ORG, library_owner_user_id: USER, listing_owner_user_id: USER, role: "owner", access_mode: "own", can_read: true, can_write: true, can_manage_subscription: true, billing_org_id: ORG, team_org_id: null }); }
  if (u.pathname.endsWith("/rpc/subscription_trial_video_context")) return response({ required: false }); // paid authority: no duration attestation
  if (u.pathname.endsWith("/rpc/create_render_job")) { assertEquals([lower(body!.p_listing), lower(body!.p_asset), body!.p_source], [LISTING, ASSET, "app"]); return response({ id: JOB, listing_id: LISTING }); }
  if (u.pathname.endsWith("/rpc/publish_recorded_render")) {
    assertEquals(body!.p_job, JOB);
    assertEquals(typeof body!.p_republish,"boolean");
    if (state.rpcRefusal) return response({ code: "P0001", message: state.rpcRefusal }, 400);
    return response(renderRow(JOB));
  }
  if (u.pathname.endsWith("/rpc/fail_render_job")) return response(null);
  if (u.pathname.endsWith("/rpc/studio_presenter_media_visibility")) return response({ assets: {}, renders: { [RENDER]: true }, keys: {} });
  throw new Error("Unmodeled transport " + r.method + " " + u.pathname + u.search);
};
let handler!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
try { Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (fn: Handler) => { handler = fn; return {}; } }); await import("../../services/supabase/functions/renders/index.ts"); }
finally { Object.defineProperty(Deno, "serve", serve); }
const publish = (route: string, extra: Record<string, unknown> = {}) => handler(new Request("https://edge.fixture.invalid/renders/" + route, {
  method: "POST", headers: { authorization: "Bearer fixture", "content-type": "application/json", "X-Org-Id": ORG, "Idempotency-Key": "render:" + LISTING + ":" + ASSET },
  body: JSON.stringify({ listing_id: LISTING.toUpperCase(), asset_id: ASSET.toUpperCase(), duration_s: 45, speed_factor: 2, chapters: [{ label: "Kitchen", t_ms: 1000, sort: 0 }], ...extra }),
}));
const rpcNames = () => state.calls.filter((c) => c.path.includes("/rpc/")).map((c) => c.path.split("/").pop());

Deno.test("republish-app selects recorded republish authority, answers 200 with the same render and marks it republished", async () => {
  state.calls = []; state.rpcRefusal = null;
  const r = await publish("republish-app");
  assertEquals(r.status, 200, await r.clone().text());
  const value = await r.json();
  assertEquals([value.id, value.slug, value.job_id, value.republished], [RENDER, "b58slug0004", JOB, true]);
  assertEquals(value.share_url, "https://rendprop.com/f/b58slug0004");
  assertEquals(value.unbranded_url, "https://rendprop.com/u/b58slug0004");
  const names = rpcNames();
  assert(names.includes("publish_recorded_render"),names.join(","));
  assertEquals(state.calls.find(c=>c.path.endsWith("/rpc/publish_recorded_render"))!.body!.p_republish,true);
  assert(names.indexOf("create_render_job") < names.indexOf("publish_recorded_render"));
});

Deno.test("publish-app selects recorded first-publish authority, 201, not marked republished", async () => {
  state.calls = []; state.rpcRefusal = null;
  const r = await publish("publish-app");
  assertEquals(r.status, 201, await r.clone().text());
  const value = await r.json();
  assertEquals([value.id, value.republished], [RENDER, false]);
  const names = rpcNames();
  assert(names.includes("publish_recorded_render"),names.join(","));
  assertEquals(state.calls.find(c=>c.path.endsWith("/rpc/publish_recorded_render"))!.body!.p_republish,false);
});

Deno.test("a republish refused by SQL keeps its status and fails the job it created", async () => {
  state.calls = []; state.rpcRefusal = "RP403: your role does not permit publishing renders";
  const r = await publish("republish-app");
  assertEquals(r.status, 403);
  assert(rpcNames().includes("fail_render_job"), "the created job must not linger");
});

Deno.test("republish-app validates like publish-app", async () => {
  state.calls = []; state.rpcRefusal = null;
  const r = await publish("republish-app", { asset_id: undefined });
  assertEquals(r.status, 400);
  assert(!rpcNames().includes("publish_recorded_render"));
});
