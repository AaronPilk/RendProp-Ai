import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { canonicalPhotoKey, galleryCaption, handleListingActions, photoRow } from "./listing-actions.ts";
import { HttpError } from "../_shared/http.ts";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", id = "30000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004";
const asset = { id, listing_id: listing, uploaded: true, bucket: "renders", kind: "photo", content_type: "image/jpeg", storage_key: `renders/${org}/${listing}/gallery-${id}.jpg` };
type Result = { data: unknown; error?: unknown };
function fixture(results: Array<{ table: string; result: Result; client?: "db" | "admin"; wait?: () => Promise<void> }>) {
  // The role fixture now represents the service-only listing authority, not
  // a client membership lookup. Keep every subsequent business query intact.
  results = results.map(item => item.table === "memberships" ? {table:"listing_library_scope",client:"admin" as const,result:{data:{actor_id:user,org_id:org,library_org_id:org,listing_id:listing,listing_owner_user_id:user,library_owner_user_id:user,role:(item.result.data as any)?.role,access_mode:"own",can_read:true,can_write:(item.result.data as any)?.role!=="marketing",can_manage_subscription:false,billing_org_id:org,team_org_id:null},error:item.result.error}} : item);
  const calls: Array<{ table: string; op: string; args: unknown[]; client: "db" | "admin" }> = [];
  const client = (boundary: "db" | "admin") => ({ rpc(name: string, args: unknown) {
    const item = results.shift(); assertEquals(item?.table, name); assertEquals(item?.client ?? "db", boundary);
    calls.push({ table: name, op: "rpc", args: [args], client: boundary }); return Promise.resolve(item!.result);
  }, from(table: string) {
    const item = results.shift(); assertEquals(item?.table, table); assertEquals(item?.client ?? "db", boundary);
    const query: Record<string, unknown> = {};
    for (const op of ["select", "eq", "is", "limit", "update", "insert"]) query[op] = (...args: unknown[]) => { calls.push({ table, op, args, client: boundary }); return query; };
    for (const op of ["maybeSingle", "single"]) query[op] = async () => { await item!.wait?.(); return item!.result; };
    return query;
  } });
  const context = {
    userId: user, orgId: org, publicURL: (key: string) => `https://media.rendprop.com/${key}`,
    authorizeListing: async (value: string) => { assertEquals(value, listing); },
    db: client("db"), admin: client("admin"),
  };
  return { context, calls, remaining: () => results.length };
}
function request(action: string, body: unknown, method = "POST") {
  return new Request(`https://fixture.invalid/functions/v1/studio/${action}`, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}
Deno.test("gallery accepts only completed same-property canonical photos", () => {
  assertEquals(canonicalPhotoKey(asset, org, listing), asset.storage_key);
  assertThrows(() => canonicalPhotoKey({ ...asset, uploaded: false }, org, listing), Error, "completely uploaded");
  assertThrows(() => canonicalPhotoKey({ ...asset, listing_id: org }, org, listing), Error, "this property");
  assertThrows(() => canonicalPhotoKey({ ...asset, storage_key: `renders/${org}/${listing}/../other.jpg` }, org, listing), Error, "this property");
});

Deno.test("caption edits retain authoritative disclosure without duplicating its suffix", () => {
  assertEquals(galleryCaption("Sunny kitchen", "AI-altered photo"), "Sunny kitchen · AI-altered photo");
  assertEquals(galleryCaption("Sunny kitchen · AI-altered photo", "AI-altered photo"), "Sunny kitchen · AI-altered photo");
  assertEquals(galleryCaption("", "AI-altered photo"), "AI-altered photo");
  assertEquals(galleryCaption("", null), null);
  assertThrows(() => galleryCaption("x".repeat(501), null), Error, "500 characters");
});
Deno.test("caption action binds service RPC to verified actor and exact baseline, ignoring injected flags", async () => {
  const photo = { ...photoRow(asset, org, listing, "Kitchen"), is_staged: true, caption: "Kitchen · AI-altered photo", is_main: false };
  const f = fixture([{ table: "memberships", result: { data: { role: "agent" } } },
    { table: "studio_photo_caption", client: "admin", result: { data: { ok: true, photo: { ...photo, caption: "Bright kitchen · AI-altered photo" } } } }]);
  const response = await handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: photo.caption, caption: "Bright kitchen", is_staged: false, original_key: "invented", org_id: "invented" }, "PATCH"), f.context);
  assertEquals(response?.status, 200);
  assertEquals(f.calls.find(c => c.op === "rpc" && c.table !== "listing_library_scope")?.args, [{ p_actor: user, p_org: org, p_listing: listing, p_photo: id, p_expected: photo.caption, p_caption: "Bright kitchen" }]);
  assertEquals(f.calls.some(c => ["update", "insert"].includes(c.op)), false);
});
Deno.test("caption conflict is refused and exact desired replay uses the same atomic RPC", async () => {
  const make = (result: Result) => fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "studio_photo_caption", client: "admin", result }]);
  const f = make({ data: null, error: { message: "RP409: This caption changed on another device. Refresh before saving again" } });
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: "Old caption", caption: "Office caption" }, "PATCH"), f.context), Error, "changed on another device");
  const replay = await handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: "Old caption", caption: "Phone caption" }, "PATCH"), make({ data: { ok: true, photo: { id, listing_id: listing, caption: "Phone caption" } } }).context);
  assertEquals(replay?.status, 200);
});
Deno.test("gallery cover and order use actor-bound request service RPC with bounded exact ids", async () => {
  const f = fixture([{ table: "memberships", result: { data: { role: "agent" } } }, { table: "studio_gallery_update_v2", client: "admin", result: { data: { ok: true, main_photo_key: asset.storage_key } } }]);
  assertEquals((await handleListingActions(request("photos", { listing_id: listing, action: "cover", photo_id: id, expected_main_photo_key: null, org_id: "invented" }, "PATCH"), f.context))?.status, 200);
  assertEquals(f.calls.find(c => c.op === "rpc" && c.table !== "listing_library_scope")?.args[0], { p_actor: user, p_org_id: org, p_listing_id: listing, p_action: "cover", p_photo_id: id, p_expected: null, p_value: null });
  const invalid = fixture([{ table: "memberships", result: { data: { role: "agent" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "reorder", expected_order: [id, id], photo_ids: [id, id] }, "PATCH"), invalid.context), Error, "each gallery photo once");
});
Deno.test("gallery permission and database conflicts remain actionable without succeeding", async () => {
  const denied = fixture([{ table: "memberships", result: { data: { role: "marketing" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "cover", photo_id: id, expected_main_photo_key: null }, "PATCH"), denied.context), Error, "role does not permit");
  const stale = fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "studio_gallery_update_v2", client: "admin", result: { data: null, error: { message: "RP409: The gallery changed on another device. Refresh before reordering" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "reorder", expected_order: [id], photo_ids: [id] }, "PATCH"), stale.context), Error, "changed on another device");
});
Deno.test("altered gallery photo derives immutable original and disclosure from provenance", () => {
  const provenance = { id: user, org_id: org, listing_id: listing, original_key: `renders/${org}/${listing}/original-${user}.jpg`, altered_key: asset.storage_key, disclosure: "AI-altered photo", kind: "photo_edit" };
  const row = photoRow(asset, org, listing, "Living room", provenance);
  assertEquals(row.original_key, provenance.original_key); assertEquals(row.enhanced_key, asset.storage_key); assertEquals(row.is_staged, true); assertEquals(row.caption, "Living room · AI-altered photo");
  assertThrows(() => photoRow(asset, org, listing, "", { ...provenance, original_key: null }), Error, "untouched original");
  assertThrows(() => photoRow(asset, org, listing, "", { ...provenance, org_id: listing }), Error, "does not belong");
});
Deno.test("marketing role cannot create public gallery or floor-plan metadata", async () => {
  const f = fixture([{ table: "memberships", result: { data: { role: "marketing" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, asset_id: id }), f.context), Error, "role does not permit");
  assertEquals(f.remaining(), 0); assertEquals(f.calls.some((c) => c.op === "insert"), false);
});
Deno.test("replayed photo attachment uses stable asset id and does not insert duplicate", async () => {
  const row = photoRow(asset, org, listing, "Kitchen");
  const f = fixture([
    { table: "memberships", result: { data: { role: "agent" } } },
    { table: "capture_assets", result: { data: asset } },
    { table: "studio_attach_photo", client: "admin", result: { data: { ok: true, created: false, photo: row } } },
  ]);
  const response = await handleListingActions(request("photos", { listing_id: listing, asset_id: id, caption: "Kitchen" }), f.context);
  assertEquals(response?.status, 200); assertEquals(f.calls.some((c) => c.op === "insert"), false);
});
Deno.test("floor-plan attachment preserves listing details and uses optimistic concurrency", async () => {
  const details = { features: ["Pool"], description: "Phone description" };
  const f = fixture([
    { table: "memberships", result: { data: { role: "owner" } } },
    { table: "capture_assets", result: { data: asset } },
    { table: "listings", result: { data: { id: listing, details } } },
    { table: "studio_attach_floorplan", result: { data: { id: listing } }, client: "admin" },
  ]);
  const response = await handleListingActions(request("floorplan", { listing_id: listing, asset_id: id, org_id: "invented", details: { description: "injected replacement" } }), f.context);
  assertEquals(response?.status, 200);
  const rpc = f.calls.find(c => c.op === "rpc" && c.table !== "listing_library_scope")!;
  assertEquals(rpc.client, "admin");
  assertEquals(rpc.args, [{ p_actor: user, p_org: org, p_listing: listing, p_asset: id,
    p_expected: details, p_url: `https://media.rendprop.com/${asset.storage_key}` }]);
  assertEquals(f.calls.some(c => c.op === "update"), false);
});
Deno.test("floor-plan concurrent phone edit produces conflict instead of success", async () => {
  for (const code of ["PT409", "40001"]) {
  const f = fixture([
    { table: "memberships", result: { data: { role: "owner" } } },
    { table: "capture_assets", result: { data: asset } },
    { table: "listings", result: { data: { id: listing, details: {} } } },
    { table: "studio_attach_floorplan", result: { data: null, error: { code } }, client: "admin" },
  ]);
  const error = await assertRejects(() => handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), f.context), HttpError, "changed on another device");
  assertEquals(error.status, 409);
  assertEquals(f.calls.filter(c => c.op === "rpc" && c.table !== "listing_library_scope").length, 1);
  assertEquals(f.calls.some(c => c.op === "update"), false);
  }
});

