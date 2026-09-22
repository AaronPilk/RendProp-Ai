// agentreel.ts — the edit-decision list for an AGENT-ON-CAMERA reel.
//
// ── WHY THIS ROUTE EXISTS, AND WHY IT GENERATES NO VIDEO ─────────────────────
//
// Every other video surface in this app animates a still: /ai-video/reel_clip
// hands one photograph to an i2v model and asks it to move. That is the right
// answer when all you have is a photograph. It is the WRONG answer here.
//
// An agent-on-camera reel starts from footage that already exists — the agent
// filmed themselves talking. Their face is real, their voice is real, their
// timing is real. Handing that to a generative model would cost roughly 10x and
// give back a drifting impression of a person the viewer is being asked to
// trust with the largest purchase of their life. So this route does not
// generate anything. It DECIDES AN EDIT, and the phone executes it with
// AVFoundation compositing it already does (Render/ReelComposer.swift).
//
// The cost consequence is the whole business case: the transcript is produced
// on-device, the composition is on-device, and the only money that leaves the
// building is ONE bounded text call — a couple of cents for a sixty-second reel
// against roughly fourteen dollars to generate the same length.
//
// ── THE INVERSION OF shotlist.ts ─────────────────────────────────────────────
//
// shotlist.ts owns a rule worth restating: THE SERVER OWNS THE STRUCTURE and
// the model only writes words. There, the structure is the shot order, the
// camera moves and the seconds, because the pictures are all we have.
//
// Here the structure is already fixed by something better than a planner — it
// is fixed by WHAT THE AGENT ACTUALLY SAID AND WHEN. So the server computes the
// COVERAGE WINDOWS from the transcript's own timings (below), and the model's
// entire job is to answer two questions per window:
//
//   • which of the listing's photographs belongs over these words, and
//   • what four words to burn on it.
//
// It cannot move a window, lengthen one, or invent one, because it is never
// given the ability to: it answers against `window_id`s that already exist, and
// anything else in its reply is dropped. A model that renumbers or reorders
// cannot slide the whole reel one picture to the left, which is the failure
// parseShotlist() was written to make impossible and this file inherits.
//
// ── THE SIX RULES THAT MAKE IT AN AGENT REEL AND NOT A SLIDESHOW ─────────────
//
// These are the product knowledge. They are deterministic, they run before a
// token is spent, and they are the reason the output is watchable:
//
//   1. THE FIRST SECONDS ARE ALWAYS THE AGENT'S FACE. You establish the person
//      before you cut away from them. A reel that opens on a kitchen is a
//      listing reel with a voiceover, which is a different product.
//   2. THE LAST SECONDS ARE ALWAYS THE AGENT'S FACE. The ask — call me, DM me,
//      come to the open house — lands on a person, not on a countertop.
//   3. A CUT NEVER LANDS MID-PHRASE. Windows snap to the transcript's own
//      boundaries. Cutting away on the third syllable of "granite" is the
//      single thing that makes an edit read as automated.
//   4. THE AGENT IS SEEN BETWEEN ANY TWO CUTAWAYS. Without a floor on the gap,
//      a talkative agent gets buried under their own listing photos.
//   5. B-ROLL NEVER EXCEEDS ITS SHARE OF THE CLIP. They are selling themselves
//      at least as much as the house; the majority of the runtime is their face.
//   6. NO PHOTOGRAPH PLAYS TWICE IN A ROW. Enforced after the model answers,
//      because it is the model that assigns pictures.
//
// Rule 5's share and rule 1/2's leads are the only numbers here anyone should
// want to tune, so they are named constants at the top rather than buried.

import {
  type ScriptFacts,
  type SpaceType,
  type Tone,
  extractJsonObject,
  factLines,
  toneDirection,
} from "./prompt.ts";
import {
  type Motion,
  type RoomClass,
  type ShotPhoto,
  MAX_OVERLAY_CHARS,
  MAX_OVERLAY_WORDS,
  MAX_PHOTO_ID_CHARS,
  SURFACE_SEPARATOR,
  captionFrom,
  classifyRoom,
} from "./shotlist.ts";

