/** Local edit intent. Media stays in browser memory; this is not a publish approval. */
export const EDIT_LIMITS = {
  clips: 12,
  fileBytes: 32 * 1024 * 1024,
  totalBytes: 160 * 1024 * 1024,
  imagePixels: 12_000_000,
  videoPixels: 8_400_000,
  sourceSeconds: 300,
  timelineSeconds: 180,
  minClipSeconds: 0.5,
  photoSeconds: 30,
  captionCharacters: 120,
  draftBytes: 64 * 1024,
  outputBytes: 128 * 1024 * 1024,
} as const;

export type Ratio = "9:16" | "16:9" | "1:1";
export type SourceRef = {
  name: string;
  size: number;
  lastModified: number;
  sha256: string;
  kind: "image" | "video";
  width: number;
  height: number;
  duration: number;
};
export type EditClip = {
  id: string;
  source: SourceRef;
  start: number;
  end: number;
  caption: string;
  focusX: number;
  focusY: number;
};
export type EditDraft = {
  schema: 1;
  id: string;
  revision: number;
  ratio: Ratio;
  title: string;
  audio: "original" | "muted";
  clips: EditClip[];
};
export type TimelinePosition = {
  clip: EditClip;
  index: number;
  localTime: number;
  sourceTime: number;
};

export function newDraft(): EditDraft {
  return {
    schema: 1,
    id: crypto.randomUUID(),
    revision: 0,
    ratio: "9:16",
    title: "",
    audio: "original",
    clips: [],
  };
}

export function clipDuration(clip: EditClip): number {
  return clip.end - clip.start;
}
export function timelineDuration(clips: EditClip[]): number {
  return clips.reduce((sum, clip) => sum + clipDuration(clip), 0);
}
export function locateTime(
  clips: EditClip[],
  time: number,
): TimelinePosition | null {
  if (!clips.length) return null;
  let remaining = Math.min(
    Math.max(0, Number.isFinite(time) ? time : 0),
    timelineDuration(clips),
  );
  for (let index = 0; index < clips.length; index++) {
    const clip = clips[index]!;
    const duration = clipDuration(clip);
    if (remaining < duration || index === clips.length - 1) {
      const localTime = Math.min(remaining, duration);
      return { clip, index, localTime, sourceTime: clip.start + localTime };
    }
    remaining -= duration;
  }
  return null;
}
export function moveClip(
  clips: EditClip[],
  from: number,
  to: number,
): EditClip[] {
  if (
    !Number.isInteger(from) ||
    !Number.isInteger(to) ||
    from < 0 ||
    to < 0 ||
    from >= clips.length ||
    to >= clips.length
  ) {
    throw new Error("Choose an existing clip position.");
  }
  const result = [...clips];
  const [clip] = result.splice(from, 1);
  result.splice(to, 0, clip!);
  return result;
}
export function renderDimensions(ratio: Ratio): {
  width: number;
  height: number;
} {
  return ratio === "9:16"
    ? { width: 720, height: 1280 }
    : ratio === "16:9"
      ? { width: 1280, height: 720 }
      : { width: 960, height: 960 };
}
export function coverCrop(
  sourceWidth: number,
  sourceHeight: number,
  targetWidth: number,
  targetHeight: number,
  focusX = 0.5,
  focusY = 0.5,
) {
  if (
    ![sourceWidth, sourceHeight, targetWidth, targetHeight].every(
      (n) => Number.isFinite(n) && n > 0,
    )
  ) {
    throw new Error("Media dimensions must be positive.");
  }
  const scale = Math.max(
    targetWidth / sourceWidth,
    targetHeight / sourceHeight,
  );
  const width = targetWidth / scale;
  const height = targetHeight / scale;
  const boundedFocus = (n: number) =>
    Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0.5;
  return {
    x: (sourceWidth - width) * boundedFocus(focusX),
    y: (sourceHeight - height) * boundedFocus(focusY),
    width,
    height,
  };
}
export function mediaKind(
  file: Pick<File, "name" | "type">,
): "image" | "video" {
  // Do not accept SVG/HTML: only raster photos and browser-decodable video belong on the canvas.
  if (["image/jpeg", "image/png", "image/webp"].includes(file.type))
    return "image";
  if (["video/mp4", "video/webm", "video/quicktime"].includes(file.type))
    return "video";
  if (!file.type && /\.(jpe?g|png|webp)$/i.test(file.name)) return "image";
  if (!file.type && /\.(mp4|webm|mov)$/i.test(file.name)) return "video";
  throw new Error(
    `${file.name}: use JPG, PNG, WebP, MP4, WebM, or a browser-decodable MOV.`,
  );
}
export function validateFileBatch(
  files: Pick<File, "name" | "size" | "type">[],
  existing: EditClip[] = [],
): void {
  if (!files.length) throw new Error("Choose at least one photo or video.");
  if (files.length + existing.length > EDIT_LIMITS.clips)
    throw new Error(
      `This local editor supports ${EDIT_LIMITS.clips} clips; this selection would make ${files.length + existing.length}.`,
    );
  let total = existing.reduce((sum, clip) => sum + clip.source.size, 0);
  for (const file of files) {
    mediaKind(file);
    if (!Number.isSafeInteger(file.size) || file.size <= 0)
      throw new Error(
        `${file.name}: the file is empty or its size is invalid.`,
      );
    if (file.size > EDIT_LIMITS.fileBytes)
      throw new Error(
        `${file.name}: ${Math.ceil(file.size / 1024 / 1024)} MiB exceeds the 32 MiB local per-file limit.`,
      );
    total += file.size;
  }
  if (total > EDIT_LIMITS.totalBytes)
    throw new Error(
      `Selected media totals ${Math.ceil(total / 1024 / 1024)} MiB; the local limit is 160 MiB.`,
    );
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error(`Invalid ${label}.`);
  return value as Record<string, unknown>;
}
function boundedNumber(
  value: unknown,
  min: number,
  max: number,
  label: string,
): number {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < min ||
    value > max
  )
    throw new Error(`Invalid ${label}: expected ${min}–${max}.`);
  return value;
}
function boundedText(
  value: unknown,
  max: number,
  label: string,
  nonempty = false,
): string {
  if (
    typeof value !== "string" ||
    value.length > max ||
    (nonempty && !value.trim()) ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)
  )
    throw new Error(`Invalid ${label}.`);
  if (
    (label === "caption" || label === "title") &&
    value.split("\n").length > 4
  )
    throw new Error(
      `${label === "caption" ? "Captions" : "Titles"} support at most four lines.`,
    );
  return value;
}
function safeInteger(
  value: unknown,
  min: number,
  max: number,
  label: string,
): number {
  const result = boundedNumber(value, min, max, label);
  if (!Number.isSafeInteger(result))
    throw new Error(`Invalid ${label}: expected a whole number.`);
  return result;
}

