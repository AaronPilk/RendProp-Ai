// ai-chapters — post-processing of the model's raw chapter list.
//
// PURE. No env, no network, no Supabase client: everything here is a function of
// its arguments, which is what makes `postprocess_test.ts` able to cover the
// rules that actually decide what the agent sees.
//
// A video model given a 90-second walkthrough will happily emit sixteen
// "chapters", three of them 0.4 s long, two of them the same room twice in a
// row, one of them starting after the video ends, and one of them describing
// "a warm family home in a great school district". None of that may reach a
// room tagger. The order below is deliberate:
//
//   1. parse      — tolerate strings, "MM:SS", nulls; drop only what is unusable
//   2. gate       — assertMarketingCopy() over every description (§4)
//   3. snap       — labels onto the app's own quick-tag vocabulary
//   4. clamp      — into [0, video_seconds]
//   5. sort       — by start_s
//   6. dedupe     — merge ADJACENT same-label runs
//   7. close      — fill/repair end_s from the next chapter's start
//   8. merge      — anything under MIN_CHAPTER_SECONDS into a neighbour
//   9. cap        — keep the `maxChapters` longest, then re-sort and re-close
//
// Every reduction that changes what the agent sees adds a WARNING string, which
// the contract requires the app to show verbatim.

import { assertMarketingCopy } from "../_shared/fairhousing.ts";

/** A room shorter than this is camera pan, not a room. */
export const MIN_CHAPTER_SECONDS = 3;

/** Beyond this a "label" is prose, not a room name. */
export const MAX_LABEL_CHARS = 32;

/** Descriptions are a caption seed, not an essay. */
export const MAX_DESCRIPTION_CHARS = 240;

export interface Chapter {
  label: string;
  start_s: number;
  end_s: number;
  /** 0…1 from the model, or null when it sent none. */
  confidence: number | null;
  /** null when the model sent none OR when it failed the fair-housing gate. */
  description: string | null;
}

export interface PostprocessOptions {
  /** Duration of the SUBMITTED asset. Everything is clamped into [0, this]. */
  videoSeconds: number;
  /** Hard ceiling on how many chapters come back (1…24). */
  maxChapters: number;
  /** Canonical room labels for this listing's space type, plus "Other". */
  allowedLabels: string[];
  /** Override only in tests. */
  minChapterSeconds?: number;
}

export interface PostprocessResult {
  chapters: Chapter[];
  warnings: string[];
}

// ── Fair housing ─────────────────────────────────────────────────────────────

/**
 * The FULL marketing-copy gate (script rules + the image-prompt denylist), used
 * as a PREDICATE. `assertMarketingCopy` throws by design — here a failure means
 * "drop this one string", never "fail the agent's whole request", because the
 * offending text was written by a model, not by the agent, and there is nothing
 * for them to fix.
 */
export function passesFairHousing(text: string | null | undefined): boolean {
  try {
    assertMarketingCopy(text, "This AI room description");
    return true;
  } catch {
    return false;
  }
}

/**
 * A ROOM-LABEL-only refusal list, on top of the shared gate.
 *
 * `_shared/fairhousing.ts` is written for prompts and marketing scripts, and it
 * is right for those — but it does not catch "Prayer room", because nobody was
 * ever going to type that as a photo prompt. A room LABELLER can, and a chapter
 * chip is exactly where it would land: printed on a public tour, under the
 * agent's licence, naming the occupant's religion.
 *
 * That file is shared and frozen this wave, so the narrow, feature-specific rule
 * lives here. It is deliberately over-broad: a refused label falls back to
 * "Other", which costs the agent three seconds of typing. The reverse mistake
 * costs them a fair-housing complaint.
 *
 * NOT listed, on purpose: accessibility words (accessible, wheelchair, ramp,
 * roll-in). Describing accessible FEATURES is lawful and useful — HUD wants
 * those disclosed, not hidden.
 */
