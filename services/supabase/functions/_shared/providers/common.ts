// Shared runtime for every provider adapter: time budgets, the error class the
// router's `error_class` is derived from, SSRF-safe fetching, an in-process
// semaphore, and the R2 side of persist().
//
// Nothing in here ever logs a credential or a signed URL. Vendor bodies are
// truncated before they reach a log line, and presigned URLs are used and
// dropped — they are never returned, logged, or put in a JobRef.

import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";
import { HttpError } from "../http.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS, headObject, presignPut, publicR2Url } from "../r2.ts";
import type { DoneState, ErrorClass, JobRef, JobState, ProviderAdapter } from "./types.ts";

// ── Time budgets (hard rule: every adapter call is bounded) ───────────────────

export const BUDGETS = {
  /** One submit POST. */
  submitMs: 30_000,
  /** One poll GET. */
  pollMs: 20_000,
  /** Whole poll loop for a VIDEO job. */
  totalVideoMs: 6 * 60_000,
  /** Whole poll loop for an IMAGE job. */
  totalImageMs: 2 * 60_000,
  /** Downloading a finished result out of the vendor, and the R2 PUT. */
  transferMs: 120_000,
  /** Poll cadence: starts here, backs off ×1.5 to pollMaxIntervalMs. */
  pollIntervalMs: 2_000,
  pollMaxIntervalMs: 8_000,
} as const;

/** Refuse to buffer a result larger than this (edge functions have ~150 MB). */
export const MAX_PERSIST_BYTES = 100 * 1024 * 1024;

// ── Errors ───────────────────────────────────────────────────────────────────

/**
 * A provider failure that carries the router's `error_class`. The chain loop in
 * ai-photo / ai-video reads it to decide: `validation` and `nsfw` are the
 * caller's problem and rethrow immediately; everything else fails over to the
 * next step.
 */
export class ProviderError extends Error {
  readonly error_class: ErrorClass;
  readonly provider: string;
  readonly status?: number;
  constructor(provider: string, error_class: ErrorClass, message: string, status?: number) {
    super(message);
    this.name = "ProviderError";
    this.provider = provider;
    this.error_class = error_class;
    this.status = status;
  }
  /** The HTTP status this failure should surface as when the chain is exhausted. */
  get httpStatus(): number {
    switch (this.error_class) {
      case "validation":
        return 400;
      case "nsfw":
        return 400;
      case "rate_limit":
        return 429;
      default:
        return 502;
    }
  }
}

/** Default HTTP-status → error_class mapping. Adapters override per vendor. */
export function classifyStatus(status: number): ErrorClass {
  if (status === 429) return "rate_limit";
  if (status === 408 || status === 504) return "timeout";
  if (status === 400 || status === 402 || status === 413 || status === 422) return "validation";
  if (status >= 500) return "upstream";
  // 401/403 is OUR misconfiguration, never the caller's session — `upstream`
  // keeps the app from signing the user out (same rule as ai-voice).
  if (status === 401 || status === 403) return "upstream";
  return "other";
}

/** error_class for anything thrown inside a chain step. */
export function errorClassOf(err: unknown): ErrorClass {
  if (err instanceof ProviderError) return err.error_class;
  if (err instanceof HttpError) {
    if (err.code === "unsupported_edit" || err.code === "validation" || err.code === "payload_too_large") {
      return "validation";
    }
    if (err.code === "rate_limited") return "rate_limit";
    if (err.status === 408 || err.status === 504) return "timeout";
    if (err.status >= 500) return "upstream";
    return "other";
  }
  if (err instanceof DOMException && err.name === "TimeoutError") return "timeout";
  if (err instanceof Error && /timed out|aborted/i.test(err.message)) return "timeout";
  return "other";
}

/**
 * Any URL carrying signing material. Vendors echo the input URL back in their
 * error bodies, and those bodies end up in our error messages — so a presigned
 * R2 GET we handed Kie to fetch a customer photo could otherwise be returned to
 * a caller or written to a log line. Redacted at the one choke point every
 * vendor body passes through.
 */
