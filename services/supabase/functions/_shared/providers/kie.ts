// Kie.ai adapter — TWO code paths, because Kie runs two different APIs.
//
// A) MARKET API (everything modelled as a "job"):
//      POST https://api.kie.ai/api/v1/jobs/createTask
//           { model, input: { prompt, image_url, resolution: "1080p", duration: "5" } }
//        -> { code, msg, data: { taskId } }
//      GET  https://api.kie.ai/api/v1/jobs/recordInfo?taskId=...
//        -> data.state ∈ waiting | queuing | generating | success | fail
//           data.resultJson is a JSON *STRING* holding { resultUrls: [...] } — it
//           has to be parsed, it is not an object.
//
// B) LEGACY VEO API:
//      POST https://api.kie.ai/api/v1/veo/generate
//           { prompt, imageUrls: [], model: "veo3_fast", aspect_ratio, duration: 8, resolution: "1080p" }
//      GET  https://api.kie.ai/api/v1/veo/record-info?taskId=...
//        -> data.successFlag 0 = generating, 1 = success, 2|3 = failed
//
// Kie answers HTTP 200 with a `code` in the body far more often than it answers
// a real status, so BOTH are classified.  402 -> validation ("credits"),
// 408/455/501 -> upstream, 429 -> rate_limit.
//
// TRUST NOTHING IN THE ECHO. Kie has silently downgraded duration/resolution on
// resold capacity; every terminal state re-checks what came back against what we
// asked for and sets meta.substituted = true when they differ, so the ledger and
// the app can tell the truth about what the customer actually got.
//
// Kie deletes generated media after 14 DAYS — persist() is not optional here.
//
// Customer photos are staged in OUR R2 behind a short-lived presigned GET, never
// on Kie's upload host (kieai.redpandaai.co): a listing photo is a photograph of
// somebody's home and it stays on our storage.

import type { RouteStep } from "../router.ts";
import type { DoneState, ErrorClass, GenerateInput, JobRef, JobState, ProviderAdapter } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  fetchJson,
  persistResult,
  publicImageUrlFor,
  rememberBounded,
  requireHost,
  snippet,
} from "./common.ts";

const PROVIDER = "kie";
const KIE_BASE = "https://api.kie.ai";
const KIE_HOSTS = ["api.kie.ai"] as const;

function kieKey(): string {
  const key = Deno.env.get("KIE_API_KEY")?.trim();
  if (!key) throw new ProviderError(PROVIDER, "upstream", "KIE_API_KEY function secret is not set");
  return key;
}

function kieHeaders(): Record<string, string> {
  return { "Authorization": `Bearer ${kieKey()}`, "Content-Type": "application/json" };
}

/** True for the legacy Veo endpoints (model ids "veo3_fast", "veo3", …). */
export function isLegacyVeoModel(model: string): boolean {
  return /^veo3(_|$)/i.test(model.trim());
}

/** Kie's own status codes → the router's error vocabulary. */
export function classifyKie(code: number, message = ""): ErrorClass {
  if (code === 402) return "validation"; // out of credits: a caller-visible refusal
  if (code === 429) return "rate_limit";
  if (code === 408 || code === 455 || code === 501) return "upstream";
  if (code === 400 || code === 422 || code === 451) {
    return /nsfw|sensitive|content polic/i.test(message) ? "nsfw" : "validation";
  }
  if (code === 401 || code === 403) return "upstream"; // our key, not the caller's session
  if (code === 404) return "upstream";
  if (code >= 500) return "upstream";
  return "other";
}

function kieMessage(code: number, msg: string): string {
  // Kie echoes the request (including the presigned image URL we handed it) in
  // some error messages — snippet() redacts anything signed.
  const safe = snippet(msg, 200);
  if (code === 402) return `Kie rejected the job: out of credits (${safe || "402"})`;
  return `Kie ${code}: ${safe || "no message"}`;
}

interface KieEnvelope<T> {
  code?: number;
  msg?: string;
  data?: T;
}