// ── Tunables ─────────────────────────────────────────────────────────────────

/** Rule 1. The agent is on screen for this long before anything cuts away. */
export const FACE_LEAD_SECONDS = 2.0;
/** Rule 2. And for this long at the end, so the call to action lands on them. */
export const FACE_TAIL_SECONDS = 1.5;
/** Rule 4. The agent is visible for at least this long between two cutaways. */
export const MIN_FACE_GAP_SECONDS = 1.2;

/** A cutaway shorter than this reads as a flash frame, not a shot. */
export const MIN_BROLL_SECONDS = 1.6;
/** Longer than this and the viewer has forgotten whose reel this is. */
export const MAX_BROLL_SECONDS = 3.5;

/** Rule 5. B-roll may cover at most this share of the talking-head clip. */
export const MAX_BROLL_SHARE = 0.55;

/** Nobody watches a ninety-second vertical reel, and the transcript for one is
 *  a prompt we would rather not pay for. Above this the route refuses instead
 *  of silently editing the tail off somebody's take. */
export const MAX_CLIP_SECONDS = 180;
/** Below this there is nothing to cut. */
export const MIN_CLIP_SECONDS = 6;

/** A hard ceiling on cutaways, so a five-minute rant cannot mint a prompt with
 *  eighty windows in it. Reached long after MAX_BROLL_SHARE in practice. */
export const MAX_WINDOWS = 12;

/** Transcript hygiene. Phrase-level, not word-level: word-level timings make a
 *  prompt four times the size and buy nothing, because rule 3 snaps to phrase
 *  boundaries anyway. */
export const MAX_TRANSCRIPT_PHRASES = 200;
export const MAX_PHRASE_CHARS = 200;

/** What the reel is about. It changes which photographs are appropriate and it
 *  changes the close, and it is the caller's declaration rather than something
 *  inferred from the transcript — an agent talking about themselves in front of
 *  a listing is a personal-brand reel, and only they know that. */
export const SUBJECTS = ["listing", "agent"] as const;
export type ReelSubject = typeof SUBJECTS[number];

export function subjectOf(raw: unknown): ReelSubject {
  const s = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  return (SUBJECTS as readonly string[]).includes(s) ? (s as ReelSubject) : "listing";
}

// ── Small helpers ────────────────────────────────────────────────────────────

/** One line of caller text, trimmed, collapsed and capped. Mirrors the private
 *  helper in shotlist.ts deliberately rather than exporting that one: these two
 *  files should be free to disagree about their limits later. */
function line(raw: unknown, maxChars: number): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/\s+/g, " ").trim().slice(0, maxChars);
}

/** Round to tenths. Every boundary in an EDL is a presentation time that has to
 *  survive a JSON round trip and land on the same frame twice. */
export function t1(n: number): number {
  return Math.round(n * 10) / 10;
}

// ── The transcript ───────────────────────────────────────────────────────────

/** One spoken phrase and the second it starts at. */
export interface Phrase {
  /** Seconds from the start of the talking-head clip. */
  t: number;
  text: string;
}

/**
 * Clean the caller's transcript into a strictly increasing list of phrases.
 *
 * OUT-OF-ORDER OR DUPLICATE TIMESTAMPS ARE DROPPED, NOT SORTED. A transcript
 * whose timings do not advance is not a transcript with a sorting problem — it
 * is a recogniser that lost the thread, and re-sorting it would produce
 * confident cut points for words that were never said in that order. Dropping
 * is honest: the window planner simply has fewer boundaries to snap to.
 */
export function cleanTranscript(raw: unknown, clipSeconds: number): Phrase[] {
  if (!Array.isArray(raw)) return [];
  const out: Phrase[] = [];
  let last = -1;
  for (const row of raw.slice(0, MAX_TRANSCRIPT_PHRASES)) {
    if (!row || typeof row !== "object") continue;
    const r = row as Record<string, unknown>;
    const t = Number(r.t);
    if (!Number.isFinite(t) || t < 0 || t > clipSeconds) continue;
    if (t <= last) continue;
    const text = line(r.text, MAX_PHRASE_CHARS);
    if (!text) continue;
    out.push({ t: t1(t), text });
    last = t;
  }
  return out;
}