const ROOM_LABEL_REFUSALS: RegExp[] = [
  // Religion / worship
  /\b(pray(er|ing)?|worship|devotional|shrine|altar|chapel|church|mosque|synagogue|temple|sanctuary)\b/i,
  // Occupant identity, usually as a possessive: "the kids' room", "Nanny's room"
  /\b(nanny|nannies|maids?|servants?|au\s?pair|housekeepers?)\b/i,
  /\b(grandma|grandpa|granny|grandmother|grandfather|nan|nana)('?s)?\b/i,
  /\b(kids?|child|childs|children)('|'s|s')?\s*(room|bedroom|suite|wing|area|space)\b/i,
  /\b(boys?|girls?)('|'s|s')\s*(room|bedroom)\b/i,
  /\b(nurser(y|ies)|playroom|baby'?s?\s+room)\b/i,
];

/** True when a room LABEL is safe to show. Runs the shared gate first. */
export function isSafeRoomLabel(label: string): boolean {
  if (!passesFairHousing(label)) return false;
  return !ROOM_LABEL_REFUSALS.some((re) => re.test(label));
}

// ── Label vocabulary ─────────────────────────────────────────────────────────

/** Lowercase, single-spaced, punctuation-free — the matching key for a label. */
function normalizeLabel(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/**
 * What a video model actually calls these rooms, mapped onto the app's own
 * vocabulary. Applied ONLY when the target label is in the listing's allowed
 * set, so a restaurant never gets "Primary" and a gym never gets "Backyard".
 */
const SYNONYMS: Record<string, string> = {
  "master": "Primary",
  "master bedroom": "Primary",
  "master suite": "Primary",
  "primary bedroom": "Primary",
  "primary suite": "Primary",
  "owners suite": "Primary",
  "guest bedroom": "Bedroom",
  "second bedroom": "Bedroom",
  "third bedroom": "Bedroom",
  "bedroom 2": "Bedroom",
  "bedroom 3": "Bedroom",
  "bathroom": "Bath",
  "full bath": "Bath",
  "half bath": "Bath",
  "powder room": "Bath",
  "ensuite": "Bath",
  "en suite": "Bath",
  "washroom": "Bath",
  "foyer": "Entry",
  "entryway": "Entry",
  "entry hall": "Entry",
  "front door": "Entry",
  "front entrance": "Entrance",
  "living": "Living Room",
  "living area": "Living Room",
  "family room": "Living Room",
  "great room": "Living Room",
  "den": "Living Room",
  "sitting room": "Living Room",
  "dining room": "Dining",
  "dining area": "Dining",
  "breakfast nook": "Dining",
  "kitchen island": "Kitchen",
  "galley kitchen": "Kitchen",
  "study": "Office",
  "home office": "Office",
  "back yard": "Backyard",
  "rear yard": "Backyard",
  "yard": "Backyard",
  "garden": "Backyard",
  "patio": "Backyard",
  "deck": "Backyard",
  "front yard": "Exterior",
  "front of house": "Exterior",
  "street view": "Exterior",
  "curb appeal": "Exterior",
  "facade": "Exterior",
  "driveway": "Exterior",
  "carport": "Garage",
  "main floor": "Main Floor",
  "gym floor": "Main Floor",
  "weight room": "Weights",
  "free weights": "Weights",
  "locker rooms": "Locker Room",
  "changing room": "Locker Room",
  "toilets": "Restrooms",
  "bar area": "Bar",
  "stockroom": "Backroom",
  "store room": "Backroom",
  "storeroom": "Backroom",
  "cash wrap": "Checkout",
  "tills": "Checkout",
  "main room": "Main Area",
  "lobby": "Reception",
};

export interface SnappedLabel {
  label: string;
  /** true when the label is not in the allowed set and was kept as free text. */
  offVocabulary: boolean;
}

/**
 * Snap a model label onto the listing's vocabulary.
 *   • exact (normalized) match      → the canonical spelling
 *   • known synonym of an allowed label → that label
 *   • otherwise: kept verbatim IF it clears the fair-housing gate and is short,
 *     else "Other".
 * A room label is never allowed to smuggle in a person, a religion or a
 * neighborhood — that is the whole point of the last branch.
 */
export function snapLabel(raw: unknown, allowedLabels: string[]): SnappedLabel {
  const text = typeof raw === "string" ? raw.trim().replace(/\s+/g, " ") : "";
  if (!text) return { label: "Other", offVocabulary: false };

  const key = normalizeLabel(text);
  if (!key) return { label: "Other", offVocabulary: false };

  for (const allowed of allowedLabels) {
    if (normalizeLabel(allowed) === key) return { label: allowed, offVocabulary: false };
  }

  const synonym = SYNONYMS[key];
  if (synonym) {
    for (const allowed of allowedLabels) {
      if (normalizeLabel(allowed) === normalizeLabel(synonym)) {
        return { label: allowed, offVocabulary: false };
      }
    }
  }

  if (text.length <= MAX_LABEL_CHARS && isSafeRoomLabel(text)) {
    return { label: text, offVocabulary: true };
  }
  return { label: "Other", offVocabulary: false };
}

// ── Parsing ──────────────────────────────────────────────────────────────────

/**
 * Seconds from whatever the model sent. Accepts a number, a numeric string, and
 * the "MM:SS" / "H:MM:SS" the video docs teach the model to speak — a chapter
 * that arrives as "01:15" is a good chapter, not a parse failure.
 */
export function toSeconds(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!s) return null;

  if (/^\d{1,2}:\d{1,2}(:\d{1,2})?(\.\d+)?$/.test(s)) {
    const parts = s.split(":").map(Number);
    if (parts.some((p) => !Number.isFinite(p))) return null;
    const secs = parts.length === 3
      ? parts[0] * 3600 + parts[1] * 60 + parts[2]
      : parts[0] * 60 + parts[1];
    return Number.isFinite(secs) ? secs : null;
  }

  const n = Number(s.replace(/s$/i, ""));
  return Number.isFinite(n) ? n : null;
}

function toConfidence(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  if (!Number.isFinite(n)) return null;
  return Math.min(1, Math.max(0, n));
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

// ── The pipeline ─────────────────────────────────────────────────────────────

/**
 * Turn the model's raw `chapters` array into the bounded, sorted, gated list the
 * app pre-fills the tagger with. Never throws: a malformed model response is an
 * empty chapter list plus a warning, not a 500 the agent has to read.
 */
export function postprocessChapters(raw: unknown, opts: PostprocessOptions): PostprocessResult {
  const warnings: string[] = [];
  const minSeconds = opts.minChapterSeconds ?? MIN_CHAPTER_SECONDS;
  // A zero, negative, or unparseable ceiling is nonsense input, not a request
  // for one chapter — fall back to the default rather than to a stub of a tour.
  const askedFor = Math.round(Number(opts.maxChapters));
  const maxChapters = Number.isFinite(askedFor) && askedFor > 0 ? Math.min(24, askedFor) : 12;
  const duration = Number.isFinite(opts.videoSeconds) && opts.videoSeconds > 0
    ? opts.videoSeconds
    : 0;

  if (duration <= 0) {
    return { chapters: [], warnings: ["No video duration was available, so no chapters were kept."] };
  }
  if (!Array.isArray(raw)) {
    return { chapters: [], warnings: ["The model returned no chapter list."] };
  }

  // 1–4. parse + gate + snap + clamp -----------------------------------------
  let dropped = 0;
  let gated = 0;
  let offVocab = 0;
  const parsed: Chapter[] = [];

  for (const entry of raw as Array<Record<string, unknown>>) {
    if (!entry || typeof entry !== "object") {
      dropped++;
      continue;
    }
    const start = toSeconds(entry.start_s ?? entry.startS ?? entry.start ?? entry.t);
    if (start === null) {
      dropped++;
      continue;
    }
    // A chapter that starts after the video ends is a hallucinated timestamp,
    // not a room — clamping it to the last frame would invent a tag.
    if (start > duration + 0.5) {
      dropped++;
      continue;
    }

    const snapped = snapLabel(entry.label ?? entry.name ?? entry.room, opts.allowedLabels);
    if (snapped.offVocabulary) offVocab++;

    const rawDescription = typeof entry.description === "string"
      ? entry.description.trim().slice(0, MAX_DESCRIPTION_CHARS)
      : "";
    let description: string | null = null;
    if (rawDescription) {
      if (passesFairHousing(rawDescription)) {
        description = rawDescription;
      } else {
        // The CHAPTER survives; only the offending sentence is dropped. A room
        // that exists does not stop existing because the model described it badly.
        gated++;
      }
    }

    const endRaw = toSeconds(entry.end_s ?? entry.endS ?? entry.end);
    const clampedStart = Math.min(duration, Math.max(0, start));
    const clampedEnd = endRaw === null ? clampedStart : Math.min(duration, Math.max(0, endRaw));

    parsed.push({
      label: snapped.label,
      start_s: clampedStart,
      end_s: clampedEnd,
      confidence: toConfidence(entry.confidence),
      description,
    });
  }

  if (dropped > 0) warnings.push(`${dropped} suggestion${dropped === 1 ? "" : "s"} had no usable timestamp and ${dropped === 1 ? "was" : "were"} dropped.`);
  if (gated > 0) warnings.push(`${gated} AI description${gated === 1 ? "" : "s"} did not meet the fair-housing rules and ${gated === 1 ? "was" : "were"} removed.`);
  if (offVocab > 0) warnings.push(`${offVocab} suggestion${offVocab === 1 ? "" : "s"} used a room name outside your usual list — check ${offVocab === 1 ? "it" : "them"}.`);

  if (parsed.length === 0) return { chapters: [], warnings };

  // 5. sort ------------------------------------------------------------------
  parsed.sort((a, b) => (a.start_s - b.start_s) || (a.end_s - b.end_s));

  // 6. merge ADJACENT same-label runs ----------------------------------------
  let merged = 0;
  const deduped: Chapter[] = [];
  for (const c of parsed) {
    const prev = deduped[deduped.length - 1];
    if (prev && normalizeLabel(prev.label) === normalizeLabel(c.label)) {
      prev.end_s = Math.max(prev.end_s, c.end_s, c.start_s);
      prev.confidence = maxConfidence(prev.confidence, c.confidence);
      prev.description = prev.description ?? c.description;
      merged++;
      continue;
    }
    deduped.push({ ...c });
  }

  // 7. close end_s -----------------------------------------------------------
  closeEnds(deduped, duration);

  // 8. merge anything under the floor ---------------------------------------
  let list = deduped;
  for (let pass = 0; pass < 8; pass++) {
    const next = mergeShort(list, minSeconds, duration);
    merged += next.merged;
    list = next.chapters;
    if (next.merged === 0) break;
  }
  if (merged > 0) {
    warnings.push(`${merged} short or repeated suggestion${merged === 1 ? " was" : "s were"} merged into ${merged === 1 ? "its" : "their"} neighbour${merged === 1 ? "" : "s"}.`);
  }

  // 9. cap -------------------------------------------------------------------
  if (list.length > maxChapters) {
    const cut = list.length - maxChapters;
    // Keep the rooms the camera actually spent time in. Confidence only breaks
    // a tie: a long low-confidence room still beats a 3-second high-confidence one.
    const kept = [...list]
      .sort((a, b) =>
        (b.end_s - b.start_s) - (a.end_s - a.start_s) ||
        ((b.confidence ?? 0) - (a.confidence ?? 0)) ||
        (a.start_s - b.start_s)
      )
      .slice(0, maxChapters);
    kept.sort((a, b) => (a.start_s - b.start_s) || (a.end_s - b.end_s));
    closeEnds(kept, duration);
    list = kept;
    warnings.push(`${cut} extra suggestion${cut === 1 ? " was" : "s were"} trimmed to keep the top ${maxChapters}.`);
  }

  return {
    chapters: list.map((c) => ({
      label: c.label,
      start_s: round3(c.start_s),
      end_s: round3(Math.max(c.start_s, c.end_s)),
      confidence: c.confidence === null ? null : round3(c.confidence),
      description: c.description,
    })),
    warnings,
  };
}

function maxConfidence(a: number | null, b: number | null): number | null {
  if (a === null) return b;
  if (b === null) return a;
  return Math.max(a, b);
}

/**
 * Repair `end_s` in place: a missing/short/overlapping end becomes the next
 * chapter's start (the last one runs to the end of the video). A room ends when
 * the next room begins — that is what a walkthrough IS.
 */
function closeEnds(list: Chapter[], duration: number): void {
  for (let i = 0; i < list.length; i++) {
    const nextStart = i + 1 < list.length ? list[i + 1].start_s : duration;
    const boundary = Math.max(list[i].start_s, Math.min(nextStart, duration));
    if (!(list[i].end_s > list[i].start_s) || list[i].end_s > boundary) {
      list[i].end_s = boundary;
    }
  }
}

/**
 * ONE merge pass. A chapter shorter than `minSeconds` is absorbed by its
 * PREVIOUS neighbour (which simply runs longer); the first chapter has no
 * previous, so it is absorbed by the NEXT one, which then starts earlier.
 * Returns a new array — the caller loops until a pass changes nothing.
 */
function mergeShort(
  list: Chapter[],
  minSeconds: number,
  duration: number,
): { chapters: Chapter[]; merged: number } {
  if (list.length <= 1) return { chapters: list, merged: 0 };

  const out: Chapter[] = [];
  let merged = 0;
  let pendingStart: number | null = null; // start pulled back from a dropped first chapter

  for (let i = 0; i < list.length; i++) {
    const c = { ...list[i] };
    if (pendingStart !== null) {
      c.start_s = Math.min(c.start_s, pendingStart);
      pendingStart = null;
    }
    const short = (c.end_s - c.start_s) < minSeconds;
    if (!short) {
      out.push(c);
      continue;
    }
    const prev = out[out.length - 1];
    if (prev) {
      prev.end_s = Math.max(prev.end_s, c.end_s);
      prev.description = prev.description ?? c.description;
      merged++;
      continue;
    }
    if (i + 1 < list.length) {
      pendingStart = c.start_s; // the next chapter inherits this entry point
      merged++;
      continue;
    }
    out.push(c); // the only chapter there is — a short tour is still a tour
  }

  closeEnds(out, duration);
  return { chapters: out, merged };
}