/** Rebuild allowlisted fields: imported JSON cannot retain URLs, credentials, or unknown state. */
export function validateDraft(value: unknown): EditDraft {
  const draft = record(value, "edit plan");
  if (
    draft.schema !== 1 ||
    !["original", "muted"].includes(String(draft.audio)) ||
    !["9:16", "16:9", "1:1"].includes(String(draft.ratio))
  )
    throw new Error(
      "Unsupported edit plan version, aspect ratio, or audio mode.",
    );
  if (!Array.isArray(draft.clips) || draft.clips.length > EDIT_LIMITS.clips)
    throw new Error("Edit plans support up to 12 clips.");
  const ids = new Set<string>();
  const clips = draft.clips.map((value): EditClip => {
    const clip = record(value, "clip");
    const source = record(clip.source, "source");
    const id = boundedText(clip.id, 100, "clip ID", true);
    if (ids.has(id)) throw new Error("Duplicate clip ID.");
    ids.add(id);
    if (source.kind !== "image" && source.kind !== "video")
      throw new Error("Invalid media kind.");
    const sha256 = boundedText(source.sha256, 64, "content hash");
    if (!/^[a-f0-9]{64}$/.test(sha256))
      throw new Error(
        "A SHA-256 content hash is required for safe file reselection.",
      );
    const width = safeInteger(source.width, 1, 12_000, "source width");
    const height = safeInteger(source.height, 1, 12_000, "source height");
    if (
      width * height >
      (source.kind === "image"
        ? EDIT_LIMITS.imagePixels
        : EDIT_LIMITS.videoPixels)
    )
      throw new Error("Source exceeds the local decoded-pixel limit.");
    const duration = boundedNumber(
      source.duration,
      source.kind === "video" ? 0.5 : 0,
      EDIT_LIMITS.sourceSeconds,
      "source duration",
    );
    if (source.kind === "image" && duration !== 0)
      throw new Error("Photos must have a zero source duration.");
    const start = boundedNumber(
      clip.start,
      0,
      source.kind === "image" ? 0 : duration,
      "trim start",
    );
    const end = boundedNumber(
      clip.end,
      start + EDIT_LIMITS.minClipSeconds,
      source.kind === "image" ? EDIT_LIMITS.photoSeconds : duration,
      "trim end",
    );
    return {
      id,
      source: {
        name: boundedText(source.name, 255, "source name", true),
        size: safeInteger(source.size, 1, EDIT_LIMITS.fileBytes, "file bytes"),
        lastModified: safeInteger(
          source.lastModified,
          0,
          Number.MAX_SAFE_INTEGER,
          "file date",
        ),
        sha256,
        kind: source.kind,
        width,
        height,
        duration,
      },
      start,
      end,
      caption: boundedText(
        clip.caption,
        EDIT_LIMITS.captionCharacters,
        "caption",
      ),
      focusX: boundedNumber(clip.focusX, 0, 1, "horizontal framing"),
      focusY: boundedNumber(clip.focusY, 0, 1, "vertical framing"),
    };
  });
  if (timelineDuration(clips) > EDIT_LIMITS.timelineSeconds + 0.00001)
    throw new Error("The edit exceeds the 180-second local timeline limit.");
  if (
    clips.reduce((sum, clip) => sum + clip.source.size, 0) >
    EDIT_LIMITS.totalBytes
  )
    throw new Error("The edit exceeds the 160 MiB total media limit.");
  return {
    schema: 1,
    id: boundedText(draft.id, 100, "edit ID", true),
    revision: safeInteger(
      draft.revision,
      0,
      Number.MAX_SAFE_INTEGER - 1,
      "revision",
    ),
    ratio: draft.ratio as Ratio,
    title: boundedText(draft.title, 80, "title"),
    audio: draft.audio as EditDraft["audio"],
    clips,
  };
}
export function reviseDraft(
  draft: EditDraft,
  patch: Partial<Pick<EditDraft, "clips" | "title" | "ratio" | "audio">>,
): EditDraft {
  return validateDraft({ ...draft, ...patch, revision: draft.revision + 1 });
}
export function serializeDraft(draft: EditDraft): string {
  return JSON.stringify(validateDraft(draft), null, 2);
}
export function parseDraft(json: string): EditDraft {
  if (new TextEncoder().encode(json).byteLength > EDIT_LIMITS.draftBytes)
    throw new Error("Edit plans must be smaller than 64 KiB.");
  return validateDraft(JSON.parse(json));
}
export function assertSourceMatch(
  expected: SourceRef,
  actual: SourceRef,
): void {
  if (
    expected.sha256 !== actual.sha256 ||
    expected.size !== actual.size ||
    expected.kind !== actual.kind ||
    expected.width !== actual.width ||
    expected.height !== actual.height ||
    Math.abs(expected.duration - actual.duration) > 0.05
  ) {
    throw new Error(
      "This is a different file. Reselect the original media; its complete SHA-256 hash must match the saved edit.",
    );
  }
}
export function assertCurrentRevision(
  expected: Pick<EditDraft, "id" | "revision">,
  current: Pick<EditDraft, "id" | "revision">,
  signal: AbortSignal,
): void {
  if (signal.aborted && signal.reason instanceof Error) throw signal.reason;
  if (
    signal.aborted ||
    expected.id !== current.id ||
    expected.revision !== current.revision
  )
    throw new DOMException(
      "Export cancelled because the edit changed or cancellation was requested.",
      "AbortError",
    );
}
export function formatTime(seconds: number): string {
  const safe =
    Math.round(Math.max(0, Number.isFinite(seconds) ? seconds : 0) * 10) / 10;
  return `${Math.floor(safe / 60)}:${(safe % 60).toFixed(1).padStart(4, "0")}`;
}
