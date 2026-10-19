import assert from "node:assert/strict";
import test from "node:test";
import { assertBaselineStall, originalAudioStall } from "./export-baseline-refusal.mjs";

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
