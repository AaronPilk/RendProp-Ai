import {EDIT_LIMITS, clipDuration, renderDimensions, type EditDraft} from "./model";

export type EncoderConfig = Readonly<{
  width: number; height: number; frames: number; durationMicroseconds: number;
  withAudio: boolean; audioFrames: number; windowFrameCounts: readonly number[];
}>;
export type NormalizedEncoderConfig = EncoderConfig & Readonly<{
  frameRate: 30; sampleRate: 48000; channels: 2;
}>;
export type ExportWindow = Readonly<{
  clipId: string; index: number; startSeconds: number; durationSeconds: number;
  startFrame: number; frameCount: number;
}>;
export type ExportPlan = Readonly<{
  config: EncoderConfig; duration: number; windows: readonly ExportWindow[];
}>;

/** Canonical timing is independent for video microseconds and 48 kHz PCM. */
export function planExport(draft: EditDraft, withAudio: boolean): ExportPlan {
  if (typeof withAudio !== "boolean" || !draft ||
      !["16:9", "9:16", "1:1"].includes(draft.ratio) ||
      !Array.isArray(draft.clips) || draft.clips.length < 1 || draft.clips.length > EDIT_LIMITS.clips)
    throw new Error("The export timeline is invalid.");
  const windows: ExportWindow[] = [], ids = new Set<string>();
  let duration = 0, previousFrame = 0;
  for (const [index, clip] of draft.clips.entries()) {
    const source = clip?.source, speed = clip?.speed ?? 1;
    if (!source || !["image", "video"].includes(source.kind) ||
        typeof clip.id !== "string" || !clip.id || ids.has(clip.id) ||
        ![source.width, source.height].every(n => Number.isSafeInteger(n) && n > 0 && n <= 12000) ||
        source.width * source.height > (source.kind === "video" ? EDIT_LIMITS.videoPixels : EDIT_LIMITS.imagePixels) ||
        ![clip.start, clip.end, source.duration, speed].every(Number.isFinite) ||
        clip.start < 0 || clip.end - clip.start < EDIT_LIMITS.minClipSeconds ||
        (source.kind === "image" && (source.duration !== 0 || clip.start !== 0 || clip.end > EDIT_LIMITS.photoSeconds || speed !== 1)) ||
        (source.kind === "video" && (source.duration < EDIT_LIMITS.minClipSeconds ||
          source.duration > EDIT_LIMITS.sourceSeconds || clip.end > source.duration || speed < .25 || speed > 4)))
      throw new Error("A clip's export dimensions or timing is invalid.");
    ids.add(clip.id);
    const startSeconds = duration, durationSeconds = clipDuration(clip);
    duration += durationSeconds;
    if (!Number.isFinite(duration) || duration <= 0 || duration > EDIT_LIMITS.timelineSeconds)
      throw new Error("The export exceeds the three-minute timeline limit.");
    if (withAudio) {
      const endFrame = Math.round(duration * 48000), frameCount = endFrame - previousFrame;
      if (frameCount < 1) throw new Error("An audio window has no samples.");
      windows.push(Object.freeze({clipId: clip.id, index, startSeconds, durationSeconds,
        startFrame: previousFrame, frameCount}));
      previousFrame = endFrame;
    }
  }
  const durationMicroseconds = Math.round(duration * 1e6);
  const frames = Math.ceil(durationMicroseconds * 30 / 1e6);
  if (durationMicroseconds < 1 || frames < 1 || frames > 5400)
    throw new Error("The export frame plan is invalid.");
  const config = Object.freeze({...renderDimensions(draft.ratio), frames, durationMicroseconds,
    withAudio, audioFrames: withAudio ? Math.round(duration * 48000) : 0,
    windowFrameCounts: Object.freeze(windows.map(window => window.frameCount))});
  return Object.freeze({config, duration, windows: Object.freeze(windows)});
}
