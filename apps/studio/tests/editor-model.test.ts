import test from "node:test";
import assert from "node:assert/strict";
import {
  EDIT_LIMITS,
  assertCurrentRevision,
  assertSourceMatch,
  coverCrop,
  formatTime,
  locateTime,
  mediaKind,
  moveClip,
  parseDraft,
  renderDimensions,
  reviseDraft,
  serializeDraft,
  timelineDuration,
  validateDraft,
  validateFileBatch,
  type EditClip,
  type EditDraft,
} from "../src/editor/model.ts";

const photo = (id = "photo"): EditClip => ({
  id,
  source: {
    name: "Kitchen.jpg",
    size: 12_345,
    lastModified: 100,
    sha256: "a".repeat(64),
    kind: "image",
    width: 1200,
    height: 800,
    duration: 0,
  },
  start: 0,
  end: 3,
  caption: "A light-filled kitchen",
  focusX: 0.5,
  focusY: 0.5,
});
const video = (): EditClip => ({
  id: "video",
  source: {
    name: "Walkthrough.mp4",
    size: 234_567,
    lastModified: 200,
    sha256: "b".repeat(64),
    kind: "video",
    width: 1920,
    height: 1080,
    duration: 20,
  },
  start: 4,
  end: 9,
  caption: "",
  focusX: 0.5,
  focusY: 0.5,
});
const draft = (): EditDraft => ({
  schema: 1,
  id: "edit-1",
  revision: 0,
  ratio: "9:16",
  title: "Just listed",
  audio: "original",
  clips: [photo(), video()],
});

test("timeline resolves exact cut boundaries, trim offsets, and end position", () => {
  const clips = draft().clips;
  assert.equal(timelineDuration(clips), 8);
  assert.equal(locateTime(clips, 0)?.clip.id, "photo");
  assert.equal(locateTime(clips, 2.999)?.clip.id, "photo");
  assert.deepEqual(locateTime(clips, 3), {
    clip: clips[1],
    index: 1,
    localTime: 0,
    sourceTime: 4,
  });
  assert.equal(locateTime(clips, 5)?.sourceTime, 6);
  assert.equal(locateTime(clips, 500)?.sourceTime, 9);
  assert.equal(locateTime(clips, -10)?.localTime, 0);
  assert.equal(locateTime(clips, Number.NaN)?.localTime, 0);
  assert.equal(locateTime([], 0), null);
});

test("reordering is immutable and changes the playback order", () => {
  const before = draft().clips;
  const moved = moveClip(before, 0, 1);
  assert.deepEqual(
    moved.map((clip) => clip.id),
    ["video", "photo"],
  );
  assert.equal(before[0]?.id, "photo");
  assert.equal(locateTime(moved, 4)?.clip.id, "video");
  assert.equal(locateTime(moved, 5)?.clip.id, "photo");
  assert.throws(() => moveClip(before, -1, 0), /existing clip/);
  assert.throws(() => moveClip(before, 0, 2), /existing clip/);
  assert.throws(() => moveClip(before, 0.5, 1), /existing clip/);
});

test("cover crop preserves source geometry and exposes framing over excess pixels", () => {
  const crop = coverCrop(1920, 1080, 720, 1280);
  assert.equal(crop.height, 1080);
  assert.equal(crop.width, 607.5);
  assert.equal(crop.x, 656.25);
  assert.equal(crop.y, 0);
  assert.equal(coverCrop(1920, 1080, 720, 1280, 0).x, 0);
  assert.equal(coverCrop(1920, 1080, 720, 1280, 1).x, 1312.5);
  assert.deepEqual(coverCrop(800, 1200, 960, 960, 0.5, 1), {
    x: 0,
    y: 400,
    width: 800,
    height: 800,
  });
  assert.deepEqual(coverCrop(1200, 800, 960, 960, 99, -2), {
    x: 400,
    y: 0,
    width: 800,
    height: 800,
  });
  assert.throws(() => coverCrop(0, 800, 720, 1280), /positive/);
  assert.throws(() => coverCrop(Infinity, 800, 720, 1280), /positive/);
  for (const ratio of ["9:16", "16:9", "1:1"] as const) {
    const size = renderDimensions(ratio);
    const [w, h] = ratio.split(":").map(Number);
    assert.equal(size.width / size.height, w! / h!);
    assert.ok(size.width <= 1280 && size.height <= 1280);
  }
});

