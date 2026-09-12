// Plan entitlements — read from the DATABASE, never hardcoded per function.
//
// Every allowance lives in one table (public.plan_entitlements, migration 0010;
// sizes reworked by 0044 on 2026-09-12) so the numbers the code enforces and
// the numbers rendprop.com/pricing advertises can't drift apart. That drift is
// exactly what the round-4 audit caught: the site sold 2/5/15 renders while
// the backend allowed 20/100/400. tests/invariants.sql asserts the table equals
// the pricing page.
//
// Since 0044 the TRIAL is industry-aware: an org whose `orgs.space_type` is a
// single-location business (venue, restaurant, retail, fitness, other) gets a
// 1-tour free week from public.plan_entitlement_overrides, while real estate
// keeps the 3-tour base row. Paid plans and free are not industry-aware. The
// database resolves all of that in ONE function, org_entitlement(org) —
// effective_plan() (an expired trial is `free`) + the base row + the override
// — and it is the same function create_render_job() and log_job_cost() read,
// so what this helper returns is what the charge paths enforce.
//
// The allowances are sized from MEASURED unit costs (see
// services/pipeline/providers/costs.py and docs/AI-COST-MODEL.md):
//   tour render (90s server encode) .. $0.0075   <- the cheap unit
//   AI photo edit ................... $0.039
//   reel clip (Seedance 5s) ......... $0.24
//   AI aerial (Veo 3.1 Fast 8s) ..... $0.80      <- 3x a reel, meter it
//   Topaz drone glide (90s 1080p60) . $3.60      <- add-on only, never bundled
//
// A per-org monthly COGS ceiling (also in the table) is enforced inside
// log_job_cost() as the hard backstop, so an allowance mistake can't become an
// unbounded bill.

import { HttpError } from "./http.ts";
import { adminClient } from "./supabase.ts";

export interface Entitlement {
  plan: string;
  renders_per_month: number;
  photo_edits_per_month: number;
  reels_per_month: number;
  aerials_per_month: number;
  topaz_per_month: number;
  seats: number;
  cogs_ceiling_cents: number;
  price_cents: number;
  /** true when the lookup failed and these are the fail-closed fallback numbers.
   *  Guards turn this into a 503 (F-E-02 / F-supabase-34): a missing table must
   *  masquerade neither as a plan boundary nor as a Team-sized budget. */
  degraded?: boolean;
}

/** Conservative fallback if the table is unreachable: the (real-estate) trial
 *  allowance as 0032 seeds it. Fail CLOSED — a lookup failure must never hand
 *  out a Team-sized budget. Callers on a charge path 503 on `degraded` anyway
 *  (entitlementForCharge), so these numbers only ever reach a display. */
const TRIAL_FALLBACK: Entitlement = {
  plan: "trial",
  renders_per_month: 3,
  photo_edits_per_month: 60,
  reels_per_month: 4,
  aerials_per_month: 2,
  topaz_per_month: 1,
  seats: 1,
  cogs_ceiling_cents: 1200,
  price_cents: 0,
};

const NUMERIC_FIELDS = [
  "renders_per_month", "photo_edits_per_month", "reels_per_month", "aerials_per_month",
  "topaz_per_month", "seats", "cogs_ceiling_cents", "price_cents",
] as const;

/** Shape a plan_entitlements row (from the table or from org_entitlement())
 *  into an Entitlement, or null when it is not one. PostgREST returns a
 *  non-SETOF composite as one object; a one-element array is accepted too. */
function entitlementRow(raw: unknown): Entitlement | null {
  const row = Array.isArray(raw) ? raw[0] : raw;
  if (!row || typeof row !== "object") return null;
  const r = row as Record<string, unknown>;
  if (typeof r.plan !== "string" || r.plan === "") return null;
  const out: Record<string, unknown> = { plan: r.plan };
  for (const f of NUMERIC_FIELDS) {
    const n = Number(r[f]);
    if (!Number.isFinite(n)) return null;
    out[f] = n;
  }
  return out as unknown as Entitlement;
}

