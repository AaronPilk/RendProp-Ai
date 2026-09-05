// events/schema.ts — the event VOCABULARY, the per-event props whitelist, and
// the PII scrubber. Pure functions only: no network, no Deno.serve, no env, so
// events.test.ts can exercise the rules that actually keep personal data out of
// the analytics table without standing up a server.
//
// `index.ts` is the only caller. It is split out for exactly one reason: this
// is the part that must be TESTED, and a module that calls Deno.serve at import
// time cannot be imported by a test. (Same split as _shared/router.ts and its
// router.test.ts.)
//
// THE RULE THIS FILE EXISTS TO KEEP: nothing that could identify a person ever
// reaches `app_events`. Three independent layers, in order:
//
//   1. VOCABULARY  — an event name we did not write is rejected (400). The only
//                    client is our own app, so a new name is a deploy, not a
//                    surprise.
//   2. WHITELIST   — each event declares the prop keys it may carry. Anything
//                    else is DROPPED SILENTLY and counted, never rejected: a
//                    newer app build sending a prop this deploy hasn't heard of
//                    must not lose its whole batch over it.
//   3. SCRUB       — every surviving STRING value is rewritten through
//                    `scrubString`, which redacts anything shaped like a URL,
//                    an e-mail address, a street address or a phone number.
//                    Layer 3 assumes layers 1 and 2 will one day be wrong.
//
// Numbers and booleans are passed through unchanged (they cannot carry a name).
// Objects, arrays and nulls are dropped — a nested value is a place for PII to
// hide from the scrubber.

/** Max characters kept for one string prop value. */
export const MAX_PROP_STRING = 200;
/** Max characters kept for app_version / os. */
export const MAX_META_STRING = 40;
/** Max serialized bytes for ONE event (contract: "max 1 KB per event"). */
export const MAX_EVENT_BYTES = 1024;
/** Max events in one POST /events body. */
export const MAX_EVENTS_PER_CALL = 100;

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The event vocabulary, frozen by docs/LAUNCH-CONTRACT.md §Events, and for each
 * name the prop keys it may carry.
 *
 * Keys are chosen so that NONE of them could reasonably hold a person, a place
 * or a file: they are enums, counts, durations, booleans and product ids. There
 * is deliberately no `address`, no `name`, no `email`, no `path`, no `url` and
 * no `id` of a listing or a photo — a listing id is a join key back to a street
 * address, which is the thing this table must never be able to reveal.
 */
export const EVENT_SCHEMA: Readonly<Record<string, readonly string[]>> = Object.freeze({
  // Lifecycle
  app_open:           ["cold", "source", "session_n"],
  signup:             ["method"],
  signin:             ["method"],
  // Core creation funnel
  home_created:       ["space_type", "source"],
  capture_started:    ["space_type", "mode"],
  capture_finished:   ["space_type", "mode", "duration_s", "rooms"],
  render_finished:    ["tier", "duration_s", "seconds", "ok"],
  tour_published:     ["space_type", "unbranded", "ok"],
  // AI tools
  ai_photo_edit:      ["task", "provider", "ok", "ms"],
  reel_made:          ["clips", "duration_s", "ok"],
  voiceover_added:    ["duration_s", "captions", "ok"],
  aerial_made:        ["provider", "ok", "ms"],
  // Money
  paywall_viewed:     ["source", "plan"],
  purchase_started:   ["product_id", "plan", "period"],
  purchase_completed: ["product_id", "plan", "period", "trial"],
  purchase_failed:    ["product_id", "plan", "reason"],
  restore:            ["ok", "plan"],
  // Stability (MetricKit summaries — see Analytics/CrashReporter.swift)
  crash:              ["kind", "signal", "exception_type", "termination_reason", "top_frame", "app_version", "os"],
  error:              ["category", "code", "step", "detail", "launch_time_ms", "hang_ms", "app_version", "os"],
});

/** Sorted vocabulary — what a 400 tells the client it may send. */
export const ALLOWED_EVENT_NAMES: readonly string[] = Object.freeze(
  Object.keys(EVENT_SCHEMA).sort(),
);

export function isAllowedEvent(name: unknown): boolean {
  return typeof name === "string" && Object.prototype.hasOwnProperty.call(EVENT_SCHEMA, name);
}

// ── The scrubber ────────────────────────────────────────────────────────────
//
// ORDER MATTERS and is not arbitrary:
//   URLs first     — an e-mail or a phone number inside a query string is
//                    swallowed by the URL rule, so it can never survive as a
//                    fragment of a partially-redacted link.
//   e-mail second  — before the phone rule, whose digit run would otherwise
//                    chew the numeric part of `a1234567@x.com`.
//   address third  — before phone: a street address STARTS with digits, and a
//                    half-redacted "[redacted] Pennsylvania Ave" is worse than
//                    a whole one.
//   phone last     — the greediest rule, so it runs when nothing else claimed
//                    the text.
//
// These are deliberately over-eager. A false positive costs one analytics
// string; a false negative costs a person's address in a database that is not
// supposed to be able to hold one.

const REDACTED = "[redacted]";

