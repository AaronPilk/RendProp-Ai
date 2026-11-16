import assert from "node:assert/strict";
import { test } from "node:test";
import { AudioStartupClock, CaptureCadenceClock, RecordingClock, CAPTURE_DENSITY_WINDOW_MILLISECONDS, MAX_CAPTURE_GAP_MILLISECONDS, MAX_RECORDING_DRIFT_SECONDS, MAX_TRANSITION_CAPTURE_GAP_MILLISECONDS, MIN_CAPTURE_FRAMES_PER_WINDOW, MIN_TRANSITION_CAPTURE_FPS } from "../src/editor/recording-clock";

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

test("capture cadence refuses a missing dissolve even when media and audio clocks agree", () => {
  const clock = new CaptureCadenceClock(), recording = new RecordingClock();
  clock.capture(8_748.3); // First request after resuming the recorder.
  recording.read(.03, .03, .03);
  recording.read(.28, .28, .28); // Clock drift alone cannot detect lost pictures.
  assert.throws(() => clock.capture(8_999.3), error => {
    assert(error instanceof Error);
    assert.match(error.message, /Video frames were skipped.*No download was created/);
    assert.deepEqual(error.cause, {gapMilliseconds: 251, maxGapMilliseconds: MAX_CAPTURE_GAP_MILLISECONDS});
    return true;
  });
});
test("capture cadence tolerates ordinary startup and frame jitter without an audio clock", () => {
  const clock = new CaptureCadenceClock();
  clock.capture(10_000); // Slow decode and audio readiness happened before capture.
  for (const at of [10_033, 10_066, 10_112, 10_190, 10_339]) clock.capture(at);
  assert.equal(MAX_CAPTURE_GAP_MILLISECONDS, 150);
  const nextClip = new CaptureCadenceClock(); // Paused preparation is excluded.
  nextClip.capture(14_000);
  nextClip.capture(14_034);
});
test("capture cadence refuses repeated sub-threshold delays that make a 14 fps video", () => {
  const clock = new CaptureCadenceClock();
  assert.equal(CAPTURE_DENSITY_WINDOW_MILLISECONDS, 500);
  assert.equal(MIN_CAPTURE_FRAMES_PER_WINDOW, 11);
  for (let at = 0; at < 500; at += 72) clock.capture(at);
  assert.throws(() => clock.capture(504), error => {
    assert(error instanceof Error);
    assert.match(error.message, /Video frames were skipped.*No download was created/);
    assert.deepEqual(error.cause, {windowMilliseconds: 500, framesCaptured: 7, minFrames: 11});
    return true;
  });
  const healthy = new CaptureCadenceClock();
  for (let at = 0; at <= 1000; at += 33) healthy.capture(at);
});
test("short dissolve requires distinct painted frames, not merely a final endpoint", () => {
  assert.equal(MAX_TRANSITION_CAPTURE_GAP_MILLISECONDS, 130);
  assert.equal(MIN_TRANSITION_CAPTURE_FPS, 20);
  const missed = new CaptureCadenceClock(280);
  for (const at of [0, 75, 150, 225]) missed.capture(at, at);
  assert.throws(() => missed.capture(300, 300), error => {
    assert(error instanceof Error);
    assert.match(error.message, /Video frames were skipped.*No download was created/);
    assert.deepEqual(error.cause, {transitionMilliseconds: 280, framesCaptured: 4, minFrames: 6});
    return true;
  });
  const healthy = new CaptureCadenceClock(280);
  for (let at = 0; at <= 330; at += 33) healthy.capture(at, at);
});
test("a 140 ms gap inside a dissolve is refused before the transition ends", () => {
  const clock = new CaptureCadenceClock(280);
  clock.capture(1000, 0);
  clock.capture(1033, 33);
  assert.throws(() => clock.capture(1173, 173), error => {
    assert(error instanceof Error);
    assert.deepEqual(error.cause, {gapMilliseconds: 140, maxTransitionGapMilliseconds: 130});
    return true;
  });
  assert.throws(() => new CaptureCadenceClock(280).capture(0), /transition clock could not be verified/);
});
test("capture cadence rejects invalid and reversed timestamps", () => {
  for (const at of [NaN, Infinity, -1])
    assert.throws(() => new CaptureCadenceClock().capture(at), /could not be verified/);
  const clock = new CaptureCadenceClock();
  clock.capture(100);
  assert.throws(() => clock.capture(99), /moved backwards/);
});
