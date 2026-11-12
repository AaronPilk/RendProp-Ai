import {encodeExportAudio, requiresLivePCM} from "./export-audio";
import type {ExportAudioBootstrap} from "./export-audio-bootstrap";
import {seekExportFrame} from "./export-frame-seek";
import {createOwnedEncoderBridge, EncoderUnsupportedError,
  isEncoderUnsupportedError} from "./encoder-bridge";
import {videoTiming} from "./encoder-protocol";
import {planExport, type ExportPlan} from "./export-plan";
import {OverlayPainter} from "./overlay-renderer";
import {verifyMp4FrameCadence, type EncodedTransition} from "./mp4-cadence";
import {
  assertCurrentRevision, clipDuration, draftMedia, locateTime,
  transitionSeconds, validateDraft, type EditDraft,
} from "./model";
import {
  decodeMedia, drawFrame, throwIfAborted,
  type DecodedMedia, type LocalMedia,
} from "./media";
import type {ExportFormat, LocalExport} from "./export";
import encoderWorkerURL from "./encoder-worker.ts?worker&url";

/** Probe the same worker codec admission before showing a format to the user. */
export async function probeExplicitMp4(ratio: EditDraft["ratio"], withAudio: boolean,
  signal: AbortSignal): Promise<boolean> {
  if (signal.aborted)
    throw signal.reason ?? new DOMException("Format check cancelled.", "AbortError");
  const {width, height} = ratio === "16:9" ? {width: 1280, height: 720} :
    ratio === "9:16" ? {width: 720, height: 1280} :
    {width: 960, height: 960};
  // Codec support depends on output geometry and audio presence. This valid
  // one-frame plan submits no content and opens no AudioContext.
  const bridge = createOwnedEncoderBridge({
    workerURL: encoderWorkerURL,
    runId: crypto.randomUUID(), revision: "format-probe",
    config: {width, height, frames: 1, durationMicroseconds: 33_333,
      withAudio, audioFrames: withAudio ? 1600 : 0,
      windowFrameCounts: withAudio ? [1600] : []},
    signal, isCurrent: () => !signal.aborted, stopInput: () => {},
    validateOutput: async () => {throw new Error("Format probe cannot produce output.");},
    deadlineMs: 10_000,
  });
  try {
    await bridge.ready;
    return true;
  } catch (error) {
    if (isEncoderUnsupportedError(error)) return false;
    throw error;
  } finally {
    bridge.abort(new DOMException("Format probe finished.", "AbortError"));
  }
}

export type WebCodecsExportOptions = {
  draft: EditDraft;
  media: Map<string, LocalMedia>;
  narrationBlob?: Blob;
  musicBlob?: Blob;
  format: ExportFormat;
  signal: AbortSignal;
  currentDraft(): EditDraft;
  onProgress(fraction: number): void;
  /** Created and resumed in the original Export gesture before any awaits. */
  begunAudio?: ExportAudioBootstrap;
};

function transitions(draft: EditDraft): EncodedTransition[] {
  let at = 0;
  const result: EncodedTransition[] = [];
  draft.clips.forEach((clip, index) => {
    if (index && transitionSeconds(clip) > 0)
      result.push({startSeconds: at, durationSeconds: transitionSeconds(clip)});
    at += clipDuration(clip);
  });
  return result;
}

function assertInput(options: WebCodecsExportOptions, draft: EditDraft,
  plan: ExportPlan): void {
  if (options.format.extension !== "mp4")
    throw new Error("This export format cannot use the MP4 encoder.");
  if (!draft.clips.length)
    throw new Error("Add media before exporting.");
  for (const clip of draftMedia(draft)) {
    const local = options.media.get(clip.id);
    if (!local || local.source.sha256 !== clip.source.sha256)
      throw new Error(`Reselect the original file for ${clip.source.name} before exporting.`);
  }
  if (draft.narration && !options.narrationBlob?.size)
    throw new Error("Restore the selected narration before exporting.");
  if (draft.music && options.musicBlob?.size !== draft.music.source.size)
    throw new Error("Restore the selected music before exporting.");
  if (plan.config.withAudio !== Boolean(options.begunAudio))
    throw new Error("The export audio clock was not started in the Export gesture.");
  assertCurrentRevision(draft, options.currentDraft(), options.signal);
  if (document.hidden)
    throw new Error("Keep this tab visible while exporting.");
}

