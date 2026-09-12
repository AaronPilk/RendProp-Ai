// dronecost.ts — what one POST /ai-video/drone submission will cost, and the
// ceilings that refuse it BEFORE fal is ever called.
//
// Pulled out of index.ts (which calls Deno.serve at module load and so is never
// imported by a test — see uploads/content_type.ts or events/schema.ts for the
// same pattern in this codebase) purely so this arithmetic gets direct unit
// tests instead of only being reachable through an HTTP-level integration test.
// See dronecost.test.ts. Everything here is PURE: no env, no network, no
// Supabase — the one DB read the monthly check needs (org_month_spend_cents)
// stays in index.ts and is handed in as a number.
//
// ── The incident this exists to prevent ──────────────────────────────────────
//
// The 4,000 sq ft field test: a 410 s 4K60 tour billed ~$48 from one tap. The
// route accepted it without comment — no ceiling, no confirmation, no estimate
// anywhere in the 202, and no per-submission cap of any kind. One tap, on a
// plan whose ENTIRE monthly AI budget is $82.00.
//
// Priced against the rate card this repo actually commits (16.0¢ per output
// second at 4K60 — see below), that same submission is
//
//     410 s × 16.0 ¢/s = 6,560¢ = $65.60
//
// so the guard is sized off the committed number, not off the invoice the field
// test happened to see. Two of them in a month is $131.20 against a $82.00
// ceiling: 160% of the whole plan's COGS budget from two taps, and a retry loop
// or a fat-fingered tier had no upper bound at all.
//
// ── Why the existing cost machinery did not already stop it ──────────────────
//
// It structurally could not. The per-generation cap this repo already commits
// to — MAX_GEN_COST_PER_JOB_CENTS ($25.00, _shared/ledger.ts) — is enforced
// inside the log_job_cost() RPC (migrations 0010 / 0024), and that RPC starts
// with `perform 1 from render_jobs where id = p_job for update` and raises
// RP404 when there is none. The in-app AI routes have no render job: they write
// their spend through recordAppAiCost(), which inserts into cost_ledger
// directly with the service role and therefore passes through NEITHER the
// per-job cap NOR the per-org monthly ceiling. Drone was the most expensive tap
// in the product and the one with no ceiling on it at all.
//
// Nothing here replaces that machinery, and nothing here borrows the $25.00.
// The rate card is still APP_AI_UNIT_CENTS, and the monthly wall is still the
// plan's own cogs_ceiling_cents measured by org_month_spend_cents() — the exact
// pair log_job_cost() compares, read and pre-flighted at submit time because
// there is no job row to run them on. The PER-SUBMISSION ceiling is a new,
// derived number (DRONE_MAX_SUBMISSION_CENTS below) rather than the RPC's cap,
// because that cap can never apply on this route and is the wrong size for it
// anyway — see the constant's own comment.
//
// This file writes nothing, so it cannot double-count: the one cost_ledger row
// is still written by index.ts after fal accepts the submit, exactly as before.

import { HttpError, round4 } from "../_shared/http.ts";
import { APP_AI_UNIT_CENTS } from "../_shared/ledger.ts";

// Drone-glide tiers → output target. Topaz bills per output pixel-frame, so the
// upscale factor is derived from the SOURCE resolution (never > the target,
// never 8K) — see index.ts. `fps` is the tier's own nominal output frame rate,
// which is also the denominator of the frame-rate multiplier below.
export const DRONE_TIERS: Record<string, { longEdge: number; fps: number }> = {
  "1080p60": { longEdge: 1920, fps: 60 },
  "4k30": { longEdge: 3840, fps: 30 },
  "4k60": { longEdge: 3840, fps: 60 },
};

// Topaz drone-glide cost per OUTPUT second, by tier (F-E-15). Authoritative
// numbers live in _shared/ledger.ts APP_AI_UNIT_CENTS, which is itself kept in
// lockstep with services/pipeline/providers/costs.py and the admin provider
// inventory (functions/admin/index.ts) — a price only moves if all three move.
export const DRONE_TIER_CENTS: Record<string, number> = {
  "1080p60": APP_AI_UNIT_CENTS.topaz_1080p60_per_s,
  "4k30": APP_AI_UNIT_CENTS.topaz_4k30_per_s,
  "4k60": APP_AI_UNIT_CENTS.topaz_4k60_per_s,
};

