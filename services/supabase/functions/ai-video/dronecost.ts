// Topaz header-based output estimates and conservative cost admission.
// Duration, geometry and frame rate come from the server's media header probe.
// Those checks do not attest every decoded picture. Holds and ledger receipts
// use the maximum published supported tariff, independent of a cheaper estimate.
// Client upload metadata and a requested tier are not price authority.
// This module has no provider or database calls. The route commits an atomic
// org cost hold before POST and atomically swaps that hold for a ledger receipt.

import { HttpError, round4 } from "../_shared/http.ts";
import { APP_AI_UNIT_CENTS } from "../_shared/ledger.ts";

// Requested presentation targets. The route never silently downsamples a source
// that is already larger or faster, so these targets do not determine its cost.
export const DRONE_TIERS: Record<string, { longEdge: number; fps: number }> = {
  "1080p60": { longEdge: 1920, fps: 60 },
  "4k30": { longEdge: 3840, fps: 30 },
  "4k60": { longEdge: 3840, fps: 60 },
};

// Retained for display and legacy route resolution only. Admission must use the
// actual output dimensions and frame rate, never this nominal tier lookup.
export const DRONE_TIER_CENTS: Record<string, number> = {
  "1080p60": APP_AI_UNIT_CENTS.topaz_1080p60_per_s,
  "4k30": APP_AI_UNIT_CENTS.topaz_4k30_per_s,
  "4k60": APP_AI_UNIT_CENTS.topaz_4k60_per_s,
};

// Public fal Proteus tariff checked 2026-10-04:
// https://fal.ai/models/fal-ai/topaz/upscale/video
// Up to 720p: 1c/s; through 1080p: 2c/s; above 1080p: 8c/s.
// 60fps doubles the price. The public tariff does not price >60fps, despite
// the API supporting 120fps. Conservatively double any >30..60fps output and
// classify nonstandard aspect ratios by both dimensions in an oriented box.
// Gaia 2's discount does not apply: the fal adapter explicitly pins Proteus.
export const DRONE_MAX_SOURCE_SECONDS = 300;
export const DRONE_MAX_OUTPUT_DIMENSION = 4096;
// A bounded MP4 header probe cannot exclude decoder-tolerated in-band geometry
// changes. Until decoded metadata/invoices can be reconciled, every accepted
// Topaz request holds and books the maximum published supported tariff. This
// is a conservative accounting fence, not a claim about the actual invoice.
export const DRONE_SAFE_HOLD_UNIT_CENTS = 16;
export const DRONE_MAX_SUBMISSION_CENTS = DRONE_MAX_SOURCE_SECONDS *
  DRONE_SAFE_HOLD_UNIT_CENTS;

type ResolutionBucket = "720p" | "1080p" | "above1080p";
export interface DroneEstimate {
  /** Requested label, retained for display; not used to price the output. */
  tier: string;
  seconds: number;
  fps: number;
  /** Integer header-based dimensions after the exact sent factor, not a decoded geometry attestation. */
  output_width: number;
  output_height: number;
  resolution_bucket: ResolutionBucket;
  resolution_unit_cents: number;
  fps_multiplier: 1 | 2;
  unit_cents: number;
  cents: number;
  usd: string;
  ceiling_cents: number;
}

type OutputGeometry = {
  outputWidth: number;
  outputHeight: number;
  outputFps: number;
};

