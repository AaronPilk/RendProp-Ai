// Cost ledger — the single source of truth for what a render job has spent.
//
// Every billable provider/GPU/stream unit becomes one cost_ledger row.
// render_jobs.cost_cents is the integer rollup (== round(sum of ledger)).
// logCost() enforces MAX_GEN_COST_PER_JOB_CENTS *before* recording, so a
// runaway job throws (402) instead of racking up spend. Per AI-COST-MODEL,
// the caller is expected to meter a unit before making the provider call.

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
 * which case NOTHING is written, so the caller can abort cleanly.
 */
export async function logCost(admin: SupabaseClient, args: LogCostArgs): Promise<LogCostResult> {
  const units = args.units ?? 1;
  const total_cents = round4(units * args.unit_cost_cents);

  // Precise running total from the ledger (rows per job are few).
  const { data: rows, error: sumErr } = await admin
    .from("cost_ledger")
    .select("total_cents")
    .eq("job_id", args.job_id);
  if (sumErr) throw new HttpError(500, `Ledger read failed: ${sumErr.message}`);

  const spent = (rows ?? []).reduce((s, r) => s + Number(r.total_cents ?? 0), 0);
  const projected = round4(spent + total_cents);

  if (projected > MAX_GEN_COST_PER_JOB_CENTS) {
    throw new HttpError(
      402,
      `Cost cap exceeded: job ${args.job_id} would reach ${projected}¢ ` +
        `(> MAX_GEN_COST_PER_JOB_CENTS=${MAX_GEN_COST_PER_JOB_CENTS}¢). Aborting before spend.`,
    );
  }

  const { error: insErr } = await admin.from("cost_ledger").insert({
    job_id: args.job_id,
    org_id: args.org_id ?? null,
    feature: args.feature,
    provider: args.provider,
    model: args.model ?? null,
    units,
    unit_cost_cents: args.unit_cost_cents,
    total_cents,
    meta: args.meta ?? {},
  });
  if (insErr) throw new HttpError(500, `Ledger insert failed: ${insErr.message}`);

  // Keep the job's integer rollup == round(precise sum).
  const job_cost_cents = Math.round(projected);
  const { error: upErr } = await admin
    .from("render_jobs")
    .update({ cost_cents: job_cost_cents })
    .eq("id", args.job_id);
  if (upErr) throw new HttpError(500, `Job cost update failed: ${upErr.message}`);

  return { total_cents, job_cost_cents };
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
