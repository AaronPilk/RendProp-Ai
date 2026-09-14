import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeNativeReel, nativeCaptionStyle, nativeReelShots } from "../src/features/sync/native-reel";
const first = "11111111-1111-4111-8111-111111111111", second = "22222222-2222-4222-8222-222222222222", voice = "ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDEF";
function recipe() { return { schema: 1, kind: "native-reel-setup", portrait: true, titleCard: true, shotCaptions: false, captionStyle: "lowerThird", transition: "dissolve", motionPrompt: "A slow motion through the property", script: "Welcome home.", tone: "warm", wordCaptions: true, voiceMode: "aiVoice", voiceResultId: voice, localNarration: false, photos: [{ localId: "cloud-one", sourcePhotoId: second }, { localId: "cloud-two", sourcePhotoId: first }], localExtraClipCount: 0, updatedAt: "2026-09-14T12:00:00Z" }; }

test("build26 payload preserves native settings and normalizes cloud UUIDs", () => {
  const value = decodeNativeReel(recipe()); assert.equal(value.voiceResultId, voice.toLowerCase());
  assert.equal(value.transition, "dissolve"); assert.equal(value.script, "Welcome home."); assert.equal(value.titleCard, true); assert.equal(value.shotCaptions, false);
});
test("Swift omitted optional UUID fields remain explicit local-media gaps", () => {
  const raw: any = recipe(); delete raw.voiceResultId; delete raw.photos[0].sourcePhotoId;
  const value = decodeNativeReel(raw); assert.equal(value.voiceResultId, null); assert.equal(value.photos[0].sourcePhotoId, null);
  assert.throws(() => nativeReelShots(value), /No photos were skipped/);
});
test("native shot conversion preserves every selected photo in order without inventing timing, captions, or motion", () => {
  const raw = recipe(), shots = nativeReelShots(decodeNativeReel(raw));
  assert.deepEqual(shots.map(shot => shot.photoId), [second, first]); assert.deepEqual(shots.map(shot => shot.order), [1, 2]);
  assert.ok(shots.every(shot => shot.seconds === 3 && shot.motion === "still" && shot.caption === "" && shot.voiceLine === "" && shot.room === ""));
  assert.equal(raw.photos[0].sourcePhotoId, second);
});
test("all caption style mappings match native enum semantics", () => {
  assert.equal(nativeCaptionStyle("off"), undefined); assert.equal(nativeCaptionStyle("lowerThird"), "clean"); assert.equal(nativeCaptionStyle("punchCard"), "center"); assert.equal(nativeCaptionStyle("highlightBox"), "highlight");
});
test("local extra clips block partial sequence import with actionable explanation", () => {
  const raw = recipe(); raw.localExtraClipCount = 1;
  assert.throws(() => nativeReelShots(decodeNativeReel(raw)), /Upload those clips/);
});
test("an empty setup requires choosing photos and cannot silently clear an existing edit", () => {
  const raw = recipe(); raw.photos = []; assert.throws(() => nativeReelShots(decodeNativeReel(raw)), /Choose photos/);
});
test("duplicate local identities, URL identities, malformed UUIDs, and unsupported versions are rejected", () => {
  const duplicate = recipe(); duplicate.photos[1].localId = duplicate.photos[0].localId;
  const badLocal = recipe(); badLocal.photos[0].localId = "file:///private/photo.jpg";
  const badCloud = recipe(); badCloud.photos[0].sourcePhotoId = "https://example.invalid/photo";
  for (const raw of [duplicate, badLocal, badCloud, { ...recipe(), schema: 2 }, { ...recipe(), kind: "other" }]) assert.throws(() => decodeNativeReel(raw), /could not be read/);
});
test("invalid booleans, choices, counts, timestamps and oversized strings do not become defaults", () => {
  for (const patch of [{ portrait: "true" }, { captionStyle: "new-style" }, { transition: "zoom" }, { voiceMode: "remote" }, { tone: "other" }, { localExtraClipCount: 1.1 }, { localExtraClipCount: -1 }, { localExtraClipCount: 101 }, { updatedAt: "yesterday" }, { motionPrompt: "x".repeat(4001) }, { script: "x".repeat(100001) }, { photos: Array(101).fill(recipe().photos[0]) }]) assert.throws(() => decodeNativeReel({ ...recipe(), ...patch }), /could not be read/);
});
test("repeated source photos with different local identities remain repeated shots", () => {
  const raw = recipe(); raw.photos[1].sourcePhotoId = raw.photos[0].sourcePhotoId;
  assert.equal(nativeReelShots(decodeNativeReel(raw)).length, 2);
});
