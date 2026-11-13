import assert from "node:assert/strict";
import { test } from "node:test";
import type { ListingMedia, StudioPhoto, StudioVideo } from "../src/data/contracts";
import { earliestExpiry, LINK_KEEP_MS, mediaObject, recallMedia, rememberMedia, retainFreshLinks } from "../src/data/media-cache";

const ORG = "33333333-3333-4333-8333-333333333333", LISTING = "44444444-4444-4444-8444-444444444444";
const NOW = Date.parse("2026-11-12T12:00:00Z");
const at = (ms: number) => new Date(NOW + ms).toISOString();
const signed = (key: string, signature: string) => `https://media.example.invalid/${key}?X-Amz-Signature=${signature}`;
const gateway = (key: string, exp: number) =>
  `https://rendprop.com/private-media/${Buffer.from(JSON.stringify({ v: 1, exp, actor: "a", org: ORG, listing: LISTING, bucket: "uploads", key })).toString("base64url")}.${"a".repeat(64)}`;
const photo = (id: string, url: string, expiresAt: string, extra: Partial<StudioPhoto> = {}): StudioPhoto =>
  ({ id, listingId: LISTING, url, expiresAt, caption: null, isStaged: false, sort: 0, ...extra });
const video = (id: string, url: string, expiresAt: string): StudioVideo =>
  ({ id, listingId: LISTING, url, expiresAt, kind: "video", createdAt: at(0), durationSeconds: 5 });
const media = (photos: StudioPhoto[], videos: StudioVideo[] = [], listingId = LISTING): ListingMedia =>
  ({ orgId: ORG, listingId, photos, videos, nextOffset: null, unavailableCount: 0 });

test("a signed link's object identity ignores its signature and expiry", () => {
  assert.equal(mediaObject(signed("uploads/a.jpg", "one")), mediaObject(signed("uploads/a.jpg", "two")));
  assert.notEqual(mediaObject(signed("uploads/a.jpg", "one")), mediaObject(signed("uploads/b.jpg", "one")));
  assert.equal(mediaObject(gateway("uploads/x/a.jpg", 1)), "uploads/uploads/x/a.jpg");
  assert.equal(mediaObject(gateway("uploads/x/a.jpg", 1)), mediaObject(gateway("uploads/x/a.jpg", 2)));
  assert.equal(mediaObject("not a url"), "");
  assert.equal(mediaObject("https://rendprop.com/private-media/%%%." + "a".repeat(64)), "https://rendprop.com/private-media/%%%." + "a".repeat(64));
});

test("a refresh keeps a still-good link for the same object and takes every new, changed or aging one", () => {
  const previous = media([
    photo("p-keep", signed("a.jpg", "old"), at(LINK_KEEP_MS + 1000)),
    photo("p-aging", signed("b.jpg", "old"), at(LINK_KEEP_MS - 1000)),
    photo("p-edited", signed("c.jpg", "old"), at(LINK_KEEP_MS + 1000)),
    photo("p-removed", signed("d.jpg", "old"), at(LINK_KEEP_MS + 1000)),
    photo("p-original", signed("e-edit.jpg", "old"), at(LINK_KEEP_MS + 1000), { originalUrl: signed("e.jpg", "old") }),
    photo("p-original-new", signed("f-edit.jpg", "old"), at(LINK_KEEP_MS + 1000)),
  ], [video("v-keep", signed("v.mp4", "old"), at(LINK_KEEP_MS + 1000))]);
  const next = media([
    photo("p-keep", signed("a.jpg", "new"), at(600_000), { caption: "New caption" }),
    photo("p-aging", signed("b.jpg", "new"), at(600_000)),
    photo("p-edited", signed("c-twilight.jpg", "new"), at(600_000)),
    photo("p-added", signed("g.jpg", "new"), at(600_000)),
    photo("p-original", signed("e-edit.jpg", "new"), at(600_000), { originalUrl: signed("e.jpg", "new") }),
    photo("p-original-new", signed("f-edit.jpg", "new"), at(600_000), { originalUrl: signed("f.jpg", "new") }),
  ], [video("v-keep", signed("v.mp4", "new"), at(600_000))]);
  const merged = retainFreshLinks(previous, next, NOW);
  const by = new Map(merged.photos.map((item) => [item.id, item]));
  assert.deepEqual(merged.photos.map((item) => item.id), next.photos.map((item) => item.id), "the new answer alone decides what is listed");
  assert.equal(by.get("p-keep")!.url, signed("a.jpg", "old"));
  assert.equal(by.get("p-keep")!.expiresAt, at(LINK_KEEP_MS + 1000), "a kept link keeps its own, earlier expiry");
  assert.equal(by.get("p-keep")!.caption, "New caption", "details always come from the new answer");
  assert.equal(by.get("p-aging")!.url, signed("b.jpg", "new"));
  assert.equal(by.get("p-edited")!.url, signed("c-twilight.jpg", "new"), "a changed saved object never keeps the old link");
  assert.equal(by.get("p-added")!.url, signed("g.jpg", "new"));
  assert.equal(by.get("p-original")!.url, signed("e-edit.jpg", "old"));
  assert.equal(by.get("p-original")!.originalUrl, signed("e.jpg", "old"));
  assert.equal(by.get("p-original-new")!.url, signed("f-edit.jpg", "new"), "a newly available original takes both new links");
  assert.equal(by.get("p-original-new")!.originalUrl, signed("f.jpg", "new"));
  assert.equal(merged.videos[0].url, signed("v.mp4", "old"));
  assert.equal(earliestExpiry(merged), NOW + LINK_KEEP_MS + 1000);
  assert.equal(retainFreshLinks(media([photo("p-keep", signed("a.jpg", "old"), at(600_000))], [], "55555555-5555-4555-8555-555555555555"), next, NOW), next, "another property's links are never reused");
  assert.equal(retainFreshLinks(null, next, NOW), next);
  assert.equal(earliestExpiry(media([])), Infinity);
});

test("remembered media is scoped to one account, library and property and expires with its links", () => {
  const owner = {}, scope = { identityVersion: 1, user: "u", library: ORG, org: ORG, listing: LISTING };
  const saved = media([photo("p", signed("a.jpg", "s"), at(300_000))]);
  rememberMedia(owner, "full", scope, saved);
  assert.equal(recallMedia(owner, "full", scope, NOW), saved);
  assert.equal(recallMedia(owner, "preview", scope, NOW), null);
  assert.equal(recallMedia({}, "full", scope, NOW), null, "another service instance shares nothing");
  assert.equal(recallMedia(owner, "full", { ...scope, identityVersion: 2 }, NOW), null, "a new sign-in shares nothing");
  assert.equal(recallMedia(owner, "full", { ...scope, user: "other" }, NOW), null);
  assert.equal(recallMedia(owner, "full", { ...scope, library: "other" }, NOW), null);
  assert.equal(recallMedia(owner, "full", scope, NOW + 250_000), null, "links within a minute of expiry are not reused");
  assert.equal(recallMedia(owner, "full", scope, NOW), null, "an expired entry is dropped");
  for (let index = 0; index < 40; index++) rememberMedia(owner, "full", { ...scope, listing: `l-${index}` }, { ...saved, listingId: `l-${index}` });
  assert.equal(recallMedia(owner, "full", { ...scope, listing: "l-0" }, NOW), null, "the oldest entries are evicted");
  assert.notEqual(recallMedia(owner, "full", { ...scope, listing: "l-39" }, NOW), null);
});
