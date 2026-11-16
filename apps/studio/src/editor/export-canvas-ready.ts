// Observe a real frame from the export canvas's existing capture source before
// starting MediaRecorder. The processor is a temporary sink on a cloned track:
// cancelling it and stopping the clone must not stop the recorder's track.
type WindowTrackProcessor = new (init: {
  track: MediaStreamTrack;
  maxBufferSize: number;
}) => {readable: ReadableStream<VideoFrame>};

const MAX_FRAME_READY_MS = 2_000;
const MAX_READER_CLEANUP_MS = 250;

function abortReason(signal: AbortSignal): Error {
  return signal.reason instanceof Error
    ? signal.reason
    : new DOMException("Operation cancelled.", "AbortError");
}

export async function awaitCanvasFrameReady(
  track: CanvasCaptureMediaStreamTrack,
  width: number,
  height: number,
  signal: AbortSignal,
  requireCurrent: () => void,
  paintPreparedFrame: () => Promise<void>,
  timeoutMs = MAX_FRAME_READY_MS,
): Promise<boolean> {
  const Processor = (globalThis as typeof globalThis & {
    MediaStreamTrackProcessor?: WindowTrackProcessor;
  }).MediaStreamTrackProcessor;
  // Other browsers retain the existing recorder path. This does not assert
  // that they delivered a first frame.
  if (typeof Processor !== "function" || typeof track.requestFrame !== "function")
    return false;
  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0 ||
      !Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > MAX_FRAME_READY_MS)
    throw new Error("This video could not be prepared for recording. No download was created.");
  if (signal.aborted) throw abortReason(signal);
  requireCurrent();
  if (track.readyState !== "live")
    throw new Error("Video capture stopped before recording. No download was created. Please try again.");

  const clone = track.clone();
  let reader: ReadableStreamDefaultReader<VideoFrame> | undefined;
  let frame: VideoFrame | undefined;
  let readFinished = false;
  let readinessTimer: ReturnType<typeof setTimeout> | undefined;
  let removeAbort: (() => void) | undefined;
  let failure: unknown;
  let failed = false;
  let cleanupFailure: unknown;
  let cleaned = true;
  try {
    if (clone.readyState !== "live")
      throw new Error("Video capture stopped before recording. No download was created. Please try again.");
    const processor = new Processor({track: clone, maxBufferSize: 1});
    reader = processor.readable.getReader();
    const pendingRead = reader.read().then(result => {
      if (readFinished) result.value?.close();
      else frame = result.value;
      return result;
    });
    // Painting can await a cutaway decode before the race below is installed.
    // Keep an observer attached so a concurrent processor rejection cannot
    // become an unhandled rejection; the original promise still propagates.
    void pendingRead.catch(() => undefined);
    // With the sink already connected, paint the exact first timeline picture
    // once more. The caller's existing export deadline and abort-aware overlay
    // painter bound this pre-content work; only frame delivery gets this 2 s
    // limit. No media playback or recording has started yet.
    await paintPreparedFrame();
    if (signal.aborted) throw abortReason(signal);
    requireCurrent();
    const deadline = new Promise<never>((_, reject) => {
      const aborted = () => reject(abortReason(signal));
      signal.addEventListener("abort", aborted, {once: true});
      removeAbort = () => signal.removeEventListener("abort", aborted);
      readinessTimer = setTimeout(() => reject(new Error(
        "Your browser could not prepare the first video frame. No download was created. Close other busy tabs and try again.",
      )), timeoutMs);
    });
    if (signal.aborted) throw abortReason(signal);
    requireCurrent();
    track.requestFrame();
    const result = await Promise.race([pendingRead, deadline]);
    if (signal.aborted) throw abortReason(signal);
    requireCurrent();
    if (result.done || !result.value ||
        result.value.displayWidth !== width || result.value.displayHeight !== height ||
        track.readyState !== "live")
      throw new Error("Your browser could not prepare a complete video frame. No download was created. Please try again.");
  } catch (error) {
    failure = error;
    failed = true;
  } finally {
    readFinished = true;
    if (readinessTimer !== undefined) clearTimeout(readinessTimer);
    removeAbort?.();
    try { frame?.close(); } catch (error) { cleanupFailure ??= error; cleaned = false; }
    if (reader) {
      let cleanupTimer: ReturnType<typeof setTimeout> | undefined;
      try {
        await Promise.race([
          Promise.resolve(reader.cancel()),
          new Promise<never>((_, reject) => {
            cleanupTimer = setTimeout(() => reject(new Error("The canvas frame reader did not close.")), MAX_READER_CLEANUP_MS);
          }),
        ]);
      } catch (error) { cleanupFailure ??= error; cleaned = false; }
      finally {
        if (cleanupTimer !== undefined) clearTimeout(cleanupTimer);
        try { reader.releaseLock(); } catch (error) { cleanupFailure ??= error; cleaned = false; }
      }
    }
    try { clone.stop(); } catch (error) { cleanupFailure ??= error; cleaned = false; }
  }
  if (failed) throw failure;
  if (!cleaned)
    throw new Error("Video preparation did not finish cleanly. No download was created. Please try again.", {cause: cleanupFailure});
  if (signal.aborted) throw abortReason(signal);
  requireCurrent();
  if (track.readyState !== "live")
    throw new Error("Video capture stopped before recording. No download was created. Please try again.");
  return true;
}