Deno.test("floor-plan attachment fails safely when its request service client is unavailable", async () => {
  const f = fixture([
    { table: "memberships", result: { data: { role: "owner" } } },
    { table: "capture_assets", result: { data: asset } },
  ]);
  const { admin: _admin, ...withoutAdmin } = f.context;
  await assertRejects(() => handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), withoutAdmin), Error, "temporarily unavailable");
  assertEquals(f.calls.some(c => c.op === "update"), false);
});

Deno.test("floor-plan authorization and asset checks precede every service mutation", async () => {
  const denied = fixture([{ table: "memberships", result: { data: { role: "marketing" } } }]);
  await assertRejects(() => handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), denied.context), Error, "role does not permit");
  assertEquals(denied.calls.some(c => c.client === "admin" && c.table !== "listing_library_scope"), false);
  const foreign = fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "capture_assets", result: { data: { ...asset, storage_key: `renders/${id}/${listing}/foreign.jpg` } } }]);
  await assertRejects(() => handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), foreign.context), Error, "does not belong");
  assertEquals(foreign.calls.some(c => c.client === "admin" && c.table !== "listing_library_scope"), false);
});

Deno.test("Studio binds both floor-plan clients to the verified request context", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  assertEquals(source.includes("const db = userClient(req), admin = adminClient();"), true);
  assertEquals(source.includes("const context: StudioContext = { userId: user.id, orgId: org, listingId: listingId ?? null, db, admin,"), true);
  assertEquals(source.includes("handleListingActions(req, context)"), true);
});

