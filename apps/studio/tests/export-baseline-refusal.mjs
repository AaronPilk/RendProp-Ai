import assert from "node:assert/strict";

export const originalAudioStall = "Original audio playback stalled during export. No download was created. Try a shorter clip or export with audio explicitly muted.";
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
