// drift.ts — the quality gate for AI-generated video: is it still HIS HOUSE?
//
// ── The incident ─────────────────────────────────────────────────────────────
//
// 2026-09-07. The owner sent a screenshot of a generated aerial: the roof tiles
// were smeared into a warped painterly mess and the geometry under them was
// invented. His words: "the photo to reel generator is changing how the house
// looks and that's false advertising — it has AI slop left over." He is right,
// and it is not a cosmetic complaint. Rendprop sells into real estate:
//
//   • CA AB 723 (in force 1 Jan 2026) requires disclosure of AI-altered listing
//     media. A clip that invents the geometry of a real property is past
//     "altered" and into "not the property".
//   • NorthstarMLS requires a before image per altered room — which is only
//     meaningful if the after image is the same room.
//   • HUD guidance governs what generated marketing media may depict.
//
// A clip that redraws a real house, published on a real listing, is a
// liability. Not a polish item.
//
// ── Why prompt-tuning does not fix this, and why this module exists ──────────
//
// The reel and the grounded aerial are IMAGE-TO-VIDEO: one still photograph in,
// several seconds of video out. Any camera move that shows a surface the
// photograph never contained — a rise over a roof, an orbit to the far side of
// a room — is a request for the model to INVENT that surface. It will. That is
// what the model is for.
//
// The prompt already says, in ai-video/motion.ts buildReelPrompt(): "Do not
// add, remove, or move any objects; no scene changes, style shifts, warping, or
// flicker." The aerial's own AERIAL_GUARDRAILS says "no morphing or warping
// structures, no added or removed buildings". The model did it anyway. A
// stronger sentence is not the fix; a sentence is not a constraint.
//
// So this module does the only thing that actually helps: it JUDGES THE OUTPUT
// against the SOURCE and refuses the bad ones before the user ever sees them.
// The vocabulary, the thresholds, the parser and the decision live here, pure
// and testable (ai-video/drift.test.ts); the route wiring, the provider call,
// the meter and the audit rows live in ai-video/index.ts, which calls
// Deno.serve at module load and so can never be imported by a test — the same
// split dronecost.ts and motion.ts already make.
//
// ── The infrastructure was already here ──────────────────────────────────────
//
// `judge.qc_drift` has been seeded in migration 0018 since the router landed —
// three steps (claude-haiku-4-5 0.66¢, claude-sonnet-5 1.3¢ "escalation",
// gpt-5.6-luna 0.12¢ "a genuinely independent third opinion"), described in its
// own comment as a "4-image verdict" — and it had ZERO callers. So did
// `text.listing_copy` until ai-copy landed. This is that table's second unused
// route being used. `_shared/providers/anthropic.ts` even documents its image
// blocks as "up to four frames for QC".
//
// The Python pipeline has run exactly this gate on PHOTOS for months
// (services/pipeline/providers/anthropic_qc.py — "ARCHITECTURE NEVER CHANGES",
// 0–100 axes, verdict pass|regen|fail, defensive coercion that fails toward
// not-shipping). Everything below is that doctrine, moved to video and to the
// edge runtime, deliberately keeping its numbers (85 to pass, escalate below
// 0.75 confidence) so the two gates cannot drift apart in what they call good.
//
// ── FAIL CLOSED, everywhere ──────────────────────────────────────────────────
//
// A judge that cannot reach its model must never read as a pass. Three separate
// paths enforce that here, because there are three separate ways to fail:
//
//   1. no model answered at all              → unavailableVerdict() → "hold"
//   2. the model answered unreadable JSON    → judgement "unknown"  → "hold"
//   3. the model answered a pass but some
//      field of it did not parse             → downgraded to "unknown" → "hold"
//
// "hold" is not "retry": re-running a 24¢ generation because our PARSER hiccuped
// spends the customer's money on our bug. Hold means the clip stays unpublished
// and the check can be run again. Only a verdict the model actually delivered,
// and that actually says the property changed, spends money on a retry.

// ── The task, and the prices it is judged against ────────────────────────────
//
// The task id is the one migration 0018 seeded. Nothing here re-prices it: the
// route rows are authoritative, and DRIFT_FALLBACK_CENTS below exists only for
// the in-code chain the route falls back to when the routing table is
// unreadable (the same shape ai-copy's fallbackStep() uses).

