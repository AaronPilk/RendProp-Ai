import assert from "node:assert/strict";
import test from "node:test";
import type { Listing, ListingMedia, Workspace } from "../src/data/contracts";
import { EMPTY_STATE } from "../src/features/listings/model";
import type { Asset, Job, Published } from "../src/features/listings/model";
import { canEditListing, listingFinish } from "../src/features/listings/readiness";
const listing: Listing = { id: "listing", orgId: "org", address: "10 Oak Street", tagline: null, details: {}, status: "ready", createdAt: "2026-09-22", mainPhotoKey: null, beds: null, baths: null, sqft: null, priceCents: null };
const media: ListingMedia = { listingId: listing.id, orgId: listing.orgId, photos: [], videos: [], unavailableCount: 0, nextOffset: null };
const asset: Asset = { id: "asset", listing_id: listing.id, storage_key: "renders/org/listing/photo.jpg", kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: "2026-09-22" };
const job: Job = { id: "job", listing_id: listing.id, capture_asset_id: asset.id, status: "ready", progress: 1, current_step: "ready", tier: "smooth", error: null, created_at: "2026-09-22" };
const published: Published = { id: "render", listing_id: listing.id, job_id: job.id, slug: "oak-street", published_at: "2026-09-22T12:00:00Z", duration_s: 30, staged: false, created_at: "2026-09-22" };
function input() { return { listing, state: structuredClone(EMPTY_STATE), media: structuredClone(media), loading: false, loadFailed: false, pendingUploads: 0, canWrite: true, hasCreativeTools: true }; }

