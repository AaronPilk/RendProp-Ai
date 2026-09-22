// ai-copy — the SHOT LIST: which photo plays where, how the camera moves on it,
// how long it holds, what is burned across it, and the line of narration that
// runs underneath. One plan, because those five things are one decision.
//
// PURE. Imports ONLY ./prompt.ts, which itself imports nothing — so this file is
// as testable as prompt.ts is, and the character budget, the {address} rule and
// the industry vocabulary are the SAME code /ai-copy/script uses rather than a
// second copy that drifts. Nothing here touches Deno.env, the network or
// Supabase; the compliance loop lives next door in guard.ts, unchanged.
//
// ── WHAT IS WRONG WITH THE REEL TODAY ───────────────────────────────────────
//
// A reel is currently: the user taps N photos → each becomes a five-second clip
// under ONE fixed server prompt, "one slow, subtle, grounded push-in"
// (ai-video/index.ts `reelPrompt()`) → the clips are stitched in tap order → a
// voiceover written by a SEPARATE call is laid over the top. So:
//
//   • every clip moves identically, which reads as a slideshow with a Ken Burns
//     filter rather than as a cut reel;
//   • the order is whichever order a thumb happened to move in;
//   • the narration was written without knowing what is on screen when it plays,
//     so shot 3's line lands over shot 6's picture as often as not.
//
// This route decides all of it at once, and the split of responsibility is the
// design:
//
//   THE SERVER OWNS THE STRUCTURE — order, camera move, seconds. Those are
//   editorial RULES, they have to be deterministic, they have to be renderable
//   by the provider, and a model that hallucinates a photo id must never be able
//   to reorder somebody's reel or ask for a 7.5-second clip.
//
//   THE MODEL OWNS THE WORDS — the burned-in caption and the line of narration,
//   written against a shot list it can see. That is the whole reason this is one
//   call and not three: shot 3's line is written knowing shot 3 is the kitchen,
//   that it holds four seconds, and that the camera is pushing in.

import {
  ADDRESS_PLACEHOLDER,
  CHARS_PER_SECOND,
  type ScriptFacts,
  type SpaceType,
  type Tone,
  charBudgetFor,
  cleanScript,
  extractJsonObject,
  factLines,
  normalizePlaceholder,
  scrubStreetAddress,
  toneDirection,
  vocabFor,
} from "./prompt.ts";

// ── The closed set of camera moves ───────────────────────────────────────────
//
// ⚠ THIS LIST IS ai-video's, NOT OURS. A `motion` this route returns is handed
// straight to POST /ai-video/reel-clip, which turns it into the prompt clause
// that actually drives the clip — so ai-video/motion.ts `REEL_MOTIONS` owns the
// render contract and this is a mirror of it, kept identical so the move named
// in the shot list is the move the viewer sees.
//
// It is the eight things an image-to-video model can hold for five seconds off a
// SINGLE STILL without inventing the room; motion.ts argues each exclusion (whip
// pans and snap zooms need frames that do not exist, a full orbit paints the far
// side of a room it has never seen, an indoor crane runs out of ceiling and
// invents one). Two aerial spellings — `orbit` and `rise_reveal` — are valid on
// /ai-video/aerial and are NOT here: motion.ts aliases them to orbit_left and
// tilt_up for callers who send them anyway, but this route emits the exact enum
// so the `motion` in the response is always the move that was rendered, never
// one that was quietly translated on the way in.
//
// shotlist_test.ts imports ai-video/motion.ts and asserts this list and the
// family map below are the same as REEL_MOTIONS and REEL_MOTION_FAMILY. That
// test is why this comment is a guarantee rather than a promise: adding a move
// there and not here fails the build.
export const MOTIONS = [
  "push_in",
  "pull_back",
  "tilt_up",
  "tilt_down",
  "orbit_left",
  "orbit_right",
  "rack_focus",
  "static_parallax",
] as const;
export type Motion = typeof MOTIONS[number];

// ── Move families ────────────────────────────────────────────────────────────
//
// A mirror of motion.ts REEL_MOTION_FAMILY, and the reason for it is theirs:
// every move belongs to exactly one family grouped by WHAT PHYSICALLY MOVES —
// dolly (the camera translates along the lens axis), vertical (it rotates),
// lateral (it translates across the scene), optical (nothing translates; the
// lens or the air does the work).
//
// Families are what makes VARIATION mean something. "Not the same move" would
// let orbit_left follow orbit_right, which is two lateral arcs back to back and
// reads exactly as monotonous as two push-ins. So consecutive shots must differ
// by FAMILY, which implies they differ by move.
const MOTION_FAMILY: Record<Motion, "dolly" | "vertical" | "lateral" | "optical"> = {
  push_in: "dolly",
  pull_back: "dolly",
  tilt_up: "vertical",
  tilt_down: "vertical",
  orbit_left: "lateral",
  orbit_right: "lateral",
  rack_focus: "optical",
  static_parallax: "optical",
};

// ── Shot length ──────────────────────────────────────────────────────────────
//
// The provider takes an INTEGER number of seconds: the Seedance duration enum is
// the strings "2".."12" (ai-video/index.ts, MODEL_I2V), and its reel route
// already clamps with `Math.min(12, Math.max(2, secs))`. So these two numbers
// are not a house style, they are the render contract — a 1-second shot cannot
// be ordered at all, and even if it could, a clip that short reads as a glitch
// rather than as a cut.

