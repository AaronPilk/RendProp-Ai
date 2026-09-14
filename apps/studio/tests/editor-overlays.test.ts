import test from "node:test";
import assert from "node:assert/strict";
import {
  type EditOverlay,
  locateOverlay,
  overlaySources,
  validateOverlays,
} from "../src/editor/overlays";
const source = {
  name: "Kitchen.jpg",
  size: 1000,
  lastModified: 1,
  sha256: "a".repeat(64),
  kind: "image" as const,
  width: 1200,
  height: 800,
  duration: 0,
};
const overlay = (id = "first", start = 4, end = 7): EditOverlay => ({
  id,
  source: { ...source },
  start,
  end,
  caption: "Kitchen",
  focusX: .5,
  focusY: .5,
  motion: "push_in",
});
test("cutaway gaps and interval boundaries reveal the continuously playing base video", () => {
  const overlays = validateOverlays([overlay(), overlay("second", 9, 12)], 20);
  for (const time of [0, 3.99, 7, 8, 12, 19, NaN]) {
    assert.equal(locateOverlay(overlays, time), null);
  }
  assert.equal(locateOverlay(overlays, 4)?.id, "first");
  assert.equal(locateOverlay(overlays, 6.99)?.id, "first");
  assert.equal(locateOverlay(overlays, 9)?.id, "second");
});
test("a cutaway plan rejects overlaps, reversed time and ranges beyond its actual base footage", () => {
  assert.throws(
    () => validateOverlays([overlay(), overlay("second", 6, 9)], 20),
    /overlapping/,
  );
  for (
    const item of [
      overlay("first", 4, 4.4),
      overlay("first", -1, 2),
      overlay("first", 19, 21),
      overlay("first", 5, 4),
    ]
  ) assert.throws(() => validateOverlays([item], 20));
  assert.throws(() => validateOverlays([overlay("first", 180, 181)], 181));
  assert.throws(
    () => validateOverlays([overlay(), overlay("second", 0, 2)], 20),
    /time order/,
  );
});
test("only bounded complete still-photo references survive import and URLs are discarded", () => {
  const raw = {
    ...overlay(),
    source: {
      ...source,
      url: "https://private.invalid/image.jpg",
      storage_key: "private-key",
    },
    unsafe: "discard",
  };
  const [clean] = validateOverlays([raw], 20);
  assert.deepEqual(clean, overlay());
  assert.ok(!JSON.stringify(clean).includes("private"));
  for (
    const invalid of [
      { kind: "video" },
      { size: 128 * 1024 ** 2 + 1 },
      { width: 12000, height: 12000 },
      { sha256: "short" },
      { duration: 2 },
    ]
  ) {
    assert.throws(() =>
      validateOverlays([{ ...raw, source: { ...source, ...invalid } }], 20)
    );
  }
});
test("saved cutaways have distinct IDs, bounded captions and supported photo motions", () => {
  assert.throws(
    () => validateOverlays([overlay(), overlay("first", 8, 10)], 20),
    /unique/,
  );
  assert.throws(
    () => validateOverlays([{ ...overlay(), caption: "x".repeat(121) }], 20),
    /caption/,
  );
  assert.throws(
    () => validateOverlays([{ ...overlay(), motion: "generate_drone" }], 20),
    /framing motion/,
  );
  assert.throws(
    () =>
      validateOverlays(
        Array.from({ length: 13 }, (_, i) => overlay(String(i), i, i + .5)),
        20,
      ),
    /12 photo/,
  );
});
test("repeated cutaway images share one recoverable source while returned references remain detached", () => {
  const overlays = validateOverlays([overlay(), overlay("second", 9, 12)], 20),
    refs = overlaySources(overlays);
  assert.equal(refs.length, 1);
  refs[0].name = "Changed";
  assert.equal(overlays[0].source.name, "Kitchen.jpg");
  assert.throws(
    () =>
      validateOverlays([overlay(), {
        ...overlay("second", 9, 12),
        source: { ...source, width: 1000 },
      }], 20),
    /inconsistent/,
  );
});