/**
 * Hard ceiling on the source duration a drone-glide submission may carry.
 *
 * ── Why 300 s, with the arithmetic written out ───────────────────────────────
 *
 * The committed rate card prices Topaz per OUTPUT second, and the output runs
 * the same wall-clock as the source:
 *
 *     1080p60    4.0 ¢/s
 *     4k30       8.0 ¢/s   <- the route's DEFAULT tier (`body.tier ?? "4k30"`)
 *     4k60      16.0 ¢/s   <- "the single most expensive tap" (admin inventory)
 *
 * 300 s is the PRIMARY rule here — the length a tour may be AI-enhanced at all —
 * and the per-submission cost ceiling below is derived FROM it rather than the
 * other way round. It is sized off what the product actually produces, because
 * a ceiling that refuses the properties this is sold for is not a guard, it is
 * a feature that never fires:
 *
 *   • the app refuses an import over 600 s (MediaImporter.maxDurationSeconds)
 *     and RenderEngine speeds a walkthrough up 2× (1.25× for drone-flagged
 *     footage), so a master over 300 s means a walk over ten minutes;
 *   • the 4,000 sq ft house that produced the incident is an 8-10 minute walk
 *     and cannot be filmed faster — that renders to a 240-300 s master, which
 *     has to keep working on BOTH paid AI tiers;
 *   • 300 s says as "5 minutes", which is a rule an agent can act on.
 *
 * What one tap then costs at the cap, at each tier:
 *
 *     300 s ×  4.0 ¢/s = 1,200¢ = $12.00   1080p60
 *     300 s ×  8.0 ¢/s = 2,400¢ = $24.00   4k30 nominal (30 fps output)
 *     300 s × 16.0 ¢/s = 4,800¢ = $48.00   4k60 — the worst case, and exactly
 *                                          DRONE_MAX_SUBMISSION_CENTS, so a
 *                                          full-length 4K60 tour PASSES both
 *                                          guards rather than being refused by
 *                                          a ceiling its own length implies
 *
 * NOTE the 4k30 row is nominal. The shipped app renders its master at 60 fps
 * (RenderEngine.outputFPS), and `4k30` + target_fps 30 makes index.ts request NO
 * interpolation — the source already runs at/above the target — so Topaz emits
 * 4K at 60 fps and fal charges the 4K60 pixel-frame rate. In practice BOTH paid
 * tiers price at 16.0 ¢/s, which is why the ceiling is derived from that rate
 * and not from the cheaper one.
 *
 * The duration cap is therefore the product answer ("how long a tour may be
 * enhanced at all") and the cost ceiling is the money answer ("is this price in
 * line with that length"). Neither subsumes the other: 410 s of 1080p60
 * ($16.40) is cheap and is still refused on DURATION; 300 s of 4k30 asked for
 * at 120 fps is legal in length and is refused on COST, because 32.0 ¢/s is not
 * a price any 5-minute tour should carry.
 *
 * ── Why $48.00 a tap is still bounded ────────────────────────────────────────
 *
 * The monthly wall does the bounding, and it is unchanged. Sanity against the
 * plan table (migration 0010, sizes reworked by 0044): `team` is the only paid
 * plan with topaz_per_month > 0 (2 taps/month) and its cogs_ceiling_cents is
 * 6,000¢ = $60.00. Two maxed-out taps would be $96.00, so
 * assertMonthlyHeadroom() refuses the SECOND one — max drone exposure stays
 * ~$48-60 per org per month, enforced by machinery that already existed. What
 * the worst single tap costs went from $25.00 to $48.00; what a MONTH can cost
 * did not move.
 *
 * Sanity against the product, so this refuses as little real work as possible:
 * the master handed to this route is normally ≤ 300 s already (see above). The
 * band this cap actually costs anyone is a drone-flagged capture longer than
 * 6 min 15 s. Those still publish their standard tour at FULL length — only the
 * AI enhance is capped, which is exactly what the refusal says.
 */
export const DRONE_MAX_SOURCE_SECONDS = 300;

