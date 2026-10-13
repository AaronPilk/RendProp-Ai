import assert from "node:assert/strict";
import { test } from "node:test";
import { RecordingClock, MAX_RECORDING_DRIFT_SECONDS } from "../src/editor/recording-clock";

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
