// The DB owns the deletion boundary; Edge executes only a confirmed leased
// snapshot. A transient failure must retain work, never invent an empty one.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError, json, throwRpc } from "../_shared/http.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";
import { payloadEmpty, type DeletionPayload } from "./logic.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const id = (v: unknown): v is string => typeof v === "string" && UUID.test(v);
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
function requireReceipt(ok: unknown): asserts ok {
  if (!ok) throw new HttpError(502, "Deletion was not confirmed; no unverified cleanup was started", "upstream");
}
// An `RPnnn:` message is the SQL boundary refusing the request on purpose and
// keeps its own copy. Anything else — a deadlock, a lock timeout, a missing
// overload, a dropped connection — is the database being unavailable: log it,
// answer 503 "retry", and never echo text that names a function signature or a
// table to the caller (the same split spatial/index.ts makes).
function throwDatabase(message: string | undefined, action: string): never {
  if (/RP\d{3}:/.test(message ?? "")) throwRpc(message);
  console.error(`${action} failed:`, message ?? "(no message)");
  throw new HttpError(503, "Account deletion could not be confirmed — retry", "upstream");
}
type Lease = { request: string; user: string; token: string; payload: DeletionPayload;
  solo: string[]; shared: string[]; manual: boolean };
type Cleanup = (payload: DeletionPayload) => Promise<{ remaining: DeletionPayload; notes: string[] }>;

function lease(raw: unknown, user?: string, request?: string): Lease {
  requireReceipt(object(raw) && raw.ok === true && raw.snapshot_version === 2 && id(raw.request_id) &&
    id(raw.source_user_id) && id(raw.lease_token) && (!user || raw.source_user_id === user) &&
    (!request || raw.request_id === request) && typeof raw.manual_review_required === "boolean");
  const scope = raw.scope, p = raw.payload;
  requireReceipt(object(scope) && scope.source_user_id === raw.source_user_id && scope.db_purged === true && Array.isArray(scope.solo_orgs) &&
    scope.solo_orgs.every(id) && Array.isArray(scope.shared_orgs) && scope.shared_orgs.every(id));
  const solo = scope.solo_orgs;
  const keyTarget = (x: unknown): x is Record<string, unknown> => object(x) &&
    [R2_BUCKET_UPLOADS, R2_BUCKET_RENDERS].includes(x.bucket as string) &&
    typeof x.key === "string" && x.key.length > 0 && x.key.length <= 4096;
  requireReceipt(object(p) && Array.isArray(p.r2) && p.r2.length <= 25000 &&
    p.r2.every(x => object(x) && [R2_BUCKET_UPLOADS, R2_BUCKET_RENDERS].includes(x.bucket as string) &&
      typeof x.key === "string" && x.key.length > 0 && x.key.length <= 4096) &&
    Array.isArray(p.stream_uids) && p.stream_uids.every(x => typeof x === "string" && x.length > 0 && x.length <= 512) &&
    Array.isArray(p.ghl_targets) && p.ghl_targets.every(x => object(x) && id(x.org_id) && solo.includes(x.org_id) &&
      typeof x.email === "string" && x.email.length > 0 && x.email.length <= 512) &&
    (p.apple_refresh_token === null || (typeof p.apple_refresh_token === "string" && p.apple_refresh_token.length <= 16384)));
  requireReceipt(Array.isArray(p.provider_leases) && p.provider_leases.length<=30000 &&
    p.provider_leases.every(x=>object(x)&&id(x.job_id)&&id(x.lease_token)) &&
    Array.isArray(p.multipart_uploads) && p.multipart_uploads.length<=25000 &&
    p.multipart_uploads.every(x=>keyTarget(x)&&typeof x.upload_id==="string"&&x.upload_id.length>0&&x.upload_id.length<=2048) &&
    Array.isArray(p.unresolved_uploads) && p.unresolved_uploads.length<=25000 &&
    p.unresolved_uploads.every(x=>keyTarget(x)&&id(x.operation_id)) &&
    Array.isArray(p.unresolved_render_jobs) && p.unresolved_render_jobs.length<=50000 && p.unresolved_render_jobs.every(id) &&
    (p.storage_not_before===null || (typeof p.storage_not_before==="string"&&Number.isFinite(Date.parse(p.storage_not_before)))));
  for (const key of ["analytics_user_id", "profile_id", "auth_user_id"]) {
    requireReceipt(p[key] === null || p[key] === raw.source_user_id);
  }
  // New snapshots purge DB rows transactionally. Never revive the old sweeper's
  // arbitrary db.ids payload or tolerate unknown cleanup categories silently.
  requireReceipt(Object.keys(p).every(k => ["r2", "stream_uids", "ghl_targets", "apple_refresh_token",
    "analytics_user_id", "profile_id", "auth_user_id", "provider_leases", "multipart_uploads",
    "unresolved_uploads", "storage_not_before", "unresolved_render_jobs"].includes(k)));
  return { request: raw.request_id, user: raw.source_user_id, token: raw.lease_token,
    payload: p as unknown as DeletionPayload, solo: scope.solo_orgs, shared: scope.shared_orgs,
    manual: raw.manual_review_required };
}