const SIGNED_URL_RE =
  /https?:\/\/[^\s"'<>]*(?:X-Amz-[A-Za-z0-9-]+=|[?&](?:signature|token|sig|key|expires)=)[^\s"'<>]*/gi;

export function redactSignedUrls(s: string): string {
  return s.replace(SIGNED_URL_RE, "[redacted-signed-url]");
}

/** Bound a vendor body before it reaches a log line or an error message. */
export function snippet(v: unknown, max = 300): string {
  let s: string;
  try {
    s = typeof v === "string" ? v : JSON.stringify(v);
  } catch {
    s = String(v);
  }
  return redactSignedUrls(s ?? "").slice(0, max);
}

// ── Fetch ────────────────────────────────────────────────────────────────────

/**
 * SSRF guard. Every URL an adapter fetches with OUR credentials — including a
 * poll_url that came back through a client round-trip — must be https on a host
 * the adapter itself names. A JobRef is client-visible, so this is the only
 * thing standing between a forged poll_url and our vendor keys.
 */
export function requireHost(raw: string, allowed: readonly string[], provider: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ProviderError(provider, "validation", `${provider}: not a valid URL`);
  }
  const host = url.hostname.toLowerCase();
  const ok = url.protocol === "https:" &&
    allowed.some((a) => (a.startsWith(".") ? host.endsWith(a) : host === a));
  if (!ok) {
    throw new ProviderError(provider, "validation", `${provider}: refusing to call a non-${provider} host`);
  }
  return url.toString();
}

/** fetch() with a hard deadline. Never retries. */
export async function fetchBounded(
  provider: string,
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (e) {
    const name = e instanceof DOMException ? e.name : "";
    if (name === "TimeoutError" || name === "AbortError") {
      throw new ProviderError(provider, "timeout", `${provider} did not answer within ${Math.round(timeoutMs / 1000)}s`);
    }
    throw new ProviderError(provider, "upstream", `${provider} request failed: ${snippet(e instanceof Error ? e.message : e, 120)}`);
  }
}

/** Bounded fetch → parsed JSON. Non-2xx becomes a ProviderError with a class. */
export async function fetchJson<T = Record<string, unknown>>(
  provider: string,
  url: string,
  init: RequestInit,
  timeoutMs: number,
  classify: (status: number, body: unknown) => ErrorClass = classifyStatus,
): Promise<T> {
  const res = await fetchBounded(provider, url, init, timeoutMs);
  const text = await res.text().catch(() => "");
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!res.ok) {
    throw new ProviderError(
      provider,
      classify(res.status, body),
      `${provider} HTTP ${res.status}: ${snippet(body)}`,
      res.status,
    );
  }
  return (body ?? {}) as T;
}

// ── Concurrency ──────────────────────────────────────────────────────────────

/**
 * In-process semaphore. Higgsfield returns a bare 400 at the 4th concurrent job
 * and publishes no Retry-After, so we self-limit rather than discover it.
 * Per-isolate only — it bounds one function instance, not the fleet.
 */
