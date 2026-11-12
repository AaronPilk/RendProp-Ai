import assert from "node:assert/strict";
import test from "node:test";
import {disjointMusicCurve} from "../src/editor/export-audio-schedule";

test("fractional PCM windows keep separate Web Audio curves disjoint", () => {
  const counts = [572865, 473630, 24000];
  let startFrame = 0;
  let lastEnd = -Infinity;
  for (const count of counts) {
    const curve = disjointMusicCurve(startFrame, count);
    // Chrome rejects a new curve when its start is below the prior curve end.
    assert(curve.startSeconds >= lastEnd);
    assert(curve.durationSeconds > 0);
    assert(curve.startSeconds + curve.durationSeconds <=
      (startFrame + count) / 48_000);
    lastEnd = curve.startSeconds + curve.durationSeconds;
    startFrame += count;
  }
  assert(572865 / 48_000 + 473630 / 48_000 > 1046495 / 48_000,
    "The reported case must expose the original floating-point overlap");
});

test("up to twelve valid windows never overlap at their canonical frame boundaries", () => {
  const counts = [24000, 24113, 572865, 473630, 32784, 96000,
    25117, 48001, 119999, 80321, 34567, 182442];
  let startFrame = 0;
  let lastEnd = -Infinity;
  for (const count of counts) {
    const {startSeconds, durationSeconds} = disjointMusicCurve(startFrame, count);
    assert(startSeconds >= lastEnd);
    lastEnd = startSeconds + durationSeconds;
    startFrame += count;
  }
  assert.throws(() => disjointMusicCurve(0, 0));
  assert.throws(() => disjointMusicCurve(180 * 48_000, 1));
});