/**
 * Ceiling on what ONE drone submission may cost, in cents.
 *
 * DERIVED, not picked: it is exactly what the duration cap already implies at
 * the most expensive tier —
 *
 *     300 s × 16.0 ¢/s = 4,800¢ = $48.00
 *
 * — so the two guards cannot contradict each other. A tour the duration rule
 * allows can never be refused by a price the same rule already sanctioned, and
 * the cost ceiling is left doing the one job only it can do: catching a
 * submission whose PRICE is out of line with its LENGTH. That is the
 * `{tier:"4k30", target_fps:120}` case — 32.0 ¢/s, four times the rate a
 * 5-minute tour should carry — which the frame-rate multiplier in
 * estimateDroneCents() is what prices correctly. Without that multiplier this
 * ceiling would be unreachable and therefore pointless; with it, it has teeth.
 *
 * This is deliberately NOT MAX_GEN_COST_PER_JOB_CENTS. That $25.00 is the
 * per-generation cap enforced inside log_job_cost(), and log_job_cost() raises
 * RP404 without a render_job — which this route does not have and never will.
 * The cap does not and CANNOT apply here, so pointing at the constant would
 * only make two unrelated numbers look linked. It is also the wrong size: at
 * the 16.0 ¢/s both paid tiers really run at, $25.00 binds at 156 s of tour —
 * a five-minute walk — which would refuse the AI enhance for exactly the
 * property class the product is sold to. See DRONE_MAX_SOURCE_SECONDS above for
 * why $48.00 a tap is still bounded: the per-org monthly ceiling is what caps a
 * month, and it is unchanged.
 */
export const DRONE_MAX_SUBMISSION_CENTS = Math.round(
  DRONE_MAX_SOURCE_SECONDS * APP_AI_UNIT_CENTS.topaz_4k60_per_s,
);

/**
 * The priced shape of one submission. Returned on the SUCCESS path in the 202
 * as `estimated_cost` (additive — see index.ts) and attached to the details of
 * every refusal below, so the app can show the number either way.
 */
export interface DroneEstimate {
  tier: string;
  /** Source seconds = output seconds: Topaz preserves duration. */
  seconds: number;
  /** The output frame rate this was priced at (see the multiplier below). */
  fps: number;
  /** ¢ per output second AFTER the frame-rate multiplier. */
  unit_cents: number;
  /** ¢ for the whole submission (round4, like every cost_ledger figure). */
  cents: number;
  /** "24.00" — the same number formatted for display, never re-derived client-side. */
  usd: string;
  /** The per-submission ceiling this was measured against, for the UI. */
  ceiling_cents: number;
}

/** "$24.00" from 2400¢. Cents are the currency of record; this is display only. */
export function centsToUsd(cents: number): string {
  return (Math.round(cents) / 100).toFixed(2);
}

/** "16" from 16.0, "4.8" from 4.8 — a rate said the way a person would say it. */
export function trimNumber(n: number): string {
  return Number.isInteger(n) ? String(n) : String(round4(n));
}

/** "6 min 50 s" / "5 min" / "42 s" — the copy the refusals are written in. */
export function formatDuration(seconds: number): string {
  const total = Math.round(seconds);
  if (total < 60) return `${total} s`;
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s === 0 ? `${m} min` : `${m} min ${s} s`;
}

/**
 * The same duration said as a LIMIT ("5 minutes"), which is how a person reads
 * a rule rather than a measurement. Falls back to formatDuration() whenever the
 * cap is not a whole number of minutes, so the copy stays correct if the cap
 * moves off 300 s.
 */
export function formatDurationLimit(seconds: number): string {
  const total = Math.round(seconds);
  if (total >= 60 && total % 60 === 0) {
    const m = total / 60;
    return m === 1 ? "1 minute" : `${m} minutes`;
  }
  return formatDuration(total);
}

/**
 * Price ONE submission: duration × tier × frame rate.
 *
 * FRAME RATE. `target_fps` is a caller-supplied override, bounded 24-120 in
 * index.ts, and the rate card prices a TIER, not a frame rate — so
 * `{ tier: "4k30", target_fps: 120 }` would bill at the 4K30 rate for four
 * times the output pixel-frames Topaz actually renders. Estimating on the tier
 * price alone lets exactly that submission through the ceiling. So the estimate
 * scales the tier price by (output fps ÷ the tier's own fps), FLOORED at 1× so
 * a below-tier frame rate can never discount below the committed rate card.
 *
 * This scaling is estimate-side only. The cost_ledger row still records the
 * committed tier price (index.ts, `unitCentsOverride`), because that is the
 * number the three-way rate-card lockstep owns and this file does not get to
 * invent accounting. Erring HIGH on a pre-flight estimate is the doctrine
 * costs.py's qc_estimate_cents() already states in as many words: "an estimate
 * that is too low lets a call through that the cap should have stopped."
 *
 * An unknown tier prices at the most expensive tier rather than throwing or
 * defaulting cheap — same reason. (index.ts rejects unknown tiers before this
 * is ever reached; this is the fail-closed branch, not the happy path.)
 */
