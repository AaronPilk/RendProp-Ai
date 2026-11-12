/*
 * DIAGNOSTIC PROTOTYPE ONLY. Intended staging path in a disposable checkout:
 * apps/studio/src/editor/experimental-webcodecs.ts
 *
 * This exercises a separate three-second audible-original fixture with real LocalMedia
 * and the shipping frame/overlay renderer. It is deliberately unable to export
 * arbitrary customer drafts. Only external static checks have run.
 */
import {
  AudioSampleSource,
  BufferTarget,
  Mp4OutputFormat,
  Output,
  Quality,
  VideoSample,
  VideoSampleSource,
  canEncodeAudio,
  canEncodeVideo,
} from "mediabunny";
import {captureAudibleOriginalProof, beginAudibleProofAudio,
  AudioBootstrapSetupError, type AudibleTrace} from "./audible-pcm";
import {OverlayPainter} from "./overlay-renderer";
import {verifyMp4FrameCadence, type EncodedTransition} from "./mp4-cadence";
import {
  EDIT_LIMITS, assertCurrentRevision, clipDuration, draftMedia, locateTime,
  renderDimensions, timelineDuration, transitionSeconds, validateDraft,
  type EditDraft,
} from "./model";
import {
  awaitMediaOperation, decodeMedia, drawFrame, seekMedia, throwIfAborted,
  type DecodedMedia, type LocalMedia,
} from "./media";
import type {ExportFormat, LocalExport} from "./export";

const FPS = 30;
const SAMPLE_RATE = 48_000;
const EXPECTED_SECONDS = 3;
const VIDEO_CODEC = "avc1.42001f";
const AUDIO_CODEC = "mp4a.40.2";

type ProofOptions = {
  draft: EditDraft;
  media: Map<string, LocalMedia>;
  narrationBlob?: Blob;
  musicBlob?: Blob;
  format: ExportFormat;
  signal: AbortSignal;
  currentDraft: () => EditDraft;
  onProgress: (fraction: number) => void;
};

function requireFixtureScope(draft: EditDraft, options: ProofOptions): void {
  if (draft.audio !== "original" || draft.music || options.musicBlob ||
      draft.overlays?.length || draft.speech?.length || draft.narration ||
      options.narrationBlob || draft.clips.length !== 3 ||
      draft.clips[0]?.source.kind !== "image" ||
      draft.clips[1]?.source.kind !== "video" ||
      draft.clips[2]?.source.kind !== "image" ||
      draft.clips[1]?.speed !== 2 ||
      Math.abs(clipDuration(draft.clips[0]) - .5) > .00001 ||
      Math.abs(clipDuration(draft.clips[1]) - 2) > .00001 ||
      Math.abs(clipDuration(draft.clips[2]) - .5) > .00001 ||
      Math.abs(timelineDuration(draft.clips) - EXPECTED_SECONDS) > .00001) {
    throw new Error("Audible proof only supports the exact three-second original-audio test edit. No download was created.");
  }
  if (options.format.extension !== "mp4") {
    throw new Error("Audible proof requires MP4. No download was created.");
  }
  for (const clip of draftMedia(draft)) {
    const local = options.media.get(clip.id);
    if (!local || local.source.sha256 !== clip.source.sha256)
      throw new Error(`Reselect ${clip.source.name} before exporting. No download was created.`);
  }
}

function trackTransitions(draft: EditDraft): EncodedTransition[] {
  let at = 0;
  const result: EncodedTransition[] = [];
  draft.clips.forEach((clip, index) => {
    if (index && transitionSeconds(clip) > 0)
      result.push({startSeconds: at, durationSeconds: transitionSeconds(clip)});
    at += clipDuration(clip);
  });
  return result;
}

