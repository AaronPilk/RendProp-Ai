import type { Shot } from "../creative/model";
import type { CaptionStyle } from "../../editor/model";

/** Version-one semantic setup saved by iPhone build 26; it is not a rendered timeline. */
export type NativeReel = {
  schema: 1;
  kind: "native-reel-setup";
  portrait: boolean;
  titleCard: boolean;
  shotCaptions: boolean;
  captionStyle: "off" | "lowerThird" | "punchCard" | "highlightBox";
  transition: "cut" | "dissolve" | "whip";
  motionPrompt: string;
  script: string;
  tone: "warm" | "punchy" | "luxury";
  wordCaptions: boolean;
  voiceMode: "off" | "myVoice" | "aiVoice";
  voiceResultId: string | null;
  localNarration: boolean;
  photos: { localId: string; sourcePhotoId: string | null }[];
  localExtraClipCount: number;
  updatedAt: string;
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const invalid = () => new Error("The saved iPhone setup could not be read. Open it on your iPhone and save the setup again.");
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid();
  return value as Record<string, unknown>;
}
function text(value: unknown, limit: number): string {
  if (typeof value !== "string" || value.length > limit) throw invalid();
  return value;
}
function flag(value: unknown): boolean { if (typeof value !== "boolean") throw invalid(); return value; }
function choice<T extends string>(value: unknown, choices: readonly T[]): T {
  if (typeof value !== "string" || !choices.includes(value as T)) throw invalid();
  return value as T;
}
function optionalId(value: unknown): string | null {
  // Swift encodeIfPresent omits nil fields. Explicit null is valid too.
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !UUID.test(value)) throw invalid();
  return value.toLowerCase();
}

export function decodeNativeReel(value: unknown): NativeReel {
  const raw = record(value);
  if (raw.schema !== 1 || raw.kind !== "native-reel-setup" || !Array.isArray(raw.photos) || raw.photos.length > 100 ||
    !Number.isInteger(raw.localExtraClipCount) || (raw.localExtraClipCount as number) < 0 || (raw.localExtraClipCount as number) > 100) throw invalid();
  const photos = raw.photos.map(value => {
    const photo = record(value), localId = text(photo.localId, 120);
    if (!localId || /[\\/:]/.test(localId)) throw invalid();
    return { localId, sourcePhotoId: optionalId(photo.sourcePhotoId) };
  });
  if (new Set(photos.map(photo => photo.localId)).size !== photos.length) throw invalid();
  const updatedAt = text(raw.updatedAt, 64);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(updatedAt) || !Number.isFinite(Date.parse(updatedAt))) throw invalid();
  return {
    schema: 1, kind: "native-reel-setup", portrait: flag(raw.portrait), titleCard: flag(raw.titleCard),
    shotCaptions: flag(raw.shotCaptions), captionStyle: choice(raw.captionStyle, ["off", "lowerThird", "punchCard", "highlightBox"]),
    transition: choice(raw.transition, ["cut", "dissolve", "whip"]), motionPrompt: text(raw.motionPrompt, 4000), script: text(raw.script, 100_000),
    tone: choice(raw.tone, ["warm", "punchy", "luxury"]), wordCaptions: flag(raw.wordCaptions),
    voiceMode: choice(raw.voiceMode, ["off", "myVoice", "aiVoice"]), voiceResultId: optionalId(raw.voiceResultId), localNarration: flag(raw.localNarration),
    photos, localExtraClipCount: raw.localExtraClipCount as number, updatedAt,
  };
}

export function nativeCaptionStyle(style: NativeReel["captionStyle"]): CaptionStyle | undefined {
  return ({ off: undefined, lowerThird: "clean", punchCard: "center", highlightBox: "highlight" } as const)[style];
}

export function nativeReelShots(recipe: NativeReel): Shot[] {
  // Revalidate so callers cannot accidentally bypass completeness checks with a cast.
  const checked = decodeNativeReel(recipe);
  if (checked.localExtraClipCount > 0) throw new Error("This setup includes clips saved only on the iPhone. Upload those clips to this listing and build the complete sequence in Studio, or save an iPhone setup without the extra clips.");
  if (!checked.photos.length) throw new Error("Choose photos on your iPhone and save the setup again before importing a sequence.");
  if (checked.photos.some(photo => photo.sourcePhotoId === null)) throw new Error("Some selected photos are saved only on the iPhone. Choose Upload photos on your iPhone, let the upload finish, and choose Save setup again. No photos were skipped.");
  return checked.photos.map((photo, index) => ({
    photoId: photo.sourcePhotoId!, order: index + 1, room: "", motion: "still", seconds: 3, caption: "", voiceLine: "",
  }));
}
