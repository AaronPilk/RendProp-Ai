import { assert, HttpError, throwRpc } from "../_shared/http.ts";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// The selected workspace and actor come from verified request context. Cleanup
// targets are frozen by SQL before the inquiry/snapshots are removed.
// deno-lint-ignore no-explicit-any
export async function deleteLead(admin: any, user: string, org: string, lead: string) {
  assert(UUID.test(lead), 400, "Choose a valid inquiry.");
  const { data, error } = await admin.rpc("delete_workspace_lead", { p_user: user, p_org: org, p_lead: lead });
  if (error) { if (/RP\d{3}:/.test(error.message ?? "")) throwRpc(error.message); throw new HttpError(503, "Inquiry deletion could not be confirmed. Please retry."); }
  assert(data && data.ok === true && data.deleted === true && data.lead_id === lead && typeof data.cleanup_pending === "boolean", 503, "Inquiry deletion could not be confirmed.");
  return data;
}