/** Every phrase joined — the agent's own words, which the INPUT fair-housing
 *  gate reads. They are user speech, not model output, and they are gated in
 *  the same place and for the same reason a typed brief is. */
export function transcriptText(phrases: Phrase[]): string {
  return phrases.map((p) => p.text).join(" ");
}

// ── The coverage plan (deterministic, runs before anything is spent) ──────────

/** One decided cutaway. The model fills `photo_id` and the caption; everything
 *  else here is already true before the model is called. */
export interface Window {
  /** Stable id the model answers against. Never a position. */
  window_id: string;
  start: number;
  end: number;
  /** The words the agent is saying underneath it — this is what makes the model
   *  able to pick a picture that MATCHES rather than a picture that is next. */
  says: string;
}

/**
 * Lay cutaway windows over the clip.
 *
 * The algorithm is deliberately boring, because an editor's judgement encoded
 * as arithmetic is auditable and an editor's judgement encoded in a prompt is
 * not. It walks the transcript's own boundaries and opens a window whenever all
 * six rules allow one, stopping at the b-roll budget.
 *
 * `photoCount` caps the windows because a window with no picture to put in it
 * is a hole in the reel, not a feature.
 */
export function planWindows(
  phrases: Phrase[],
  clipSeconds: number,
  photoCount: number,
): Window[] {
  const budget = clipSeconds * MAX_BROLL_SHARE;
  const lastAllowed = clipSeconds - FACE_TAIL_SECONDS;
  const maxWindows = Math.max(0, Math.min(MAX_WINDOWS, photoCount));
  if (maxWindows === 0 || phrases.length === 0) return [];

  const out: Window[] = [];
  let spent = 0;
  let freeFrom = FACE_LEAD_SECONDS; // rule 1

  for (let i = 0; i < phrases.length && out.length < maxWindows; i++) {
    const start = phrases[i].t;
    if (start < freeFrom) continue; // rule 1 and rule 4

    // Rule 3: the window ends at a later phrase boundary, never mid-phrase.
    // The clip's own end is a boundary too — the last phrase has to end
    // somewhere — so it is offered as the final candidate.
    let end = -1;
    for (let j = i + 1; j <= phrases.length; j++) {
      const cand = j < phrases.length ? phrases[j].t : clipSeconds;
      const len = cand - start;
      if (len < MIN_BROLL_SECONDS) continue;
      if (len > MAX_BROLL_SECONDS) break;
      end = cand;
      break;
    }
    if (end < 0) continue;
    if (end > lastAllowed) break; // rule 2
    if (spent + (end - start) > budget) break; // rule 5

    // The words underneath are every phrase that starts inside the window.
    const says = phrases
      .filter((p) => p.t >= start && p.t < end)
      .map((p) => p.text)
      .join(" ");

    out.push({ window_id: `w${out.length + 1}`, start: t1(start), end: t1(end), says });
    spent += end - start;
    freeFrom = end + MIN_FACE_GAP_SECONDS; // rule 4
  }
  return out;
}

/** Seconds of the clip the windows cover. The app shows this, and the tests
 *  assert it against MAX_BROLL_SHARE. */
export function coveredSeconds(windows: Window[]): number {
  return t1(windows.reduce((n, w) => n + (w.end - w.start), 0));
}

// ── Motion, decided here rather than by the model ─────────────────────────────
//
// The move a cutaway uses is a function of the ROOM, not of the sentence, and
// it is the same product knowledge ai-video/motion.ts documents at length: a
// pull-back states scale, a tilt-up states height, an orbit needs something you
// can walk around and a tight room refuses it. Asking a language model to
// re-derive that per reel would spend tokens to get a worse answer less
// reliably. It is also what guarantees two adjacent cutaways never move the
// same way, which no prompt can promise.