export class Semaphore {
  #max: number;
  #active = 0;
  #waiting: Array<() => void> = [];
  constructor(max: number) {
    this.#max = Math.max(1, max);
  }
  async run<T>(fn: () => Promise<T>): Promise<T> {
    if (this.#active >= this.#max) {
      await new Promise<void>((resolve) => this.#waiting.push(resolve));
    }
    this.#active++;
    try {
      return await fn();
    } finally {
      this.#active--;
      const next = this.#waiting.shift();
      if (next) next();
    }
  }
  get active(): number {
    return this.#active;
  }
}

// ── Synchronous providers ────────────────────────────────────────────────────

/**
 * Gemini, OpenAI images/audio and Anthropic answer inside the submit call.
 * They stash the finished state here and poll() hands it back once, so a
 * synchronous vendor still satisfies the submit/poll/persist interface.
 * Per-isolate and single-read: nothing accumulates.
 */
const inline = new Map<string, JobState>();

export function stashInline(id: string, state: JobState): void {
  rememberBounded(inline, id, state, 64);
}

export function takeInline(provider: string, id: string): JobState {
  const s = inline.get(id);
  inline.delete(id);
  if (!s) {
    return {
      status: "failed",
      error_class: "other",
      message: `${provider}: this result was produced inline and has already been read`,
    };
  }
  return s;
}

/**
 * Insert into a per-isolate cache, evicting the oldest entry past `max`.
 * These maps live for the life of a warm isolate; without a ceiling a
 * long-lived instance would accumulate one entry per job it ever submitted.
 */
export function rememberBounded<K, V>(map: Map<K, V>, key: K, value: V, max = 200): void {
  map.set(key, value);
  while (map.size > max) {
    const oldest = map.keys().next();
    if (oldest.done) break;
    map.delete(oldest.value);
  }
}

export function newJobId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID()}`;
}

// ── Poll loop ────────────────────────────────────────────────────────────────

/** Sleep, bounded. */
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Drive an adapter's poll() to a terminal state inside `budgetMs`. Fixed
 * backoff, no unbounded retry: when the budget runs out the job is reported as
 * a `timeout` failure and the caller fails over to the next step.
 */
export async function awaitJob(
  adapter: ProviderAdapter,
  ref: JobRef,
  budgetMs: number,
): Promise<DoneState> {
  const deadline = Date.now() + budgetMs;
  let interval: number = BUDGETS.pollIntervalMs;
  let last: JobState = { status: "queued" };
  while (Date.now() < deadline) {
    last = await adapter.poll(ref);
    if (last.status === "done") return last;
    if (last.status === "failed") {
      throw new ProviderError(ref.provider, last.error_class, `${ref.provider}: ${last.message}`);
    }
    const left = deadline - Date.now();
    if (left <= 0) break;
    await sleep(Math.min(interval, left));
    interval = Math.min(Math.round(interval * 1.5), BUDGETS.pollMaxIntervalMs);
  }
  throw new ProviderError(
    ref.provider,
    "timeout",
    `${ref.provider} did not finish within ${Math.round(budgetMs / 1000)}s (last status: ${last.status})`,
  );
}

// ── R2 ───────────────────────────────────────────────────────────────────────

const trimmedEnv = (name: string): string | undefined => {
  const raw = Deno.env.get(name);
  if (raw === undefined) return undefined;
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
};

// Presigned GET has no home in _shared/r2.ts yet (that file is owned elsewhere
// this cycle); ai-voice carries the same twelve lines for the same reason.
const R2_ACCOUNT_ID = trimmedEnv("CLOUDFLARE_ACCOUNT_ID");
const R2_ACCESS_KEY_ID = trimmedEnv("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = trimmedEnv("R2_SECRET_ACCESS_KEY");

let _r2: AwsClient | null = null;
function r2Client(): AwsClient {
  if (_r2) return _r2;
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) {
    throw new HttpError(500, "Missing R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY", "internal");
  }
  _r2 = new AwsClient({
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  return _r2;
}

function r2Endpoint(): string {
  if (!R2_ACCOUNT_ID) throw new HttpError(500, "Missing env var: CLOUDFLARE_ACCOUNT_ID", "internal");
  return `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
}

const encodeKey = (key: string) => key.split("/").map(encodeURIComponent).join("/");