export const DRIFT_TASK = "judge.qc_drift";

/**
 * The two steps the in-code fallback chain runs, mirroring rows 1 and 2 of
 * `judge.qc_drift` in migration 0018 VERBATIM. Step 3 (gpt-5.6-luna) is
 * deliberately not mirrored: it is seeded as an A/B candidate and an
 * independent third opinion, and a hardcoded fallback should carry the two
 * steps whose behaviour on this exact rubric is understood.
 */
export const DRIFT_FALLBACK_CENTS = { primary: 0.66, escalation: 1.3 } as const;

/**
 * ── THE COST ARITHMETIC (item 5), stated where it can be checked ─────────────
 *
 * WHAT THE CHECK COSTS. One 4-image call on `judge.qc_drift` step 1:
 *
 *     claude-haiku-4-5, unit "call", 0.66¢          (migration 0018, row 431)
 *
 * WHAT IT PROTECTS, from _shared/ledger.ts APP_AI_UNIT_CENTS (the same numbers
 * services/pipeline/providers/costs.py and the admin inventory hold):
 *
 *     reel clip        Seedance 1.0 Pro Fast   4.8¢/s × 5 s  = 24.0¢
 *     grounded aerial  Seedance                4.8¢/s × 6 s  = 28.8¢
 *                                              4.8¢/s × 8 s  = 38.4¢
 *     ungrounded aerial Veo 3.1 Fast           flat per clip = 80.0¢
 *
 *     0.66 / 24.0  = 2.75 %      0.66 / 28.8 = 2.29 %
 *     0.66 / 38.4  = 1.72 %      0.66 / 80.0 = 0.83 %
 *
 * So the gate costs between 0.8 % and 2.8 % of the generation it is checking.
 * That is a good trade and it is not close: one clip caught is one clip we do
 * not pay to publish, one listing that does not carry a house nobody owns, and
 * one AB 723 problem that does not exist. At 2.75 % the check pays for itself
 * if it catches one clip in thirty-six.
 *
 * WHY THREE FRAMES AND NOT THE WHOLE CLIP. A 5 s clip at 24 fps is 120 frames;
 * sampled at 8 fps it is still 40 images. Images dominate the token bill on a
 * vision call, so 0018's own 4-image price of 0.66¢ implies roughly 0.15¢ an
 * image once the ~500-token rubric is amortised — 40 images is therefore ~6¢,
 * a quarter of the 24¢ clip it is checking. 4 images is 0.66¢ and 2.75 %.
 * Twenty-five percent is a tax; two point seven five is a rounding error.
 *
 * AND THREE IS ENOUGH, for a reason particular to image-to-video: drift is
 * cumulative. The model starts ON the photograph — frame one is nearly always
 * faithful, which is exactly why a check that looked only at the poster frame
 * (the one PosterMaker already grabs at 0.25 s) would have passed the aerial in
 * the screenshot. The invention accrues as the camera travels, so the LAST
 * frame is the maximum-drift sample and the one that matters most. The MIDDLE
 * frame catches the transient morph that resolves before the end. The FIRST
 * frame catches the rarer case where the model rewrites the scene immediately.
 * Source + first + middle + last = the 4-image call 0018 priced.
 *
 * THE ESCALATION IS ALSO ARITHMETIC. When the cheap judge reports low
 * confidence we pay 1.3¢ for a second opinion from claude-sonnet-5 (0018's own
 * word for row 2 is "escalation") instead of treating "not sure" as a failure.
 * Treating it as a failure would trigger a retry: another 24¢ generation plus
 * another 0.66¢ check. So escalating is worth it if it rescues more than about
 * one low-confidence verdict in nineteen (1.3 / 24.66). It rescues far more
 * than that — low confidence usually means a dim or ambiguous frame, not a
 * ruined one. This is the same escalation the Python pipeline runs, kept for a
 * reason that is specific to the edge route: there, a regen costs 4¢ and runs
 * in a loop; here it costs 24¢ and a person is waiting for it.
 */
export const DRIFT_FRAME_POSITIONS = ["first", "middle", "last"] as const;
export type DriftFramePosition = typeof DRIFT_FRAME_POSITIONS[number];

