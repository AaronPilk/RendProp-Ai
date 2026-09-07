// The opaque job token that lets ONE async status route serve every provider.
//
// ai-video submits and returns 202 with { request_id, status_url, response_url },
// and the shipped app hands those three strings back to GET /ai-video/status
// verbatim — it never looks inside them (LiveAPIClient percent-encodes and
// returns them as-is). So for a routed job we mint a URL addressed to OUR OWN
// status route carrying the vendor job in a query parameter, and one code path
// serves fal, Kie and Higgsfield with no client change at all.
//
// ── SECURITY (audit item 4) ──────────────────────────────────────────────────
//
// Before this fix a token was plain base64url JSON: unsigned, unowned, and
// forever valid. Two consequences:
//   • LEAK → ADOPTION. Any other authenticated caller who obtained the string
//     (a referrer header, a shared log line, a screenshot) could hand it back
//     to GET /ai-video/status and have the finished asset persisted under
//     THEIR OWN org — silently adopting someone else's paid generation.
//   • FORGERY → CREDENTIAL MISUSE. Nothing stopped a caller from HAND-BUILDING
//     a token (any base64url JSON of the right shape) naming an arbitrary
//     provider/model/vendor-id/poll_url. The server would poll that URL with
//     OUR vendor credentials on the forger's say-so.
//
// The fix makes a token a SIGNED, OWNED, EXPIRING capability instead of a
// readable bag of JSON:
//   • SIGNED   — HMAC-SHA256 over the payload with a server-only secret
//                (JOB_TOKEN_SIGNING_SECRET; see this repo's function README.md
//                §2 and DEPLOYMENT.md). A tampered payload or a forged
//                signature fails verification and decodes to `null`.
//   • OWNED    — every token carries the org id (`o`) AND user id (`usr`) that
//                created the job. GET /ai-video/status re-derives the caller's
//                own org/user from THEIR JWT (never from the token) and
//                verifyJobToken() refuses to hand back a token whose owner
//                does not match — a leaked token can be replayed by nobody but
//                the org+user it was minted for.
//   • EXPIRING — every token carries a short-lived `exp` (unix seconds).
//
// verifyJobToken() is the ONE gate: signature, shape, expiry and ownership are
// all checked there, BEFORE the caller ever polls the vendor with our
// credentials — so a forged or leaked/mismatched-owner token never reaches
// adapter.poll().
//
// NO GRACE PATH for the pre-fix unsigned format. Nothing in this repository is
// a live deployment with async jobs already in flight, so there is nothing an
// old token needs to keep working for, and a grace path is itself a bounded
// re-opening of the exact hole this closes. A real rollout that DOES have
// in-flight jobs at deploy time would need one — time-boxed to the longest
// supported job (see TOKEN_TTL_SECONDS below) — see docs/handoff/audit-fixes.md.
//
// WHAT A TOKEN MAY CONTAIN: provider, model, vendor job id, vendor poll URL,
// submit time, task, the org id + user id that created it, and an expiry.
// Still NO vendor credential and NO signed URL. Every OTHER authorization
// decision (role, membership, plan) still runs off the caller's own JWT
// exactly as before — the token only ever narrows what a caller may do, never
// widens it.

import type { JobRef } from "./types.ts";

export interface RouterJobToken {
  p: string; // provider
  m: string; // model
  i: string; // vendor job id
  u?: string; // vendor poll url
  t: string; // submitted_at
  k: string; // task
  o: string; // org id that created the job
  usr: string; // user id that created the job
  exp: number; // unix-seconds expiry
}

/** Who a token must be minted for, and who a status request must match. */
export interface JobTokenOwner {
  orgId: string;
  userId: string;
}

// How long a minted token stays valid. Generous relative to the longest job
// the router's seed advertises (video.upscale_4k / video.upscale_1080p60,
// max_latency_s = 1800s = 30 min — 0018_ai_routes.sql) plus slack for a vendor
// queue that is running behind and a client that polls slowly.
export const TOKEN_TTL_SECONDS = 2 * 60 * 60; // 2 hours

