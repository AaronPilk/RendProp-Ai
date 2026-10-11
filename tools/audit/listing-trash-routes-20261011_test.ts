// Build 58 — standalone (one process per file: it sets env and replaces
// globalThis.fetch for the whole module, so it must not run inside the
// functions-wide `deno test .` sweep where the first importer of a shared
// module wins). CI runs it with its own `deno test` invocation.
// Recently deleted: the ENTIRE actual listings handler against a
// closed synthetic Auth/PostgREST transport. Proves routing, the delete
// route's restore window, the two new routes' authority binding and the
// phone's casing. The SQL side (restore_listing, list_trashed_listings,
// listing_trash_sweep, republish_render) is proved in
// services/supabase/tests/build58_db_controls.sql on a real cluster.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const ORG = "a0581011-0000-4000-8000-000000000001", ID = "a0581011-0000-4000-8000-000000000002", USER = "a0581011-0000-4000-8000-000000000003";
for (const [k, v] of Object.entries({ SUPABASE_URL: "https://trash-fixture.invalid", SUPABASE_ANON_KEY: "fixture-anon", SUPABASE_SERVICE_ROLE_KEY: "fixture-service", CLOUDFLARE_ACCOUNT_ID: "fixture", R2_ACCESS_KEY_ID: "fixture", R2_SECRET_ACCESS_KEY: "fixture", R2_BUCKET_RENDERS: "renders", R2_BUCKET_UPLOADS: "uploads", R2_PUBLIC_BASE_URL: "https://media.fixture.invalid" })) Deno.env.set(k, v);

type Handler = (req: Request) => Promise<Response>;
type Call = { path: string; method: string; body: unknown; search: string; headers: Record<string, string> };
const state = { calls: [] as Call[], trashed: true, restoreRefusal: null as string | null, listTrash: null as unknown, deletePatch: null as Record<string, unknown> | null, deleting: false };
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
const lower = (v: unknown) => typeof v === "string" ? v.toLowerCase() : v;
const trashRow = () => ({ id: ID, org_id: ORG, library_org_id: ORG, agent_id: USER, address: "855 Central Ave", space_type: "real_estate", main_photo_key: null, deleted_at: "2026-10-11T15:00:00Z", trash_expires_at: "2026-11-10T15:00:00Z", had_published_tour: true, can_restore: true });

globalThis.fetch = async (input, init) => {
  const r = new Request(input, init), u = new URL(r.url);
  assert(u.hostname === "trash-fixture.invalid", "transport stays on the closed fixture origin");
  const body = r.method === "GET" || r.method === "HEAD" ? null : await r.text().then((t) => t ? JSON.parse(t) : null);
  state.calls.push({ path: u.pathname, method: r.method, body, search: u.search, headers: Object.fromEntries(r.headers) });
  if (u.pathname === "/auth/v1/user") return response({ id: USER, is_anonymous: false });
  if (u.pathname === "/rest/v1/deletion_requests") return response(state.deleting ? { id: "x" } : null);
  if (u.pathname.endsWith("/rpc/workspace_directory")) return response({ actor_id: USER, own_org_id: ORG, billing_org_id: ORG, can_switch_agent_libraries: false, active_org_id: ORG, workspaces: [{ id: ORG, name: "Fixture", role: "owner", access_mode: "own", library_owner_user_id: USER, billing_org_id: ORG, can_read: true, can_write: true, can_manage_subscription: true, team_org_id: null }] });
  if (u.pathname.endsWith("/rpc/list_trashed_listings")) {
    assertEquals(body, { p_actor: USER, p_org: ORG });
    return response(state.listTrash ?? { actor_id: USER, org_id: ORG, listings: [trashRow()] });
  }
  if (u.pathname.endsWith("/rpc/restore_listing")) {
    assertEquals(body, { p_actor: USER, p_listing: ID });
    if (state.restoreRefusal) return response({ code: "P0001", message: state.restoreRefusal }, 400);
    state.trashed = false;
    return response({ ok: true, actor_id: USER, listing_id: ID, org_id: ORG, library_org_id: ORG, address: "855 Central Ave", republished_renders: 1, cancelled_client_deliveries: 0, restored_at: "2026-10-11T16:00:00Z" });
  }
  if (u.pathname.endsWith("/rpc/listing_library_scope")) {
    assertEquals(lower(body.p_listing), ID);
    if (state.trashed) return response({ code: "P0001", message: "RP404: Listing not found" }, 400);
    return response({ actor_id: USER, listing_id: ID, org_id: ORG, library_org_id: ORG, library_owner_user_id: USER, listing_owner_user_id: USER, role: "owner", access_mode: "own", can_read: true, can_write: true, can_manage_subscription: true, billing_org_id: ORG, team_org_id: null });
  }
  if (u.pathname === "/rest/v1/listings" && r.method === "GET") return response({ id: ID, org_id: ORG });
  if (u.pathname === "/rest/v1/listings" && r.method === "PATCH") { state.deletePatch = body; return response({ id: ID }); }
  if (u.pathname === "/rest/v1/renders" && r.method === "PATCH") return response([]);
  throw new Error("Unmodeled transport " + r.method + " " + u.pathname + u.search);
};
let handler!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
try { Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (fn: Handler) => { handler = fn; return {}; } }); await import("../../services/supabase/functions/listings/index.ts"); }
finally { Object.defineProperty(Deno, "serve", serve); }
const call = (path: string, method = "GET", headers: Record<string, string> = { "X-Org-Id": ORG }) =>
  handler(new Request("https://edge.fixture.invalid/listings" + path, { method, headers: { authorization: "Bearer fixture", "content-type": "application/json", ...headers } }));
