import type { StudioContext } from "./context.ts";
import { assert, HttpError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS, deleteObject, presignPut } from "../_shared/r2.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { cancelHfMotionTransfer, estimateHfMotionTransfer, pollHfMotionTransfer, submitHfMotionTransfer } from "../_shared/providers/higgsfield.ts";
import { presenterRpcError } from "./presenter.ts";
import { mediaBytes, PRESENTER_VIDEO_BYTES, sha256 } from "./presenter-media.ts";
import { type PresenterExecutionDeps, type PresenterObject } from "./presenter-execution.ts";

function record(value: unknown): PresenterObject { assert(!!value && typeof value === "object" && !Array.isArray(value), 503, "Presenter service response could not be read."); return value as PresenterObject; }
function outputHosts(): string[] { return (Deno.env.get("PRESENTER_OUTPUT_HOSTS") ?? "").split(",").map((s) => s.trim()).filter(Boolean); }
export function presenterLiveConfigured(): boolean {
  return Deno.env.get("PRESENTER_EXECUTION_ENABLED") === "true" && !!Deno.env.get("HIGGSFIELD_API_KEY_ID")?.trim() && !!Deno.env.get("HIGGSFIELD_API_KEY_SECRET")?.trim() &&
    outputHosts().length > 0 && outputHosts().every((host) => /^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}$/.test(host));
}

/** All provider refs and bucket paths originate in service-only SQL. Nothing
 * from the browser can choose a provider, price, prompt, source URL or R2 key. */
export function presenterProduction(req?: Request, context?: StudioContext): PresenterExecutionDeps {
  const admin = context?.admin ?? adminClient();
  async function rpc(name: string, args: PresenterObject) {
    // Do not attach the browser's abort signal to durable writes: a disconnect
    // cannot make an accepted paid POST eligible for another submission.
    const result = await admin.rpc(name, args);
    presenterRpcError(result.error);
    return record(result.data);
  }
  return {
    user(action, listing, payload) {
      assert(context, 403, "A signed-in workspace is required.");
      return rpc("studio_presenter_execution", { p_actor: context.userId, p_org_id: context.orgId, p_listing_id: listing, p_action: action, p_payload: payload });
    },
    worker(job, action, payload = {}) { return rpc("studio_presenter_execution_worker", { p_job_id: job, p_action: action, p_payload: payload }); },
    liveConfigured: presenterLiveConfigured,
    sign: (key, seconds) => presignGet(R2_BUCKET_UPLOADS, key, seconds),
    fetch: (url, init) => fetch(url, init),
    estimate: estimateHfMotionTransfer,
    submit: submitHfMotionTransfer,
    poll: pollHfMotionTransfer,
    cancel: cancelHfMotionTransfer,
    outputHosts,
    async put(key, bytes, deadline) {
      const remaining = Date.parse(deadline) - Date.now();
      assert(remaining > 5000 && remaining <= 300_000, 409, "The private output write lease expired.");
      // The URL and HTTP request both expire before the ledger's cleanup grace.
      const signed = await presignPut({ bucket: R2_BUCKET_UPLOADS, key, expiresIn: Math.max(1, Math.floor(remaining / 1000) - 1), contentType: "video/mp4" });
      const response = await fetch(signed, { method: "PUT", headers: { "content-type": "video/mp4", "if-none-match": "*" }, body: bytes, redirect: "error", signal: AbortSignal.timeout(Math.min(120_000, remaining - 1000)) });
      await response.body?.cancel();
      assert(response.ok || response.status === 412, 502, "The private generated video could not be saved.");
      // Replaying a storage step never replaces an existing private result. A
      // lost PUT response is recovered only when its actual bytes are identical.
      const stored = await mediaBytes(await fetch(await presignGet(R2_BUCKET_UPLOADS, key, 120), { redirect: "error", signal: AbortSignal.timeout(60_000) }), PRESENTER_VIDEO_BYTES);
      assert(stored.length === bytes.length && await sha256(stored) === await sha256(bytes), 409, "Private presenter output integrity verification failed.");
    },
    async remove(key, bucket) { await deleteObject(bucket === "uploads" ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS, key); },
    uploadOrigin: () => Deno.env.get("UPLOAD_GATEWAY_ORIGIN")?.trim() || "https://uploads.rendprop.com",
    async upload(path, body, requestKey) {
      assert(req && context && /^uploads(?:\/[a-f0-9-]{36}\/(?:renew|complete))?$/.test(path), 403, "A signed-in import request is required.");
      const base = Deno.env.get("SUPABASE_URL")?.replace(/\/+$/, "");
      assert(base, 503, "Presenter imports are not configured.");
      const headers = new Headers({ authorization: req.headers.get("authorization") ?? "", "X-Org-Id": context.orgId, "content-type": "application/json" });
      const apikey = req.headers.get("apikey"); if (apikey) headers.set("apikey", apikey);
      if (requestKey) headers.set("Idempotency-Key", requestKey);
      const response = await fetch(`${base}/functions/v1/${path}`, { method: "POST", headers, body: JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(90_000) });
      if (!response.ok) { await response.body?.cancel(); throw new HttpError(response.status, "Presenter import could not finish. Refresh this job before retrying."); }
      const bytes = await mediaBytes(response, 128 * 1024);
      try { return record(JSON.parse(new TextDecoder().decode(bytes))); } catch { throw new HttpError(502, "The presenter upload service returned an unreadable response."); }
    },
  };
}