test("each accepted edit increments revision and leaves the previous edit intact", () => {
  const initial = draft();
  const next = reviseDraft(initial, {
    title: "Open house",
    ratio: "16:9",
    audio: "muted",
  });
  assert.equal(next.revision, 1);
  assert.equal(initial.title, "Just listed");
  assert.equal(initial.audio, "original");
  assert.equal(next.audio, "muted");
  assert.throws(
    () =>
      reviseDraft(initial, {
        clips: [photo(), { ...video(), start: 10, end: 9 }],
      }),
    /trim end/,
  );
});

test("saved plans are schema checked and serialize only allowed edit fields", () => {
  const original = draft();
  const untrusted = {
    ...original,
    blobURL: "blob:do-not-persist",
    token: "do-not-persist",
    clips: original.clips.map((clip) => ({
      ...clip,
      url: "blob:source",
      source: { ...clip.source, url: "blob:source" },
    })),
  };
  const safe = validateDraft(untrusted);
  assert.deepEqual(safe, original);
  const json = serializeDraft(safe);
  assert.equal(json.includes("blob:"), false);
  assert.equal(json.includes("do-not-persist"), false);
  assert.deepEqual(parseDraft(json), original);
  assert.throws(() => parseDraft("{"), SyntaxError);
  assert.throws(
    () => parseDraft(" ".repeat(EDIT_LIMITS.draftBytes + 1)),
    /64 KiB/,
  );
  assert.throws(() => validateDraft({ ...original, schema: 2 }), /Unsupported/);
  assert.throws(
    () => validateDraft({ ...original, audio: "generated" }),
    /Unsupported/,
  );
  assert.throws(
    () => validateDraft({ ...original, ratio: "3:2" }),
    /Unsupported/,
  );
  assert.throws(
    () => validateDraft({ ...original, clips: [photo(), photo()] }),
    /Duplicate/,
  );
  assert.throws(
    () => validateDraft({ ...original, revision: 0.5 }),
    /whole number/,
  );
  assert.throws(
    () =>
      validateDraft({
        ...original,
        clips: [{ ...photo(), source: { ...photo().source, sha256: "" } }],
      }),
    /SHA-256/,
  );
});

test("all duration, caption, media, and timeline limits fail visibly", () => {
  const base = draft();
  const badClips: Array<[EditClip, RegExp]> = [
    [{ ...photo(), start: 1 }, /trim start/],
    [{ ...photo(), end: 0.49 }, /trim end/],
    [{ ...photo(), end: 31 }, /trim end/],
    [{ ...video(), end: 21 }, /trim end/],
    [{ ...video(), start: NaN }, /trim start/],
    [{ ...video(), end: Infinity }, /trim end/],
    [{ ...photo(), focusX: 1.01 }, /horizontal framing/],
    [{ ...photo(), caption: "x".repeat(121) }, /caption/],
    [{ ...photo(), caption: "1\n2\n3\n4\n5" }, /four lines/],
    [
      {
        ...photo(),
        source: { ...photo().source, width: 12_000, height: 12_000 },
      },
      /pixel limit/,
    ],
    [
      { ...video(), source: { ...video().source, duration: Infinity } },
      /duration/,
    ],
    [{ ...photo(), source: { ...photo().source, size: 1.5 } }, /whole number/],
  ];
  for (const [clip, message] of badClips)
    assert.throws(() => validateDraft({ ...base, clips: [clip] }), message);
  assert.throws(
    () =>
      validateDraft({
        ...base,
        clips: Array.from({ length: 7 }, (_, index) => ({
          ...photo(String(index)),
          end: 30,
        })),
      }),
    /180-second/,
  );
  assert.throws(
    () =>
      validateDraft({
        ...base,
        clips: Array.from({ length: 13 }, (_, index) => photo(String(index))),
      }),
    /12 clips/,
  );
  assert.throws(
    () =>
      validateDraft({
        ...base,
        clips: Array.from({ length: 6 }, (_, index) => ({
          ...photo(String(index)),
          source: { ...photo().source, sha256: String(index).repeat(64), size: EDIT_LIMITS.fileBytes },
        })),
      }),
    /512 MiB/,
  );
});

