import {
  EDIT_LIMITS,
  coverCrop,
  clipDuration,
  narrationCaption,
  transitionSeconds,
  type CaptionStyle,
  mediaKind,
  validateFileBatch,
  type EditClip,
  type EditDraft,
  type SourceRef,
} from "./model";

export type LocalMedia = {
  file: File;
  url: string;
  thumbnail: string;
  source: SourceRef;
};
export type DecodedMedia = {
  element: HTMLImageElement | HTMLVideoElement;
  dispose: () => void;
};

export function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted)
    throw signal.reason instanceof Error
      ? signal.reason
      : new DOMException("Operation cancelled.", "AbortError");
}

/** Native media promises can remain pending when playback or audio is blocked. */
export function awaitMediaOperation<T>(
  operation: Promise<T>,
  signal: AbortSignal,
  description: string,
  timeoutMs = 15_000,
): Promise<T> {
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timeout);
      signal.removeEventListener("abort", aborted);
    };
    const aborted = () => {
      cleanup();
      reject(
        signal.reason instanceof Error
          ? signal.reason
          : new DOMException("Operation cancelled.", "AbortError"),
      );
    };
    const timeout = setTimeout(() => {
      cleanup();
      reject(
        new Error(
          `${description} took too long. Try a smaller clip or another browser.`,
        ),
      );
    }, timeoutMs);
    signal.addEventListener("abort", aborted, { once: true });
    operation.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error) => {
        cleanup();
        reject(error);
      },
    );
  });
}

export function waitForEvent(
  target: EventTarget,
  event: string,
  signal: AbortSignal,
  timeoutMs = 15_000,
): Promise<void> {
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timeout);
      target.removeEventListener(event, done);
      target.removeEventListener("error", failed);
      signal.removeEventListener("abort", aborted);
    };
    const done = () => {
      cleanup();
      resolve();
    };
    const failed = () => {
      cleanup();
      reject(
        new Error(
          "This browser could not decode or record the media. Try an H.264 MP4, JPG, PNG, or WebP.",
        ),
      );
    };
    const aborted = () => {
      cleanup();
      reject(
        signal.reason instanceof Error
          ? signal.reason
          : new DOMException("Operation cancelled.", "AbortError"),
      );
    };
    const timeout = setTimeout(() => {
      cleanup();
      reject(
        new Error(
          "The browser took too long to load or record media. Try a smaller file.",
        ),
      );
    }, timeoutMs);
    target.addEventListener(event, done, { once: true });
    target.addEventListener("error", failed, { once: true });
    signal.addEventListener("abort", aborted, { once: true });
  });
}

function checkDimensions(
  width: number,
  height: number,
  kind: SourceRef["kind"],
) {
  const ceiling =
    kind === "image" ? EDIT_LIMITS.imagePixels : EDIT_LIMITS.videoPixels;
  if (
    !Number.isSafeInteger(width) ||
    !Number.isSafeInteger(height) ||
    width <= 0 ||
    height <= 0 ||
    width * height > ceiling ||
    width > 12_000 ||
    height > 12_000
  ) {
    throw new Error(
      `${kind === "image" ? "Photo" : "Video"} exceeds the ${kind === "image" ? "12" : "8.4"} megapixel local decoding limit, or has invalid dimensions.`,
    );
  }
}

export async function decodeMedia(
  url: string,
  kind: SourceRef["kind"],
  signal: AbortSignal,
): Promise<DecodedMedia> {
  throwIfAborted(signal);
  if (kind === "image") {
    const image = new Image();
    image.decoding = "async";
    const dispose = () => {
      image.removeAttribute("src");
    };
    try {
      const ready = waitForEvent(image, "load", signal);
      image.src = url;
      await ready;
      checkDimensions(image.naturalWidth, image.naturalHeight, kind);
      return { element: image, dispose };
    } catch (error) {
      dispose();
      throw error;
    }
  }
  const video = document.createElement("video");
  video.preload = "auto";
  video.playsInline = true;
  video.muted = true;
  const dispose = () => {
    video.pause();
    video.removeAttribute("src");
    video.load();
  };
  try {
    const metadata = waitForEvent(video, "loadedmetadata", signal);
    video.src = url;
    video.load();
    await metadata;
    checkDimensions(video.videoWidth, video.videoHeight, kind);
    if (
      !Number.isFinite(video.duration) ||
      video.duration < EDIT_LIMITS.minClipSeconds ||
      video.duration > EDIT_LIMITS.sourceSeconds
    )
      throw new Error(
        "Source videos must have a known duration between 0.5 and 300 seconds.",
      );
    if (video.readyState < 2) await waitForEvent(video, "loadeddata", signal);
    return { element: video, dispose };
  } catch (error) {
    dispose();
    throw error;
  }
}

