// probe.ts — "are my API keys actually working?", answered for $0.
//
// GET /admin/providers already answers a DIFFERENT question: "is this env var
// set?". A set env var proves nothing — a rotated key, a truncated paste, a
// key from the wrong account and a perfectly good key all read `configured:
// true`. Several of the keys below (ElevenLabs, Anthropic, OpenAI, Kie,
// Higgsfield, World Labs) have never been exercised from deployed code at all.
// This module exercises every one of them.
//
// ── THE FOUR RULES ───────────────────────────────────────────────────────────
//
// 1. EVERY PROBE IS $0 AND IDEMPOTENT. Each one is a list / credits / status
//    read — never a generation, never a write, never anything that mints a
//    resource. Where a vendor has no such endpoint the probe says so and
//    returns ok:null. A green light that cost money, or a green light nobody
//    actually earned, are both worse than an honest "can't test".
//
// 2. NO CREDENTIAL, AND NO RESPONSE BODY, EVER LEAVES THIS MODULE. A vendor's
//    error body is arbitrary text that can echo the key back (OpenAI's 401
//    literally quotes a masked form of the key you sent). Nothing is returned
//    verbatim: every upstream string goes through sanitize(), which redacts any
//    24+ character token-shaped run and truncates to 80 characters. Keys are
//    read once, put in a header, and never logged, measured or hashed.
//
// 3. A THROW IS NEVER A KEY VERDICT. A bad key is an HTTP ANSWER; a fetch that
//    throws (DNS, TLS, the 8-second abort) means we could not reach them at
//    all. Those are `auth` and `network` respectively and the console words
//    them differently — "wrong key" and "can't reach" are different jobs.
//
// 4. EVERY ENDPOINT AND EVERY STATUS CODE BELOW WAS VERIFIED against the live
//    vendor with a deliberately-bogus key on 2026-09-05. The doc URL and the
//    observed bad-key status are in each probe's comment. Two vendors do NOT
//    use 401 and would otherwise be misreported:
//      • Gemini answers 400 INVALID_ARGUMENT ("API key not valid").
//      • Kie answers HTTP 200 with {"code":401} in the BODY.
//
// Shape: docs/LAUNCH-CONTRACT.md § Key probe, plus `detail` (credits/quota) and
// `message` (sanitized) per result.

import {
  probeBucket,
  R2_BUCKET_UPLOADS,
} from "../_shared/r2.ts";

// ── Vocabulary ───────────────────────────────────────────────────────────────

/**
 * Why a probe failed, in the four words the console can act on:
 *   auth       — the vendor answered, and rejected the key (401/403, or the
 *                two documented off-spec equivalents above). Fix: the key.
 *   network    — fetch threw, or the 8-second abort fired. We never reached
 *                them. Fix: nothing, probably; try again.
 *   rate_limit — 429. The key is fine; we asked too often.
 *   other      — the vendor answered with something else (5xx, a 404 on a
 *                route we expected, a malformed body).
 */
export type ProbeErrorClass = "auth" | "network" | "rate_limit" | "other";

/** Scalars only — a number or a short label. Never a body, never an id. */
export type ProbeDetail = Record<string, string | number>;

export interface ProbeResult {
  /** Matches the `key` in admin/index.ts PROVIDERS where one exists. */
  key: string;
  /** Every env var this probe needs is set to a non-empty value. */
  configured: boolean;
  /**
   * true  — the vendor authenticated this key.
   * false — the vendor answered and it did not work, OR we could not reach it.
   * null  — NOT PROBEABLE (or not configured). Never rendered as a pass.
   */
  ok: boolean | null;
  latency_ms: number | null;
  error_class: ProbeErrorClass | null;
  /** Plain words: exactly what was called and what a pass proves. */
  how: string;
  /** Sanitized, <= 80 chars. Never a verbatim body. */
  message: string | null;
  /** Credits / quota worth knowing. Scalars only. */
  detail: ProbeDetail | null;
  /** The env var NAMES this probe reads. NAMES ONLY — never a value. */
  env_names: string[];
  /** Vendor documentation for the endpoint, so the choice is checkable. */
  doc: string;
}

export interface ProbeReport {
  checked_at: string;
  probe_count: number;
  ok_count: number;
  fail_count: number;
  /** Configured but deliberately unverifiable, or not configured at all. */
  not_probeable_count: number;
  results: ProbeResult[];
}

/** What one probe's `run` hands back. Everything else is filled in around it. */
interface ProbeOutcome {
  ok: boolean | null;
  error_class?: ProbeErrorClass | null;
  message?: string | null;
  detail?: ProbeDetail | null;
  /** Replaces the static `how` when the run learned something more specific. */
  how?: string;
}

