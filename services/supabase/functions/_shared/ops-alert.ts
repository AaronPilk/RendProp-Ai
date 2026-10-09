import { assert } from "./http.ts";
/** Admin alerts (category ops_alert) are queued once per finding per UTC day.
 * Delivery re-checks that the finding is still present and the recipient is
 * still a global admin; ops_alert_current expires the row otherwise. Rows of
 * other categories pass through untouched. */
export async function opsAlertCurrent(admin: any, row: { id: string; category: string }): Promise<boolean> {
  if (row.category !== "ops_alert") return true;
  const { data, error } = await admin.rpc("ops_alert_current", { p_outbox: row.id });
  assert(!error && typeof data === "boolean", 503, "Admin alert currency could not be verified.");
  return data;
}