export function estimateDroneCents(args: {
  tier: string;
  seconds: number;
  /** The frame rate the OUTPUT will actually run at. */
  outputFps: number;
}): DroneEstimate {
  const tierCents = DRONE_TIER_CENTS[args.tier] ?? APP_AI_UNIT_CENTS.topaz_4k60_per_s;
  const tierFps = DRONE_TIERS[args.tier]?.fps ?? 60;
  const fps = Number.isFinite(args.outputFps) && args.outputFps > 0 ? args.outputFps : tierFps;
  const multiplier = Math.max(1, fps / tierFps);
  const unitCents = round4(tierCents * multiplier);
  const cents = round4(unitCents * args.seconds);
  return {
    tier: args.tier,
    seconds: round4(args.seconds),
    fps: round4(fps),
    unit_cents: unitCents,
    cents,
    usd: centsToUsd(cents),
    ceiling_cents: DRONE_MAX_SUBMISSION_CENTS,
  };
}

/**
 * The longest source, in seconds, this tier + frame rate can afford — the "trim
 * it to about X" figure in the cost refusal.
 *
 * Clamped to DRONE_MAX_SOURCE_SECONDS so the advice can never name a length the
 * OTHER guard would refuse anyway. (With the ceiling derived from that same cap
 * at the top tier, a rate cheap enough for the clamp to bite cannot reach this
 * refusal in the first place — but a helper that can be read on its own should
 * not hand out a number the product does not allow.)
 */
export function affordableSeconds(unitCents: number): number {
  if (!(unitCents > 0)) return 0;
  return Math.min(DRONE_MAX_SOURCE_SECONDS, Math.floor(DRONE_MAX_SUBMISSION_CENTS / unitCents));
}

/**
 * Refuse a submission we cannot price, one that is too long, or one that costs
 * more than a single tap may — BEFORE any quota is charged and before a
 * provider is called. Returns the estimate when the submission passes, so the
 * caller has exactly one place the price is computed.
 *
 * ── Missing duration FAILS CLOSED ────────────────────────────────────────────
 *
 * capture_assets.duration_s is nullable and CLIENT-declared: POST
 * /uploads/:id/complete stores whatever the app sends (metadataPatch() bounds
 * it to 0 < d ≤ 7200 and nothing else), and nothing server-side ever probes the
 * file. So it is trustworthy only in the sense that the shipped app always
 * sends it — RendpropApp.swift uploads the AI-enhance master as
 * `UploadMetadata(durationS: tour.durationS, …)` taken from RenderEngine's own
 * output duration — and it is absent only when some other client skipped it.
 *
 * Without it Topaz cannot be priced AT ALL: it bills per output second. The
 * route used to submit anyway and merely console.warn() that the spend went
 * unrecorded (the documented "F-E-15 residual gap"), which is the worst of both
 * outcomes — fal bills the org, and the cost_ledger, the per-org monthly COGS
 * ceiling and GET /admin/spend all see $0.00 for it. A submission we cannot
 * price is a submission we cannot cap, so it is refused. That also closes the
 * residual gap outright: every drone submission that now reaches fal has a
 * duration, so every one of them writes its ledger row.
 *
 * The refusal deliberately copies /ai-video/declutter's existing precedent for
 * the same missing field — 409 `conflict`, "re-upload it with duration_s so the
 * clip can be pre-checked" — so the app has one behaviour to handle, not two.
 * (RendpropApp.swift's enhance path catches ANY error from this route and
 * publishes the standard tour with the server's own sentence as the note, so
 * every refusal here degrades to "AI enhance unavailable (…) — publishing your
 * standard tour instead" rather than a dead end.)
 */
