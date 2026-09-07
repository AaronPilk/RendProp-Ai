// ai-copy — the words. Industry vocabulary, the two instruction builders, the
// character budget arithmetic, and the parsing/clamping every model answer goes
// through before anyone sees it.
//
// PURE. Zero imports, no Deno.env, no network, no Supabase — deliberately, for
// two reasons:
//
//   1. A test can read the EXACT words we send (ai-chapters/prompt.ts sets the
//      same precedent), and every number below is asserted in prompt_test.ts.
//   2. ai-photo/index.ts imports `editPromptInstruction()` from here. That is a
//      reach into a sibling function's folder, which resolves exactly the way
//      `../_shared/…` does (both are under functions/, both are followed by the
//      bundler) — but it only stays cheap while this file drags nothing behind
//      it. Keep it importing nothing. The compliance loop that DOES need
//      _shared/fairhousing.ts lives next door in guard.ts, which ai-photo does
//      not import.
//
// ── WHY THIS FILE EXISTS AT ALL (the asymmetry it closes) ────────────────────
//
// ai-photo gives a PRESET edit about sixty words of engineered direction
// (RE_PROMPTS + STAGE_LOCK + RE_STAGE_STYLES): what changes, what stays
// identical, materials, shadows, perspective. A CUSTOM edit got one sentence
// wrapped around whatever the user typed (`customPrompt()`), so the user's raw
// words carried the entire semantic load — a marketer who is not a prompt
// engineer got a visibly worse edit than one who tapped a preset button.
// `editPromptInstruction()` is the fix: it asks the model to write the SAME
// density of direction a preset carries, from a rough idea.
//
// The reel script is the other half of the same complaint ("describing a script
// for the reel so that way prompting is perfect"). It is MARKETING copy, not a
// house description: hook first, the facts that actually sell in the industry's
// own vocabulary, and a close that tells the viewer what to do.
//
// VOCABULARY is not invented here. It mirrors `SpaceType` in
// apps/ios/Rendprop/Models/Listing.swift (spaceNoun, customerNoun, areaNoun,
// ctaTitle, pitch) — the same mirror coach/prompt.ts and ai-chapters/prompt.ts
// keep. A script that says "buyers" about a gym reads as a bug the first time
// the owner hears it played back over their own footage.

// ── Space types (mirror of SpaceType in Models/Listing.swift) ────────────────

export const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
export type SpaceType = typeof SPACE_TYPES[number];

/** Coerce anything (a body field, a listing row) into a known space type.
 *  Unknown/missing → real_estate, the same default `SpaceType.current` uses. */
export function spaceTypeOf(raw: unknown): SpaceType {
  const s = String(raw ?? "").trim().toLowerCase().replace(/-/g, "_");
  return (SPACE_TYPES as readonly string[]).includes(s) ? (s as SpaceType) : "real_estate";
}

interface Vocab {
  /** Listing.spaceNoun — "home" | "venue" | "place" | "store" | "studio" | "space". */
  space: string;
  /** Listing.customerNoun — who is watching: "buyers" | "planners" | … */
  customer: string;
  /** Listing.areaNoun — "room" for real estate, "area" for everything else. */
  area: string;
  /** Listing.ctaTitle — the tour's own end-card CTA, so the script's close and
   *  the button the viewer then taps say the same thing. */
  cta: string;
  /** Listing.pitch — the one-line promise, the register the script should hit. */
  pitch: string;
  /** ai-photo's PROFILES[x].photo — "real-estate photo", "restaurant photo", … */
  photo: string;
  /** ai-photo's PROFILES[x].audience — who is asking for the edit. */
  audience: string;
}