function trimmedEnv(name: string): string | undefined {
  const raw = Deno.env.get(name);
  if (raw === undefined) return undefined;
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
}

/**
 * Dedicated signing secret for these tokens (documented in README.md §2 and
 * DEPLOYMENT.md as a required ai-video secret). Deliberately its OWN env var
 * rather than reusing a vendor key or the Supabase service-role key: rotating
 * it must never also rotate a vendor credential, and a token forged from a
 * leaked vendor key would defeat the whole point of signing.
 */
function requireSecret(): string {
  const secret = trimmedEnv("JOB_TOKEN_SIGNING_SECRET");
  if (!secret) {
    throw new Error(
      "JOB_TOKEN_SIGNING_SECRET function secret is not set — async job tokens cannot be " +
        "signed or verified. Set it (services/supabase/functions/README.md §2, DEPLOYMENT.md).",
    );
  }
  return secret;
}

// The imported CryptoKey is cached per-isolate (import is not free), keyed by
// the secret's own value so a changed secret can never keep signing/verifying
// with the stale key inside one long-lived isolate.
let cachedKey: { secret: string; key: CryptoKey } | null = null;
async function hmacKey(): Promise<CryptoKey> {
  const secret = requireSecret();
  if (cachedKey && cachedKey.secret === secret) return cachedKey.key;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  cachedKey = { secret, key };
  return key;
}

function toB64Url(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Built on a concrete `new ArrayBuffer(...)` (not `Uint8Array.from`, which
// infers `Uint8Array<ArrayBufferLike>`) so the result satisfies `BufferSource`
// for crypto.subtle.verify() — mirrors providers/common.ts b64Bytes().
function fromB64Url(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "="));
  const bytes = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

/**
 * Sign + encode one job token for `owner`. The wire shape is
 * `<base64url(payload JSON)>.<base64url(HMAC-SHA256 of that string)>` — a
 * dot separates the two, which base64url's alphabet never contains, so
 * splitting on the LAST dot is unambiguous.
 *
 * Throws (a plain Error, not HttpError — this is a shared module with no HTTP
 * dependency) when JOB_TOKEN_SIGNING_SECRET is unset. Callers should let that
 * surface as a loud 500 rather than silently minting an unsigned token.
 */
export async function encodeJobToken(
  job: Omit<RouterJobToken, "o" | "usr" | "exp">,
  owner: JobTokenOwner,
): Promise<string> {
  const full: RouterJobToken = {
    p: job.p,
    m: job.m,
    i: job.i,
    u: job.u,
    t: job.t,
    k: job.k,
    o: owner.orgId,
    usr: owner.userId,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  };
  const payloadB64 = toB64Url(new TextEncoder().encode(JSON.stringify(full)));
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", await hmacKey(), new TextEncoder().encode(payloadB64)),
  );
  return `${payloadB64}.${toB64Url(mac)}`;
}

/**
 * Verify the signature and shape of a raw token string. Does NOT check expiry
 * or ownership — see verifyJobToken() for the full gate. Exported separately
 * so tests can exercise "tampered payload" and "forged signature" at this
 * granular level.
 *
 * Never throws: a missing secret, a malformed string, a bad signature, or a
 * payload that doesn't parse into the expected shape all answer `null`.
 */
