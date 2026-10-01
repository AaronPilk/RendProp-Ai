// Durable, opt-in reflection erasure. All paid attempts have a committed SQL
// receipt before dispatch; an ambiguous submit is never automatically repeated.
import { assert, HttpError, json, readJson } from "../_shared/http.ts";
import { assertFairHousing, GUARDRAILS } from "../_shared/fairhousing.ts";
import { probeMP4Duration, probeMP4Timing } from "./mp4duration.ts";

export const ERASE_MODEL = "bria/video/erase/prompt";
export const ERASE_CENTS_PER_SECOND = 14;
export const ERASE_BATCH_CENTS = 240;
export const ERASE_DISCLOSURE =
  "Selected portions of this walkthrough were edited with AI to remove visible people and reflections of the photographer or camera. The unedited walkthrough is provided for comparison.";
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export const ERASE_PROMPT =
  "Remove visible people, including the photographer and people reflected in mirrors or windows, and reflected phones or cameras. Reconstruct only the area they occlude as the empty room or reflection would appear. Do not remove or repair cracks, stains, wear, fixtures, utility infrastructure, architecture, permanent surroundings, or anything visible through a window. Preserve the camera motion, perspective, lighting, timing and audio. " +
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
export interface EraseDeps {
  rpc(name: string, args: Obj): Promise<{ data: unknown; error: unknown }>;
  resolveAsset(id: string, req: Request): Promise<Asset>;
  fetch(input: string, init: RequestInit): Promise<Response>;
  falKey(): string;
  persist(url: string, key: string): Promise<string>;
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
      model_id: ERASE_MODEL,
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
      if (!deps.falKey()) quote.available = false;
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
      assert(
        deps.falKey(),
        503,
        "Reflection removal is not configured",
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
      const reserved = await rpc("reserve", {
          ...identity(ctx),
          p_listing: listingId,
          p_batch: batchId,
          p_asset: assetId,
          p_idem: idem,
          p_hash: hash,
          p_seconds: timing.billable_s,
        }),
        job = object(reserved.job);
      if (!reserved.dispatch) return submission(req, job);
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