function verifiedOutput(args: OutputGeometry) {
  if (
    !Number.isFinite(args.outputWidth) || args.outputWidth <= 0 ||
    !Number.isFinite(args.outputHeight) || args.outputHeight <= 0
  ) {
    throw new HttpError(
      409,
      "The video output dimensions could not be verified. Upload a complete saved video before requesting AI enhance.",
      "conflict",
    );
  }
  const width = Math.ceil(args.outputWidth),
    height = Math.ceil(args.outputHeight);
  const longEdge = Math.max(width, height), shortEdge = Math.min(width, height);
  if (longEdge > DRONE_MAX_OUTPUT_DIMENSION) {
    throw new HttpError(
      400,
      "AI enhance supports output dimensions up to 4096 pixels. Export a smaller source video or publish the standard version.",
      "validation",
    );
  }
  if (!Number.isFinite(args.outputFps) || args.outputFps <= 0) {
    throw new HttpError(
      409,
      "The video output frame rate could not be verified. Upload a complete saved video before requesting AI enhance.",
      "conflict",
    );
  }
  if (args.outputFps > 60) {
    throw new HttpError(
      409,
      "AI enhance supports verified output up to 60 fps. Export a video at 60 fps or lower, or publish the standard version.",
      "conflict",
    );
  }
  const bucket: ResolutionBucket = longEdge <= 1280 && shortEdge <= 720
    ? "720p"
    : longEdge <= 1920 && shortEdge <= 1080
    ? "1080p"
    : "above1080p";
  const resolutionCents = bucket === "720p" ? 1 : bucket === "1080p" ? 2 : 8;
  const multiplier: 1 | 2 = args.outputFps > 30 ? 2 : 1;
  return { width, height, bucket, resolutionCents, multiplier };
}

/** Display only; cents remain the currency of record. */
export function centsToUsd(cents: number): string {
  return (Math.round(cents) / 100).toFixed(2);
}
export function trimNumber(n: number): string {
  return Number.isInteger(n) ? String(n) : String(round4(n));
}
export function formatDuration(seconds: number): string {
  const total = Math.round(seconds);
  if (total < 60) return `${total} s`;
  const m = Math.floor(total / 60), s = total % 60;
  return s === 0 ? `${m} min` : `${m} min ${s} s`;
}
export function formatDurationLimit(seconds: number): string {
  const total = Math.round(seconds);
  if (total >= 60 && total % 60 === 0) {
    const m = total / 60;
    return m === 1 ? "1 minute" : `${m} minutes`;
  }
  return formatDuration(total);
}

/** Price the verified output. Missing geometry/fps never defaults to a tier. */
export function estimateDroneCents(
  args: OutputGeometry & {
    tier: string;
    seconds: number;
  },
): DroneEstimate {
  if (!Number.isFinite(args.seconds) || args.seconds <= 0) {
    throw new HttpError(
      409,
      "The video duration could not be verified.",
      "conflict",
    );
  }
  const output = verifiedOutput(args);
  const unitCents = output.resolutionCents * output.multiplier;
  const cents = round4(unitCents * args.seconds);
  if (!Number.isFinite(cents)) {
    throw new HttpError(
      409,
      "The video expense could not be verified.",
      "conflict",
    );
  }
  return {
    tier: args.tier,
    seconds: round4(args.seconds),
    fps: args.outputFps,
    output_width: output.width,
    output_height: output.height,
    resolution_bucket: output.bucket,
    resolution_unit_cents: output.resolutionCents,
    fps_multiplier: output.multiplier,
    unit_cents: unitCents,
    cents,
    usd: centsToUsd(cents),
    ceiling_cents: DRONE_MAX_SUBMISSION_CENTS,
  };
}

/** Keep the geometry estimate separate from the conservative held/booked cost. */
export function droneReservation(estimate: DroneEstimate): {
  unit_cents: 16;
  cents: number;
  usd: string;
  basis: "published_maximum_tariff";
} {
  const seconds = estimate.seconds;
  const cents = round4(seconds * DRONE_SAFE_HOLD_UNIT_CENTS);
  if (
    !Number.isFinite(seconds) || seconds <= 0 || !Number.isFinite(cents) ||
    cents <= 0
  ) {
    throw new HttpError(
      409,
      "The video cost reservation could not be verified.",
      "conflict",
    );
  }
  if (
    seconds > DRONE_MAX_SOURCE_SECONDS || cents > DRONE_MAX_SUBMISSION_CENTS
  ) {
    throw new HttpError(
      400,
      "AI enhance is limited to 5 minutes and a $48.00 cost reservation. Trim the tour or publish the standard version.",
      "validation",
    );
  }
  return {
    unit_cents: DRONE_SAFE_HOLD_UNIT_CENTS,
    cents,
    usd: centsToUsd(cents),
    basis: "published_maximum_tariff",
  };
}