const VOCAB: Record<SpaceType, Vocab> = {
  real_estate: {
    space: "home",
    customer: "buyers",
    area: "room",
    cta: "Book a showing",
    pitch: "Sell homes with cinematic tours",
    photo: "real-estate photo",
    audience: "a real-estate agent",
  },
  venue: {
    space: "venue",
    customer: "planners",
    area: "area",
    cta: "Plan your event",
    pitch: "Book more events",
    photo: "event-venue photo",
    audience: "an event-venue manager",
  },
  restaurant: {
    space: "place",
    customer: "guests",
    area: "area",
    cta: "Book a table",
    pitch: "Fill more tables",
    photo: "restaurant photo",
    audience: "a restaurant owner",
  },
  retail: {
    space: "store",
    customer: "shoppers",
    area: "area",
    cta: "Visit us",
    pitch: "Bring shoppers through the door",
    photo: "retail-store photo",
    audience: "a retail store owner",
  },
  fitness: {
    space: "studio",
    customer: "members",
    area: "area",
    cta: "Book a session",
    pitch: "Sign up more members",
    photo: "fitness-studio photo",
    audience: "a gym or studio owner",
  },
  other: {
    space: "space",
    customer: "customers",
    area: "area",
    cta: "Get in touch",
    pitch: "Show off any space",
    photo: "commercial-space photo",
    audience: "a business owner",
  },
};

export function vocabFor(space: SpaceType): Vocab {
  return VOCAB[space];
}

// ── The character budget ─────────────────────────────────────────────────────
//
// LENGTH IS A HARD CONSTRAINT, NOT A SUGGESTION.
//
// The reel stitcher lets VIDEO LENGTH WIN: if the voiceover runs longer than the
// stitched clips it HOLDS THE LAST VIDEO FRAME for the remainder rather than
// truncating the speaker (FlythroughDetailView.swift, `stitch(clips:…)`). So an
// over-long script does not get cut off — it produces a reel that ends on a
// frozen still while a voice keeps talking, which is the single most obviously
// amateur thing a "cinematic" tour can do.
//
// The rate comes from a number this repo already committed to: ai-voice's own
// length refusal says "a 1,000-character script is already about 90 seconds of
// speech" (services/supabase/functions/ai-voice/index.ts, MAX_TEXT_CHARS).
//
//     1000 chars ÷ 90 s = 11.1 chars/s  →  11 chars per second of video
//
// 11 (not 11.1) is deliberate: rounding DOWN the characters-per-second budget
// asks for a slightly shorter script, and short is free while long freezes a
// frame. `target_seconds` is 5 × clip count, so 10-45 in practice; at 45 s the
// ask is 495 characters, comfortably inside the ceiling.

/** Characters of script per second of finished video. See the note above. */
export const CHARS_PER_SECOND = 11;

/** The hard ceiling, matching ai-voice/index.ts MAX_TEXT_CHARS EXACTLY. A
 *  longer script is a 400 from /ai-voice/tts, i.e. a script the user cannot
 *  use — so this function must never produce one. */
export const MAX_SCRIPT_CHARS = 1000;

/** Floor/ceiling on `target_seconds`. The contract's range is 10-45 (5 × clip
 *  count); the accepted range is wider so an unusual client is clamped rather
 *  than refused, and 90 s is exactly where the 11 ch/s budget meets the
 *  1,000-character ceiling (90 × 11 = 990). */
export const MIN_TARGET_SECONDS = 5;
export const MAX_TARGET_SECONDS = 90;

/** Clamp a client-sent `target_seconds` into the usable range. Non-finite or
 *  missing → the low end: a script that is too short costs nothing. */
export function cleanTargetSeconds(raw: unknown): number {
  const n = Math.round(Number(raw));
  if (!Number.isFinite(n)) return MIN_TARGET_SECONDS;
  return Math.min(MAX_TARGET_SECONDS, Math.max(MIN_TARGET_SECONDS, n));
}

/**
 * How many characters of script `seconds` of video can carry.
 *
 * The clamp at MAX_SCRIPT_CHARS is the load-bearing half: `cleanTargetSeconds`
 * already keeps the product under the ceiling, but this function is also what
 * the OUTPUT is trimmed against, and belt-and-braces here is the difference
 * between a long answer being trimmed and a long answer being rejected by
 * /ai-voice/tts after the user has already accepted it.
 */
export function charBudgetFor(seconds: number): number {
  const raw = Math.round(Number(seconds) * CHARS_PER_SECOND);
  if (!Number.isFinite(raw) || raw <= 0) return 0;
  return Math.min(MAX_SCRIPT_CHARS, raw);
}

/** Seconds of speech a script of `chars` characters is expected to take, at the
 *  same rate. Returned to the client as `estimated_seconds` so the UI can show
 *  the fit against the reel's real length. One decimal. */
export function estimatedSecondsFor(chars: number): number {
  const n = Number(chars);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.round((n / CHARS_PER_SECOND) * 10) / 10;
}