for (const change of ["role revoked", "account deletion started"]) Deno.test(`floor-plan held listing read cannot save after ${change}`, async () => {
  let release!: () => void, arrived!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  const arrival = new Promise<void>(resolve => { arrived = resolve; });
  const mutation = { table: "studio_attach_floorplan", result: { data: { id: listing } } as Result, client: "admin" as const };
  const f = fixture([
    { table: "memberships", result: { data: { role: "owner" } } },
    { table: "capture_assets", result: { data: asset } },
    { table: "listings", result: { data: { id: listing, details: {} } }, wait: async () => { arrived(); await held; } },
    mutation,
  ]);
  const pending = handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), f.context);
  await arrival;
  // The real database fixture performs the corresponding role/deletion change
  // before invoking this same service RPC. Its write-time refusal maps to403.
  mutation.result = { data: null, error: { code: "42501" } }; release();
  await assertRejects(() => pending, Error, "no longer permits");
  assertEquals(f.calls.some(c => c.op === "update"), false);
  assertEquals(f.calls.find(c => c.op === "rpc" && c.table !== "listing_library_scope")?.table, "studio_attach_floorplan");
});

Deno.test("direct gallery and floor plan attachment reject an uploaded client headshot before property writes",async()=>{
 const headshot={...asset,storage_key:`renders/${org}/${listing}/contact-${id}.jpg`};
 assertThrows(()=>photoRow(headshot,org,listing,"Client portrait"),Error,"headshots");
 for(const action of ["photos","floorplan"]){
   const f=fixture([{table:"memberships",result:{data:{role:"agent"}}},{table:"capture_assets",result:{data:headshot}}]);
   await assertRejects(()=>handleListingActions(request(action,{listing_id:listing,asset_id:id}),f.context),Error,"headshots");
   assertEquals(f.calls.some(call=>["update","insert"].includes(call.op)),false);
 }
});