const CLASS_MOVES: Record<RoomClass, readonly Motion[]> = {
  // Deliberately a TOTAL record: add a room class to shotlist.ts and this file
  // stops compiling until someone decides how that room should move.
  exterior_front: ["push_in", "static_parallax", "pull_back"],
  exterior_rear: ["pull_back", "push_in", "static_parallax"],
  hero_living: ["pull_back", "orbit_left", "push_in"],
  kitchen: ["orbit_left", "push_in", "tilt_down"],
  dining: ["orbit_right", "pull_back", "push_in"],
  primary: ["push_in", "pull_back", "tilt_up"],
  bed: ["push_in", "pull_back", "tilt_up"],
  bath: ["rack_focus", "push_in", "tilt_down"],   // tight room: never an orbit
  entry: ["tilt_up", "push_in", "pull_back"],     // height is what an entry sells
  work: ["push_in", "pull_back", "rack_focus"],
  detail: ["rack_focus", "tilt_down", "push_in"],
};

/** The safe move for a room we cannot classify — the same fallback, and the
 *  same reason, as ai-video/motion.ts: a push-in only ever shows LESS of the
 *  frame's edges. */
const FALLBACK_MOVE: Motion = "push_in";

/**
 * Pick this window's move: the room's first preference that is not the move the
 * previous window used. Deterministic, so the same reel edits the same way
 * twice, which is what makes a re-render reproducible.
 */
export function moveFor(room: string, previous: Motion | null): Motion {
  const ranked = CLASS_MOVES[classifyRoom(room)];
  for (const m of ranked) if (m !== previous) return m;
  return ranked[0] ?? FALLBACK_MOVE;
}

// ── The request, the instruction and the turn ────────────────────────────────

export interface AgentReelRequest {
  space: SpaceType;
  tone: Tone;
  subject: ReelSubject;
  facts: ScriptFacts;
  photos: ShotPhoto[];
  windows: Window[];
  clipSeconds: number;
}

/**
 * The system rules.
 *
 * Short on purpose. This model is not writing a script — the agent already
 * spoke — so most of scriptInstruction()'s craft is irrelevant here and would
 * only invite the model to start rewriting things it does not own.
 */
export function agentReelInstruction(req: AgentReelRequest): string {
  const about = req.subject === "agent"
    ? "The agent is talking about THEMSELVES — their service, their market, their record. " +
      "The photographs are supporting evidence, not the subject."
    : "The agent is talking about ONE PROPERTY. The photographs are that property.";

  return [
    "You are the editor of a short vertical video for a real-estate agent who has already",
    "filmed themselves speaking to camera. You are NOT writing the script: every word in",
    "this reel has already been said. You decide only what the viewer sees when the agent",
    "cuts away, and what few words appear on screen.",
    "",
    about,
    "",
    "RULES:",
    "1. You are given CUTAWAY WINDOWS that are already fixed. You cannot add, remove,",
    "   move, lengthen or reorder them. Answer for the window_ids you were given.",
    "2. For each window pick the ONE photograph that best matches WHAT IS BEING SAID",
    "   underneath it. If the agent says the kitchen opens onto the deck, that window",
    "   shows the kitchen or the deck — not the next picture in the list.",
    "3. A photograph may be used more than once across the reel, but never in two",
    "   windows in a row.",
    "4. If no photograph honestly matches a window, return an empty photo_id for it.",
    "   A window that stays on the agent's face is a better reel than a window showing",
    "   a bathroom while they talk about the school district.",
    `5. on_screen_text is at most ${MAX_OVERLAY_WORDS} words and ${MAX_OVERLAY_CHARS}`,
    "   characters, upper case, and it must NOT repeat what is being said out loud. It",
    "   adds a number, a name or a fact the ear cannot catch. Leave it empty rather than",
    "   padding it.",
    "6. Never describe or address the people who might live somewhere. Describe the",
    "   property and the service only.",
    "",
    toneDirection(req.tone),
    "",
    'Answer with JSON only: {"windows":[{"window_id":"w1","photo_id":"...","on_screen_text":"..."}]}',
  ].join("\n");
}

/** The turn: the facts, the pictures on offer, and the windows with the words
 *  underneath them. Nothing else — the model does not need the whole transcript
 *  to fill a window, only the part it is covering. */
