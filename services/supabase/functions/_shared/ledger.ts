// Cost ledger — the single source of truth for what a render job has spent.
//
// Every billable provider/GPU/stream unit becomes one cost_ledger row.
// render_jobs.cost_cents is the integer rollup (== round(sum of ledger)).
//
// Audit P0-3: the old read/sum/insert/update sequence raced under concurrency,
// so parallel provider calls could sail past the cap together. logCost() now
// delegates to the log_job_cost() Postgres RPC (migration 0006), which takes a
// row lock on the job, checks the cap, inserts the line, and updates the
// rollup in ONE transaction. Nothing is written when the cap would be blown —
// the RPC raises and we surface HttpError(402).

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError, round4 } from "./http.ts";

export const MAX_GEN_COST_PER_JOB_CENTS = Number(
  Deno.env.get("MAX_GEN_COST_PER_JOB_CENTS") ?? "2500",
);

// feature: declutter | restage | hero | qc | render | stream_store | stream_deliver
// provider: gemini | fal | anthropic | kie | cloudflare
export interface LogCostArgs {
  job_id: string;
  org_id?: string | null;
  feature: string;
  provider: string;
  model?: string | null;
  /** Number of units (images, seconds, minutes, tokens/1k...). Default 1. */
  units?: number;
  /** Cost per unit, in cents (may be fractional, e.g. 3.9 for Nano Banana). */
  unit_cost_cents: number;
  meta?: Record<string, unknown>;
}

export interface LogCostResult {
  total_cents: number; // this line item
  job_cost_cents: number; // new job rollup (integer)
}

/**
 * Record one billable unit against a render job and return the new rollup.
 * Throws HttpError(402) if it would push the job over the per-job cap — in
 * which case NOTHING was written (the RPC is transactional).
 */
export async function logCost(admin: SupabaseClient, args: LogCostArgs): Promise<LogCostResult> {
  const units = args.units ?? 1;
  const total_cents = round4(units * args.unit_cost_cents);

  const { data, error } = await admin.rpc("log_job_cost", {
    p_job: args.job_id,
    p_org: args.org_id ?? null,
    p_feature: args.feature,
    p_provider: args.provider,
    p_model: args.model ?? null,
    p_units: units,
    p_unit_cost: args.unit_cost_cents,
    p_meta: args.meta ?? {},
    p_cap_cents: MAX_GEN_COST_PER_JOB_CENTS,
  });
  if (error) {
    const msg = error.message ?? "ledger write failed";
    if (msg.includes("RP402")) throw new HttpError(402, msg.replace(/^.*RP402:\s*/, "Cost cap exceeded: "));
    if (msg.includes("RP404")) throw new HttpError(404, "Render job not found");
    throw new HttpError(500, `Ledger write failed: ${msg}`);
  }

  const newTotal = Number(data ?? 0);
  return { total_cents, job_cost_cents: Math.round(newTotal) };
}

/**
 * Read-only cap check without recording anything — used by the thin /ai-enhance
 * enqueue to reject a job that is already at/over budget before queuing more work.
 * Returns the current precise spend for the job.
 */
export async function jobSpentCents(admin: SupabaseClient, jobId: string): Promise<number> {
  const { data, error } = await admin
    .from("cost_ledger")
    .select("total_cents")
    .eq("job_id", jobId);
  if (error) throw new HttpError(500, `Ledger read failed: ${error.message}`);
  return round4((data ?? []).reduce((s, r) => s + Number(r.total_cents ?? 0), 0));
}

// Rough per-unit estimates (cents) for the pre-flight cap check in /ai-enhance.
// These are NOT authoritative — the pipeline logs real costs via logCost().
export const ESTIMATED_UNIT_COST_CENTS: Record<string, number> = {
  declutter: 4, // Flux Fill/Kontext masked inpaint (~$0.04/img)
  restage: 3.9, // Nano Banana direct (~$0.039/img)
  hero: 24, // Seedance 1.0 Pro Fast 5s clip (~$0.24)
};
