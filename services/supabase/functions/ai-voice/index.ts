// ai-voice — ElevenLabs text-to-speech for reel voiceovers, with the
// character-level alignment the app turns into word-by-word captions.
// Owner-authenticated, same envelope and RPnnn conventions as ai-photo.
//
//   GET  /ai-voice/voices
//        -> { voices: [ { voice_id, name, labels: "narration · american" } ], cached }
//        The catalogue the picker shows. Cached in-process for 10 minutes.
//        ELEVENLABS_API_KEY unset -> 503 `upstream` naming the missing
//        configuration. NEVER a silent empty list, and never the key itself.
//
//   POST /ai-voice/tts   { text, voice_id, listing_id?, label? }
//        -> { audio_url, mime, duration_s, duration_source, words[],
//             voice_name, characters, disclosure, provenance }
//        `audio_url` is a SHORT-LIVED SIGNED GET on R2 (15 min). The base64
//        audio ElevenLabs returns is never forwarded to the app: a 60-second
//        mp3 is ~1 MB, which is ~1.4 MB of base64 inside a JSON body the phone
//        then has to hold in memory twice to decode. The app downloads the URL.
//
// ── THE ELEVENLABS CALL (verified against the vendor docs 2026-09-04) ────────
//
//   POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/with-timestamps
//        ?output_format=mp3_44100_128
//   header: `xi-api-key: <key>`      (NOT Authorization: Bearer)
//   body:   { text, model_id?, voice_settings? }
//   200:    { audio_base64,
//             alignment:            { characters[], character_start_times_seconds[],
//                                     character_end_times_seconds[] },
//             normalized_alignment: { …same shape… } }
//   docs:   https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps
//
//   `output_format` is a QUERY parameter, not a body field — sending it in the
//   body silently gets you the default. `model_id` is deliberately omitted
//   unless ELEVENLABS_MODEL_ID is set: pinning a model id in code is how the
//   Gemini text helper broke when Google retired gemini-2.5-flash, and the
//   vendor's own default cannot be retired out from under us.
//
//   WORDS. `alignment` is indexed against the ORIGINAL text (what the agent
//   typed and what the caption should show); `normalized_alignment` is indexed
//   against the spoken/normalised text ("$5" → "five dollars"). Both sit on the
//   same audio timeline. We group `alignment` on whitespace — a word's `start`
//   is its FIRST character's start, its `end` is its LAST character's end — and
//   fall back to `normalized_alignment` only if `alignment` is unusable.
//
//   NO INVENTED TIMINGS. If alignment is absent, the three arrays disagree in
//   length, or a word's own characters carry no finite timing, that word (or
//   the whole list) is dropped and `words: []` is returned. Captions then
//   simply do not render. A caption that drifts is worse than no caption, and
//   an interpolated timing is a drift we manufactured ourselves.
//
//   duration_s is never guessed either — `duration_source` says where it came
//   from, because a video layout is built on this number:
//     "alignment"        the last alignment end time (authoritative)
//     "bitrate_estimate" bytes×8÷128000, valid only because WE request CBR
//                        mp3_44100_128; accurate to a frame or two
//     "last_word"        the last word we could time
//     "unknown"          0 — nothing reliable was available; do not lay out on it
//
// ── GATES (all of them run BEFORE anything billable) ─────────────────────────
//
//   1. FAIR HOUSING on `text` — `assertMarketingCopy()` in _shared/fairhousing.ts.
//      A voiceover script is property marketing: 42 U.S.C. §3604(c) covers a
//      spoken advertisement exactly as it covers a written listing description,
//      so "great for families", "safe neighborhood", "walk to St. Mary's" and
//      "no kids" are refused with 400 `unsupported_edit` and copy naming the
//      offending phrase. There is no header, flag or body field that skips it —
//      the check sits between body parsing and every network call below.
//   2. LENGTH — 1,000 characters. Longer is a 400 before anything else runs.
//   3. ROLE — marketing is read-only, same gate as ai-photo.
//   4. QUOTA — metered against the plan's `reels_per_month` allowance. 0 → 402.
//   5. RATE — 20 requests / 5 min / org.
//   6. PROVENANCE — one media_provenance row: this is AI-GENERATED AUDIO and
//      the hosted tour has to be able to disclose it.
//
//   METER KEY. The CAP is `reels_per_month` (per the contract — a new plan
//   column would need a migration across every plan row), but the COUNTER is
//   its own key, `aivoicemo:<org>`, not ai-video's `reelmo:<org>`. Sharing the
//   counter would (a) silently change the budget of a shipped feature owned by
//   another function, and (b) let a fraction-of-a-cent TTS call consume a
//   $0.24 Seedance clip's allowance. Same published number, separate meter.
//
//   CHARGE / REFUND. The meter is charged immediately BEFORE the ElevenLabs
//   call and refunded with `refundRateLimit` if that call (or the R2 upload)
//   fails, so a failed generation costs the org nothing — same net effect as
//   charging afterwards, without the race that charging afterwards opens (N
//   concurrent requests would all read an uncharged counter and all spend).
//
//   IDEMPOTENCY is a DUPLICATE-BLOCK, NOT A REPLAY — exactly what ai-photo and
//   ai-video do today. A repeated `Idempotency-Key` inside 120 s gets a 409
//   `conflict`; it does not return the first response. So a double tap cannot
//   double-charge, but a genuinely lost response cannot be recovered either —
//   the retry is refused rather than re-answered. Nothing is persisted
//   server-side to replay from.
//
// Needs the ELEVENLABS_API_KEY function secret plus the shared R2 env.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { durableRateLimit, refundRateLimit } from "../_shared/ratelimit.ts";
import { entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { assertMarketingCopy } from "../_shared/fairhousing.ts";
import { recordProvenance } from "../_shared/provenance.ts";
import { R2_BUCKET_UPLOADS, presignPut } from "../_shared/r2.ts";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

// Denial-of-wallet guard: every TTS call bills ElevenLabs per character.
const TTS_MAX_PER_WINDOW = 20;
const TTS_WINDOW_SECONDS = 300; // 20 voiceovers / 5 min / org
const MONTH_SECONDS = 30 * 86400;

/** Hard cap from the contract. Counted in UTF-16 units, which is ≥ the code
 *  point count, so the check errs strict and never lets more through. */
const MAX_TEXT_CHARS = 1000;

/** How long the returned audio URL stays valid. The app downloads immediately. */
const AUDIO_URL_TTL_SECONDS = 900;

/** Voice catalogue cache lifetime (contract: 10 minutes). */
const VOICES_TTL_MS = 10 * 60 * 1000;

const ELEVEN_BASE = "https://api.elevenlabs.io";
/** CBR so `duration_source: "bitrate_estimate"` is arithmetic, not a guess. */
const OUTPUT_FORMAT = "mp3_44100_128";
const OUTPUT_BITRATE = 128_000;
const OUTPUT_MIME = "audio/mpeg";

const ELEVENLABS_KEY = Deno.env.get("ELEVENLABS_API_KEY")?.trim() || undefined;
/** Optional pin. Unset (the default) = ElevenLabs' own current default model. */
const ELEVENLABS_MODEL_ID = Deno.env.get("ELEVENLABS_MODEL_ID")?.trim() || undefined;

/** Auth header for every ElevenLabs call. `xi-api-key`, never Bearer. The value
 *  is read here and nowhere else — never logged, never returned, never measured. */
function elevenHeaders(): Record<string, string> {
  return { "xi-api-key": ELEVENLABS_KEY!, "content-type": "application/json" };
}

/** 503 when the provider is not configured. Names the SECRET, never its value. */
function requireElevenLabs(): void {
  if (!ELEVENLABS_KEY) {
    throw new HttpError(
      503,
      "AI voiceover isn't configured on this server: the ELEVENLABS_API_KEY function " +
        "secret is not set. Set it with services/supabase/set-secrets.sh and redeploy.",
      "upstream",
    );
  }
}

// ── R2 signed GET ────────────────────────────────────────────────────────────
//
// _shared/r2.ts presigns PUT but has no GET, and it is frozen for this change
// (it trims every credential for a reason: one trailing newline in the access
// key took the whole storage layer down on 2026-09-04). So the GET signer lives
// here, with the SAME trimming discipline and the same aws4fetch version.
// It belongs in _shared/r2.ts as `presignGet` the moment that file is open for
// edits again — this is a scoping duplicate, not a second way of doing things.

const trimmedEnv = (name: string): string | undefined => {
  const raw = Deno.env.get(name);
  if (raw === undefined) return undefined;
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
};

const R2_ACCOUNT_ID = trimmedEnv("CLOUDFLARE_ACCOUNT_ID");
const R2_ACCESS_KEY_ID = trimmedEnv("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = trimmedEnv("R2_SECRET_ACCESS_KEY");

let _r2: AwsClient | null = null;
function r2Client(): AwsClient {
  if (_r2) return _r2;
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) {
    throw new HttpError(500, "Missing R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY");
  }
  _r2 = new AwsClient({
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  return _r2;
}

/** Encode each path segment but keep the "/" separators (safe for S3 SigV4). */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

function r2Endpoint(): string {
  if (!R2_ACCOUNT_ID) throw new HttpError(500, "Missing env var: CLOUDFLARE_ACCOUNT_ID");
  return `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
}

/** Presign an R2 GET URL. Mirror of r2.ts `presignPut` (see note above). */
async function presignGet(bucket: string, key: string, expiresIn: number): Promise<string> {
  const url = new URL(`${r2Endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signed = await r2Client().sign(url.toString(), { method: "GET", aws: { signQuery: true } });
  return signed.url;
}

// ── Guards ───────────────────────────────────────────────────────────────────

/** Role gate: marketing is read-only, same rule as ai-photo / ai-video. */
async function requireEditorRole(userId: string, req: Request, what: string): Promise<string> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const { data: mem, error: mErr } = await adminClient()
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, `Your role does not permit ${what}`);
  }
  return orgId;
}

/** What one charged TTS consumed, so a failure can hand every unit back. */
interface Charge {
  orgId: string;
  monthlyKey: string;
  burstKey: string;
}

/**
 * Charge the quotas for one voiceover. Called ONLY after the body, the length
 * cap and the fair-housing gate have all passed — charging before validation is
 * how `{}` bodies used to burn an org's allowance without a provider call ever
 * being made (audit round 4).
 */
async function guardTTS(userId: string, req: Request): Promise<Charge> {
  const orgId = await requireEditorRole(userId, req, "AI voiceovers");
  // A degraded plan lookup is a 503, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = ent.reels_per_month; // the CAP is shared; the counter is not
  if (monthlyCap <= 0) throw quotaError("AI voiceover", 0, 0, ent.plan);

  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aivoiceidem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this voiceover was already started.", "conflict");
    }
  }

  const burstKey = `aivoice:${orgId}`;
  if (!(await durableRateLimit(burstKey, TTS_MAX_PER_WINDOW, TTS_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI voiceover limit reached for now — try again in a few minutes.", "rate_limited");
  }
  const monthlyKey = `aivoicemo:${orgId}`;
  if (!(await durableRateLimit(monthlyKey, monthlyCap, MONTH_SECONDS))) {
    throw quotaError("AI voiceover", monthlyCap, monthlyCap, ent.plan);
  }
  return { orgId, monthlyKey, burstKey };
}

/**
 * Hand back everything a FAILED voiceover charged. Best effort and never throws
 * — a failed refund must not replace the real error the user needs to see.
 */
async function refundCharge(charge: Charge): Promise<void> {
  await refundRateLimit(charge.monthlyKey, MONTH_SECONDS, 1);
  await refundRateLimit(charge.burstKey, TTS_WINDOW_SECONDS, 1);
}

// ── Voice catalogue ──────────────────────────────────────────────────────────

interface Voice {
  voice_id: string;
  name: string;
  /** Flattened for display: "narration · american". Never an object. */
  labels: string;
}

let voicesCache: { at: number; voices: Voice[] } | null = null;

/** Flatten ElevenLabs' `labels` object into the one display string the picker
 *  shows. Order is stable and useful-first, and unknown keys still come along. */
function flattenLabels(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const obj = raw as Record<string, unknown>;
  const preferred = ["use_case", "description", "accent", "age", "gender", "language"];
  const seen = new Set<string>();
  const parts: string[] = [];
  const push = (v: unknown) => {
    const s = String(v ?? "").trim().toLowerCase();
    if (!s || seen.has(s)) return;
    seen.add(s);
    parts.push(s);
  };
  for (const k of preferred) if (k in obj) push(obj[k]);
  for (const [k, v] of Object.entries(obj)) if (!preferred.includes(k)) push(v);
  return parts.slice(0, 4).join(" · ");
}

/**
 * The voice catalogue, cached for 10 minutes. `GET /v2/voices` is the current
 * endpoint (v1 is documented as legacy); we ask for a full page so the picker
 * is not silently truncated to the 10-voice default.
 */
async function fetchVoices(): Promise<Voice[]> {
  const now = Date.now();
  if (voicesCache && now - voicesCache.at < VOICES_TTL_MS) return voicesCache.voices;

  const url = `${ELEVEN_BASE}/v2/voices?page_size=100&include_total_count=false`;
  const res = await fetch(url, { headers: elevenHeaders() });
  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    // The upstream body can echo request details but never our key (we send it
    // as a header and never as a query param). Bounded to keep logs sane.
    throw new HttpError(502, `ElevenLabs ${res.status}: ${JSON.stringify(data).slice(0, 300)}`, "upstream");
  }

  const raw = Array.isArray((data as Record<string, unknown>).voices)
    ? ((data as { voices: unknown[] }).voices)
    : [];
  const voices: Voice[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const id = String(o.voice_id ?? "").trim();
    const name = String(o.name ?? "").trim();
    if (!id || !name) continue;
    voices.push({ voice_id: id, name, labels: flattenLabels(o.labels) });
  }
  voices.sort((a, b) => a.name.localeCompare(b.name));
  voicesCache = { at: now, voices };
  return voices;
}