export function affordableSeconds(unitCents: number): number {
  if (!Number.isFinite(unitCents) || unitCents <= 0) return 0;
  return Math.min(
    DRONE_MAX_SOURCE_SECONDS,
    Math.floor(DRONE_MAX_SUBMISSION_CENTS / unitCents),
  );
}

/** Refuse unreadable or unsupported media before allowance or provider POST. */
export function assertDroneWithinLimits(
  args: OutputGeometry & {
    tier: string;
    /** Server-probed source/output duration, never a client metadata hint. */
    durationS: number | null | undefined;
    assetId: string;
  },
): DroneEstimate {
  const seconds = args.durationS;
  if (
    typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0
  ) {
    throw new HttpError(
      409,
      `This asset has no verified duration_s. Upload a complete saved video so AI enhance can be priced before it runs (asset ${args.assetId}).`,
      "conflict",
    );
  }
  const estimate = estimateDroneCents({ ...args, seconds });
  if (seconds > DRONE_MAX_SOURCE_SECONDS) {
    throw new HttpError(
      400,
      `This tour is ${formatDuration(seconds)}. AI enhance is limited to ` +
        `${
          formatDurationLimit(DRONE_MAX_SOURCE_SECONDS)
        } — trim the tour or publish the standard version.`,
      "validation",
      {
        limit_seconds: DRONE_MAX_SOURCE_SECONDS,
        source_seconds: round4(seconds),
        estimate_cents: estimate.cents,
        estimate_usd: estimate.usd,
      },
    );
  }
  if (estimate.cents > DRONE_MAX_SUBMISSION_CENTS) {
    const fits = affordableSeconds(estimate.unit_cents);
    throw new HttpError(
      400,
      `AI enhance would cost about $${estimate.usd} for this ${
        formatDuration(seconds)
      } tour ` +
        `(${estimate.output_width}×${estimate.output_height} at ${
          trimNumber(estimate.fps)
        } fps, ` +
        `${
          trimNumber(estimate.unit_cents)
        }¢ per second), and a single enhance is capped at ` +
        `$${centsToUsd(DRONE_MAX_SUBMISSION_CENTS)}. Trim it to about ${
          formatDuration(fits)
        } or publish the standard version.`,
      "validation",
      {
        limit_cents: DRONE_MAX_SUBMISSION_CENTS,
        estimate_cents: estimate.cents,
        estimate_usd: estimate.usd,
        estimate_unit_cents: estimate.unit_cents,
        estimate_fps: estimate.fps,
        output_width: estimate.output_width,
        output_height: estimate.output_height,
        source_seconds: round4(seconds),
        fits_seconds: fits,
        tier: args.tier,
      },
    );
  }
  return estimate;
}

// This early comparison gives a useful quota error, but cannot serialize two
// submissions. app_video_cost_reserve is the authoritative atomic admission
// point and includes booked cost plus all outstanding org holds.
export function assertMonthlyHeadroom(args: {
  monthSpentCents: number;
  ceilingCents: number;
  projectedCents: number;
  plan: string;
  feature: string;
}): void {
  if (!(args.ceilingCents > 0)) return;
  const spent = Number.isFinite(args.monthSpentCents)
    ? Math.max(0, args.monthSpentCents)
    : 0;
  if (spent + args.projectedCents <= args.ceilingCents) return;
  throw new HttpError(
    402,
    `Your workspace has spent $${centsToUsd(spent)} of its ` +
      `$${
        centsToUsd(args.ceilingCents)
      } monthly AI budget on the ${args.plan} plan, and this ` +
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
