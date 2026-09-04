// HTTP utilities shared by every function: JSON responses, a typed error class
// with a machine-readable code, request-body parsing, path routing (Supabase
// strips nothing, so we strip the function name ourselves), a URL-safe slug
// generator, and a best-effort in-memory rate limiter for the public routes.

import { corsHeaders } from "./cors.ts";

/**
 * Stable machine-readable error codes (wire contract B4). The iOS client keys
 * its UI on these — `plan_required` / `quota_exceeded` → "Upgrade plan",
 * `unauthorized` → sign-in prompt, `conflict` on /complete → treat as success,
 * `rate_limited` → "try again in a few minutes". Keep the set small and stable.
 */
export type ErrorCode =
  | "validation"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "plan_required"
  | "quota_exceeded"
  | "rate_limited"
  | "payload_too_large"
  // A prompt the FAIR-HOUSING guardrails refuse (people, pets, religious or
  // cultural objects, neighborhood/school claims — see _shared/fairhousing.ts).
  // 400, never auto-derived from a status: only thrown deliberately, so the app
  // can show the refusal differently from an ordinary validation error.
  | "unsupported_edit"
  | "upstream"
  | "internal";

/** Default code for a status when a throw site doesn't say otherwise. */
export function codeForStatus(status: number): ErrorCode {
  switch (status) {
    case 400:
    case 405:
    case 422:
      return "validation";
    case 401:
      return "unauthorized";
    case 402:
      return "plan_required";
    case 403:
      return "forbidden";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 413:
      return "payload_too_large";
    case 429:
      return "rate_limited";
    case 502:
    case 503:
    case 504:
      return "upstream";
    default:
      return status >= 500 ? "internal" : "validation";
  }
}

/**
 * An error that carries an HTTP status + a machine-readable code (+ optional
 * structured details such as {feature, used, cap, plan} for quota errors).
 * Throw it anywhere; respondError maps it to `{ error, code, ...details }`.
 */
export class HttpError extends Error {
  status: number;
  code: ErrorCode;
  details?: Record<string, unknown>;
  constructor(status: number, message: string, code?: ErrorCode, details?: Record<string, unknown>) {
    super(message);
    this.status = status;
    this.code = code ?? codeForStatus(status);
    this.details = details;
    this.name = "HttpError";
  }
}

/** Throw an HttpError unless `cond` is truthy. */
export function assert(cond: unknown, status: number, msg: string, code?: ErrorCode): asserts cond {
  if (!cond) throw new HttpError(status, msg, code);
}

/** JSON response with CORS headers attached. */
export function json(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

/**
 * Map any thrown value to the JSON error envelope `{ error, code, ...details }`.
 * `error` is human copy the app may show verbatim; `code` is what it branches on.
 */
export function respondError(err: unknown): Response {
  if (err instanceof HttpError) {
    return json({ ...(err.details ?? {}), error: err.message, code: err.code }, err.status);
  }
  console.error("Unhandled error:", err);
  const message = err instanceof Error ? err.message : "Internal Server Error";
  return json({ error: message, code: "internal" }, 500);
}

/** Parse a JSON request body, or throw a 400. */
export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}

/**
 * Return the path segments that belong to THIS function, stripping the
 * `/functions/v1/<name>` prefix that Supabase may or may not include.
 *
 *   hosted:  /functions/v1/renders/<id>/publish  -> ["<id>", "publish"]
 *   local:   /renders/<id>/publish               -> ["<id>", "publish"]
 */
export function pathSegments(req: Request, functionName: string): string[] {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  if (parts[0] === "functions") parts.shift();
  if (parts[0] === "v1") parts.shift();
  if (parts[0] === functionName) parts.shift();
  return parts;
}

// URL-safe (base64url) alphabet — 64 chars so `byte & 63` is unbiased.
const SLUG_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

/** Cryptographically-random, URL-safe id (nanoid-style). Default 12 chars. */
export function nanoid(size = 12): string {
  const bytes = crypto.getRandomValues(new Uint8Array(size));
  let out = "";
  for (let i = 0; i < size; i++) out += SLUG_ALPHABET[bytes[i] & 63];
  return out;
}

/** Round to 4 decimal places (cost_ledger columns are numeric(_,4)). */
export function round4(n: number): number {
  return Math.round(n * 1e4) / 1e4;
}

/**
 * Map an `RPnnn: message` exception raised by one of the SECURITY DEFINER RPCs
 * (create_render_job, publish_render, fail_render_job, set_render_chapters,
 * set_lead_status, log_job_cost) to an HttpError with the right status + code.
 * RP402 is a QUOTA when the RPC says a limit was reached, otherwise a plan
 * boundary; RP429 from create_render_job is the in-flight/burst guard.
 */
export function throwRpc(message: string | undefined): never {
  const msg = message ?? "request failed";
  const m = /RP(\d{3}):\s*([\s\S]*)/.exec(msg);
  if (!m) throw new HttpError(400, msg);
  const status = Number(m[1]);
  const text = m[2].trim() || msg;
  let code: ErrorCode | undefined;
  if (status === 402) code = /limit reached|ceiling reached/i.test(text) ? "quota_exceeded" : "plan_required";
  throw new HttpError(status, text, code);
}

// ---------------------------------------------------------------------------
// Best-effort rate limiting for public routes (/leads, /beacon).
// NOTE: this is per-instance and resets on cold start — the durable limiter
// in _shared/ratelimit.ts (Postgres bump_rate) is the primary; this is its
// fallback.
// ---------------------------------------------------------------------------
const buckets = new Map<string, { count: number; reset: number }>();

export function rateLimit(key: string, limit = 30, windowMs = 60_000): boolean {
  const now = Date.now();
  const b = buckets.get(key);
  if (!b || now > b.reset) {
    buckets.set(key, { count: 1, reset: now + windowMs });
    return true;
  }
  if (b.count >= limit) return false;
  b.count++;
  return true;
}

/** Client IP for rate limiting. cf-connecting-ip is set by Cloudflare itself
 * and can't be spoofed by the caller; x-forwarded-for is attacker-suppliable,
 * so it is only the fallback (audit: XFF-first let callers rotate limit keys). */
export function clientIp(req: Request): string {
  const cf = req.headers.get("cf-connecting-ip");
  if (cf) return cf.trim();
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return "unknown";
}
