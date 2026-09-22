export type SourceImage = {
  file: File;
  base64: string;
  mime: "image/jpeg";
  preview: string;
  originalAssetId?: string;
};
function aborted(signal?: AbortSignal) {
  if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
}
export async function prepareImage(
  file: File,
  signal?: AbortSignal,
): Promise<SourceImage> {
  if (
    !["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
    file.size > 32 * 1024 * 1024 || !file.size
  ) throw new Error("Choose a JPEG, PNG or WebP photo under 32 MB.");
  aborted(signal);
  const image = await createImageBitmap(file);
  try {
    aborted(signal);
    if (
      !image.width || !image.height || image.width * image.height > 100_000_000
    ) throw new Error("This photo is too large to edit in your browser.");
    const factor = Math.min(1, 1536 / Math.max(image.width, image.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.width * factor));
    canvas.height = Math.max(1, Math.round(image.height * factor));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("This browser cannot prepare the photo.");
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    const data = canvas.toDataURL("image/jpeg", .9);
    return {
      file,
      base64: data.slice(data.indexOf(",") + 1),
      mime: "image/jpeg",
      preview: data,
    };
  } finally {
    image.close();
  }
}
export function editedImage(value: string, mime: string): File {
  if (
    !["image/jpeg", "image/png", "image/webp"].includes(mime) || !value ||
    value.length > 32 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)
  ) throw new Error("The photo service returned an unreadable image.");
  const raw = atob(value), bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return new File(
    [bytes],
    `rendprop-edit.${
      mime === "image/jpeg" ? "jpg" : mime === "image/png" ? "png" : "webp"
    }`,
    { type: mime },
  );
}
export async function imageFromURL(
  url: string,
  label: string,
  signal?: AbortSignal,
): Promise<SourceImage> {
  const response = await fetch(url, {
    credentials: "omit",
    redirect: "error",
    signal,
  });
  if (!response.ok) {
    throw new Error(
      "This photo link has expired. Refresh the listing and try again.",
    );
  }
  if (Number(response.headers.get("content-length")) > 32 * 1024 * 1024) {
    throw new Error("This photo is too large. Import a copy under 32 MB.");
  }
  const blob = await response.blob();
  const mime = blob.type.split(";")[0]!.trim().toLowerCase();
  const extension = ({
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
  } as Record<string, string>)[mime];
  if (!extension) {
    throw new Error(
      "This photo format cannot be edited in Studio. Import a JPEG, PNG or WebP copy.",
    );
  }
  const filename = `${
    label.replace(/[\\/]/g, "-").replace(/\.[^.]+$/, "") || "property"
  }.${extension}`;
  return prepareImage(new File([blob], filename, { type: mime }), signal);
}
export function downloadText(
  name: string,
  content: string,
  type = "text/plain",
) {
  const url = URL.createObjectURL(new Blob([content], { type })),
    a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export async function videoFrames(
  url: string,
  signal?: AbortSignal,
): Promise<
  { frames: { at: string; b64: string; mime: string }[]; seconds: number }
> {
  const video = document.createElement("video");
  video.crossOrigin = "anonymous";
  video.preload = "auto";
  video.muted = true;
  video.src = url;
  function wait(event: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () =>
          done(
            new Error(
              "The clip could not be read for quality review. Refresh its media link and try again.",
            ),
          ),
        25_000,
      );
      function done(error?: unknown) {
        clearTimeout(timer);
        video.removeEventListener(event, ready);
        video.removeEventListener("error", failed);
        signal?.removeEventListener("abort", cancel);
        error ? reject(error) : resolve();
      }
      function ready() {
        done();
      }
      function failed() {
        done(new Error("The clip could not be opened."));
      }
      function cancel() {
        done(new DOMException("Cancelled", "AbortError"));
      }
      video.addEventListener(event, ready, { once: true });
      video.addEventListener("error", failed, { once: true });
      signal?.addEventListener("abort", cancel, { once: true });
      if (signal?.aborted) cancel();
    });
  }
  try {
    if (video.readyState < 1) await wait("loadedmetadata");
    const seconds = video.duration;
    if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 180) {
      throw new Error(
        "Choose a completed clip under three minutes for quality review.",
      );
    }
    const canvas = document.createElement("canvas"),
      scale = Math.min(1, 640 / Math.max(video.videoWidth, video.videoHeight));
    canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
    canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("This browser cannot review the clip.");
    const frames = [];
    for (
      const [at, time] of [["first", Math.min(.1, seconds / 10)], [
        "middle",
        seconds / 2,
      ], ["last", Math.max(0, seconds - .15)]] as const
    ) {
      aborted(signal);
      const ready = wait("seeked");
      video.currentTime = time;
      await ready;
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      frames.push({
        at,
        b64: canvas.toDataURL("image/jpeg", .8).split(",")[1]!,
        mime: "image/jpeg",
      });
    }
    return { frames, seconds };
  } finally {
    video.removeAttribute("src");
    video.load();
  }
}