/** Source + first + middle + last: the 4-image verdict migration 0018 priced. */
export const DRIFT_MAX_FRAMES = DRIFT_FRAME_POSITIONS.length;

// ── What is being judged ─────────────────────────────────────────────────────
//
// Five axes, each 0–100 where 100 is "identical to the source". They are not
// interchangeable and they are not averaged, because they answer to different
// authorities: `architecture` is the one AB 723 and the MLS care about,
// `additions` is the one HUD and the fair-housing lock care about, and
// `artifacts` is the one the owner was actually looking at when he wrote "AI
// slop". A clip fails if ANY axis fails — see DRIFT_PASS_SCORES.

export const DRIFT_CATEGORIES = [
  "architecture",
  "contents",
  "additions",
  "artifacts",
  "same_room",
] as const;
export type DriftCategory = typeof DRIFT_CATEGORIES[number];

/** What each axis means, in the words the rubric uses. Read before editing. */
export const DRIFT_CATEGORY_TEXT: Record<DriftCategory, string> = {
  architecture:
    "walls, roof lines and roof surface, windows, doors, columns, stairs, built-in " +
    "cabinetry, counters, floors, ceilings, exterior materials and cladding, the " +
    "shape and proportions of the building, and the view through every window",
  contents:
    "the free-standing contents: furniture, rugs, lamps, art, plants, appliances, " +
    "vehicles, and landscaping — nothing may move, appear, vanish or change kind",
  additions:
    "people, faces, pets or other animals, text, captions, logos, watermarks, " +
    "signage, flags, or religious and cultural objects that are not in the source",
  artifacts:
    "melting, smearing, warping, rippling, ghosting, duplicated or impossible " +
    "geometry, flicker, and painterly or plastic surfaces where the photograph is sharp",
  same_room:
    "whether this is still the same room, the same building and the same camera " +
    "position as the source photograph at all",
};

/**
 * The bar each axis has to clear, and why each number is where it is.
 *
 * `architecture` is 85 — the SAME number services/pipeline/config.py has used
 * for photo QC since the pipeline shipped (`qc_pass_score: int = 85`). Two
 * gates on the same product must not disagree about what "the architecture is
 * unchanged" means, so this one is copied rather than chosen.
 *
 * `additions` is 90, the strictest bar here. A person the photograph did not
 * contain is not a quality bug, it is a fair-housing exposure: _shared/
 * fairhousing.ts spends four hundred lines keeping invented people out of
 * generated listing media, and a video that puts one back in walks straight
 * past all of it. Same for a watermark or a logo, which is somebody else's
 * trademark on our customer's listing.
 *
 * `same_room` is 90 for the reason the incident exists: "it is not his house"
 * is the whole complaint, and it is the one failure a buyer notices from the
 * kerb.
 *
 * `contents` is 80. Furniture that shifts a little between a still and a moving
 * shot is partly parallax, which is the point of the clip; a sofa that becomes
 * a different sofa is not, and scores far below 80 when a judge is asked
 * specifically about it.
 *
 * `artifacts` is 75, the most permissive. Generated video is not photography
 * and never will be: some softness in motion is the medium, and a bar set where
 * the others are would reject every clip the product sells. 75 rejects the
 * smeared roof in the screenshot — which no judge scores above about 30 — while
 * passing an honest clip that is merely soft in the last half second.
 */
export const DRIFT_PASS_SCORES: Record<DriftCategory, number> = {
  architecture: 85,
  contents: 80,
  additions: 90,
  artifacts: 75,
  same_room: 90,
};

/**
 * Below this self-reported confidence the cheap judge's answer is not acted on;
 * the route escalates to `judge.qc_drift` step 2 (see the arithmetic above).
 * The number is services/pipeline/config.py's `qc_confidence_escalate` (0.75),
 * kept identical for the same reason the pass score is.
 */
export const ESCALATE_BELOW_CONFIDENCE = 0.75;

/**
 * The move a rejected clip is retried with.
 *
 * A push-in only ever shows LESS of the frame than the photograph already
 * contains, so it is the one move in either vocabulary that cannot ask the
 * model to invent a surface — ai-video/motion.ts says exactly this about it
 * ("SAFEST MOVE IN THE SET, and therefore the fallback everywhere"). It is a
 * member of BOTH REEL_MOTIONS and AERIAL_MOTIONS, which is what lets one
 * constant serve both kinds; drift.test.ts asserts that, so a future edit to
 * either enum that dropped it would fail the suite rather than fail a retry.
 */