/** The display name for a voice id, best effort. NEVER throws and never blocks
 *  a paid generation: a catalogue hiccup must not fail a voiceover the user is
 *  about to pay for, so an unknown id falls back to a neutral label. */
async function voiceNameFor(voiceId: string): Promise<string> {
  try {
    const list = await fetchVoices();
    const hit = list.find((v) => v.voice_id === voiceId);
    if (hit?.name) return hit.name;
  } catch (e) {
    console.error("voice catalogue lookup failed (non-fatal):", e instanceof Error ? e.message : e);
  }
  return "AI voice";
}

// ── Alignment → caption words ────────────────────────────────────────────────

interface CaptionWord {
  text: string;
  start: number;
  end: number;
}

interface Alignment {
  characters?: unknown;
  character_start_times_seconds?: unknown;
  character_end_times_seconds?: unknown;
}

interface Timed {
  words: CaptionWord[];
  /** Last end time seen across ALL characters, or null when unusable. */
  lastEnd: number | null;
}

/**
 * Group ElevenLabs' per-character alignment into words on whitespace.
 *
 * A word's `start` is its first character's start and its `end` is its last
 * character's end — no interpolation anywhere. A word whose own characters
 * carry no finite, non-inverted timing is DROPPED rather than approximated; a
 * structurally malformed alignment (missing arrays, mismatched lengths) yields
 * no words at all. Both cases end as `words: []`, and captions simply do not
 * render, which is the correct degradation.
 *
 * Exported so the grouping can be exercised directly — it is the one piece of
 * this function whose output lands frame-accurately on a video.
 */