/** Explicit-PTS MP4 export. Worker ownership enforces exact frame/PCM admission. */
export async function exportWebCodecs(options: WebCodecsExportOptions): Promise<LocalExport> {
  const draft = validateDraft(options.draft);
  const withAudio = draft.audio === "original" &&
    draft.clips.some(clip => clip.source.kind === "video") ||
    Boolean(draft.narration || draft.music);
  const plan = planExport(draft, withAudio);
  assertInput(options, draft, plan);
  if (withAudio && requiresLivePCM(draft, plan) &&
      (typeof AudioWorkletNode !== "function" ||
       !options.begunAudio?.context.audioWorklet?.addModule))
    throw new EncoderUnsupportedError("This browser cannot capture the selected audio mix.");
  const controller = new AbortController();
  const forwardAbort = () => controller.abort(options.signal.reason);
  options.signal.addEventListener("abort", forwardAbort, {once: true});
  if (options.signal.aborted) forwardAbort();
  const hidden = () => {
    if (document.hidden)
      controller.abort(new DOMException(
        "Export cancelled because the tab was hidden. Keep it visible and retry.",
        "AbortError"));
  };
  document.addEventListener("visibilitychange", hidden);
  const deadline = setTimeout(() => controller.abort(new Error(
    "Export exceeded its local time limit. Try fewer or smaller clips.")),
    (plan.duration * 2 + 60) * 1000);
  const signal = controller.signal;
  const requireCurrent = () => {
    throwIfAborted(signal);
    assertCurrentRevision(draft, options.currentDraft(), signal);
    if (document.hidden)
      throw new Error("The tab was hidden during export. No download was created.");
  };
  const dims = {width: plan.config.width, height: plan.config.height};
  const canvas = document.createElement("canvas");
  Object.assign(canvas, dims);
  const previous = document.createElement("canvas");
  Object.assign(previous, dims);
  const overlays = new OverlayPainter(draft, options.media, signal);
  let active: DecodedMedia | undefined;
  let activeIndex = -1;
  const runId = crypto.randomUUID();
  const revision = `${draft.id}:${draft.revision}`;
  let bridge: ReturnType<typeof createOwnedEncoderBridge> | undefined;
  try {
    requireCurrent();
    bridge = createOwnedEncoderBridge({
      // Vite emits the worker as JavaScript; the bridge owns its lifetime.
      workerURL: encoderWorkerURL,
      runId, revision, config: plan.config, signal,
      isCurrent: () => {
        try {requireCurrent(); return true;} catch {return false;}
      },
      stopInput: reason => {if (reason !== null) controller.abort(reason);},
      validateOutput: async (blob, context) => {
        await verifyMp4FrameCadence(blob, transitions(draft), context.signal, plan.config);
        requireCurrent();
      },
    });
    // Worker readiness is the sole capability-fallback seam. Nothing from the
    // edit is submitted until H.264 and, when needed, AAC support is admitted.
    await bridge.ready;
    requireCurrent();
    if (withAudio) {
      await encodeExportAudio({begun: options.begunAudio!, draft, plan,
        media: options.media, narrationBlob: options.narrationBlob,
        musicBlob: options.musicBlob, encoder: bridge, signal,
        currentDraft: options.currentDraft,
        fail: error => controller.abort(error), onProgress: options.onProgress});
    }
    // Use the same production drawFrame/OverlayPainter path as preview and
    // recorder export. Explicit PTS is independent of decoder/paint wall time;
    // a source failure refuses rather than duplicating the previous frame.
    for (let index = 0; index < plan.config.frames; index++) {
      requireCurrent();
      const timing = videoTiming(plan.config, index);
      const time = timing.timestamp / 1_000_000;
      const position = locateTime(draft.clips, time);
      if (!position)
        throw new Error("The export timeline ended early. No download was created.");
      if (position.index !== activeIndex) {
        if (active) {
          previous.getContext("2d")!.drawImage(canvas, 0, 0);
          active.dispose();
          active = undefined;
        }
        if (position.index !== activeIndex + 1)
          throw new Error("The export skipped a clip. No download was created.");
        const local = options.media.get(position.clip.id)!;
        active = await decodeMedia(local.url, position.clip.source.kind, signal);
        activeIndex = position.index;
      }
      if (active!.element instanceof HTMLVideoElement)
        await seekExportFrame(active!.element, position.sourceTime, signal);
      drawFrame(canvas, active!, position.clip, draft, {
        time, localTime: position.localTime,
        ...(activeIndex > 0 ? {previous} : {}),
      });
      await overlays.paint(canvas, time);
      requireCurrent();
      // The bridge consumes ownership on success and every refusal path.
      const frame = new VideoFrame(canvas, timing);
      await bridge.addVideo(frame);
      if (index % 5 === 0 || index === plan.config.frames - 1)
        options.onProgress((withAudio ? .45 : 0) +
          (index + 1) / plan.config.frames * (withAudio ? .55 : 1));
    }
    requireCurrent();
    const output = await bridge.finish();
    requireCurrent();
    options.onProgress(1);
    return {blob: output.blob, extension: "mp4", mime: "video/mp4",
      revision: draft.revision, duration: plan.duration, audio: draft.audio,
      ...(draft.narration ? {narration: true} : {}),
      ...(draft.music ? {music: true} : {})};
  } catch (error) {
    bridge?.abort(error);
    throw error;
  } finally {
    active?.dispose();
    overlays.dispose();
    canvas.width = canvas.height = 0;
    previous.width = previous.height = 0;
    clearTimeout(deadline);
    document.removeEventListener("visibilitychange", hidden);
    options.signal.removeEventListener("abort", forwardAbort);
  }
}
