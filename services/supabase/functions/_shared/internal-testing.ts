import { HttpError } from "./http.ts";
import type { adminClient } from "./supabase.ts";

type Admin = ReturnType<typeof adminClient>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type PrivateTestingContext = {
  active: true;
  sponsor_org_id: string;
  sponsor_org_name: string;
  private_org_id: string;
  beneficiary_user_id: string;
  plan: "team";
  source: "manual";
  unmetered_business_allowances: true;
};

export type PrivateTestingMember = {
  user_id: string;
  role: "agent";
  name: string | null;
  email: string | null;
  private_testing: true;
  benefits_active: boolean;
  joined_at: string;
};

export type PrivateTestingHostMode = { configured: true; active: boolean; access_mode: "private_testing" };

function unavailable(): never {
  throw new HttpError(503, "Testing team access could not be verified. Please retry.", "upstream");
}

/** Identity comes from verified Auth and the selected resource workspace.
 * Sponsorship never selects a workspace or supplies listing permissions. */
export async function privateTestingContext(admin: Admin, userId: string, orgId: string): Promise<PrivateTestingContext | null> {
  const { data, error } = await admin.rpc("private_internal_testing_context", { p_user: userId, p_private_org: orgId });
  if (error) unavailable();
  if (data === null) return null;
  if (!data || typeof data !== "object" || Array.isArray(data) || data.active !== true ||
      data.private_org_id !== orgId || data.beneficiary_user_id !== userId ||
      typeof data.sponsor_org_id !== "string" || !UUID.test(data.sponsor_org_id) || data.sponsor_org_id === orgId ||
      typeof data.sponsor_org_name !== "string" || data.plan !== "team" || data.source !== "manual" ||
      data.unmetered_business_allowances !== true) unavailable();
  return data as PrivateTestingContext;
}

/** The master grant is distinct from a beneficiary's private access. */
export async function masterTestingAccess(admin: Admin, orgId: string): Promise<boolean> {
  const { data, error } = await admin.rpc("org_has_internal_testing_grant", { p_org: orgId });
  if (error || typeof data !== "boolean") unavailable();
  return data;
}

/** Privacy mode survives expiry; expiry must never turn a private invite into
 * permission to read the sponsor's projects. */
export async function privateTestingHostMode(admin: Admin, actor: string, orgId: string): Promise<PrivateTestingHostMode | null> {
  const { data, error } = await admin.rpc("private_internal_testing_host_mode", { p_actor: actor, p_org: orgId });
  if (error) unavailable();
  if (data === null || data?.configured === false) return null;
  if (!data || data.configured !== true || typeof data.active !== "boolean" || data.access_mode !== "private_testing") unavailable();
  return { configured: true, active: data.active, access_mode: "private_testing" };
}

/** A service-only RPC rechecks the manager, and returns roster metadata only. */
export async function privateTestingMembers(admin: Admin, actor: string, sponsorOrg: string): Promise<PrivateTestingMember[]> {
  const { data, error } = await admin.rpc("private_internal_testing_members", { p_actor: actor, p_sponsor_org: sponsorOrg });
  if (error || !Array.isArray(data)) unavailable();
  const seen = new Set<string>();
  for (const member of data) {
    if (!member || typeof member !== "object" || typeof member.user_id !== "string" || !UUID.test(member.user_id) ||
        member.role !== "agent" || member.private_testing !== true || typeof member.benefits_active !== "boolean" ||
        typeof member.joined_at !== "string" || (member.name !== null && typeof member.name !== "string") ||
        (member.email !== null && typeof member.email !== "string") || seen.has(member.user_id)) unavailable();
    seen.add(member.user_id);
  }
  return data as PrivateTestingMember[];
}
