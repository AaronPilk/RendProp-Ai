import assert from "node:assert/strict";

export const originalAudioStall = "Original audio playback stalled during export. No download was created. Try a shorter clip or export with audio explicitly muted.";
export const encodedCadenceStall = "Encoded video frames were skipped. No download was created. Close other busy tabs and retry.";
export const captureCadenceStall = "Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.";
export function assertDeadlineOnlyCadence(attempt) {
  assert.equal(attempt.variant, "cadence-baseline");
  assert.equal(attempt.errorName, "Error");
  assert.equal(attempt.error, captureCadenceStall);
  assert.equal(attempt.result, null);
  assert.equal(attempt.downloadHidden, true);
  assert.equal(attempt.tracks.length, 2);
  assert(attempt.tracks.every(state => state === "ended"));
  assert.equal(attempt.errorCause?.maxGapMilliseconds, 150);
  assert(attempt.errorCause.gapMilliseconds >= 400,
    "The deadline-only control must measure the held 500 ms photo-frame gap");
  const clock = attempt.trace.find(event => event.event === "clip.clock.start" && event.index === 0);
  const read = attempt.trace.find(event => event.event === "clip.clock.read" && event.index === 0);
  assert(read?.at - clock?.at >= 400,
    "The actual first export-frame wait must overrun the capture deadline");
  const held = attempt.trace.filter(event => event.event === "export.frame.held" && event.index === 0);
  const cancelled = attempt.trace.filter(event => event.event === "export.frame.cancelled" && event.index === 0);
  assert.equal(held.length, 1);
  assert.equal(cancelled.length, 1);
  assert.equal(cancelled[0].id, held[0].id);
  assert.equal(attempt.trace.filter(event => event.event === "export.frame.delivered").length, 0);
  assert.equal(attempt.trace.filter(event => event.event === "stop.native").length, 1);
}
export function assertClockBaselineCadence(attempt) {
  assert.equal(attempt.variant, "clock-baseline");
  assert.equal(attempt.errorName, "Error");
  assert.equal(attempt.error, encodedCadenceStall);
  assert.equal(attempt.result, null);
  assert.equal(attempt.downloadHidden, true);
  assert.equal(attempt.tracks.length, 2);
  assert(attempt.tracks.every(state => state === "ended"));
  const clocks = attempt.trace.filter(event => event.event === "clip.clock.start");
  const firstPhotoRead = attempt.trace.find(event => event.event === "clip.clock.read" && event.index === 0);
  const firstPause = attempt.trace.find(event => event.event === "pause.call");
  assert.deepEqual(clocks.map(event => event.index), [0, 1, 2]);
  assert(firstPhotoRead?.at - clocks[0].at >= 100,
    "The historical photo clock must receive an actually delayed animation callback");
  assert(firstPause?.at - clocks[0].at > 600,
    "The animation-only clock must overrun its 500 ms opening photo segment");
  assert.equal(attempt.trace.filter(event => event.event === "resume.return").length, 2);
  assert.equal(attempt.trace.filter(event => event.event === "pause.call").length, 3);
  assert.equal(attempt.trace.find(event => event.event === "play.call")?.rate, 1);
  assert.equal(attempt.trace.filter(event => event.event === "stop.native").length, 1);
}
export function assertBaselineCadence(attempt, resumeNotificationDelayMs) {
  assert.equal(attempt.variant, "baseline");
  assert.equal(attempt.errorName, "Error");
  assert.equal(attempt.error, encodedCadenceStall);
  assert.equal(attempt.result, null);
  assert.equal(attempt.downloadHidden, true);
  assert.equal(attempt.tracks.length, 2);
  assert(attempt.tracks.every(state => state === "ended"));
  const resumed = attempt.trace.filter(event => event.event === "resume.return");
  const delivered = attempt.trace.filter(event => event.event === "resume.delivered");
  assert(resumed.length > 0 && delivered.length > 0 && delivered.length <= resumed.length);
  assert(delivered.every((event, index) => resumed[index].state === "recording" &&
    event.at - resumed[index].at >= resumeNotificationDelayMs - 1));
  assert(attempt.trace.find(event => event.event === "play.call")?.at >= delivered[0].at,
    "The old resume await must precede original playback");
}
export function assertBaselineStall(attempt, resumeNotificationDelayMs) {
  assert.equal(attempt.variant, "baseline");
  assert.equal(attempt.errorName, "Error");
  assert.equal(attempt.error, originalAudioStall);
  assert.equal(attempt.result, null);
  assert.equal(attempt.downloadHidden, true);
  assert.equal(attempt.tracks.length, 2);
  assert(attempt.tracks.every(state => state === "ended"));
  const refusals = attempt.trace.filter(event => event.event === "original.audio.refusal");
  assert.equal(refusals.length, 1);
  assert.equal(refusals[0].kind, "original_audio_stall");
  const readings = attempt.trace.filter(event => event.event === "original.audio.loss" && event.at <= refusals[0].at).slice(-2);
  assert.equal(readings.length, 2);
  assert.equal(readings[0].index, readings[1].index);
  assert(readings[1].at > readings[0].at && readings[1].audio > readings[0].audio,
    "Refusal classification needs two distinct audio-clock readings");
  for (const reading of readings) {
    assert.equal(reading.limit, 2 / 30);
    assert(reading.elapsed < reading.duration && !reading.ended);
    assert([reading.audio, reading.audioStart, reading.media, reading.mediaStart, reading.rate, reading.loss].every(Number.isFinite));
    assert(reading.rate > 0);
    assert.equal(reading.loss, reading.audio - reading.audioStart - Math.max(0, reading.media - reading.mediaStart) / reading.rate);
    assert(reading.loss > 2 / 30, "Each actual guard reading must prove lost original-audio time");
  }
  const resumed = attempt.trace.filter(event => event.event === "resume.return");
  const delivered = attempt.trace.filter(event => event.event === "resume.delivered");
  assert(delivered.length > 0 && delivered.length <= 2);
  assert(delivered.every((event, index) => resumed[index] && event.at - resumed[index].at >= resumeNotificationDelayMs - 1));
  assert(attempt.trace.find(event => event.event === "play.call").at >= delivered[0].at,
    "The restored old await must actually precede original playback");
}
