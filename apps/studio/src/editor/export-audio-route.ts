import type {ExportWindow} from "./export-plan";
import type {EditClip, EditDraft} from "./model";

export const OFFLINE_PCM_CAP = 32 * 1024 * 1024;
const CHANNELS = 2;

/** Another clip's live source does not make a finite photo or buffered clip
 * depend on the realtime audio clock. Decide only after this clip is ready. */
export function pcmWindowMode(draft: EditDraft, clip: EditClip,
  window: ExportWindow, hasBufferedOriginal: boolean,
  offlineAvailable: boolean): "offline" | "live" {
  const needsElementAudio = draft.audio === "original" &&
    clip.source.kind === "video" &&
    (!hasBufferedOriginal || (clip.speed ?? 1) !== 1);
  return !needsElementAudio && offlineAvailable &&
    window.frameCount * CHANNELS * 4 <= OFFLINE_PCM_CAP ? "offline" : "live";
}

/** A track's exact source point and start delay inside one canonical output
 * window. Reusing this mapping prevents a narration or music restart at every
 * offline/live boundary. */
export function windowTrackSlice(windowStart: number, windowDuration: number,
  trackOutputStart: number, sourceStart: number, sourceEnd: number):
  {delay: number; sourceOffset: number; duration: number} | null {
  const delay = Math.max(0, trackOutputStart - windowStart);
  const elapsed = Math.max(0, windowStart - trackOutputStart);
  const duration = Math.min(sourceEnd - sourceStart - elapsed,
    windowDuration - delay);
  return duration > 0 ? {delay, sourceOffset: sourceStart + elapsed, duration} : null;
}

/** Original sound is ducked while the saved narration occupies this window. */
export function originalDuckTiming(windowStart: number, windowDuration: number,
  narrationStart?: number, narrationDuration = 0):
  {initial: number; duckAt?: number; recoverAt?: number} {
  if (narrationStart === undefined) return {initial: 1};
  const begin = narrationStart - windowStart;
  const end = begin + narrationDuration;
  return {initial: begin <= 0 && end > 0 ? .22 : 1,
    duckAt: begin > 0 && begin < windowDuration ? begin : undefined,
    recoverAt: end > 0 && end < windowDuration ? end : undefined};
}