export function wordsFromAlignment(a: Alignment | null | undefined): Timed {
  const empty: Timed = { words: [], lastEnd: null };
  if (!a || typeof a !== "object") return empty;

  const chars = a.characters;
  const starts = a.character_start_times_seconds;
  const ends = a.character_end_times_seconds;
  if (!Array.isArray(chars) || !Array.isArray(starts) || !Array.isArray(ends)) return empty;
  // Mismatched lengths mean we cannot trust ANY index to line up. Refuse the
  // whole alignment rather than caption part of it against the wrong times.
  if (chars.length !== starts.length || chars.length !== ends.length) return empty;
  if (chars.length === 0) return empty;

  const words: CaptionWord[] = [];
  let lastEnd: number | null = null;

  let buf = "";
  let wordStart: number | null = null;
  let wordEnd: number | null = null;
  let wordBroken = false;

  const flush = () => {
    // `end` is the LAST character's end, exactly as specified — not the maximum
    // across the word. A word whose own end precedes its own start is
    // internally inconsistent, so it is DROPPED rather than emitted backwards
    // or silently stretched: the caption for that one word simply doesn't show.
    if (
      buf.length > 0 && !wordBroken &&
      wordStart !== null && wordEnd !== null && wordEnd >= wordStart
    ) {
      words.push({ text: buf, start: round3(wordStart), end: round3(wordEnd) });
    }
    buf = "";
    wordStart = null;
    wordEnd = null;
    wordBroken = false;
  };

  for (let i = 0; i < chars.length; i++) {
    const rawCh = chars[i];
    const s = timeAt(starts[i]);
    const e = timeAt(ends[i]);
    if (e !== null && (lastEnd === null || e > lastEnd)) lastEnd = e;

    if (typeof rawCh !== "string") {
      // A non-string entry means this alignment slot is malformed. Mark the
      // word untimeable but keep scanning so its NEIGHBOURS still caption.
      wordBroken = true;
      continue;
    }
    // Whitespace ends the current word. JS `\s` already covers space, tab,
    // newline AND U+00A0, so one test is the whole rule.
    if (rawCh.length === 0 || /^\s+$/.test(rawCh)) {
      flush();
      continue;
    }
    if (s === null || e === null) {
      // This character has no usable timing, so this WORD is untimeable.
      wordBroken = true;
      buf += rawCh;
      continue;
    }
    if (buf.length === 0) wordStart = s;
    buf += rawCh;
    wordEnd = e;
  }
  flush();

  return { words, lastEnd };
}