async function finish(admin: SupabaseClient, work: Lease, cleanup: Cleanup) {
  const { remaining, notes } = await cleanup(work.payload);
  const { data, error } = await admin.rpc("finish_account_deletion", {
    p_request: work.request, p_token: work.token, p_remaining: remaining,
    p_notes: notes.slice(0, 10).join(" | ").slice(0, 2000),
  });
  if (error) throwDatabase(error.message, "finish_account_deletion");
  requireReceipt(object(data) && data.ok === true && data.request_id === work.request &&
    data.source_user_id === work.user && typeof data.cleanup_complete === "boolean" &&
    typeof data.manual_review_required === "boolean" &&
    (data.escalation_reason == null || typeof data.escalation_reason === "string"));
  requireReceipt(!data.cleanup_complete || (payloadEmpty(remaining) && !data.manual_review_required));
  // The DB parks a request that no sweep can finish (twelve passes without
  // progress, or a GPU lease with no provider journal a day later) and says
  // why. It leaves the due queue at that point; surface the reason instead
  // of silently dropping the account from the sweep.
  const escalation = typeof data.escalation_reason === "string" ? data.escalation_reason : null;
  const authGone = !remaining.auth_user_id;
  return { remaining, notes, authGone, done: data.cleanup_complete, manual: data.manual_review_required, escalation };
}

export async function deleteAccount(admin: SupabaseClient, user: string, cleanup: Cleanup): Promise<Response> {
  const { data, error } = await admin.rpc("prepare_account_deletion", {
    p_user: user, p_upload_bucket: R2_BUCKET_UPLOADS, p_render_bucket: R2_BUCKET_RENDERS,
  });
  if (error) throwDatabase(error.message, "prepare_account_deletion");
  const work = lease(data, user);
  const result = await finish(admin, work, cleanup);
  const warnings = [...result.notes, ...(result.escalation ? [`escalated for manual review: ${result.escalation}`] : [])];
  return json({ ok: result.authGone, deletion_request_id: work.request,
    deleted_orgs: work.solo.length, left_orgs: work.shared.length,
    cleanup_complete: result.done, manual_review_required: result.manual,
    pending: { r2_objects: result.remaining.r2.length, stream_videos: result.remaining.stream_uids.length,
      crm_contacts: result.remaining.ghl_targets.length, apple_revocation: !!result.remaining.apple_refresh_token,
      analytics_cleanup: !!result.remaining.analytics_user_id, profile_row: !!result.remaining.profile_id,
      auth_user: !!result.remaining.auth_user_id, gpu_attempts: result.remaining.provider_leases?.length ?? 0,
      multipart_uploads: result.remaining.multipart_uploads?.length ?? 0,
      unverified_uploads: result.remaining.unresolved_uploads?.length ?? 0,
      unverified_render_jobs: result.remaining.unresolved_render_jobs?.length ?? 0,
      waiting_for_storage_writes: !!result.remaining.storage_not_before },
    ...(!result.authGone ? { error: "The sign-in record could not be deleted; cleanup remains queued." } : {}),
    ...(warnings.length ? { warnings } : {}),
  }, result.authGone ? 200 : 500);
}

export async function sweepAccounts(admin: SupabaseClient, cleanup: Cleanup): Promise<Response> {
  // Backoff belongs to each request, not the first five oldest accounts. An
  // unresolved provider must not starve all newer users' deletion requests.
  // A request the DB has parked for manual review is not due any more: the
  // filter below is what ends its five-minute loop, and the DB row records
  // the reason (escalation_reason) for whoever picks it up.
  const due = new Date().toISOString();
  const { data: rows, error } = await admin.from("deletion_requests").select("id")
    .eq("manual_review_required", false)
    .in("status", ["pending", "processing"]).lte("next_cleanup_at", due)
    .order("next_cleanup_at", { ascending: true }).limit(5);
  if (error) throw new HttpError(503, "Deletion queue is temporarily unavailable", "upstream");
  let processed = 0, manual = 0, deferred = 0, escalated = 0;
  for (const row of rows ?? []) {
    requireReceipt(id(row.id));
    const { data, error: claimError } = await admin.rpc("claim_account_deletion", { p_request: row.id });
    if (claimError) { deferred++; continue; } // busy/outage leaves exact durable payload untouched
    if (object(data) && data.ok === false && data.request_id === row.id && data.manual_review_required === true) {
      manual++; continue;
    }
    if (object(data) && data.ok === false && data.request_id === row.id && data.completed === true) continue;
    const work = lease(data, undefined, row.id);
    const result = await finish(admin, work, cleanup);
    processed++;
    if (result.escalation) {
      escalated++;
      console.warn(`deletion request ${row.id} escalated for manual review: ${result.escalation}`);
    }
  }
  return json({ ok: true, processed, manual_review: manual, deferred, escalated });
}
