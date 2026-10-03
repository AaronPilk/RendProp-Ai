// Durable, opt-in reflection erasure. All paid attempts have a committed SQL
// receipt before dispatch; an ambiguous submit is never automatically repeated.
import { assert, HttpError, json, readJson } from "../_shared/http.ts";
import { assertFairHousing, GUARDRAILS } from "../_shared/fairhousing.ts";
import {
  BriaError,
  type BriaStage,
  createBriaAdapter,
  readBriaRef,
} from "./bria.ts";
import { probeMP4Duration, probeMP4Timing } from "./mp4duration.ts";

export const ERASE_MODEL = "bria/video/erase/prompt";
export const ERASE_CENTS_PER_SECOND = 14;
export const ERASE_BATCH_CENTS = 240;
export const BRIA_CONSENT = "bria-video-v1";
export const BRIA_MODEL =
  "bria:/v2/video/segment/mask_by_prompt+/v2/video/edit/erase";
export const ERASE_DISCLOSURE =
  "Selected portions of this walkthrough were edited with AI to remove visible people and reflections of the photographer or camera. The unedited walkthrough is provided for comparison.";
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export const ERASE_PROMPT =
  "Remove visible people, including the photographer and people reflected in mirrors or windows, and reflected phones or cameras. Reconstruct only the area they occlude as the empty room or reflection would appear. Do not remove or repair cracks, stains, wear, fixtures, utility infrastructure, architecture, permanent surroundings, or anything visible through a window. Preserve the camera motion, perspective, lighting, timing and audio. " +
  GUARDRAILS;
// Segmentation describes the objects to mask; erase reconstructs only that mask.
export const ERASE_MASK_PROMPT =
  "Visible people, including the photographer and people reflected in mirrors or windows, and reflected phones or cameras. Exclude cracks, stains, wear, fixtures, utility infrastructure, architecture, permanent surroundings, and anything visible through a window. " +
  GUARDRAILS;
