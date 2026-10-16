import assert from "node:assert/strict";
import { test } from "node:test";
import { AudioStartupClock, RecordingClock, MAX_RECORDING_DRIFT_SECONDS } from "../src/editor/recording-clock";

test("audio startup does not admit the retained running-but-frozen readings", () => {
  const clock = new AudioStartupClock();
  for (const wall of [0, .0012, .0093, .06, .0748, .1299, .3])
    assert.equal(clock.read(wall, .010666666666666666), false);
});
test("audio startup requires multiple advancing samples and a stable capture interval", () => {
  const clock = new AudioStartupClock();
  assert.equal(clock.read(0, 0), false);
  assert.equal(clock.read(.034, .032), false);
  assert.equal(clock.read(.068, .064), false);
  assert.equal(clock.read(.102, .096), false);
  assert.equal(clock.read(.136, .128), true);
});
test("one audio quantum then a freeze cannot restart the stable origin", () => {
  const clock = new AudioStartupClock();
  for (const [wall, audio] of [[0, 0], [.034, .032], [.068, .032], [.102, .032]])
    assert.equal(clock.read(wall, audio), false);
  assert.throws(() => clock.read(.136, .032), /timing drifted/);
});
test("initial paused clock and a released getter jump both establish one fresh stable origin", () => {
  for (const initialJump of [false, true]) {
    const clock = new AudioStartupClock(), offset = initialJump ? .2 : 0;
    for (const [wall, audio] of [[0, 0], [.034, 0], [.2, 0], [.234, .032 + offset], [.268, .064 + offset], [.302, .096 + offset]])
      assert.equal(clock.read(wall, audio), false);
    assert.equal(clock.read(.336, .128 + offset), true);
  }
});
test("audio startup does not accept a jump after the fixed stable origin", () => {
  const clock = new AudioStartupClock();
  for (const [wall, audio] of [[0, 0], [.034, .032], [.068, .24]]) clock.read(wall, audio);
  assert.throws(() => clock.read(.102, .272), /timing drifted/);
});
test("audio startup rejects invalid and backwards samples", () => {
  for (const [wall, audio] of [[NaN, 0], [0, Infinity], [-1, 0], [0, -1]])
    assert.throws(() => new AudioStartupClock().read(wall, audio), /could not be verified/);
  const clock = new AudioStartupClock(); clock.read(1, 1);
  assert.throws(() => clock.read(1.01, .99), /backwards/);
});

test("recording timing tolerates frame granularity and one delayed reading", () => {
  const clock = new RecordingClock();
  clock.read(.1, .09, .09);
  clock.read(.2, .1, .1);
  clock.read(.23, .22, .22);
  clock.read(.3, .2, .2);
  clock.read(.33, .32, .32);
  assert.equal(MAX_RECORDING_DRIFT_SECONDS, 2 / 30);
});
test("audio and media advancing together cannot hide capture-wall drift", () => {
  const clock = new RecordingClock();
  clock.read(.4, .3, .3);
  assert.throws(() => clock.read(.44, .33, .33), error => {
    assert(error instanceof Error);
    const cause = error.cause as { maxLossSeconds: number; readings: unknown[] };
    assert(cause.maxLossSeconds > .1);
    assert.equal(cause.readings.length, 2);
    return true;
  });
});
test("muted source with narration rejects a media clock drifting behind sound", () => {
  const clock = new RecordingClock();
  clock.read(.4, .3, .4);
  assert.throws(() => clock.read(.45, .32, .45), /timing drifted/);
});
test("photo with narration rejects an interrupted audio clock", () => {
  const clock = new RecordingClock();
  clock.read(.4, .4, .3);
  assert.throws(() => clock.read(.45, .45, .3), /timing drifted/);
});
test("muted photo needs no audio clock", () => {
  const clock = new RecordingClock();
  for (let frame = 1; frame < 200; frame++) clock.read(frame / 30, frame / 30);
});