// ── Tone ─────────────────────────────────────────────────────────────────────

export const TONES = ["warm", "punchy", "luxury"] as const;
export type Tone = typeof TONES[number];

/**
 * Unknown / absent tone → "warm".
 *
 * Warm is the only one of the three that is never a lie. "luxury" narrating a
 * $210,000 starter home, or "punchy" over a funeral-home walkthrough, is copy
 * the owner has to throw away; warm reads correctly for every industry and
 * every price. A default has to be the safe one, not the exciting one.
 */
export function toneOf(raw: unknown): Tone {
  const s = String(raw ?? "").trim().toLowerCase();
  return (TONES as readonly string[]).includes(s) ? (s as Tone) : "warm";
}

const TONE_DIRECTION: Record<Tone, string> = {
  warm: "Warm and human. Short, plain sentences. Invite, never oversell.",
  punchy:
    "Punchy and fast. Very short sentences, strong verbs, no filler words. " +
    "Written to survive a thumb hovering over the scroll.",
  luxury:
    "Understated and confident. Restrained, specific language; let the space " +
    "carry it. No superlatives, no exclamation marks.",
};

/** The one style direction for a tone. Exported because ai-copy/shotlist.ts
 *  writes to the same three tones and a second copy of these strings is the
 *  drift this file exists to prevent. */
export function toneDirection(tone: Tone): string {
  return TONE_DIRECTION[tone];
}

// ── The address placeholder (a privacy rule, not a formatting choice) ────────
//
// THE STREET ADDRESS IS NEVER SENT TO THIS FUNCTION. It is not in the request
// body and there is no field for it — the same line ai-video's aerial route
// already holds, where `cleanRegion()` drops anything that starts like a house
// number and only a city/state label ("Sausalito, CA") is ever sent upstream.
//
// So the model is told to write this literal token wherever the property should
// be named, and the CLIENT substitutes the real address on-device, where it
// already lives. The property is named in the finished voiceover without any
// vendor ever receiving the address of somebody's home.

export const ADDRESS_PLACEHOLDER = "{address}";

/** Accept the near-misses a model reaches for and normalise them to the exact
 *  token the client substitutes: {{address}}, [address], {Address}, {ADDRESS},
 *  {the address}, {property address}. Anything else is left alone. */
export function normalizePlaceholder(text: string): string {
  return String(text ?? "")
    .replace(/\{\{\s*(?:the\s+)?(?:property\s+|street\s+|listing\s+)?address\s*\}\}/gi, ADDRESS_PLACEHOLDER)
    .replace(/[[{]\s*(?:the\s+)?(?:property\s+|street\s+|listing\s+)?address\s*[\]}]/gi, ADDRESS_PLACEHOLDER);
}

/**
 * Replace anything shaped like a street address with the placeholder.
 *
 * This is not paranoia about the model being creative — it is arithmetic. The
 * address is never in the request, so the request contains nothing the model
 * could copy one from: any street address in the output is INVENTED, and a
 * voiceover that names a house number that is not the property's is worse than
 * one that names none. Substituting the placeholder means the client fills in
 * the real address and the reel is correct either way.
 *
 * Requires a house number, a name and a street suffix, so "2 Bakery Lane" is
 * caught and "the 3 bedrooms upstairs" is not.
 */
const STREET_SUFFIX =
  "st|street|ave|avenue|rd|road|dr|drive|ln|lane|blvd|boulevard|ct|court|way|pl|place|" +
  "ter|terrace|cir|circle|hwy|highway|pkwy|parkway|trail|trl";
const STREET_RE = new RegExp(
  String.raw`\b\d{1,6}\s+(?:[A-Za-z][\w'-]*\s+){1,3}(?:${STREET_SUFFIX})\b\.?`,
  "gi",
);

export function scrubStreetAddress(text: string): string {
  return String(text ?? "").replace(STREET_RE, ADDRESS_PLACEHOLDER);
}

// ── Cleaning the model's answer ──────────────────────────────────────────────

/**
 * Strict-JSON extraction, mirroring coach/actions.ts `extractJsonObject()`:
 * try the raw text, try it unfenced, then scan for the first BALANCED `{…}`
 * (tracking string literals, so a brace inside a quoted value doesn't end the
 * scan early — the exact bug that scanner was rewritten to fix).
 *
 * A bare JSON array is not an object and answers null: every contract in this
 * file is an object, and coercing an array into one is how a malformed answer
 * becomes a confidently wrong result.
 */
