// fal.ai adapter — the queue API the shipped product already runs on.
//
//   submit  POST https://queue.fal.run/{model}          -> { request_id, status_url, response_url }
//   poll    GET  {status_url}?logs=1                    -> IN_QUEUE | IN_PROGRESS | COMPLETED | FAILED
//   result  GET  {response_url}                         -> { video: { url } } | { images: [...] }
//
// THE PAYLOADS ARE THE SHIPPED ONES. falInput() reproduces, byte for byte
// (including key order), the object each legacy route sends today — that is what
// makes `ai_router.enabled = false` a no-op. providers_test.ts asserts it.
//
// One deliberate addition on every submit:
//   X-Fal-Object-Lifecycle-Preference: {"expiration_duration_seconds": 86400}
// fal keeps result objects indefinitely by default. These are photographs of
// other people's homes; 24 hours is enough for persist() to copy the asset into
// our R2 and is the difference between "a client's living room lives on a
// vendor's CDN forever" and "it doesn't".

import type { RouteStep } from "../router.ts";
import type { DoneState, ErrorClass, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  classifyStatus,
  fetchJson,
  persistResult,
  rememberBounded,
  requireHost,
  snippet,
} from "./common.ts";

const PROVIDER = "fal";
const FAL_QUEUE_BASE = "https://queue.fal.run";
const FAL_HOSTS = ["queue.fal.run", ".fal.run"] as const;

/** 24 h. Long enough for persist(); short enough that a missed persist expires. */
export const FAL_OBJECT_LIFECYCLE_HEADER = "X-Fal-Object-Lifecycle-Preference";
export const FAL_OBJECT_LIFECYCLE_VALUE = JSON.stringify({ expiration_duration_seconds: 86400 });

/** Vendor namespaces fal serves un-prefixed; everything else lives under fal-ai/. */
const PASSTHROUGH_NAMESPACES = ["fal-ai/", "bria/"];

/** Route rows may carry the short slug ("bytedance/seedance/..."); the queue
 *  wants the full endpoint path. Normalising here keeps the routing table
 *  readable without changing a single byte of what we send. */
export function falEndpoint(model: string): string {
  const m = model.trim().replace(/^\/+/, "");
  return PASSTHROUGH_NAMESPACES.some((p) => m.startsWith(p)) ? m : `fal-ai/${m}`;
}

function falKey(): string {
  const key = Deno.env.get("FAL_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "FAL_KEY function secret is not set");
  return key;
}

function falHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {
    "Authorization": `Key ${falKey()}`,
    "Content-Type": "application/json",
    ...extra,
  };
}

// ── Request shapes ───────────────────────────────────────────────────────────

const secondsOf = (input: GenerateInput, dflt: number) => {
  const n = Math.round(Number(input.seconds ?? dflt));
  return Number.isFinite(n) ? n : dflt;
};

/**
 * The exact JSON body for (model, task). Every branch below is a shipped
 * payload copied verbatim — same keys, same order, same types.
 */
