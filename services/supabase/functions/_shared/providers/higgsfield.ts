// Higgsfield adapter.
//
//   auth   Authorization: Key <HIGGSFIELD_API_KEY_ID>:<HIGGSFIELD_API_KEY_SECRET>
//   base   https://api.higgsfield.ai
//   submit POST /bytedance/seedance/v1/pro/fast/image-to-video   (their Seedance proxy)
//          POST /higgsfield-ai/dop/turbo                          (DoP turbo)
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
//  2. enhance_prompt IS ALWAYS false. Their prompt rewriter is unreviewable, and
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

type HfPath = { path: string; kind: "seedance" | "dop" };

export function hfEndpoint(model: string): HfPath {
  const m = model.trim().replace(/^\/+/, "");
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