const reset = () => { state.calls = []; state.trashed = true; state.restoreRefusal = null; state.listTrash = null; state.deletePatch = null; state.deleting = false; };

Deno.test("DELETE opens a 30-day restore window and says so", async () => {
  reset(); state.trashed = false;
  const before = Date.now();
  const r = await call(`/${ID.toUpperCase()}`, "DELETE");
  assertEquals(r.status, 200);
  const value = await r.json();
  assertEquals(value.ok, true);
  assert(state.deletePatch && typeof state.deletePatch.deleted_at === "string" && typeof state.deletePatch.trash_expires_at === "string");
  const window = Date.parse(state.deletePatch.trash_expires_at as string) - Date.parse(state.deletePatch.deleted_at as string);
  assertEquals(window, 30 * 24 * 60 * 60 * 1000);
  assert(Date.parse(value.restorable_until) >= before + 30 * 24 * 60 * 60 * 1000 - 1000);
  assertEquals(state.deletePatch.trash_expires_at, value.restorable_until);
});

Deno.test("GET /listings/trash lists the selected library's Recently deleted", async () => {
  reset();
  const r = await call("/trash");
  assertEquals(r.status, 200);
  const value = await r.json();
  assertEquals(value.org_id, ORG);
  assertEquals(value.listings.length, 1);
  assertEquals(value.listings[0].id, ID);
  assertEquals(value.listings[0].had_published_tour, true);
  // The trashed row never went near the ordinary listing authority.
  assert(!state.calls.some((c) => c.path.endsWith("/rpc/listing_library_scope")));
});

Deno.test("GET /listings/trash needs a selected workspace and refuses other methods", async () => {
  reset();
  assertEquals((await call("/trash", "GET", {})).status, 409);
  assertEquals((await call("/trash", "POST")).status, 405);
  assert(!state.calls.some((c) => c.path.endsWith("/rpc/list_trashed_listings")));
});

Deno.test("GET /listings/trash refuses an authority answer bound to someone else", async () => {
  reset(); state.listTrash = { actor_id: "a0581011-0000-4000-8000-00000000beef", org_id: ORG, listings: [] };
  const r = await call("/trash");
  assertEquals(r.status, 503);
  assertEquals((await r.json()).code, "upstream");
});

Deno.test("POST /listings/:id/restore (uppercase id from the phone) restores and re-checks the ordinary authority", async () => {
  reset();
  const r = await call(`/${ID.toUpperCase()}/restore`, "POST");
  assertEquals(r.status, 200, await r.clone().text());
  const value = await r.json();
  assertEquals([value.ok, value.id, value.org_id, value.republished_renders, value.address], [true, ID, ORG, 1, "855 Central Ave"]);
  const names = state.calls.map((c) => c.path.split("/").pop());
  assertEquals(names.filter((n) => n === "restore_listing").length, 1);
  // Deletion gate first, then the restore, then the fresh ordinary scope on the live row.
  assert(names.indexOf("deletion_requests") < names.indexOf("restore_listing"));
  assert(names.indexOf("restore_listing") < names.lastIndexOf("listing_library_scope"));
});

Deno.test("restore refusals keep their SQL status: window closed 410, stranger 403, not deleted 409", async () => {
  for (const [refusal, status] of [["RP410: The restore window for this listing has closed", 410], ["RP403: Your role does not permit restoring this listing", 403], ["RP409: This listing is not deleted", 409], ["RP404: Listing not found", 404]] as const) {
    reset(); state.restoreRefusal = refusal;
    const r = await call(`/${ID}/restore`, "POST");
    assertEquals(r.status, status, refusal);
  }
});

Deno.test("restore refuses a listing from another workspace and an account being deleted", async () => {
  reset();
  assertEquals((await call(`/${ID}/restore`, "POST", { "X-Org-Id": "a0581011-0000-4000-8000-00000000cafe" })).status, 404);
  reset(); state.deleting = true;
  assertEquals((await call(`/${ID}/restore`, "POST")).status, 409);
  assert(!state.calls.some((c) => c.path.endsWith("/rpc/restore_listing")), "no restore while the account is being deleted");
  reset();
  assertEquals((await call(`/not-a-uuid/restore`, "POST")).status, 400);
  assertEquals((await call(`/${ID}/restore`, "GET")).status, 405);
});