export interface Probe {
  key: string;
  /** Env var NAMES only. All must be non-empty for `configured` to be true. */
  env_names: string[];
  how: string;
  doc: string;
  /**
   * Runs ONE $0 authenticated call. Must not throw for an ordinary vendor
   * answer — only a genuine transport failure may escape, and probeAll()
   * classifies that as `network`.
   */
  run(signal: AbortSignal): Promise<ProbeOutcome>;
}

// ── Redaction and classification (pure — covered by probe.test.ts) ───────────

/**
 * Any run of 24+ characters from the base64url/API-key alphabet. Every key in
 * this file is far longer than that, and no English word is: `[…]` costs a
 * little readability and buys the guarantee that a leaked key cannot ride out
 * of here inside a vendor's error message.
 */
const TOKEN_SHAPED = /[A-Za-z0-9_\-+/=]{24,}/g;

/** Longest message any result may carry. */
export const MAX_MESSAGE_CHARS = 80;

/**
 * Redact FIRST, then collapse whitespace, then truncate. The order matters: a
 * truncate-first sanitizer can slice a key in half and let the first 40
 * characters through, which is still a key.
 */
export function sanitize(raw: unknown, max = MAX_MESSAGE_CHARS): string {
  const text = typeof raw === "string" ? raw : String(raw ?? "");
  const redacted = text.replace(TOKEN_SHAPED, "[…]");
  const collapsed = redacted.replace(/\s+/g, " ").trim();
  if (collapsed.length <= max) return collapsed;
  return collapsed.slice(0, Math.max(1, max - 1)) + "…";
}

/** HTTP status → error class. 401/403 auth · 429 rate_limit · everything else other. */
export function classifyStatus(status: number): ProbeErrorClass {
  if (status === 401 || status === 403) return "auth";
  if (status === 429) return "rate_limit";
  return "other";
}

/**
 * Anything thrown out of `fetch` is a REACHABILITY failure, never a verdict on
 * the key: a rejected key is an HTTP answer, and an answer never throws. The
 * 8-second AbortError lands here too — a vendor that does not respond in eight
 * seconds is "can't reach", not "wrong key".
 */
export function classifyThrown(_err: unknown): ProbeErrorClass {
  return "network";
}

/** True when `err` is our own 8-second abort rather than a transport failure. */
export function isAbort(err: unknown): boolean {
  if (err instanceof DOMException) return err.name === "AbortError";
  return err instanceof Error && err.name === "AbortError";
}

/** Plain-words, sanitized message for a thrown fetch. */
export function thrownMessage(err: unknown): string {
  if (isAbort(err)) return `No answer in ${TIMEOUT_MS / 1000} seconds`;
  const raw = err instanceof Error ? err.message : String(err ?? "");
  const clean = sanitize(raw);
  return clean.length > 0 ? clean : "Could not reach the service";
}

// ── Env: NAMES in, boolean out. A value never leaves a probe's own call. ─────

function envValue(name: string): string | undefined {
  const raw = Deno.env.get(name);
  if (typeof raw !== "string") return undefined;
  // Trim for the same reason r2.ts does: one trailing newline from an
  // `echo`-piped `supabase secrets set` took the whole storage layer down on
  // 2026-09-04. A probe that reports "wrong key" for a stray \n is useless.
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
}

function envSet(name: string): boolean {
  return envValue(name) !== undefined;
}

/** First non-empty of several accepted NAMES (Stream is set under three). */
function firstEnv(...names: string[]): string | undefined {
  for (const n of names) {
    const v = envValue(n);
    if (v !== undefined) return v;
  }
  return undefined;
}

// ── HTTP plumbing ────────────────────────────────────────────────────────────

/** Per-probe ceiling. Long enough for a cold vendor, short enough for a human. */
export const TIMEOUT_MS = 8_000;

/**
 * One bounded GET. Returns the status plus a PARSED body for classification —
 * the parsed value is used to decide `ok`, and only ever leaves this module
 * through sanitize().
 */
async function getJson(
  url: string,
  headers: Record<string, string>,
  signal: AbortSignal,
  method = "GET",
  body?: { form: Record<string, string> },
): Promise<{ status: number; json: unknown; text: string }> {
  // `redirect: "manual"`, not "follow". Every probe carries its credential in a
  // VENDOR-SPECIFIC header (x-api-key, xi-api-key, x-goog-api-key, Api-Key…),
  // and only `Authorization` is stripped when fetch follows a cross-origin
  // redirect — so a hijacked or misconfigured vendor host that answers 302 to
  // somewhere else would be handed the key. None of these endpoints redirects;
  // if one ever starts, it surfaces here as `Unexpected answer (HTTP 30x)`,
  // which is a visible, diagnosable failure rather than a silent disclosure.
  const init: RequestInit = { method, headers, signal, redirect: "manual" };
  if (body) {
    init.headers = { ...headers, "content-type": "application/x-www-form-urlencoded" };
    init.body = new URLSearchParams(body.form).toString();
  }
  const res = await fetch(url, init);
  // Bounded read: a vendor that streams megabytes at an error page must not be
  // able to hold an edge function open. 8 KB is far more than any of these
  // endpoints answer with at page size 1.
  const text = (await res.text()).slice(0, 8192);
  let json: unknown = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: res.status, json, text };
}