Deno.test("photo attachment fails closed without request service client or confirmed scoped receipt", async () => {
  const base = [{ table: "memberships", result: { data: { role: "owner" } } }, { table: "capture_assets", result: { data: asset } }];
  const missing = fixture([...base]); const { admin: _admin, ...context } = missing.context;
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, asset_id: id }), context), Error, "temporarily unavailable");
  const foreign = fixture([...base, { table: "studio_attach_photo", client: "admin", result: { data: { ok: true, created: true, photo: { id, listing_id: org } } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, asset_id: id }), foreign.context), Error, "could not be confirmed");
});
Deno.test("photo service refusal after preliminary read preserves atomic authority gate", async () => {
  for (const message of ["RP403: Your role does not permit editing photos", "RP409: This account is being deleted"]) {
    const f = fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "capture_assets", result: { data: asset } }, { table: "studio_attach_photo", client: "admin", result: { data: null, error: { message } } }]);
    await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, asset_id: id, caption: "Reviewed", is_staged: false, enhanced_key: "invented" }), f.context), Error, message.slice(7));
    assertEquals(f.calls.find(c => c.op === "rpc" && c.table !== "listing_library_scope")?.args[0], { p_actor: user, p_org: org, p_listing: listing, p_asset: id, p_caption: "Reviewed", p_provenance: null });
    assertEquals(f.calls.some(c => ["insert", "update"].includes(c.op)), false);
  }
});
