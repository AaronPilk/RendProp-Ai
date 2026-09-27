import {sha256} from "@noble/hashes/sha2.js";
import {awaitMediaOperation, decodeMedia, nextFrame, throwIfAborted, waitForEvent, type DecodedMedia} from "./media";
import {exportFormats} from "./export";

export const PROXY_LIMITS = {originalBytes: 2 * 1024 * 1024 * 1024, sourceSeconds: 180, outputBytes: 128 * 1024 * 1024, hashChunkBytes: 1024 * 1024, timeoutMs: 8 * 60 * 1000} as const;
export type ProxyManifest = {
  schema: 1; kind: "rendprop-editing-copy"; createdAt: string;
  original: {name: string; bytes: number; sha256: string; duration: number; width: number; height: number};
  copy: {name: string; bytes: number; sha256: string; duration: number; width: number; height: number; mime: string};
  settings: {frameRate: 30; videoBitsPerSecond: 3000000; audioBitsPerSecond: 128000};
  originalStorage: "user-device-only";
};
export type EditingCopy = {file: File; manifest: ProxyManifest};
export function validateProxyInput(file: Pick<File, "name" | "type" | "size">): void {
  if (!Number.isSafeInteger(file.size) || file.size <= 0 || file.size > PROXY_LIMITS.originalBytes) throw new Error("Choose one original video up to 2 GiB. For a larger recording, export a shorter excerpt from Photos first.");
  if (!["video/mp4", "video/quicktime", "video/webm"].includes(file.type) && !(!file.type && /\.(mp4|mov|webm)$/i.test(file.name))) throw new Error("Choose an MP4, MOV or WebM video. If this browser cannot decode your phone’s format, export a Most Compatible copy from Photos.");
}
export function proxyDimensions(width: number, height: number): {width: number; height: number} {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 2 || height < 2 || width * height > 8_400_000) throw new Error("Editing copies support source video up to 4K (8.4 megapixels).");
  const scale = Math.min(1, 1280 / Math.max(width, height), 720 / Math.min(width, height));
  return {width: Math.max(2, Math.floor(width * scale / 2) * 2), height: Math.max(2, Math.floor(height * scale / 2) * 2)};
}
/** The original is read only in fixed 1 MiB slices. No complete-source arrayBuffer. */
export async function hashFileInChunks(file: Blob, signal: AbortSignal, progress: (fraction: number) => void = () => {}): Promise<string> {
  const hash = sha256.create();
  try {
    for (let offset = 0; offset < file.size; offset += PROXY_LIMITS.hashChunkBytes) {
      throwIfAborted(signal);
      const bytes = await awaitMediaOperation(file.slice(offset, offset + PROXY_LIMITS.hashChunkBytes).arrayBuffer(), signal, "Reading original fingerprint");
      throwIfAborted(signal); hash.update(new Uint8Array(bytes)); progress(Math.min(1, (offset + bytes.byteLength) / file.size));
      // Let input/cancel events run between bounded CPU chunks.
      await new Promise<void>(resolve => setTimeout(resolve, 0));
    }
    throwIfAborted(signal);
    return Array.from(hash.digest(), byte => byte.toString(16).padStart(2, "0")).join("");
  } finally {hash.destroy();}
}
export async function createEditingCopy(file: File, signal: AbortSignal, onProgress: (stage: string, fraction: number) => void): Promise<EditingCopy> {
  validateProxyInput(file); throwIfAborted(signal);
  const format = exportFormats().find(item => item.extension === "mp4");
  if (!format || typeof AudioContext === "undefined") throw new Error("This browser cannot make H.264/AAC editing copies. Use Chrome on your Mac, or export a 720p Most Compatible video from Photos.");
  if (document.hidden) throw new Error("Keep this tab visible while preparing an editing copy.");
  const controller = new AbortController(), forward = () => controller.abort(signal.reason);
  signal.addEventListener("abort", forward, {once: true});
  const hide = () => {if (document.hidden) controller.abort(new Error("Editing copy canceled because the tab was hidden. Your original is unchanged."));};
  document.addEventListener("visibilitychange", hide);
  const deadline = setTimeout(() => controller.abort(new Error("Editing copy exceeded eight minutes. Use a shorter recording.")), PROXY_LIMITS.timeoutMs);
  const work = controller.signal, sourceUrl = URL.createObjectURL(file), canvas = document.createElement("canvas");
  let audio: AudioContext | undefined;
  let decoded: DecodedMedia | undefined, recorder: MediaRecorder | undefined, stream: MediaStream | undefined;
  let source: MediaElementAudioSourceNode | undefined, destination: MediaStreamAudioDestinationNode | undefined, silence: ConstantSourceNode | undefined;
  const chunks: Blob[] = []; let bytes = 0;
  try {
    audio = new AudioContext({sampleRate: 48000});
    await awaitMediaOperation(audio.resume(), work, "Starting editing copy sound");
    if (audio.state !== "running") throw new Error("Press Create editing copy again to let the browser start its sound encoder.");
    onProgress("Checking the original", 0);
    decoded = await decodeMedia(sourceUrl, "video", work);
    const video = decoded.element as HTMLVideoElement;
    if (video.duration > PROXY_LIMITS.sourceSeconds) throw new Error("Choose a recording up to three minutes. Trim a longer take in Photos first; the original can stay there.");
    const original = {name: file.name, bytes: file.size, duration: video.duration, width: video.videoWidth, height: video.videoHeight, sha256: ""};
    const dimensions = proxyDimensions(video.videoWidth, video.videoHeight); Object.assign(canvas, dimensions);
    original.sha256 = await hashFileInChunks(file, work, fraction => onProgress("Verifying the original", fraction * .2));
    throwIfAborted(work);
    const paint = () => canvas.getContext("2d", {alpha: false})!.drawImage(video, 0, 0, canvas.width, canvas.height);
    destination = audio.createMediaStreamDestination(); source = audio.createMediaElementSource(video); source.connect(destination);
    silence = audio.createConstantSource(); silence.offset.value = 0; silence.connect(destination); silence.start();
    video.muted = false; video.volume = 1; video.playbackRate = 1;
    paint(); stream = canvas.captureStream(30); for (const track of destination.stream.getAudioTracks()) stream.addTrack(track);
    recorder = new MediaRecorder(stream, {mimeType: format.mime, videoBitsPerSecond: 3_000_000, audioBitsPerSecond: 128_000});
    recorder.addEventListener("error", () => controller.abort(new Error("The browser could not encode this original. Export a 720p Most Compatible video from Photos.")));
    recorder.addEventListener("dataavailable", event => {
      if (!event.data.size || work.aborted) return;
      bytes += event.data.size;
      if (bytes > PROXY_LIMITS.outputBytes) {controller.abort(new Error("The editing copy exceeded 128 MiB. Choose a shorter original.")); return;}
      chunks.push(event.data);
    });
    recorder.start(500); paint(); (stream.getVideoTracks()[0] as CanvasCaptureMediaStreamTrack).requestFrame?.();
    await awaitMediaOperation(video.play(), work, "Starting original playback");
    let lastTime = video.currentTime, advanced = performance.now();
    while (!video.ended) {
      const now = await nextFrame(work); paint();
      if (video.currentTime > lastTime + .001) {lastTime = video.currentTime; advanced = now;}
      if (now - advanced > 10_000) throw new Error("The original stalled. Export a shorter Most Compatible clip from Photos and try again.");
      onProgress("Making the editing copy — keep this tab visible", .2 + .75 * Math.min(1, video.currentTime / original.duration));
    }
    const stopped = waitForEvent(recorder, "stop", work); recorder.stop(); await stopped; throwIfAborted(work);
    if (!bytes) throw new Error("The encoder returned no editing copy. Your original is unchanged.");
    const name = `${file.name.replace(/\.[^.]+$/, "").slice(0, 180)}-editing-copy-720p.mp4`;
    const copy = new File(chunks, name, {type: "video/mp4", lastModified: Date.now()});
    const copySha = await hashFileInChunks(copy, work, fraction => onProgress("Verifying the editing copy", .95 + .04 * fraction));
    const copyUrl = URL.createObjectURL(copy); let checked: DecodedMedia | undefined;
    try {
      checked = await decodeMedia(copyUrl, "video", work); const result = checked.element as HTMLVideoElement;
      if (Math.abs(result.duration - original.duration) > .75 || result.videoWidth !== dimensions.width || result.videoHeight !== dimensions.height) throw new Error("The editing copy did not preserve the original timing or expected size. It has not been imported.");
      const manifest: ProxyManifest = {schema: 1, kind: "rendprop-editing-copy", createdAt: new Date().toISOString(), original, copy: {name, bytes: copy.size, sha256: copySha, duration: result.duration, width: result.videoWidth, height: result.videoHeight, mime: copy.type}, settings: {frameRate: 30, videoBitsPerSecond: 3000000, audioBitsPerSecond: 128000}, originalStorage: "user-device-only"};
      throwIfAborted(work); onProgress("Editing copy ready", 1); return {file: copy, manifest};
    } finally {checked?.dispose(); URL.revokeObjectURL(copyUrl);}
  } finally {
    clearTimeout(deadline); signal.removeEventListener("abort", forward); document.removeEventListener("visibilitychange", hide);
    if (recorder && recorder.state !== "inactive") {const finished = new Promise<void>(resolve => recorder!.addEventListener("stop", () => resolve(), {once: true})); recorder.stop(); await Promise.race([finished, new Promise(resolve => setTimeout(resolve, 2000))]);}
    decoded?.dispose(); source?.disconnect(); silence?.stop(); silence?.disconnect(); stream?.getTracks().forEach(track => track.stop()); destination?.stream.getTracks().forEach(track => track.stop());
    if (audio) await Promise.race([audio.close().catch(() => undefined), new Promise(resolve => setTimeout(resolve, 2000))]); URL.revokeObjectURL(sourceUrl); canvas.width = canvas.height = 0; chunks.length = 0;
  }
}
