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
// C) PROPERTY VIDEO PROFILE kie-kling3-4k-steady-v1 (../property-video-kie.ts),
//    selected ONLY by extra.property_video_quality_profile. Every field, the
//    identity's own consistency and the exact reviewed prompt (its pinned
//    template SHA-256) are checked before the key is read or any request
//    exists, and the wire is closed:
//      { model: "kling-3.0/video", input: { prompt, image_urls: [url],
//        sound: false, duration: "5", mode: "4K", multi_shots: false } }
//    No aspect_ratio (image_urls auto-adapt the aspect), no callBackUrl, no
//    kling_elements, no negative prompt. The source is the caller's owned https
//    capability, byte for byte; it is never restaged. A missing KIE_API_KEY on
//    this path is a definite pre-request refusal (status 0, dispatch_rejected):
//    nothing was sent, so the reserved hold is released.
//
// Kie answers HTTP 200 with a `code` in the body far more often than it answers
// a real status, so BOTH are classified.  402 -> upstream (our vendor credits),
// 408/455/501 -> upstream, 429 -> rate_limit.
//
// SUBMIT OUTCOMES (market createTask, every market model). An envelope code of
// 400/401/402/403/404/422/429 with no task receipt proves no job exists:
// dispatch_rejected, and the reserved budget is released. Everything else —
// timeout, network, 5xx, 455/500/501/505, code 200 without a taskId, a body that
// is not JSON — may have created a billable job: the hold stays and nothing is
// POSTed again. A poll is never a dispatch rejection.
//
// TRUST NOTHING IN THE ECHO. Kie has silently downgraded duration/resolution on
// resold capacity; every terminal state re-checks what came back against what we
// asked for and sets meta.substituted = true when they differ, so the ledger and
// the app can tell the truth about what the customer actually got. The property
// profile records the tier it actually requests (mode "4K"), and only for that
// ask an echoed "4K", "4k" or "2160p" is the same tier. A poll with
// no record of the request (another isolate submitted it) claims nothing and says
// echo_unverified. A market "success" whose first result is not https is a
// failure: it is never downloaded. The actual MP4 is the only quality evidence.
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
  definitiveSubmitRejection,
  fetchJson,
  persistResult,
  publicImageUrlFor,
  rememberBounded,
  requireHost,
  snippet,
} from "./common.ts";
import {
  KIE_PROPERTY_IDENTITY,
  KIE_PROPERTY_MODE,
  KIE_PROPERTY_MODEL,
  KIE_PROPERTY_PROFILE,
  kiePropertyIdentityConsistent,
  kiePropertyPromptPinned,
} from "../property-video-kie.ts";

import {aerialOpeningKieRequest,AERIAL_OMNI_REFERENCE_MODEL} from "../aerial-kie.ts";

const PROVIDER = "kie";
const KIE_BASE = "https://api.kie.ai";
const KIE_HOSTS = ["api.kie.ai"] as const;
const KIE_KEY_MISSING = "KIE_API_KEY function secret is not set";

/**
 * The function secret. `definiteWhenMissing` is the property profile only: it
 * reads the key after full validation and before any request exists, so a
 * missing secret proves nothing was sent (status 0, dispatch_rejected) and the
 * reserved hold is released. Every other Kie path keeps its existing error.
 */
function kieKey(definiteWhenMissing = false): string {
  const key = Deno.env.get("KIE_API_KEY")?.trim();
  if (!key) {
    throw definiteWhenMissing
      ? new ProviderError(PROVIDER, "upstream", KIE_KEY_MISSING, 0, true)
      : new ProviderError(PROVIDER, "upstream", KIE_KEY_MISSING);
  }
  return key;
}

function kieHeaders(definiteWhenMissing = false): Record<string, string> {
  return { "Authorization": `Bearer ${kieKey(definiteWhenMissing)}`, "Content-Type": "application/json" };
}

/** True for the legacy Veo endpoints (model ids "veo3_fast", "veo3", …). */
export function isLegacyVeoModel(model: string): boolean {
  return /^veo3(_|$)/i.test(model.trim());
}

/** Kie failure text that means a content/safety refusal of the customer's media. */
const KIE_CONTENT_REFUSAL = /nsfw|sensitive|content polic/i;

