import assert from "node:assert/strict";
import test from "node:test";
import { assertBaselineCadence, assertBaselineStall, assertClockBaselineCadence, assertDeadlineOnlyCadence, captureCadenceStall, encodedCadenceStall, originalAudioStall } from "./export-baseline-refusal.mjs";

function closedTrace() {
  const readings = [
    { event: "original.audio.loss", at: 2000, index: 1, elapsed: .1, duration: 2, ended: false, limit: 2 / 30, audio: 1.2, audioStart: 1, media: .2, mediaStart: .1, rate: 2, loss: 0 },
    { event: "original.audio.loss", at: 2006, index: 1, elapsed: .11, duration: 2, ended: false, limit: 2 / 30, audio: 1.22, audioStart: 1, media: .22, mediaStart: .1, rate: 2, loss: 0 },
  ];
  for (const reading of readings) reading.loss = reading.audio - reading.audioStart - Math.max(0, reading.media - reading.mediaStart) / reading.rate;
  return {
    variant: "baseline", errorName: "Error", error: originalAudioStall, result: null,
    downloadHidden: true, tracks: ["ended", "ended"],
    trace: [
      { event: "resume.return", at: 0, state: "recording" },
      { event: "resume.delivered", at: 1000 },
      { event: "play.call", at: 1001 },
      ...readings,
      { event: "original.audio.refusal", at: 2007, kind: "original_audio_stall" },
    ],
  };
}

type Attempt = ReturnType<typeof closedTrace>;
const losses = (attempt: Attempt) => attempt.trace.filter(event => event.event === "original.audio.loss");
const event = (attempt: Attempt, name: string) => attempt.trace.find(value => value.event === name)!;

test("historical negative control accepts only its closed, measured audio-loss refusal", () => {
  assert.doesNotThrow(() => assertBaselineStall(closedTrace(), 1000));
});

const controls: Array<[string, (attempt: Attempt) => void]> = [
  ["current fixed exporter", a => { a.variant = "fixed"; }],
  ["current late-frame exporter", a => { a.variant = "late-frames"; }],
  ["different error", a => { a.error = "Audio and picture timing drifted during export"; }],
  ["different error type", a => { a.errorName = "AbortError"; }],
  ["wrong refusal marker", a => { event(a, "original.audio.refusal").kind = "other"; }],
  ["missing refusal marker", a => { a.trace = a.trace.filter(v => v.event !== "original.audio.refusal"); }],
  ["duplicate refusal marker", a => { a.trace.push({ ...event(a, "original.audio.refusal") }); }],
  ["missing loss readings", a => { a.trace = a.trace.filter(v => v.event !== "original.audio.loss"); }],
  ["only one loss reading", a => { a.trace.splice(a.trace.indexOf(losses(a)[0]), 1); }],
  ["duplicate reading", a => { Object.assign(losses(a)[1], losses(a)[0]); }],
  ["nonadvancing audio quantum", a => { losses(a)[1].audio = losses(a)[0].audio; }],
  ["nonadvancing sample time", a => { losses(a)[1].at = losses(a)[0].at; }],
  ["different clip", a => { losses(a)[1].index = 2; }],
  ["under threshold", a => { const r = losses(a)[1]; r.audio = 1.06; r.media = .1; r.loss = r.audio - r.audioStart; }],
  ["only one excessive reading", a => { const r = losses(a)[0]; r.audio = 1.02; r.media = .1; r.loss = r.audio - r.audioStart; }],
  ["inconsistent numeric loss", a => { losses(a)[1].loss += .01; }],
  ["nonfinite numeric reading", a => { losses(a)[1].audio = NaN; }],
  ["wrong threshold", a => { losses(a)[1].limit = .4; }],
  ["ended media", a => { losses(a)[1].ended = true; }],
  ["completed clip", a => { losses(a)[1].elapsed = losses(a)[1].duration; }],
  ["zero playback rate", a => { losses(a)[1].rate = 0; }],
  ["live recording track", a => { a.tracks[1] = "live"; }],
  ["missing recording tracks", a => { a.tracks = []; }],
  ["visible download", a => { a.downloadHidden = false; }],
  ["offered output", a => { (a as any).result = { bytes: 1 }; }],
  ["missing old resume", a => { a.trace = a.trace.filter(v => v.event !== "resume.return"); }],
  ["missing delayed delivery", a => { a.trace = a.trace.filter(v => v.event !== "resume.delivered"); }],
  ["undelayed resume notification", a => { event(a, "resume.delivered").at = 500; }],
  ["playback before delayed resume", a => { event(a, "play.call").at = 999; }],
];
for (const [name, mutate] of controls) test(`refusal oracle rejects ${name}`, () => {
  const attempt = closedTrace();
  mutate(attempt);
  assert.throws(() => assertBaselineStall(attempt, 1000));
});