/** Presign a GET. The URL is short-lived, never logged and never persisted. */
export async function presignGet(bucket: string, key: string, expiresIn: number): Promise<string> {
  const url = new URL(`${r2Endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signed = await r2Client().sign(url.toString(), { method: "GET", aws: { signQuery: true } });
  return signed.url;
}

const EXT_BY_MIME: Record<string, string> = {
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "video/webm": "webm",
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "audio/mpeg": "mp3",
  "audio/wav": "wav",
};

export function extFor(mime: string): string {
  return EXT_BY_MIME[mime.split(";")[0].trim().toLowerCase()] ?? "bin";
}

/** Deterministic-ish R2 key for a routed generation. Never contains user text. */
export function routedR2Key(orgId: string, task: string, mime: string): string {
  const safeTask = task.replace(/[^a-z0-9._-]/gi, "_");
  return `ai-router/${orgId}/${safeTask}/${crypto.randomUUID()}.${extFor(mime)}`;
}

/** base64 → bytes. Typed on a real ArrayBuffer so it is a valid BodyInit/BlobPart. */
export function b64Bytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const bytes = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

/** bytes → base64, chunked so a large image cannot blow the call stack. */
export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  return btoa(bin);
}

/** Read a `data:` URL into bytes + mime, or null when it is not one. */
export function decodeDataUrl(url: string): { bytes: Uint8Array<ArrayBuffer>; mime: string } | null {
  const m = /^data:([^;,]+);base64,([\s\S]+)$/.exec(url);
  if (!m) return null;
  return { bytes: b64Bytes(m[2]), mime: m[1] };
}

/** PUT bytes at an R2 key through a short-lived presigned URL. */
export async function putBytes(
  bucket: string,
  key: string,
  bytes: BodyInit,
  mime: string,
): Promise<{ key: string; bytes: number }> {
  const putUrl = await presignPut({ bucket, key, expiresIn: 600, contentType: mime });
  const put = await fetchBounded("r2", putUrl, {
    method: "PUT",
    headers: { "content-type": mime },
    body: bytes,
  }, BUDGETS.transferMs);
  if (!put.ok) {
    // The presigned URL is a credential — never in the message.
    const detail = await put.text().catch(() => "");
    throw new ProviderError("r2", "upstream", `Storing the result failed (R2 ${put.status}): ${snippet(detail, 160)}`);
  }
  const head = await headObject(bucket, key);
  if (!head.exists) throw new ProviderError("r2", "upstream", "Stored object is missing from R2 after PUT");
  return { key, bytes: head.bytes ?? 0 };
}

/**
 * The persist() body every adapter shares: pull the vendor's result and write
 * it into OUR renders bucket. Handles `data:` results (inline b64 from Gemini /
 * OpenAI) without a network hop.
 */
export async function persistResult(
  provider: string,
  state: DoneState,
  r2Key: string,
): Promise<{ key: string; bytes: number }> {
  const inlineData = decodeDataUrl(state.result_url);
  if (inlineData) {
    return await putBytes(R2_BUCKET_RENDERS, r2Key, inlineData.bytes, inlineData.mime || state.mime);
  }
  const res = await fetchBounded(provider, state.result_url, { method: "GET" }, BUDGETS.transferMs);
  if (!res.ok) {
    throw new ProviderError(provider, "upstream", `${provider} result download failed (HTTP ${res.status})`);
  }
  const declared = Number(res.headers.get("content-length") ?? "0");
  if (declared > MAX_PERSIST_BYTES) {
    throw new ProviderError(
      provider,
      "upstream",
      `${provider} result is ${Math.round(declared / 1e6)} MB, over the ${Math.round(MAX_PERSIST_BYTES / 1e6)} MB edge limit`,
    );
  }
  const buf = await res.arrayBuffer();
  if (buf.byteLength === 0) throw new ProviderError(provider, "upstream", `${provider} returned an empty result`);
  if (buf.byteLength > MAX_PERSIST_BYTES) {
    throw new ProviderError(provider, "upstream", `${provider} result exceeds the ${Math.round(MAX_PERSIST_BYTES / 1e6)} MB edge limit`);
  }
  const mime = res.headers.get("content-type")?.split(";")[0].trim() || state.mime;
  return await putBytes(R2_BUCKET_RENDERS, r2Key, buf, mime);
}

/** Public https URL for a persisted key, or null when no public base is set. */
export function persistedUrl(key: string): string | null {
  return publicR2Url(key);
}

/**
 * Put a caller's inline image into OUR storage and hand back a short-lived
 * presigned GET. Used by vendors that will only fetch a public URL (Kie,
 * Higgsfield): customer media stays on our storage, never on a vendor's upload
 * host, and the link dies with the job.
 */
export async function stageInputImage(
  b64: string,
  mime: string,
  ttlSeconds = 900,
): Promise<{ key: string; url: string }> {
  const bytes = b64Bytes(b64);
  const key = `ai-router/input/${crypto.randomUUID()}.${extFor(mime)}`;
  await putBytes(R2_BUCKET_UPLOADS, key, bytes, mime);
  return { key, url: await presignGet(R2_BUCKET_UPLOADS, key, ttlSeconds) };
}

/**
 * The public image URL a vendor can actually fetch. Prefers a URL the caller
 * already has; falls back to staging inline base64 into our uploads bucket.
 */
export async function publicImageUrlFor(
  input: { image_url?: string; image_b64?: string; extra?: Record<string, unknown> },
  provider: string,
): Promise<string> {
  if (input.image_url && /^https:\/\//i.test(input.image_url)) return input.image_url;
  if (input.image_b64) {
    const mime = String(input.extra?.image_mime ?? "image/jpeg");
    const staged = await stageInputImage(input.image_b64, mime);
    return staged.url;
  }
  if (input.image_url?.startsWith("data:")) {
    const decoded = decodeDataUrl(input.image_url);
    if (decoded) {
      const b64 = input.image_url.split(",")[1] ?? "";
      const staged = await stageInputImage(b64, decoded.mime);
      return staged.url;
    }
  }
  throw new ProviderError(provider, "validation", `${provider} needs a public image URL and none could be built`);
}

/** Images are returned to the app inline; refuse anything absurd. */
export const MAX_INLINE_IMAGE_BYTES = 25 * 1024 * 1024;

/**
 * Make a done-state's bytes local ONCE.
 *
 * ai-photo answers with `image_b64` inline, and persist() must also write those
 * bytes to R2. Downloading a remote result twice (once to return, once to
 * store) is a wasted round trip on the user's critical path, so a remote result
 * is pulled here and handed back as a `data:` state — persist() then writes the
 * bytes already in hand. An inline result is returned untouched.
 */
export async function inlineImageResult(provider: string, state: DoneState): Promise<DoneState> {
  if (decodeDataUrl(state.result_url)) return state;
  const res = await fetchBounded(provider, state.result_url, { method: "GET" }, BUDGETS.transferMs);
  if (!res.ok) {
    throw new ProviderError(provider, "upstream", `${provider} image download failed (HTTP ${res.status})`);
  }
  const declared = Number(res.headers.get("content-length") ?? "0");
  if (declared > MAX_INLINE_IMAGE_BYTES) {
    throw new ProviderError(provider, "upstream", `${provider} returned an image over the inline size limit`);
  }
  const buf = new Uint8Array(await res.arrayBuffer());
  if (buf.byteLength === 0) throw new ProviderError(provider, "upstream", `${provider} returned an empty image`);
  if (buf.byteLength > MAX_INLINE_IMAGE_BYTES) {
    throw new ProviderError(provider, "upstream", `${provider} returned an image over the inline size limit`);
  }
  const mime = res.headers.get("content-type")?.split(";")[0].trim() || state.mime;
  const b64 = bytesToB64(buf);
  return {
    ...state,
    result_url: `data:${mime};base64,${b64}`,
    mime,
    meta: { ...(state.meta ?? {}), image_b64: b64 },
  };
}

/** The base64 payload of a done state whose result_url is inline data. */
export function inlineBase64(state: DoneState): string | null {
  const fromMeta = state.meta?.image_b64;
  if (typeof fromMeta === "string" && fromMeta.length > 0) return fromMeta;
  const m = /^data:[^;,]+;base64,([\s\S]+)$/.exec(state.result_url);
  return m ? m[1] : null;
}
