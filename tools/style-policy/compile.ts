import { REEL_MOTIONS } from "../../services/supabase/functions/ai-video/motion.ts";
import {
  FACE_LEAD_SECONDS,
  FACE_TAIL_SECONDS,
  MAX_BROLL_SECONDS,
  MAX_BROLL_SHARE,
  MAX_CLIP_SECONDS,
  MAX_TRANSCRIPT_PHRASES,
  MAX_WINDOWS,
  MIN_BROLL_SECONDS,
  MIN_CLIP_SECONDS,
  MIN_FACE_GAP_SECONDS,
} from "../../services/supabase/functions/ai-copy/agentreel.ts";
import {
  MAX_OVERLAY_CHARS,
  MAX_OVERLAY_WORDS,
  MAX_PHOTO_ID_CHARS,
  MAX_SHOT_SECONDS,
  MAX_SHOTS,
  MIN_SHOT_SECONDS,
  overlayWordCount,
} from "../../services/supabase/functions/ai-copy/shotlist.ts";
import {
  check,
  digest,
  frozen,
  hash,
  list,
  number,
  object,
  oneOf,
  text,
  unique,
} from "./common.ts";
import { resolveStyle } from "./policy.ts";

function caption(value: unknown): void {
  check(
    overlayWordCount(text(value, 0, MAX_OVERLAY_CHARS)) <= MAX_OVERLAY_WORDS,
    "caption word limit",
  );
}
function ticks(value: unknown, max: number): number {
  const seconds = number(value, 0, max);
  // Check the existing tenth-second wire precision; never round the raw EDL.
  check(
    Math.abs(seconds * 10 - Math.round(seconds * 10)) < 1e-9,
    "timestamp is not a tenth-second boundary",
  );
  return Math.round(seconds * 10);
}
export function validateEDL(raw: unknown): Readonly<Record<string, unknown>> {
  check(raw !== null && typeof raw === "object", "EDL required");
  const mode = Object.getOwnPropertyDescriptor(raw, "mode")?.value;
  if (mode === "photo_sequence") {
    const edl = object(raw, ["schema_version", "mode", "shots"]);
    check(edl.schema_version === 1, "unknown EDL version");
    const shots = list(edl.shots, 1, MAX_SHOTS).map((item) => {
      const shot = object(item, [
        "photo_id",
        "room",
        "motion",
        "seconds",
        "on_screen_text",
      ]);
      text(shot.photo_id, 1, MAX_PHOTO_ID_CHARS);
      text(shot.room, 0, 80);
      oneOf(shot.motion, REEL_MOTIONS);
      number(shot.seconds, MIN_SHOT_SECONDS, MAX_SHOT_SECONDS, true);
      caption(shot.on_screen_text);
      return shot;
    });
    unique(shots.map((s) => s.photo_id));
    return frozen(edl);
  }
  check(mode === "recorded_agent", "unknown EDL mode");
  const edl = object(raw, [
    "schema_version",
    "mode",
    "clip_seconds",
    "original_audio_sha256",
    "phrase_boundaries",
    "photos",
    "cutaways",
  ]);
  check(edl.schema_version === 1, "unknown EDL version");
  const clip = number(edl.clip_seconds, MIN_CLIP_SECONDS, MAX_CLIP_SECONDS);
  digest(edl.original_audio_sha256);
  const boundaries = list(edl.phrase_boundaries, 1, MAX_TRANSCRIPT_PHRASES).map(
    (n) => ticks(n, clip),
  );
  check(
    boundaries.every((n, i) => i === 0 || n > boundaries[i - 1]),
    "duplicate or unordered phrase boundary",
  );
  const photos = list(edl.photos, 1, MAX_SHOTS).map((item) => {
    const photo = object(item, ["id", "room"]);
    text(photo.id, 1, MAX_PHOTO_ID_CHARS);
    text(photo.room, 0, 80);
    return photo;
  });
  unique(photos.map((p) => p.id));
  const windows = list(edl.cutaways, 0, MAX_WINDOWS);
  const ids: string[] = [];
  let lastEnd = -Infinity, coveredTicks = 0, previousPhoto = "";
  for (const item of windows) {
    const w = object(item, [
      "window_id",
      "start",
      "end",
      "photo_id",
      "room",
      "motion",
      "on_screen_text",
    ]);
    ids.push(text(w.window_id, 1, 64));
    const start = ticks(w.start, clip), end = ticks(w.end, clip);
    check(
      start >= FACE_LEAD_SECONDS * 10 &&
        end <= (clip - FACE_TAIL_SECONDS) * 10 + 1e-9,
      "face lead or tail violation",
    );
    check(
      end - start >= MIN_BROLL_SECONDS * 10 &&
        end - start <= MAX_BROLL_SECONDS * 10,
      "cutaway duration violation",
    );
    check(
      start - lastEnd >= MIN_FACE_GAP_SECONDS * 10,
      "face gap or window order violation",
    );
    check(
      boundaries.includes(start) && boundaries.includes(end),
      "window does not match phrase boundaries",
    );
    lastEnd = end;
    const photoId = text(w.photo_id, 0, MAX_PHOTO_ID_CHARS);
    text(w.room, 0, 80);
    caption(w.on_screen_text);
    oneOf(w.motion, REEL_MOTIONS);
    if (!photoId) {
      check(
        w.room === "" && w.on_screen_text === "",
        "empty-photo window must not obscure the agent",
      );
    } else {
      check(
        photos.some((p) => p.id === photoId && p.room === w.room),
        "unknown photo or room mismatch",
      );
      check(photoId !== previousPhoto, "repeated adjacent photo");
      previousPhoto = photoId;
      coveredTicks += end - start;
    }
  }
  unique(ids);
  check(
    coveredTicks <= clip * 10 * MAX_BROLL_SHARE + 1e-9,
    "B-roll share violation",
  );
  return frozen(edl);
}

export async function compileStyle(styleRef: unknown, rawEDL: unknown) {
  // Resolve again here: a caller-supplied resolved object is not trusted authority.
  const decision = await resolveStyle(styleRef);
  const edl = validateEDL(rawEDL);
  const sourceHash = await hash(rawEDL);
  return frozen({
    schema_version: 1,
    stage: "offline-plan",
    rendered: false,
    live_api_applied: false,
    room_safety: "unverified",
    publication_ready: false,
    decision,
    edl,
    source_edl_sha256: sourceHash,
    output_edl_sha256: await hash(edl),
    presentation_intent: decision.kind === "selected"
      ? decision.policy.presentation
      : null,
    applied_effects: [],
    unapplied_effects: [
      "timing",
      "motion",
      "music",
      "grade",
      "transition",
      "caption-treatment",
    ],
    limitations: [
      "No room-veto accessor: vocabulary validation is not room safety.",
      "No renderer, publication, fair-housing clearance or original-audio verification.",
      "Original audio hash is a declaration; no media bytes were read.",
    ],
  });
}