/** One bounded Kie call; unwraps `{code,msg,data}` and classifies both layers. */
async function kieCall<T>(url: string, init: RequestInit, timeoutMs: number): Promise<T> {
  const env = await fetchJson<KieEnvelope<T>>(
    PROVIDER,
    url,
    init,
    timeoutMs,
    (status, body) => classifyKie(Number((body as KieEnvelope<unknown>)?.code ?? status), snippet(body, 200)),
  );
  const code = Number(env.code ?? 200);
  if (code !== 200) {
    throw new ProviderError(PROVIDER, classifyKie(code, env.msg ?? ""), kieMessage(code, env.msg ?? ""), code);
  }
  if (env.data == null) throw new ProviderError(PROVIDER, "upstream", `Kie returned no data: ${snippet(env)}`);
  return env.data;
}

// ── What we asked for, so the echo can be checked ────────────────────────────

interface Asked {
  duration: string;
  resolution: string;
}
const asked = new Map<string, Asked>();

/** Compare what came back against what we asked for. */
export function checkSubstitution(
  want: Asked | undefined,
  got: { duration?: unknown; resolution?: unknown },
): { substituted: boolean; requested?: Asked; returned?: { duration?: string; resolution?: string } } {
  if (!want) return { substituted: false };
  const gotDuration = got.duration == null ? undefined : String(got.duration).replace(/s$/i, "");
  const gotResolution = got.resolution == null ? undefined : String(got.resolution).toLowerCase();
  const durationDiff = gotDuration != null && gotDuration !== want.duration;
  const resolutionDiff = gotResolution != null && gotResolution !== want.resolution.toLowerCase();
  return {
    substituted: durationDiff || resolutionDiff,
    requested: want,
    returned: { duration: gotDuration, resolution: gotResolution },
  };
}

/**
 * `data.resultJson` is a STRING of JSON, not JSON. Parse it defensively and pull
 * the first result URL out of any of the three shapes Kie has shipped.
 */
export function parseResultUrls(resultJson: unknown): string[] {
  let parsed: unknown = resultJson;
  if (typeof resultJson === "string") {
    const trimmed = resultJson.trim();
    if (!trimmed) return [];
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      return /^https?:\/\//i.test(trimmed) ? [trimmed] : [];
    }
  }
  if (Array.isArray(parsed)) return parsed.filter((u) => typeof u === "string") as string[];
  if (parsed && typeof parsed === "object") {
    const o = parsed as Record<string, unknown>;
    for (const key of ["resultUrls", "result_urls", "urls", "resultUrl"]) {
      const v = o[key];
      if (Array.isArray(v)) return v.filter((u) => typeof u === "string") as string[];
      if (typeof v === "string") return [v];
    }
  }
  return [];
}

function mimeFor(url: string, task: string): string {
  if (/\.(mp4|m4v)(\?|$)/i.test(url)) return "video/mp4";
  if (/\.(mov)(\?|$)/i.test(url)) return "video/quicktime";
  if (/\.(png)(\?|$)/i.test(url)) return "image/png";
  if (/\.(jpe?g)(\?|$)/i.test(url)) return "image/jpeg";
  return task.startsWith("photo.") ? "image/png" : "video/mp4";
}

// ── Adapter ──────────────────────────────────────────────────────────────────