export function buildAgentReelTurn(req: AgentReelRequest): string {
  const parts: string[] = [];
  const facts = factLines(req.space, req.facts);
  if (facts.length) parts.push("FACTS:\n" + facts.map((f) => `- ${f}`).join("\n"));

  parts.push(
    "PHOTOGRAPHS:\n" +
      req.photos
        .map((p) => `- ${p.id}${p.room ? ` — ${p.room}` : ""}${p.caption_hint ? ` (${p.caption_hint})` : ""}`)
        .join("\n"),
  );

  parts.push(
    `CUTAWAY WINDOWS (the clip is ${t1(req.clipSeconds)}s long):\n` +
      req.windows
        .map((w) => `- ${w.window_id} @ ${w.start}s–${w.end}s — they are saying: "${w.says}"`)
        .join("\n"),
  );
  return parts.join("\n\n");
}

// ── The answer ───────────────────────────────────────────────────────────────

/** One cutaway, exactly as the route returns it. */
export interface Cutaway {
  window_id: string;
  start: number;
  end: number;
  /** "" when the model honestly had no match — the reel stays on the agent. */
  photo_id: string;
  room: string;
  motion: Motion;
  on_screen_text: string;
}

export interface AgentReelAnswer {
  cutaways: Cutaway[];
  covered_seconds: number;
  /** Every model-authored caption, joined for the output fair-housing gate. */
  surface: string;
}

/**
 * Turn one model answer into the finished edit, or null when it is unusable.
 *
 * CUTAWAYS ARE MATCHED BY window_id AND NEVER BY POSITION — the same guarantee
 * parseShotlist() makes about photo_id, for the same reason: a renumbered reply
 * must not be able to slide every picture onto the wrong sentence.
 *
 * A photo_id we never offered is dropped rather than trusted, and rule 3 (no
 * repeat in adjacent windows) is enforced HERE rather than asked for, because
 * the model is the thing assigning pictures and a rule the answer can break is
 * not a rule.
 *
 * Unusable means not one window got a picture: an edit with no cutaways is the
 * original clip, which the app can already produce without paying for a call.
 */
export function parseAgentReel(
  raw: string,
  windows: Window[],
  photos: ShotPhoto[],
): AgentReelAnswer | null {
  if (windows.length === 0) return null;
  const known = new Map(photos.map((p) => [p.id, p]));
  const obj = extractJsonObject(raw);
  const rows = obj && Array.isArray(obj.windows) ? (obj.windows as unknown[]) : [];

  const byWindow = new Map<string, { photo_id: string; caption: string }>();
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const r = row as Record<string, unknown>;
    const id = line(r.window_id, 16);
    if (!id || byWindow.has(id)) continue; // first entry wins, deterministically
    const pid = line(r.photo_id, MAX_PHOTO_ID_CHARS);
    byWindow.set(id, {
      photo_id: known.has(pid) ? pid : "", // an id we never offered is not a picture
      caption: captionFrom(r.on_screen_text),
    });
  }

  const cutaways: Cutaway[] = [];
  let previousPhoto = "";
  let previousMove: Motion | null = null;
  for (const w of windows) {
    const written = byWindow.get(w.window_id);
    // Rule 3, enforced not requested.
    let pid = written?.photo_id ?? "";
    if (pid && pid === previousPhoto) pid = "";
    const room = pid ? (known.get(pid)?.room ?? "") : "";
    const motion: Motion = pid ? moveFor(room, previousMove) : FALLBACK_MOVE;
    cutaways.push({
      window_id: w.window_id,
      start: w.start,
      end: w.end,
      photo_id: pid,
      room,
      motion,
      // A caption with no picture under it would burn text over the agent's own
      // face, which is the one frame in this reel that must stay clean.
      on_screen_text: pid ? (written?.caption ?? "") : "",
    });
    if (pid) {
      previousPhoto = pid;
      previousMove = motion;
    }
  }

  const filled = cutaways.filter((c) => c.photo_id);
  if (filled.length === 0) return null;

  const captions = cutaways.map((c) => c.on_screen_text).filter((t) => t.length > 0);
  return {
    cutaways,
    covered_seconds: t1(filled.reduce((n, c) => n + (c.end - c.start), 0)),
    surface: captions.join(SURFACE_SEPARATOR),
  };
}
