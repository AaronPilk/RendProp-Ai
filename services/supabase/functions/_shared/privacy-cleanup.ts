import { HttpError } from "./http.ts";
import { cleanupLegacyGhlTarget } from "./legacy-ghl-cleanup.ts";
import { deleteObjects, R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS, type R2Object } from "./r2.ts";
import { deleteStreamVideo, streamConfigured } from "./stream.ts";
import type { GhlCleanupTarget } from "../me/logic.ts";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Payload = { r2: R2Object[]; stream_uids: string[]; ghl_targets: GhlCleanupTarget[] };
type Operations = { objects: typeof deleteObjects; stream: typeof deleteStreamVideo; crm: typeof cleanupLegacyGhlTarget; streamEnabled: () => boolean };
const defaults: Operations = { objects: (objects, concurrency, cap) => deleteObjects(objects.map(target => ({ ...target, bucket: target.bucket === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS })), concurrency, cap), stream: deleteStreamVideo, crm: cleanupLegacyGhlTarget, streamEnabled: streamConfigured };
// deno-lint-ignore no-explicit-any
export async function sweepPrivacyCleanup(admin: any, operations: Operations = defaults) {
  const { data: due, error } = await admin.rpc("privacy_cleanup_due", {});
  if (error || !Array.isArray(due) || due.length > 5 || due.some(id => typeof id !== "string" || !UUID.test(id)) || new Set(due).size !== due.length) throw new HttpError(503, "Privacy cleanup inventory could not be confirmed.");
  let processed = 0, completed = 0, failed = 0;
  // One owned job per invocation keeps transport deadlines within Edge wall
  // time even when several services are unavailable. SQL retains every rest.
  for (const id of due.slice(0, 1)) {
    const { data: claim, error } = await admin.rpc("privacy_cleanup_claim", { p_id: id });
    if (error) { failed++; continue; } if (claim === null) continue;
    const payload = claim?.payload as Payload;
    if (claim?.id !== id || typeof claim.token !== "string" || !UUID.test(claim.token) || !UUID.test(claim.org_id) ||
      !payload || !Array.isArray(payload.r2) || payload.r2.length > 25000 || payload.r2.some(t => !t || !["uploads", "renders"].includes(t.bucket) || typeof t.key !== "string" || !t.key || t.key.length > 4096) ||
      !Array.isArray(payload.stream_uids) || payload.stream_uids.some(uid => typeof uid !== "string" || !uid || uid.length > 512) ||
      !Array.isArray(payload.ghl_targets) || payload.ghl_targets.some(t => t?.org_id !== claim.org_id || (!t.email && !t.phone))) { failed++; continue; }
    const remaining: Payload = { r2: [], stream_uids: [], ghl_targets: [] }; const notes: string[] = [];
    const batch = payload.r2.slice(0, 8); remaining.r2.push(...payload.r2.slice(8));
    if (batch.length) {
      try { const result = await operations.objects(batch, 4, 8); if (result.errors.length || result.deleted !== batch.length) { remaining.r2.push(...batch); notes.push("Object cleanup remains unconfirmed."); } }
      catch { remaining.r2.push(...batch); notes.push("Object cleanup is temporarily unavailable."); }
    }
    for (const [i, uid] of payload.stream_uids.entries()) {
      if (i >= 2 || !operations.streamEnabled()) { remaining.stream_uids.push(uid); continue; }
      try { if (await operations.stream(uid) !== true) throw new Error("Video deletion acknowledgment missing"); } catch { remaining.stream_uids.push(uid); notes.push("Video cleanup remains unconfirmed."); }
    }
    for (const [i, target] of payload.ghl_targets.entries()) {
      if (i >= 2) { remaining.ghl_targets.push(target); continue; }
      try { const result = await operations.crm(target); if (result.leftover) { remaining.ghl_targets.push(target); notes.push("Legacy CRM ownership needs manual review."); } }
      catch { remaining.ghl_targets.push(target); notes.push("Legacy CRM cleanup remains queued."); }
    }
    const done = !remaining.r2.length && !remaining.stream_uids.length && !remaining.ghl_targets.length;
    const { data: receipt, error: finishError } = await admin.rpc("privacy_cleanup_finish", { p_id: id, p_token: claim.token, p_remaining: remaining, p_notes: notes.join(" ") });
    if (finishError || receipt?.ok !== true || receipt.id !== id || receipt.cleanup_complete !== done) { failed++; continue; }
    processed++; if (done) completed++;
  }
  return { ok: failed === 0, processed, completed, failed };
}