export const MIN_SHOT_SECONDS = 2;
export const MAX_SHOT_SECONDS = 12;

/** Seconds per clip the app uses today, and therefore the default reel length
 *  (5 × the number of photos) when the client does not ask for one. */
export const DEFAULT_SHOT_SECONDS = 5;

/**
 * The most shots one reel may carry.
 *
 * Every shot is a paid image-to-video clip and a burned-in caption; twenty of
 * them is already a 100-second reel at the default pace, which is past what
 * Reels and TikTok reward. A request for more is REFUSED (400) rather than
 * truncated: the user picked those photos, and silently dropping the last
 * fifteen of them would be a worse answer than telling them the truth.
 */
export const MAX_SHOTS = 20;

// ── On-screen text ───────────────────────────────────────────────────────────
//
// This is the realtor-reel idiom, and it is a real format with real rules: a big
// short caption burned into the clip — "5 BED · 3.5 BATH", "CHEF'S KITCHEN",
// "$1.5M" — read at arm's length in about a second, on a phone, often muted.
// Sentences do not survive that; three or four words do. The word budget is a
// MAXIMUM, not a target: "$1.5M" is one word and is the best caption on the
// reel.

export const MAX_OVERLAY_WORDS = 5;

/** …and a character cap on top of the word cap, because five long words is a
 *  caption that wraps to three lines over somebody's kitchen. */
export const MAX_OVERLAY_CHARS = 28;

/** Words, counting only tokens that carry a letter or a digit — the separators
 *  the idiom is built from ("·", "|", "—") are punctuation, not words, so
 *  "5 BED · 3.5 BATH" is FOUR words and fits. Exported so the clamp below and
 *  the test that checks the clamp count the same way. */
export function overlayWordCount(text: string): number {
  return String(text ?? "")
    .split(/\s+/)
    .filter((t) => /[\p{L}\p{N}]/u.test(t))
    .length;
}

/**
 * Clamp a model-written caption into the idiom: upper case, at most five words
 * and MAX_OVERLAY_CHARS characters, no markdown, no emoji, no terminal
 * punctuation. Returns "" when nothing usable survives — an empty caption is a
 * legitimate answer (a caption on EVERY clip is noise; caption the shots that
 * carry a fact), so this never invents one.
 *
 * The kept punctuation is exactly what the idiom uses: the separators, the
 * currency and percent signs, the decimal point in "3.5 BATH" and "$1.5M", the
 * apostrophe in "CHEF'S KITCHEN", and the comma and slash in "2,400 SQ FT" and
 * "INDOOR/OUTDOOR". Everything else is dropped rather than transliterated.
 */
export function cleanOverlayText(raw: unknown): string {
  const flat = String(raw ?? "")
    .replace(/[\r\n]+/g, " ")
    .replace(/[*_#`~]+/g, "")
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, "")
    .replace(/[•–—|]/g, "·")
    .replace(/[^\p{L}\p{N}$€£%&+/'.,:·\s-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!flat) return "";

  // Keep whole tokens until the word budget is spent, so a caption is never cut
  // mid-word and a trailing separator never survives its own word.
  const kept: string[] = [];
  let words = 0;
  for (const token of flat.split(" ")) {
    const isWord = /[\p{L}\p{N}]/u.test(token);
    if (isWord && words >= MAX_OVERLAY_WORDS) break;
    if (isWord) words++;
    kept.push(token);
  }

  let out = trimOverlayEdges(kept.join(" ").toUpperCase());
  if (out.length > MAX_OVERLAY_CHARS) {
    const window = out.slice(0, MAX_OVERLAY_CHARS);
    const lastSpace = window.lastIndexOf(" ");
    out = trimOverlayEdges(lastSpace > 0 ? window.slice(0, lastSpace) : window);
  }
  return out;
}

/**
 * A caption as it will be BURNED INTO THE FRAME — `cleanOverlayText()` plus the
 * address rule, which for a caption is "drop it", not "scrub it".
 *
 * A street address on screen is worse than one in the voiceover: it is legible,
 * it is held for the whole shot, and the request contains nothing to copy an
 * address from — so any address here was INVENTED. Scrubbing it would leave a
 * caption reading "ADDRESS" (the braces are not in the caption character set),
 * which is a bug the agent has to notice and delete. A caption is optional by
 * design, so the honest answer is NO CAPTION: the clip plays, the narration
 * still names the property with {address}, and nothing wrong is on screen.
 */
export function captionFrom(raw: unknown): string {
  const text = String(raw ?? "");
  if (scrubStreetAddress(text) !== text) return "";       // an invented street address
  if (text.includes(ADDRESS_PLACEHOLDER)) return "";      // the token itself
  if (normalizePlaceholder(text) !== text) return "";     // {{address}}, [address], {Address}…
  return cleanOverlayText(text);
}

/** A caption is not a sentence: it never opens or closes on punctuation. */
function trimOverlayEdges(text: string): string {
  return text.replace(/^[\s.,:;!?·/&+-]+/, "").replace(/[\s.,:;!?·/&+-]+$/, "").trim();
}

// ── The photos the client sends ──────────────────────────────────────────────

export interface ShotPhoto {
  /** The client's own asset id. It is the ONLY key the model's answer is matched
   *  on — see `parseShotlist()`. */
  id: string;
  /** The room label the app already shows for this photo, or "". */
  room: string;
  /** Anything the photographer noted about the frame ("twilight, lights on"). */
  caption_hint: string;
}

export const MAX_PHOTO_ID_CHARS = 64;
export const MAX_ROOM_CHARS = 40;
export const MAX_HINT_CHARS = 120;

function line(raw: unknown, maxChars: number): string {
  return String(raw ?? "").replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, maxChars);
}

/**
 * Coerce the client's `photos` into the bounded shape the planner reads, IN THE
 * ORDER THEY WERE SENT — that order is the user's tap order, and it is the
 * tiebreak that makes the plan deterministic (see `planShots`).
 *
 * An entry with no `id` is dropped: it could never be matched to a line of
 * narration, so keeping it would put a silent, uncaptioned clip in the reel. A
 * REPEATED id is dropped for the same reason — two shots with one id cannot be
 * told apart in the model's answer — and the response echoes every photo_id it
 * planned, so a client that sent duplicates can see exactly what happened.
 */
export function cleanPhotos(raw: unknown): ShotPhoto[] {
  if (!Array.isArray(raw)) return [];
  const out: ShotPhoto[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (out.length >= MAX_SHOTS) break;
    const o = (item && typeof item === "object" ? item : {}) as Record<string, unknown>;
    const id = line(o.id, MAX_PHOTO_ID_CHARS);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      room: line(o.room, MAX_ROOM_CHARS),
      caption_hint: line(o.caption_hint, MAX_HINT_CHARS),
    });
  }
  return out;
}

