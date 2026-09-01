// Plan entitlements — read from the DATABASE, never hardcoded per function.
//
// Every allowance lives in one table (public.plan_entitlements, migration 0010)
// so the numbers the code enforces and the numbers rendprop.com/pricing
// advertises can't drift apart. That drift is exactly what the round-4 audit
// caught: the site sold 2/5/15 renders while the backend allowed 20/100/400.
//
// The allowances are sized from MEASURED unit costs (see
// services/pipeline/providers/costs.py and docs/AI-COST-MODEL.md):
//   tour render (90s server encode) .. $0.0075   <- the cheap unit
//   AI photo edit ................... $0.039
//   reel clip (Seedance 5s) ......... $0.24
//   AI aerial (Veo 3.1 Fast 8s) ..... $0.80      <- 3x a reel, meter it
//   Topaz drone glide (90s 1080p60) . $3.60      <- add-on only, never bundled
// Each tier holds ~75-78% gross margin at FULL utilization.
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
}

/** Conservative fallback if the table is unreachable: the trial allowance.
 *  Fail CLOSED — a lookup failure must never hand out a Team-sized budget. */
const TRIAL_FALLBACK: Entitlement = {
  plan: "trial",
  renders_per_month: 1,
  photo_edits_per_month: 10,
  reels_per_month: 1,
  aerials_per_month: 0,
  topaz_per_month: 0,
  seats: 1,
  cogs_ceiling_cents: 200,
  price_cents: 0,
};

/**
 * The allowances an org is actually entitled to right now.
 * Uses effective_plan(), so an EXPIRED trial silently drops to `free` — a
 * lapsed card can't keep spending.
 */
export async function entitlementFor(orgId: string): Promise<Entitlement> {
  const admin = adminClient();

  const { data: planRow, error: pErr } = await admin
    .rpc("effective_plan", { p_org: orgId });
  if (pErr) {
    console.error("effective_plan lookup failed, falling back to trial:", pErr.message);
    return TRIAL_FALLBACK;
  }
  const plan = String(planRow ?? "trial");

  const { data, error } = await admin
    .from("plan_entitlements").select("*").eq("plan", plan).maybeSingle();
  if (error || !data) {
    console.error(`entitlement lookup failed for plan "${plan}", falling back to trial`);
    return { ...TRIAL_FALLBACK, plan };
  }
  return data as Entitlement;
}

/** Human-readable 429 body so the app can prompt an upgrade, not just fail. */
export function quotaError(feature: string, used: number, cap: number, plan: string): HttpError {
  if (cap <= 0) {
    return new HttpError(
      402,
      `${feature} isn't included on the ${plan} plan — upgrade to unlock it.`,
    );
  }
  return new HttpError(
    429,
    `Monthly ${feature} limit reached for the ${plan} plan (${used} of ${cap}). ` +
      `Upgrade for more, or wait for your next cycle.`,
  );
}