/** Kie's own status codes → the router's error vocabulary. */
export function classifyKie(code: number, message = ""): ErrorClass {
  if (code === 402) return "upstream"; // our vendor balance, never invalid customer inputs
  if (code === 429) return "rate_limit";
  if (code === 408 || code === 455 || code === 501) return "upstream";
  if (code === 400 || code === 422 || code === 451) {
    return KIE_CONTENT_REFUSAL.test(message) ? "nsfw" : "validation";
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

/**
 * createTask envelope codes that prove no job was created: auth, balance,
 * not-found, validation and rate-limit refusals. 455/500/501/505 and anything
 * unknown may follow an accepted job, so they stay ambiguous.
 */
const KIE_DEFINITE_SUBMIT_CODES: ReadonlySet<number> = new Set([400, 401, 402, 403, 404, 422, 429]);

/**
 * One bounded Kie call; unwraps `{code,msg,data}` and classifies both layers.
 * `marketSubmit` marks the createTask POST, the only call whose envelope can
 * prove that no job (and so no charge) exists. Non-2xx HTTP answers carry
 * fetchJson's own definitive-POST check; polls are never dispatch rejections.
 */
async function kieCall<T>(url: string, init: RequestInit, timeoutMs: number, marketSubmit = false): Promise<T> {
  const env = await fetchJson<KieEnvelope<T>>(
    PROVIDER,
    url,
    init,
    timeoutMs,
    (status, body) => classifyKie(Number((body as KieEnvelope<unknown>)?.code ?? status), snippet(body, 200)),
  );
  const code = Number(env.code ?? 200);
  if (code !== 200) {
    const rejected = marketSubmit && KIE_DEFINITE_SUBMIT_CODES.has(code) && definitiveSubmitRejection(code, env);
    throw new ProviderError(PROVIDER, classifyKie(code, env.msg ?? ""), kieMessage(code, env.msg ?? ""), code, rejected);
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
/** Asks recorded by the property profile, which requests the native-4K tier
 * (mode "4K"). Only these treat an echoed "4K", "4k" or "2160p" as that same
 * tier; every other ask keeps the exact case-insensitive comparison. */
const nativeFourKAsks = new WeakSet<Asked>();
const nativeFourKTier = (value: string) => value === "2160p" ? "4k" : value;

/** Compare what came back against what we asked for. */
export function checkSubstitution(
  want: Asked | undefined,
  got: { duration?: unknown; resolution?: unknown },
): { substituted: boolean; requested?: Asked; returned?: { duration?: string; resolution?: string } } {
  if (!want) return { substituted: false };
  const gotDuration = got.duration == null ? undefined : String(got.duration).replace(/s$/i, "");
  const gotResolution = got.resolution == null ? undefined : String(got.resolution).toLowerCase();
  const durationDiff = gotDuration != null && gotDuration !== want.duration;
  const resolutionDiff = gotResolution != null && (nativeFourKAsks.has(want)
    ? nativeFourKTier(gotResolution) !== nativeFourKTier(want.resolution.toLowerCase())
    : gotResolution !== want.resolution.toLowerCase());
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

/** True only for an absolute URL whose parsed scheme is https. */
function isHttpsUrl(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

/**
 * Kie's task receipt: a non-blank string (or a finite number). Anything else is
 * no receipt, so the submit stays ambiguous instead of being called accepted.
 */
function receiptId(value: unknown): string {
  if (typeof value === "string") return value.trim() ? value : "";
  return typeof value === "number" && Number.isFinite(value) ? String(value) : "";
}

/** A JobRef only for a usable receipt; without one the outcome is ambiguous. */
function acceptedJob(step: RouteStep, taskId: string, want: Asked, legacy: boolean): JobRef {
  if (!taskId) throw new ProviderError(PROVIDER, "upstream", "Kie accepted the job but returned no taskId");
  rememberBounded(asked, taskId, want);
  return {
    provider: PROVIDER,
    model: step.model,
    id: taskId,
    poll_url: legacy
      ? `${KIE_BASE}/api/v1/veo/record-info?taskId=${encodeURIComponent(taskId)}`
      : `${KIE_BASE}/api/v1/jobs/recordInfo?taskId=${encodeURIComponent(taskId)}`,
    submitted_at: new Date().toISOString(),
  };
}

// ── Property video profile (kie-kling3-4k-steady-v1) ─────────────────────────

const KIE_PROPERTY_PROMPT_MAX_CHARS = 2500;

/** Nothing was sent: a definitive pre-dispatch refusal releases the hold. */
function propertyRefusal(field: string): ProviderError {
  return new ProviderError(
    PROVIDER,
    "validation",
    `Kie property video refused before dispatch: ${field} does not match ${KIE_PROPERTY_PROFILE}.`,
    400,
    true,
  );
}

/** The frozen identity itself is inconsistent: the profile cannot be sent. */
function inconsistentPropertyIdentity(): ProviderError {
  return new ProviderError(
    PROVIDER,
    "validation",
    `Kie property video refused before dispatch: the ${KIE_PROPERTY_PROFILE} identity is internally inconsistent.`,
    400,
    true,
  );
}

/**
 * The owned source capability exactly as issued: lowercase https://, printable
 * ASCII only, a host and no userinfo. Never a data: URL, never restaged.
 */
function ownedHttpsSource(value: unknown): value is string {
  if (typeof value !== "string" || !value.startsWith("https://") || /[^\x21-\x7e]/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname !== "" && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}

export interface KiePropertyRequest {
  model: string;
  input: { prompt: string; image_urls: [string]; sound: boolean; duration: string; mode: string; multi_shots: boolean };
}

/**
 * The closed createTask body for the property profile. Refuses (validation,
 * 400, dispatch_rejected) unless step and input are exactly the profile; the
 * body is built from the frozen identity and carries nothing a caller can widen.
 */
export function kiePropertyRequest(step: RouteStep, input: GenerateInput): KiePropertyRequest {
  if (!kiePropertyIdentityConsistent()) throw inconsistentPropertyIdentity();
  const extra = input.extra ?? {};
  if (step.provider !== KIE_PROPERTY_IDENTITY.provider) throw propertyRefusal("provider");
  if (step.model !== KIE_PROPERTY_MODEL) throw propertyRefusal("model");
  if (input.task !== "video.reel_clip") throw propertyRefusal("task");
  if (input.framing !== "preserve_photo") throw propertyRefusal("framing");
  if (input.seconds !== KIE_PROPERTY_IDENTITY.seconds) throw propertyRefusal("duration");
  if (input.resolution !== "1080p") throw propertyRefusal("resolution");
  if (extra.kie_mode !== KIE_PROPERTY_MODE) throw propertyRefusal("mode");
  if (extra.sound !== KIE_PROPERTY_IDENTITY.sound) throw propertyRefusal("sound");
  if ((input.aspect !== "16:9" && input.aspect !== "9:16") || extra.property_video_target_aspect !== input.aspect) {
    throw propertyRefusal("target canvas");
  }
  const source = input.image_url;
  if (input.image_b64 !== undefined || !ownedHttpsSource(source)) throw propertyRefusal("source image");
  const prompt = input.prompt;
  if (typeof prompt !== "string" || !prompt.trim() || prompt.length > KIE_PROPERTY_PROMPT_MAX_CHARS) {
    throw propertyRefusal("prompt");
  }
  return {
    model: KIE_PROPERTY_MODEL,
    input: {
      prompt,
      image_urls: [source],
      sound: KIE_PROPERTY_IDENTITY.sound,
      duration: String(KIE_PROPERTY_IDENTITY.seconds),
      mode: KIE_PROPERTY_MODE,
      multi_shots: KIE_PROPERTY_IDENTITY.multi_shots,
    },
  };
}

// ── Adapter ──────────────────────────────────────────────────────────────────

export const kieAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    if(input.extra?.aerial_opening_profile!==undefined){
      let request;try{request=aerialOpeningKieRequest(step,input);}catch{throw new ProviderError(PROVIDER,'validation','Aerial opening profile refused before dispatch.',400,true);}
      const data=await kieCall<{taskId?:unknown}>(`${KIE_BASE}/api/v1/jobs/createTask`,{method:'POST',headers:kieHeaders(true),body:JSON.stringify(request)},BUDGETS.submitMs,true);
      const fourK='mode'in request.input&&request.input.mode==='4K';const want:Asked={duration:'5',resolution:fourK?'4K':'1080p'};if(fourK)nativeFourKAsks.add(want);return acceptedJob(step,receiptId(data.taskId),want,false);
    }
    if (input.extra?.property_video_quality_profile === KIE_PROPERTY_PROFILE) {
      // Fully validated before the key is read or a request exists.
      const request = kiePropertyRequest(step, input);
      // Only the exact reviewed steady prompt the frozen identity pins.
      if (!await kiePropertyPromptPinned(request.input.prompt)) throw propertyRefusal("prompt");
      const data = await kieCall<{ taskId?: unknown }>(
        `${KIE_BASE}/api/v1/jobs/createTask`,
        { method: "POST", headers: kieHeaders(true), body: JSON.stringify(request) },
        BUDGETS.submitMs,
        true,
      );
      // Record the tier actually requested, so a truthful 4K echo is no
      // substitution; acceptance still rests on the actual MP4 facts only.
      const want: Asked = { duration: request.input.duration, resolution: request.input.mode };
      nativeFourKAsks.add(want);
      return acceptedJob(step, receiptId(data.taskId), want, false);
    }
    const duration = String(Math.round(Number(input.seconds ?? 5)));
    const resolution = input.resolution ?? "1080p";
    const legacy = isLegacyVeoModel(step.model);
    if (input.framing === "preserve_photo" && (input.task !== "video.reel_clip" || step.model !== "kling-3.0/video")) {
      throw new ProviderError(PROVIDER, "validation", "This model cannot preserve photo framing.", 400, true);
    }

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
      if (step.model === "kling-3.0/video") {
        // Official single-shot I2V schema. Omit aspect_ratio for source-auto.
        // https://docs.kie.ai/market/kling/kling-3-0#aspect-ratio-auto-adaptation
        if (!imageUrl || duration !== "5" || resolution !== "1080p" ||
            !["pro", "4K"].includes(String(input.extra?.kie_mode)) || input.extra?.sound !== false ||
            input.framing !== "preserve_photo") {
          throw new ProviderError(PROVIDER, "validation", "Kling comparison requires a priced five-second Pro or 4K silent photo-preserving shot.", 400, true);
        }
        jobInput.image_urls = [imageUrl];
        jobInput.sound = false;
        jobInput.duration = duration;
        jobInput.mode = "pro";
        if (input.extra?.kie_mode === "4K") jobInput.mode = "4K";
        jobInput.multi_shots = false;
        if(input.extra?.property_video_target_aspect!==undefined){
          if(!['16:9','9:16'].includes(String(input.extra.property_video_target_aspect))||input.extra.property_video_target_aspect!==input.aspect)throw new ProviderError(PROVIDER,'validation','The server property-video target canvas changed.',400,true);
          jobInput.aspect_ratio=input.extra.property_video_target_aspect;
        }
      } else {
        if (imageUrl) jobInput.image_url = imageUrl;
        jobInput.resolution = resolution;
        jobInput.duration = duration;
      }
      if (step.model === "bytedance/v1-pro-fast-image-to-video") {
        // No aspect_ratio field. Real owner QA returned landscape from portrait
        // sources, so this model is not eligible for preserve_photo requests.
        // https://docs.kie.ai/market/bytedance/v1-pro-fast-image-to-video
        if (!["5", "10"].includes(duration) || !["720p", "1080p"].includes(resolution)) {
          throw new ProviderError(PROVIDER, "validation", "Kie Seedance Fast needs a supported duration and resolution", 400);
        }
        jobInput.nsfw_checker = true;
      }
      const data = await kieCall<{ taskId?: unknown }>(
        `${KIE_BASE}/api/v1/jobs/createTask`,
        {
          method: "POST",
          headers: kieHeaders(),
          body: JSON.stringify({ model: step.model, input: jobInput }),
        },
        BUDGETS.submitMs,
        true,
      );
      taskId = receiptId(data.taskId);
    }

    return acceptedJob(step, taskId, { duration, resolution }, legacy);
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

    if(ref.model===AERIAL_OMNI_REFERENCE_MODEL&&(data.taskId!==ref.id||data.model!==AERIAL_OMNI_REFERENCE_MODEL))return{status:'failed',error_class:'upstream',message:'The saved aerial reference task identity changed'};
    const want = asked.get(ref.id);
    const done = (
      first: string | undefined,
      echo: { duration?: unknown; resolution?: unknown },
      observed: Record<string, unknown> = {},
    ): JobState => {
      if (!first) {
        return { status: "failed", error_class: "upstream", message: "Kie reported success with no result URL" };
      }
      asked.delete(ref.id);
      // Cold start (another isolate submitted, or this one restarted): with no
      // record of the request there is nothing to compare, so no substitution
      // is claimed either way — only echo_unverified.
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
          ...observed,
        },
      };
    };

    if (legacy) {
      const flag = Number(data.successFlag ?? 0);
      const response = (data.response ?? {}) as Record<string, unknown>;
      if (flag === 1) {
        const urls = parseResultUrls(response.resultUrls ?? data.resultJson);
        return done(urls.find((u) => typeof u === "string" && /^https?:\/\//i.test(u)), {
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
        // The first result is the deliverable. Anything but https (http, data:,
        // file:, relative) is a failure and is never downloaded.
        const urls = parseResultUrls(data.resultJson);
        if (urls.length > 0 && !isHttpsUrl(urls[0])) {
          return { status: "failed", error_class: "upstream", message: "Kie reported success with a non-https result URL" };
        }
        const credits = data.creditsConsumed;
        return done(urls[0], {
          duration: resultObj.duration ?? echo.duration,
          resolution: resultObj.resolution ?? echo.resolution,
        }, {
          kie_state: state,
          ...(typeof credits === "number" && Number.isFinite(credits) && credits >= 0 ? { credits_consumed: credits } : {}),
        });
      }
      case "fail": {
        const msg = String(data.failMsg ?? "Kie reported a failed generation");
        return {
          status: "failed",
          // A content refusal concerns the customer's media, whatever code Kie attached.
          error_class: KIE_CONTENT_REFUSAL.test(msg) ? "nsfw" : classifyKie(Number(data.failCode ?? 500), msg),
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