/** Every word the CALLER wrote about the photos, for the input fair-housing
 *  gate. Ids are excluded — an asset uuid cannot trip a housing rule and a gate
 *  that reads them only invents false positives (the same argument
 *  `userFreeText()` makes about a bed count). */
export function photoWords(photos: ShotPhoto[]): string[] {
  const out: string[] = [];
  for (const p of photos) {
    if (p.room) out.push(p.room);
    if (p.caption_hint) out.push(p.caption_hint);
  }
  return out;
}

// ── Reel length ──────────────────────────────────────────────────────────────

/** The reel the app makes today: five seconds per photo. */
export function defaultTargetSeconds(photoCount: number): number {
  return Math.max(1, Math.round(photoCount)) * DEFAULT_SHOT_SECONDS;
}

/**
 * Clamp `target_seconds` to something this many shots can actually render.
 *
 * The binding constraint is not taste, it is arithmetic: every shot must be an
 * integer 2..12, so a reel of n shots can only be 2n..12n seconds long. A
 * request outside that range is CLAMPED rather than refused — the client asked
 * for a length, not for a specific per-shot duration, and answering a
 * 3-photo/60-second request with 36 seconds of reel is a better outcome than a
 * 400 the user cannot act on.
 */
export function cleanShotlistTarget(raw: unknown, photoCount: number): number {
  const n = Math.max(1, Math.round(photoCount));
  const asked = Math.round(Number(raw));
  const wanted = Number.isFinite(asked) && asked > 0 ? asked : defaultTargetSeconds(n);
  return Math.min(n * MAX_SHOT_SECONDS, Math.max(n * MIN_SHOT_SECONDS, wanted));
}

// ── Rooms → beats ────────────────────────────────────────────────────────────
//
// A room label is free text the app already shows ("Primary Bath", "Backyard",
// "Great Room"). Classifying it is what lets the ORDER be a decision rather than
// a tap order, and it is deliberately a small, ordered list of patterns rather
// than anything clever: first match wins, so the specific test comes before the
// general one. "Primary Bath" is a BATHROOM, not the primary suite — which is
// why `bath` is tested before `primary`.

export const ROOM_CLASSES = [
  "exterior_rear",
  "exterior_front",
  "bath",
  "kitchen",
  "dining",
  "hero_living",
  "primary",
  "bed",
  "entry",
  "work",
  "detail",
] as const;
export type RoomClass = typeof ROOM_CLASSES[number];