/** PostgREST's "no such function" (PGRST202: not in the schema cache) or
 *  Postgres's own 42883 (undefined_function): migration 0044 is not applied
 *  to this database yet. Anything else is a real failure. */
function isMissingFunction(err: { code?: string; message?: string }): boolean {
  if (err.code === "PGRST202" || err.code === "42883") return true;
  return /could not find the function|function .* does not exist/i.test(err.message ?? "");
}

/**
 * The allowances an org is actually entitled to right now.
 *
 * Reads org_entitlement() (migration 0044): effective_plan(), so an EXPIRED
 * trial silently drops to `free` — a lapsed card can't keep spending — with
 * the org's industry override applied. While 0044 is not yet deployed the
 * RPC is missing (PGRST202 / 42883) and this falls back to the pre-0044 path,
 * effective_plan() + the plan_entitlements row, so a function deployed ahead
 * of the migration serves the plan-only numbers instead of a 503.
 */
export async function entitlementFor(orgId: string): Promise<Entitlement> {
  const admin = adminClient();

  const { data, error } = await admin.rpc("org_entitlement", { p_org: orgId });
  if (!error) {
    const ent = entitlementRow(data);
    if (ent) return ent;
    console.error("org_entitlement returned no usable row, falling back to trial");
    return { ...TRIAL_FALLBACK, degraded: true };
  }
  if (!isMissingFunction(error)) {
    console.error("org_entitlement lookup failed, falling back to trial:", error.message);
    return { ...TRIAL_FALLBACK, degraded: true };
  }
  console.warn("org_entitlement is not deployed yet (migration 0044); using the plan-only lookup");
  return await planOnlyEntitlementFor(orgId);
}

/** The pre-0044 lookup: effective_plan() then the plan_entitlements row. Not
 *  industry-aware. Kept only as the deploy-order fallback above. */
async function planOnlyEntitlementFor(orgId: string): Promise<Entitlement> {
  const admin = adminClient();

  const { data: planRow, error: pErr } = await admin
    .rpc("effective_plan", { p_org: orgId });
  if (pErr) {
    console.error("effective_plan lookup failed, falling back to trial:", pErr.message);
    return { ...TRIAL_FALLBACK, degraded: true };
  }
  const plan = String(planRow ?? "trial");

  const { data, error } = await admin
    .from("plan_entitlements").select("*").eq("plan", plan).maybeSingle();
  const ent = error ? null : entitlementRow(data);
  if (!ent) {
    console.error(`entitlement lookup failed for plan "${plan}", falling back to trial`);
    return { ...TRIAL_FALLBACK, plan, degraded: true };
  }
  return ent;
}

/**
 * Entitlement for a charge decision. A degraded lookup is a 503 ("try again"),
 * never a 402 that would tell a paying Team org to upgrade.
 */
export async function entitlementForCharge(orgId: string): Promise<Entitlement> {
  const ent = await entitlementFor(orgId);
  if (ent.degraded) {
    throw new HttpError(503, "Plan lookup is temporarily unavailable — try again in a moment.", "upstream");
  }
  return ent;
}

/**
 * Human-readable quota error the app can act on:
 *   cap == 0 → 402 `plan_required` (a plan boundary: prompt an upgrade)
 *   cap  > 0 → 429 `quota_exceeded` (this cycle's allowance is used up)
 * Both carry {feature, used, cap, plan} so the UI can say "8 of 8 used".
 */
export function quotaError(feature: string, used: number, cap: number, plan: string): HttpError {
  const details = { feature, used, cap, plan };
  if (cap <= 0) {
    return new HttpError(
      402,
      `${feature} isn't included on the ${plan} plan — upgrade to unlock it.`,
      "plan_required",
      details,
    );
  }
  return new HttpError(
    429,
    `Monthly ${feature} limit reached for the ${plan} plan (${used} of ${cap}). ` +
      `Upgrade for more, or wait for your next cycle.`,
    "quota_exceeded",
    details,
  );
}
