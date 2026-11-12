import {CaptureCadenceClock, RecordingClock} from "./recording-clock";
import {transitionSeconds, type EditClip} from "./model";

export function canContinueSilentCut(format: string, withAudio: boolean, outgoing: EditClip,
  incoming: EditClip | undefined, successorReady: boolean): boolean {
  return format === "mp4" && !withAudio && outgoing.source.kind === "image" &&
    incoming?.source.kind === "image" && transitionSeconds(incoming) === 0 && successorReady;
}

// One owner for an unpaused recorder run. No timer, paint, source or codec APIs.
export class ContinuousSilentCutRun {
  private pending = false;
  private cadence?: CaptureCadenceClock;
  private recording?: RecordingClock;
  private wallOrigin?: number;
  private timelineOrigin?: number;
  offer(eligible: boolean, recorderState: RecordingState): boolean {
    if (this.pending) throw new Error("An unconsumed photo handoff already exists. No download was created.");
    if (!eligible) return false;
    if (recorderState !== "recording") throw new Error("The prepared photo handoff is not recording. No download was created.");
    this.pending = true;
    return true;
  }
  take(recorderState: RecordingState): boolean {
    if (!this.pending) return false;
    if (recorderState !== "recording") throw new Error("The prepared photo handoff lost its recorder. No download was created.");
    this.pending = false;
    return true;
  }
  capture(atMilliseconds: number): void {
    this.cadence ??= new CaptureCadenceClock(0);
    this.cadence.capture(atMilliseconds);
  }
  beginSegment(originalWallStart: number, elapsedBefore: number): void {
    if (!Number.isFinite(originalWallStart) || originalWallStart < 0 ||
        !Number.isFinite(elapsedBefore) || elapsedBefore < 0)
      throw new Error("The continuous photo clock could not be verified. No download was created.");
    // Fixed at the original segment clock, never a request/callback epoch.
    if (this.wallOrigin === undefined) {
      this.wallOrigin = originalWallStart;
      this.timelineOrigin = elapsedBefore;
      this.recording = new RecordingClock();
    }
  }
  read(now: number, nominalTimeline: number): void {
    if (this.wallOrigin === undefined || this.timelineOrigin === undefined || !this.recording ||
        !Number.isFinite(now) || !Number.isFinite(nominalTimeline))
      throw new Error("The continuous photo clock could not be verified. No download was created.");
    this.recording.read((now - this.wallOrigin) / 1000, nominalTimeline - this.timelineOrigin);
  }
  didPause(recorderState: RecordingState): void {
    if (recorderState !== "paused") throw new Error("Photo capture history requires an actual paused recorder. No download was created.");
    this.pending = false;
    this.cadence = undefined;
    this.recording = undefined;
    this.wallOrigin = this.timelineOrigin = undefined;
  }
}