export function extractJsonObject(raw: string): Record<string, unknown> | null {
  const text = String(raw ?? "").trim();
  if (!text) return null;

  const unfenced = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();

  for (const candidate of [unfenced, text]) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // fall through to the balanced-brace scan
    }
  }

  let start = unfenced.indexOf("{");
  while (start >= 0) {
    let depth = 0;
    let inString = false;
    let escaped = false;
    let end = -1;
    for (let i = start; i < unfenced.length; i++) {
      const ch = unfenced[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end < 0) break; // unbalanced from here on — nothing later can close it
    try {
      const parsed = JSON.parse(unfenced.slice(start, end + 1));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // not JSON — keep looking
    }
    start = unfenced.indexOf("{", start + 1);
  }
  return null;
}

/** Collapse a model answer into one speakable paragraph: no markdown, no smart
 *  quotes around the whole thing, no stage directions in brackets, no runs of
 *  whitespace. A TTS engine reads "**Kitchen**" out loud as asterisks. */
function flatten(text: string): string {
  return String(text ?? "")
    .replace(/\r/g, "")
    .replace(/^\s*```(?:\w+)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .replace(/[*_#`]+/g, "")
    .replace(/\((?:pause|beat|music|sfx|voiceover|vo)[^)]*\)/gi, "")
    .replace(/\[(?:pause|beat|music|sfx|voiceover|vo)[^\]]*\]/gi, "")
    .replace(/\s+/g, " ")
    .replace(/^["'“”]+|["'“”]+$/g, "")
    .trim();
}

/**
 * Trim to `maxChars` WITHOUT ending mid-word.
 *
 * Preference order: the last sentence end inside the budget (a script that stops
 * on a full stop still sounds finished), else the last word boundary. Never an
 * ellipsis — this text is going into a text-to-speech engine, which reads "…"
 * as a pause into silence, and never a hard mid-word cut.
 *
 * The sentence-boundary cut is only used when it keeps at least 60% of the
 * budget; below that we would be throwing away most of a paid generation to
 * avoid a comma.
 */
export function fitToBudget(text: string, maxChars: number): string {
  const s = String(text ?? "").trim();
  if (maxChars <= 0) return "";
  if (s.length <= maxChars) return s;

  const window = s.slice(0, maxChars);
  const lastSentence = Math.max(
    window.lastIndexOf("."),
    window.lastIndexOf("!"),
    window.lastIndexOf("?"),
  );
  if (lastSentence >= Math.floor(maxChars * 0.6)) return window.slice(0, lastSentence + 1).trim();

  const lastSpace = window.lastIndexOf(" ");
  return (lastSpace > 0 ? window.slice(0, lastSpace) : window).trim();
}

/**
 * The full post-processing pipeline for a reel script: flatten → normalise the
 * placeholder → scrub any invented street address → fit the budget. Returns ""
 * when nothing usable survived, which the caller treats as a failed attempt.
 *
 * Order matters. Scrubbing runs BEFORE the trim so a hallucinated address can
 * never survive by sitting past the cut, and normalising runs before scrubbing
 * so `{Address}` is already the token and is not mistaken for prose.
 */
export function cleanScript(raw: string, maxChars: number): string {
  return fitToBudget(scrubStreetAddress(normalizePlaceholder(flatten(raw))), maxChars);
}

/** Post-processing for a polished photo-edit instruction. No placeholder and no
 *  address scrub (a photo prompt never names the property), just one flat
 *  imperative paragraph inside the cap. */
export function cleanEditPrompt(raw: string, maxChars: number): string {
  return fitToBudget(flatten(raw), maxChars);
}

// ── Facts (what the caller may send, and what we will say about it) ──────────

export interface ScriptFacts {
  beds?: number;
  baths?: number;
  sqft?: number;
  /** ALREADY FORMATTED by the client, e.g. "$1,500,000" — never a raw number,
   *  because the client knows the locale and currency and this function does not. */
  price_label?: string;
  tagline?: string;
  /** City/state only ("Sausalito, CA"). NEVER a street address — see
   *  ADDRESS_PLACEHOLDER above and ai-video's cleanRegion(). */
  region?: string;
  details?: Record<string, string>;
}

/** Bound every free-text fact. These strings go into a prompt AND into the
 *  fair-housing gate, so they are length-capped before either sees them. */
export const MAX_TAGLINE_CHARS = 200;
export const MAX_REGION_CHARS = 80;
export const MAX_DETAIL_KEYS = 12;
export const MAX_DETAIL_VALUE_CHARS = 120;
export const MAX_ROOM_TAGS = 24;
export const MAX_ROOM_TAG_CHARS = 40;

function cleanLine(raw: unknown, maxChars: number): string {
  return String(raw ?? "").replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, maxChars);
}