export async function inspectFile(
  file: File,
  signal: AbortSignal,
): Promise<LocalMedia> {
  validateFileBatch([file]);
  if (!crypto.subtle)
    throw new Error(
      "Media identity checks require HTTPS or localhost in a modern browser.",
    );
  throwIfAborted(signal);
  // Digest is not streaming. The 128 MiB per-file cap and sequential imports bound this allocation.
  const digest = await crypto.subtle.digest(
    "SHA-256",
    await file.arrayBuffer(),
  );
  throwIfAborted(signal);
  const sha256 = Array.from(new Uint8Array(digest), (n) =>
    n.toString(16).padStart(2, "0"),
  ).join("");
  const kind = mediaKind(file);
  const url = URL.createObjectURL(file);
  let decoded: DecodedMedia | undefined;
  try {
    decoded = await decodeMedia(url, kind, signal);
    const element = decoded.element;
    const video = element instanceof HTMLVideoElement;
    const width = video ? element.videoWidth : element.naturalWidth;
    const height = video ? element.videoHeight : element.naturalHeight;
    const thumb = document.createElement("canvas");
    thumb.width = 240;
    thumb.height = 160;
    const crop = coverCrop(width, height, thumb.width, thumb.height);
    thumb
      .getContext("2d")
      ?.drawImage(
        element,
        crop.x,
        crop.y,
        crop.width,
        crop.height,
        0,
        0,
        thumb.width,
        thumb.height,
      );
    const thumbnail = thumb.toDataURL("image/jpeg", 0.65);
    thumb.width = 0;
    thumb.height = 0;
    return {
      file,
      url,
      thumbnail,
      source: {
        name: file.name,
        size: file.size,
        lastModified: file.lastModified,
        sha256,
        kind,
        width,
        height,
        duration: video ? element.duration : 0,
      },
    };
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  } finally {
    decoded?.dispose();
  }
}

export async function seekMedia(
  video: HTMLVideoElement,
  time: number,
  signal: AbortSignal,
): Promise<void> {
  throwIfAborted(signal);
  const target = Math.max(
    0,
    Math.min(time, Math.max(0, video.duration - 0.001)),
  );
  if (Math.abs(video.currentTime - target) < 0.015 && video.readyState >= 2)
    return;
  const seeking = waitForEvent(video, "seeked", signal);
  video.currentTime = target;
  await seeking;
}

function wrapText(
  ctx: CanvasRenderingContext2D,
  text: string,
  width: number,
): string[] {
  const lines: string[] = [];
  for (const paragraph of text.split("\n")) {
    let line = "";
    for (const character of paragraph) {
      if (line && ctx.measureText(line + character).width > width) {
        lines.push(line.trim());
        line = "";
      }
      line += character;
    }
    lines.push(line.trim());
  }
  return lines;
}

