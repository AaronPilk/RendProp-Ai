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

// ── App-AI cost rows (in-app generations with NO render job) ─────────────────
//
// The worker pipeline records cost through logCost() → log_job_cost() above,
// which REQUIRES a render_job to lock and roll up onto. The in-app AI routes
// (/ai-photo, /ai-video) have no render job: they call Gemini / fal directly and
// hand the result back inline. Their spend still has to reach cost_ledger, or the
// owner spend console under-reports AND the per-org monthly COGS ceiling never
// sees app AI at all — the feature meters are the only thing bounding it today
// (audit F-E-15, docs/handoff/E-network.md §2).
//
// So recordAppAiCost() writes ONE org-scoped cost_ledger row with job_id = NULL,
// straight to the table with the SERVICE-ROLE client — migration 0007 revoked
// INSERT on cost_ledger from every tenant role, so only the service role can
// write it, exactly like the Python pipeline's REST insert. The admin console's
// coverage probe keys "app AI is represented" on precisely this shape (an
// org-scoped row with job_id IS NULL), so one successful write heals it.
//
// Authoritative unit costs, mirrored from services/pipeline/providers/costs.py
// and the admin provider inventory (functions/admin/index.ts). Update in lockstep
// with those two — a price only moves in one place if all three move together.
export const APP_AI_UNIT_CENTS = {
  /** Gemini 2.5 Flash Image ("Nano Banana") photo edit — per image. */
  gemini_image: 3.9,
  /** Seedance 1.0 Pro Fast image-to-video (reel + grounded aerial) — per output second. */
  seedance_per_s: 4.8,
  /** Veo 3.1 Fast ungrounded establishing aerial — flat per clip (repo has no per-second Veo price). */
  veo_aerial_clip: 80.0,
  /** Topaz Video AI drone-glide render — per output second, by tier. */
  topaz_1080p60_per_s: 4.0,
  topaz_4k30_per_s: 8.0,
  topaz_4k60_per_s: 16.0,
} as const;

export interface AppAiCostArgs {
  /** The org the spend is billed to. Required: an org_id-less row is invisible to
   *  the per-org COGS ceiling and to GET /admin/usage, so we refuse to write one. */
  orgId: string;
  /** cost_ledger.provider — gemini | fal (matches the admin provider inventory). */
  provider: string;
  /** cost_ledger.feature — photo_edit | reel | aerial | drone_render (app-AI vocab). */
  feature: string;
  model?: string | null;
  /** Images = 1; video = seconds of OUTPUT. Default 1. */
  units?: number;
  /** Cost per unit in cents (fractional ok, e.g. 3.9). */
  unitCents: number;
  /** Small, no PII / no secrets — provider request ids, tier, seconds, etc. */
  meta?: Record<string, unknown>;
}

export interface AppAiCostResult {
  recorded: boolean;
  /** The line-item cents (round(units × unitCents)) whether or not it persisted. */
  total_cents: number;
  /** Why nothing was written (only when recorded === false). */
  reason?: string;
}

/**
 * Record ONE cost_ledger row for a successful in-app AI generation that has no
 * render job. Modelled on recordProvenance(): BEST EFFORT and NEVER THROWS.
 *
 * By the time this is called the provider has already run and already billed —
 * dropping the user's finished image/clip because a ledger insert hit a Supabase
 * blip is the wrong trade, so a failure is logged and swallowed. (The Python
 * pipeline ledger deliberately does the opposite and fails CLOSED, because a
 * render job has a durable spool + reconciliation spine; app AI has neither, and
 * the console's coverage panel already measures the residual gap this leaves.)
 *
 * Call it ONLY on the confirmed-success path — after the image came back, or
 * after fal ACCEPTED the submit — so a failed/refunded generation writes no row.
 * Idempotency is the caller's Idempotency-Key 409 duplicate block: a retried
 * request is rejected before it ever reaches the provider, so one generation
 * writes exactly one row.
 */
