import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { assert, HttpError, throwRpc } from "./http.ts";

export type Workspace = { id: string; name: string; role: string; access_mode?: "own" | "team_owner";
  library_owner_user_id?: string; billing_org_id?: string; can_read?: boolean; can_write?: boolean };
export type WorkspaceDirectory = { active_org_id: string; workspaces: Workspace[]; actor_id: string;
  own_org_id: string; billing_org_id: string; can_switch_agent_libraries: boolean };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function workspaceID(value: unknown): string {
  assert(typeof value === "string" && UUID.test(value), 400, "Choose a valid workspace.");
  return value.toLowerCase();
}
/** A present, malformed header must not silently become the active default. */
export function requestedWorkspace(req: Request): string | undefined {
  const value = req.headers.get("x-org-id");
  return value === null ? undefined : workspaceID(value);
}
function workspaceError(message?: string): never {
  if (message && /RP\d{3}:/.test(message)) throwRpc(message);
  throw new HttpError(503, "Your workspaces could not be verified. Please retry.", "upstream");
}
/** Service-only SQL validates live membership, deletion and explicit selection.
 * The caller ID is always the verified session's; never read it from a body. */
export async function workspaceDirectory(admin: SupabaseClient, userId: string, preferred?: string): Promise<WorkspaceDirectory> {
  const { data, error } = await admin.rpc("workspace_directory", { p_user: userId, p_preferred_org: preferred ?? null });
  if (error) workspaceError(error.message);
  if (!data || data.actor_id !== userId || typeof data.own_org_id !== "string" || !UUID.test(data.own_org_id) ||
      typeof data.billing_org_id !== "string" || !UUID.test(data.billing_org_id) || typeof data.can_switch_agent_libraries !== "boolean" ||
      typeof data.active_org_id !== "string" || !UUID.test(data.active_org_id) ||
      !Array.isArray(data.workspaces) || !data.workspaces.every((w: Workspace) => w && typeof w.id === "string" && UUID.test(w.id) && typeof w.name === "string" && ["owner","admin","agent","marketing","team_owner"].includes(w.role) &&
      ["own","team_owner"].includes(String(w.access_mode)) && typeof w.library_owner_user_id === "string" && UUID.test(w.library_owner_user_id) &&
      typeof w.billing_org_id === "string" && UUID.test(w.billing_org_id) && w.can_read === true && typeof w.can_write === "boolean" &&
      (w.access_mode !== "own" || w.library_owner_user_id === userId) &&
      (w.access_mode !== "team_owner" || w.role === "team_owner")) ||
      new Set(data.workspaces.map((w: Workspace) => w.id)).size !== data.workspaces.length ||
      data.workspaces.some((w: Workspace & {can_manage_subscription?:unknown}) =>
        (w.access_mode === "team_owner" && (!data.can_switch_agent_libraries || w.can_manage_subscription === true)) ||
        (w.can_manage_subscription !== undefined && typeof w.can_manage_subscription !== "boolean")) ||
      (!data.can_switch_agent_libraries && data.active_org_id !== data.own_org_id) ||
      !data.workspaces.some((w: Workspace) => w.id === data.active_org_id) ||
      (preferred !== undefined && data.active_org_id !== preferred)) workspaceError();
  return data as WorkspaceDirectory;
}
export async function selectWorkspace(admin: SupabaseClient, userId: string, orgId: string): Promise<{ok:true;org_id:string;org_name:string;role:string}> {
  const { data, error } = await admin.rpc("select_workspace", { p_user:userId, p_org:orgId });
  if (error) workspaceError(error.message);
  if (!data || data.actor_id !== userId || data.ok !== true || data.org_id !== orgId || typeof data.org_name !== "string" || !["owner","admin","agent","marketing","team_owner"].includes(data.role)) workspaceError();
  return data;
}
