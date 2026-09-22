import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { canonicalPhotoKey, galleryCaption, handleListingActions, photoRow } from "./listing-actions.ts";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", id = "30000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004";
const asset = { id, listing_id: listing, uploaded: true, bucket: "renders", kind: "photo", content_type: "image/jpeg", storage_key: `renders/${org}/${listing}/gallery-${id}.jpg` };
type Result = { data: unknown; error?: unknown };
function fixture(results: Array<{ table: string; result: Result }>) {
  const calls: Array<{ table: string; op: string; args: unknown[] }> = [];
  const context = {
    userId: user, orgId: org, publicURL: (key: string) => `https://media.rendprop.com/${key}`,
    authorizeListing: async (value: string) => { assertEquals(value, listing); },
    db: { rpc(name: string, args: unknown) { const item = results.shift(); assertEquals(item?.table, name); calls.push({ table: name, op: "rpc", args: [args] }); return Promise.resolve(item!.result); }, from(table: string) {
      const item = results.shift(); assertEquals(item?.table, table);
      const query: Record<string, unknown> = {};
      for (const op of ["select", "eq", "is", "limit", "update", "insert"]) query[op] = (...args: unknown[]) => { calls.push({ table, op, args }); return query; };
      for (const op of ["maybeSingle", "single"]) query[op] = () => Promise.resolve(item!.result);
      return query;
    } },
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
Deno.test("caption action fences simultaneous edits and cannot modify disclosure storage or flags", async () => {
  const photo = { ...photoRow(asset, org, listing, "Kitchen"), is_staged: true, caption: "Kitchen · AI-altered photo", is_main: false };
  const f = fixture([
    { table: "memberships", result: { data: { role: "agent" } } },
    { table: "photos", result: { data: photo } },
    { table: "media_provenance", result: { data: { disclosure: "AI-altered photo" } } },
    { table: "photos", result: { data: { ...photo, caption: "Bright kitchen · AI-altered photo" } } },
  ]);
  const response = await handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: photo.caption, caption: "Bright kitchen", is_staged: false, original_key: "invented" }, "PATCH"), f.context);
  assertEquals(response?.status, 200);
  assertEquals(f.calls.find(c => c.op === "update")?.args, [{ caption: "Bright kitchen · AI-altered photo" }]);
  assertEquals(f.calls.some(c => c.op === "eq" && c.args[0] === "caption" && c.args[1] === photo.caption), true);
  assertEquals(f.calls.some(c => c.op === "eq" && c.args[0] === "listing_id" && c.args[1] === listing), true);
});
Deno.test("caption conflict leaves server metadata unchanged, replay of desired caption succeeds", async () => {
  const photo = { ...photoRow(asset, org, listing, "Phone caption"), is_main: false };
  const make = () => fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "photos", result: { data: photo } }, { table: "media_provenance", result: { data: null } }]);
  const f = make();
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: "Old caption", caption: "Office caption" }, "PATCH"), f.context), Error, "changed on another device");
  assertEquals(f.calls.some(c => c.op === "update"), false);
  const replay = await handleListingActions(request("photos", { listing_id: listing, action: "caption", photo_id: id, expected_caption: "Old caption", caption: "Phone caption" }, "PATCH"), make().context);
  assertEquals(replay?.status, 200);
});
Deno.test("gallery cover and order use request RLS RPC with server workspace and bounded exact ids", async () => {
  const f = fixture([{ table: "memberships", result: { data: { role: "agent" } } }, { table: "studio_gallery_update", result: { data: { ok: true, main_photo_key: asset.storage_key } } }]);
  assertEquals((await handleListingActions(request("photos", { listing_id: listing, action: "cover", photo_id: id, expected_main_photo_key: null, org_id: "invented" }, "PATCH"), f.context))?.status, 200);
  assertEquals(f.calls.find(c => c.op === "rpc")?.args[0], { p_org_id: org, p_listing_id: listing, p_action: "cover", p_photo_id: id, p_expected: null, p_value: null });
  const invalid = fixture([{ table: "memberships", result: { data: { role: "agent" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "reorder", expected_order: [id, id], photo_ids: [id, id] }, "PATCH"), invalid.context), Error, "each gallery photo once");
});
Deno.test("gallery permission and database conflicts remain actionable without succeeding", async () => {
  const denied = fixture([{ table: "memberships", result: { data: { role: "marketing" } } }]);
  await assertRejects(() => handleListingActions(request("photos", { listing_id: listing, action: "cover", photo_id: id, expected_main_photo_key: null }, "PATCH"), denied.context), Error, "role does not permit");
  const stale = fixture([{ table: "memberships", result: { data: { role: "owner" } } }, { table: "studio_gallery_update", result: { data: null, error: { message: "RP409: The gallery changed on another device. Refresh before reordering" } } }]);
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
    { table: "media_provenance", result: { data: null } },
    { table: "photos", result: { data: row } },
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
    { table: "listings", result: { data: { id: listing } } },
  ]);
  const response = await handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), f.context);
  assertEquals(response?.status, 200);
  const update = f.calls.find((c) => c.op === "update")!.args[0] as { details: Record<string, unknown> };
  assertEquals(update.details.features, details.features); assertEquals(update.details.description, details.description);
  assertEquals(update.details.floorplan_asset_id, id);
  assertEquals(f.calls.some((c) => c.op === "eq" && c.args[0] === "details" && c.args[1] === JSON.stringify(details)), true);
});
Deno.test("floor-plan concurrent phone edit produces conflict instead of success", async () => {
  const f = fixture([
    { table: "memberships", result: { data: { role: "owner" } } },
    { table: "capture_assets", result: { data: asset } },
    { table: "listings", result: { data: { id: listing, details: {} } } },
    { table: "listings", result: { data: null } },
  ]);
  await assertRejects(() => handleListingActions(request("floorplan", { listing_id: listing, asset_id: id }), f.context), Error, "changed on another device");
});