test("loading and failed reads never claim the listing is empty or ready", () => {
  assert.equal(listingFinish({ ...input(), loading: true }).checking, true);
  assert.equal(listingFinish({ ...input(), media: null }).next, null);
  const value = input(); value.state.renders = [published];
  const failed = listingFinish({ ...value, loadFailed: true });
  assert.equal(failed.publishedLinks, null); assert.equal(failed.steps.length, 0);
  assert.deepEqual(failed.next?.destination, { refresh: true });
});
test("partial pages cannot produce completion or a live link", () => {
  const value = input(); value.state.renders = [published]; value.state.nextOffset = 100;
  assert.equal(listingFinish(value).publishedLinks, null);
  value.state.nextOffset = null; value.media.nextOffset = 100;
  assert.deepEqual(listingFinish(value).next?.destination, { refresh: true });
});
test("saved facts are distinguished from a human review; optional facts are not required", () => {
  const result = listingFinish(input());
  assert.equal(result.steps[0].status, "saved"); assert.match(result.steps[0].detail, /Check the address/);
  assert.match(result.title, /Add the property's photos/);
  assert.equal(listingFinish({ ...input(), listing: { ...listing, address: " " } }).next?.label, "Review details");
});
test("photos-only property leads to reviewing and downloading without requiring a camera or paid video", () => {
  const value = input(); value.state.assets = [asset];
  const result = listingFinish(value);
  assert.equal(result.title, "Your photos are ready to review");
  assert.deepEqual(result.next?.destination, { tab: "media" });
  assert.equal(result.next?.requiresWrite, undefined);
  assert.equal(result.steps.find(step => step.id === "create")?.status, "optional");
  assert.equal(result.steps.find(step => step.id === "share")?.title, "Download and share");
  assert.equal(result.steps.find(step => step.id === "review")?.status, "review");
  assert.equal(result.publishedLinks, null);
});
test("a floor-plan-only upload does not count as listing photography", () => {
  const value = input(); value.state.assets = [asset]; value.listing = { ...listing, details: { floorplan_asset_id: asset.id } };
  assert.match(listingFinish(value).title, /Add the property's photos/);
});
test("an uncompleted upload cannot be treated as usable media", () => {
  const value = input(); value.state.assets = [{ ...asset, uploaded: false }];
  assert.match(listingFinish(value).title, /Add the property's photos/);
  const pending = listingFinish({ ...value, pendingUploads: 2 });
  assert.equal(pending.title, "Finish your interrupted uploads"); assert.match(pending.detail, /2 uploads/);
});
test("unavailable media is visible in the checklist instead of marked saved", () => {
  const value = input(); value.state.assets = [asset]; value.media.unavailableCount = 2;
  const step = listingFinish(value).steps.find(step => step.id === "media")!;
  assert.equal(step.status, "waiting"); assert.match(step.detail, /2 media items need a fresh upload/);
});
test("raw video can open the existing reel tool; finished video leads to review before publishing", () => {
  const value = input(); value.state.assets = [{ ...asset, kind: "video", bucket: "uploads" }];
  assert.deepEqual(listingFinish(value).next?.destination, { feature: "reel" });
  value.state.assets[0].bucket = "renders";
  assert.equal(listingFinish(value).next?.label, "Review before publishing");
});
test("generated output QC cannot be bypassed by its presence, ready job, or processing progress", () => {
  const value = input(); value.state.assets = [{ ...asset, kind: "video", qc_required: true }]; value.state.jobs = [job];
  const result = listingFinish(value);
  assert.equal(result.title, "Check the generated results");
  assert.deepEqual(result.next?.destination, { feature: "animate" });
  value.state.assets[0].qc_publishable = true;
  assert.equal(listingFinish(value).next?.label, "Review before publishing");
});
test("a ready job without its source projection is not proof of a publishable video", () => {
  const value = input(); value.state.jobs = [job];
  assert.notEqual(listingFinish(value).next?.label, "Review before publishing");
});
test("active job progress is bounded, tolerates invalid values, and cannot produce a live claim", () => {
  const value = input(); value.state.jobs = [{ ...job, status: "rendering", progress: 45 }, { ...job, id: "other", status: "queued", progress: NaN }];
  const result = listingFinish(value);
  assert.equal(result.progress, .225); assert.equal(result.publishedLinks, null);
  assert.deepEqual(result.next?.destination, { tab: "tour" });
});
test("failed jobs guide to their issue but historical failure does not conceal an existing live tour", () => {
  const value = input(); value.state.jobs = [{ ...job, status: "failed", error: "Processing failed" }];
  assert.equal(listingFinish(value).title, "A render needs attention");
  value.state.renders = [published];
  assert.equal(listingFinish(value).title, "Your tour is live");
  assert.equal(listingFinish(value).publishedLinks?.branded, "https://rendprop.com/f/oak-street");
});
test("published status requires a timestamp and a valid slug, not listing.status or a render row alone", () => {
  const value = input(); value.state.renders = [{ ...published, slug: "javascript:alert(1)" }, { ...published, published_at: null }];
  assert.equal(listingFinish(value).publishedLinks, null);
  value.state.renders = [published, { ...published, id: "later", slug: "oak-later", published_at: "2026-09-23T12:00:00Z" }];
  assert.equal(listingFinish(value).publishedLinks?.branded, "https://rendprop.com/f/oak-later");
});
test("archived and sold properties retain truthful existing-public-link state", () => {
  const value = input(); value.listing = { ...listing, status: "archived" }; value.state.renders = [published];
  assert.equal(listingFinish(value).title, "This property is archived");
  assert.ok(listingFinish(value).publishedLinks);
  assert.equal(listingFinish({ ...value, listing: { ...listing, soldAt: "2026-09-22" } }).title, "This property is marked sold");
});
test("read-only members can view media but never receive a creative primary action", () => {
  const value = input(); value.canWrite = false; value.state.assets = [{ ...asset, kind: "video", qc_required: true }];
  assert.deepEqual(listingFinish(value).next?.destination, { tab: "media" });
  const workspace = { org: { id: "org" }, memberships: [{ orgId: "org", role: "marketing" }] } as Workspace;
  assert.equal(canEditListing(workspace), false);
  assert.equal(canEditListing({ ...workspace, memberships: [] }), false);
  for (const role of ["owner", "admin", "agent"] as const) assert.equal(canEditListing({ ...workspace, memberships: [{ orgId: "org", role } as Workspace["memberships"][number]] }), true);
});