const PATTERNS: readonly RegExp[] = [
  // Anything with a scheme (http://, mailto:, file://, rendprop://) or a
  // leading www., plus any bare token that contains BOTH a dot and a slash
  // (a path — "Users/aaron/Photos/IMG_1.jpg").
  /\b[a-z][a-z0-9+.-]*:\/\/\S+/gi,
  /\bmailto:\S+/gi,
  /\bwww\.\S+/gi,
  /\S*\/\S*\.\S+/g,
  // e-mail
  /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,
  // US-style street address: house number + up to 4 words + a street suffix.
  /\b\d{1,6}\s+(?:[A-Za-z0-9.'#-]+\s+){0,4}(?:st|street|ave|avenue|rd|road|blvd|boulevard|ln|lane|dr|drive|ct|court|pl|place|way|ter|terrace|cir|circle|hwy|highway|pkwy|parkway|sq|square|trl|trail|apt|unit|suite|ste)\b\.?/gi,
  // Phone: a run of 8+ digits, optionally broken by spaces, dots, dashes,
  // parentheses or a leading +. Short numbers (durations, counts, ZIP codes)
  // do not reach 8 digits and are left alone.
  /\+?\d(?:[\d\s().-]{6,})\d/g,
];

/**
 * Replace anything that looks like a URL, e-mail, street address or phone
 * number with "[redacted]", then clip to `max`.
 *
 * Not a guarantee that the result is safe — it is the LAST layer, under a
 * vocabulary and a whitelist that are supposed to make it unnecessary.
 */
export function scrubString(input: string, max = MAX_PROP_STRING): string {
  let out = input;
  for (const re of PATTERNS) {
    // Fresh lastIndex every call: these are module-level /g regexes.
    re.lastIndex = 0;
    out = out.replace(re, REDACTED);
  }
  out = out.replace(/\s+/g, " ").trim();
  return out.length > max ? out.slice(0, max) : out;
}

/** Scrub + clip a metadata string (app_version, os). Empty → null. */
export function scrubMeta(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const s = scrubString(input, MAX_META_STRING);
  return s.length === 0 ? null : s;
}

export interface SanitizedProps {
  props: Record<string, string | number | boolean>;
  /** How many keys were thrown away (unknown key, or a value we won't store). */
  dropped: number;
}

/**
 * Keep only the whitelisted keys for `name`, coerce each value to a scalar we
 * are willing to store, and scrub every string.
 *
 * Silent by design: an unknown key is DROPPED and counted, never a 400. The
 * client is our own app and a newer build will send props an older deploy has
 * not heard of — losing that batch would lose real funnel data over a field
 * nobody needed.
 */
export function sanitizeProps(name: string, raw: unknown): SanitizedProps {
  const allowed = EVENT_SCHEMA[name];
  if (!allowed) return { props: {}, dropped: 0 };
  if (raw === null || raw === undefined) return { props: {}, dropped: 0 };
  if (typeof raw !== "object" || Array.isArray(raw)) return { props: {}, dropped: 1 };

  const source = raw as Record<string, unknown>;
  const props: Record<string, string | number | boolean> = {};
  let dropped = 0;

  for (const key of Object.keys(source)) {
    if (!allowed.includes(key)) { dropped++; continue; }
    const value = source[key];
    if (typeof value === "string") {
      const scrubbed = scrubString(value);
      if (scrubbed.length === 0) { dropped++; continue; }
      props[key] = scrubbed;
    } else if (typeof value === "number") {
      // NaN/Infinity are not representable in JSON and would arrive as null.
      if (!Number.isFinite(value)) { dropped++; continue; }
      props[key] = value;
    } else if (typeof value === "boolean") {
      props[key] = value;
    } else {
      // object / array / null / undefined — a place for PII to hide.
      dropped++;
    }
  }

  return { props, dropped };
}

/**
 * Device-side timestamps, made safe.
 *
 * A missing or unparseable `t` becomes `now`. A `t` in the FUTURE is clamped to
 * `now`: a phone with a wrong clock (or a client that lies) must not be able to
 * park rows beyond every funnel window, where the retention purge — which runs
 * on received_at — would still eventually collect them but the funnel never
 * would. Past timestamps are left alone; the app genuinely buffers events
 * offline for days.
 */
export function normalizeTimestamp(raw: unknown, now: Date): string {
  if (typeof raw === "string" && raw.length > 0) {
    const ms = Date.parse(raw);
    if (Number.isFinite(ms)) {
      return new Date(Math.min(ms, now.getTime())).toISOString();
    }
  }
  return now.toISOString();
}

export interface NormalizedEvent {
  name: string;
  t: string;
  props: Record<string, string | number | boolean>;
}

export interface NormalizeResult {
  events: NormalizedEvent[];
  droppedProps: number;
  /** Events thrown away for being over MAX_EVENT_BYTES after sanitising. */
  droppedEvents: number;
  /** The first unknown event name seen, for the 400 message. */
  unknownName: string | null;
}

/**
 * Turn a raw `events: [...]` array into rows we are willing to insert.
 *
 * Returns `unknownName` rather than throwing so the caller owns the HTTP
 * envelope (index.ts turns it into a 400 that lists the whole vocabulary).
 *
 * An event that is STILL over 1 KB once its props have been whitelisted and
 * scrubbed is dropped on its own — one fat event must not cost the other 99
 * their trip.
 */
export function normalizeBatch(raw: unknown, now: Date): NormalizeResult {
  const out: NormalizeResult = { events: [], droppedProps: 0, droppedEvents: 0, unknownName: null };
  if (!Array.isArray(raw)) return out;

  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) { out.droppedEvents++; continue; }
    const e = item as Record<string, unknown>;
    const name = typeof e.name === "string" ? e.name.trim() : "";
    if (!isAllowedEvent(name)) {
      if (out.unknownName === null) out.unknownName = name.slice(0, 40) || "(missing)";
      continue;
    }
    const { props, dropped } = sanitizeProps(name, e.props);
    out.droppedProps += dropped;
    const row: NormalizedEvent = { name, t: normalizeTimestamp(e.t, now), props };
    if (new TextEncoder().encode(JSON.stringify(row)).length > MAX_EVENT_BYTES) {
      out.droppedEvents++;
      continue;
    }
    out.events.push(row);
  }
  return out;
}
