// Capture timestamps use wall time. Media and Web Audio can advance at a
// different rate under decoder starvation or an audio-device interruption.
// Never offer a recording after two successive readings exceed two frames.
export const MAX_RECORDING_DRIFT_SECONDS = 2 / 30;
export type RecordingClockReading = { wall: number; timeline: number; audio?: number; drift: number };
// Readiness is established before recording or any user audio starts. A running
// AudioContext can still have a stationary clock; never use state alone as proof.
export class AudioStartupClock {
  private previous?: { wall: number; audio: number };
  private origin?: { wall: number; audio: number };
  private advances = 0;
  private stableClock = new RecordingClock();
  readonly readings: Array<{ wall: number; audio: number }> = [];
  read(wall: number, audio: number): boolean {
    if (!Number.isFinite(wall) || !Number.isFinite(audio) || wall < 0 || audio < 0)
      throw new Error("The audio startup clock could not be verified.");
    const current = { wall, audio };
    this.readings.push(current);
    if (this.readings.length > 8) this.readings.shift();
    const previous = this.previous;
    this.previous = current;
    if (!previous) return false;
    if (wall <= previous.wall || audio < previous.audio)
      throw new Error("The audio startup clock moved backwards.");
    if (!this.origin) {
      if (audio === previous.audio) return false;
      // The initial stationary interval precedes content. Fix this origin once
      // at the first genuine advance; a later stall must never restart it.
      this.origin = current;
      this.advances = 1;
      return false;
    }
    const wallElapsed = wall - this.origin.wall, audioElapsed = audio - this.origin.audio;
    this.stableClock.read(wallElapsed, audioElapsed, audioElapsed);
    if (audio > previous.audio) this.advances++;
    return this.advances >= 3 && wallElapsed >= MAX_RECORDING_DRIFT_SECONDS &&
      audioElapsed >= MAX_RECORDING_DRIFT_SECONDS;
  }
}
export class RecordingClock {
  private consecutive = 0;
  private maximum = 0;
  private readings: RecordingClockReading[] = [];
  read(wall: number, timeline: number, audio?: number): void {
    const drift = Math.max(Math.abs(wall - timeline), audio === undefined ? 0 : Math.abs(wall - audio));
    this.maximum = Math.max(this.maximum, drift);
    this.readings.push({ wall, timeline, audio, drift });
    if (this.readings.length > 8) this.readings.shift();
    this.consecutive = drift > MAX_RECORDING_DRIFT_SECONDS ? this.consecutive + 1 : 0;
    if (this.consecutive >= 2) throw new Error(
      "Audio and picture timing drifted during export. No download was created. Close other busy tabs and retry.",
      { cause: { maxLossSeconds: this.maximum, readings: [...this.readings] } },
    );
  }
}