export function falInput(step: RouteStep, input: GenerateInput): Record<string, unknown> {
  const model = falEndpoint(step.model);
  const extra = input.extra ?? {};

  // Seedance 1.0 Pro Fast image-to-video — the reel and the grounded aerial.
  if (model.endsWith("bytedance/seedance/v1/pro/fast/image-to-video")) {
    if (input.task === "video.aerial") {
      return {
        prompt: input.prompt,
        image_url: input.image_url,
        resolution: "1080p",
        duration: String(secondsOf(input, 6)), // Seedance takes duration as a string
        aspect_ratio: input.aspect,
        camera_fixed: false,
      };
    }
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      resolution: "1080p",
      duration: String(secondsOf(input, 5)), // Seedance takes duration as a string
    };
  }

  // Hailuo 02 standard i2v — the different-model failover for the reel. 768p,
  // 6 s ceiling: the row advertises that, and we clamp rather than 400.
  if (model.includes("hailuo")) {
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      duration: String(Math.min(6, secondsOf(input, 5))),
    };
  }

  // Veo 3.1 Fast image-to-video (different-model failover for the aerial).
  if (model.endsWith("veo3.1/fast/image-to-video")) {
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      duration: `${secondsOf(input, 6)}s`,
      resolution: input.resolution ?? "1080p",
      aspect_ratio: input.aspect,
      generate_audio: false,
    };
  }

  // Veo 3.1 Fast text-to-video — the ungrounded aerial.
  if (model.endsWith("veo3.1/fast")) {
    return {
      prompt: input.prompt,
      duration: `${secondsOf(input, 6)}s`,
      resolution: input.resolution ?? "1080p",
      aspect_ratio: input.aspect,
      generate_audio: false, // silent b-roll; the app scores it (and it's ~33% cheaper)
    };
  }

  // Topaz Video AI — drone glide. upscale_factor / target_fps are computed by
  // the caller from the SOURCE asset and arrive in `extra`.
  if (model.includes("topaz/upscale/video")) {
    const body: Record<string, unknown> = {
      video_url: input.video_url,
      model: "Proteus", // natural detail; interpolation gives the glide
      upscale_factor: extra.upscale_factor,
      H264_output: true,
    };
    if (extra.target_fps != null) body.target_fps = extra.target_fps;
    return body;
  }

  // Bria prompt-driven video eraser — declutter.
  if (model.includes("bria/video/erase")) {
    return {
      video_url: input.video_url,
      prompt: input.prompt,
      auto_trim: false, // never silently cut the video — process the full clip
      preserve_audio: true,
      output_container_and_codec: "mp4_h264",
    };
  }

  // FLUX.1 Fill — the only TRUE mask inpaint in the photo chain.
  if (model.includes("flux-pro/v1/fill")) {
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      mask_url: input.mask_url,
    };
  }

  // FLUX.1 Kontext — prompt-only photo edit.
  if (model.includes("flux-pro/kontext")) {
    return {
      prompt: input.prompt,
      image_url: input.image_url,
    };
  }

  throw new ProviderError(PROVIDER, "validation", `fal: no request shape is defined for model "${step.model}"`);
}

// ── Adapter ──────────────────────────────────────────────────────────────────

/** Submit ids as fal returned them, for the one invocation that submitted.
 *  Lets ai-video keep echoing fal's own status_url/response_url VERBATIM in the
 *  202 (the shipped app's contract) without a second round trip. */
const submitEcho = new Map<string, { request_id: string; status_url: string; response_url: string }>();

export function falSubmitEcho(requestId: string): { request_id: string; status_url: string; response_url: string } | null {
  return submitEcho.get(requestId) ?? null;
}

/** fal's response_url is the status_url without the trailing /status. */
export function falResponseUrl(statusUrl: string): string {
  return statusUrl.replace(/\/status(\?.*)?$/, "");
}

function classifyFal(status: number, body: unknown): ErrorClass {
  const text = snippet(body, 400).toLowerCase();
  if (/nsfw|safety|content policy/.test(text)) return "nsfw";
  if (status === 422) return "validation";
  return classifyStatus(status);
}

// deno-lint-ignore no-explicit-any
function extractResult(result: any): { url: string; mime: string; width?: number; height?: number; duration_s?: number } | null {
  const v = result?.video; // Topaz / Bria / Veo / Seedance: { video: { url } }
  if (typeof v === "string") return { url: v, mime: "video/mp4" };
  if (v && typeof v.url === "string") {
    return {
      url: v.url,
      mime: typeof v.content_type === "string" ? v.content_type : "video/mp4",
      width: typeof v.width === "number" ? v.width : undefined,
      height: typeof v.height === "number" ? v.height : undefined,
      duration_s: typeof result?.duration === "number" ? result.duration : undefined,
    };
  }
  const vids = result?.videos;
  if (Array.isArray(vids) && vids.length > 0) {
    const first = vids[0];
    if (typeof first === "string") return { url: first, mime: "video/mp4" };
    if (first && typeof first.url === "string") {
      return { url: first.url, mime: typeof first.content_type === "string" ? first.content_type : "video/mp4" };
    }
  }
  if (typeof result?.video_url === "string") return { url: result.video_url, mime: "video/mp4" };

  const imgs = result?.images;
  if (Array.isArray(imgs) && imgs.length > 0) {
    const first = imgs[0];
    if (typeof first === "string") return { url: first, mime: "image/png" };
    if (first && typeof first.url === "string") {
      return {
        url: first.url,
        mime: typeof first.content_type === "string" ? first.content_type : "image/png",
        width: typeof first.width === "number" ? first.width : undefined,
        height: typeof first.height === "number" ? first.height : undefined,
      };
    }
  }
  const img = result?.image;
  if (img && typeof img.url === "string") {
    return { url: img.url, mime: typeof img.content_type === "string" ? img.content_type : "image/png" };
  }
  return null;
}