export const kieAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    const duration = String(Math.round(Number(input.seconds ?? 5)));
    const resolution = input.resolution ?? "1080p";
    const legacy = isLegacyVeoModel(step.model);

    let taskId: string;
    if (legacy) {
      const imageUrls = input.image_url || input.image_b64
        ? [await publicImageUrlFor(input, PROVIDER)]
        : [];
      const data = await kieCall<{ taskId?: string }>(
        `${KIE_BASE}/api/v1/veo/generate`,
        {
          method: "POST",
          headers: kieHeaders(),
          body: JSON.stringify({
            prompt: input.prompt,
            imageUrls,
            model: step.model,
            aspect_ratio: input.aspect ?? "16:9",
            duration: Number(duration) || 8,
            resolution,
          }),
        },
        BUDGETS.submitMs,
      );
      taskId = String(data.taskId ?? "");
    } else {
      const imageUrl = input.image_url || input.image_b64
        ? await publicImageUrlFor(input, PROVIDER)
        : undefined;
      const jobInput: Record<string, unknown> = { prompt: input.prompt };
      if (imageUrl) jobInput.image_url = imageUrl;
      jobInput.resolution = resolution;
      jobInput.duration = duration;
      const data = await kieCall<{ taskId?: string }>(
        `${KIE_BASE}/api/v1/jobs/createTask`,
        {
          method: "POST",
          headers: kieHeaders(),
          body: JSON.stringify({ model: step.model, input: jobInput }),
        },
        BUDGETS.submitMs,
      );
      taskId = String(data.taskId ?? "");
    }

    if (!taskId) throw new ProviderError(PROVIDER, "upstream", "Kie accepted the job but returned no taskId");
    rememberBounded(asked, taskId, { duration, resolution });
    return {
      provider: PROVIDER,
      model: step.model,
      id: taskId,
      poll_url: legacy
        ? `${KIE_BASE}/api/v1/veo/record-info?taskId=${encodeURIComponent(taskId)}`
        : `${KIE_BASE}/api/v1/jobs/recordInfo?taskId=${encodeURIComponent(taskId)}`,
      submitted_at: new Date().toISOString(),
    };
  },

  async poll(ref: JobRef): Promise<JobState> {
    const url = requireHost(
      ref.poll_url ?? `${KIE_BASE}/api/v1/jobs/recordInfo?taskId=${encodeURIComponent(ref.id)}`,
      KIE_HOSTS,
      PROVIDER,
    );
    const legacy = /\/veo\/record-info/.test(url);
    const data = await kieCall<Record<string, unknown>>(
      url,
      { method: "GET", headers: kieHeaders() },
      BUDGETS.pollMs,
    );

    const want = asked.get(ref.id);
    const done = (urls: string[], echo: { duration?: unknown; resolution?: unknown }): JobState => {
      const first = urls.find((u) => typeof u === "string" && /^https?:\/\//i.test(u));
      if (!first) {
        return { status: "failed", error_class: "upstream", message: "Kie reported success with no result URL" };
      }
      asked.delete(ref.id);
      const sub = checkSubstitution(want, echo);
      return {
        status: "done",
        result_url: first,
        mime: mimeFor(first, ref.model.startsWith("photo") ? "photo." : "video."),
        meta: {
          task_id: ref.id,
          // Kie media is deleted after 14 days: persist() before success.
          expires_in_days: 14,
          ...(sub.substituted
            ? { substituted: true, requested: sub.requested, returned: sub.returned }
            : {}),
          ...(want ? {} : { echo_unverified: true }),
        },
      };
    };

    if (legacy) {
      const flag = Number(data.successFlag ?? 0);
      const response = (data.response ?? {}) as Record<string, unknown>;
      if (flag === 1) {
        return done(parseResultUrls(response.resultUrls ?? data.resultJson), {
          duration: response.duration ?? data.duration,
          resolution: response.resolution ?? data.resolution,
        });
      }
      if (flag === 2 || flag === 3) {
        const msg = String(data.errorMessage ?? data.failMsg ?? "Kie reported a failed generation");
        return {
          status: "failed",
          error_class: classifyKie(Number(data.errorCode ?? data.failCode ?? 500), msg),
          message: snippet(msg, 300),
        };
      }
      return { status: flag === 0 ? "running" : "queued" };
    }

    const state = String(data.state ?? "").toLowerCase();
    switch (state) {
      case "waiting":
      case "queuing":
        return { status: "queued" };
      case "generating":
        return { status: "running" };
      case "success": {
        // resultJson is a JSON STRING; param is Kie's echo of our request.
        let echo: Record<string, unknown> = {};
        if (typeof data.param === "string") {
          try {
            const p = JSON.parse(data.param) as Record<string, unknown>;
            echo = (p.input ?? p) as Record<string, unknown>;
          } catch { /* an unparseable echo is simply no echo */ }
        }
        const resultObj = (() => {
          if (typeof data.resultJson !== "string") return {} as Record<string, unknown>;
          try {
            return JSON.parse(data.resultJson) as Record<string, unknown>;
          } catch {
            return {} as Record<string, unknown>;
          }
        })();
        return done(parseResultUrls(data.resultJson), {
          duration: resultObj.duration ?? echo.duration,
          resolution: resultObj.resolution ?? echo.resolution,
        });
      }
      case "fail": {
        const msg = String(data.failMsg ?? "Kie reported a failed generation");
        return {
          status: "failed",
          error_class: classifyKie(Number(data.failCode ?? 500), msg),
          message: snippet(msg, 300),
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