function cleanCount(raw: unknown, max: number): number | undefined {
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.min(max, Math.round(n * 10) / 10);
}

/** Coerce the client's `facts` into the bounded shape the prompt is built from.
 *  Anything unrecognised is dropped rather than passed through. */
export function cleanFacts(raw: unknown): ScriptFacts {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const out: ScriptFacts = {};
  const beds = cleanCount(o.beds, 99);
  const baths = cleanCount(o.baths, 99);
  const sqft = cleanCount(o.sqft, 9_999_999);
  if (beds !== undefined) out.beds = beds;
  if (baths !== undefined) out.baths = baths;
  if (sqft !== undefined) out.sqft = Math.round(sqft);
  const price = cleanLine(o.price_label, 40);
  if (price) out.price_label = price;
  const tagline = cleanLine(o.tagline, MAX_TAGLINE_CHARS);
  if (tagline) out.tagline = tagline;
  // A region that starts like a house number is a street address, not a region
  // — the same test ai-video's cleanRegion() applies, for the same reason.
  const region = cleanLine(o.region, MAX_REGION_CHARS);
  if (region && !/^\d{1,6}\s+\S/.test(region)) out.region = region;

  if (o.details && typeof o.details === "object" && !Array.isArray(o.details)) {
    const details: Record<string, string> = {};
    let n = 0;
    for (const [k, v] of Object.entries(o.details as Record<string, unknown>)) {
      if (n >= MAX_DETAIL_KEYS) break;
      const key = cleanLine(k, 40);
      const value = cleanLine(v, MAX_DETAIL_VALUE_CHARS);
      if (!key || !value) continue;
      details[key] = value;
      n++;
    }
    if (n > 0) out.details = details;
  }
  return out;
}

/** Room tags IN WALK ORDER. Order is the whole value — it is the spine the
 *  narration follows so the words match what is on screen — so this dedupes
 *  and bounds but NEVER sorts. */
export function cleanRoomTags(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (out.length >= MAX_ROOM_TAGS) break;
    const tag = cleanLine(item, MAX_ROOM_TAG_CHARS);
    if (!tag) continue;
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(tag);
  }
  return out;
}

/** Every piece of free text the CALLER wrote, joined for the input fair-housing
 *  gate. Numbers are excluded — "3 beds" cannot trip a fair-housing rule, and a
 *  gate that reads them only adds false positives. */
export function userFreeText(facts: ScriptFacts, roomTags: string[]): string {
  const parts: string[] = [];
  if (facts.tagline) parts.push(facts.tagline);
  if (facts.region) parts.push(facts.region);
  if (facts.details) for (const [k, v] of Object.entries(facts.details)) parts.push(`${k}: ${v}`);
  parts.push(...roomTags);
  return parts.join(". ");
}

// ── The reel-script instruction ──────────────────────────────────────────────

export interface ScriptRequest {
  space: SpaceType;
  tone: Tone;
  /** Already clamped by cleanTargetSeconds(). */
  targetSeconds: number;
  /** Already computed by charBudgetFor(targetSeconds). */
  charBudget: number;
  facts: ScriptFacts;
  roomTags: string[];
  photoCount: number;
}

/**
 * The system rules for `POST /ai-copy/script`.
 *
 * This is MARKETING copy, because marketing is what the owner is buying. The
 * four rules below are in priority order and each one is here because of how
 * Reels and TikTok actually behave, not because of how listing descriptions
 * are usually written:
 *
 *   1. HOOK FIRST. The opening line has to earn the next two seconds. "Welcome
 *      to" spends the only two seconds you are given saying nothing.
 *   2. THE FACTS THAT SELL, in the industry's own words (vocabFor()).
 *   3. A CLOSE THAT ASKS FOR SOMETHING — the same words as the tour's own
 *      end-card CTA, so the script and the button agree.
 *   4. LENGTH IS A CONSTRAINT. See the CHARS_PER_SECOND note: overrunning
 *      freezes the last video frame, it does not truncate the voice.
 */
