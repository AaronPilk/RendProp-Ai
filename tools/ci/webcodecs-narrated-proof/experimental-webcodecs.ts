/*
 * DIAGNOSTIC PROTOTYPE ONLY. Intended staging path in a disposable checkout:
 * apps/studio/src/editor/experimental-webcodecs.ts
 *
 * This exercises the existing three-second narrated fixture with real LocalMedia
 * and the shipping frame/overlay renderer. It is deliberately unable to export
 * arbitrary customer drafts. It has not been installed, compiled, or run.
 */
import {
  AudioBufferSource,
  BufferTarget,
  Mp4OutputFormat,
  Output,
  Quality,
  VideoSample,
  VideoSampleSource,
  canEncodeAudio,
  canEncodeVideo,
} from "mediabunny";
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
  if (draft.audio !== "muted" || draft.music || options.musicBlob ||
      draft.overlays?.length || draft.speech?.length || !draft.narration ||
      draft.clips.length !== 3 ||
      draft.clips[0]?.source.kind !== "image" ||
      draft.clips[1]?.source.kind !== "video" ||
      draft.clips[2]?.source.kind !== "image" ||
      draft.clips[1]?.speed !== 2 ||
      Math.abs(timelineDuration(draft.clips) - EXPECTED_SECONDS) > 0.00001) {
    throw new Error("WebCodecs proof only supports the muted-source, three-second narrated test edit. No download was created.");
  }
  if (options.format.extension !== "mp4" || !options.narrationBlob?.size ||
      options.narrationBlob.size > EDIT_LIMITS.narrationBytes) {
    throw new Error("WebCodecs proof requires MP4 and the restored narration. No download was created.");
  }
  for (const clip of draftMedia(draft)) {
    const local = options.media.get(clip.id);
    if (!local || local.source.sha256 !== clip.source.sha256)
      throw new Error(`Reselect ${clip.source.name} before exporting. No download was created.`);
  }
}

async function narrationMix(draft: EditDraft, blob: Blob, signal: AbortSignal): Promise<AudioBuffer> {
  const frames = EXPECTED_SECONDS * SAMPLE_RATE;
  const offline = new OfflineAudioContext(1, frames, SAMPLE_RATE);
  const decoded = await awaitMediaOperation(
    offline.decodeAudioData(await blob.arrayBuffer()), signal, "Decoding proof narration");
  if (!Number.isFinite(decoded.duration) || decoded.duration <= 0 ||
      decoded.duration > 300 || decoded.numberOfChannels > 2 ||
      decoded.sampleRate > 96_000)
    throw new Error("The proof narration is invalid. No download was created.");
  const source = offline.createBufferSource();
  const gain = offline.createGain();
  source.buffer = decoded;
  gain.gain.value = draft.narration!.volume;
  source.connect(gain);
  gain.connect(offline.destination);
  source.start(draft.narration!.offset);
  try {
    const mix = await awaitMediaOperation(offline.startRendering(), signal, "Rendering proof narration");
    if (mix.length !== frames || mix.sampleRate !== SAMPLE_RATE || mix.numberOfChannels !== 1)
      throw new Error("The proof narration timeline changed. No download was created.");
    return mix;
  } finally {
    source.disconnect();
    gain.disconnect();
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
export async function exportNarratedWebCodecsProof(options: ProofOptions): Promise<LocalExport> {
  const draft = validateDraft(options.draft);
  requireFixtureScope(draft, options);
  if (document.hidden) throw new Error("Keep this tab visible while exporting. No download was created.");
  assertCurrentRevision(draft, options.currentDraft(), options.signal);
  const dims = renderDimensions(draft.ratio);
  const videoQuality = new Quality({bitrate: 5_000_000});
  const audioQuality = new Quality({bitrate: 128_000});
  if (!await awaitMediaOperation(canEncodeVideo("avc", {
    width: dims.width, height: dims.height, frameRate: FPS,
    quality: videoQuality, fullCodecString: VIDEO_CODEC,
    latencyMode: "quality", hardwareAcceleration: "no-preference",
  }), options.signal, "Checking proof H.264 support") ||
      !await awaitMediaOperation(canEncodeAudio("aac", {
    numberOfChannels: 1, sampleRate: SAMPLE_RATE,
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
  const trace = {kind: "webcodecs-narrated-proof", requested: 0,
    encoded: [] as {timestamp: number; duration: number; bytes: number; sequenceNumber: number}[],
    finalized: false, failed: false};
  (window as typeof window & {webCodecsNarratedProof?: typeof trace}).webCodecsNarratedProof = trace;
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
  const audioSource = new AudioBufferSource({
    codec: "aac", quality: audioQuality, fullCodecString: AUDIO_CODEC,
  });
  output.addVideoTrack(videoSource, {frameRate: FPS});
  output.addAudioTrack(audioSource);
  let active: DecodedMedia | undefined;
  let activeIndex = -1;
  let completed = false;
  try {
    const mixedNarration = await narrationMix(draft, options.narrationBlob!, signal);
    assertCurrentRevision(draft, options.currentDraft(), signal);
    await awaitMediaOperation(output.start(), signal, "Starting proof MP4 output");
    await awaitMediaOperation(audioSource.add(mixedNarration), signal, "Encoding proof narration");
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
      duration: EXPECTED_SECONDS, audio: draft.audio, narration: true};
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
}
