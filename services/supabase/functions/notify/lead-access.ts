import { HttpError } from "../_shared/http.ts";
import type { OutboxRow } from "./deliver.ts";

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
type Reader = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
};

/** A queued buyer alert is private even after the original insert succeeds.
 * Team access or the listing may be removed before the notification drains. */
export async function leadNoticeCurrent(db: Reader, row: OutboxRow): Promise<boolean> {
  if (row.category !== "lead_received") return true;
  const data = row.payload?.data;
  const facts = data && typeof data === "object" && !Array.isArray(data)
    ? data as Record<string, unknown>
    : null;
  const actor = row.user_id;
  const lead = facts?.lead_id;
  const listing = facts?.listing_id;
  if (!actor || !row.org_id || typeof lead !== "string" || typeof listing !== "string" ||
      !UUID.test(actor) || !UUID.test(row.org_id) || !UUID.test(lead) || !UUID.test(listing)) return false;

  const { data: scope, error } = await db.rpc("lead_library_scope", {
    p_actor: actor,
    p_lead: lead,
  });
  if (error) {
    const message = error && typeof error === "object" ? (error as { message?: unknown }).message : null;
    if (typeof message === "string" && /\bRP40[34]:/.test(message)) return false;
    throw new HttpError(503, "Current inquiry notification access could not be verified.");
  }
  const current = scope && typeof scope === "object" && !Array.isArray(scope)
    ? scope as Record<string, unknown>
    : null;
  return current?.actor_id === actor && current.lead_id === lead &&
    current.listing_id === listing && current.org_id === row.org_id &&
    current.can_read === true;
}