export const SAFEST_MOTION = "push_in";

// ── The verdict ──────────────────────────────────────────────────────────────

export type DriftJudgement = "pass" | "regen" | "fail" | "unknown";

export type DriftScores = Record<DriftCategory, number>;

export interface DriftVerdict {
  /** The model's own summary judgement, downgraded by the parser when unsafe. */
  judgement: DriftJudgement;
  scores: DriftScores;
  /** The headline number: the architecture axis, because that is the legal one. */
  score: number;
  /** 0–1, self-reported. Below ESCALATE_BELOW_CONFIDENCE the route escalates. */
  confidence: number;
  /** One sentence a human could read. Sanitised; never published to a tour. */
  reason: string;
  /** False when any field of the reply had to be coerced or was missing. */
  clean: boolean;
  /** True when no model answered at all — never a pass, never a retry. */
  unavailable: boolean;
}

const ZERO_SCORES: DriftScores = {
  architecture: 0,
  contents: 0,
  additions: 0,
  artifacts: 0,
  same_room: 0,
};

/** A fresh copy, so a caller can never mutate the shared zero object. */
function zeroScores(): DriftScores {
  return { ...ZERO_SCORES };
}

// ── The rubric ───────────────────────────────────────────────────────────────

/** What the clip is of, so the rubric can name it instead of saying "the scene". */
export interface DriftSubject {
  /** "reel" (a listing photo animated) or "aerial" (an establishing shot). */
  kind: "reel" | "aerial";
  /** "home", "restaurant", "store"… — index.ts's SCENE_NOUN for the space type. */
  sceneNoun: string;
  /** The camera move that was ASKED for, so the judge knows what is legitimate. */
  motionText?: string | null;
}

/**
 * The system rubric.
 *
 * Written for a property listing, not for "image quality" — which is the whole
 * point. A generic "does this look good" judge passes a beautiful clip of the
 * wrong house. Every instruction below names something a buyer, an MLS or a
 * regulator would care about, and the judge is told that the source photograph
 * is the ground truth and the video is the thing on trial.
 *
 * It also tells the judge what is NOT a failure, and that matters as much: a
 * clip is supposed to move. Parallax, a widening frame edge, motion blur and
 * changing perspective are the product working. A rubric that does not say so
 * produces a judge that fails everything, which costs a retry every time and
 * teaches the team to switch the gate off.
 */
export function driftRubric(subject: DriftSubject): string {
  const noun = subject.sceneNoun.trim() || "property";
  const what = subject.kind === "aerial"
    ? `an AI-generated aerial establishing shot of a real ${noun}`
    : `an AI-generated video clip animated from one real photograph of a ${noun}`;
  return [
    `You are Rendprop's drift judge for real-estate marketing video. You are given ONE SOURCE ` +
    `PHOTOGRAPH of a real property that is for sale or for rent, and up to three FRAMES taken ` +
    `from ${what} that was generated from that photograph.`,
    ``,
    `THE SOURCE PHOTOGRAPH IS THE TRUTH. The video is on trial. This media will be published on ` +
    `a real estate listing, so a video that shows a property different from the photographed one ` +
    `is false advertising, not a quality problem: California AB 723 requires AI-altered listing ` +
    `media to be disclosed, MLS rules require the altered media to be of the same room, and fair ` +
    `housing rules govern who and what may appear in it.`,
    ``,
    `Judge the OUTPUT FRAMES against the SOURCE on five axes, each scored 0-100 where 100 means ` +
    `"identical to the source" and 0 means "a different property".`,
    ...DRIFT_CATEGORIES.map((c, i) => `  ${i + 1}. ${c} — ${DRIFT_CATEGORY_TEXT[c]}.`),
    ``,
    `WHAT IS NOT A FAILURE. The clip is supposed to move. Do not penalise: camera motion itself; ` +
    `parallax; a frame edge that widens or narrows as the camera travels; a change of viewing ` +
    `angle consistent with that motion; motion blur; ordinary video compression; a small overall ` +
    `shift in exposure or white balance.` +
    (subject.motionText ? ` The move this clip was asked for was: ${subject.motionText}.` : ``),
    ``,
    `WHAT IS ALWAYS A FAILURE, however good it looks: a roof, wall, window, door or room that is ` +
    `drawn rather than photographed; a surface that melts, smears or ripples; a person, face, ` +
    `animal, logo, watermark or caption that is not in the source; a room that has become a ` +
    `different room.`,
    ``,
    `Also report:`,
    `  confidence (0.0-1.0): how sure you are. Lower it when the frames are dark, small, ` +
    `motion-blurred, or the source photograph does not show the area the camera moved into.`,
    `  verdict: "pass"  = publish it; the property is unchanged.`,
    `           "regen" = recoverable; worth generating once more with a safer camera move.`,
    `           "fail"  = the property itself changed, or something was added that must not be ` +
    `there. Never publish.`,
    `  reason: ONE plain sentence, under 200 characters, that a real estate agent could read and ` +
    `act on. Name the thing that changed and where. Do not describe people beyond their presence.`,
    ``,
    `Reply with ONLY a compact JSON object, no prose, exactly these keys:`,
    `{"architecture": <int>, "contents": <int>, "additions": <int>, "artifacts": <int>, ` +
    `"same_room": <int>, "confidence": <float>, "verdict": "pass|regen|fail", "reason": "<string>"}`,
  ].join("\n");
}

