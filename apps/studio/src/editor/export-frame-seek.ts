import {throwIfAborted} from "./media";

/** Seek every distinct source time used by an explicit output frame. */
export async function seekExportFrame(
  video: HTMLVideoElement,
  time: number,
  signal: AbortSignal,
): Promise<void> {
  throwIfAborted(signal);
  if (!Number.isFinite(time) || !Number.isFinite(video.duration))
    throw new Error("The video has no finite export seek position.");
  const target = Math.max(0, Math.min(time, Math.max(0, video.duration - .001)));
  const sameTime = Math.abs(video.currentTime - target) <=
    Number.EPSILON * Math.max(1, Math.abs(target));
  if (!sameTime || video.readyState < 2) {
    await new Promise<void>((resolve, reject) => {
      const cleanup = () => {
        clearTimeout(timeout);
        video.removeEventListener("seeked", done);
        video.removeEventListener("error", failed);
        signal.removeEventListener("abort", aborted);
      };
      const done = () => {cleanup(); resolve();};
      const failed = () => {
        cleanup();
        reject(new Error("This browser could not decode the requested export frame."));
      };
      const aborted = () => {
        cleanup();
        reject(signal.reason instanceof Error ? signal.reason :
          new DOMException("Operation cancelled.", "AbortError"));
      };
      const timeout = setTimeout(() => {
        cleanup();
        reject(new Error("The browser took too long to seek the export frame."));
      }, 15_000);
      video.addEventListener("seeked", done, {once: true});
      video.addEventListener("error", failed, {once: true});
      signal.addEventListener("abort", aborted, {once: true});
      try {video.currentTime = target;}
      catch (error) {cleanup(); reject(error);}
    });
  }
  throwIfAborted(signal);
  // A completed seek must still be close to the requested source position.
  // Half of a 120 fps source frame is the largest accepted discrepancy.
  if (video.readyState < 2 || Math.abs(video.currentTime - target) > 1 / 240)
    throw new Error("The video decoder missed an export frame. No download was created.");
}