// deno-lint-ignore no-explicit-any
function field(json: unknown, path: string): any {
  let cur: unknown = json;
  for (const seg of path.split(".")) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}

/** A finite number, or undefined. Vendors return quotas as strings sometimes. */
function num(value: unknown): number | undefined {
  const n = typeof value === "string" ? Number(value) : value;
  return typeof n === "number" && Number.isFinite(n) ? n : undefined;
}

/** The standard "vendor answered and it wasn't 2xx" outcome. */
function httpFailure(status: number, vendorMessage?: unknown): ProbeOutcome {
  const cls = classifyStatus(status);
  const detail = sanitize(vendorMessage ?? "");
  const base = cls === "auth"
    ? `Rejected the key (HTTP ${status})`
    : cls === "rate_limit"
    ? `Rate limited (HTTP ${status})`
    : `Unexpected answer (HTTP ${status})`;
  return {
    ok: false,
    error_class: cls,
    message: detail ? sanitize(`${base}: ${detail}`) : base,
  };
}

// ── The probes ───────────────────────────────────────────────────────────────
//
// Ordered the way the console lists them: the AI vendors that cost money first,
// then infrastructure, then the integrations.

export const PROBES: Probe[] = [
  // ── Google Gemini ──────────────────────────────────────────────────────────
  // GET /v1beta/models?pageSize=1 — model metadata only, no tokens, $0.
  // Doc:  https://ai.google.dev/api/models#method:-models.list
  // Header `x-goog-api-key` matches _shared/providers/gemini.ts:108 exactly.
  // VERIFIED 2026-09-05: a bogus key answers **400** INVALID_ARGUMENT
  // ("API key not valid. Please pass a valid API key."), NOT 401 — so the
  // generic 401/403 rule would have called a dead Gemini key "other" and the
  // console would have shown amber instead of red. Special-cased here.
  {
    key: "gemini",
    env_names: ["GEMINI_API_KEY"],
    how: "GET generativelanguage.googleapis.com/v1beta/models?pageSize=1 — lists model names only, generates nothing",
    doc: "https://ai.google.dev/api/models#method:-models.list",
    async run(signal) {
      const { status, json } = await getJson(
        "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1",
        { "x-goog-api-key": envValue("GEMINI_API_KEY")! },
        signal,
      );
      if (status === 200) return { ok: true };
      const msg = field(json, "error.message");
      // Google's own off-spec auth answer.
      if (status === 400 && /api key/i.test(String(msg ?? ""))) {
        return { ok: false, error_class: "auth", message: "Rejected the key (HTTP 400: API key not valid)" };
      }
      return httpFailure(status, msg);
    },
  },

  // ── fal.ai ─────────────────────────────────────────────────────────────────
  // GET https://api.fal.ai/v1/models?limit=1 — the platform model index. $0.
  // Doc:  https://fal.ai/docs/platform-apis/v1/models
  // Auth: `Authorization: Key <FAL_KEY>` (matches providers/fal.ts falHeaders).
  //
  // WHAT WE FOUND, and why this endpoint and not another (verified 2026-09-05):
  //   • With NO Authorization header it answers 200 — it is a public index.
  //     On its own that would prove nothing.
  //   • With a BOGUS key it answers 401 {"type":"authorization_error"}. So when
  //     a key IS sent it is genuinely validated, and this probe ALWAYS sends
  //     one (an unconfigured fal never reaches `run`). A 200 here therefore
  //     does prove the key.
  //   • The alternative — GET queue.fal.run/{model}/requests/{unknown-id}/status,
  //     which answers 404 NOT_FOUND with a good key and 401 with a bad one —
  //     also works and was verified, but it needs a hardcoded model slug and
  //     leans on a 401-vs-404 distinction fal does not document. The models
  //     index gives a plain 200/401 and needs no model id, so it wins.
  //   • GET /v1/models/usage was rejected: fal documents it as ADMIN-scope, and
  //     an API-scope FAL_KEY would fail it — a false red on a working key.
  {
    key: "fal",
    env_names: ["FAL_KEY"],
    how: "GET api.fal.ai/v1/models?limit=1 — model index, no generation. Public without a key, but a key that IS sent gets validated (bad key ⇒ 401), and this probe always sends one",
    doc: "https://fal.ai/docs/platform-apis/v1/models",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.fal.ai/v1/models?limit=1",
        { "Authorization": `Key ${envValue("FAL_KEY")!}` },
        signal,
      );
      if (status === 200) {
        const models = field(json, "models");
        return {
          ok: true,
          detail: Array.isArray(models) ? { models_visible: models.length } : null,
        };
      }
      return httpFailure(status, field(json, "error.message") ?? field(json, "detail"));
    },
  },

  // ── OpenAI ─────────────────────────────────────────────────────────────────
  // GET /v1/models — model list, no tokens, $0.
  // Doc:  https://platform.openai.com/docs/api-reference/models/list
  // VERIFIED 2026-09-05: bogus key ⇒ 401. Its 401 BODY quotes a masked form of
  // the key you sent, which is exactly the class of echo rule 2 exists for —
  // the message here is composed from the status, and the body never used.
  {
    key: "openai",
    env_names: ["OPENAI_API_KEY"],
    how: "GET api.openai.com/v1/models?limit=1 — lists model ids, generates nothing",
    doc: "https://platform.openai.com/docs/api-reference/models/list",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.openai.com/v1/models?limit=1",
        { "Authorization": `Bearer ${envValue("OPENAI_API_KEY")!}` },
        signal,
      );
      if (status === 200) {
        const data = field(json, "data");
        return { ok: true, detail: Array.isArray(data) ? { models_visible: data.length } : null };
      }
      // Deliberately NOT passing OpenAI's body through: it echoes the key.
      return httpFailure(status);
    },
  },

  // ── Anthropic ──────────────────────────────────────────────────────────────
  // GET /v1/models?limit=1 — model metadata, no tokens, $0.
  // Doc:  https://platform.claude.com/docs/en/api/models/list
  // Headers mirror providers/anthropic.ts: x-api-key + anthropic-version.
  // VERIFIED 2026-09-05: bogus key ⇒ 401 authentication_error.
  {
    key: "anthropic",
    env_names: ["ANTHROPIC_API_KEY"],
    how: "GET api.anthropic.com/v1/models?limit=1 — model metadata, zero tokens billed",
    doc: "https://platform.claude.com/docs/en/api/models/list",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.anthropic.com/v1/models?limit=1",
        {
          "x-api-key": envValue("ANTHROPIC_API_KEY")!,
          "anthropic-version": "2023-06-01",
        },
        signal,
      );
      if (status === 200) return { ok: true };
      return httpFailure(status, field(json, "error.message"));
    },
  },

  // ── ElevenLabs ─────────────────────────────────────────────────────────────
  // GET /v1/user/subscription — the account's own quota. $0, and it answers the
  // second question the owner always asks straight after "does the key work":
  // how much voiceover is left this month.
  // Doc:  https://elevenlabs.io/docs/api-reference/user/subscription/get
  // Header `xi-api-key` (never Bearer) — providers/elevenlabs.ts says so too.
  // VERIFIED 2026-09-05: bogus key ⇒ 401 {"detail":{"code":"unauthorized"}}.
  {
    key: "elevenlabs",
    env_names: ["ELEVENLABS_API_KEY"],
    how: "GET api.elevenlabs.io/v1/user/subscription — your own plan and character quota, generates no audio",
    doc: "https://elevenlabs.io/docs/api-reference/user/subscription/get",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.elevenlabs.io/v1/user/subscription",
        { "xi-api-key": envValue("ELEVENLABS_API_KEY")! },
        signal,
      );
      if (status !== 200) {
        return httpFailure(status, field(json, "detail.message") ?? field(json, "detail"));
      }
      const detail: ProbeDetail = {};
      const used = num(field(json, "character_count"));
      const limit = num(field(json, "character_limit"));
      if (used !== undefined && limit !== undefined) {
        detail.characters_left = Math.max(0, Math.round(limit - used));
      }
      const tier = field(json, "tier");
      if (typeof tier === "string" && tier.trim() !== "") detail.tier = sanitize(tier, 24);
      return { ok: true, detail: Object.keys(detail).length > 0 ? detail : null };
    },
  },

  // ── Kie.ai ─────────────────────────────────────────────────────────────────
  // GET /api/v1/chat/credit — the account's remaining credits. $0.
  // Doc:  https://docs.kie.ai/common-api/get-account-credits
  //
  // KIE DOES NOT USE HTTP STATUS. Verified 2026-09-05: a bogus bearer answers
  // **HTTP 200** with {"code":401,"msg":"Unauthorized – ..."} in the body. The
  // adapter (providers/kie.ts) already documents this. Reading only the HTTP
  // status here would have reported a dead Kie key as WORKING — the single most
  // dangerous possible bug in this file, so the body's `code` is authoritative.
  {
    key: "kie",
    env_names: ["KIE_API_KEY"],
    how: "GET api.kie.ai/api/v1/chat/credit — remaining credits, generates nothing. Kie answers HTTP 200 even when it rejects the key, so the body's own `code` is what decides",
    doc: "https://docs.kie.ai/common-api/get-account-credits",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.kie.ai/api/v1/chat/credit",
        { "Authorization": `Bearer ${envValue("KIE_API_KEY")!}`, "Content-Type": "application/json" },
        signal,
      );
      // A real transport-level failure still counts.
      if (status >= 500) return httpFailure(status);
      const code = num(field(json, "code")) ?? status;
      const msg = field(json, "msg");
      if (code === 200) {
        const credits = num(field(json, "data"));
        return { ok: true, detail: credits !== undefined ? { credits_left: credits } : null };
      }
      return httpFailure(code, msg);
    },
  },

  // ── Higgsfield ─────────────────────────────────────────────────────────────
  // GET /requests/{uuid}/status with an all-zero request id. $0 — it looks up a
  // request that does not exist and generates nothing.
  // Doc:  https://docs.higgsfield.ai/docs/api-reference/requests/get-request-status
  // Auth: `Authorization: Key <ID>:<SECRET>` — providers/higgsfield.ts hfHeaders.
  //
  // Higgsfield's OpenAPI documents BOTH answers explicitly, which is what makes
  // this readable as a key test:
  //   401 — "Missing or invalid API credentials."  ⇒ the key is wrong.
  //   404 — "The request does not exist or belongs to another account."
  //         ⇒ we got PAST authentication. The key works.
  // VERIFIED 2026-09-05: bogus creds ⇒ 401 {"detail":"Invalid credentials"}.
  //
  // Base host is api.higgsfield.ai, NOT platform.higgsfield.ai. The adapter's
  // GET /v1/motions also authenticates (bogus creds ⇒ 401) and would give a
  // plain 200, but it is absent from Higgsfield's published docs, so a 404 from
  // it could not be told apart from a working key with a moved route. The
  // documented status endpoint is used instead.
  {
    key: "higgsfield",
    env_names: ["HIGGSFIELD_API_KEY_ID", "HIGGSFIELD_API_KEY_SECRET"],
    how: "GET api.higgsfield.ai/requests/{unknown-id}/status — looks up a request that does not exist. 404 means the key authenticated; 401 means it did not",
    doc: "https://docs.higgsfield.ai/docs/api-reference/requests/get-request-status",
    async run(signal) {
      const id = envValue("HIGGSFIELD_API_KEY_ID")!;
      const secret = envValue("HIGGSFIELD_API_KEY_SECRET")!;
      const { status, json } = await getJson(
        "https://api.higgsfield.ai/requests/00000000-0000-0000-0000-000000000000/status",
        { "Authorization": `Key ${id}:${secret}` },
        signal,
      );
      // 404 is the PASS here — see the note above.
      if (status === 404 || status === 200) {
        return { ok: true, message: "Signed in (the test request id is deliberately unknown)" };
      }
      return httpFailure(status, field(json, "detail"));
    },
  },

  // ── World Labs (Marble) ────────────────────────────────────────────────────
  // GET /marble/v1/credits — remaining API credits. $0.
  // Doc:  https://docs.worldlabs.ai/api/reference/credits/get
  // Auth: header `WLT-Api-Key` — NOT Bearer and NOT x-api-key (confirmed from
  // their OpenAPI securitySchemes: {in: header, name: WLT-Api-Key}).
  // VERIFIED 2026-09-05: bogus key ⇒ 401 {"message":"Unauthorized"}.
  //
  // ENV NAME IS NEW. `WORLDLABS_API_KEY` appears NOWHERE in this repo today —
  // there is no worldlabs adapter, set-secrets.sh does not list it, and the
  // only worldlabs references are a router seed row and the 3D research brief.
  // Until the owner sets it this row reports "Not set", which is the truth.
  // Their docs note 404 = "the caller is not an API-enabled user", which is a
  // real and distinct state: an account that exists but has no API access.
  {
    key: "worldlabs",
    env_names: ["WORLDLABS_API_KEY"],
    how: "GET api.worldlabs.ai/marble/v1/credits — remaining credits, builds no world",
    doc: "https://docs.worldlabs.ai/api/reference/credits/get",
    async run(signal) {
      const { status, json } = await getJson(
        "https://api.worldlabs.ai/marble/v1/credits",
        { "WLT-Api-Key": envValue("WORLDLABS_API_KEY")! },
        signal,
      );
      if (status === 200) {
        const credits = num(field(json, "remaining_credits"));
        return { ok: true, detail: credits !== undefined ? { credits_left: credits } : null };
      }
      if (status === 404) {
        return {
          ok: false,
          error_class: "other",
          message: "This account has no World API access yet",
        };
      }
      return httpFailure(status, field(json, "message"));
    },
  },

  // ── Cloudflare R2 ──────────────────────────────────────────────────────────
  // A SigV4-signed ListObjectsV2 with max-keys=1 on the uploads bucket. $0 —
  // R2 charges for class-A operations at a rate of $0 on the free tier and
  // fractions of a cent per million otherwise, and one list moves no bytes.
  // Doc:  https://developers.cloudflare.com/r2/api/s3/api/
  // Signing reuses the SAME aws4fetch client every presign and every delete
  // uses (probeBucket in _shared/r2.ts) — so a pass here proves the exact
  // credentials the upload path uses, not a second copy of them.
  {
    key: "cloudflare_r2",
    env_names: ["CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"],
    how: `Signed ListObjectsV2 (max-keys=1) on the "${R2_BUCKET_UPLOADS}" bucket — reads at most one object NAME, moves no bytes`,
    doc: "https://developers.cloudflare.com/r2/api/s3/api/",
    async run(_signal) {
      // r2.ts owns the credentials; this module never reads them.
      let res: Awaited<ReturnType<typeof probeBucket>>;
      try {
        res = await probeBucket(R2_BUCKET_UPLOADS);
      } catch (err) {
        // Worth catching separately: the ACCOUNT ID is part of R2's hostname
        // (<account>.r2.cloudflarestorage.com), so a wrong or pasted-with-
        // whitespace CLOUDFLARE_ACCOUNT_ID fails DNS and arrives here as a bare
        // "fetch failed". Naming the likely cause turns an unhelpful "can't
        // reach" into something the owner can actually fix. (Verified
        // 2026-09-05 with a well-formed but nonexistent account id.)
        return {
          ok: false,
          error_class: classifyThrown(err),
          message: isAbort(err)
            ? `No answer in ${TIMEOUT_MS / 1000} seconds`
            : "Couldn't reach R2 — check CLOUDFLARE_ACCOUNT_ID (it's part of the address)",
        };
      }
      if (res.ok) return { ok: true, detail: { bucket: res.bucket } };
      if (res.status === 404) {
        return {
          ok: false,
          error_class: "other",
          message: `The bucket "${sanitize(res.bucket, 40)}" does not exist`,
          detail: { bucket: res.bucket },
        };
      }
      // S3/R2 answers 403 for both a wrong key id and a wrong secret.
      return { ...httpFailure(res.status), detail: { bucket: res.bucket } };
    },
  },

  // ── Cloudflare Stream ──────────────────────────────────────────────────────
  // GET /accounts/{id}/stream?per_page=1 — lists at most one video. $0.
  // Doc:  https://developers.cloudflare.com/api/resources/stream/methods/list/
  //
  // TOKEN NAME: _shared/stream.ts accepts THREE names in this order —
  // CLOUDFLARE_STREAM_API_TOKEN, then CLOUDFLARE_STREAM_TOKEN, then
  // CLOUDFLARE_API_TOKEN — because following the repo's own set-secrets.sh had
  // previously left Stream deletion silently unconfigured. The probe reads the
  // same three in the same order, so it can never disagree with the code that
  // actually deletes videos.
  //
  // CLOUDFLARE DOES NOT USE 401 EITHER. Verified 2026-09-05: a bogus token
  // answers **400** with {"success":false,"errors":[{"code":9106,"message":
  // "Authentication failed"}]}. Cloudflare's auth-family codes are matched
  // explicitly so this reads as "wrong key", not "unexpected answer".
  {
    key: "cloudflare_stream",
    env_names: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_STREAM_TOKEN"],
    how: "GET api.cloudflare.com/client/v4/accounts/{id}/stream?per_page=1 — lists at most one video, uploads nothing",
    doc: "https://developers.cloudflare.com/api/resources/stream/methods/list/",
    async run(signal) {
      const account = envValue("CLOUDFLARE_ACCOUNT_ID")!;
      const token = firstEnv(
        "CLOUDFLARE_STREAM_API_TOKEN",
        "CLOUDFLARE_STREAM_TOKEN",
        "CLOUDFLARE_API_TOKEN",
      )!;
      const { status, json } = await getJson(
        `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(account)}/stream?per_page=1`,
        { "Authorization": `Bearer ${token}` },
        signal,
      );
      const errors = field(json, "errors");
      const first = Array.isArray(errors) && errors.length > 0 ? errors[0] : null;
      const cfCode = num(first?.code);
      const cfMessage = first?.message;

      if (status === 200 && field(json, "success") === true) {
        const result = field(json, "result");
        return { ok: true, detail: Array.isArray(result) ? { videos_visible: result.length } : null };
      }
      // 9106 / 9109 / 10000 are Cloudflare's authentication family; they arrive
      // on a 400, which classifyStatus would otherwise call "other".
      const authCode = cfCode !== undefined && [9106, 9109, 10000].includes(cfCode);
      const authWords = /authenticat|unauthor|invalid.*(token|key|credential)/i.test(String(cfMessage ?? ""));
      if (status === 401 || status === 403 || authCode || authWords) {
        return {
          ok: false,
          error_class: "auth",
          message: sanitize(`Rejected the token (HTTP ${status}: ${cfMessage ?? "authentication failed"})`),
        };
      }
      return httpFailure(status, cfMessage);
    },
  },

  // ── GoHighLevel CRM ────────────────────────────────────────────────────────
  // GET /locations/{GHL_LOCATION_ID} — reads the CRM location the leads
  // function upserts into. $0 (the CRM subscription covers API calls) and it
  // creates no contact.
  // Doc:  https://marketplace.gohighlevel.com/docs/ghl/locations/get-location
  // Host + `Version: 2021-07-28` header mirror leads/index.ts pushToGHL.
  // VERIFIED 2026-09-05: bogus token ⇒ 401 {"message":"Invalid Private
  // Integration token"} on BOTH /locations/{id} and /contacts/.
  //
  // ONE SUBTLETY, handled honestly: a Private Integration token scoped only to
  // `contacts.write` (all the lead sync needs) will get a 403 here, not a 200.
  // A 403 still proves the token AUTHENTICATED — LeadConnector answers 401, not
  // 403, for a token it does not recognise. So 403 is reported as a PASS with a
  // sentence saying the token simply cannot read locations, which is fine.
  {
    key: "ghl",
    env_names: ["GHL_API_KEY", "GHL_LOCATION_ID"],
    how: "GET services.leadconnectorhq.com/locations/{id} — reads the CRM location, creates no contact",
    doc: "https://marketplace.gohighlevel.com/docs/ghl/locations/get-location",
    async run(signal) {
      const key = envValue("GHL_API_KEY")!;
      const location = envValue("GHL_LOCATION_ID")!;
      const { status, json } = await getJson(
        `https://services.leadconnectorhq.com/locations/${encodeURIComponent(location)}`,
        {
          "Authorization": `Bearer ${key}`,
          "Version": "2021-07-28",
          "Accept": "application/json",
        },
        signal,
      );
      if (status === 200) return { ok: true };
      if (status === 403) {
        return {
          ok: true,
          message: "Key works — it just can't read locations (that's fine for lead sync)",
        };
      }
      return httpFailure(status, field(json, "message"));
    },
  },

  // ── Cloudflare Turnstile ───────────────────────────────────────────────────
  // POST /turnstile/v0/siteverify with a deliberately-invalid response token.
  // Free, idempotent (verifying a token that was never issued changes nothing)
  // and it is the SAME call leads/index.ts makes on every public lead form.
  // Doc:  https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
  //
  // The trick is which error code comes back, and it is a clean split verified
  // against Cloudflare on 2026-09-05:
  //   bad secret  ⇒ HTTP 400, error-codes ["invalid-input-secret"]
  //   good secret ⇒ HTTP 200, error-codes ["invalid-input-response"]
  //                 (Cloudflare only bothers to validate the TOKEN once it has
  //                  accepted the SECRET, so reaching that error is the pass.)
  // This is a POST rather than a GET, which is the only $0 authenticated call
  // Turnstile offers; it spends nothing and writes nothing.
  {
    key: "turnstile",
    env_names: ["TURNSTILE_SECRET_KEY"],
    how: "POST challenges.cloudflare.com/turnstile/v0/siteverify with a token that was never issued — \"invalid-input-secret\" means the secret is wrong, anything else means it is right",
    doc: "https://developers.cloudflare.com/turnstile/get-started/server-side-validation/",
    async run(signal) {
      const { status, json } = await getJson(
        "https://challenges.cloudflare.com/turnstile/v0/siteverify",
        {},
        signal,
        "POST",
        {
          form: {
            secret: envValue("TURNSTILE_SECRET_KEY")!,
            response: "rendprop-key-probe-not-a-real-token",
          },
        },
      );
      const codes = field(json, "error-codes");
      const list = Array.isArray(codes) ? codes.map((c) => String(c)) : [];
      if (list.includes("invalid-input-secret") || list.includes("missing-input-secret")) {
        return { ok: false, error_class: "auth", message: "Cloudflare rejected the secret" };
      }
      if (status === 200) {
        return { ok: true, message: "Secret accepted (the test token was expected to fail)" };
      }
      return httpFailure(status, list.join(", "));
    },
  },

  // ── Sign in with Apple ─────────────────────────────────────────────────────
  // NO NETWORK CALL. Apple's token endpoints (appleid.apple.com/auth/token and
  // /auth/revoke) both require a real user artefact — a single-use
  // authorizationCode that expires in five minutes, or a stored refresh token.
  // Neither can be manufactured, so there is NO $0 authenticated probe: any
  // request we could construct would be rejected for the missing artefact, not
  // for the key, and could not tell a good key from a bad one.
  //
  // What CAN be proved without a user is that the .p8 is a real ES256 private
  // key: importing it with WebCrypto is exactly what clientSecret() in
  // _shared/apple.ts does before every call, and a paste that lost its newlines
  // or its PEM armour fails here for the same reason it would fail there. That
  // is the failure this actually catches, and it is the common one.
  {
    key: "apple",
    env_names: ["APPLE_TEAM_ID", "APPLE_CLIENT_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY_P8"],
    how: "Imports the .p8 private key with WebCrypto (ES256/P-256) — the same parse _shared/apple.ts does before every Apple call. Apple has no $0 authenticated endpoint: signing in needs a real user, so nothing here proves the key against Apple's servers",
    doc: "https://developer.apple.com/documentation/technotes/tn3194-generating-and-validating-a-sign-in-with-apple-authorization-code",
    async run(_signal) {
      const pem = envValue("APPLE_PRIVATE_KEY_P8")!;
      try {
        await crypto.subtle.importKey(
          "pkcs8",
          pemToPkcs8(pem),
          { name: "ECDSA", namedCurve: "P-256" },
          false,
          ["sign"],
        );
      } catch {
        // The thrown message can quote key bytes. It is never surfaced.
        return {
          ok: false,
          error_class: "other",
          message: "The .p8 key could not be read — re-paste it, newlines and all",
        };
      }
      return { ok: true, message: "Private key parses. Signing in still needs a real person" };
    },
  },
];