/** Last few log lines from a fal status body (?logs=1). */
function logsTail(st: Record<string, unknown>): string[] {
  const logs = Array.isArray(st.logs) ? st.logs : [];
  return logs
    .slice(-5)
    .map((l) => String((l as Record<string, unknown>)?.message ?? ""))
    .filter((m) => m.length > 0);
}

export const falAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    const endpoint = falEndpoint(step.model);
    const body = falInput(step, input);
    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${FAL_QUEUE_BASE}/${endpoint}`,
      {
        method: "POST",
        headers: falHeaders({ [FAL_OBJECT_LIFECYCLE_HEADER]: FAL_OBJECT_LIFECYCLE_VALUE }),
        body: JSON.stringify(body),
      },
      BUDGETS.submitMs,
      classifyFal,
    );
    const { request_id, status_url, response_url } = data;
    if (!request_id || !status_url || !response_url) {
      throw new ProviderError(PROVIDER, "upstream", `Unexpected fal submit response (${endpoint}): ${snippet(data, 400)}`);
    }
    const echo = {
      request_id: String(request_id),
      status_url: String(status_url),
      response_url: String(response_url),
    };
    rememberBounded(submitEcho, echo.request_id, echo);
    return {
      provider: PROVIDER,
      model: step.model,
      id: echo.request_id,
      poll_url: echo.status_url,
      submitted_at: new Date().toISOString(),
    };
  },

  async poll(ref: JobRef): Promise<JobState> {
    if (!ref.poll_url) return { status: "failed", error_class: "other", message: "fal job has no status URL" };
    const statusUrl = new URL(requireHost(ref.poll_url, FAL_HOSTS, PROVIDER));
    statusUrl.searchParams.set("logs", "1");

    const st = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      statusUrl.toString(),
      { method: "GET", headers: falHeaders() },
      BUDGETS.pollMs,
      classifyFal,
    );

    const status = String(st.status ?? "");
    if (status === "IN_QUEUE") return { status: "queued" };
    if (status === "IN_PROGRESS") return { status: "running" };

    if (status === "COMPLETED") {
      const responseUrl = requireHost(
        typeof st.response_url === "string" ? st.response_url : falResponseUrl(ref.poll_url),
        FAL_HOSTS,
        PROVIDER,
      );
      const result = await fetchJson<Record<string, unknown>>(
        PROVIDER,
        responseUrl,
        { method: "GET", headers: falHeaders() },
        BUDGETS.pollMs,
        classifyFal,
      );
      // Some fal image models report the safety verdict in the result body.
      const nsfwFlags = (result as { has_nsfw_concepts?: unknown }).has_nsfw_concepts;
      if (Array.isArray(nsfwFlags) && nsfwFlags.some(Boolean)) {
        return { status: "failed", error_class: "nsfw", message: "fal flagged this generation as NSFW" };
      }
      const out = extractResult(result);
      if (!out) {
        return { status: "failed", error_class: "upstream", message: `fal result had no media url: ${snippet(result)}` };
      }
      return {
        status: "done",
        result_url: out.url,
        mime: out.mime,
        ...(out.duration_s != null ? { duration_s: out.duration_s } : {}),
        ...(out.width != null ? { width: out.width } : {}),
        ...(out.height != null ? { height: out.height } : {}),
        meta: { request_id: ref.id },
      };
    }

    const tail = logsTail(st);
    return {
      status: "failed",
      error_class: "upstream",
      message: tail.length > 0 ? tail.join(" | ").slice(0, 500) : `fal reported status ${status || "FAILED"}`,
    };
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
