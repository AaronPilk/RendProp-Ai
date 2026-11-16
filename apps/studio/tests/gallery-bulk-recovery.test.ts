import test from "node:test";
import assert from "node:assert/strict";
import { StudioError } from "../src/data/config";
import type { StudioServices } from "../src/data/services";
import { MAX_SAVED_SOURCE_BATCH, prepareSavedSourceBatch, savedSourceCandidates } from "../src/features/listings/gallery-bulk-recovery";
import type { GalleryCopy } from "../src/features/listings/gallery-copy";
import type { GalleryScope } from "../src/features/listings/gallery-selection";

const scope: GalleryScope = { actor: "actor", org: "org", library: "org", listing: "listing" };
const services = {} as StudioServices;
const source = (id: string) => ({ id, caption: id });
const finished = (id: string) => ({ complete: true, photo: { id, listing_id: scope.listing } }) as GalleryCopy;

test("saved source batch excludes transferred gallery uploads and unrelated assets", () => {
  const root = "renders/org/listing/";
  const photos = [source("original"), source("edited"), source("gallery"), source("foreign"), source("uploads"), source("video"), source("original")];
  const assets = [
    { id: "original", kind: "photo", bucket: "renders", uploaded: true, storage_key: `${root}original-one.jpg` },
    { id: "edited", kind: "photo", bucket: "renders", uploaded: true, storage_key: `${root}edited-one.jpg` },
    { id: "gallery", kind: "photo", bucket: "renders", uploaded: true, storage_key: `${root}gallery-one.jpg` },
    { id: "foreign", kind: "photo", bucket: "renders", uploaded: true, storage_key: "renders/org/other/original-one.jpg" },
    { id: "uploads", kind: "photo", bucket: "uploads", uploaded: true, storage_key: "uploads/org/listing/original-one.jpg" },
    { id: "video", kind: "video", bucket: "renders", uploaded: true, storage_key: `${root}video-one.mp4` },
  ];
  assert.deepEqual(savedSourceCandidates(photos, assets, scope.org, scope.listing), [source("original"), source("edited")]);
});

test("a source-proof refusal does not block other saved sources", async () => {
  const attempted: string[] = [];
  const progress: number[] = [];
  const result = await prepareSavedSourceBatch(services, scope, [source("one"), source("unproven"), source("three")], new AbortController().signal,
    value => progress.push(value.checked), async (_services, _scope, id, _caption, _signal, options) => {
      attempted.push(id);
      if (id === "unproven") throw new StudioError("source_unproven", "No verified original or edit history", 409);
      options?.onSourcePrepared?.();
      return finished(id);
    });
  assert.deepEqual(attempted, ["one", "unproven", "three"]);
  assert.deepEqual(progress, [0, 1, 2, 3]);
  assert.equal(result.prepared, 2);
  assert.equal(result.unavailable, 1);
  assert.equal(result.unavailablePhotos[0]?.id, "unproven");
});

test("a later conflict stops the batch for same-photo resume", async () => {
  const attempted: string[] = [];
  await assert.rejects(() => prepareSavedSourceBatch(services, scope, [source("pending"), source("next")], new AbortController().signal,
    () => {}, async (_services, _scope, id, _caption, _signal, options) => {
      attempted.push(id);
      options?.onSourcePrepared?.();
      throw new StudioError("copy_conflict", "Finish this photo's saved upload", 409);
    }), /Finish this photo/);
  assert.deepEqual(attempted, ["pending"]);
});

test("an ambiguous response stops rather than skipping to another photo", async () => {
  const attempted: string[] = [];
  await assert.rejects(() => prepareSavedSourceBatch(services, scope, [source("uncertain"), source("next")], new AbortController().signal,
    () => {}, async (_services, _scope, id) => { attempted.push(id); throw new Error("Unknown reply"); }), /Unknown reply/);
  assert.deepEqual(attempted, ["uncertain"]);
});

test("a malformed prepare request stops instead of marking every source unavailable", async () => {
  const attempted: string[] = [];
  await assert.rejects(() => prepareSavedSourceBatch(services, scope, [source("bad-request"), source("next")], new AbortController().signal,
    () => {}, async (_services, _scope, id) => { attempted.push(id); throw new StudioError("invalid_request", "Malformed request", 400); }), /Malformed request/);
  assert.deepEqual(attempted, ["bad-request"]);
});

test("one batch never prepares more than fifty sources", async () => {
  const attempted: string[] = [];
  const sources = Array.from({ length: MAX_SAVED_SOURCE_BATCH + 3 }, (_, index) => source(String(index)));
  const result = await prepareSavedSourceBatch(services, scope, sources, new AbortController().signal,
    () => {}, async (_services, _scope, id, _caption, _signal, options) => {
      attempted.push(id);
      options?.onSourcePrepared?.();
      return finished(id);
    });
  assert.equal(result.total, MAX_SAVED_SOURCE_BATCH);
  assert.equal(attempted.length, MAX_SAVED_SOURCE_BATCH);
});
