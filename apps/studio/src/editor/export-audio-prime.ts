import {seekExportFrame} from "./export-frame-seek";
import {throwIfAborted} from "./media";

function waitPrimeTurn(signal: AbortSignal, milliseconds: number): Promise<void> {
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const cleanup = () => {clearTimeout(timer); signal.removeEventListener("abort", aborted);};
    const aborted = () => {
      cleanup();
      reject(signal.reason instanceof Error ? signal.reason :
        new DOMException("Operation cancelled.", "AbortError"));
    };
    const timer = setTimeout(() => {cleanup(); resolve();}, milliseconds);
    signal.addEventListener("abort", aborted, {once: true});
    if (signal.aborted) aborted();
  });
}

/** Warm the same live source before its PCM window, with its gain held at zero. */
export async function primeExportAudioSource(
  video: HTMLVideoElement,
  start: number,
  end: number,
  speed: number,
  signal: AbortSignal,
  requireCurrent: () => void,
): Promise<void> {
  requireCurrent();
  if (![start, end, speed].every(Number.isFinite) || end <= start || speed <= 0)
    throw new Error("The original audio trim is invalid. No download was created.");
  await seekExportFrame(video, start, signal);
  requireCurrent();
  if (Math.abs(video.currentTime - start) > 1 / 240)
    throw new Error("The original audio source missed its trim. No download was created.");
  // A short real source advance exercises the decoder without capturing a
  // prefix. Pause and seek back before the fixed PCM origin is armed.
  const advance = Math.min((end - start) / 4, Math.max(1 / 120, speed * .04));
  const deadline = performance.now() + 2000;
  let playError: unknown;
  try {
    const played = video.play();
    void played.catch(error => {playError = error;});
    while (video.currentTime - start < advance) {
      requireCurrent();
      if (playError) throw playError;
      const remaining = deadline - performance.now();
      if (remaining <= 0)
        throw new Error("Original audio did not advance before export. No download was created.");
      await waitPrimeTurn(signal, Math.max(1, Math.min(1000 / 30, remaining)));
    }
    if (performance.now() >= deadline)
      throw new Error("Original audio did not advance before export. No download was created.");
    requireCurrent();
    if (playError) throw playError;
  } finally {
    video.pause();
  }
  await seekExportFrame(video, start, signal);
  if (Math.abs(video.currentTime - start) > 1 / 240)
    throw new Error("The original audio source did not return to its trim. No download was created.");
  requireCurrent();
}
