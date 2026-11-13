import test from "node:test";
import assert from "node:assert/strict";
import { FEATURES, featureFor } from "../src/features/home/features";
import { listingFinish } from "../src/features/listings/readiness";
import { EMPTY_STATE } from "../src/features/listings/model";

// The iPhone Home leads with photos → AI photo edits → Make a video (Listing 16:9 or Social 9:16),
// with the recorded walkthrough as an optional fourth tool. Studio tiles must describe the same flow.
test("Studio tool cards lead with photos and name the photo video for listing or social, like the iPhone", () => {
  assert.deepEqual(FEATURES.map(feature => feature.id).slice(0, 4), ["photos", "studio", "reel", "tour"]);
  const video = featureFor("reel");
  assert.equal(video.title, "Make a video");
  assert.match(video.description, /listing/i);
  assert.match(video.description, /social/i);
  assert.doesNotMatch(`${video.title} ${video.description}`, /\breel\b|one social video/i);
  const walkthrough = featureFor("tour");
  assert.match(`${walkthrough.title} ${walkthrough.description}`, /optional/i);
  // The property page shows a subset in FEATURES order; the photo tools must lead there too.
  assert.deepEqual(FEATURES.filter(feature => ["studio", "reel", "tour", "aerial"].includes(feature.id)).map(feature => feature.id), ["studio", "reel", "tour", "aerial"]);
  assert.equal(featureFor("aerial").comingSoon, true);
});
test("the listing finish guide offers the photo video by its current name, still optional and write-gated", () => {
  const listing = { id: "listing", orgId: "org", address: "10 Oak Street", tagline: null, details: {}, status: "ready", createdAt: "2026-10-15", mainPhotoKey: null, beds: null, baths: null, sqft: null, priceCents: null } as const;
  const asset = { id: "photo", listing_id: "listing", storage_key: "renders/org/listing/photo.jpg", kind: "photo", bucket: "renders", uploaded: true, duration_s: null, created_at: "2026-10-15" } as const;
  const finish = listingFinish({ listing, state: { ...structuredClone(EMPTY_STATE), assets: [asset] }, media: { orgId: "org", listingId: "listing", photos: [], videos: [], nextOffset: null, unavailableCount: 0 }, loading: false, loadFailed: false, pendingUploads: 0, canWrite: true, hasCreativeTools: true });
  const create = finish.steps.find(step => step.id === "create")!;
  assert.equal(create.status, "optional");
  assert.deepEqual(create.action, { label: "Make a video", destination: { feature: "reel" }, requiresWrite: true });
  assert.doesNotMatch([finish.title, finish.detail, ...finish.steps.map(step => `${step.title} ${step.detail} ${step.action.label}`)].join("\n"), /\breels?\b/i);
});
