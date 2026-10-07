import { assert, HttpError } from "../_shared/http.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
/** A purchase started for one workspace must not follow a later active-org switch. */
export function assertExpectedSubscriptionWorkspace(expected: unknown, actual: string): void {
  if (expected === undefined) return; // Older builds do not send the binding.
  assert(typeof expected === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(expected), 400, "Choose a valid subscription workspace.");
  assert(expected.toLowerCase() === actual.toLowerCase(), 409, "Your active workspace changed. Restore this purchase in the workspace you selected.");
}

/** Apple keeps the original account token after a guest workspace is adopted.
 * Only the existing, exact database transfer receipt can authorize that alias.
 * A shared team membership alone is never enough to claim another user's JWS. */
export async function assertVerifiedPurchaseOwner(
  accountToken: string | null, userId: string, orgId: string, admin: SupabaseClient,
): Promise<void> {
  if (accountToken === null || accountToken.toLowerCase() === userId.toLowerCase()) return;
  const denied = () => new HttpError(403, "That purchase belongs to a different Rendprop account. Sign in with the account that bought it, or use Restore Purchases there.", "forbidden");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(accountToken)) throw denied();
  const source = accountToken.toLowerCase(), destination = userId.toLowerCase(), org = orgId.toLowerCase();
  const { data, error } = await admin.from("anonymous_adoption_receipts")
    .select("operation_id,source_user_id,destination_user_id,org_id")
    .eq("source_user_id", source).eq("destination_user_id", destination).eq("org_id", org).maybeSingle();
  if (error) throw new HttpError(503, "Purchase ownership could not be verified. Please retry.", "upstream");
  if (!data || data.source_user_id !== source || data.destination_user_id !== destination || data.org_id !== org ||
      typeof data.operation_id !== "string") throw denied();
  // The existing RPC also refuses revoked membership, deleted workspaces and
  // pending account deletion. A historical receipt alone cannot restore access.
  const result = await admin.rpc("adoption_receipt", {p_user:destination,p_anon_user:source,p_operation:data.operation_id});
  if (result.error) {
    if (/RP4\d\d:/.test(result.error.message ?? "")) throw denied();
    throw new HttpError(503, "Purchase ownership could not be verified. Please retry.", "upstream");
  }
  const receipt = result.data;
  if (!receipt || receipt.ok !== true || receipt.adopted !== true || receipt.operation_id !== data.operation_id ||
      receipt.source_user_id !== source || receipt.destination_user_id !== destination || receipt.org_id !== org) throw denied();
}
