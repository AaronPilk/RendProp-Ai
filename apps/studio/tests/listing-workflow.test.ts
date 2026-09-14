import test from "node:test";
import assert from "node:assert/strict";
import { File } from "node:buffer";
import { canPublishAsset, decodeListingState, listingPayload, parseChapterText, tourLinks } from "../src/features/listings/model";
import type { Asset } from "../src/features/listings/model";
import { cancelListingUpload, fingerprintFile, uploadListingAsset, validateUpload } from "../src/features/listings/uploads";
import type { UploadJournal } from "../src/features/listings/uploads";
import { decodeSpatialJob, spatialRetryKey } from "../src/features/listings/SpatialWorkflow";
import type { StudioServices } from "../src/data/services";
const org = "10000000-0000-4000-8000-000000000001", listing = "20000000-0000-4000-8000-000000000002", asset = "30000000-0000-4000-8000-000000000003", user = "40000000-0000-4000-8000-000000000004";
const key = `uploads/${org}/${listing}/${asset}.mp4`;
const options = (file: File) => ({ orgId: org, listingId: listing, file: file as globalThis.File });
function fixture(handler: (path: string, options: Record<string, unknown>) => unknown | Promise<unknown>, onUpload?: (body: Blob) => void) {
  let version = 1;
  const calls: { path: string; options: Record<string, unknown> }[] = [];
  const transfers: Blob[] = [];
  const service = {
    getSnapshot: () => ({ status: "signed-in", identityVersion: version, identity: { userId: user, isAnonymous: false } }),
    api: async (path: string, args: Record<string, unknown>) => { calls.push({ path, options: args }); return await handler(path, args); },
    upload: async (_url: string, body: Blob, args: { onProgress?: (n: number, total: number) => void }) => { transfers.push(body); onUpload?.(body); args.onProgress?.(body.size, body.size); return { etag: `receipt-${transfers.length}` }; },
  } as unknown as StudioServices;
  return { service, calls, transfers, switchAccount: () => version++ };
}
const completed = { id: asset, uploaded: true, listing_id: listing, storage_key: key };
test("import validates exact content type, purpose and memory-safe 2GB ceiling before reserving", () => {
  assert.deepEqual(validateUpload({ name: "walk.mov", type: "video/quicktime", size: 2 * 1024 ** 3 }), { kind: "video", contentType: "video/quicktime" });
  assert.throws(() => validateUpload({ name: "walk.mp4", type: "video/mp4", size: 2 * 1024 ** 3 + 1 }), /2 GB/);
  assert.throws(() => validateUpload({ name: "photo.png", type: "image/jpeg", size: 10 }), /disagree/);
  assert.throws(() => validateUpload({ name: "scan.heic", type: "image/heic", size: 10 }, "gallery"), /Export/);
  assert.throws(() => validateUpload({ name: "video.mp4", type: "video/mp4", size: 10 }, "original"), /Choose a photo/);
});
test("file identity includes bytes in the middle, not just filename and endpoints", async () => {
  const first = new Uint8Array(17 * 1024 ** 2), other = first.slice(); other[9 * 1024 ** 2] = 10;
  assert.notEqual(await fingerprintFile(new Blob([first])), await fingerprintFile(new Blob([other])));
});
test("single upload persists reservation before PUT and confirms same server asset", async () => {
  const journals: UploadJournal[] = [];
  const { service, calls, transfers } = fixture((path) => path.endsWith("/complete") ? completed : { asset_id: asset, storage_key: key, mode: "single", uploaded: false, put_url: "https://uploads.rendprop.com/v2/test" });
  const file = new File([new Uint8Array([1, 2, 3])], "walk.mp4", { type: "video/mp4" });
  const result = await uploadListingAsset(service, { ...options(file), onJournal: (j) => journals.push(j) });
  assert.equal(result.assetId, asset); assert.equal(transfers.length, 1);
  assert.equal(calls[0].options.orgId, org); assert.match(String(calls[0].options.idempotencyKey), /^studio-upload:/);
  assert.ok(journals.some((j) => j.assetId === asset)); assert.ok(!JSON.stringify(journals).includes("https://"));
  assert.equal(calls[1].options.idempotencyKey, `complete:${asset}`);
});
test("lost completion response leaves the same reservation available and does not automatically retry", async () => {
  let journal: UploadJournal | undefined;
  const f = fixture((path) => { if (path.endsWith("/complete")) throw new Error("Connection lost"); return { asset_id: asset, storage_key: key, mode: "single", uploaded: false, put_url: "https://uploads.rendprop.com/v2/test" }; });
  const file = new File(["movie"], "walk.mp4", { type: "video/mp4" });
  await assert.rejects(uploadListingAsset(f.service, { ...options(file), onJournal: (j) => journal = j }), /Connection lost/);
  assert.equal(journal?.assetId, asset); assert.equal(f.calls.length, 2); assert.equal(f.transfers.length, 1);
  const resumed = fixture(() => ({ asset_id: asset, storage_key: key, mode: "single", uploaded: true }));
  await uploadListingAsset(resumed.service, { ...options(file), resume: journal });
  assert.equal(resumed.calls.length, 1); assert.match(resumed.calls[0].path, /\/renew$/); assert.equal(resumed.transfers.length, 0);
});
test("completion adopts the server's immutable operation key and persists it", async () => {
  const canonical = `uploads/${org}/${listing}/objects/confirmed-copy.mp4`;
  const f = fixture(path => path.endsWith("/complete") ? {...completed,storage_key:canonical} : {asset_id:asset,storage_key:key,mode:"single",uploaded:false,put_url:"https://uploads.rendprop.com/v2/test"});
  const journals:UploadJournal[]=[];
  const result=await uploadListingAsset(f.service,{...options(new File(["a"],"walk.mp4",{type:"video/mp4"})),onJournal:j=>journals.push(j)});
  assert.equal(result.assetId,asset);assert.equal(result.storageKey,canonical);assert.equal(journals.at(-1)?.storageKey,canonical);
  const wrong=fixture(path=>path.endsWith("/complete")?{...completed,storage_key:`uploads/${org}/${asset}/wrong.mp4`}:{asset_id:asset,storage_key:key,mode:"single",uploaded:false,put_url:"https://uploads.rendprop.com/v2/test"});
  await assert.rejects(uploadListingAsset(wrong.service,options(new File(["a"],"walk.mp4",{type:"video/mp4"}))),/confirmation is still pending/);
});
test("resume refuses a different account, org or changed file before requesting transfer authority", async () => {
  const file = new File(["movie"], "walk.mp4", { type: "video/mp4" });
  const journal: UploadJournal = { version: 1, userId: user, orgId: org, listingId: listing, filename: file.name, bytes: file.size, contentType: file.type, role: "capture", fingerprint: await fingerprintFile(file), operationId: asset, assetId: asset, parts: [], updatedAt: "now" };
  const f = fixture(() => { throw new Error("must not call"); });
  await assert.rejects(uploadListingAsset(f.service, { ...options(new File(["other"], "walk.mp4", { type: "video/mp4" })), resume: journal }), /does not match/);
  await assert.rejects(uploadListingAsset(f.service, { ...options(file), resume: { ...journal, userId: asset } }), /does not match/);
  assert.equal(f.calls.length, 0);
});
test("multipart renew skips only server-confirmed parts and completes exact ordered receipts", async () => {
  const file = new File([new Uint8Array(65 * 1024 ** 2)], "walk.mp4", { type: "video/mp4" });
  const journal: UploadJournal = { version: 1, userId: user, orgId: org, listingId: listing, filename: file.name, bytes: file.size, contentType: file.type, role: "capture", fingerprint: await fingerprintFile(file), operationId: asset, assetId: asset, parts: [], updatedAt: "now" };
  const f = fixture((path, args) => {
    if (path.endsWith("/renew")) return { asset_id: asset, storage_key: key, mode: "multipart", uploaded: false, part_size: 32 * 1024 ** 2, part_count: 3, confirmed_parts: [{ number: 1, etag: "phone-confirmed" }] };
    if (path.endsWith("/part-urls")) return { urls: [{ number: ((args.body as { numbers: number[] }).numbers[0]), url: "https://uploads.rendprop.com/v2/test" }] };
    assert.deepEqual((args.body as { parts: unknown }).parts, [{ number: 1, etag: "phone-confirmed" }, { number: 2, etag: "receipt-1" }, { number: 3, etag: "receipt-2" }]);
    return completed;
  });
  await uploadListingAsset(f.service, { ...options(file), resume: journal });
  assert.deepEqual(f.transfers.map((blob) => blob.size), [32 * 1024 ** 2, 1024 ** 2]);
  assert.equal(f.calls.filter((c) => c.path.endsWith("/part-urls")).length, 2);
});
test("an account switch after ticket prevents uploading bytes", async () => {
  const f = fixture(() => { f.switchAccount(); return { asset_id: asset, storage_key: key, mode: "single", uploaded: false, put_url: "https://uploads.rendprop.com/v2/test" }; });
  await assert.rejects(uploadListingAsset(f.service, options(new File(["a"], "walk.mp4", { type: "video/mp4" }))), /account changed/);
  assert.equal(f.transfers.length, 0);
});
test("successful HTTP completion with a wrong listing is not upload success", async () => {
  const f = fixture((path) => path.endsWith("/complete") ? { ...completed, listing_id: org } : { asset_id: asset, storage_key: key, mode: "single", uploaded: false, put_url: "https://uploads.rendprop.com/v2/test" });
  await assert.rejects(uploadListingAsset(f.service, options(new File(["a"], "walk.mp4", { type: "video/mp4" }))), /confirmation is still pending/);
});
test("cancel requires explicit aborted receipt, not any 2xx response", async () => {
  const f = fixture(() => ({ ok: true }));
  await assert.rejects(cancelListingUpload(f.service, { assetId: asset, userId: user, orgId: org } as UploadJournal), /Cancellation could not be confirmed/);
});
test("property form preserves cents and rejects invalid counts", () => {
  const form = new FormData(); form.set("address", "  123 Oak Street "); form.set("price", "129999.95"); form.set("beds", "3"); form.set("space_type", "real_estate");
  const payload = listingPayload(form); assert.equal(payload.price_cents, 12999995); assert.equal(payload.address, "123 Oak Street");
  form.set("beds", "3.2"); assert.throws(() => listingPayload(form), /valid beds/);
});
test("chapter editor validates order, times, duration and maximum count", () => {
  assert.deepEqual(parseChapterText("0:00 Entry\n0:12 Kitchen", 45), [{ label: "Entry", t_ms: 0, sort: 0 }, { label: "Kitchen", t_ms: 12000, sort: 1 }]);
  assert.throws(() => parseChapterText("0:12 Entry\n0:10 Kitchen"), /time order/);
  assert.throws(() => parseChapterText("0:61 Entry"), /Use a time/);
  assert.throws(() => parseChapterText("1:10 Entry", 60), /after the video/);
});
test("property state rejects cross-workspace data and malformed page cursors", () => {
  const state = { org_id: org, listing_id: listing, assets: [], jobs: [], renders: [], next_offset: null };
  assert.equal(decodeListingState(state, org, listing).assets.length, 0);
  assert.throws(() => decodeListingState({ ...state, org_id: listing }, org, listing), /property changed/);
  assert.throws(() => decodeListingState({ ...state, next_offset: 999 }, org, listing), /pagination/);
  assert.throws(() => decodeListingState({ ...state, assets: [{ id: asset, listing_id: org }] }, org, listing), /another property/);
  assert.equal(tourLinks("javascript:alert(1)"), null);
});
test("spatial review requires current artifact and approved state before a shared URL", async () => {
  const room = { id: asset, listing_id: listing, room_label: "Living room", status: "review", progress: 1, attempt_number: 1, artifact_revision: org, privacy_state: "unreviewed", viewer_url: "https://rendprop.com/3d/private", share_url: null, can_retry: false, can_cancel: false, can_resume: false };
  assert.equal(decodeSpatialJob(room, listing).status, "review");
  assert.throws(() => decodeSpatialJob({ ...room, artifact_revision: null }, listing));
  assert.throws(() => decodeSpatialJob({ ...room, share_url: "https://rendprop.com/3d/public" }, listing), /not been approved/);
  assert.equal(await spatialRetryKey({ id: asset, attempt_number: 1 }), await spatialRetryKey({ id: asset.toUpperCase(), attempt_number: 1 }));
  assert.notEqual(await spatialRetryKey({ id: asset, attempt_number: 1 }), await spatialRetryKey({ id: asset, attempt_number: 2 }));
});
test("generated videos fail closed until the trusted accuracy projection permits publishing", () => {
  assert.equal(canPublishAsset({ qc_required: true } as Asset), false);
  assert.equal(canPublishAsset({ qc_required: true, qc_publishable: false } as Asset), false);
  assert.equal(canPublishAsset({ qc_required: true, qc_publishable: true } as Asset), true);
  assert.equal(canPublishAsset({ qc_required: false } as Asset), true);
});