function cadenceTrace() {
  const attempt = closedTrace();
  attempt.error = encodedCadenceStall;
  attempt.trace = attempt.trace.filter(value => value.event !== "original.audio.loss" && value.event !== "original.audio.refusal");
  return attempt;
}

test("historical negative control accepts an encoded cadence refusal after its delayed resume", () => {
  assert.doesNotThrow(() => assertBaselineCadence(cadenceTrace(), 1000));
});
for (const [name, mutate] of [
  ["current exporter", (a: Attempt) => { a.variant = "fixed"; }],
  ["different error", (a: Attempt) => { a.error = originalAudioStall; }],
  ["missing delayed event", (a: Attempt) => { a.trace = a.trace.filter(value => value.event !== "resume.delivered"); }],
  ["undelayed event", (a: Attempt) => { event(a, "resume.delivered").at = 500; }],
  ["playback before resume", (a: Attempt) => { event(a, "play.call").at = 999; }],
  ["live track", (a: Attempt) => { a.tracks[0] = "live"; }],
  ["offered output", (a: Attempt) => { (a as any).result = { bytes: 1 }; }],
] as Array<[string, (attempt: Attempt) => void]>) test(`cadence refusal oracle rejects ${name}`, () => {
  const attempt = cadenceTrace();
  mutate(attempt);
  assert.throws(() => assertBaselineCadence(attempt, 1000));
});

function clockCadenceTrace() {
  const trace: Array<{event: string; at: number; index?: number; rate?: number}> = [
    { event: "clip.clock.start", at: 1000, index: 0 },
    { event: "clip.clock.read", at: 1125, index: 0 },
    { event: "pause.call", at: 1730 },
    { event: "resume.return", at: 1731 },
    { event: "play.call", at: 1732, rate: 1 },
    { event: "clip.clock.start", at: 1731, index: 1 },
    { event: "pause.call", at: 3730 },
    { event: "resume.return", at: 3731 },
    { event: "clip.clock.start", at: 3731, index: 2 },
    { event: "pause.call", at: 4460 },
    { event: "stop.native", at: 4462 },
  ];
  return {variant: "clock-baseline", errorName: "Error", error: encodedCadenceStall,
    result: null as null | {bytes: number}, downloadHidden: true, tracks: ["ended", "ended"], trace};
}
type ClockAttempt = ReturnType<typeof clockCadenceTrace>;
test("historical animation-only photo clock accepts only measured encoded-frame refusal", () => {
  assert.doesNotThrow(() => assertClockBaselineCadence(clockCadenceTrace()));
});
for (const [name, mutate] of [
  ["current fixed export", (a: ClockAttempt) => { a.variant = "fixed"; }],
  ["different error", (a: ClockAttempt) => { a.error = originalAudioStall; }],
  ["wrong error type", (a: ClockAttempt) => { a.errorName = "AbortError"; }],
  ["early photo callback", (a: ClockAttempt) => { a.trace[1].at = 1050; }],
  ["photo within planned duration", (a: ClockAttempt) => { a.trace[2].at = 1500; }],
  ["missing third clip", (a: ClockAttempt) => { a.trace = a.trace.filter(value => value.index !== 2); }],
  ["missing recorder resume", (a: ClockAttempt) => { a.trace = a.trace.filter(value => value.event !== "resume.return"); }],
  ["wrong playback rate", (a: ClockAttempt) => { a.trace.find(value => value.event === "play.call")!.rate = 2; }],
  ["missing recorder stop", (a: ClockAttempt) => { a.trace = a.trace.filter(value => value.event !== "stop.native"); }],
  ["live track", (a: ClockAttempt) => { a.tracks[0] = "live"; }],
  ["visible download", (a: ClockAttempt) => { a.downloadHidden = false; }],
  ["offered output", (a: ClockAttempt) => { a.result = {bytes: 100}; }],
] as Array<[string, (attempt: ClockAttempt) => void]>) test(`animation-clock refusal oracle rejects ${name}`, () => {
  const attempt = clockCadenceTrace();
  mutate(attempt);
  assert.throws(() => assertClockBaselineCadence(attempt));
});

