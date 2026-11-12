import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {canContinueSilentCut, ContinuousSilentCutRun} from "../src/editor/export-continuity";
import {CaptureCadenceClock, RecordingClock} from "../src/editor/recording-clock";
import type {EditClip, Transition} from "../src/editor/model";

function photo(transition: Transition = "cut"): EditClip {
  return {id: "photo", source: {name: "Synthetic photo", size: 1, lastModified: 0,
    sha256: "a".repeat(64), kind: "image", width: 800, height: 450, duration: 0},
  start: 0, end: .517, caption: "", focusX: .5, focusY: .5, transition};
}
function video(): EditClip {
  const clip = photo();
  return {...clip, source: {...clip.source, kind: "video", duration: 4}};
}

test("continuation requires MP4, no selected audio, two prepared photos and an incoming cut", () => {
  const outgoing = photo(), incoming = photo();
  assert.equal(canContinueSilentCut("mp4", false, outgoing, incoming, true), true);
  const refusals: Parameters<typeof canContinueSilentCut>[] = [
    ["webm", false, outgoing, incoming, true],
    ["mp4", true, outgoing, incoming, true],
    ["mp4", false, video(), incoming, true],
    ["mp4", false, outgoing, video(), true],
    ["mp4", false, outgoing, photo("dissolve"), true],
    ["mp4", false, outgoing, photo("whip"), true],
    ["mp4", false, outgoing, incoming, false],
    ["mp4", false, outgoing, undefined, true],
  ];
  for (const values of refusals) assert.equal(canContinueSilentCut(...values), false);
});

test("one continuation is consumed once and a lost recording state refuses", () => {
  const run = new ContinuousSilentCutRun();
  assert.equal(run.offer(true, "recording"), true);
  assert.throws(() => run.offer(true, "recording"), /unconsumed/);
  assert.throws(() => run.take("paused"), /lost its recorder/);
  assert.equal(run.take("recording"), true);
  assert.equal(run.take("paused"), false);
  assert.equal(run.offer(false, "recording"), false);
  assert.throws(() => run.offer(true, "inactive"), /not recording/);
  assert.throws(() => run.didPause("recording"), /actual paused/);
});

test("the real 150ms capture gap limit spans an unpaused photo boundary", () => {
  const run = new ContinuousSilentCutRun();
  run.capture(0); run.capture(33);
  run.offer(true, "recording"); run.take("recording");
  assert.throws(() => run.capture(184), error => {
    assert(error instanceof Error);
    assert.deepEqual(error.cause, {gapMilliseconds: 151, maxGapMilliseconds: 150});
    return true;
  });
  // A new per-clip guard alone cannot see this cross-boundary loss.
  assert.doesNotThrow(() => new CaptureCadenceClock(0).capture(184));
});

test("the real 11-in-500ms density limit spans individually short photo clips", () => {
  const run = new ContinuousSilentCutRun();
  const first = new CaptureCadenceClock(0), second = new CaptureCadenceClock(0);
  for (const at of [0, 55, 110, 165, 220]) {first.capture(at); run.capture(at);}
  run.offer(true, "recording"); run.take("recording");
  for (const at of [275, 330, 385, 440]) {second.capture(at); run.capture(at);}
  second.capture(500);
  assert.throws(() => run.capture(500), error => {
    assert(error instanceof Error);
    assert.deepEqual(error.cause, {windowMilliseconds: 500, framesCaptured: 10, minFrames: 11});
    return true;
  });
});

test("fixed run origin catches cumulative drift while each local clip clock agrees", () => {
  const run = new ContinuousSilentCutRun();
  run.beginSegment(1000, 3); run.read(1010, 3.01);
  run.offer(true, "recording"); run.take("recording");
  run.beginSegment(1580, 3.5);
  run.read(1590, 3.51);
  const local = new RecordingClock(); local.read(.01, .01); local.read(.02, .02);
  assert.throws(() => run.read(1600, 3.52), error => {
    assert(error instanceof Error);
    assert.match(error.message, /timing drifted/);
    const cause = error.cause as {maxLossSeconds: number; readings: {wall: number; timeline: number}[]};
    assert(cause.maxLossSeconds > 2 / 30);
    assert.equal(cause.readings.at(-1)!.wall, .6);
    assert(Math.abs(cause.readings.at(-1)!.timeline - .52) < 1e-10);
    return true;
  });
});

test("healthy fixed-origin continuation passes; only an acknowledged pause resets history", () => {
  const run = new ContinuousSilentCutRun();
  run.beginSegment(1000, 0); run.read(1010, .01);
  run.offer(true, "recording"); run.take("recording");
  run.beginSegment(1517.8, .517); run.read(1527.8, .527); run.read(1537.8, .537);
  run.capture(1000); run.capture(1033);
  assert.throws(() => run.didPause("recording"), /actual paused/);
  assert.throws(() => run.capture(2000), /frames were skipped/);
  run.didPause("paused");
  assert.doesNotThrow(() => run.capture(3000));
  assert.throws(() => run.read(3010, .01), /could not be verified/);
  run.beginSegment(3000, 1.2);
  assert.doesNotThrow(() => run.read(3010, 1.21));
});