export async function recordAppAiCost(
  admin: SupabaseClient,
  args: AppAiCostArgs,
): Promise<AppAiCostResult> {
  const units = args.units ?? 1;
  const total_cents = round4(units * args.unitCents);
  try {
    if (!args.orgId) {
      console.error("recordAppAiCost: missing orgId — skipping ledger write", {
        feature: args.feature,
        provider: args.provider,
      });
      return { recorded: false, total_cents, reason: "missing orgId" };
    }
    const { error } = await admin.from("cost_ledger").insert({
      job_id: null, // app AI has no render job — the shape the coverage probe keys on
      org_id: args.orgId,
      feature: args.feature,
      provider: args.provider,
      model: args.model ?? null,
      units,
      unit_cost_cents: args.unitCents,
      total_cents,
      meta: args.meta ?? {},
    });
    if (error) {
      console.error("recordAppAiCost: cost_ledger insert failed:", error.message);
      return { recorded: false, total_cents, reason: error.message };
    }
    return { recorded: true, total_cents };
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    console.error("recordAppAiCost threw:", reason);
    return { recorded: false, total_cents, reason };
  }
}

// ── Routed app-AI cost rows (AI router, contract §4) ─────────────────────────
//
// When the router picks the step, the ledger must carry the provider+model that
// ACTUALLY RAN — not the one the function used to hardcode. These two helpers
// are the only new thing the router needs from the ledger; recordAppAiCost()
// below them is unchanged and still does the writing.
//
// The step is described STRUCTURALLY on purpose: importing _shared/router.ts
// here would make every function that touches the ledger depend on the router.

/** The slice of a RouteStep the ledger cares about. */
export interface RoutedStepLike {
  route_id: string;
  task: string;
  provider: string;
  model: string;
  /** "image" | "second" | "call" | "minute" | "1k_chars" | "world" */
  unit: string;
  unit_cents: number;
}

/** What one generation consumed, in whatever units the caller measured. */
export interface RoutedUsage {
  seconds?: number;
  minutes?: number;
  chars?: number;
  images?: number;
}

/**
 * Convert measured usage into the step's billing unit. An unknown unit bills as
 * ONE unit rather than zero: over-reporting a strange row is recoverable,
 * silently recording $0.00 is not.
 */
export function unitsForStep(unit: string, usage: RoutedUsage): number {
  switch (unit) {
    case "second":
      return Math.max(0, usage.seconds ?? 0);
    case "minute":
      return Math.max(0, usage.minutes ?? (usage.seconds != null ? usage.seconds / 60 : 0));
    case "1k_chars":
      return Math.max(0, (usage.chars ?? 0) / 1000);
    case "image":
      return usage.images ?? 1;
    case "call":
    case "world":
      return 1;
    default:
      return usage.images ?? 1;
  }
}

export interface RoutedCostArgs extends RoutedUsage {
  orgId: string;
  /** cost_ledger.feature — photo_edit | reel | aerial | drone_render. */
  feature: string;
  step: RoutedStepLike;
  /**
   * Price override for the rare case where one route row cannot express the
   * price: Topaz bills per OUTPUT pixel-frame, so 4K60 is twice 4K30 while the
   * routing table holds a single `video.upscale_4k` row. The caller passes the
   * tier price from APP_AI_UNIT_CENTS and the row's price is ignored.
   */
  unitCentsOverride?: number;
  meta?: Record<string, unknown>;
}

/**
 * Record one cost_ledger row for a step the router chose. Same best-effort,
 * never-throws contract as recordAppAiCost(): by the time this runs the
 * provider has already billed us.
 */
export async function recordRoutedAiCost(
  admin: SupabaseClient,
  args: RoutedCostArgs,
): Promise<AppAiCostResult> {
  const { orgId, feature, step, unitCentsOverride, meta, ...usage } = args;
  return await recordAppAiCost(admin, {
    orgId,
    provider: step.provider,
    feature,
    model: step.model,
    units: unitsForStep(step.unit, usage),
    unitCents: unitCentsOverride ?? step.unit_cents,
    meta: { ...(meta ?? {}), route_id: step.route_id, task: step.task, unit: step.unit },
  });
}
