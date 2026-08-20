// HTTP utilities shared by every function: JSON responses, a typed error class,
// request-body parsing, path routing (Supabase strips nothing, so we strip the
// function name ourselves), a URL-safe slug generator, and a best-effort
// in-memory rate limiter for the public routes.

import { corsHeaders } from "./cors.ts";

/** An error that carries an HTTP status. Throw it anywhere; respondError maps it. */
export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
    this.name = "HttpError";
  }
}

/** Throw an HttpError unless `cond` is truthy. */
export function assert(cond: unknown, status: number, msg: string): asserts cond {
  if (!cond) throw new HttpError(status, msg);
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

/** Map any thrown value to a JSON error response. */
export function respondError(err: unknown): Response {
  if (err instanceof HttpError) {
    return json({ error: err.message }, err.status);
  }
  console.error("Unhandled error:", err);
  const message = err instanceof Error ? err.message : "Internal Server Error";
  return json({ error: message }, 500);
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

// ---------------------------------------------------------------------------
// Best-effort rate limiting for public routes (/leads, /beacon).
// NOTE: this is per-instance and resets on cold start — it blunts obvious
// abuse but is NOT a real limiter. TODO: back with Cloudflare Turnstile +
// a durable store (Upstash Redis / CF KV) before launch. See leads/beacon.
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

/** Best-effort client IP from proxy headers. */
export function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("cf-connecting-ip") ?? "unknown";
}
