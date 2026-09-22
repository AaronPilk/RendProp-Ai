import assert from "node:assert/strict";
import test from "node:test";
import { downloadReelMedia, downloadReelSelection, reelMediaItems, validateReelMediaPage } from "../src/features/sync/ReelMediaPicker";
import type { ReelMedia } from "../src/features/sync/ReelMediaPicker";
import { EDIT_LIMITS } from "../src/editor/model";
const listing = "10000000-0000-4000-8000-000000000001";
const photo: ReelMedia = { id: "photo-1", listingId: listing, url: "https://media.example.invalid/photo.png?signature=fixture", kind: "photo", label: "Kitchen.jpg", altered: false };
const fetchResult = (response: Response): typeof fetch => async () => response;
const signal = () => new AbortController().signal;
test("media paging follows the real 50-row contract without skipping a page", () => {
  validateReelMediaPage(0, 50); validateReelMediaPage(50, 100); validateReelMediaPage(100, null);
  assert.throws(() => validateReelMediaPage(0, 100), /completely/);
  assert.throws(() => validateReelMediaPage(50, 50), /completely/);
  assert.throws(() => validateReelMediaPage(10000, 10050), /completely/);
});

test("media picker preserves property scope, photo identity and existing alteration labels", () => {
  const result = reelMediaItems([{ id: photo.id, listingId: listing, url: photo.url, expiresAt: "2099-01-01T00:00:00Z", caption: "Kitchen", isStaged: true, sort: 0 }], [{ id: "video-1", listingId: listing, url: "https://media.example.invalid/tour.mp4", kind: "video", durationSeconds: 32, createdAt: "2026-09-14T00:00:00Z", expiresAt: "2099-01-01T00:00:00Z" }], listing);
  assert.equal(result[0]?.id, photo.id); assert.equal(result[0]?.altered, true); assert.equal(result[1]?.seconds, 32);
  assert.throws(() => reelMediaItems([{ id: photo.id, listingId: "other", url: photo.url, expiresAt: "2099-01-01T00:00:00Z", caption: "Kitchen", isStaged: false, sort: 0 }], [], listing), /another property/);
});
test("download retains actual source bytes and mime; no account credentials go to storage", async () => {
  const bytes = new Uint8Array([4, 8, 15, 16, 23, 42]); let observed: RequestInit | undefined;
  const file = await downloadReelMedia(photo, 100, signal(), async (url, options) => { assert.equal(url, photo.url); observed = options; return new Response(bytes, { headers: { "content-type": "image/png", "content-length": "6" } }); });
  assert.deepEqual(new Uint8Array(await file.arrayBuffer()), bytes); assert.equal(file.name, "Kitchen.png"); assert.equal(file.type, "image/png"); assert.equal(file.lastModified, 0);
  assert.equal(observed?.credentials, "omit"); assert.equal(observed?.redirect, "error"); assert.equal(observed?.referrerPolicy, "no-referrer"); assert.equal(observed?.headers, undefined);
});
test("declared media over per-file or remaining limits cancels the response before reading it", async () => {
  for (const remaining of [3, EDIT_LIMITS.totalBytes]) {
    let cancelled = false;
    const response = new Response(new ReadableStream({ cancel: () => { cancelled = true; } }), { headers: { "content-type": "image/png", "content-length": String(remaining === 3 ? 4 : EDIT_LIMITS.fileBytes + 1) } });
    await assert.rejects(downloadReelMedia(photo, remaining, signal(), fetchResult(response)), /limit/); assert.equal(cancelled, true);
  }
});
test("streamed bytes remain bounded when no content length is supplied", async () => {
  const response = new Response(new Uint8Array(5), { headers: { "content-type": "image/png" } });
  await assert.rejects(downloadReelMedia(photo, 4, signal(), fetchResult(response)), /limit/);
});
test("empty, truncated and unsupported source media never reach the editor", async () => {
  const cases = [
    new Response(new Uint8Array(), { headers: { "content-type": "image/png" } }),
    new Response(new Uint8Array(2), { headers: { "content-type": "image/png", "content-length": "3" } }),
    new Response(new Uint8Array(2), { headers: { "content-type": "image/heic" } }),
    new Response(new Uint8Array(2), { headers: { "content-type": "video/mp4" } }),
  ];
  for (const response of cases) await assert.rejects(downloadReelMedia(photo, 100, signal(), fetchResult(response)), /incomplete|copy/);
});
test("selection order is retained with exact source IDs, and limits decrease across downloads", async () => {
  const second = { ...photo, id: "photo-2", label: "Living room" }, remaining: number[] = [], progress: number[] = [];
  const request = await downloadReelSelection([second, photo], listing, 10, signal(), () => {}, index => progress.push(index), async (item, budget) => { remaining.push(budget); return new File([new Uint8Array(4)], `${item.id}.png`, { type: "image/png" }); });
  assert.deepEqual(request.sourceMedia, [{ id: "photo-2", kind: "photo" }, { id: "photo-1", kind: "photo" }]);
  assert.deepEqual(request.files.map(file => file.name), ["photo-2.png", "photo-1.png"]); assert.deepEqual(remaining, [10, 6]); assert.deepEqual(progress, [1, 2]);
  assert.equal(request.listingId, listing);
});
test("selection failure returns no partial import request", async () => {
  let calls = 0;
  await assert.rejects(downloadReelSelection([photo, { ...photo, id: "photo-2" }], listing, 100, signal(), () => {}, () => {}, async () => { if (++calls === 2) throw new Error("Link expired"); return new File(["x"], "source.png", { type: "image/png" }); }), /Link expired/);
  assert.equal(calls, 2);
});
test("account switch after a downloaded source prevents handoff and later downloads", async () => {
  let current = true, calls = 0;
  await assert.rejects(downloadReelSelection([photo, { ...photo, id: "photo-2" }], listing, 100, signal(), () => { if (!current) throw new Error("Account changed"); }, () => {}, async () => { calls++; current = false; return new File(["x"], "source.png", { type: "image/png" }); }), /Account changed/);
  assert.equal(calls, 1);
});
test("cancelling download prevents handoff and later files", async () => {
  const controller = new AbortController(); let calls = 0;
  await assert.rejects(downloadReelSelection([photo, { ...photo, id: "photo-2" }], listing, 100, controller.signal, () => {}, () => {}, async () => { calls++; controller.abort(); return new File(["x"], "source.png", { type: "image/png" }); }), /abort/i);
  assert.equal(calls, 1);
});
test("invalid, duplicate or out-of-scope selections fail before downloads", async () => {
  let calls = 0;
  for (const items of [[], [photo, photo], [{ ...photo, listingId: "another" }], Array.from({ length: 13 }, (_, index) => ({ ...photo, id: String(index) }))]) {
    await assert.rejects(downloadReelSelection(items, listing, 100, signal(), () => {}, () => {}, async () => { calls++; return new File(["x"], "source.png"); }), /12 different/);
  }
  assert.equal(calls, 0);
});
