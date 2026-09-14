import type { SourceRef } from "./model";

export type EditOverlay = {
  id: string;
  source: SourceRef;
  start: number;
  end: number;
  caption: string;
  focusX: number;
  focusY: number;
  motion?: "still" | "push_in" | "pull_out" | "pan_left" | "pan_right";
};
// These limits match model. Keep this module's import type-only: model validates
// overlays, so a runtime import back to model would create an initialization cycle.
const LIMITS = {
  count: 12,
  bytes: 128 * 1024 ** 2,
  totalBytes: 512 * 1024 ** 2,
  pixels: 12_000_000,
  seconds: 180,
};
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("The cutaway plan contains an invalid photo overlay.");
  }
  return value as Record<string, unknown>;
}
function number(
  value: unknown,
  min: number,
  max: number,
  label: string,
  integer = false,
): number {
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < min ||
    value > max || integer && !Number.isSafeInteger(value)
  ) throw new Error(`Invalid cutaway ${label}.`);
  return value;
}
function text(
  value: unknown,
  max: number,
  label: string,
  required = false,
): string {
  if (
    typeof value !== "string" || value.length > max ||
    required && !value.trim() ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)
  ) throw new Error(`Invalid cutaway ${label}.`);
  return value;
}
export function validateOverlays(
  value: unknown,
  baseDuration: number,
): EditOverlay[] {
  if (!Array.isArray(value) || value.length > LIMITS.count) {
    throw new Error("Use at most 12 photo cutaways.");
  }
  if (!value.length) return [];
  number(baseDuration, .5, LIMITS.seconds, "base video duration");
  const ids = new Set<string>(), sources = new Map<string, SourceRef>();
  let previousEnd = 0;
  const overlays = value.map((raw) => {
    const row = record(raw),
      image = record(row.source),
      id = text(row.id, 100, "ID", true);
    if (ids.has(id)) throw new Error("Each photo cutaway needs a unique ID.");
    ids.add(id);
    if (image.kind !== "image" || image.duration !== 0) {
      throw new Error("Choose a still photo for each cutaway.");
    }
    const width = number(image.width, 1, 12000, "photo width", true),
      height = number(image.height, 1, 12000, "photo height", true);
    if (width * height > LIMITS.pixels) {
      throw new Error("A cutaway photo exceeds the 12-million-pixel limit.");
    }
    if (
      typeof image.sha256 !== "string" || !/^[a-f0-9]{64}$/i.test(image.sha256)
    ) {
      throw new Error(
        "Save the complete source photo before adding a cutaway.",
      );
    }
    const source: SourceRef = {
      name: text(image.name, 255, "filename", true),
      size: number(image.size, 1, LIMITS.bytes, "file size", true),
      lastModified: number(
        image.lastModified,
        0,
        Number.MAX_SAFE_INTEGER,
        "file date",
        true,
      ),
      sha256: image.sha256.toLowerCase(),
      kind: "image",
      width,
      height,
      duration: 0,
    };
    const previous = sources.get(source.sha256);
    if (
      previous &&
      (previous.size !== source.size || previous.width !== width ||
        previous.height !== height)
    ) {
      throw new Error(
        "A repeated cutaway photo has inconsistent source details.",
      );
    }
    sources.set(source.sha256, source);
    const start = number(
        row.start,
        0,
        Math.min(baseDuration, LIMITS.seconds),
        "start",
      ),
      end = number(
        row.end,
        start + .5,
        Math.min(baseDuration, LIMITS.seconds),
        "end",
      );
    if (start < previousEnd) {
      throw new Error(
        "Photo cutaways must stay in time order without overlapping.",
      );
    }
    previousEnd = end;
    const motion = row.motion;
    if (
      motion !== undefined &&
      !["still", "push_in", "pull_out", "pan_left", "pan_right"].includes(
        String(motion),
      )
    ) throw new Error("Choose a supported photo framing motion.");
    return {
      id,
      source,
      start,
      end,
      caption: text(row.caption, 120, "caption"),
      focusX: number(row.focusX, 0, 1, "horizontal framing"),
      focusY: number(row.focusY, 0, 1, "vertical framing"),
      ...(motion !== undefined
        ? { motion: motion as EditOverlay["motion"] }
        : {}),
    };
  });
  if (
    [...sources.values()].reduce((sum, source) => sum + source.size, 0) >
      LIMITS.totalBytes
  ) throw new Error("Cutaway photos exceed the 512 MiB total source limit.");
  return overlays;
}

/** Cutaways cover only their interval; the underlying video/audio keep running. */
export function locateOverlay(
  overlays: EditOverlay[],
  time: number,
): EditOverlay | null {
  if (!Number.isFinite(time) || time < 0) return null;
  return overlays.find((overlay) =>
    time >= overlay.start && time < overlay.end
  ) ?? null;
}
export function overlaySources(overlays: EditOverlay[]): SourceRef[] {
  return [
    ...new Map(
      overlays.map((overlay) => [overlay.source.sha256, overlay.source]),
    ).values(),
  ].map((source) => ({ ...source }));
}
