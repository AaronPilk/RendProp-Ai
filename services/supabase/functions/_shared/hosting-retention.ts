import { assert, HttpError } from "./http.ts";
export type HostingRetention = { org_id: string; policy: "preserved" | "prospective_90_day_grace"; protected: boolean; retention_ends_at: string | null; hosting_available: boolean };
export async function hostingRetention(admin: any, org: string): Promise<HostingRetention> {
  const { data, error } = await admin.rpc("hosting_retention_state", { p_org: org });
  assert(!error && data && data.org_id === org && typeof data.protected === "boolean" && typeof data.hosting_available === "boolean", 503, "Hosting status could not be verified. Please retry.");
  assert(data.policy === "preserved" && data.retention_ends_at === null && data.hosting_available === true || data.policy === "prospective_90_day_grace" && data.protected === false && typeof data.retention_ends_at === "string" && Number.isFinite(Date.parse(data.retention_ends_at)), 503, "Hosting status could not be verified. Please retry.");
  return { org_id: org, policy: data.policy, protected: data.protected, retention_ends_at: data.retention_ends_at, hosting_available: data.hosting_available };
}
export async function assertHostingAvailable(admin: any, org: string): Promise<void> {
  const state = await hostingRetention(admin, org);
  if (!state.hosting_available || state.retention_ends_at !== null && Date.parse(state.retention_ends_at) <= Date.now()) throw new HttpError(404, "This tour is no longer hosted.");
}
/** The notice can be withdrawn by renewal, membership/deletion or QA protection
 * between queuing and send; current SQL authority owns that final decision. */
export async function hostingNoticeCurrent(admin: any, row: { id: string; payload: Record<string, unknown> }): Promise<boolean> {
  if (!Object.hasOwn(row.payload, "hosting_retention")) return true;
  const { data, error } = await admin.rpc("hosting_retention_notice_current", { p_outbox: row.id });
  assert(!error && typeof data === "boolean", 503, "Hosting notice authority could not be verified.");
  return data;
}
