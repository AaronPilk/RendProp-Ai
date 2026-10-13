// Capture timestamps use wall time. Media and Web Audio can advance at a
// different rate under decoder starvation or an audio-device interruption.
// Never offer a recording after two successive readings exceed two frames.
export const MAX_RECORDING_DRIFT_SECONDS = 2 / 30;
export type RecordingClockReading = { wall: number; timeline: number; audio?: number; drift: number };
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
