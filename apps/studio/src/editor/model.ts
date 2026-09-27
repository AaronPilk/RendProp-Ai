import {validateMusic, validateSpeech, type MusicTrack, type SpeechTrack} from "./finishing";
export type {AudioSourceRef, MusicTrack, SpeechTrack} from "./finishing";
import {validateOverlays, type EditOverlay} from "./overlays";
export type {EditOverlay} from "./overlays";
/** Local edit intent. Media stays in browser memory; this is not a publish approval. */
export const EDIT_LIMITS = {
  clips: 12,
  fileBytes: 128 * 1024 * 1024,
  totalBytes: 512 * 1024 * 1024,
  imagePixels: 12_000_000,
  videoPixels: 8_400_000,
  sourceSeconds: 300,
  timelineSeconds: 180,
  minClipSeconds: 0.5,
  photoSeconds: 30,
  captionCharacters: 120,
  draftBytes: 64 * 1024,
  narrationBytes: 16 * 1024 * 1024,
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
export type CaptionStyle = "clean" | "center" | "highlight";
export type Transition = "cut" | "dissolve" | "whip";
export type Narration = { resultId: string; label: string; offset: number; volume: number; wordCaptions: boolean; words: {text: string; start: number; end: number}[] };
export type EditClip = {
  id: string;
  source: SourceRef;
  start: number;
  end: number;
  caption: string;
  focusX: number;
  focusY: number;
  speed?: number;
  captionStyle?: CaptionStyle;
  transition?: Transition;
  motion?: "still" | "push_in" | "pull_out" | "pan_left" | "pan_right";
};
export type EditDraft = {
  schema: 1;
  id: string;
  revision: number;
  ratio: Ratio;
  title: string;
  audio: "original" | "muted";
  clips: EditClip[];
  narration?: Narration;
  music?: MusicTrack;
  speech?: SpeechTrack[];
  overlays?: EditOverlay[];
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

export function draftMedia(draft: EditDraft): (EditClip | EditOverlay)[] { return [...draft.clips, ...(draft.overlays ?? [])]; }

export function clipDuration(clip: EditClip): number {
  return (clip.end - clip.start) / (clip.source.kind === "video" ? (clip.speed ?? 1) : 1);
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
      return { clip, index, localTime, sourceTime: clip.start + localTime * (clip.speed ?? 1) };
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
  // Split clips can refer to one file many times without allocating that file
  // again. New selections remain conservatively counted until their hash is read.
  let total = [...new Map(existing.map(clip => [clip.source.sha256, clip.source])).values()].reduce((sum, source) => sum + source.size, 0);
  for (const file of files) {
    const kind = mediaKind(file);
    if (!Number.isSafeInteger(file.size) || file.size <= 0)
      throw new Error(
        `${file.name}: the file is empty or its size is invalid.`,
      );
    if (file.size > EDIT_LIMITS.fileBytes)
      throw new Error(
        `${file.name}: ${Math.ceil(file.size / 1024 / 1024)} MiB exceeds the 128 MiB per-file limit. ${kind === "video" ? "For a video up to 2 GiB and three minutes, open “Large video? Create an editing copy” below the preview. Your original stays on your device." : "Export a smaller JPG, PNG or WebP copy first and keep your original."}`,
      );
    total += file.size;
  }
  if (total > EDIT_LIMITS.totalBytes)
    throw new Error(
      `Selected media totals ${Math.ceil(total / 1024 / 1024)} MiB; the local limit is 512 MiB.`,
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

function allowedChoice<T extends string>(value: unknown, choices: readonly T[], label: string): T {
  if (!choices.includes(value as T)) throw new Error(`Invalid ${label}.`);
  return value as T;
}
export function validateNarration(value: unknown): Narration {
  const row = record(value, "narration");
  if (typeof row.resultId !== "string" || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(row.resultId)) throw new Error("Choose a saved narration result.");
  if (typeof row.wordCaptions !== "boolean" || !Array.isArray(row.words) || row.words.length > 1500) throw new Error("Invalid narration captions.");
  let previous = 0;
  const words = row.words.map(value => {
    const word = record(value, "narration word");
    const start = boundedNumber(word.start, previous, 7200, "word start"), end = boundedNumber(word.end, start, 7200, "word end"); previous = start;
    return {text: boundedText(word.text, 200, "word", true), start, end};
  });
  return {resultId: row.resultId, label: boundedText(row.label, 100, "narration label"), offset: boundedNumber(row.offset, 0, 180, "narration start"), volume: boundedNumber(row.volume, 0, 1, "narration volume"), wordCaptions: row.wordCaptions, words};
}
export function transitionSeconds(clip: EditClip): number {
  return Math.min(clipDuration(clip) / 2, clip.transition === "dissolve" ? 0.28 : clip.transition === "whip" ? 0.18 : 0);
}
export function narrationCaption(narration: Narration | undefined, time: number): string {
  if (!narration?.wordCaptions) return "";
  const local = time - narration.offset;
  const index = narration.words.findIndex(word => local >= word.start && local < word.end);
  if (index < 0) return "";
  const start = Math.floor(index / 5) * 5;
  return narration.words.slice(start, start + 5).map(word => word.text).join(" ");
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
      ...(clip.speed !== undefined ? {speed: boundedNumber(clip.speed, source.kind === "image" ? 1 : 0.25, source.kind === "image" ? 1 : 4, "clip speed")} : {}),
      ...(clip.captionStyle !== undefined ? {captionStyle: allowedChoice(clip.captionStyle, ["clean", "center", "highlight"] as const, "caption style")} : {}),
      ...(clip.motion !== undefined ? {motion: allowedChoice(clip.motion, ["still", "push_in", "pull_out", "pan_left", "pan_right"] as const, "photo motion")} : {}),
      ...(clip.transition !== undefined ? {transition: allowedChoice(clip.transition, ["cut", "dissolve", "whip"] as const, "transition")} : {}),
    };
  });
  if (timelineDuration(clips) > EDIT_LIMITS.timelineSeconds + 0.00001)
    throw new Error("The edit exceeds the 180-second local timeline limit.");
  const overlays = draft.overlays !== undefined ? validateOverlays(draft.overlays, timelineDuration(clips)) : undefined;
  if (overlays?.some(overlay => ids.has(overlay.id))) throw new Error("A cutaway and a base clip cannot share the same ID.");
  const allSources = new Map<string, SourceRef>();
  for (const item of [...clips, ...(overlays ?? [])]) {
    const previous = allSources.get(item.source.sha256);
    if (previous) assertSourceMatch(previous, item.source);
    allSources.set(item.source.sha256, item.source);
  }
  if ([...allSources.values()].reduce((sum, source) => sum + source.size, 0) > EDIT_LIMITS.totalBytes) throw new Error("Base footage and cutaway photos exceed the 512 MiB total source limit.");
  const validated: EditDraft = {
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
    ...(overlays ? {overlays} : {}),
    ...(draft.music != null ? {music: validateMusic(draft.music)} : {}),
    ...(draft.speech != null ? {speech: validateSpeech(draft.speech).filter(track => clips.some(clip => clip.source.kind === "video" && clip.source.sha256 === track.sourceSha256 && Math.abs(clip.source.duration - track.sourceDuration) <= .1))} : {}),
    ...(draft.narration != null ? {narration: validateNarration(draft.narration)} : {}),
  };
  if (new TextEncoder().encode(JSON.stringify(validated)).byteLength > EDIT_LIMITS.draftBytes) throw new Error("The edit plan exceeds 64 KiB. Shorten its text or narration captions.");
  return validated;
}
export function reviseDraft(
  draft: EditDraft,
  patch: Partial<Pick<EditDraft, "clips" | "title" | "ratio" | "audio" | "narration" | "overlays" | "music" | "speech">>,
): EditDraft {
  return validateDraft({ ...draft, ...patch, revision: draft.revision + 1 });
}
export function serializeDraft(draft: EditDraft): string {
  const checked = validateDraft(draft), pretty = JSON.stringify(checked, null, 2);
  return new TextEncoder().encode(pretty).byteLength <= EDIT_LIMITS.draftBytes ? pretty : JSON.stringify(checked);
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
