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

import { paramsOf, type RouteStep } from "../router.ts";
import { OWNER_RAIL_MOTION_PROFILE, OWNER_RAIL_ROUTE_ID, OWNER_RAIL_NEGATIVE_PROMPT, OWNER_RAIL_CFG_SCALE } from "../property-motion-profile.ts";
import type { DoneState, ErrorClass, GenerateInput, JobRef, JobState, ProviderAdapter, ProviderDeliveryIssue } from "./types.ts";
import {
  BUDGETS,
  ProviderError,
  classifyStatus,
  definitiveSubmitRejection,
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

export type FalLegacyReceipt = { endpoint: string; requestId: string };

/** Parse only the paired, credential-free queue URLs used by older jobs. */
export function falLegacyReceipt(status: string, response: string): FalLegacyReceipt | null {
  try {
    const statusURL = new URL(status), responseURL = new URL(response);
    for (const url of [statusURL, responseURL]) {
      if (url.origin !== FAL_QUEUE_BASE || url.username || url.password || url.search || url.hash) return null;
    }
    const match = /^\/([A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)+)\/requests\/([A-Za-z0-9_-]{1,256})\/status$/.exec(statusURL.pathname);
    if (!match || responseURL.pathname !== `/${match[1]}/requests/${match[2]}`) return null;
    return { endpoint: match[1], requestId: match[2] };
  } catch {
    return null;
  }
}

/** The complete model comes from our owned durable receipt, never the caller.
 * fal's SDK status/result methods use owner/alias and omit the endpoint subpath:
 * https://github.com/fal-ai/fal-js/blob/main/libs/client/src/queue.ts
 * The REST docs also show complete endpoint URLs, so preserve that exact form.
 * No other prefix or sibling endpoint is an equivalent receipt. */
export function falLegacyReceiptMatchesModel(model: unknown, requestId: unknown, receipt: FalLegacyReceipt): boolean {
  if (typeof model !== "string" || requestId !== receipt.requestId) return false;
  const endpoint = falEndpoint(model);
  const parts = endpoint.split("/");
  if (parts.length < 2 || parts.some((p) => !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(p))) return false;
  const applicationRoot = parts.slice(0, 2).join("/");
  return receipt.endpoint === endpoint || receipt.endpoint === applicationRoot;
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
  const kling4K = model === "fal-ai/kling-video/v3/4k/image-to-video";
  const ownerMotion = extra.owner_motion_profile;
  const ownerRouteProfile = paramsOf(step)?.owner_motion_profile;
  const markedMotion = ownerMotion !== undefined || ownerRouteProfile !== undefined || step.route_id === OWNER_RAIL_ROUTE_ID;
  if (markedMotion && (ownerMotion !== OWNER_RAIL_MOTION_PROFILE || !kling4K ||
      step.provider !== PROVIDER || step.route_id !== OWNER_RAIL_ROUTE_ID ||
      ownerRouteProfile !== OWNER_RAIL_MOTION_PROFILE || step.unit !== "second" || step.unit_cents !== 42 ||
      ["negative_prompt", "cfg_scale", "end_image_url", "generate_audio", "sound"].some(key => extra[key] !== undefined))) {
    throw new ProviderError(PROVIDER, "validation", "The owner motion comparison recipe is unavailable.", 400, true);
  }
  if (input.framing === "preserve_photo" && (input.task !== "video.reel_clip" ||
      (!model.endsWith("bytedance/seedance/v1/pro/fast/image-to-video") && !kling4K))) {
    throw new ProviderError(PROVIDER, "validation", "This model cannot preserve photo framing.", 400, true);
  }

  if(extra.property_video_target_aspect!==undefined&&(!['16:9','9:16'].includes(String(extra.property_video_target_aspect))||extra.property_video_target_aspect!==input.aspect))throw new ProviderError(PROVIDER,'validation','The server property-video target canvas changed.',400,true);
  if (kling4K) {
    // Exact native4K endpoint. I2V inherits source aspect; do not outpaint or
    // pretend an ignored aspect field supplies real destination pixels.
    // https://fal.ai/models/fal-ai/kling-video/v3/4k/image-to-video/api
    if (input.task !== "video.reel_clip" || input.seconds !== 5 || input.resolution !== "1080p" ||
        input.framing !== "preserve_photo" || !["16:9", "9:16"].includes(String(input.aspect)) ||
        typeof input.image_url !== "string" || !/^(https:\/\/|data:image\/(jpeg|png|webp);base64,)/.test(input.image_url)) {
      throw new ProviderError(PROVIDER, "validation", "Kling4K comparison requires a priced five-second silent photo-preserving shot.", 400, true);
    }
    return { prompt: input.prompt, start_image_url: input.image_url, duration: "5", generate_audio: false,
      ...(ownerMotion === OWNER_RAIL_MOTION_PROFILE ? { negative_prompt: OWNER_RAIL_NEGATIVE_PROMPT, cfg_scale: OWNER_RAIL_CFG_SCALE } : {}) };
  }
  // Seedance 1.0 Pro Fast image-to-video — the reel and the grounded aerial.
  if (model.endsWith("bytedance/seedance/v1/pro/fast/image-to-video")) {
    if (input.task === "video.aerial") {
      return {
        prompt: input.prompt,
        image_url: input.image_url,
        resolution: "1080p",
        duration: String(secondsOf(input, 6)), // Seedance takes duration as a string
        num_frames: secondsOf(input, 6) * 24 + 1,
        aspect_ratio: input.aspect ?? "16:9",
        camera_fixed: false,
      };
    }
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      resolution: "1080p",
      duration: String(secondsOf(input, 5)), // Seedance takes duration as a string
      num_frames: secondsOf(input, 5) * 24 + 1,
      aspect_ratio: input.extra?.property_video_target_aspect === input.aspect && ["16:9","9:16"].includes(String(input.aspect)) ? input.aspect : input.framing === "preserve_photo" ? "auto" : input.aspect ?? "16:9",
      camera_fixed: false,
    };
  }

  // Hailuo 02 accepts 6 or 10 seconds, not Seedance's 5-second default.
  // Refuse before dispatch instead of secretly generating/billing a longer clip.
  // This does not enable a 768p fallback for a route that requires 1080p.
  if (model.includes("hailuo")) {
    const duration = secondsOf(input, 6);
    if (duration !== 6 && duration !== 10) {
      throw new ProviderError(PROVIDER, "validation", "This model requires a six- or ten-second clip.", 400, true);
    }
    return {
      prompt: input.prompt,
      image_url: input.image_url,
      duration: String(duration),
      prompt_optimizer: false,
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
      num_images: 1,
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
  const text = snippet(body, 400).toLowerCase().replace(/[_-]/g, " ");
  if (/nsfw|safety|content policy/.test(text)) return "nsfw";
  if (status === 422) return "validation";
  return classifyStatus(status);
}

/** A completed request whose result GET is denied is not proof that generation
 * failed. Keep its exact accepted receipt; never turn this into another POST.
 * Only closed classifications leave this function; no body/URL is retained. */
export function falResultErrorReason(body: unknown): "balance_exhausted" | "account_locked" | "auth" | "permission" | "content_policy" | "unknown" {
  // Diagnostic categorization only. It never authorizes generation or changes
  // the safety decision. Prefer documented structured type/code; bounded known
  // messages support older endpoints. Unknown replies stay explicitly unknown.
  const text = snippet(body, 400).toLowerCase().replace(/[_-]/g, " ");
  if (/nsfw|safety|content policy/.test(text)) return "content_policy";
  if (/user balance exhausted|insufficient (?:balance|credits)|balance (?:exhausted|depleted)|out of credits/.test(text)) return "balance_exhausted";
  if (/user is locked|account (?:locked|disabled)|user disabled/.test(text)) return "account_locked";
  if (/invalid (?:api )?key|unauthorized|authentication/.test(text)) return "auth";
  if (/permission|not authorized|access denied|forbidden/.test(text)) return "permission";
  return "unknown";
}
export function falResultReadIssue(status: number, body: unknown): ProviderDeliveryIssue | null {
  const reason = falResultErrorReason(body);
  if (status !== 403 || reason === "content_policy") return null;
  return { phase: "result_read", provider: "fal", provider_state: "completed", provider_status: 403, reason };
}

/** Closed submission diagnostics never preserve a response body, URL or key.
 * A403 is not itself evidence of insufficient provider credit. */
export function falSubmitDiagnostic(status:number,body:unknown){
  return {event:"fal_submit_refused",provider:"fal",phase:"submit",provider_status:status,
    reason:falResultErrorReason(body),dispatch_rejected:definitiveSubmitRejection(status,body)};
}

/** fal's terminal failure is COMPLETED plus error/error_type, not a new take. */
export function falCompletedFailure(data: Record<string, unknown>): Extract<JobState, { status: "failed" }> | null {
  const hasError = data.error != null && data.error !== false && data.error !== "";
  const hasType = typeof data.error_type === "string" && data.error_type.trim().length > 0;
  if (!hasError && !hasType) return null;
  // An opaque message cannot mask the provider's explicit safety type.
  // Only the derived class and generic sentence leave this helper.
  const errorClass = classifyFal(500, `${snippet(data.error_type, 120)} ${snippet(data.error, 280)}`);
  return {
    status: "failed", error_class: errorClass,
    message: errorClass === "nsfw" ? "The service refused this content under its safety policy." :
      "The video service could not complete this generation.",
  };
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

export interface FalRetainedResultDiagnostic {
  state:"completed"|"failed"|"unavailable";
  provider_status:number|null;
  reason?:ReturnType<typeof falResultErrorReason>;
  has_media?:boolean;
  error_class?:ErrorClass;
}
/** ONE read of the exact paired result endpoint, even when status is missing.
 * This does not persist, submit, refund or expose the returned media URL. */
export async function falRetainedResultDiagnostic(ref:JobRef):Promise<FalRetainedResultDiagnostic>{
  const response=ref.poll_url?falResponseUrl(ref.poll_url):null;
  const pair=ref.poll_url&&response?falLegacyReceipt(ref.poll_url,response):null;
  if(!pair||!falLegacyReceiptMatchesModel(ref.model,ref.id,pair))throw new ProviderError(PROVIDER,"validation","The retained provider receipt pair does not match.",0,true);
  const failure:{status:number|null;reason:ReturnType<typeof falResultErrorReason>}={status:null,reason:"unknown"};
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),BUDGETS.pollMs);
  try{
    // Keep this diagnostic self-contained: the deployed video closure retains
    // its older shared fetch helper. Bound both the read and response here.
    const res=await fetch(response!,{method:"GET",headers:falHeaders(),redirect:"error",signal:controller.signal});
    failure.status=res.status;
    const maximum=16384,declared=res.headers.get("content-length");
    if(declared!==null&&(!/^[0-9]+$/.test(declared)||Number(declared)>maximum)){
      void res.body?.cancel().catch(()=>{});
      throw new ProviderError(PROVIDER,"upstream","The retained result response exceeded its diagnostic bound.",res.status);
    }
    const reader=res.body?.getReader(),chunks:Uint8Array[]=[];let bytes=0;
    if(reader)try{for(;;){const next=await reader.read();if(next.done)break;
      if(!(next.value instanceof Uint8Array)||next.value.length>maximum-bytes)throw new ProviderError(PROVIDER,"upstream","The retained result response exceeded its diagnostic bound.",res.status);
      bytes+=next.value.length;chunks.push(next.value);
    }}catch(error){void reader.cancel().catch(()=>{});throw error;}finally{reader.releaseLock();}
    const joined=new Uint8Array(bytes);let at=0;for(const chunk of chunks){joined.set(chunk,at);at+=chunk.length;}
    const text=new TextDecoder("utf-8",{fatal:true}).decode(joined);
    let body:unknown=null;try{body=text?JSON.parse(text):null;}catch{body=text;}
    if(!res.ok){failure.reason=falResultErrorReason(body);throw new ProviderError(PROVIDER,classifyFal(res.status,body),"The retained result endpoint refused the read.",res.status);}
    if(!body||typeof body!=="object"||Array.isArray(body))return{state:"unavailable",provider_status:200,reason:"unknown",has_media:false};
    const failed=falCompletedFailure(body as Record<string,unknown>);
    if(failed)return{state:"failed",provider_status:200,error_class:failed.error_class};
    const media=extractResult(body);
    return media&&media.mime.split(";")[0].trim().toLowerCase()==="video/mp4"?{state:"completed",provider_status:200,has_media:true}:{state:"unavailable",provider_status:200,reason:"unknown",has_media:false};
  }catch(error){return{state:"unavailable",provider_status:failure.status??(error instanceof ProviderError?error.status??null:null),reason:failure.reason,error_class:error instanceof ProviderError?error.error_class:controller.signal.aborted?"timeout":"other"};}
  finally{clearTimeout(timer);}
}

export const falAdapter: ProviderAdapter = {
  key: PROVIDER,

  async submit(step: RouteStep, input: GenerateInput): Promise<JobRef> {
    let endpoint: string, body: Record<string, unknown>, headers: Record<string, string>;
    try {
      endpoint = falEndpoint(step.model);
      body = falInput(step, input);
      headers = falHeaders({ [FAL_OBJECT_LIFECYCLE_HEADER]: FAL_OBJECT_LIFECYCLE_VALUE });
    } catch (error) {
      // No network call has started. Status0 is an internal before-dispatch
      // marker, never a fabricated upstream HTTP answer.
      if (error instanceof ProviderError) {
        throw new ProviderError(PROVIDER, error.error_class, "The service could not prepare this submission.", 0, true);
      }
      throw new ProviderError(PROVIDER, "validation", "The service could not prepare this submission.", 0, true);
    }
    const data = await fetchJson<Record<string, unknown>>(
      PROVIDER,
      `${FAL_QUEUE_BASE}/${endpoint}`,
      {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      },
      BUDGETS.submitMs,
      (status, body) => {
        if (status === 403) console.error(JSON.stringify(falSubmitDiagnostic(status, body)));
        return classifyFal(status, body);
      },
    );
    const { request_id, status_url, response_url } = data;
    if (typeof request_id !== "string" || !/^[!-~]{1,256}$/.test(request_id) ||
        typeof status_url !== "string" || typeof response_url !== "string") {
      throw new ProviderError(PROVIDER, "upstream", "The service did not return a valid submission receipt.");
    }
    requireHost(status_url, FAL_HOSTS, PROVIDER);
    requireHost(response_url, FAL_HOSTS, PROVIDER);
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

    let st:Record<string,unknown>, retainedResult:Record<string,unknown>|undefined;
    try{st = await fetchJson<Record<string, unknown>>(
      PROVIDER, statusUrl.toString(), { method: "GET", headers: falHeaders() }, BUDGETS.pollMs, classifyFal,
    );}catch(error){
      if(!(error instanceof ProviderError)||error.status!==404)throw error;
      const responseUrl=falResponseUrl(ref.poll_url),pair=falLegacyReceipt(ref.poll_url,responseUrl);
      if(!pair||!falLegacyReceiptMatchesModel(ref.model,ref.id,pair))throw new ProviderError(PROVIDER,"validation","The saved provider receipt pair does not match.",0,true);
      // A missing status is not proof the generation failed. Try its exact
      // paired result once; a usable result keeps the normal persist/QC path.
      try{retainedResult=await fetchJson<Record<string,unknown>>(PROVIDER,responseUrl,{method:"GET",headers:falHeaders(),redirect:"error"},BUDGETS.pollMs,classifyFal);}
      catch(resultError){if(resultError instanceof ProviderError&&resultError.status===404)return{status:"running",delivery_issue:{phase:"status_and_result_read",provider:"fal",provider_state:"unavailable",provider_status:404,result_status:404,reason:"not_found"}};throw resultError;}
      st={status:"COMPLETED"};
    }

    const status = String(st.status ?? "");
    if (status === "IN_QUEUE") return { status: "queued" };
    if (status === "IN_PROGRESS") return { status: "running" };

    if (status === "COMPLETED") {
      const failed = falCompletedFailure(st);
      if (failed) return failed;
      const responseUrl = requireHost(
        typeof st.response_url === "string" ? st.response_url : falResponseUrl(ref.poll_url),
        FAL_HOSTS,
        PROVIDER,
      );
      let result: Record<string, unknown>;
      const delivery: { issue: ProviderDeliveryIssue | null } = { issue: null };
      try {
        result = retainedResult ?? await fetchJson<Record<string, unknown>>(
          PROVIDER, responseUrl, { method: "GET", headers: falHeaders() }, BUDGETS.pollMs, (status, body) => { delivery.issue = falResultReadIssue(status, body); return classifyFal(status, body); },
        );
      } catch (error) {
        if (!(error instanceof ProviderError) || !error.status) throw error;
        console.error("fal completed result failed", { provider_status: error.status, error_class: error.error_class, result_reason: delivery.issue?.reason ?? (error.error_class === "nsfw" ? "content_policy" : "unknown") });
        if (delivery.issue) return { status: "running", delivery_issue: delivery.issue };
        // The generation already completed. A temporary result GET failure is
        // recoverable by polling this receipt; it must not invite another POST.
        if (error.status === 408 || error.status === 429 || error.status >= 500) throw error;
        return { status: "failed", error_class: error.error_class, message: "The video service could not return this generation." };
      }
      const resultFailed = falCompletedFailure(result);
      if (resultFailed) return resultFailed;
      // Some fal image models report the safety verdict in the result body.
      const nsfwFlags = (result as { has_nsfw_concepts?: unknown }).has_nsfw_concepts;
      if (Array.isArray(nsfwFlags) && nsfwFlags.some(Boolean)) {
        return { status: "failed", error_class: "nsfw", message: "fal flagged this generation as NSFW" };
      }
      const out = extractResult(result);
      if (!out) {
        return { status: "failed", error_class: "upstream", message: "The service completed without a usable media file." };
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

    const terminalFailure = falCompletedFailure(st);
    if (terminalFailure) return terminalFailure;
    return {
      status: "failed",
      error_class: "upstream",
      message: "The video service could not complete this generation.",
    };
  },

  persist(state: DoneState, r2Key: string) {
    return persistResult(PROVIDER, state, r2Key);
  },
};