/**
 * A timestamp from the alignment arrays, or null when there isn't one.
 *
 * `Number()` is NOT good enough here: `Number(null)`, `Number("")` and
 * `Number([])` are all 0 — finite, and a perfectly plausible timestamp. A null
 * start time would have been read as "this word starts at 0.0" and the caption
 * would have DRIFTED instead of dropping out. Only a real number (or a numeric
 * string) counts. Caught by the grouping tests, not by review.
 */
function timeAt(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string") {
    const t = v.trim();
    if (t === "") return null;
    const n = Number(t);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

// ── Routes ───────────────────────────────────────────────────────────────────

interface TtsBody {
  text?: string;
  voice_id?: string;
  /** Anchors the provenance row. Without it nothing is entered in the audit log. */
  listing_id?: string;
  /** "Reel voiceover" — shown next to the public disclosure. */
  label?: string;
}

/** Voice ids go straight into the upstream URL PATH, so the format is enforced
 *  strictly: anything outside this alphabet could traverse or inject a path. */
const VOICE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    const user = await getUser(req); // owner auth
    const seg = pathSegments(req, "ai-voice");

    // ---- GET /ai-voice/voices ----
    if (req.method === "GET" && seg.length === 1 && seg[0] === "voices") {
      requireElevenLabs();
      // Read-only catalogue: any member may see it (the picker is part of the
      // editor UI, and no money moves here). Burst-limited so a loop can't
      // hammer the vendor through us on a cold cache.
      const orgId = await orgForUser(user.id, preferredOrg(req));
      if (!(await durableRateLimit(`aivoicelist:${orgId}`, 60, 300))) {
        throw new HttpError(429, "Too many voice-list requests — try again in a moment.", "rate_limited");
      }
      const cached = voicesCache !== null && Date.now() - voicesCache.at < VOICES_TTL_MS;
      return json({ voices: await fetchVoices(), cached });
    }

    // ---- POST /ai-voice/tts ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "tts") {
      requireElevenLabs();

      const body = await readJson<TtsBody>(req);

      // ── VALIDATE ────────────────────────────────────────────────────────────
      assert(typeof body.text === "string", 400, "text is required");
      const text = (body.text as string).trim();
      assert(text.length > 0, 400, "text is required");
      assert(
        text.length <= MAX_TEXT_CHARS,
        400,
        `Script is too long: ${text.length} characters (max ${MAX_TEXT_CHARS}). ` +
          `Trim it — a ${MAX_TEXT_CHARS}-character script is already about 90 seconds of speech.`,
      );

      // ── FAIR HOUSING ── nothing below this line is free, and there is no way
      // for a caller to reach it without passing here. Throws 400
      // `unsupported_edit` naming the offending phrase and why.
      assertMarketingCopy(text, "This voiceover script");

      const voiceId = String(body.voice_id ?? "").trim();
      assert(voiceId.length > 0, 400, "voice_id is required — call GET /ai-voice/voices first");
      assert(VOICE_ID_RE.test(voiceId), 400, "voice_id is not a valid ElevenLabs voice id");

      // Resolve the display name BEFORE charging: it is a free, cached call, and
      // a catalogue failure must never cost an allowance (it can't — it never
      // throws), let alone fail a generation the user already paid for.
      const voiceName = await voiceNameFor(voiceId);

      // ── CHARGE ── everything above is validated; the meter is charged here,
      // immediately before the billable call, and refunded on any failure.
      const charge = await guardTTS(user.id, req);

      try {
        // Held as an ArrayBuffer (a BodyInit) so the PUT streams the bytes with
        // no extra copy and no view/buffer type juggling.
        let audioBuf: ArrayBuffer;
        let timed: Timed;
        let normalizedFallback = false;
        const url =
          `${ELEVEN_BASE}/v1/text-to-speech/${encodeURIComponent(voiceId)}/with-timestamps` +
          `?output_format=${OUTPUT_FORMAT}`;
        const payload: Record<string, unknown> = { text };
        if (ELEVENLABS_MODEL_ID) payload.model_id = ELEVENLABS_MODEL_ID;

        const res = await fetch(url, {
          method: "POST",
          headers: elevenHeaders(),
          body: JSON.stringify(payload),
        });
        const data = await res.json().catch(() => ({} as Record<string, unknown>));
        if (!res.ok) {
          // Always 502 `upstream`, whatever ElevenLabs said. A 401/403 from the
          // vendor is OUR misconfiguration, not the caller's — surfacing it as
          // a 401 would tell the app the USER's session died and sign them out.
          throw new HttpError(
            502,
            `ElevenLabs ${res.status}: ${JSON.stringify(data).slice(0, 300)}`,
            "upstream",
          );
        }

        const b64 = (data as Record<string, unknown>).audio_base64;
        if (typeof b64 !== "string" || b64.length === 0) {
          throw new HttpError(502, "ElevenLabs returned no audio", "upstream");
        }
        try {
          const bin = atob(b64);
          audioBuf = new ArrayBuffer(bin.length);
          const view = new Uint8Array(audioBuf);
          for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
        } catch {
          throw new HttpError(502, "ElevenLabs returned audio that is not valid base64", "upstream");
        }
        if (audioBuf.byteLength === 0) {
          throw new HttpError(502, "ElevenLabs returned an empty audio file", "upstream");
        }

        // `alignment` indexes the ORIGINAL text (what the caption should show);
        // `normalized_alignment` indexes the spoken text. Same timeline.
        const d = data as Record<string, unknown>;
        timed = wordsFromAlignment(d.alignment as Alignment | undefined);
        if (timed.words.length === 0) {
          const alt = wordsFromAlignment(d.normalized_alignment as Alignment | undefined);
          if (alt.words.length > 0) {
            timed = alt;
            normalizedFallback = true;
          } else if (timed.lastEnd === null && alt.lastEnd !== null) {
            timed = alt; // no words either way, but a usable duration
          }
        }

        // ── STORE ── the mp3 goes to R2; the app gets a short-lived signed GET.
        // Own prefix so an R2 lifecycle rule can expire voiceovers without
        // touching listing media.
        const key = `ai-voice/${charge.orgId}/${crypto.randomUUID()}.mp3`;
        const putUrl = await presignPut({
          bucket: R2_BUCKET_UPLOADS,
          key,
          expiresIn: 300,
          contentType: OUTPUT_MIME,
        });
        const put = await fetch(putUrl, {
          method: "PUT",
          headers: { "content-type": OUTPUT_MIME },
          body: audioBuf,
        });
        if (!put.ok) {
          const detail = await put.text().catch(() => "");
          throw new HttpError(502, `Storing the voiceover failed (R2 ${put.status}): ${detail.slice(0, 200)}`, "upstream");
        }
        const audioUrl = await presignGet(R2_BUCKET_UPLOADS, key, AUDIO_URL_TTL_SECONDS);

        // ── DURATION ── measured, estimated or absent, and always labelled.
        let durationS = 0;
        let durationSource: "alignment" | "bitrate_estimate" | "last_word" | "unknown" = "unknown";
        if (timed.lastEnd !== null && Number.isFinite(timed.lastEnd) && timed.lastEnd > 0) {
          durationS = round3(timed.lastEnd);
          durationSource = "alignment";
        } else if (audioBuf.byteLength > 0) {
          // Only sound because WE asked for CBR mp3_44100_128 above.
          durationS = round3((audioBuf.byteLength * 8) / OUTPUT_BITRATE);
          durationSource = "bitrate_estimate";
        } else if (timed.words.length > 0) {
          durationS = round3(timed.words[timed.words.length - 1].end);
          durationSource = "last_word";
        }

        // ── PROVENANCE ── AI-generated audio, so the tour must be able to
        // disclose it. `kind` is "other": migration 0012's check constraint
        // allows photo_edit | virtual_stage | declutter | aerial | reel | other,
        // and "reel" would print the CLIP sentence ("generated from a still
        // photo… the motion is simulated"), which is not true of audio. Adding
        // a "voiceover" kind needs a migration; "other" discloses honestly
        // ("This media was digitally altered or generated with AI.") today.
        // Best effort — the generation is already billed, so a failed audit
        // insert reports itself instead of destroying a paid result.
        const prov = await recordProvenance(req, {
          listingId: body.listing_id ?? null,
          kind: "other",
          label: body.label ?? "Reel voiceover",
          modelId: `elevenlabs/${ELEVENLABS_MODEL_ID ?? "default"}`,
          edit: "voiceover",
          style: voiceName,
          // The script IS the user's own words; bounded and stripped by the RPC
          // and never returned publicly.
          promptSummary: text.slice(0, 300),
        });

        return json({
          audio_url: audioUrl,
          mime: OUTPUT_MIME,
          duration_s: durationS,
          /** Where duration_s came from — a video layout is built on it. */
          duration_source: durationSource,
          words: timed.words,
          voice_name: voiceName,
          characters: text.length,
          /** True when the timings came from the normalised (spoken) text
           *  because the original-text alignment was unusable. */
          normalized_alignment_used: normalizedFallback,
          disclosure: prov.disclosure,
          provenance: {
            id: prov.id,
            recorded: prov.recorded,
            ...(prov.reason ? { reason: prov.reason } : {}),
          },
        });
      } catch (err) {
        // The voiceover did not happen: hand the allowance back (audit F-E-16).
        //
        // This catch spans the provenance write too, which is safe ONLY because
        // recordProvenance() is documented and implemented as never-throwing
        // (it returns `{ recorded:false, reason }` instead). If that ever stops
        // being true, move the provenance call below this block — refunding a
        // voiceover that actually generated would hand back an allowance for
        // audio the user is holding.
        await refundCharge(charge);
        throw err;
      }
    }

    throw new HttpError(404, "Unknown ai-voice route — use GET /ai-voice/voices or POST /ai-voice/tts");
  } catch (err) {
    return respondError(err);
  }
});
