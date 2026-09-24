// Higgsfield adapter.
//
//   auth   Authorization: Key <HIGGSFIELD_API_KEY_ID>:<HIGGSFIELD_API_KEY_SECRET>
//   base   https://api.higgsfield.ai
//   submit POST /bytedance/seedance/v1/pro/fast/image-to-video   (their Seedance proxy)
//          POST /higgsfield-ai/dop/turbo                          (DoP turbo)
//          POST /higgsfiled/genjutsu/motion-transfer/v1.0       (approved presenter input only)
//       -> { request_id, status_url, cancel_url }
//   poll   GET  {status_url} -> status ∈ queued | in_progress | completed | failed | nsfw | canceled
//
// THREE things about this vendor are load-bearing:
//
//  1. `nsfw` IS ITS OWN TERMINAL STATE. It is not a failure to retry and it is
//     not an outage — it is a refusal about the customer's own photo. It maps to
//     error_class "nsfw", which the chain loop rethrows instead of failing over:
//     asking a second vendor to generate what the first one refused is exactly
//     the behaviour a fair-housing / content review would hang us for.
//
//  2. Where supported, enhance_prompt IS ALWAYS false. Genjutsu has a closed
//     schema with no enhancement parameter; send its reviewed prompt verbatim.
//     Their prompt rewriter is unreviewable, and
//     every prompt we send has already been through the fair-housing guardrails.
//     A rewriter that re-adds "family home in a great school district" downstream
//     of the gate would defeat the gate.
//
//  3. THEY 400 AT FOUR CONCURRENT JOBS and publish no Retry-After, so we
//     self-limit to three with an in-process semaphore instead of discovering it
//     under load.
//
// Higgsfield media expires after 7 DAYS — persist() before reporting success.

import type { RouteStep } from "../router.ts";
import type { DoneState, ErrorClass, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  Semaphore,
  classifyStatus,
  fetchJson,
  persistResult,
  publicImageUrlFor,
  requireHost,
  snippet,
} from "./common.ts";

const PROVIDER = "higgsfield";
const HF_BASE = "https://api.higgsfield.ai";
const HF_HOSTS = ["api.higgsfield.ai", ".higgsfield.ai"] as const;

/** They 400 at 4 concurrent jobs with no Retry-After. Three, per isolate. */
export const HF_MAX_CONCURRENCY = 3;
const gate = new Semaphore(HF_MAX_CONCURRENCY);

function hfHeaders(): Record<string, string> {
  const id = Deno.env.get("HIGGSFIELD_API_KEY_ID")?.trim();
  const secret = Deno.env.get("HIGGSFIELD_API_KEY_SECRET")?.trim();
  if (!id || !secret) {
    throw new ProviderError(
      PROVIDER,
      "upstream",
      "HIGGSFIELD_API_KEY_ID / HIGGSFIELD_API_KEY_SECRET function secrets are not set",
    );
  }
  return { "Authorization": `Key ${id}:${secret}`, "Content-Type": "application/json" };
}

// ── Motion presets ───────────────────────────────────────────────────────────
//
// DoP motions are UUIDs, not names. The real map comes from GET /v1/motions
// (auth-gated) and is cached per isolate. The fallback below exists so a
// motions-endpoint outage degrades to a NAMED error instead of a wrong motion:
// the uuids are deliberately null. THEY MUST BE FETCHED, NEVER INVENTED — a
// guessed uuid is either a 404 or, worse, somebody else's camera move.
//
// TODO(ADAPT): fill these in from a real `GET /v1/motions` response once the
// Higgsfield keys exist, and keep them here as the offline fallback.
export const HF_MOTION_FALLBACK: Record<string, string | null> = {
  crane_down: null,
  crane_up: null,
  orbit: null,
  dolly_in: null,
  pull_back: null,
  aerial_pullback: null,
};

let motionCache: Record<string, string> | null = null;