function paintText(
  ctx: CanvasRenderingContext2D,
  text: string,
  y: number,
  placement: "top" | "bottom",
  width: number,
  height: number,
  style: CaptionStyle = "clean",
) {
  if (!text.trim()) return;
  const margin = width * 0.065;
  let size = Math.round(
    Math.min(width, height) * (style === "center" ? 0.075 : placement === "top" ? 0.041 : 0.049),
  );
  let lines: string[] = [];
  do {
    ctx.font = `${style === "clean" ? 600 : 800} ${size}px system-ui, sans-serif`;
    lines = wrapText(ctx, text, width - margin * 2);
    size -= 1;
  } while (lines.length > 4 && size > 14);
  const lineHeight = (size + 1) * 1.32;
  const blockHeight = lines.length * lineHeight + 24;
  const top = style === "center" ? height / 2 - blockHeight / 2 : placement === "bottom" ? y - blockHeight : y;
  ctx.fillStyle = style === "highlight" ? "#e7f46c" : "rgba(11,13,16,0.76)";
  ctx.fillRect(margin - 12, top, width - margin * 2 + 24, blockHeight);
  ctx.fillStyle = style === "highlight" ? "#172008" : "#F2F3F5";
  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  lines.forEach((line, index) =>
    ctx.fillText(line, width / 2, top + 12 + index * lineHeight),
  );
}

export function drawFrame(
  canvas: HTMLCanvasElement,
  media: DecodedMedia,
  clip: EditClip,
  draft: Pick<EditDraft, "title" | "narration">,
  options: {time?: number; localTime?: number; previous?: HTMLCanvasElement} = {},
): void {
  const ctx = canvas.getContext("2d", { alpha: false });
  if (!ctx) throw new Error("Canvas rendering is unavailable in this browser.");
  const { width, height } = canvas;
  const crop = coverCrop(
    clip.source.width,
    clip.source.height,
    width,
    height,
    clip.focusX,
    clip.focusY,
  );
  if (clip.source.kind === "image" && clip.motion && clip.motion !== "still") {
    const fraction = Math.min(1, Math.max(0, (options.localTime ?? 0) / clipDuration(clip)));
    const zoom = clip.motion === "push_in" ? 1 + 0.12 * fraction : clip.motion === "pull_out" ? 1.12 - 0.12 * fraction : 1.1;
    crop.width /= zoom; crop.height /= zoom;
    const focus = clip.motion === "pan_left" ? 0.7 - 0.4 * fraction : clip.motion === "pan_right" ? 0.3 + 0.4 * fraction : clip.focusX;
    crop.x = (clip.source.width - crop.width) * focus; crop.y = (clip.source.height - crop.height) * clip.focusY;
  }
  ctx.fillStyle = "#0B0D10";
  ctx.fillRect(0, 0, width, height);
  ctx.drawImage(
    media.element,
    crop.x,
    crop.y,
    crop.width,
    crop.height,
    0,
    0,
    width,
    height,
  );
  paintText(ctx, draft.title, height * 0.055, "top", width, height);
  const spokenCaption = narrationCaption(draft.narration, options.time ?? 0);
  paintText(ctx, clip.caption, height * (spokenCaption ? 0.76 : 0.91), "bottom", width, height, clip.captionStyle ?? "clean");
  if (spokenCaption) paintText(ctx, spokenCaption, height * 0.94, "bottom", width, height, "highlight");
  const seconds = transitionSeconds(clip), progress = seconds ? Math.min(1, Math.max(0, (options.localTime ?? seconds) / seconds)) : 1;
  if (options.previous && progress < 1) {
    ctx.save();
    if (clip.transition === "dissolve") {
      ctx.globalAlpha = 1 - progress; ctx.drawImage(options.previous, 0, 0, width, height);
    } else if (clip.transition === "whip") {
      const eased = progress * progress * (3 - 2 * progress);
      // Shift the incoming frame in place, then slide the held outgoing frame away.
      ctx.drawImage(canvas, Math.round(width * (1 - eased)), 0);
      ctx.drawImage(options.previous, Math.round(-width * eased), 0, width, height);
    }
    ctx.restore();
  }
}

export function nextFrame(signal: AbortSignal): Promise<number> {
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const aborted = () => {
      cancelAnimationFrame(frame);
      reject(
        signal.reason instanceof Error
          ? signal.reason
          : new DOMException("Operation cancelled.", "AbortError"),
      );
    };
    const frame = requestAnimationFrame((time) => {
      signal.removeEventListener("abort", aborted);
      resolve(time);
    });
    signal.addEventListener("abort", aborted, { once: true });
  });
}