export function scriptInstruction(req: ScriptRequest): string {
  const v = vocabFor(req.space);
  const walk = req.roomTags.length > 0
    ? `The walkthrough visits these ${v.area}s IN THIS ORDER: ${req.roomTags.join(" → ")}. ` +
      `That order is the SPINE of the script — narrate the walk in it, so the words match what is ` +
      `on screen. You do not have to name every ${v.area}; name the ones that sell.`
    : `No ${v.area} list was captured for this walkthrough, so do not name specific ${v.area}s — ` +
      `you would be guessing at what is on screen. Write to the ${v.space} as a whole.`;

  return [
    `You write short voiceover scripts for social-video tours of a ${v.space}, for ${v.audience}. ` +
      `The finished reel is posted to Instagram Reels and TikTok, where ${v.customer} are scrolling. ` +
      `The product's own promise for this industry is "${v.pitch}" — write to that.`,
    "",
    "RULES, in priority order:",
    `1. HOOK FIRST. The opening line has to earn the next two seconds — that is the whole game on ` +
      `Reels and TikTok. Never open with "Welcome to", "Come see", "Take a look at", "Step inside" ` +
      `or any other greeting. Open on the single most interesting true thing you were given.`,
    `2. THEN THE FACTS THAT SELL, in this industry's own words — say "${v.customer}", say ` +
      `"${v.area}", call it a ${v.space}. Use only the facts below. Never invent a fact, a number, ` +
      `a price, a feature or a neighbourhood, and never describe anything you were not told about.`,
    `3. CLOSE BY ASKING FOR SOMETHING. End on the action the tour's own button offers: ` +
      `"${v.cta}". One short line.`,
    `4. LENGTH IS A HARD CONSTRAINT, NOT A SUGGESTION. Write AT MOST ${req.charBudget} characters ` +
      `— that is roughly ${req.targetSeconds} seconds of speech, which is exactly how long the video ` +
      `is. A longer script does not get cut off: the video runs out and the last frame FREEZES while ` +
      `the voice keeps talking. Shorter is fine. Longer is a broken reel.`,
    "",
    walk,
    "",
    `NAMING THE ${req.space === "real_estate" ? "PROPERTY" : "BUSINESS"}. You have not been told the ` +
      `address, and you must never invent one. Where the script should name it, write the literal ` +
      `token ${ADDRESS_PLACEHOLDER} — the app replaces that token on the device before the script is ` +
      `spoken. Use it at most once. If the script reads better without naming it at all, leave it out.`,
    "",
    "STYLE: " + toneDirection(req.tone),
    `Spoken English, plain words, no markdown, no emoji, no hashtags, no stage directions, no ` +
      `speaker labels, no section headings, no quotation marks around the whole script. Write it as ` +
      `one continuous paragraph a person can read aloud.`,
    "",
    `NEVER describe or refer to people, families, children, a neighbourhood, schools, a "safe" or ` +
      `"good" area, or who would like living or shopping here. Describe the ${v.space}, never its ` +
      `occupants or its neighbours — this is advertising copy and that rule is the law, not a ` +
      `preference. A script that breaks it is thrown away and costs the user their turn.`,
    "",
    `Reply with STRICT JSON only, exactly: {"script":"<the script>"}`,
  ].join("\n");
}

/**
 * The FACT BLOCK, in the words and the order every route states it in.
 *
 * Extracted from `buildScriptTurn()` verbatim so `/ai-copy/shotlist` states the
 * same facts the same way rather than growing a second dialect of "Beds: 4" —
 * two prompts describing one listing differently is how two routes start
 * answering differently about the same house.
 */