/**
 * PEM (.p8) → PKCS#8 bytes. A local copy of the same three lines
 * _shared/apple.ts uses, because that file's helper is not exported and
 * apple.ts is not this agent's to change. Tolerant of the two shapes a .p8
 * arrives in: real newlines, and the `\n`-escaped form a shell here-doc makes.
 */
function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buf = new ArrayBuffer(raw.length);
  const out = new Uint8Array(buf);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return buf;
}

// ── Running them all ─────────────────────────────────────────────────────────

/** The one place a single probe's lifecycle is managed: timeout, clock, catch. */
async function runOne(probe: Probe): Promise<ProbeResult> {
  const base = {
    key: probe.key,
    how: probe.how,
    env_names: probe.env_names,
    doc: probe.doc,
  };

  const configured = probe.env_names.length > 0 && probe.env_names.every(envSet);
  if (!configured) {
    // Not a failure: an unset key is a feature that is off, and the console
    // renders it grey. Never red, and never green.
    return {
      ...base,
      configured: false,
      ok: null,
      latency_ms: null,
      error_class: null,
      message: "Not set, so there is nothing to test",
      detail: null,
    };
  }

  const controller = new AbortController();
  // A vendor that has not answered in 8 seconds is not going to; the console
  // waits on ALL of these at once, so one slow vendor must not own the screen.
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const started = Date.now();
  try {
    const outcome = await probe.run(controller.signal);
    return {
      ...base,
      how: outcome.how ?? probe.how,
      configured: true,
      ok: outcome.ok,
      latency_ms: Date.now() - started,
      error_class: outcome.ok === false ? (outcome.error_class ?? "other") : null,
      message: outcome.message ? sanitize(outcome.message) : null,
      detail: outcome.detail ?? null,
    };
  } catch (err) {
    // Nothing about `err` is logged: a thrown request can carry the URL, and a
    // URL can carry a query-string credential.
    return {
      ...base,
      configured: true,
      ok: false,
      latency_ms: Date.now() - started,
      error_class: classifyThrown(err),
      message: thrownMessage(err),
      detail: null,
    };
  } finally {
    // Deno keeps the isolate alive for a pending timer; always clear it.
    clearTimeout(timer);
  }
}

/**
 * Every probe, concurrently, bounded. `Promise.allSettled` rather than
 * `Promise.all` so one vendor's failure can never blank the other twelve
 * answers — the whole point of the screen is seeing which one is broken.
 */
export async function probeAll(): Promise<ProbeReport> {
  const settled = await Promise.allSettled(PROBES.map(runOne));

  const results: ProbeResult[] = settled.map((s, i) => {
    if (s.status === "fulfilled") return s.value;
    // runOne catches everything itself, so this branch is defence in depth.
    const p = PROBES[i];
    return {
      key: p.key,
      configured: p.env_names.every(envSet),
      ok: false,
      latency_ms: null,
      error_class: "other",
      how: p.how,
      message: "The test itself failed to run",
      detail: null,
      env_names: p.env_names,
      doc: p.doc,
    };
  });

  return {
    checked_at: new Date().toISOString(),
    probe_count: results.length,
    ok_count: results.filter((r) => r.ok === true).length,
    fail_count: results.filter((r) => r.ok === false).length,
    not_probeable_count: results.filter((r) => r.ok === null).length,
    results,
  };
}