test("input batch limits reject the complete selection without truncation", () => {
  const file = { name: "Image.jpg", type: "image/jpeg", size: 100 };
  assert.doesNotThrow(() => validateFileBatch([file], draft().clips));
  assert.throws(() => validateFileBatch([]), /at least one/);
  assert.throws(() => validateFileBatch([{ ...file, size: 0 }]), /empty/);
  assert.throws(
    () => validateFileBatch([{ ...file, size: EDIT_LIMITS.fileBytes + 1 }]),
    /per-file limit/,
  );
  assert.throws(
    () =>
      validateFileBatch(
        Array.from({ length: 11 }, () => file),
        draft().clips,
      ),
    /would make 13/,
  );
  assert.throws(
    () =>
      validateFileBatch(
        Array.from({ length: 6 }, () => ({
          ...file,
          size: EDIT_LIMITS.fileBytes,
        })),
      ),
    /512 MiB/,
  );
  assert.throws(
    () => mediaKind({ name: "house.svg", type: "image/svg+xml" }),
    /use JPG/,
  );
  assert.throws(
    () => mediaKind({ name: "photo.jpg", type: "text/html" }),
    /use JPG/,
  );
  assert.equal(mediaKind({ name: "photo.JPG", type: "" }), "image");
  assert.equal(mediaKind({ name: "video.mp4", type: "" }), "video");
});

test("file reselection uses the complete content hash, not name, size, or date", () => {
  const expected = photo().source;
  assert.doesNotThrow(() =>
    assertSourceMatch(expected, {
      ...expected,
      name: "Renamed.jpg",
      lastModified: 500,
    }),
  );
  assert.throws(
    () => assertSourceMatch(expected, { ...expected, sha256: "c".repeat(64) }),
    /different file/,
  );
  assert.throws(
    () => assertSourceMatch(expected, { ...expected, width: 1300 }),
    /different file/,
  );
  assert.throws(
    () => assertSourceMatch(expected, { ...expected, size: expected.size + 1 }),
    /different file/,
  );
});

test("cancellation fences both stale revisions and replacement edit identity", () => {
  const controller = new AbortController();
  const initial = draft();
  assert.doesNotThrow(() =>
    assertCurrentRevision(initial, initial, controller.signal),
  );
  assert.throws(
    () =>
      assertCurrentRevision(
        initial,
        { ...initial, revision: 1 },
        controller.signal,
      ),
    { name: "AbortError" },
  );
  assert.throws(
    () =>
      assertCurrentRevision(
        initial,
        { ...initial, id: "another-edit" },
        controller.signal,
      ),
    { name: "AbortError" },
  );
  controller.abort();
  assert.throws(
    () => assertCurrentRevision(initial, initial, controller.signal),
    { name: "AbortError" },
  );
});

test("time readout is deterministic and does not expose negative or NaN values", () => {
  assert.equal(formatTime(0), "0:00.0");
  assert.equal(formatTime(65.2), "1:05.2");
  assert.equal(formatTime(59.99), "1:00.0");
  assert.equal(formatTime(-1), "0:00.0");
  assert.equal(formatTime(NaN), "0:00.0");
});
