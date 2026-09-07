// me/logic.ts — the pure decision logic behind DELETE /me and its sweeper,
// split out of index.ts so it can be unit-tested (index.ts calls Deno.serve at
// import time and cannot be imported by a test — same split as
// events/schema.ts and apple-subscriptions/logic.ts).
//
// Two audit findings live here:
//
//   P0-4  cleanup_complete must be TRUE only when every destructive step
//         actually finished. payloadEmpty() is the single source of truth for
//         that: index.ts computes `cleanupComplete` from it AFTER every step
//         (including the analytics-forget and profile-row steps, which used to
//         run after the tombstone was already marked completed) has run, never
//         before.
//
//   cross-tenant CRM deletion. GHL_LOCATION_ID is one shared location for every
//   tenant (leads/index.ts), so a contact can only be told apart by its tag —
//   `rendprop_org:<org_id>` (see _shared/ghl.ts). decideGhlTagAction() is the
//   ENTIRE decision of what account deletion may do to a GHL contact: delete
//   it outright only when it carries no OTHER tenant's tag, strip just this
//   tenant's tag when it carries others, and touch nothing at all when this
//   tenant's own tag cannot be confirmed present.

import type { R2Object } from "../_shared/r2.ts";
import { ghlOrgTag, isGhlOrgTag } from "../_shared/ghl.ts";

/** One CRM contact this tenant's deletion still needs to reach, by email. */
export interface GhlCleanupTarget {
  email: string;
  org_id: string;
}

export interface DeletionPayload {
  r2: R2Object[];
  stream_uids: string[];
  ghl_targets: GhlCleanupTarget[];
  apple_refresh_token: string | null;
  /** Set while `app_events` still carries this user's id (Phase 6b, forget-analytics). */
  analytics_user_id?: string | null;
  /** Set while the `profiles` row still needs deleting. */
  profile_id?: string | null;
  /** Row deletions that FAILED and must be retried. Previously these were
   * warnings only, so a failed row delete (or share-link revocation) was never
   * retried while the response still said ok:true — data retained, nobody
   * chasing it (audit round 4). */
  db?: {
    org_ids?: string[];
    listing_ids?: string[];
    render_ids?: string[];
    job_ids?: string[];
    asset_ids?: string[];
  };
}

export function dbEmpty(d: DeletionPayload["db"]): boolean {
  return !d || (!d.org_ids?.length && !d.listing_ids?.length && !d.render_ids?.length &&
    !d.job_ids?.length && !d.asset_ids?.length);
}

/**
 * True only when NOTHING is left for the sweeper: no external object, no CRM
 * contact, no Apple token, no analytics row to forget, no profile row, and no
 * retryable DB write. This is what `cleanup_complete` in the DELETE /me
 * response — and the tombstone's own `completed` status — must be computed
 * from, evaluated AFTER every destructive step has actually run (P0-4).
 */
export function payloadEmpty(p: DeletionPayload): boolean {
  return p.r2.length === 0 && p.stream_uids.length === 0 &&
    p.ghl_targets.length === 0 && !p.apple_refresh_token &&
    !p.analytics_user_id && !p.profile_id && dbEmpty(p.db);
}

export function chunk<T>(items: T[], size = 200): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export type GhlTagAction = "delete" | "untag" | "leftover";

export interface GhlTagDecision {
  action: GhlTagAction;
  /** The tag this tenant owns on the contact (ghlOrgTag(orgId)), regardless of action. */
  tag: string;
  reason: string;
}

/**
 * Decide what account deletion may do to ONE GHL contact that matched this
 * tenant's lead email, given the contact's current tag list.
 *
 *   tags unreadable / not an array   -> "leftover" (never guess; manual cleanup)
 *   this tenant's tag absent         -> "leftover" (never ours to touch)
 *   another tenant's org tag ALSO present -> "untag" (strip only ours, keep the contact)
 *   only this tenant's org tag present    -> "delete" (safe to remove outright)
 *
 * This is the whole fix for the cross-tenant deletion bug: every branch that
 * is not a clean "this contact is unambiguously and only ours" ends in
 * "leftover", never a delete.
 */
export function decideGhlTagAction(tags: unknown, orgId: string): GhlTagDecision {
  const tag = ghlOrgTag(orgId);
  if (!Array.isArray(tags)) {
    return { action: "leftover", tag, reason: "contact's tags could not be read" };
  }
  const normalized = tags.filter((t): t is string => typeof t === "string");
  if (!normalized.includes(tag)) {
    return { action: "leftover", tag, reason: "contact is not tagged for this tenant" };
  }
  const otherTenantTags = normalized.filter((t) => isGhlOrgTag(t) && t !== tag);
  if (otherTenantTags.length > 0) {
    return {
      action: "untag",
      tag,
      reason: `also tagged for ${otherTenantTags.length} other tenant(s): ${otherTenantTags.join(", ")}`,
    };
  }
  return { action: "delete", tag, reason: "only this tenant's tag is present" };
}