/** The label that introduces the source image in the user turn. */
export const DRIFT_SOURCE_LABEL =
  "SOURCE PHOTOGRAPH — the real property, as photographed:";

/** The label that introduces the generated frames, in clip order. */
export function driftFramesLabel(positions: readonly DriftFramePosition[]): string {
  return `GENERATED VIDEO FRAMES to judge (${positions.join(", ")} of the clip, in order):`;
}

// ── Parsing a model's reply ──────────────────────────────────────────────────
//
// Directly modelled on services/pipeline/providers/anthropic_qc.py's `_Coerce`
// (audit F-G-19: "A judge that replies `"structure": "92"`, `95.0`, `"n/a"` or
// omits a key used to raise ValueError deep inside the loop and kill the
// enhancement pass"). Every field coerces; any coercion failure marks the
// verdict unclean; an unclean PASS is never treated as a pass.

/**
 * A number out of a model's reply, or null when the value cannot be read as one.
 *
 * NUMBERS AND NUMERIC STRINGS ONLY. `Number(null)`, `Number("")` and
 * `Number([])` are all 0 in JavaScript, so a plain `Number()` would read a
 * MISSING axis as a score of zero — which reads as a catastrophic failure and
 * would trigger a paid retry — and, worse, `Number(true)` is 1. Python's
 * `float(None)` raises instead, which is why the pipeline's own coercion
 * degrades the verdict here; this reproduces that behaviour rather than
 * JavaScript's.
 */