/** External experiment only. It never changes the shipping export path. */
export async function exportAudibleWebCodecsProof(options: ProofOptions): Promise<LocalExport> {
  const draft = validateDraft(options.draft);
  requireFixtureScope(draft, options);
  if (document.hidden) throw new Error("Keep this tab visible while exporting. No download was created.");
  assertCurrentRevision(draft, options.currentDraft(), options.signal);
  let begunAudio: ReturnType<typeof beginAudibleProofAudio>;
  try {begunAudio = beginAudibleProofAudio();}
  catch (error) {
    if (error instanceof AudioBootstrapSetupError) {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const result = await Promise.race([
        error.closeStarted.then(() => "closed" as const, () => "rejected" as const),
        new Promise<"timed-out">(resolve => {
          timeout = setTimeout(() => resolve("timed-out"), 2000);
        }),
      ]);
      if (timeout !== undefined) clearTimeout(timeout);
      (window as typeof window & {audibleProofSetupClose?: typeof result})
        .audibleProofSetupClose = result;
      if (result !== "closed")
        throw new Error("The proof AudioContext did not close after setup failure. No download was created.",
          {cause: error.cause ?? error});
      throw error.cause ?? error;
    }
    throw error;
  }
  try {
  const dims = renderDimensions(draft.ratio);
  const videoQuality = new Quality({bitrate: 5_000_000});
  const audioQuality = new Quality({bitrate: 128_000});
  if (!await awaitMediaOperation(canEncodeVideo("avc", {
    width: dims.width, height: dims.height, frameRate: FPS,
    quality: videoQuality, fullCodecString: VIDEO_CODEC,
    latencyMode: "quality", hardwareAcceleration: "no-preference",
  }), options.signal, "Checking proof H.264 support") ||
      !await awaitMediaOperation(canEncodeAudio("aac", {
    numberOfChannels: 2, sampleRate: SAMPLE_RATE,
    quality: audioQuality, fullCodecString: AUDIO_CODEC,
  }), options.signal, "Checking proof AAC support"))
    throw new Error("H.264/AAC WebCodecs proof is unsupported in this browser. No download was created.");
  throwIfAborted(options.signal);
  if (document.hidden) throw new Error("Keep this tab visible while exporting. No download was created.");

  const controller = new AbortController();
  const forwardAbort = () => controller.abort(options.signal.reason);
  options.signal.addEventListener("abort", forwardAbort, {once: true});
  if (options.signal.aborted) forwardAbort();
  const hidden = () => { if (document.hidden) controller.abort(new Error("The tab was hidden during export. No download was created.")); };
  document.addEventListener("visibilitychange", hidden);
  const deadline = setTimeout(() => controller.abort(new Error("The bounded WebCodecs proof timed out. No download was created.")),
    (EXPECTED_SECONDS * 2 + 60) * 1000);
  const signal = controller.signal;
  const canvas = document.createElement("canvas"); Object.assign(canvas, dims);
  const previous = document.createElement("canvas"); Object.assign(previous, dims);
  const overlays = new OverlayPainter(draft, options.media, signal);
  const target = new BufferTarget();
  const output = new Output({format: new Mp4OutputFormat({fastStart: false}), target});
  const trace = {kind: "webcodecs-audible-original-proof", requested: 0,
    audio: undefined as AudibleTrace | undefined,
    encoded: [] as {timestamp: number; duration: number; bytes: number; sequenceNumber: number}[],
    finalized: false, failed: false};
  (window as typeof window & {webCodecsAudibleProof?: typeof trace}).webCodecsAudibleProof = trace;
  let encodedVideoPackets = 0;
  let encodedBytes = 0;
  const videoSource = new VideoSampleSource({
    codec: "avc", quality: videoQuality, fullCodecString: VIDEO_CODEC,
    latencyMode: "quality", hardwareAcceleration: "no-preference",
    onEncodedPacket(packet) {
      encodedVideoPackets++;
      encodedBytes += packet.byteLength;
      if (trace.encoded.length < EXPECTED_SECONDS * FPS)
        trace.encoded.push({timestamp: packet.timestamp, duration: packet.duration,
          bytes: packet.byteLength, sequenceNumber: packet.sequenceNumber});
      if (encodedBytes > EDIT_LIMITS.outputBytes)
        controller.abort(new Error("Proof output exceeded 128 MiB. No download was created."));
    },
  });
  const audioSource = new AudioSampleSource({
    codec: "aac", quality: audioQuality, fullCodecString: AUDIO_CODEC,
  });
  output.addVideoTrack(videoSource, {frameRate: FPS});
  output.addAudioTrack(audioSource);
  let active: DecodedMedia | undefined;
  let activeIndex = -1;
  let completed = false;
  try {
    assertCurrentRevision(draft, options.currentDraft(), signal);
    await awaitMediaOperation(output.start(), signal, "Starting proof MP4 output");
    trace.audio = await captureAudibleOriginalProof({
      begun: begunAudio, draft, media: options.media, audioSource, signal,
      currentDraft: options.currentDraft, fail: error => controller.abort(error),
    });
    audioSource.close();

    const frames = EXPECTED_SECONDS * FPS;
    for (let index = 0; index < frames; index++) {
      throwIfAborted(signal);
      assertCurrentRevision(draft, options.currentDraft(), signal);
      const time = index / FPS;
      const position = locateTime(draft.clips, time);
      if (!position) throw new Error("Proof timeline ended early. No download was created.");
      if (position.index !== activeIndex) {
        if (active) {
          // Match shipping export: retain the last completed outgoing paint,
          // then blend the incoming clip over it. Seeking to a video's exact
          // trimmed end can land past its last decodable frame.
          previous.getContext("2d")!.drawImage(canvas, 0, 0);
          active.dispose();
          active = undefined;
        }
        if (position.index !== activeIndex + 1)
          throw new Error("Proof timeline skipped a clip. No download was created.");
        const local = options.media.get(position.clip.id)!;
        active = await decodeMedia(local.url, position.clip.source.kind, signal);
        activeIndex = position.index;
      }
      if (active!.element instanceof HTMLVideoElement)
        await seekMedia(active!.element, position.sourceTime, signal);
      drawFrame(canvas, active!, position.clip, draft, {
        time, localTime: position.localTime,
        ...(activeIndex > 0 ? {previous} : {}),
      });
      await overlays.paint(canvas, time);
      throwIfAborted(signal);

      // VideoFrame captures the completed, real canvas paint. No synthetic
      // content frame is inserted and no dropped frame is replaced or padded.
      const firstMicrosecond = Math.round(index * 1_000_000 / FPS);
      const nextMicrosecond = Math.round((index + 1) * 1_000_000 / FPS);
      const frame = new VideoFrame(canvas, {
        timestamp: firstMicrosecond,
        duration: nextMicrosecond - firstMicrosecond,
      });
      let sample: VideoSample;
      try { sample = new VideoSample(frame); }
      catch (error) { frame.close(); throw error; }
      try {
        await awaitMediaOperation(videoSource.add(sample, {keyFrame: index === 0 || index % 60 === 0}),
          signal, "Encoding proof frame");
      } finally { sample.close(); }
      trace.requested++;
      if (index % 5 === 0) options.onProgress((index + 1) / frames);
    }
    videoSource.close();
    assertCurrentRevision(draft, options.currentDraft(), signal);
    // finalize drains encoders, but Mediabunny 1.65.2 cannot be canceled while
    // already finalizing. This is a prototype limitation, not a shipping claim.
    await output.finalize();
    trace.finalized = true;
    throwIfAborted(signal);
    if (encodedVideoPackets !== frames)
      throw new Error(`Proof encoder returned ${encodedVideoPackets} of ${frames} requested frames. No download was created.`);
    const packetTimes = trace.encoded.map(packet => {
      if (!Number.isFinite(packet.timestamp) || !Number.isFinite(packet.duration) ||
          packet.duration <= 0 || packet.bytes <= 0)
        throw new Error("Proof encoder returned invalid packet timing. No download was created.");
      return packet.timestamp;
    }).sort((a, b) => a - b);
    for (let index = 0; index < frames; index++) {
      if (Math.abs(packetTimes[index]! - index / FPS) > .001)
        throw new Error("Proof encoder skipped or duplicated a presentation time. No download was created.");
    }
    const buffer = target.buffer;
    if (!buffer || !buffer.byteLength || buffer.byteLength > EDIT_LIMITS.outputBytes)
      throw new Error("Proof MP4 is empty or exceeds 128 MiB. No download was created.");
    const blob = new Blob([buffer], {type: "video/mp4"});
    await verifyMp4FrameCadence(blob, trackTransitions(draft), signal);
    assertCurrentRevision(draft, options.currentDraft(), signal);
    completed = true;
    options.onProgress(1);
    return {blob, extension: "mp4", mime: "video/mp4", revision: draft.revision,
      duration: EXPECTED_SECONDS, audio: draft.audio};
  } catch (error) {
    trace.failed = true;
    throw error;
  } finally {
    active?.dispose();
    overlays.dispose();
    // On failure, cancel force-closes both connected sources. Calling
    // source.close() before Output.start() would mask the original error.
    if (!completed && output.state !== "finalized") {
      try { await output.cancel(); } catch { /* Keep the original refusal. */ }
    }
    previous.width = previous.height = 0;
    canvas.width = canvas.height = 0;
    clearTimeout(deadline);
    document.removeEventListener("visibilitychange", hidden);
    options.signal.removeEventListener("abort", forwardAbort);
  }
  } finally {
    const audio = begunAudio.context;
    // Capture cleanup stops this once. Also own the pre-capture capability,
    // decode, cancellation and output-start failures where capture never ran.
    let bootstrapError: unknown;
    try {begunAudio.bootstrap.stop();} catch (error) {bootstrapError = error;}
    if (audio.state !== "closed") {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const closed = await Promise.race([
        audio.close().then(() => true, () => false),
        new Promise<false>(resolve => {timeout = setTimeout(() => resolve(false), 2000);}),
      ]);
      if (timeout !== undefined) clearTimeout(timeout);
      const state = (): AudioContextState => audio.state;
      if (!closed || state() !== "closed")
        throw new Error("The proof AudioContext did not close. No download was created.");
    }
    (window as typeof window & {audibleProofOuterAudioState?: AudioContextState}).audibleProofOuterAudioState = audio.state;
    if (bootstrapError) throw bootstrapError;
  }
}