function deadlineCadenceTrace() {
  const trace: Array<{event: string; at: number; index?: number; id?: number}> = [
    {event: "clip.clock.start", at: 1000, index: 0},
    {event: "export.frame.held", at: 1001, index: 0, id: 12},
    {event: "export.frame.cancelled", at: 1500, index: 0, id: 12},
    {event: "clip.clock.read", at: 1500, index: 0},
    {event: "stop.native", at: 1502},
  ];
  return {variant: "cadence-baseline", errorName: "Error", error: captureCadenceStall,
    errorCause: {gapMilliseconds: 500, maxGapMilliseconds: 150},
    result: null as null | {bytes: number}, downloadHidden: true, tracks: ["ended", "ended"], trace};
}
type DeadlineAttempt = ReturnType<typeof deadlineCadenceTrace>;
test("historical deadline-only cadence accepts only a measured held-frame refusal", () => {
  assert.doesNotThrow(() => assertDeadlineOnlyCadence(deadlineCadenceTrace()));
});
for (const [name, mutate] of [
  ["current exporter", (a: DeadlineAttempt) => { a.variant = "late-frames"; }],
  ["different error", (a: DeadlineAttempt) => { a.error = encodedCadenceStall; }],
  ["short measured gap", (a: DeadlineAttempt) => { a.errorCause.gapMilliseconds = 100; }],
  ["wrong gap limit", (a: DeadlineAttempt) => { a.errorCause.maxGapMilliseconds = 200; }],
  ["early frame read", (a: DeadlineAttempt) => { a.trace[3].at = 1100; }],
  ["missing held frame", (a: DeadlineAttempt) => { a.trace = a.trace.filter(value => value.event !== "export.frame.held"); }],
  ["uncancelled held frame", (a: DeadlineAttempt) => { a.trace[2].id = 13; }],
  ["delivered animation frame", (a: DeadlineAttempt) => { a.trace.push({event: "export.frame.delivered", at: 1200}); }],
  ["missing recorder stop", (a: DeadlineAttempt) => { a.trace = a.trace.filter(value => value.event !== "stop.native"); }],
  ["live track", (a: DeadlineAttempt) => { a.tracks[0] = "live"; }],
  ["visible download", (a: DeadlineAttempt) => { a.downloadHidden = false; }],
  ["offered output", (a: DeadlineAttempt) => { a.result = {bytes: 100}; }],
] as Array<[string, (attempt: DeadlineAttempt) => void]>) test(`deadline-only cadence refusal oracle rejects ${name}`, () => {
  const attempt = deadlineCadenceTrace();
  mutate(attempt);
  assert.throws(() => assertDeadlineOnlyCadence(attempt));
});