const CLASS_PATTERNS: Array<[RoomClass, RegExp]> = [
  [
    "exterior_rear",
    /\b(back\s*yard|backyard|rear|pool|spa\s*deck|patio|deck|garden|yard|terrace|balcony|rooftop|roof\s*deck|dock|waterfront|water|view|outdoor|fire\s*pit|firepit|bbq|grill|lanai|courtyard|cabana)\b/i,
  ],
  [
    "exterior_front",
    /\b(exterior|front|facade|façade|curb|street|elevation|driveway|porch|approach|aerial|drone|frontage)\b/i,
  ],
  ["bath", /\b(bath|bathroom|powder|ensuite|en[\s-]suite|shower|wet\s*room|sauna)\b/i],
  ["kitchen", /\b(kitchen|pantry|butler|breakfast\s*nook|island)\b/i],
  ["dining", /\b(dining|dinette|breakfast|bar|banquette)\b/i],
  ["hero_living", /\b(living|great\s*room|family\s*room|lounge|den|sitting|parlou?r|salon|hearth)\b/i],
  ["primary", /\b(primary|master|owner'?s|main\s*(bed|suite))\b/i],
  ["bed", /\b(bed|bedroom|guest|nursery|kids?'?\s*room)\b/i],
  ["entry", /\b(entry|entryway|entrance|foyer|hall|hallway|stair|staircase|landing|mudroom|vestibule)\b/i],
  [
    "work",
    /\b(office|study|library|gym|fitness|studio|media|theat(er|re)|play\s*room|playroom|bonus|flex|loft|laundry|garage|workshop|basement|attic|closet|wine|cellar|utility)\b/i,
  ],
];

/** Unlabelled or unrecognised → `detail`, which is honest: we do not know what
 *  is in the frame, so it gets the quiet treatment (a short hold, a still
 *  parallax) rather than a hero's six seconds and an orbit. */
export function classifyRoom(room: string): RoomClass {
  const s = String(room ?? "").trim();
  if (!s) return "detail";
  for (const [klass, re] of CLASS_PATTERNS) {
    if (re.test(s)) return klass;
  }
  return "detail";
}

// ── The order is a decision ──────────────────────────────────────────────────
//
// TOUR RANK is the order a listing video actually walks a property: you arrive,
// you come in, you see the room the house is sold on, then the kitchen, then the
// private rooms, then the details, and you leave through the back. It is public
// → private, which is the order a buyer physically walks, and it is why every
// class gets exactly ONE rank: a kitchen and a great room are both "position 2"
// candidates and only one of them can have it. Rank settles that argument once,
// the same way every time, instead of leaving it to whichever photo the user
// happened to tap second.
const TOUR_RANK: Record<RoomClass, number> = {
  exterior_front: 10,
  entry: 20,
  hero_living: 30,
  kitchen: 40,
  dining: 50,
  primary: 60,
  bath: 70,
  bed: 80,
  work: 90,
  detail: 95,
  exterior_rear: 100,
};

/** Openers, best first. The establishing shot is the strongest hook a listing
 *  has; with no exterior, the biggest and most cinematic interior is the great
 *  room, then the kitchen — the two rooms that sell a house. */
const OPENER_PREFERENCE: RoomClass[] = ["exterior_front", "hero_living", "kitchen", "exterior_rear"];

/** Closers, best first. The last frame is the one the CTA card sits over, so it
 *  wants to be wide, calm and aspirational: the yard or the pool, else a second
 *  exterior, else the primary suite or the great room. A bathroom detail is not
 *  a close. */
const CLOSER_PREFERENCE: RoomClass[] = ["exterior_rear", "exterior_front", "primary", "hero_living"];

export type ShotRole = "open" | "hero" | "detail" | "close";

/** Which classes carry the reel — they get the longer holds and the moving
 *  camera; everything else is a detail cut. */
const HERO_CLASSES: RoomClass[] = ["hero_living", "kitchen", "primary", "exterior_front", "exterior_rear"];

interface Candidate {
  photo: ShotPhoto;
  klass: RoomClass;
  /** The user's own tap position — the tiebreak that keeps the plan stable. */
  tap: number;
}

function pickFirst(pool: Candidate[], preference: RoomClass[]): Candidate | null {
  for (const klass of preference) {
    const hit = pool.find((c) => c.klass === klass);
    if (hit) return hit;
  }
  return null;
}

/**
 * Order the photos: opener, the walk, closer.
 *
 *   1. THE OPENER is the best establishing shot available (OPENER_PREFERENCE),
 *      falling back to the user's first tap when nothing is labelled. The
 *      opening frame has to earn the next two seconds — the same rule
 *      `scriptInstruction()` states for the opening LINE, applied to the
 *      picture.
 *   2. THE CLOSER is the best CTA frame available (CLOSER_PREFERENCE), falling
 *      back to the last photo in tour order.
 *   3. THE MIDDLE is tour rank, then the user's tap order inside a rank. Tap
 *      order as the tiebreak is deliberate: where the rules are indifferent, the
 *      user's own sequence wins, so the plan is both deterministic AND still
 *      recognisably the reel they laid out.
 *
 * A one-photo reel has no middle and no closer; a two-photo reel is opener +
 * closer. Neither is a special case worth branching on beyond not letting one
 * photo be picked twice.
 */
function orderPhotos(photos: ShotPhoto[]): Candidate[] {
  const pool: Candidate[] = photos.map((photo, tap) => ({ photo, klass: classifyRoom(photo.room), tap }));
  if (pool.length <= 1) return pool;

  const byTour = [...pool].sort((a, b) => (TOUR_RANK[a.klass] - TOUR_RANK[b.klass]) || (a.tap - b.tap));

  const opener = pickFirst(pool, OPENER_PREFERENCE) ?? pool[0];
  const rest = byTour.filter((c) => c !== opener);
  const closer = pickFirst(rest, CLOSER_PREFERENCE) ?? rest[rest.length - 1];
  const middle = rest.filter((c) => c !== closer);

  return [opener, ...middle, closer];
}

// ── The motion belongs to the shot ───────────────────────────────────────────
//
// Every clip moving identically is what makes today's reel read as a slideshow.
// A move is a choice about the FRAME: you push in on a room you want the viewer
// inside, you pull back to leave, you tilt up a double-height entry, you orbit a
// kitchen island because the parallax is what proves the space is real.
//
// Each class gets an ordered preference of at least three moves, so the
// no-two-in-a-row repair below always has somewhere to go.
const MOTION_PREFERENCE: Record<RoomClass, Motion[]> = {
  // Arrive at the house: come toward it. The tilt is second because it is what
  // actually reveals height from a still — motion.ts makes exactly this argument
  // when it aliases the aerial `rise_reveal` onto tilt_up.
  exterior_front: ["push_in", "tilt_up", "orbit_left"],
  // Leave the house: widen out into the yard, the pool, the view.
  exterior_rear: ["pull_back", "orbit_right", "tilt_up"],
  // Entries are vertical — the stair, the double height, the light above.
  entry: ["tilt_up", "push_in", "static_parallax"],
  // The room the house is sold on: the orbit is what shows it is a real volume.
  hero_living: ["orbit_left", "push_in", "pull_back"],
  // The rack is the kitchen shot: it pulls focus off the island foreground and
  // into the room, which is what proves there is depth behind the counter.
  kitchen: ["push_in", "orbit_right", "rack_focus"],
  dining: ["orbit_right", "rack_focus", "push_in"],
  primary: ["push_in", "orbit_left", "tilt_down"],
  // A bath is small and reflective: a slow settle beats a move that reveals
  // geometry the photo never had.
  bath: ["tilt_down", "static_parallax", "push_in"],
  bed: ["orbit_right", "push_in", "static_parallax"],
  work: ["static_parallax", "push_in", "tilt_up"],
  // A detail is a foreground object: rack_focus is the move that exists for it.
  detail: ["rack_focus", "static_parallax", "tilt_down"],
};

/**
 * THE UNLABELLED REEL, which is the common one.
 *
 * `detail` is not a kind of room, it is the absence of one: no label, or a label
 * we do not recognise. If every `detail` shot drew from one preference list, a
 * reel of unlabelled photos — exactly what the app sends when the agent has not
 * tagged anything — would alternate two moves forever. The family repair would
 * be satisfied and the reel would still be a slideshow, with a longer period.
 *
 * So a detail shot takes its preference from a ROTATION instead, one step per
 * shot, each entry starting in a different family. That is the mechanism
 * ai-video/motion.ts `chooseReelMotion()` uses for the same problem
 * (FAMILY_CYCLE, walked by shot index), and it means an unlabelled reel walks
 * dolly → vertical → lateral → optical rather than ping-ponging.
 *
 * Entry 0 opens on a push-in because an unlabelled reel's first shot is usually
 * ALSO its opener, and a focus rack is a weak hook: nothing moves toward the
 * viewer in the two seconds where the scroll is decided.
 */
const DETAIL_ROTATION: Motion[][] = [
  ["push_in", "tilt_down", "orbit_left", "rack_focus"],
  ["tilt_down", "orbit_right", "rack_focus", "push_in"],
  ["orbit_left", "rack_focus", "push_in", "tilt_up"],
  ["rack_focus", "push_in", "tilt_up", "orbit_right"],
];

/** The closer's own preference wins over its class: pulling back off the last
 *  frame is the close, and it leaves room for the end card. static_parallax is
 *  the fallback rather than an afterthought — motion.ts calls it "the shot an
 *  editor puts a text or CTA card over, because nothing in it competes with the
 *  type", which is precisely what the last shot of this reel is. */
const CLOSER_MOTION: Motion[] = ["pull_back", "static_parallax", "tilt_up"];

/**
 * Assign a move per shot, then repair so NO TWO CONSECUTIVE SHOTS SHARE A
 * FAMILY — and therefore never share a move.
 *
 * The repair walks forward and only ever changes the LATER shot, so shot 1's
 * move, the one that sets the reel up, is never disturbed by a decision made
 * about shot 7. The final fallback scans MOTIONS itself, which makes the
 * invariant unconditional rather than a property of the preference lists: there
 * are four families, so a move from a different one always exists.
 */
function assignMotions(plan: Array<{ klass: RoomClass; role: ShotRole }>): Motion[] {
  const out: Motion[] = [];
  for (let i = 0; i < plan.length; i++) {
    const prefs = plan[i].role === "close"
      ? [...CLOSER_MOTION, ...MOTION_PREFERENCE[plan[i].klass]]
      : plan[i].klass === "detail"
      ? DETAIL_ROTATION[i % DETAIL_ROTATION.length]
      : MOTION_PREFERENCE[plan[i].klass];
    const lastFamily = i > 0 ? MOTION_FAMILY[out[i - 1]] : null;
    const fresh = (m: Motion) => MOTION_FAMILY[m] !== lastFamily;
    out.push(prefs.find(fresh) ?? MOTIONS.find(fresh) ?? MOTIONS[0]);
  }
  return out;
}

// ── Pacing ───────────────────────────────────────────────────────────────────
//
// Shots do not want to be equal. A hero room needs a beat to land; a detail cut
// is over before you have finished looking at it, and that is the point. But the
// total has to be exactly the reel the client asked for, and every shot has to
// be an integer the provider will accept.
//
// So: weights → exact shares → floors → hand the remainder out by largest
// fractional part (Hamilton apportionment), bounded at both ends and stable on
// index. That is one function, `apportion()`, and it is used TWICE — once to
// split the seconds across the shots and once to split the CHARACTER budget
// across the voice lines in proportion to those seconds. Splitting the
// characters the same way is what keeps the narration honest: a six-second hero
// gets three times the words of a two-second cut, and the lines sum to the
// script budget by construction rather than by hoping.

const ROLE_WEIGHT: Record<ShotRole, number> = {
  open: 1.15,
  hero: 1.15,
  detail: 0.8,
  close: 1.35,
};

/**
 * Split `total` across `weights` as integers in [min, max] that sum to EXACTLY
 * `total`. Deterministic: ties go to the earlier shot.
 *
 * The caller guarantees feasibility (`min·n ≤ total ≤ max·n`); when it does not,
 * this returns the closest bounded answer rather than looping — a clamp is
 * always better than a hang, and `cleanShotlistTarget()` is the thing that makes
 * it feasible.
 */
export function apportion(total: number, weights: number[], min: number, max: number): number[] {
  const n = weights.length;
  if (n === 0) return [];
  const safeTotal = Number.isFinite(total) && total > 0 ? Math.round(total) : 0;
  const clean = weights.map((w) => (Number.isFinite(w) && w > 0 ? w : 0));
  const sumW = clean.reduce((a, b) => a + b, 0);
  const exact = clean.map((w) => (sumW > 0 ? (safeTotal * w) / sumW : safeTotal / n));

  const out = exact.map((x) => Math.min(max, Math.max(min, Math.floor(x))));
  // Largest fractional part first; ties by index, so the answer is stable.
  const order = exact
    .map((x, i) => ({ i, frac: x - Math.floor(x) }))
    .sort((a, b) => (b.frac - a.frac) || (a.i - b.i))
    .map((e) => e.i);

  let sum = out.reduce((a, b) => a + b, 0);
  let guard = safeTotal + n + 2; // each pass moves the sum by ≥1, so this is slack
  while (sum < safeTotal && guard-- > 0) {
    let moved = false;
    for (const i of order) {
      if (out[i] >= max) continue;
      out[i]++;
      sum++;
      moved = true;
      if (sum === safeTotal) break;
    }
    if (!moved) break; // every shot is at `max` — the total is not reachable
  }
  guard = safeTotal + n + 2;
  while (sum > safeTotal && guard-- > 0) {
    let moved = false;
    for (let k = order.length - 1; k >= 0; k--) {
      const i = order[k];
      if (out[i] <= min) continue;
      out[i]--;
      sum--;
      moved = true;
      if (sum === safeTotal) break;
    }
    if (!moved) break; // every shot is at `min`
  }
  return out;
}

// ── The plan ─────────────────────────────────────────────────────────────────

export interface PlannedShot {
  photo_id: string;
  /** 1-based: "shot 3" in the instruction is `order === 3`. */
  order: number;
  motion: Motion;
  /** The caller's own room label, echoed — the app already shows this string. */
  room: string;
  seconds: number;
  /** Internal. Not in the response: the client renders `room`, not our guess. */
  klass: RoomClass;
  role: ShotRole;
  /** Characters of narration this shot's hold can carry. */
  voiceBudget: number;
  captionHint: string;
}

/**
 * The whole structural decision, from the photos and the reel length.
 *
 * PURE AND DETERMINISTIC — the same photos in the same order always produce the
 * same plan, which is what makes it safe to run this before spending a token and
 * to re-run it unchanged when a compliance retry re-generates the words.
 */
export function planShots(photos: ShotPhoto[], targetSeconds: number): PlannedShot[] {
  const ordered = orderPhotos(photos);
  const n = ordered.length;
  if (n === 0) return [];

  const roles: ShotRole[] = ordered.map((c, i) => {
    if (i === 0) return "open";
    if (i === n - 1) return "close";
    return HERO_CLASSES.includes(c.klass) ? "hero" : "detail";
  });

  const seconds = apportion(
    cleanShotlistTarget(targetSeconds, n),
    roles.map((r) => ROLE_WEIGHT[r]),
    MIN_SHOT_SECONDS,
    MAX_SHOT_SECONDS,
  );
  const motions = assignMotions(ordered.map((c, i) => ({ klass: c.klass, role: roles[i] })));

  // The character budget is split in proportion to the SECONDS, minus the spaces
  // that will join the lines — so the finished script lands inside the reel's
  // budget by construction and the join can never push it over (which would cost
  // the closing CTA its last words to a trim).
  const charBudget = charBudgetFor(seconds.reduce((a, b) => a + b, 0));
  const voiceBudgets = apportion(Math.max(0, charBudget - (n - 1)), seconds, 0, charBudget);

  return ordered.map((c, i) => ({
    photo_id: c.photo.id,
    order: i + 1,
    motion: motions[i],
    room: c.photo.room,
    seconds: seconds[i],
    klass: c.klass,
    role: roles[i],
    voiceBudget: voiceBudgets[i],
    captionHint: c.photo.caption_hint,
  }));
}

/** The reel's real length: what the client will actually render. */
export function planSeconds(plan: PlannedShot[]): number {
  return plan.reduce((a, s) => a + s.seconds, 0);
}

/** The script budget this plan's length allows — the same arithmetic
 *  /ai-copy/script uses, applied to the length we just planned. */
export function planCharBudget(plan: PlannedShot[]): number {
  return charBudgetFor(planSeconds(plan));
}

/** Under this many characters a line is not a sentence, so the shot is a quiet
 *  cut and the model is told to leave it silent rather than write a fragment. */
export const MIN_SPEAKABLE_CHARS = 25;

// ── The instruction ──────────────────────────────────────────────────────────

export interface ShotlistRequest {
  space: SpaceType;
  tone: Tone;
  facts: ScriptFacts;
  plan: PlannedShot[];
  /** planCharBudget(plan) — the whole script's ceiling. */
  charBudget: number;
  /** planSeconds(plan) — the reel's real length. */
  targetSeconds: number;
}

/**
 * How each move reads to a VIEWER, in one clause.
 *
 * Deliberately NOT ai-video's REEL_MOTION_TEXT, and not a duplicate of it: that
 * string is engineering direction written FOR THE VIDEO MODEL ("one slow,
 * shallow arc a few degrees to the left around the subject, at a constant
 * height, with gentle natural parallax"). This is what the shot looks like, told
 * to a COPYWRITER, so the sentence it writes suits a frame that is widening
 * rather than closing in. Two audiences, two texts; only the enum is shared.
 */
const MOTION_NOTE: Record<Motion, string> = {
  push_in: "the camera pushes slowly in",
  pull_back: "the camera pulls back and widens out",
  tilt_up: "the camera tilts up, revealing height",
  tilt_down: "the camera tilts down onto the surfaces",
  orbit_left: "the camera arcs slowly left around the space",
  orbit_right: "the camera arcs slowly right around the space",
  rack_focus: "the frame holds and the focus pulls from a foreground detail into the room",
  static_parallax: "the frame holds nearly still — the calm shot the end card sits over",
};

/**
 * The system rules for `POST /ai-copy/shotlist`.
 *
 * It is `scriptInstruction()`'s four rules — hook first, the facts that sell in
 * the industry's own words, a close that asks for something, length is a hard
 * constraint — plus the two this route exists for:
 *
 *   • THE SHOT LIST IS FIXED. The model writes words for shots it is given, in
 *     the order it is given them. It does not get to reorder the reel: the
 *     order, the moves and the seconds are already decided, already renderable,
 *     and already deterministic.
 *   • THE WORDS MUST MATCH THE PICTURE. Shot 3's line describes what is on
 *     screen in shot 3. That is the entire reason the script is written here
 *     rather than by a second, blind call.
 */
export function shotlistInstruction(req: ShotlistRequest): string {
  const v = vocabFor(req.space);
  const last = req.plan.length > 0 ? req.plan[req.plan.length - 1].order : 1;

  return [
    `You direct short social-video tours of a ${v.space}, for ${v.audience}. The finished reel is ` +
      `posted to Instagram Reels and TikTok, where ${v.customer} are scrolling. The product's own ` +
      `promise for this industry is "${v.pitch}" — write to that.`,
    "",
    `THE SHOT LIST BELOW IS ALREADY CUT. The order of the shots, the camera move on each one and ` +
      `how long each one holds were decided before you were called, and they are FIXED. Do not ` +
      `reorder them, do not merge them, do not add or drop one, and do not invent a photo_id. Your ` +
      `job is the WORDS: one on-screen caption and one line of narration per shot.`,
    "",
    "RULES, in priority order:",
    `1. THE WORDS MUST MATCH THE PICTURE. Shot 3's line describes what is on screen in SHOT 3 — the ` +
      `${v.area} named on that line of the shot list, and nothing else. A line that describes the ` +
      `wrong ${v.area} is worse than no line: the viewer is looking at the picture, not at you. If ` +
      `you were told nothing about a shot beyond its ${v.area}, say something true about that ` +
      `${v.area} or leave the line empty.`,
    `2. HOOK FIRST. Shot 1's line has to earn the next two seconds — that is the whole game on Reels ` +
      `and TikTok. Never open with "Welcome to", "Come see", "Take a look at", "Step inside" or any ` +
      `other greeting. Open on the single most interesting true thing you were given.`,
    `3. THE FACTS THAT SELL, in this industry's own words — say "${v.customer}", say "${v.area}", ` +
      `call it a ${v.space}. Use only the facts below. Never invent a fact, a number, a price, a ` +
      `feature or a neighbourhood, and never describe anything you were not told about.`,
    `4. CLOSE BY ASKING FOR SOMETHING. Shot ${last} is the last shot and the end card sits over it: ` +
      `its line ends on the action the tour's own button offers — "${v.cta}". One short line.`,
    `5. LENGTH IS A HARD CONSTRAINT, NOT A SUGGESTION. Every shot below carries its own character ` +
      `budget, and it is the length of that clip: about ${CHARS_PER_SECOND} characters per second of ` +
      `video. The whole script must fit ${req.charBudget} characters, which is exactly how long the ` +
      `reel is (${req.targetSeconds} seconds). A longer script does not get cut off — the video runs ` +
      `out and the last frame FREEZES while the voice keeps talking. Shorter is fine. Longer is a ` +
      `broken reel. A shot budgeted under ${MIN_SPEAKABLE_CHARS} characters is a quick cut: leave its ` +
      `voice_line EMPTY unless one short true phrase fits, and the reel plays fine under the previous ` +
      `line.`,
    "",
    `ON-SCREEN TEXT is the burned-in caption, and it is its own format: AT MOST ` +
      `${MAX_OVERLAY_WORDS} WORDS, UPPER CASE, no sentence and no full stop — "5 BED · 3.5 BATH", ` +
      `"CHEF'S KITCHEN", "$1.5M", "2,400 SQ FT". It is read at arm's length in about a second, ` +
      `often with the sound off, so it carries ONE fact. It must not repeat the words of its own ` +
      `voice_line, and it must be true of that shot's ${v.area}. NOT every shot gets one — a caption ` +
      `on every clip is noise. Leave on_screen_text as "" for the shots that carry no fact worth ` +
      `burning in. A caption NEVER names the address and never contains ${ADDRESS_PLACEHOLDER} — if ` +
      `the reel names the ${req.space === "real_estate" ? "property" : "business"} it does so out ` +
      `loud, in one voice_line.`,
    "",
    `NAMING THE ${req.space === "real_estate" ? "PROPERTY" : "BUSINESS"}. You have not been told the ` +
      `address, and you must never invent one. Where a line should name it, write the literal token ` +
      `${ADDRESS_PLACEHOLDER} — the app replaces that token on the device before the script is ` +
      `spoken. Use it AT MOST ONCE in the whole reel. If it reads better without naming it, leave ` +
      `it out.`,
    "",
    "STYLE: " + toneDirection(req.tone),
    `Spoken English, plain words, no markdown, no emoji, no hashtags, no stage directions, no ` +
      `speaker labels, no quotation marks around a line. Each voice_line is one or two short ` +
      `sentences that can be read aloud; read end to end, the lines have to sound like one script.`,
    "",
    `NEVER describe or refer to people, families, children, a neighbourhood, schools, a "safe" or ` +
      `"good" area, or who would like living or shopping here — in a voice_line OR in an on-screen ` +
      `caption. Describe the ${v.space}, never its occupants or its neighbours. This is advertising ` +
      `copy and that rule is the law, not a preference. Copy that breaks it is thrown away and costs ` +
      `the user their turn.`,
    "",
    `Reply with STRICT JSON only, exactly: ` +
      `{"shots":[{"photo_id":"<the id from the shot list>","on_screen_text":"<caption or empty>",` +
      `"voice_line":"<the narration or empty>"}]}`,
  ].join("\n");
}

/** The user turn: the facts, then the shot list itself — one line per shot,
 *  carrying everything the words have to agree with. */
export function buildShotlistTurn(req: ShotlistRequest): string {
  const v = vocabFor(req.space);
  const shots = req.plan.map((s) => {
    const bits = [
      `${s.order}. photo_id=${s.photo_id}`,
      `${v.area}: ${s.room || "(not labelled)"}`,
      `camera: ${s.motion} (${MOTION_NOTE[s.motion]})`,
      `holds ${s.seconds}s`,
      `voice_line: at most ${s.voiceBudget} characters${s.voiceBudget < MIN_SPEAKABLE_CHARS ? " — a quick cut, an empty line is fine" : ""}`,
    ];
    if (s.captionHint) bits.push(`the photographer's note: ${s.captionHint}`);
    return bits.join(" | ");
  });

  return [
    `FACTS (use only these):`,
    ...factLines(req.space, req.facts),
    `Reel length: ${req.targetSeconds} seconds across ${req.plan.length} shots`,
    `Whole-script character budget: ${req.charBudget}`,
    "",
    `THE SHOT LIST (fixed — one entry per shot, in this order):`,
    ...shots,
  ].join("\n");
}

// ── Reading the model's answer ───────────────────────────────────────────────

/** One shot, exactly as the route returns it. */
export interface Shot {
  photo_id: string;
  order: number;
  motion: Motion;
  room: string;
  on_screen_text: string;
  seconds: number;
  voice_line: string;
}

export interface ShotlistAnswer {
  shots: Shot[];
  /** The voice lines joined — cleaned by the same pipeline /ai-copy/script uses. */
  script: string;
  /** EVERYTHING the output fair-housing gate must read: the script AND every
   *  on-screen caption. See `SURFACE_SEPARATOR`. */
  surface: string;
}

/**
 * The separator that joins the script and the captions into one compliance
 * surface.
 *
 * It is deliberately NOT whitespace. Every rule in _shared/fairhousing.ts joins
 * its words with `\s+`, and `\s` matches a newline — so a whitespace separator
 * would let a script ending "…perfect for a" and a caption reading "FAMILY ROOM"
 * MANUFACTURE a violation across the seam that exists in neither. A middot
 * cannot be matched by `\s+`, so no phrase can be built across a join, and
 * nothing inside a line is changed, so nothing can hide in one either.
 */
export const SURFACE_SEPARATOR = " · ";

/**
 * Turn one model answer into the finished shot list, or null when it is
 * unusable (which the compliance loop treats as a failed attempt and retries).
 *
 * SHOTS ARE MATCHED BY photo_id AND NEVER BY POSITION. That is the guarantee the
 * whole route rests on: if a model renumbers, reorders or drops an entry,
 * position matching would slide every line one picture to the left and the reel
 * would confidently narrate the wrong rooms. An id we did not send is dropped; a
 * shot the answer never mentions keeps its planned picture and plays silent.
 *
 * An answer is unusable when it yields no narration at all — a shot list with no
 * script is not this route's deliverable, whatever else came back.
 */
export function parseShotlist(raw: string, plan: PlannedShot[]): ShotlistAnswer | null {
  if (plan.length === 0) return null;
  const obj = extractJsonObject(raw);
  const rows = obj && Array.isArray(obj.shots) ? (obj.shots as unknown[]) : [];

  const byId = new Map<string, { caption: string; line: string }>();
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const r = row as Record<string, unknown>;
    const id = line(r.photo_id, MAX_PHOTO_ID_CHARS);
    if (!id || byId.has(id)) continue; // first entry for an id wins, deterministically
    byId.set(id, {
      caption: captionFrom(r.on_screen_text),
      line: String(r.voice_line ?? ""),
    });
  }

  const shots: Shot[] = plan.map((s) => {
    const written = byId.get(s.photo_id);
    return {
      photo_id: s.photo_id,
      order: s.order,
      motion: s.motion,
      room: s.room,
      on_screen_text: written ? written.caption : "",
      seconds: s.seconds,
      voice_line: written ? cleanScript(written.line, s.voiceBudget) : "",
    };
  });

  const spoken = shots.map((s) => s.voice_line).filter((t) => t.length > 0);
  if (spoken.length === 0) return null;

  const script = spoken.join(" ");
  const captions = shots.map((s) => s.on_screen_text).filter((t) => t.length > 0);
  return { shots, script, surface: [script, ...captions].join(SURFACE_SEPARATOR) };
}
