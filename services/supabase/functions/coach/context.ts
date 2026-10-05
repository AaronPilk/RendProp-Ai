import { HttpError } from "../_shared/http.ts";
import type { Entitlement } from "../_shared/entitlements.ts";
import type { CoachListingCtx } from "./prompt.ts";

const ROLES = new Set(["owner", "admin", "agent", "marketing"]);
const STATES = new Set(["draft", "capturing", "uploading", "processing", "ready", "expired", "archived"]);
const METERS = { photo_edits: "aiphotomo", reels: "reelmo", aerials: "aerialmo", drone: "dronemo" };
const CAP_FIELDS = { renders: "renders_per_month", photo_edits: "photo_edits_per_month", reels: "reels_per_month", aerials: "aerials_per_month", drone: "topaz_per_month" } as const;

export interface CoachAccount {
  available: boolean;
  role: string;
  plan_source: string | null;
  access_until: string | null;
  can_manage_subscription: boolean;
  renewal: "on" | "off" | "unknown";
  subscription_status: "active" | "grace" | null;
  projects: number | null;
  new_leads: number | null;
  usage: Record<string, { used: number | null; cap: number | null; resets_at: string | null }>;
}

function date(raw: unknown): string | null {
  if (typeof raw !== "string" || !Number.isFinite(Date.parse(raw))) return null;
  return new Date(raw).toISOString();
}
function count(raw: unknown): number | null {
  return typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 0 ? raw : null;
}

/** Only selected-workspace counts, closed states and billing dates. Never read
 * profiles, addresses, leads content, raw job errors, receipts or provider keys.
 * The caller client retains RLS; service queries have explicit org predicates. */
export async function coachContext(
  // deno-lint-ignore no-explicit-any
  db: any,
  // deno-lint-ignore no-explicit-any
  admin: any,
  user: string,
  org: string,
  entitlement: Entitlement | null,
  hints: CoachListingCtx[],
  selected: string | null,
  now = new Date(),
): Promise<{ account: CoachAccount; listings: CoachListingCtx[]; selectedListingId: string | null }> {
  const month = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
  const nextMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString();
  const [workspace, membership, projects, leads, listings, meters, renders, subscription] = await Promise.all([
    db.from("orgs").select("plan_source,plan_expires_at,trial_ends_at,deleted_at").eq("id", org).is("deleted_at", null).maybeSingle(),
    admin.from("memberships").select("role").eq("user_id", user).eq("org_id", org).maybeSingle(),
    db.from("listings").select("id", { count: "exact", head: true }).eq("org_id", org).is("deleted_at", null),
    db.from("leads").select("id", { count: "exact", head: true }).eq("org_id", org).eq("status", "new"),
    hints.some((l) => !l.localDraft) ? db.from("listings").select("id,status").eq("org_id", org).is("deleted_at", null).in("id", hints.filter((l) => !l.localDraft).map((l) => l.serverID ?? l.id)).limit(25) : { data: [], error: null },
    admin.from("rate_limits").select("key,count,window_start,window_seconds").in("key", Object.values(METERS).map((key) => `${key}:${org}`)),
    admin.from("render_jobs").select("id,listings!inner(org_id)", { count: "exact", head: true }).eq("listings.org_id", org).eq("source", "worker").gte("created_at", month),
    entitlement && !entitlement.degraded && entitlement.plan !== "free"
      ? admin.from("apple_subscriptions").select("status,auto_renew,expires_at").eq("org_id", org).eq("plan", entitlement.plan).in("status", ["active", "grace"]).order("expires_at", { ascending: false }).limit(1).maybeSingle()
      : { data: null, error: null },
  ]);
  if (workspace.error || membership.error) throw new HttpError(503, "Workspace context could not be verified. Please retry.", "upstream");
  if (!workspace.data || !membership.data || !ROLES.has(membership.data.role)) throw new HttpError(403, "This workspace is no longer available.", "forbidden");
  const planAvailable = !!entitlement && !entitlement.degraded;
  const role = membership.data.role as string;
  const source = ["apple", "manual", "trial"].includes(workspace.data.plan_source) ? workspace.data.plan_source : null;
  const usage: CoachAccount["usage"] = {};
  for (const [feature, field] of Object.entries(CAP_FIELDS)) {
    const cap = planAvailable ? count(entitlement![field as keyof Entitlement]) : null;
    if (feature === "renders") {
      usage[feature] = { used: renders.error ? null : count(renders.count), cap, resets_at: nextMonth };
      continue;
    }
    const key = METERS[feature as keyof typeof METERS];
    const row = meters.error ? null : (meters.data ?? []).find((r: { key: string }) => r.key === `${key}:${org}`);
    const start = date(row?.window_start);
    const seconds = count(row?.window_seconds);
    const end = start && seconds ? new Date(Date.parse(start) + seconds * 1000).toISOString() : null;
    const active = end && Date.parse(end) > now.getTime();
    const used = active ? count(row?.count) : row && (!start || !seconds) ? null : 0;
    usage[feature] = { used: meters.error ? null : used !== null && cap !== null && cap > 0 ? Math.min(used, cap) : used, cap, resets_at: active ? end : null };
  }
  const sub = !subscription.error && source === "apple" ? subscription.data : null;
  const state = sub && ["active", "grace"].includes(sub.status) ? sub.status : null;
  const authorized = new Map((listings.error ? [] : listings.data ?? []).map((row: { id: string; status: string }) => [row.id.toLowerCase(), row.status]));
  const verified = hints.filter((l) => l.localDraft || authorized.has(l.serverID ?? l.id)).map((l) => ({ ...l, status: STATES.has(String(authorized.get(l.serverID ?? l.id))) ? String(authorized.get(l.serverID ?? l.id)) : null }));
  return {
    account: {
      available: planAvailable,
      role,
      plan_source: source,
      access_until: date(source === "trial" ? workspace.data.trial_ends_at : workspace.data.plan_expires_at),
      can_manage_subscription: planAvailable && ["owner", "admin"].includes(role) && source !== "manual" && entitlement!.plan !== "brokerage",
      renewal: sub?.auto_renew === true ? "on" : sub?.auto_renew === false ? "off" : "unknown",
      subscription_status: state,
      projects: projects.error ? null : count(projects.count),
      new_leads: leads.error ? null : count(leads.count),
      usage,
    },
    listings: verified,
    selectedListingId: selected && verified.some((l) => l.id === selected) ? selected : null,
  };
}
