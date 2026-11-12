// Capture timestamps use wall time. Media and Web Audio can advance at a
// different rate under decoder starvation or an audio-device interruption.
// Never offer a recording after two successive readings exceed two frames.
export const MAX_RECORDING_DRIFT_SECONDS = 2 / 30;
// A capture request more than four 30 fps intervals after the previous one
// leaves a visible hole even when the media and audio clocks advance together.
// The failed macOS export had a 332 ms encoded hole across a 280 ms dissolve.
export const MAX_CAPTURE_GAP_MILLISECONDS = 150;
// Repeated shorter delays can also turn a 30 fps dissolve into a visibly
// static or jerky file. The failed MP4 contained only 43 frames in 3 seconds,
// with individual callback gaps below the single-gap limit.
export const CAPTURE_DENSITY_WINDOW_MILLISECONDS = 500;
export const MIN_CAPTURE_FRAMES_PER_WINDOW = 11; // At least 20 fps, counting both endpoints.
// A single first-frame handoff in the fresh recorder can take ~119 ms even
// when the rest of the dissolve still visibly progresses. Keep it below the
// general gap limit and separately require distinct transition frames.
export const MAX_TRANSITION_CAPTURE_GAP_MILLISECONDS = 130;
export const MIN_TRANSITION_CAPTURE_FPS = 20;
export type RecordingClockReading = { wall: number; timeline: number; audio?: number; drift: number };
export class CaptureCadenceClock {
  private lastCaptureAt?: number;
  private lastLocalTime?: number;
  private firstCaptureAt?: number;
  private recentCaptures: number[] = [];
  private transitionBuckets = new Set<number>();
  private transitionChecked = false;
  constructor(private readonly transitionMilliseconds = 0) {
    if (!Number.isFinite(transitionMilliseconds) || transitionMilliseconds < 0)
      throw new Error("The export transition duration could not be verified. No download was created.");
  }
  capture(atMilliseconds: number, localMilliseconds?: number): void {
    if (!Number.isFinite(atMilliseconds) || atMilliseconds < 0)
      throw new Error("The export capture clock could not be verified. No download was created.");
    if (this.transitionMilliseconds > 0 &&
        (localMilliseconds === undefined || !Number.isFinite(localMilliseconds) || localMilliseconds < 0 ||
          (this.lastLocalTime !== undefined && localMilliseconds < this.lastLocalTime)))
      throw new Error("The export transition clock could not be verified. No download was created.");
    const previous = this.lastCaptureAt;
    if (previous !== undefined) {
      const gapMilliseconds = atMilliseconds - previous;
      if (gapMilliseconds < 0)
        throw new Error("The export capture clock moved backwards. No download was created.");
      if (gapMilliseconds > MAX_CAPTURE_GAP_MILLISECONDS)
        throw new Error("Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.",
          {cause: {gapMilliseconds, maxGapMilliseconds: MAX_CAPTURE_GAP_MILLISECONDS}});
      if (this.transitionMilliseconds > 0 && !this.transitionChecked &&
          this.lastLocalTime !== undefined && this.lastLocalTime < this.transitionMilliseconds &&
          gapMilliseconds > MAX_TRANSITION_CAPTURE_GAP_MILLISECONDS)
        throw new Error("Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.",
          {cause: {gapMilliseconds, maxTransitionGapMilliseconds: MAX_TRANSITION_CAPTURE_GAP_MILLISECONDS}});
    }
    if (this.transitionMilliseconds > 0 && !this.transitionChecked) {
      if (localMilliseconds! < this.transitionMilliseconds)
        this.transitionBuckets.add(Math.floor(localMilliseconds! * 30 / 1000));
      else {
        const minFrames = Math.ceil(this.transitionMilliseconds * MIN_TRANSITION_CAPTURE_FPS / 1000);
        if (this.transitionBuckets.size < minFrames)
          throw new Error("Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.",
            {cause: {transitionMilliseconds: this.transitionMilliseconds,
              framesCaptured: this.transitionBuckets.size, minFrames}});
        this.transitionChecked = true;
      }
    }
    this.firstCaptureAt ??= atMilliseconds;
    this.recentCaptures.push(atMilliseconds);
    while (this.recentCaptures[0] < atMilliseconds - CAPTURE_DENSITY_WINDOW_MILLISECONDS)
      this.recentCaptures.shift();
    if (atMilliseconds - this.firstCaptureAt >= CAPTURE_DENSITY_WINDOW_MILLISECONDS &&
        this.recentCaptures.length < MIN_CAPTURE_FRAMES_PER_WINDOW)
      throw new Error("Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.",
        {cause: {windowMilliseconds: CAPTURE_DENSITY_WINDOW_MILLISECONDS,
          framesCaptured: this.recentCaptures.length, minFrames: MIN_CAPTURE_FRAMES_PER_WINDOW}});
    this.lastCaptureAt = atMilliseconds;
    this.lastLocalTime = localMilliseconds;
  }
}
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