function coerceNumber(raw: unknown): number | null {
  if (typeof raw === "number") return Number.isFinite(raw) ? raw : null;
  if (typeof raw !== "string") return null;
  const s = raw.trim();
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

/** 0–100 integer, or null when the value cannot be read as one. */
function coerceScore(raw: unknown): number | null {
  const n = coerceNumber(raw);
  if (n === null) return null;
  return Math.max(0, Math.min(100, Math.round(n)));
}

/** 0–1 float, or null. */
function coerceConfidence(raw: unknown): number | null {
  const n = coerceNumber(raw);
  if (n === null) return null;
  return Math.max(0, Math.min(1, n));
}

/**
 * One sentence, safe to put in an API response and render in the app.
 *
 * NOT run through _shared/fairhousing.ts, deliberately. That gate polices
 * MARKETING COPY — text that will be published under the agent's licence — and
 * this sentence is the opposite: an internal QC note whose entire job may be to
 * say "a person appears on the sofa who is not in your photo". Refusing it for
 * mentioning a person would blind the one check that exists to catch invented
 * people. So it is bounded and stripped instead, and it is never published to a
 * tour, never written to media_provenance.prompt_summary, and never shown to a
 * consumer — the app shows it to the agent who took the photograph.
 */
export function sanitizeJudgeSentence(raw: unknown): string {
  return String(raw ?? "")
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

/** The first balanced-looking JSON object in a reply, fences and prose survived. */
function firstJsonObject(text: string): Record<string, unknown> | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;
  try {
    const parsed = JSON.parse(text.slice(start, end + 1));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

/**
 * A model's raw reply → a verdict that is safe to act on.
 *
 * THE CONTRACT: this function never throws, and it never returns a `pass` it is
 * not sure about. Everything else is best effort.
 *
 * The three downgrades, in the order they apply:
 *   • nothing parseable at all      → "unknown", zero scores, clean:false
 *   • some fields unparseable       → clean:false; a "pass" becomes "unknown"
 *   • a parsed pass whose scores do
 *     not actually clear the bars   → left alone here; driftPasses() is the
 *                                     one place the bars are applied, so the
 *                                     model cannot talk its way past them
 */
export function parseDriftVerdict(raw: string): DriftVerdict {
  const cleanedText = String(raw ?? "").trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  const obj = firstJsonObject(cleanedText);
  if (!obj) {
    return {
      judgement: "unknown",
      scores: zeroScores(),
      score: 0,
      confidence: 0,
      reason: "The quality check could not be read, so this clip has not been verified.",
      clean: false,
      unavailable: false,
    };
  }

  let clean = true;
  const scores = zeroScores();
  for (const c of DRIFT_CATEGORIES) {
    const v = coerceScore(obj[c]);
    if (v === null) clean = false;
    else scores[c] = v;
  }

  const confidence = coerceConfidence(obj.confidence);
  if (confidence === null) clean = false;

  const rawVerdict = String(obj.verdict ?? "").trim().toLowerCase();
  let judgement: DriftJudgement;
  if (rawVerdict === "pass" || rawVerdict === "regen" || rawVerdict === "fail") {
    judgement = rawVerdict;
  } else {
    judgement = "regen";
    clean = false;
  }

  let reason = sanitizeJudgeSentence(obj.reason);
  if (!reason) {
    clean = false;
    reason = "The quality check returned no explanation.";
  }

  // The unclean-pass downgrade. The Python gate turns this into "regen"; here
  // it becomes "unknown", which HOLDS rather than spending 24¢ regenerating a
  // clip that may well be fine because OUR parser could not read one field.
  // See the module header, FAIL CLOSED.
  if (!clean && judgement === "pass") {
    judgement = "unknown";
    reason = `${reason} (the check's reply was partly unreadable, so it is not counted as a pass)`
      .slice(0, 200);
  }

  return {
    judgement,
    scores,
    score: scores.architecture,
    confidence: confidence ?? 0, // unknown confidence escalates, exactly as the pipeline does
    reason,
    clean,
    unavailable: false,
  };
}

/**
 * The verdict when NO model answered — every step of the chain threw, or the
 * provider key is missing, or the whole task timed out.
 *
 * Not a pass and not a failure of the CLIP: it is a failure of the CHECK, and
 * the two must never be confused. `unavailable: true` routes to "hold".
 */
export function unavailableVerdict(reason: string): DriftVerdict {
  return {
    judgement: "unknown",
    scores: zeroScores(),
    score: 0,
    confidence: 0,
    reason: sanitizeJudgeSentence(
      reason || "The quality check could not reach its model, so this clip has not been verified.",
    ),
    clean: false,
    unavailable: true,
  };
}

/**
 * Does this clip clear the gate?
 *
 * BOTH conditions, exactly as services/pipeline/router.py `passes()` requires
 * both: the judge's own summary verdict must be "pass" AND every axis must
 * clear its own bar. The axes are ANDed, never averaged — an average lets a
 * perfect score on `contents` pay for a ruined roof, which is precisely the
 * clip this whole module exists to stop.
 */
export function driftPasses(v: DriftVerdict): boolean {
  if (v.unavailable) return false;
  if (v.judgement !== "pass") return false;
  if (!v.clean) return false;
  return DRIFT_CATEGORIES.every((c) => v.scores[c] >= DRIFT_PASS_SCORES[c]);
}

/** Which axes failed, best-first, for the message and the audit row. */
export function failedCategories(v: DriftVerdict): DriftCategory[] {
  if (v.unavailable) return [];
  return DRIFT_CATEGORIES.filter((c) => v.scores[c] < DRIFT_PASS_SCORES[c]);
}

// ── What happens on a bad verdict ────────────────────────────────────────────

export type DriftAction = "accept" | "retry" | "refuse" | "hold";
export type DriftStatus = "pass" | "fail" | "unavailable" | "unchecked";

export interface DriftDecisionArgs {
  verdict: DriftVerdict;
  /**
   * How many clips have ALREADY been rejected for this source still. 0 = this
   * is the first attempt. The route derives it from durable state keyed on the
   * source image itself, never from the client's word (see index.ts).
   */
  attempt: number;
  /**
   * Whether the server still holds this source still's ONE retry grant. The
   * route spends it with the same durable limiter every other quota uses, so
   * "exactly once" survives a restart, two instances and a retried request.
   */
  retryGranted: boolean;
}

export interface DriftDecision {
  action: DriftAction;
  status: DriftStatus;
  /** The single field a client should gate publishing on. Never true on doubt. */
  publishable: boolean;
  /** Honest, plain, and written to be shown to the agent as-is. */
  message: string;
  /** Set only when action === "retry": what the second attempt must use. */
  retryMotion?: string;
}

/**
 * The policy, in one pure function.
 *
 *   pass                        → accept
 *   fail, first time, grant     → retry ONCE with the safest possible move
 *   fail, again (or no grant)   → refuse, and offer the still photo instead
 *   check unavailable/unreadable→ hold: not published, not regenerated, re-check
 *
 * WHY EXACTLY ONE RETRY. A second attempt is worth having because the same
 * photograph animated with a push-in instead of a rise is a genuinely different
 * request, and it usually works. A THIRD attempt is not: by then the evidence
 * says this photograph cannot be animated cleanly — a flat roof shot from the
 * kerb has no second storey to reveal no matter how the camera moves — and
 * every further attempt spends 24¢ and the agent's afternoon to produce the
 * same disappointment. The honest thing at that point is to say so and hand
 * back the still, which is what the Python pipeline already does for photos
 * ("QC never passed — segment ships as ORIGINAL, never a bad edit").
 *
 * WHY THE STILL IS A REAL ANSWER AND NOT A CONSOLATION PRIZE. The still is the
 * photograph the agent took. It is the only asset in this flow that is
 * unambiguously the property, needs no AB 723 disclosure, and cannot be
 * challenged by a buyer standing in the driveway.
 */
export function decideDriftAction(args: DriftDecisionArgs): DriftDecision {
  const { verdict } = args;

  if (verdict.unavailable || verdict.judgement === "unknown") {
    return {
      action: "hold",
      status: "unavailable",
      publishable: false,
      message:
        "We couldn't check this clip against your photo just now, so it hasn't been approved. " +
        "Try the check again in a moment — the clip is saved.",
    };
  }

  if (driftPasses(verdict)) {
    return {
      action: "accept",
      status: "pass",
      publishable: true,
      message: "Checked against your photo: the property is unchanged.",
    };
  }

  const failed = failedCategories(verdict);
  const what = describeFailure(failed, verdict);

  if (args.attempt <= 0 && args.retryGranted) {
    return {
      action: "retry",
      status: "fail",
      publishable: false,
      retryMotion: SAFEST_MOTION,
      message:
        `${what} We're not publishing that, so we're generating it once more with the safest ` +
        `camera move — a slow push in, which can only ever show less of your photo, never more. ` +
        `This retry doesn't use another clip from your plan.`,
    };
  }

  return {
    action: "refuse",
    status: "fail",
    publishable: false,
    message:
      `${what} We tried again with the safest camera move and it still changed the property, so ` +
      `we're stopping rather than publishing a clip of a house that isn't yours. Use the still ` +
      `photo for this shot — it's the honest version, and it needs no AI disclosure.`,
  };
}

/**
 * The failure, in the agent's language.
 *
 * The judge's own sentence is preferred — it names the actual thing, and a
 * specific sentence is what makes a person believe the check rather than
 * switch it off. The category fallback exists for the case where the model
 * returned scores but no usable reason.
 */
function describeFailure(failed: DriftCategory[], verdict: DriftVerdict): string {
  const sentence = verdict.reason.trim();
  if (sentence) {
    return /[.!?]$/.test(sentence) ? sentence : `${sentence}.`;
  }
  const named: Record<DriftCategory, string> = {
    architecture: "the building's own shape changed",
    contents: "the furniture moved or changed",
    additions: "something appeared that isn't in your photo",
    artifacts: "parts of the picture smeared or melted",
    same_room: "it stopped being the same place",
  };
  const list = failed.length > 0 ? failed.map((c) => named[c]).join(", and ") : "the clip drifted from your photo";
  return `The AI changed your property in this clip: ${list}.`;
}

// ── The block both routes return ─────────────────────────────────────────────
//
// ONE shape, so a client reads the same object whether it came from
// GET /ai-video/status (which can only ever say "not checked yet") or from
// POST /ai-video/drift (which carries the verdict). Every field is additive:
// the shipped build decodes the fields it names and ignores the rest, so an
// installed copy of build 5 is unaffected by all of this.

export interface DriftBlock extends Record<string, unknown> {
  status: DriftStatus;
  publishable: boolean;
  action: DriftAction | "check";
  message: string;
}

/**
 * What GET /ai-video/status says about a completed clip nobody has checked.
 *
 * `publishable: false` is the load-bearing field, and it is why this block is
 * emitted at ALL rather than being left out when there is no verdict: silence
 * reads as approval. An unchecked clip is not a passed clip, and the response
 * says so in the same words a failed one would.
 */
export function uncheckedDriftBlock(): DriftBlock {
  return {
    status: "unchecked",
    publishable: false,
    action: "check",
    message:
      "This clip hasn't been checked against your photo yet. Run the quality check before " +
      "publishing it.",
    check: {
      method: "POST",
      path: "/ai-video/drift",
      // The client already knows how to do this: PosterMaker in the iOS app
      // pulls a frame with AVAssetImageGenerator at 0.25 s to make a tour
      // poster. This asks for three of them at known positions plus the still
      // the clip was generated from.
      frames: DRIFT_FRAME_POSITIONS,
      sends: ["request_id", "kind", "source_b64", "frames[]"],
    },
  };
}

/** The full block for a clip that has been judged. */
export function driftBlock(args: {
  decision: DriftDecision;
  verdict: DriftVerdict;
  provider: string;
  model: string;
  escalated: boolean;
  framesJudged: number;
  attempt: number;
}): DriftBlock {
  const { decision, verdict } = args;
  return {
    status: decision.status,
    publishable: decision.publishable,
    action: decision.action,
    message: decision.message,
    verdict: verdict.judgement,
    scores: verdict.scores,
    score: verdict.score,
    thresholds: DRIFT_PASS_SCORES,
    failed: failedCategories(verdict),
    confidence: Math.round(verdict.confidence * 100) / 100,
    reason: verdict.reason,
    provider: args.provider,
    model: args.model,
    escalated: args.escalated,
    frames_judged: args.framesJudged,
    attempt: args.attempt,
    // A machine-readable retry instruction, so a client does not have to parse
    // the sentence: re-submit the SAME photo to the same generate route with
    // this motion, then check the new clip with `attempt: next_attempt`. That
    // second check will refuse rather than retry, which is the point.
    ...(decision.retryMotion
      ? { retry: { motion: decision.retryMotion, next_attempt: args.attempt + 1 } }
      : {}),
  };
}

// ── Lineage ──────────────────────────────────────────────────────────────────

/**
 * The identity of the SOURCE STILL, so "retry exactly once" is a fact about the
 * photograph rather than about whatever id a client chose to send.
 *
 * A retry is a NEW generation with a new request id and a new provenance row,
 * so nothing in the job identifiers ties attempt 2 to attempt 1. The one thing
 * that IS the same across both is the photograph, and we already have its bytes
 * in hand — so the counter is keyed on a hash of them. A client cannot dodge
 * the limit by renaming anything, and two agents in the same org animating two
 * different photos never collide.
 *
 * SHA-256, truncated to 32 hex characters (128 bits): this is a cache key, not
 * a signature, and 128 bits is far past any accidental collision inside one
 * org's month of photographs.
 */
export async function driftLineageKey(sourceB64: string): Promise<string> {
  const bytes = new TextEncoder().encode(String(sourceB64 ?? ""));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}