/** name → uuid, fetched once per isolate. Never throws; falls back to the map. */
export async function motionMap(): Promise<Record<string, string>> {
  if (motionCache) return motionCache;
  try {
    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${HF_BASE}/v1/motions`,
      { method: "GET", headers: hfHeaders() },
      BUDGETS.pollMs,
    );
    const list = Array.isArray(data) ? data : Array.isArray(data.motions) ? data.motions : Array.isArray(data.items) ? data.items : [];
    const map: Record<string, string> = {};
    for (const raw of list as unknown[]) {
      if (!raw || typeof raw !== "object") continue;
      const o = raw as Record<string, unknown>;
      const id = String(o.id ?? o.uuid ?? "").trim();
      const name = String(o.name ?? o.slug ?? o.key ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
      if (id && name) map[name] = id;
    }
    if (Object.keys(map).length > 0) motionCache = map;
    return motionCache ?? {};
  } catch (e) {
    // A motions outage must not take the adapter down — the caller either has a
    // motion that resolves from the fallback map or gets a named refusal.
    console.warn("higgsfield: GET /v1/motions unavailable:", snippet(e instanceof Error ? e.message : e, 120));
    return {};
  }
}

/** Resolve a motion NAME to its uuid, or refuse. Never guesses. */
export async function motionId(name: string): Promise<string> {
  const key = name.trim().toLowerCase().replace(/[\s-]+/g, "_");
  const fetched = await motionMap();
  const id = fetched[key] ?? HF_MOTION_FALLBACK[key] ?? null;
  if (!id) {
    throw new ProviderError(
      PROVIDER,
      "validation",
      `higgsfield: motion "${key}" has no known uuid (GET /v1/motions must supply it — uuids are never invented)`,
    );
  }
  return id;
}

// ── Request shapes ───────────────────────────────────────────────────────────

// The spelling `higgsfiled` is intentional in the official API, verified
// 2026-09-24: https://docs.higgsfield.ai/docs/models/genjutsu/motion-transfer.md
export const HF_MOTION_TRANSFER_MODEL = "higgsfiled/genjutsu/motion-transfer/v1.0";
export const HF_MOTION_TRANSFER_TASK = "video.agent_presenter";

/** Server-resolved, approved assets, never the client's raw request body.
 * The caller must check ownership, active consent, reference approval, media
 * metadata, reviewed prompt and the enterprise/provider activation gates first.
 * This interface and its process-local brand are not authorization themselves.
 */
export interface HfMotionTransferInput {
  performanceVideoUrl: string;
  performanceDurationSeconds: number;
  approvedCharacterImageUrls: readonly string[];
  reviewedPrompt: string;
  resolution?: "720p" | "480p";
}

type MotionTransferPayload = {
  prompt: string;
  video_url: string;
  image_urls: readonly string[];
  resolution: "720p" | "480p";
};

// No marker a browser can forge in extra/JSON. Store an immutable snapshot so
// later mutation cannot replace the previously approved references or prompt.
const motionTransferInputs = new WeakMap<GenerateInput, Readonly<MotionTransferPayload>>();

function motionTransferRequire(condition: boolean, message: string): asserts condition {
  if (!condition) throw new ProviderError(PROVIDER, "validation", `higgsfield motion transfer: ${message}`);
}

function motionTransferUrl(value: unknown, label: string): string {
  motionTransferRequire(typeof value === "string" && value.length > 0 && value.length <= 2083 &&
    value === value.trim() && !/[\s\\]/u.test(value) &&
    ![...value].some((char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127),
    `${label} must be an HTTPS URL of at most 2083 characters`);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ProviderError(PROVIDER, "validation", `higgsfield motion transfer: ${label} is not a valid HTTPS URL`);
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  motionTransferRequire(url.protocol === "https:" && !url.username && !url.password && !url.hash &&
    !url.port && host.includes(".") && !host.includes(":") && !/^\d+(?:\.\d+)*$/.test(host) &&
    !["localhost", "local", "internal", "test", "invalid"].some((suffix) => host === suffix || host.endsWith(`.${suffix}`)),
    `${label} must use a public HTTPS host without credentials, fragments or a custom port`);
  return value; // Preserve the exact signed URL; never log or normalize it.
}

/** Construct only after server-side approval checks; performs no I/O.
 * Rendprop refuses >30s rather than silently accepting the vendor's truncation.
 * Fractional measured durations are valid and are never rounded or clamped.
 */
export function createHfMotionTransferInput(approved: HfMotionTransferInput): GenerateInput {
  motionTransferRequire(approved !== null && typeof approved === "object" && !Array.isArray(approved),
    "approved server input is required");
  const allowed = new Set(["performanceVideoUrl", "performanceDurationSeconds", "approvedCharacterImageUrls", "reviewedPrompt", "resolution"]);
  motionTransferRequire(Object.keys(approved).every((key) => allowed.has(key)), "unsupported input field");
  const seconds = approved.performanceDurationSeconds;
  motionTransferRequire(typeof seconds === "number" && Number.isFinite(seconds) && seconds >= 4 && seconds <= 30,
    "verified performance video duration must be 4–30 seconds");
  motionTransferRequire(typeof approved.reviewedPrompt === "string" && [...approved.reviewedPrompt].length <= 10_000,
    "reviewed prompt must be a string of at most 10000 characters");
  const resolution = approved.resolution === undefined ? "720p" : approved.resolution;
  motionTransferRequire(resolution === "720p" || resolution === "480p", "resolution must be 720p or 480p");
  motionTransferRequire(Array.isArray(approved.approvedCharacterImageUrls) &&
    approved.approvedCharacterImageUrls.length >= 1 && approved.approvedCharacterImageUrls.length <= 8,
    "1–8 approved character image references are required");
  const videoUrl = motionTransferUrl(approved.performanceVideoUrl, "performance video");
  const imageUrls = Array.from(approved.approvedCharacterImageUrls, (url) => motionTransferUrl(url, "character reference"));
  motionTransferRequire(imageUrls.every((url) => url !== videoUrl), "performance video and character image references must be separate assets");
  const input: GenerateInput = Object.freeze({
    task: HF_MOTION_TRANSFER_TASK,
    prompt: approved.reviewedPrompt,
    video_url: videoUrl,
    seconds,
  });
  motionTransferInputs.set(input, Object.freeze({
    prompt: approved.reviewedPrompt,
    video_url: videoUrl,
    image_urls: Object.freeze(imageUrls),
    resolution,
  }));
  return input;
}

export interface HfMotionTransferEstimate {
  credits: string;
  usd: string;
  ceilingCents: number;
}

// A parser bound, not an approved spending budget. The server caller must
// separately enforce its much smaller per-job and account limits.
export const HF_MAX_ESTIMATE_CENTS = 1_000_000;

function estimateDecimal(value: unknown, name: string): string {
  if (typeof value !== "string" || !/^(?:0|[1-9]\d{0,8})(?:\.\d{1,9})?$/.test(value)) {
    throw new ProviderError(PROVIDER, "upstream", `higgsfield estimate has an invalid ${name} amount`);
  }
  return value;
}

/** Account-specific quote only; does not submit a generation. Never retries.
 * The official billing docs prescribe /estimate/{model_slug} with the same
 * parameters. No price is inferred from unrelated example models or credits.
 */
export async function estimateHfMotionTransfer(input: GenerateInput): Promise<HfMotionTransferEstimate> {
  const approved = motionTransferInputs.get(input);
  motionTransferRequire(input.task === HF_MOTION_TRANSFER_TASK && !!approved,
    "estimate requires approved server input from createHfMotionTransferInput");
  const data = await motionRequest(
    `${HF_BASE}/estimate/${HF_MOTION_TRANSFER_MODEL}`,
    { method: "POST", body: JSON.stringify(approved) },
    BUDGETS.submitMs,
  );
  const credits = estimateDecimal(data?.credits, "credits");
  const usd = estimateDecimal(data?.usd, "USD");
  const [whole, fraction = ""] = usd.split(".");
  const scale = 10n ** BigInt(fraction.length);
  const numerator = BigInt(whole) * scale + BigInt(fraction || "0");
  const cents = (numerator * 100n + scale - 1n) / scale;
  if (cents > BigInt(HF_MAX_ESTIMATE_CENTS)) {
    throw new ProviderError(PROVIDER, "upstream", "higgsfield estimate exceeds the supported quote bound");
  }
  return { credits, usd, ceilingCents: Number(cents) };
}

export interface HfMotionTransferRef {
  request_id: string;
  status_url: string;
  cancel_url: string;
}
/** Validate references on every read from the private ledger. Credentials are
 * never sent to response-selected hosts or redirects. This is not a client API. */
export function readHfMotionTransferRef(value: unknown): HfMotionTransferRef {
  const row = value as Record<string, unknown> | null;
  motionTransferRequire(!!row && typeof row === "object" && !Array.isArray(row), "request reference is missing");
  const request_id = row.request_id;
  motionTransferRequire(typeof request_id === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request_id), "invalid request identity");
  const status_url = `${HF_BASE}/requests/${request_id}/status`;
  const cancel_url = `${HF_BASE}/requests/${request_id}/cancel`;
  motionTransferRequire(row.status_url === status_url && row.cancel_url === cancel_url, "request URLs must match the exact provider identity");
  return { request_id, status_url, cancel_url };
}

async function motionRequest(url: string, init: RequestInit, timeout: number): Promise<Record<string, unknown>> {
  const response = await fetch(url, { ...init, headers: hfHeaders(), redirect: "error", signal: AbortSignal.timeout(timeout) });
  if (!response.ok) {
    await response.body?.cancel();
    // Never include vendor bodies: they can echo signed private media URLs.
    throw new ProviderError(PROVIDER, classifyStatus(response.status), `higgsfield HTTP ${response.status}`, response.status);
  }
  const reader = response.body?.getReader();
  motionTransferRequire(!!reader, "provider response is empty");
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      motionTransferRequire(size <= 64 * 1024, "provider response exceeds the supported limit");
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let data: unknown;
  try { data = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new ProviderError(PROVIDER, "upstream", "Invalid higgsfield response"); }
  motionTransferRequire(!!data && typeof data === "object" && !Array.isArray(data), "invalid provider response");
  return data as Record<string, unknown>;
}

/** One POST only. Any transport/parse ambiguity must retain the caller's hold. */
export async function submitHfMotionTransfer(input: GenerateInput): Promise<HfMotionTransferRef> {
  const approved = motionTransferInputs.get(input);
  motionTransferRequire(input.task === HF_MOTION_TRANSFER_TASK && !!approved, "submit requires approved server input");
  const data = await motionRequest(`${HF_BASE}/${HF_MOTION_TRANSFER_MODEL}`, { method: "POST", body: JSON.stringify(approved) }, BUDGETS.submitMs);
  // Retain a confirmed identity even if a fast job already left the queue.
  // Polling determines the lifecycle; discarding these refs creates uncertainty.
  return readHfMotionTransferRef(data);
}

export type HfMotionTransferStatus = { status: "queued" | "in_progress" | "failed" | "nsfw" | "canceled" } | { status: "completed"; video_url: string };
export async function pollHfMotionTransfer(value: HfMotionTransferRef): Promise<HfMotionTransferStatus> {
  const ref = readHfMotionTransferRef(value);
  const data = await motionRequest(ref.status_url, { method: "GET" }, BUDGETS.pollMs);
  motionTransferRequire(data.request_id === ref.request_id, "status identity does not match the retained request");
  const status = data.status;
  if (status === "completed") {
    const video = data.video as { url?: unknown } | undefined;
    return { status, video_url: motionTransferUrl(video?.url, "generated video") };
  }
  motionTransferRequire(status === "queued" || status === "in_progress" || status === "failed" || status === "nsfw" || status === "canceled", "unknown provider state");
  return { status };
}

/** Official queued cancellation returns 202 with no JSON. A 400 means it has
 * already started; it does not prove a refund and the caller must keep polling. */
export async function cancelHfMotionTransfer(value: HfMotionTransferRef): Promise<"accepted" | "already_started"> {
  const ref = readHfMotionTransferRef(value);
  const response = await fetch(ref.cancel_url, { method: "POST", headers: hfHeaders(), redirect: "error", signal: AbortSignal.timeout(BUDGETS.pollMs) });
  await response.body?.cancel();
  if (response.status === 202) return "accepted";
  if (response.status === 400) return "already_started";
  throw new ProviderError(PROVIDER, classifyStatus(response.status), `higgsfield cancellation HTTP ${response.status}`, response.status);
}

type HfPath = { path: string; kind: "seedance" | "dop" | "motion_transfer" };

export function hfEndpoint(model: string): HfPath {
  const m = model.trim().replace(/^\/+/, "");
  if (m === HF_MOTION_TRANSFER_MODEL) return { path: `/${HF_MOTION_TRANSFER_MODEL}`, kind: "motion_transfer" };
  if (m.includes("genjutsu")) {
    throw new ProviderError(PROVIDER, "validation", "higgsfield: unsupported Genjutsu endpoint");
  }
  if (m.includes("dop/turbo")) return { path: "/higgsfield-ai/dop/turbo", kind: "dop" };
  if (m.includes("seedance")) return { path: "/bytedance/seedance/v1/pro/fast/image-to-video", kind: "seedance" };
  throw new ProviderError(PROVIDER, "validation", `higgsfield: no endpoint is defined for model "${model}"`);
}

/** duration is 2–12 s on the Seedance proxy. */
function clampDuration(seconds: number | undefined, dflt: number): number {
  const n = Math.round(Number(seconds ?? dflt));
  if (!Number.isFinite(n)) return dflt;
  return Math.min(12, Math.max(2, n));
}

export async function hfInput(step: RouteStep, input: GenerateInput): Promise<Record<string, unknown>> {
  const { kind } = hfEndpoint(step.model);
  if (kind === "motion_transfer") {
    const approved = motionTransferInputs.get(input);
    motionTransferRequire(step.task === HF_MOTION_TRANSFER_TASK && input.task === HF_MOTION_TRANSFER_TASK && !!approved,
      "requires approved server input from createHfMotionTransferInput");
    // Exact closed vendor schema: no duration/aspect/enhance_prompt or extra.
    return { ...approved, image_urls: [...approved.image_urls] };
  }
  const imageUrl = await publicImageUrlFor(input, PROVIDER);

  if (kind === "dop") {
    const extra = input.extra ?? {};
    const motionName = String(extra.motion ?? "pull_back");
    const strengthRaw = Number(extra.motion_strength ?? 0.7);
    const strength = Number.isFinite(strengthRaw) ? Math.min(1, Math.max(0, strengthRaw)) : 0.7;
    return {
      prompt: input.prompt,
      image_url: imageUrl,
      motions: [{ id: await motionId(motionName), strength }],
      enhance_prompt: false, // ALWAYS. Their rewriter is downstream of our fair-housing gate.
      seed: Number.isFinite(Number(extra.seed)) ? Number(extra.seed) : Math.floor(Math.random() * 1_000_000),
    };
  }

  return {
    prompt: input.prompt,
    image_url: imageUrl,
    duration: clampDuration(input.seconds, 5),
    resolution: input.resolution ?? "1080p",
    aspect_ratio: input.aspect ?? "16:9",
    enhance_prompt: false, // ALWAYS — same reason.
  };
}

// ── Adapter ──────────────────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
function extractResult(body: any): { url: string; mime: string } | null {
  const candidates = [
    body?.results?.raw,
    body?.results?.min,
    Array.isArray(body?.results) ? body.results[0] : null,
    body?.result,
    body?.output,
    body?.video,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && /^https?:\/\//i.test(c)) return { url: c, mime: "video/mp4" };
    if (c && typeof c === "object" && typeof c.url === "string") {
      const type = String(c.type ?? c.content_type ?? "").toLowerCase();
      return { url: c.url, mime: type.includes("image") ? "image/png" : "video/mp4" };
    }
  }
  if (typeof body?.video_url === "string") return { url: body.video_url, mime: "video/mp4" };
  return null;
}

function classifyHf(status: number, body: unknown): ErrorClass {
  if (/nsfw/i.test(snippet(body, 200))) return "nsfw";
  return classifyStatus(status);
}

export const higgsfieldAdapter: ProviderAdapter = {
  key: PROVIDER,

  submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    return gate.run(async () => {
      const { path } = hfEndpoint(step.model);
      const body = await hfInput(step, input);
      const data = await fetchJson<Record<string, unknown>>(
        PROVIDER,
        `${HF_BASE}${path}`,
        { method: "POST", headers: hfHeaders(), body: JSON.stringify(body) },
        BUDGETS.submitMs,
        classifyHf,
      );
      const requestId = String(data.request_id ?? data.id ?? "");
      const statusUrl = typeof data.status_url === "string" ? data.status_url : "";
      if (!requestId || !statusUrl) {
        throw new ProviderError(PROVIDER, "upstream", `Unexpected higgsfield submit response: ${snippet(data, 300)}`);
      }
      return {
        provider: PROVIDER,
        model: step.model,
        id: requestId,
        poll_url: requireHost(statusUrl, HF_HOSTS, PROVIDER),
        submitted_at: new Date().toISOString(),
      };
    });
  },

  async poll(ref: JobRef): Promise<JobState> {
    if (!ref.poll_url) return { status: "failed", error_class: "other", message: "higgsfield job has no status URL" };
    const url = requireHost(ref.poll_url, HF_HOSTS, PROVIDER);
    const body = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      url,
      { method: "GET", headers: hfHeaders() },
      BUDGETS.pollMs,
      classifyHf,
    );

    const status = String(body.status ?? "").toLowerCase();
    switch (status) {
      case "queued":
        return { status: "queued" };
      case "in_progress":
        return { status: "running" };
      case "nsfw":
        // Terminal and its own class: never failed over to another vendor.
        return {
          status: "failed",
          error_class: "nsfw",
          message: "Higgsfield refused this generation as NSFW",
        };
      case "canceled":
        return { status: "failed", error_class: "other", message: "Higgsfield job was canceled" };
      case "failed":
        return {
          status: "failed",
          error_class: "upstream",
          message: snippet(body.error ?? body.message ?? "Higgsfield reported a failed generation", 300),
        };
      case "completed": {
        const out = extractResult(body);
        if (!out) {
          return { status: "failed", error_class: "upstream", message: `Higgsfield completed with no media url: ${snippet(body)}` };
        }
        return {
          status: "done",
          result_url: out.url,
          mime: out.mime,
          // Higgsfield deletes media after 7 days: persist() before success.
          meta: { request_id: ref.id, expires_in_days: 7 },
        };
      }
      default:
        return { status: "queued" };
    }
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
