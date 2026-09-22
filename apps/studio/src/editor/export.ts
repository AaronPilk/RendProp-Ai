import {OverlayPainter} from "./overlay-renderer";
import {
  EDIT_LIMITS,
  draftMedia,
  assertCurrentRevision,
  clipDuration,
  renderDimensions,
  timelineDuration,
  validateDraft,
  type EditDraft,
} from "./model";
import {
  awaitMediaOperation,
  decodeMedia,
  drawFrame,
  nextFrame,
  seekMedia,
  throwIfAborted,
  waitForEvent,
  type DecodedMedia,
  type LocalMedia,
} from "./media";

export type ExportFormat = {
  mime: string;
  extension: "mp4" | "webm";
  label: string;
};
export type LocalExport = {
  blob: Blob;
  extension: "mp4" | "webm";
  mime: string;
  revision: number;
  duration: number;
  audio: EditDraft["audio"];
  narration?: boolean;
};

export function exportFormats(): ExportFormat[] {
  if (
    typeof MediaRecorder === "undefined" ||
    typeof HTMLCanvasElement === "undefined" ||
    typeof HTMLCanvasElement.prototype.captureStream !== "function"
  )
    return [];
  const candidates: ExportFormat[] = [
    // Generic video/mp4 can select Opus audio in Chromium. Request H.264/AAC explicitly
    // so the MP4 option means the familiar format accepted by common sharing destinations.
    {
      mime: "video/mp4;codecs=avc1.42E01F,mp4a.40.2",
      extension: "mp4",
      label: "MP4",
    },
    { mime: "video/mp4;codecs=avc1,mp4a.40.2", extension: "mp4", label: "MP4" },
    { mime: "video/webm;codecs=vp8,opus", extension: "webm", label: "WebM" },
    { mime: "video/webm", extension: "webm", label: "WebM" },
  ];
  const extensions = new Set<string>();
  return candidates.filter((format) => {
    if (
      extensions.has(format.extension) ||
      !MediaRecorder.isTypeSupported(format.mime)
    )
      return false;
    extensions.add(format.extension);
    return true;
  });
}

export function supportsOriginalAudio(): boolean {
  return typeof AudioContext !== "undefined";
}