type Obj = Record<string, unknown>;
type Context = { orgId: string; userId: string };
type Asset = {
  listing_id: string | null;
  kind: string;
  url: string;
  duration_s: number | null;
  space_type: string | null;
};
type Ref = { request_id: string; status_url: string; response_url: string };
export interface EraseConfig {
  provider: "fal" | "bria" | "disabled";
  maskUnitCostCents?: number;
  eraseUnitCostCents?: number;
  priceVersion?: string;
  outputHosts?: string[];
}
// App Store clients retain fal. Direct Bria is an explicit internal-beta
// selection for an allowlisted actor with the processor acknowledgement. A
// newly saved token never changes selection or an existing job receipt.
export function readEraseConfig(
  env: (name: string) => string | undefined,
  req?: Request,
  ctx?: Context,
): EraseConfig {
  const provider = env("VIDEO_ERASE_PROVIDER")?.trim() || "fal";
  if (provider !== "fal" && provider !== "bria") {
    return { provider: "disabled" };
  }
  const users = (env("BRIA_BETA_USER_IDS") ?? "").split(",").map((id) =>
    id.trim().toLowerCase()
  );
  const beta = env("BRIA_BETA_ENABLED")?.trim() === "true" &&
    req?.headers.get("x-rendprop-ai-consent") === BRIA_CONSENT && !!ctx &&
    users.length > 0 && users.length <= 256 &&
    users.every((id) => UUID.test(id)) &&
    users.includes(ctx.userId.toLowerCase());
  // VIDEO_ERASE_PROVIDER=bria alone cannot turn on direct processing globally.
  if (!beta) return { provider: "fal" };
  const rate = (name: string) => {
    const raw = env(name)?.trim() ?? "";
    return /^\d+(?:\.\d{1,6})?$/.test(raw) ? Number(raw) : NaN;
  };
  return {
    provider: "bria",
    maskUnitCostCents: rate("BRIA_MASK_CENTS_PER_SECOND"),
    eraseUnitCostCents: rate("BRIA_ERASE_CENTS_PER_SECOND"),
    priceVersion: env("BRIA_PRICE_VERSION")?.trim(),
    outputHosts: (env("BRIA_OUTPUT_HOSTS") ?? "").split(",").map((h) =>
      h.trim()
    ).filter(Boolean),
  };
}
export interface EraseDeps {
  rpc(name: string, args: Obj): Promise<{ data: unknown; error: unknown }>;
  resolveAsset(id: string, req: Request): Promise<Asset>;
  fetch(input: string, init: RequestInit): Promise<Response>;
  falKey(): string;
  config?(req: Request, ctx: Context): EraseConfig;
  bria?(config: Obj): ReturnType<typeof createBriaAdapter>;
  persist(
    url: string,
    key: string,
    provider?: "bria",
    config?: Obj,
  ): Promise<string>;
  now?: () => number;
}
function uuid(value: unknown, name: string): string {
  assert(
    typeof value === "string" && UUID.test(value),
    400,
    `${name} must be a UUID`,
  );
  return value.toLowerCase();
}
function object(value: unknown): Obj {
  assert(
    !!value && typeof value === "object" && !Array.isArray(value),
    502,
    "Invalid reflection job response",
    "upstream",
  );
  return value as Obj;
}
function queueUrl(value: unknown, id: string): string {
  assert(
    typeof value === "string",
    502,
    "Provider returned no queue URL",
    "upstream",
  );
  const u = new URL(value);
  assert(
    u.protocol === "https:" && u.hostname === "queue.fal.run" && !u.username &&
      !u.password && !u.hash && u.pathname.startsWith("/bria/") &&
      u.pathname.includes("/requests/" + id),
    502,
    "Invalid provider queue reference",
    "upstream",
  );
  return u.href;
}
function providerRef(value: unknown): Ref {
  const r = object(value), id = String(r.request_id ?? "");
  assert(
    /^[A-Za-z0-9_-]{6,200}$/.test(id),
    502,
    "Invalid provider request id",
    "upstream",
  );
  return {
    request_id: id,
    status_url: queueUrl(r.status_url, id),
    response_url: queueUrl(r.response_url, id),
  };
}
function mediaUrl(value: unknown): string {
  assert(
    typeof value === "string",
    502,
    "Provider returned no video",
    "upstream",
  );
  const u = new URL(value);
  assert(
    u.protocol === "https:" && !u.username && !u.password &&
      (u.hostname === "fal.media" || u.hostname.endsWith(".fal.media")),
    502,
    "Invalid provider video URL",
    "upstream",
  );
  return u.href;
}
export function extractEraseJob(req: Request): string | null {
  const u = new URL(req.url);
  if (u.searchParams.has("erase_job")) {
    return uuid(u.searchParams.get("erase_job"), "erase_job");
  }
  for (const key of ["status_url", "response_url"]) {
    const raw = u.searchParams.get(key);
    if (!raw) continue;
    let nested: URL;
    try {
      nested = new URL(raw);
    } catch {
      continue;
    }
    if (!nested.searchParams.has("erase_job")) continue;
    assert(
      nested.origin === u.origin &&
        nested.pathname.endsWith("/ai-video/status"),
      400,
      "Invalid reflection status link",
    );
    return uuid(nested.searchParams.get("erase_job"), "erase_job");
  }
  return null;
}
export function createEraseHandler(deps: EraseDeps) {
  const now = deps.now ?? Date.now;
  const consent = (req: Request) =>
    req.headers.get("x-rendprop-ai-consent") === BRIA_CONSENT;
  const selectedConfig = (req: Request, ctx: Context) =>
    deps.config?.(req, ctx) ?? { provider: "fal" } as EraseConfig;
  function directConfig(config: EraseConfig): Obj | null {
    const mask = config.maskUnitCostCents, erase = config.eraseUnitCostCents;
    if (
      typeof mask !== "number" || typeof erase !== "number" ||
      !Number.isFinite(mask) ||
      !Number.isFinite(erase) || mask <= 0 || erase <= 0 || mask > 240 ||
      erase > 240 ||
      Math.round(mask * 1e6) / 1e6 !== mask ||
      Math.round(erase * 1e6) / 1e6 !== erase ||
      !config.priceVersion ||
      !/^[A-Za-z0-9_.:-]{1,120}$/.test(config.priceVersion) ||
      !config.outputHosts?.length
    ) return null;
    return {
      mask_unit_cost_cents: mask,
      erase_unit_cost_cents: erase,
      price_version: config.priceVersion,
      output_hosts: [...config.outputHosts],
      consent_version: BRIA_CONSENT,
    };
  }
  function bria(job: Obj) {
    assert(
      deps.bria,
      503,
      "Direct reflection removal is not configured",
      "upstream",
    );
    return deps.bria(object(job.provider_config));
  }
  function stage(job: Obj, name: BriaStage): Obj {
    assert(
      Array.isArray(job.stages),
      503,
      "Reflection stage receipt is unavailable",
      "upstream",
    );
    return object(job.stages.find((s: unknown) => object(s).stage === name));
  }
  function isTerminal(job: Obj) {
    return ["completed", "failed", "uncertain", "cancelled"].includes(
      String(job.state),
    );
  }
  async function rpc(name: string, args: Obj): Promise<Obj> {
    const res = await deps.rpc("video_erase_" + name, args);
    if (res.error) {
      const message = String(
        (res.error as Obj).message ?? "Reflection database is unavailable",
      );
      const match = /RP(400|402|403|404|409|429):\s*(.+)/.exec(message);
      if (match) throw new HttpError(Number(match[1]), match[2]);
      throw new HttpError(
        503,
        "Reflection processing is temporarily unavailable; your saved video is safe",
        "upstream",
      );
    }
    return object(res.data);
  }
  const identity = (ctx: Context) => ({ p_org: ctx.orgId, p_user: ctx.userId });
  async function vendor(
    url: string,
    method = "GET",
    body?: Obj,
  ): Promise<Response> {
    const key = deps.falKey();
    assert(key, 503, "Reflection removal is not configured", "upstream");
    return await deps.fetch(url, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(25000),
      headers: {
        authorization: "Key " + key,
        "content-type": "application/json",
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  }
  function submission(req: Request, j: Obj): Response {
    const url = new URL(req.url);
    url.pathname = url.pathname.replace(/\/declutter$/, "/status");
    url.search = "";
    url.searchParams.set("erase_job", String(j.id));
    return json({
      request_id: j.id,
      batch_id: j.batch_id,
      status_url: url.href,
      response_url: url.href,
      kind: "declutter",
      model_id: j.provider === "bria" ? BRIA_MODEL : ERASE_MODEL,
      disclosure: ERASE_DISCLOSURE,
      provenance: { id: null, recorded: false },
    }, 202);
  }
  function status(j: Obj): Response {
    if (j.state === "completed") {
      return json({
        status: "completed",
        request_id: j.id,
        video_url: j.output_url,
        disclosure: ERASE_DISCLOSURE,
        publishable: false,
      });
    }
    if (["failed", "uncertain", "cancelled"].includes(String(j.state))) {
      return json({
        status: j.state === "cancelled" ? "cancelled" : "failed",
        request_id: j.id,
        error: j.error ??
          (j.state === "cancelled"
            ? "Reflection removal was cancelled"
            : "The provider response could not be confirmed. Your AI clip allowance was returned; no automatic retry was made."),
        allowance_refunded: !!j.allowance_refunded_at,
      });
    }
    return json({ status: "processing", request_id: j.id });
  }
  async function finish(
    id: string,
    state: string,
    ref: Ref | null = null,
    extra: Obj = {},
  ): Promise<Obj> {
    return await rpc("finish", {
      p_job: id,
      p_state: state,
      p_ref: ref,
      ...extra,
    });
  }
  async function finishStage(
    job: Obj,
    name: BriaStage,
    state: string,
    extra: Obj = {},
  ) {
    return await rpc("finish_stage", {
      p_job: job.id,
      p_stage: name,
      p_state: state,
      ...extra,
    });
  }
  async function dispatchDirect(
    job: Obj,
    name: BriaStage,
    videoUrl: string,
  ): Promise<Obj> {
    const adapter = bria(job);
    let ref;
    try {
      const input = { videoUrl, durationSeconds: Number(job.duration_s) };
      ref = name === "mask"
        ? await adapter.submitMask({ ...input, prompt: ERASE_MASK_PROMPT })
        : await adapter.submitErase(
          input,
          String(stage(job, "mask").output_url),
        );
    } catch (error) {
      // Explicit prequeue rejection is the only paid-dispatch outcome that can
      // release this stage's hold. Every ambiguous POST stays fenced forever.
      const noCharge = error instanceof BriaError &&
        ["rejected", "configuration", "invalid"].includes(error.outcome);
      return await finishStage(job, name, noCharge ? "failed" : "uncertain", {
        p_no_charge: noCharge,
      });
    }
    // Saving failure cannot cause a second POST: the admitted stage is durable.
    return await finishStage(job, name, "processing", { p_ref: ref });
  }
  async function directStatus(
    req: Request,
    ctx: Context,
    job: Obj,
  ): Promise<Response> {
    if (!consent(req)) {
      await rpc("cancel", { ...identity(ctx), p_job: job.id, p_batch: null });
      return status(await rpc("get", { ...identity(ctx), p_job: job.id }));
    }
    if (now() - Date.parse(String(job.created_at)) > 30 * 60 * 1000) {
      return status(
        await finish(String(job.id), "failed", null, {
          p_error:
            "Reflection processing exceeded its time limit. Your AI clip allowance was returned.",
        }),
      );
    }
    const adapter = bria(job);
    const erase = stage(job, "erase"), mask = stage(job, "mask");
    const name: BriaStage = erase.state === "pending" ? "mask" : "erase";
    const current = name === "mask" ? mask : erase;
    if (!current.provider_ref) {
      if (
        current.state === "dispatching" &&
        now() - Date.parse(String(current.admitted_at)) > 120000
      ) {
        return status(await finishStage(job, name, "uncertain"));
      }
      return status(job);
    }
    if (current.state !== "completed") {
      let result;
      try {
        result = await adapter.poll(readBriaRef(current.provider_ref), name);
      } catch (error) {
        if (error instanceof BriaError && error.outcome === "invalid") {
          return status(await finishStage(job, name, "failed"));
        }
        throw new HttpError(
          502,
          "The provider status is temporarily unavailable",
          "upstream",
        );
      }
      if (result.status === "processing") return status(job);
      if (result.status === "failed") {
        return status(await finishStage(job, name, "failed"));
      }
      job = await finishStage(job, name, "completed", {
        p_output: result.output_url,
      });
      if (isTerminal(job)) return status(job);
    }
    if (name === "mask") {
      assert(
        adapter.configured(),
        503,
        "Direct reflection removal is temporarily unavailable",
        "upstream",
      );
      // Resolve source under the requesting user's current RLS scope before
      // admission. Revoked membership, deleted media or a cancelled batch stop
      // the second paid stage; this poll can never manufacture a second job.
      const asset = await deps.resolveAsset(String(job.asset_id), req);
      assert(
        asset.kind === "video" && asset.listing_id,
        409,
        "The source clip is no longer available",
      );
      const admitted = await rpc("admit_stage", {
        ...identity(ctx),
        p_job: job.id,
        p_consent: BRIA_CONSENT,
      });
      if (!admitted.dispatch) return status(object(admitted.job));
      return status(
        await dispatchDirect(object(admitted.job), "erase", asset.url),
      );
    }
    const key = `video-reflections/${ctx.orgId}/${job.id}.mp4`;
    const saved = await deps.persist(
      String(stage(job, "erase").output_url),
      key,
      "bria",
      object(job.provider_config),
    );
    return status(
      await finish(String(job.id), "completed", null, {
        p_url: saved,
        p_key: key,
      }),
    );
  }
  return async function handle(
    req: Request,
    ctx: Context,
    action: "submit" | "quote" | "status" | "cancel" | "apply",
    jobId?: string,
  ): Promise<Response> {
    if (action === "quote") {
      const listing = uuid(
        new URL(req.url).searchParams.get("listing_id"),
        "listing_id",
      );
      const quote = await rpc("quote", {
        ...identity(ctx),
        p_listing: listing,
      });
      const config = selectedConfig(req, ctx);
      if (config.provider === "bria") {
        const pinned = directConfig(config);
        quote.unit_cost_cents = pinned
          ? Number(pinned.mask_unit_cost_cents) +
            Number(pinned.erase_unit_cost_cents)
          : 0;
        quote.available = !!quote.available && consent(req) && !!pinned &&
          !!deps.bria?.(pinned).configured();
        quote.provider = "bria";
      } else if (config.provider !== "fal" || !deps.falKey()) {
        quote.available = false;
      }
      return json(quote);
    }
    if (action === "cancel") {
      const body = await readJson<Obj>(req);
      assert(
        (body.request_id == null) !== (body.batch_id == null),
        400,
        "Supply request_id or batch_id",
      );
      return json(
        await rpc("cancel", {
          ...identity(ctx),
          p_job: body.request_id == null
            ? null
            : uuid(body.request_id, "request_id"),
          p_batch: body.batch_id == null
            ? null
            : uuid(body.batch_id, "batch_id"),
        }),
      );
    }
    if (action === "apply") {
      const body = await readJson<Obj>(req);
      const args = {
        ...identity(ctx),
        p_batch: uuid(body.batch_id, "batch_id"),
        p_original: uuid(body.original_asset_id, "original_asset_id"),
        p_altered: uuid(body.altered_asset_id, "altered_asset_id"),
      };
      const check = await rpc("apply", { ...args, p_validate_only: true });
      if (check.provenance) return json(check); // Lost acceptance response: no repeat media work.
      const original = await deps.resolveAsset(args.p_original, req),
        edited = await deps.resolveAsset(args.p_altered, req);
      const [originalSeconds, editedSeconds] = await Promise.all([
        probeMP4Duration(original.url, deps.fetch),
        probeMP4Duration(edited.url, deps.fetch),
      ]);
      assert(
        originalSeconds <= 600 && editedSeconds <= 600 &&
          Math.abs(originalSeconds - editedSeconds) <= 0.15,
        400,
        "Original and edited walkthroughs must match and be no longer than ten minutes",
      );
      assert(
        original.duration_s != null && edited.duration_s != null &&
          Math.abs(originalSeconds - original.duration_s) <= 0.011 &&
          Math.abs(editedSeconds - edited.duration_s) <= 0.011,
        400,
        "Walkthrough duration metadata does not match its video",
      );
      return json(await rpc("apply", args));
    }
    if (action === "submit") {
      const body = await readJson<Obj>(req),
        assetId = uuid(body.asset_id, "asset_id"),
        listingId = uuid(body.listing_id, "listing_id"),
        batchId = uuid(body.batch_id, "batch_id");
      const idem = uuid(req.headers.get("idempotency-key"), "Idempotency-Key");
      assert(
        body.purpose === "reflection_removal",
        400,
        "purpose must be reflection_removal",
      );
      assert(
        body.prompt == null ||
          (typeof body.prompt === "string" && body.prompt.length <= 600),
        400,
        "prompt must be at most 600 characters",
      );
      const canonical = JSON.stringify({
        assetId,
        listingId,
        batchId,
        purpose: "reflection_removal",
        prompt: body.prompt ?? null,
      });
      const hash = [
        ...new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(canonical),
          ),
        ),
      ].map((b) => b.toString(16).padStart(2, "0")).join("");
      const prior = await rpc("existing", {
        ...identity(ctx),
        p_idem: idem,
        p_hash: hash,
      });
      if (prior.job) return submission(req, object(prior.job));
      const asset = await deps.resolveAsset(assetId, req);
      assert(
        asset.listing_id === listingId,
        400,
        "asset_id must belong to listing_id",
      );
      assert(asset.kind === "video", 400, "A video clip is required");
      assert(
        asset.duration_s != null,
        409,
        "Upload must have a probed duration",
        "conflict",
      );
      assert(
        Number.isFinite(asset.duration_s) && asset.duration_s > 0 &&
          asset.duration_s < 5,
        400,
        "Reflection clips must be under five seconds with a positive finite duration",
      );
      if (body.prompt) {
        assertFairHousing(
          String(body.prompt),
          "This erase instruction",
          asset.space_type,
        );
      }
      const config = selectedConfig(req, ctx),
        pinned = config.provider === "bria" ? directConfig(config) : null;
      assert(
        config.provider === "fal"
          ? !!deps.falKey()
          : config.provider === "bria" &&
            consent(req) && !!pinned && !!deps.bria?.(pinned).configured(),
        503,
        "Reflection removal is not configured or its consent and confirmed pricing are unavailable",
        "upstream",
      );
      const timing = await probeMP4Timing(asset.url, deps.fetch),
        probed = timing.duration_s;
      assert(
        probed > 0 && timing.billable_s < 5 &&
          Math.abs(probed - asset.duration_s) <= 0.011,
        400,
        "The uploaded video duration does not match its clip metadata",
      );
      const reserved = await rpc(
          config.provider === "bria" ? "reserve_direct" : "reserve",
          {
            ...identity(ctx),
            p_listing: listingId,
            p_batch: batchId,
            p_asset: assetId,
            p_idem: idem,
            p_hash: hash,
            p_seconds: timing.billable_s,
            ...(pinned ? { p_config: pinned, p_consent: BRIA_CONSENT } : {}),
          },
        ),
        job = object(reserved.job);
      if (!reserved.dispatch) return submission(req, job);
      if (job.provider === "bria") {
        await dispatchDirect(job, "mask", asset.url);
        return submission(req, job);
      }
      let ref: Ref;
      try {
        const response = await vendor(
          "https://queue.fal.run/" + ERASE_MODEL,
          "POST",
          {
            video_url: asset.url,
            prompt: ERASE_PROMPT,
            auto_trim: false,
            preserve_audio: true,
            output_container_and_codec: "mp4_h264",
          },
        );
        if (
          [400, 401, 403, 404, 405, 413, 415, 422, 429].includes(
            response.status,
          )
        ) {
          await response.body?.cancel();
          await finish(String(job.id), "failed", null, {
            p_error: [401, 403].includes(response.status)
              ? "Reflection removal is temporarily unavailable. Your AI clip allowance was returned."
              : "The provider rejected this clip before queueing. Your AI clip allowance was returned.",
            p_no_charge: true,
          });
          return submission(req, job);
        }
        if (!response.ok) throw new Error("Provider submit was not confirmed");
        ref = providerRef(await response.json());
      } catch {
        // Dispatch may have reached the provider. Refund user allowance, retain
        // the cost hold, and never turn an uncertain receipt into a second POST.
        await finish(String(job.id), "uncertain", null, {
          p_error:
            "The provider response could not be confirmed. Your AI clip allowance was returned; no automatic retry was made.",
        });
        return submission(req, job);
      }
      // Failure to save the receipt must not re-dispatch on a client retry.
      await finish(String(job.id), "processing", ref);
      return submission(req, job);
    }
    const id = uuid(jobId ?? extractEraseJob(req), "erase_job");
    let job = await rpc("get", { ...identity(ctx), p_job: id });
    if (
      ["completed", "failed", "uncertain", "cancelled"].includes(
        String(job.state),
      )
    ) return status(job);
    if (job.provider === "bria") return await directStatus(req, ctx, job);
    assert(
      job.provider == null || job.provider === "fal",
      503,
      "Unknown reflection provider",
      "upstream",
    );
    const age = now() - Date.parse(String(job.created_at));
    if (!job.provider_ref) {
      if (age > 120000) {
        job = await finish(id, "uncertain", null, {
          p_error:
            "The provider response could not be recovered. Your AI clip allowance was returned; no automatic retry was made.",
        });
      }
      return status(job);
    }
    const ref = providerRef(job.provider_ref);
    if (age > 30 * 60 * 1000) {
      return status(
        await finish(id, "failed", ref, {
          p_error:
            "Reflection processing exceeded its time limit. Your AI clip allowance was returned.",
        }),
      );
    }
    const response = await vendor(ref.status_url);
    if (!response.ok) {
      throw new HttpError(
        502,
        "The provider status is temporarily unavailable",
        "upstream",
      );
    }
    const state = object(await response.json());
    if (state.status === "IN_QUEUE" || state.status === "IN_PROGRESS") {
      return status(job);
    }
    if (state.status !== "COMPLETED") {
      return status(
        await finish(id, "failed", ref, {
          p_error:
            "Reflection removal failed. Your AI clip allowance was returned.",
        }),
      );
    }
    const result = await vendor(ref.response_url);
    if (!result.ok) {
      return status(
        await finish(id, "failed", ref, {
          p_error:
            "The provider could not deliver the edited clip. Your AI clip allowance was returned.",
        }),
      );
    }
    let output: string;
    try {
      const data = object(await result.json());
      output = mediaUrl(
        typeof data.video === "string" ? data.video : object(data.video).url,
      );
    } catch {
      return status(
        await finish(id, "failed", ref, {
          p_error:
            "The provider returned no usable video. Your AI clip allowance was returned.",
        }),
      );
    }
    const key = `video-reflections/${ctx.orgId}/${id}.mp4`;
    const saved = await deps.persist(output, key);
    // SQL preserves cancellation if it won while download/persistence was active.
    return status(
      await finish(id, "completed", ref, { p_url: saved, p_key: key }),
    );
  };
}