export function assertDroneWithinLimits(args: {
  tier: string;
  /** capture_assets.duration_s — null/0/NaN all mean "cannot price this". */
  durationS: number | null | undefined;
  /** The frame rate the OUTPUT will actually run at. */
  outputFps: number;
  /** Named in the 409 so an operator can find the row. Never a secret. */
  assetId: string;
}): DroneEstimate {
  const seconds = Number(args.durationS);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new HttpError(
      409,
      `This asset has no probed duration — re-upload it with duration_s so the ` +
        `AI enhance can be priced and pre-checked (asset ${args.assetId}). ` +
        `Topaz bills per second of output, so a clip with no duration cannot be ` +
        `costed before it runs and is never submitted.`,
      "conflict",
    );
  }

  // The hard duration ceiling. Checked BEFORE the cost ceiling so the 410 s
  // field-test tour gets the length sentence (which the agent can act on by
  // trimming) rather than a price sentence about a tier they never chose.
  if (seconds > DRONE_MAX_SOURCE_SECONDS) {
    const estimate = estimateDroneCents({ tier: args.tier, seconds, outputFps: args.outputFps });
    throw new HttpError(
      400,
      `This tour is ${formatDuration(seconds)}. AI enhance is limited to ` +
        `${formatDurationLimit(DRONE_MAX_SOURCE_SECONDS)} — trim the tour or publish the ` +
        `standard version.`,
      "validation",
      {
        limit_seconds: DRONE_MAX_SOURCE_SECONDS,
        source_seconds: round4(seconds),
        estimate_cents: estimate.cents,
        estimate_usd: estimate.usd,
      },
    );
  }

  const estimate = estimateDroneCents({ tier: args.tier, seconds, outputFps: args.outputFps });
  if (estimate.cents > DRONE_MAX_SUBMISSION_CENTS) {
    const fits = affordableSeconds(estimate.unit_cents);
    // The frame rate is named because it is often the surprising half of the
    // price: a "4k30" tap on a 60 fps master asks for no interpolation, so
    // Topaz emits 4K at 60 fps and charges the 4K60 pixel-frame rate. "Choose a
    // lower tier" alone would be unactionable advice for that submission.
    throw new HttpError(
      400,
      `AI enhance would cost about $${estimate.usd} for this ${formatDuration(seconds)} tour ` +
        `(${args.tier}: ${trimNumber(round4(seconds))} s of ${trimNumber(estimate.fps)} fps output at ` +
        `${trimNumber(estimate.unit_cents)}¢ per second), and a single enhance is capped at ` +
        `$${centsToUsd(DRONE_MAX_SUBMISSION_CENTS)}. Trim it to about ${formatDuration(fits)}, ` +
        `pick a lower tier, or publish the standard version.`,
      "validation",
      {
        limit_cents: DRONE_MAX_SUBMISSION_CENTS,
        estimate_cents: estimate.cents,
        estimate_usd: estimate.usd,
        estimate_unit_cents: estimate.unit_cents,
        estimate_fps: estimate.fps,
        source_seconds: round4(seconds),
        fits_seconds: fits,
        tier: args.tier,
      },
    );
  }

  return estimate;
}

/**
 * Compose the projected cost with the org's EXISTING per-org monthly COGS
 * ceiling — the same pair log_job_cost() compares (0010 §4 / 0024):
 * org_month_spend_cents(org) against plan_entitlement(plan).cogs_ceiling_cents.
 *
 * This is a READ-and-compare, never a write, so it cannot double-count: the
 * projected cents are not in cost_ledger yet, and the single row for this
 * submission is still written once by index.ts after fal accepts it. It also
 * does not bypass the ceiling — it is the same ceiling, checked one step
 * earlier, at the only moment where refusing is still free. log_job_cost()
 * remains the enforcement point for everything that has a render job.
 *
 * 402 `quota_exceeded` matches what throwRpc() already maps log_job_cost()'s
 * own "monthly AI spend ceiling reached" RP402 to, so the app's existing
 * `isQuota` → upgrade-prompt branch handles it with no client change.
 *
 * A ceiling of 0 or less means "no monthly ceiling configured" and is not
 * enforced, exactly as `if v_ceiling is not null` behaves in the RPC.
 */
export function assertMonthlyHeadroom(args: {
  monthSpentCents: number;
  ceilingCents: number;
  projectedCents: number;
  plan: string;
  feature: string;
}): void {
  if (!(args.ceilingCents > 0)) return;
  const spent = Number.isFinite(args.monthSpentCents) ? Math.max(0, args.monthSpentCents) : 0;
  if (spent + args.projectedCents <= args.ceilingCents) return;
  throw new HttpError(
    402,
    `Your workspace has spent $${centsToUsd(spent)} of its ` +
      `$${centsToUsd(args.ceilingCents)} monthly AI budget on the ${args.plan} plan, and this ` +
      `${args.feature} would add about $${centsToUsd(args.projectedCents)}. ` +
      `Upgrade for a larger budget, or wait for the next cycle.`,
    "quota_exceeded",
    {
      feature: args.feature,
      plan: args.plan,
      spent_cents: round4(spent),
      ceiling_cents: args.ceilingCents,
      estimate_cents: round4(args.projectedCents),
    },
  );
}