/** A real-time local draft export; its bytes are not the canonical server artifact. */
export async function exportLocalVideo(options: {
  draft: EditDraft;
  media: Map<string, LocalMedia>;
  narrationBlob?: Blob;
  format: ExportFormat;
  signal: AbortSignal;
  currentDraft: () => EditDraft;
  onProgress: (fraction: number) => void;
}): Promise<LocalExport> {
  const { media, format, signal, currentDraft, onProgress } = options;
  const draft = validateDraft(options.draft);
  const total = timelineDuration(draft.clips);
  if (!draft.clips.length) throw new Error("Add media before exporting.");
  for (const clip of draftMedia(draft)) {
    const local = media.get(clip.id);
    if (!local || local.source.sha256 !== clip.source.sha256)
      throw new Error(
        `Reselect the original file for ${clip.source.name} before exporting.`,
      );
  }
  if (!exportFormats().some((candidate) => candidate.mime === format.mime))
    throw new Error("This export format is unavailable in this browser.");
  if (draft.narration && (!options.narrationBlob?.size || options.narrationBlob.size > EDIT_LIMITS.narrationBytes)) throw new Error("Restore the selected narration before exporting.");
  const originalAudio = draft.audio === "original" && draft.clips.some(clip => clip.source.kind === "video");
  const withAudio = originalAudio || !!draft.narration;
  if (withAudio && !supportsOriginalAudio())
    throw new Error(
      "Original audio export is unavailable in this browser. Choose Mute audio explicitly or use a browser with Web Audio support.",
    );
  assertCurrentRevision(draft, currentDraft(), signal);
  if (document.hidden)
    throw new Error("Keep this tab visible while exporting.");

  const controller = new AbortController();
  const forwardAbort = () => controller.abort(signal.reason);
  signal.addEventListener("abort", forwardAbort, { once: true });
  const hidden = () => {
    if (document.hidden)
      controller.abort(
        new DOMException(
          "Export cancelled because the tab was hidden. Keep it visible and retry.",
          "AbortError",
        ),
      );
  };
  document.addEventListener("visibilitychange", hidden);
  const deadline = setTimeout(
    () =>
      controller.abort(
        new Error(
          "Export exceeded its local time limit. Try fewer or smaller clips.",
        ),
      ),
    (total * 2 + 60) * 1000,
  );
  const renderSignal = controller.signal;
  const overlays = new OverlayPainter(draft, media, renderSignal);
  const canvas = document.createElement("canvas");
  Object.assign(canvas, renderDimensions(draft.ratio));
  let stream: MediaStream | undefined;
  let recorder: MediaRecorder | undefined;
  let audio: AudioContext | undefined;
  let destination: MediaStreamAudioDestinationNode | undefined;
  let silentSource: ConstantSourceNode | undefined;
  let audioSource: MediaElementAudioSourceNode | undefined;
  let originalGain: GainNode | undefined;
  let voiceBuffer: AudioBuffer | undefined;
  let voiceSource: AudioBufferSourceNode | undefined;
  let voiceGain: GainNode | undefined;
  const previous = document.createElement("canvas"); Object.assign(previous, renderDimensions(draft.ratio));
  let hasPrevious = false;
  let decoded: DecodedMedia | undefined;
  let stopped: Promise<void> | undefined;
  const chunks: Blob[] = [];
  let outputBytes = 0;
  try {
    // Construct and resume during the original button gesture, before decoding awaits.
    if (withAudio) {
      audio = new AudioContext();
      destination = audio.createMediaStreamDestination();
      // Keep the destination clock running through photos and decoder gaps.
      // Without a live source, Chromium omits leading silence and shifts the
      // first video's sound to t=0 in the recorded file.
      silentSource = audio.createConstantSource();
      silentSource.offset.value = 0;
      silentSource.connect(destination);
      silentSource.start();
      await awaitMediaOperation(audio.resume(), renderSignal, "Starting audio");
      if (audio.state !== "running")
        throw new Error(
          "The browser blocked original audio. Press Export again, or explicitly choose Mute audio.",
        );
    }
    if (draft.narration && audio && options.narrationBlob) {
      voiceBuffer = await awaitMediaOperation(audio.decodeAudioData(await options.narrationBlob.arrayBuffer()), renderSignal, "Decoding narration");
      if (!Number.isFinite(voiceBuffer.duration) || voiceBuffer.duration <= 0 || voiceBuffer.duration > 300 || voiceBuffer.numberOfChannels > 2 || voiceBuffer.sampleRate > 96000) throw new Error("The saved narration has an invalid duration.");
      voiceGain = audio.createGain(); voiceGain.gain.value = draft.narration.volume; voiceGain.connect(destination!);
    }
    throwIfAborted(renderSignal);
    stream = canvas.captureStream(30);
    if (destination)
      for (const track of destination.stream.getAudioTracks())
        stream.addTrack(track);
    recorder = new MediaRecorder(stream, {
      mimeType: format.mime,
      videoBitsPerSecond: 5_000_000,
      ...(withAudio ? { audioBitsPerSecond: 128_000 } : {}),
    });
    stopped = new Promise((resolve) =>
      recorder!.addEventListener("stop", () => resolve(), { once: true }),
    );
    recorder.addEventListener("error", () =>
      controller.abort(
        new Error(
          "The browser encoder failed. Try the other offered format or a smaller edit.",
        ),
      ),
    );
    recorder.addEventListener("dataavailable", (event) => {
      if (renderSignal.aborted || !event.data.size) return;
      outputBytes += event.data.size;
      if (outputBytes > EDIT_LIMITS.outputBytes) {
        controller.abort(
          new Error(
            "The output exceeded the 128 MiB local memory limit. Shorten the edit.",
          ),
        );
        return;
      }
      chunks.push(event.data);
    });
    let elapsedBefore = 0;
    let lastProgressAt = 0;
    for (const clip of draft.clips) {
      assertCurrentRevision(draft, currentDraft(), renderSignal);
      decoded = await decodeMedia(
        media.get(clip.id)!.url,
        clip.source.kind,
        renderSignal,
      );
      const video =
        decoded.element instanceof HTMLVideoElement
          ? decoded.element
          : undefined;
      if (video) {
        await seekMedia(video, clip.start, renderSignal);
        video.playbackRate = clip.speed ?? 1;
        if (originalAudio && audio && destination) {
          audioSource = audio.createMediaElementSource(video);
          originalGain = audio.createGain(); originalGain.gain.value = draft.narration ? 0.22 : 1;
          audioSource.connect(originalGain); originalGain.connect(destination);
          // Sound goes only to the recording destination, avoiding an audible duplicate.
          video.muted = false;
          video.volume = 1;
        }
      }
      drawFrame(canvas, decoded, clip, draft, {time: elapsedBefore, localTime: 0, previous: hasPrevious ? previous : undefined});
      await overlays.paint(canvas, elapsedBefore);
      throwIfAborted(renderSignal);
      if (recorder.state === "inactive") {
        // start() changes state synchronously. Some WebM encoders emit `start`
        // only after receiving a fresh frame; awaiting that event before the
        // render loop deadlocks. Submit a frame and let the loop feed the encoder.
        recorder.start(500);
        drawFrame(canvas, decoded, clip, draft, {time: elapsedBefore, localTime: 0, previous: hasPrevious ? previous : undefined});
        await overlays.paint(canvas, elapsedBefore);
        const track = stream.getVideoTracks()[0] as
          CanvasCaptureMediaStreamTrack | undefined;
        track?.requestFrame?.();
      } else {
        const resumed = waitForEvent(recorder, "resume", renderSignal);
        recorder.resume();
        await resumed;
      }
      // Start recording before advancing the source, so startup cannot discard speech.
      if (video)
        await awaitMediaOperation(video.play(), renderSignal, "Starting video");
      if (draft.narration && voiceBuffer && audio && voiceGain) {
        const offset = Math.max(0, elapsedBefore - draft.narration.offset), delay = Math.max(0, draft.narration.offset - elapsedBefore);
        if (offset < voiceBuffer.duration && delay < clipDuration(clip)) {
          voiceSource = audio.createBufferSource(); voiceSource.buffer = voiceBuffer; voiceSource.connect(voiceGain);
          voiceSource.start(audio.currentTime + delay, offset);
        }
      }
      const start = performance.now();
      let lastVideoTime = video?.currentTime ?? 0;
      let lastVideoAdvance = start;
      const duration = clipDuration(clip);
      while (true) {
        assertCurrentRevision(draft, currentDraft(), renderSignal);
        const now = await nextFrame(renderSignal);
        const elapsed = video
          ? Math.max(0, video.currentTime - clip.start) / (clip.speed ?? 1)
          : (now - start) / 1000;
        if (video && video.currentTime > lastVideoTime + 0.001) {
          lastVideoTime = video.currentTime;
          lastVideoAdvance = now;
        }
        if (video && now - lastVideoAdvance > 10_000)
          throw new Error(
            "Video playback stalled during export. Try a smaller or differently encoded clip.",
          );
        drawFrame(canvas, decoded, clip, draft, {time: elapsedBefore + elapsed, localTime: elapsed, previous: hasPrevious ? previous : undefined});
        await overlays.paint(canvas, elapsedBefore + elapsed);
        if (now - lastProgressAt > 150) {
          onProgress(Math.min(1, (elapsedBefore + elapsed) / total));
          lastProgressAt = now;
        }
        if (elapsed >= duration || video?.ended) break;
      }
      // Pausing recording while loading the next source keeps decoder setup out of the edit.
      const paused = waitForEvent(recorder, "pause", renderSignal);
      recorder.pause();
      await paused;
      video?.pause();
      voiceSource?.stop(); voiceSource?.disconnect(); voiceSource = undefined;
      originalGain?.disconnect(); originalGain = undefined;
      previous.getContext("2d")!.drawImage(canvas, 0, 0); hasPrevious = true;
      audioSource?.disconnect();
      audioSource = undefined;
      decoded.dispose();
      decoded = undefined;
      elapsedBefore += duration;
    }
    assertCurrentRevision(draft, currentDraft(), renderSignal);
    const finished = waitForEvent(recorder, "stop", renderSignal);
    recorder.stop();
    await finished;
    throwIfAborted(renderSignal);
    const mime = recorder.mimeType;
    const extension = mime.startsWith("video/mp4")
      ? "mp4"
      : mime.startsWith("video/webm")
        ? "webm"
        : null;
    if (!extension)
      throw new Error(
        `The browser returned an unsupported output type: ${mime}.`,
      );
    const blob = new Blob(chunks, { type: mime });
    if (!blob.size)
      throw new Error(
        "The browser returned an empty recording. No export was created.",
      );
    assertCurrentRevision(draft, currentDraft(), renderSignal);
    onProgress(1);
    return {
      blob,
      extension,
      mime,
      revision: draft.revision,
      duration: total,
      audio: draft.audio,
      ...(draft.narration ? {narration: true} : {}),
    };
  } finally {
    overlays.dispose();
    clearTimeout(deadline);
    signal.removeEventListener("abort", forwardAbort);
    document.removeEventListener("visibilitychange", hidden);
    decoded?.dispose();
    audioSource?.disconnect();
    originalGain?.disconnect(); voiceSource?.stop(); voiceSource?.disconnect(); voiceGain?.disconnect();
    previous.width = previous.height = 0;
    if (recorder && recorder.state !== "inactive") {
      recorder.stop();
      // onstop flushes the encoder before its tracks/context are released.
      await Promise.race([
        stopped,
        new Promise((resolve) => setTimeout(resolve, 2000)),
      ]);
    }
    stream?.getTracks().forEach((track) => track.stop());
    destination?.stream.getTracks().forEach((track) => track.stop());
    silentSource?.stop();
    silentSource?.disconnect();
    if (audio && audio.state !== "closed")
      await Promise.race([
        audio.close().catch(() => undefined),
        new Promise((resolve) => setTimeout(resolve, 2000)),
      ]);
    canvas.width = 0;
    canvas.height = 0;
    chunks.length = 0;
  }
}