export function factLines(space: SpaceType, facts: ScriptFacts): string[] {
  const v = vocabFor(space);
  const lines: string[] = [];
  lines.push(`Type of ${v.space}: ${space.replace(/_/g, " ")}`);
  if (facts.region) lines.push(`Area (city/state only): ${facts.region}`);
  if (facts.tagline) lines.push(`The owner's own one-liner: ${facts.tagline}`);
  if (facts.beds !== undefined) lines.push(`Beds: ${facts.beds}`);
  if (facts.baths !== undefined) lines.push(`Baths: ${facts.baths}`);
  if (facts.sqft !== undefined) lines.push(`Square feet: ${facts.sqft}`);
  if (facts.price_label) lines.push(`Price: ${facts.price_label}`);
  if (facts.details) {
    for (const [k, val] of Object.entries(facts.details)) lines.push(`${k}: ${val}`);
  }
  return lines;
}

/** The user turn for the script route: the facts, and nothing else. */
export function buildScriptTurn(req: ScriptRequest): string {
  const v = vocabFor(req.space);
  const lines = factLines(req.space, req.facts);
  lines.push(
    req.roomTags.length > 0
      ? `${v.area[0].toUpperCase()}${v.area.slice(1)}s in walk order: ${req.roomTags.join(", ")}`
      : `${v.area[0].toUpperCase()}${v.area.slice(1)}s in walk order: (none captured)`,
  );
  lines.push(`Photos in the reel: ${req.photoCount}`);
  lines.push(`Video length: ${req.targetSeconds} seconds`);
  lines.push(`Character budget: ${req.charBudget}`);
  return `FACTS (use only these):\n${lines.join("\n")}`;
}

// ── The photo-edit-prompt instruction (SHARED with ai-photo) ─────────────────

/** The polished instruction's ceiling. Same number ai-photo's improve_prompt has
 *  always used (MAX_IMPROVE_OUTPUT), so the shipped app's expectations do not
 *  move when it starts calling the shared builder. */
export const MAX_PROMPT_OUTPUT = 400;

/** The rough idea's ceiling, matching ai-photo's MAX_IMPROVE_INPUT. */
export const MAX_PROMPT_INPUT = 300;

/**
 * The ONE prompt-polisher. `POST /ai-copy/edit-prompt` and ai-photo's legacy
 * `edit:"improve_prompt"` both build their request from this function, so there
 * is one set of words to improve rather than two that drift apart.
 *
 * It closes the preset/custom asymmetry described at the top of this file: a
 * preset gets ~60 words naming the change, what stays IDENTICAL, and the
 * physical plausibility (materials, shadows, perspective, existing light), so
 * this asks for an instruction with that same density from a rough idea.
 *
 * IT DOES NOT APPEND THE GUARDRAILS OR THE ARCHITECTURE LOCK. ai-photo appends
 * `guardrailsFor(edit)` and its own LOCK to every prompt server-side, canned or
 * free-text; producing them here too would spend tokens writing text that is
 * about to be duplicated, and a doubled instruction is a model that weights it
 * twice and starts refusing legitimate edits.
 */
export function editPromptInstruction(space: SpaceType, roomHint?: string | null): string {
  const v = vocabFor(space);
  const hint = String(roomHint ?? "").replace(/\s+/g, " ").trim().slice(0, 60);
  return [
    `You polish rough photo-edit requests from ${v.audience} into precise instructions for an AI ` +
      `photo editor working on a real ${v.photo}${hint ? ` of the ${hint}` : ""}.`,
    "",
    `Rewrite the user's idea as ONE clear, imperative edit instruction. Give it the same density of ` +
      `direction a hand-written preset carries — name (a) exactly WHAT CHANGES, (b) what must stay ` +
      `IDENTICAL, and (c) what makes it look real: materials, surface finish, and shadows and ` +
      `reflections that match the light already in the photo. Keep the perspective and the camera ` +
      `angle as photographed.`,
    "",
    `Keep the user's intent EXACTLY. Never invent extra changes they did not ask for, never widen a ` +
      `small edit into a remodel, and never add a subject that is not already there. If the idea is ` +
      `already precise, tighten the wording and stop.`,
    "",
    `Photorealistic and plausible for a real place. No camera jargon, no markdown, no quotes, no ` +
      `lists — a single paragraph of at most ${MAX_PROMPT_OUTPUT} characters. Do NOT add boilerplate ` +
      `about preserving architecture, and do NOT add anything about people, pets or signage; the ` +
      `system appends all of that separately.`,
    "",
    `Reply with STRICT JSON only, exactly: {"prompt":"<the rewritten instruction>"}`,
  ].join("\n");
}