test("a third photo retains request history and the original run clock", () => {
  const cadence = new ContinuousSilentCutRun();
  for (const at of [0, 50, 100]) cadence.capture(at);
  cadence.offer(true, "recording"); cadence.take("recording"); cadence.capture(150);
  cadence.offer(true, "recording"); cadence.take("recording");
  assert.throws(() => cadence.capture(301), error => {
    assert(error instanceof Error);
    assert.deepEqual(error.cause, {gapMilliseconds: 151, maxGapMilliseconds: 150});
    return true;
  });
  const clock = new ContinuousSilentCutRun();
  clock.beginSegment(1000, 0); clock.read(1200, .2);
  clock.offer(true, "recording"); clock.take("recording");
  clock.beginSegment(1240, .2); clock.read(1250, .21);
  clock.offer(true, "recording"); clock.take("recording");
  clock.beginSegment(1480, .4); clock.read(1490, .41);
  assert.throws(() => clock.read(1500, .42), /timing drifted/);
});

// Execute the actual shipping handoff and resume statements with the actual
// imported owner. Native state/event objects are doubled; the policy is not.
function nativeBranches() {
  const source = readFileSync(new URL("../src/editor/export.ts", import.meta.url), "utf8");
  const from = source.indexOf("      const successorReady =");
  const until = source.indexOf("      video?.pause();", from);
  assert(from > 0 && until > from, "Actual exporter handoff block must exist once");
  const block = source.slice(from, until);
  const resume = source.match(/        if \(!continuousSilentCuts.take\(recorder.state\)\) recorder.resume\(\);/g);
  assert.equal(resume?.length, 1);
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const handoff = new AsyncFunction("canContinueSilentCut", "lookahead", "format", "withAudio", "clip", "next",
    "recorder", "waitForEvent", "renderSignal", "continuousSilentCuts", block);
  return {
    handoff: (...args: unknown[]) => handoff(canContinueSilentCut, ...args),
    resume: new Function("continuousSilentCuts", "recorder", resume![0]),
  };
}

test("actual exporter native branches continue only an owned prepared cut and otherwise pause/resume", async () => {
  const branches = nativeBranches();
  const ready = {result: {media: {}}};
  const cases = [
    {format: "mp4", audio: false, out: photo(), next: photo(), look: ready, continues: true},
    {format: "webm", audio: false, out: photo(), next: photo(), look: ready},
    {format: "mp4", audio: true, out: photo(), next: photo(), look: ready},
    {format: "mp4", audio: false, out: video(), next: photo(), look: ready},
    {format: "mp4", audio: false, out: photo(), next: video(), look: ready},
    {format: "mp4", audio: false, out: photo(), next: photo("dissolve"), look: ready},
    {format: "mp4", audio: false, out: photo(), next: photo(), look: undefined},
    {format: "mp4", audio: false, out: photo(), next: photo(), look: {result: {error: new Error("decoder")}}},
  ];
  for (const value of cases) {
    const run = new ContinuousSilentCutRun(), calls: string[] = [];
    const recorder = {state: "recording" as RecordingState,
      pause() {calls.push("pause"); this.state = "paused";},
      resume() {calls.push("resume"); this.state = "recording";}};
    await branches.handoff(value.look, {extension: value.format}, value.audio,
      value.out, value.next, recorder, () => {calls.push("wait.pause"); return Promise.resolve();},
      new AbortController().signal, run);
    branches.resume(run, recorder);
    assert.deepEqual(calls, value.continues ? [] : ["wait.pause", "pause", "resume"]);
    assert.equal(run.take("recording"), false);
  }
});

test("actual native pause rejection is preserved and cannot clear active history", async () => {
  const run = new ContinuousSilentCutRun(), rejection = new Error("native pause failed");
  run.capture(0);
  await assert.rejects(nativeBranches().handoff(undefined, {extension: "mp4"}, false,
    photo(), photo(), {state: "recording", pause() {this.state = "paused";}},
    () => Promise.reject(rejection), new AbortController().signal, run), error => error === rejection);
  assert.throws(() => run.capture(151), error => {
    assert(error instanceof Error);
    assert.deepEqual(error.cause, {gapMilliseconds: 151, maxGapMilliseconds: 150});
    return true;
  });
});

test("actual handoff waits for a pause acknowledgement before discarding active history", async () => {
  const run = new ContinuousSilentCutRun(); run.capture(0);
  let acknowledge!: () => void;
  const paused = new Promise<void>(resolve => {acknowledge = resolve;});
  const recorder = {state: "recording", pause() {this.state = "paused";}};
  const handoff = nativeBranches().handoff(undefined, {extension: "mp4"}, false,
    photo(), photo(), recorder, () => paused, new AbortController().signal, run);
  assert.equal(recorder.state, "paused");
  assert.throws(() => run.capture(151), /frames were skipped/);
  acknowledge(); await handoff;
  assert.doesNotThrow(() => run.capture(1000));
});