export async function decodeJobToken(raw: string): Promise<RouterJobToken | null> {
  const dot = raw.lastIndexOf(".");
  if (dot <= 0 || dot === raw.length - 1) return null;
  const payloadB64 = raw.slice(0, dot);
  const sigB64 = raw.slice(dot + 1);

  let key: CryptoKey;
  try {
    key = await hmacKey();
  } catch {
    return null; // no secret configured — every token is untrusted
  }

  let mac: Uint8Array<ArrayBuffer>;
  try {
    mac = fromB64Url(sigB64);
  } catch {
    return null;
  }
  let valid: boolean;
  try {
    valid = await crypto.subtle.verify(
      "HMAC",
      key,
      mac,
      new TextEncoder().encode(payloadB64),
    );
  } catch {
    return null;
  }
  if (!valid) return null;

  try {
    const bytes = fromB64Url(payloadB64);
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as Partial<RouterJobToken>;
    if (
      !parsed ||
      typeof parsed.p !== "string" || parsed.p.length === 0 ||
      typeof parsed.m !== "string" || parsed.m.length === 0 ||
      typeof parsed.i !== "string" || parsed.i.length === 0 ||
      typeof parsed.o !== "string" || parsed.o.length === 0 ||
      typeof parsed.usr !== "string" || parsed.usr.length === 0 ||
      typeof parsed.exp !== "number" || !Number.isFinite(parsed.exp)
    ) {
      return null;
    }
    if (parsed.u !== undefined && typeof parsed.u !== "string") return null;
    return {
      p: parsed.p,
      m: parsed.m,
      i: parsed.i,
      u: parsed.u,
      t: String(parsed.t ?? ""),
      k: String(parsed.k ?? ""),
      o: parsed.o,
      usr: parsed.usr,
      exp: parsed.exp,
    };
  } catch {
    return null;
  }
}

/** True when a decoded token's expiry has passed (or lands exactly now). */
export function isExpired(job: Pick<RouterJobToken, "exp">, now: Date = new Date()): boolean {
  return job.exp * 1000 <= now.getTime();
}

/**
 * THE FULL GATE. Decode + verify signature/shape, reject if expired, reject
 * if the token's org+user do not match `owner`. Returns the token only when
 * ALL of that holds; `null` on any single failure (bad signature, tampered
 * payload, expired, wrong org, or wrong user) — callers get one code path for
 * "no", which is what makes this safe to call before spending our credentials
 * on a vendor poll.
 *
 * Never throws.
 */
export async function verifyJobToken(
  raw: string,
  owner: JobTokenOwner,
  now: Date = new Date(),
): Promise<RouterJobToken | null> {
  const job = await decodeJobToken(raw);
  if (!job) return null;
  if (isExpired(job, now)) return null;
  if (job.o !== owner.orgId || job.usr !== owner.userId) return null;
  return job;
}

/** OUR status URL for a routed job, built from the request's own origin. */
export async function routerStatusUrl(
  req: Request,
  functionName: string,
  task: string,
  ref: JobRef,
  owner: JobTokenOwner,
): Promise<string> {
  const u = new URL(req.url);
  const parts = u.pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf(functionName);
  const base = idx >= 0 ? `/${parts.slice(0, idx + 1).join("/")}` : `/${functionName}`;
  const token = await encodeJobToken(
    {
      p: ref.provider,
      m: ref.model,
      i: ref.id,
      u: ref.poll_url,
      t: ref.submitted_at,
      k: task,
    },
    owner,
  );
  return `${u.origin}${base}/status?job=${token}`;
}

/**
 * Pull the raw token STRING out of a status request's query params, without
 * verifying anything. A status request can carry it two ways:
 *   • directly, as `?job=<token>` (a caller that reads our 202 body's fields
 *     by name and calls status with `job` itself), or
 *   • nested inside `status_url` / `response_url`, because those two fields
 *     are OUR OWN URL (already containing `?job=...`) and the shipped app
 *     round-trips whatever it was handed as `status_url`/`response_url`
 *     query params rather than a `job` param.
 *
 * Returns `null` only when NEITHER shape is present — i.e. this genuinely
 * looks like a legacy (flag-off, direct-fal) status request, which the caller
 * should route to the unchanged fal-URL path. A `job=` value that is present
 * but garbage is still returned here (so the caller can tell "a token was
 * attempted and failed" apart from "no token at all") — pass it to
 * verifyJobToken() to find out.
 */
export function extractJobToken(params: URLSearchParams): string | null {
  const direct = params.get("job");
  if (direct) return direct;
  const statusUrl = params.get("status_url");
  if (!statusUrl) return null;
  try {
    return new URL(statusUrl).searchParams.get("job");
  } catch {
    return null;
  }
}
