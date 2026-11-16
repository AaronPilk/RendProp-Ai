// Offline arithmetic, validation and route-order regression coverage.
// deno test --cached-only --deny-net --deny-write --deny-run \
//   --allow-env=MAX_GEN_COST_PER_JOB_CENTS --allow-read dronecost.test.ts
import {
  assert,
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { APP_AI_UNIT_CENTS } from "../_shared/ledger.ts";
import {
  affordableSeconds,
  assertDroneWithinLimits,
  assertMonthlyHeadroom,
  centsToUsd,
  DRONE_MAX_OUTPUT_DIMENSION,
  DRONE_MAX_SOURCE_SECONDS,
  DRONE_MAX_SUBMISSION_CENTS,
  DRONE_SAFE_HOLD_UNIT_CENTS,
  DRONE_TIER_CENTS,
  DRONE_TIERS,
  droneReservation,
  estimateDroneCents,
  formatDuration,
  formatDurationLimit,
  trimNumber,
} from "./dronecost.ts";

function submit(
  tier: string,
  seconds: number,
  outputFps = DRONE_TIERS[tier].fps,
  outputWidth = tier === "1080p60" ? 1920 : 3840,
  outputHeight = tier === "1080p60" ? 1080 : 2160,
) {
  return assertDroneWithinLimits({
    tier,
    durationS: seconds,
    outputFps,
    outputWidth,
    outputHeight,
    assetId: "asset-1",
  });
}
const shape = {
  tier: "1080p60",
  seconds: 300,
  outputWidth: 1920,
  outputHeight: 1080,
  outputFps: 60,
};

Deno.test("legacy display rates remain available but do not price admission", () => {
  assertEquals(
    DRONE_TIER_CENTS["1080p60"],
    APP_AI_UNIT_CENTS.topaz_1080p60_per_s,
  );
  assertEquals(DRONE_TIER_CENTS["4k30"], APP_AI_UNIT_CENTS.topaz_4k30_per_s);
  assertEquals(DRONE_TIER_CENTS["4k60"], APP_AI_UNIT_CENTS.topaz_4k60_per_s);
});
Deno.test("verified maximum output costs exactly the 300-second 4800-cent ceiling", () => {
  assertEquals(DRONE_MAX_SOURCE_SECONDS, 300);
  assertEquals(DRONE_MAX_OUTPUT_DIMENSION, 4096);
  assertEquals(DRONE_MAX_SUBMISSION_CENTS, 4800);
  assertEquals(submit("4k60", 300).cents, DRONE_MAX_SUBMISSION_CENTS);
});
Deno.test("4K60 source retained by a 1080 request is priced at 16c/s and 4800c", () => {
  const est = submit("1080p60", 300, 60, 3840, 2160);
  assertEquals(est.unit_cents, 16);
  assertEquals(est.cents, 4800);
  assertEquals(est.usd, "48.00");
  assertEquals(est.output_width, 3840);
  assertEquals(est.output_height, 2160);
  assertEquals(est.resolution_bucket, "above1080p");
  // The previous nominal-tier estimate was 1200c for the same unchanged output.
  assert(est.cents > DRONE_TIER_CENTS["1080p60"] * est.seconds);
});
Deno.test("1080p60 retained output still legitimately costs 4c/s", () => {
  assertEquals(estimateDroneCents(shape).cents, 1200);
});
Deno.test("cheap 720p and 1080p estimates hold and book the published maximum tariff", () => {
  assertEquals(DRONE_SAFE_HOLD_UNIT_CENTS, 16);
  for (
    const [outputWidth, outputHeight, outputFps, estimateCents] of [
      [1280, 720, 30, 300],
      [1920, 1080, 60, 1200],
    ]
  ) {
    const estimate = estimateDroneCents({
      ...shape,
      outputWidth,
      outputHeight,
      outputFps,
    });
    assertEquals(estimate.cents, estimateCents);
    const before = structuredClone(estimate);
    assertEquals(droneReservation(Object.freeze(estimate)), {
      unit_cents: 16,
      cents: 4800,
      usd: "48.00",
      basis: "published_maximum_tariff",
    });
    assertEquals(estimate, before);
  }
});
Deno.test("4K estimates use the same reservation floor at both frame rates", () => {
  for (const outputFps of [30, 60]) {
    const estimate = submit("4k60", 300, outputFps);
    assertEquals(droneReservation(estimate).cents, 4800);
    assertEquals(droneReservation(estimate).unit_cents, 16);
  }
});
Deno.test("the conservative reservation prices fractional accepted duration without mutation", () => {
  const estimate = estimateDroneCents({ ...shape, seconds: 1.25 });
  assertEquals(droneReservation(estimate), {
    unit_cents: 16,
    cents: 20,
    usd: "0.20",
    basis: "published_maximum_tariff",
  });
  assertEquals(estimate.cents, 5);
});
Deno.test("unreadable or zero-cost reservation quantities fail closed", () => {
  const estimate = estimateDroneCents(shape);
  for (const seconds of [0, -1, NaN, Infinity, Number.MAX_VALUE, 0.00000001]) {
    const err = assertThrows(
      () => droneReservation({ ...estimate, seconds }),
      HttpError,
    );
    assertEquals(err.status, 409);
  }
});
Deno.test("reservation rejects any duration above300 seconds instead of rounding it into the cap", () => {
  const estimate = estimateDroneCents(shape);
  for (const seconds of [300.00000001, 301, 410]) {
    const err = assertThrows(
      () => droneReservation({ ...estimate, seconds }),
      HttpError,
    );
    assertEquals(err.status, 400);
  }
  assertEquals(droneReservation(estimate).cents, DRONE_MAX_SUBMISSION_CENTS);
});
Deno.test("4K30 verified output costs 8c/s without a 60fps surcharge", () => {
  const est = submit("4k60", 300, 30);
  assertEquals(est.unit_cents, 8);
  assertEquals(est.cents, 2400);
});
Deno.test("4k30 request on a retained 60fps source costs the real 4K60 rate", () => {
  assertEquals(submit("4k30", 180, 60).cents, 2880);
});
Deno.test("verified geometry, not the requested label, selects the resolution tariff", () => {
  for (const tier of ["1080p60", "4k30", "4k60", "future-label"]) {
    assertEquals(
      estimateDroneCents({
        ...shape,
        tier,
        outputWidth: 1280,
        outputHeight: 720,
        outputFps: 30,
      }).unit_cents,
      1,
    );
    assertEquals(
      estimateDroneCents({
        ...shape,
        tier,
        outputWidth: 1920,
        outputHeight: 1080,
        outputFps: 30,
      }).unit_cents,
      2,
    );
    assertEquals(
      estimateDroneCents({
        ...shape,
        tier,
        outputWidth: 3840,
        outputHeight: 2160,
        outputFps: 30,
      }).unit_cents,
      8,
    );
  }
});
for (
  const [width, height, base] of [[1280, 720, 1], [1920, 1080, 2], [
    3840,
    2160,
    8,
  ]]
) {
  Deno.test(`oriented ${width}x${height} bounds apply equally to portrait output`, () => {
    for (
      const [outputWidth, outputHeight] of [[width, height], [height, width]]
    ) {
      assertEquals(
        estimateDroneCents({
          ...shape,
          outputWidth,
          outputHeight,
          outputFps: 30,
        }).unit_cents,
        base,
      );
      assertEquals(
        estimateDroneCents({
          ...shape,
          outputWidth,
          outputHeight,
          outputFps: 60,
        }).unit_cents,
        base * 2,
      );
    }
  });
}
Deno.test("a square or tall output cannot use only its long edge to get a cheap rate", () => {
  for (
    const [outputWidth, outputHeight] of [[1920, 1920], [1920, 1200], [
      1200,
      1920,
    ], [1280, 1080]]
  ) {
    const expected = Math.max(outputWidth, outputHeight) <= 1920 &&
        Math.min(outputWidth, outputHeight) <= 1080
      ? 4
      : 16;
    assertEquals(
      estimateDroneCents({ ...shape, outputWidth, outputHeight }).unit_cents,
      expected,
    );
  }
});
Deno.test("fractional output dimensions ceil before selecting the resolution bucket", () => {
  assertEquals(
    estimateDroneCents({
      ...shape,
      outputWidth: 1919.01,
      outputHeight: 1079.01,
    }).unit_cents,
    4,
  );
  for (
    const [outputWidth, outputHeight] of [[1920.00001, 1080], [
      1920,
      1080.00001,
    ]]
  ) {
    const est = estimateDroneCents({ ...shape, outputWidth, outputHeight });
    assertEquals(est.unit_cents, 16);
    assertEquals(est.output_width, Math.ceil(outputWidth));
    assertEquals(est.output_height, Math.ceil(outputHeight));
  }
  assertEquals(
    estimateDroneCents({
      ...shape,
      outputWidth: 1280.00001,
      outputHeight: 720,
      outputFps: 30,
    }).unit_cents,
    2,
  );
});
Deno.test("a rounded sent scale that crosses 1080p is priced above 1080p", () => {
  // Current nearest-hundredth factor: round(1920/1819*100)/100 = 1.06.
  // The actual bound is 1929x1086, despite the requested 1080 label.
  const factor = Math.round(1920 / 1819 * 100) / 100;
  assertEquals(factor, 1.06);
  const est = estimateDroneCents({
    ...shape,
    outputWidth: 1819 * factor,
    outputHeight: 1024 * factor,
  });
  assertEquals(est.output_width, 1929);
  assertEquals(est.output_height, 1086);
  assertEquals(est.cents, 4800);
});
Deno.test("the exact 4096 output boundary is allowed; any fractional excess fails", () => {
  assertEquals(
    estimateDroneCents({ ...shape, outputWidth: 4096, outputHeight: 2160 })
      .unit_cents,
    16,
  );
  for (
    const [outputWidth, outputHeight] of [[4096.00001, 2160], [
      2160,
      4096.00001,
    ], [8192, 4320]]
  ) {
    const err = assertThrows(
      () => estimateDroneCents({ ...shape, outputWidth, outputHeight }),
      HttpError,
    );
    assertEquals(err.status, 400);
  }
});
Deno.test("missing, nonfinite or nonpositive output dimensions fail closed", () => {
  for (
    const bad of [
      undefined,
      null,
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
      "1920",
    ]
  ) {
    for (const key of ["outputWidth", "outputHeight"]) {
      const err = assertThrows(
        () => estimateDroneCents({ ...shape, [key]: bad } as typeof shape),
        HttpError,
      );
      assertEquals(err.status, 409, `${key}:${bad}`);
      assertEquals(err.code, "conflict");
    }
  }
});
Deno.test("all supported frame rates through 30 use base rate; higher rates double", () => {
  for (const outputFps of [1, 23.976, 24, 25, 29.97, 30]) {
    assertEquals(estimateDroneCents({ ...shape, outputFps }).unit_cents, 2);
  }
  for (const outputFps of [30.00001, 48, 50, 59.94, 60]) {
    const est = estimateDroneCents({ ...shape, outputFps });
    assertEquals(est.unit_cents, 4);
    assertEquals(est.fps, outputFps);
    assertEquals(est.fps_multiplier, 2);
  }
});
Deno.test("unknown or nonpositive frame rate never defaults to a nominal tier", () => {
  for (
    const outputFps of [
      undefined,
      null,
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
      "60",
    ]
  ) {
    const err = assertThrows(
      () => estimateDroneCents({ ...shape, outputFps } as typeof shape),
      HttpError,
    );
    assertEquals(err.status, 409, String(outputFps));
  }
});
Deno.test("above 60fps fails closed rather than inventing a linear 120fps tariff", () => {
  for (const outputFps of [60.00001, 90, 120, 240]) {
    const err = assertThrows(
      () => estimateDroneCents({ ...shape, outputFps }),
      HttpError,
    );
    assertEquals(err.status, 409);
    assertStringIncludes(err.message, "60 fps");
  }
});
Deno.test("fractional seconds use the priced duration rather than truncating it", () => {
  assertEquals(estimateDroneCents({ ...shape, seconds: 1.25 }).cents, 5);
});
Deno.test("unknown or nonpositive duration is not a zero-cost estimate", () => {
  for (
    const seconds of [
      undefined,
      null,
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
      "300",
    ]
  ) {
    assertThrows(
      () => estimateDroneCents({ ...shape, seconds } as typeof shape),
      HttpError,
    );
  }
});
Deno.test("a finite duration cannot overflow into an unbounded expense", () => {
  const err = assertThrows(
    () => estimateDroneCents({ ...shape, seconds: Number.MAX_VALUE }),
    HttpError,
  );
  assertEquals(err.status, 409);
});
Deno.test("300 seconds is admitted; any longer verified output is refused", () => {
  for (const tier of Object.keys(DRONE_TIERS)) {
    submit(tier, 300);
    const err = assertThrows(() => submit(tier, 300.00001), HttpError);
    assertEquals(err.status, 400);
    assertEquals(err.details?.limit_seconds, 300);
  }
});
Deno.test("the 410-second refusal retains actionable duration copy and the actual price", () => {
  const err = assertThrows(() => submit("4k60", 410), HttpError);
  assertEquals(
    err.message,
    "This tour is 6 min 50 s. AI enhance is limited to 5 minutes — trim the tour or publish the standard version.",
  );
  assertEquals(err.details?.source_seconds, 410);
  assertEquals(err.details?.estimate_cents, 6560);
  assertEquals(err.details?.estimate_usd, "65.60");
});
Deno.test("duration is refused before the price ceiling for 301 seconds of 4K60", () => {
  const err = assertThrows(() => submit("4k60", 301), HttpError);
  assertEquals(err.details?.limit_seconds, 300);
  assertEquals(err.details?.limit_cents, undefined);
  assertEquals(err.details?.estimate_cents, 4816);
});
Deno.test("missing verified duration is an asset conflict, not a paywall", () => {
  for (
    const durationS of [
      undefined,
      null,
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
    ]
  ) {
    const err = assertThrows(
      () => assertDroneWithinLimits({ ...shape, durationS, assetId: "a-7" }),
      HttpError,
    );
    assertEquals(err.status, 409);
    assertEquals(err.code, "conflict");
    assertStringIncludes(err.message, "duration_s");
    assertStringIncludes(err.message, "a-7");
  }
});

// ── Composition with the EXISTING per-org monthly ceiling ────────────────────

Deno.test("monthly ceiling: a team org with headroom passes", () => {
  // team: cogs_ceiling_cents = 6000c ($60.00, migration 0044), topaz_per_month = 2.
  assertMonthlyHeadroom({
    monthSpentCents: 1000,
    ceilingCents: 6000,
    projectedCents: 2400,
    plan: "team",
    feature: "drone-glide render",
  });
});

Deno.test("monthly ceiling: a lower geometry estimate cannot admit two maximum-length reservations", () => {
  const estimate = submit("4k30", 300, 30);
  const tap = droneReservation(estimate).cents;
  assertEquals(estimate.cents, 2400);
  assertEquals(tap, 4800);
  const err = assertThrows(() =>
    assertMonthlyHeadroom({
      monthSpentCents: tap,
      ceilingCents: 6000,
      projectedCents: tap,
      plan: "team",
      feature: "drone-glide render",
    }), HttpError);
  assertEquals(err.status, 402);
});

Deno.test("monthly ceiling: the MONTH is what bounds a $48.00 tap, and it still does", () => {
  // Raising the per-tap ceiling to $48.00 did not raise monthly exposure: team
  // gets 2 Topaz taps against a 6,000c ceiling (0044), so a second maxed-out tap
  // is 2 x 4,800 = 9,600c > 6,000c and is refused HERE. Max drone exposure per org
  // per month stays ~$48-60, enforced by machinery that already existed.
  const worstTap = DRONE_MAX_SUBMISSION_CENTS;
  assertEquals(worstTap, 4800);
  // The first tap fits.
  assertMonthlyHeadroom({
    monthSpentCents: 0,
    ceilingCents: 6000,
    projectedCents: worstTap,
    plan: "team",
    feature: "drone-glide render",
  });
  // The second does not.
  const err = assertThrows(
    () =>
      assertMonthlyHeadroom({
        monthSpentCents: worstTap,
        ceilingCents: 6000,
        projectedCents: worstTap,
        plan: "team",
        feature: "drone-glide render",
      }),
    HttpError,
  );
  assertEquals(err.status, 402);
  assertEquals(err.code, "quota_exceeded");
});

Deno.test("monthly ceiling: a submission that would breach it is refused, 402 quota_exceeded", () => {
  const err = assertThrows(
    () =>
      assertMonthlyHeadroom({
        monthSpentCents: 4800,
        ceilingCents: 6000,
        projectedCents: 2400,
        plan: "team",
        feature: "drone-glide render",
      }),
    HttpError,
  );
  // Matches what throwRpc() maps log_job_cost()'s own "monthly AI spend ceiling
  // reached" RP402 to, so the app's existing isQuota branch handles it.
  assertEquals(err.status, 402);
  assertEquals(err.code, "quota_exceeded");
  assertStringIncludes(err.message, "$48.00");
  assertStringIncludes(err.message, "$60.00");
  assertStringIncludes(err.message, "$24.00");
  assertEquals(err.details?.spent_cents, 4800);
  assertEquals(err.details?.ceiling_cents, 6000);
  assertEquals(err.details?.estimate_cents, 2400);
});

Deno.test("monthly ceiling: exactly reaching the ceiling is allowed; one cent over is not", () => {
  assertMonthlyHeadroom({
    monthSpentCents: 3600,
    ceilingCents: 6000,
    projectedCents: 2400,
    plan: "team",
    feature: "drone-glide render",
  });
  assertThrows(
    () =>
      assertMonthlyHeadroom({
        monthSpentCents: 3601,
        ceilingCents: 6000,
        projectedCents: 2400,
        plan: "team",
        feature: "drone-glide render",
      }),
    HttpError,
  );
});

Deno.test("monthly ceiling: no configured ceiling is not enforced (mirrors the RPC)", () => {
  // log_job_cost() only enforces `if v_ceiling is not null` — an unset ceiling
  // must not become an accidental $0.00 budget that refuses everything.
  assertMonthlyHeadroom({
    monthSpentCents: 999_999,
    ceilingCents: 0,
    projectedCents: 2400,
    plan: "team",
    feature: "drone-glide render",
  });
});

Deno.test("monthly preflight: an over-ceiling projection is refused even with an unreadable spend total", () => {
  // The route must reject an unreadable spend total before this legacy helper.
  // This case only proves that the finite oversized projection is refused.
  assertThrows(
    () =>
      assertMonthlyHeadroom({
        monthSpentCents: Number.NaN,
        ceilingCents: 1000,
        projectedCents: 2400,
        plan: "team",
        feature: "drone-glide render",
      }),
    HttpError,
  );
});

// ── The estimate the SUCCESS path returns ────────────────────────────────────

Deno.test("success estimate: every field the 202 promises is present and consistent", () => {
  const est = submit("4k60", 150);
  assertEquals(est.tier, "4k60");
  assertEquals(est.seconds, 150);
  assertEquals(est.fps, 60);
  assertEquals(est.output_width, 3840);
  assertEquals(est.output_height, 2160);
  assertEquals(est.resolution_bucket, "above1080p");
  assertEquals(est.resolution_unit_cents, 8);
  assertEquals(est.fps_multiplier, 2);
  assertEquals(est.unit_cents, 16.0);
  assertEquals(est.cents, 2400);
  assertEquals(est.usd, "24.00");
  assertEquals(est.ceiling_cents, DRONE_MAX_SUBMISSION_CENTS);
  // usd is a formatting of cents, never an independently-derived number.
  assertEquals(est.usd, centsToUsd(est.cents));
  // cents is unit_cents x seconds, so a client can re-check the arithmetic.
  assertEquals(est.cents, est.unit_cents * est.seconds);
});

Deno.test("success estimate: the interpolation target is what gets priced", () => {
  // A 30 fps source on the 4k60 tier IS interpolated to 60 fps, so it is priced
  // at the full 4K60 rate — the estimate follows the output, not the input.
  const est = submit("4k60", 100, 60);
  assertEquals(est.fps, 60);
  assertEquals(est.cents, 1600);
});

// ── Copy helpers ─────────────────────────────────────────────────────────────

Deno.test("formatDuration: the shapes the refusals are written in", () => {
  assertEquals(formatDuration(410), "6 min 50 s");
  assertEquals(formatDuration(300), "5 min");
  assertEquals(formatDuration(156), "2 min 36 s");
  assertEquals(formatDuration(42), "42 s");
  assertEquals(formatDuration(60), "1 min");
});

Deno.test("formatDurationLimit: a cap is said as a rule, not as a measurement", () => {
  assertEquals(formatDurationLimit(300), "5 minutes");
  assertEquals(formatDurationLimit(60), "1 minute");
  // Off a whole minute it falls back rather than lying about the number.
  assertEquals(formatDurationLimit(330), "5 min 30 s");
});

// ── Wiring: the guard is only worth anything where it sits ──────────────────
//
// index.ts calls Deno.serve at module load, so it cannot be imported and the
// route cannot be exercised in-process. Grep its source instead — the same
// approach admin/probe.test.ts uses for its own "no SSRF surface" invariants.
// The ORDER these appear in is the entire safety property: a guard that ran
// after guardGenerate() would burn an org's monthly Topaz allowance on a
// submission it then refuses, and one that ran after runChain() would refuse a
// job fal had already accepted and billed for.

const INDEX_SRC = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
const DRONE_ROUTE = INDEX_SRC.slice(
  INDEX_SRC.indexOf("// ---- POST /ai-video/drone ----"),
  INDEX_SRC.indexOf("// ---- POST /ai-video/aerial ----"),
);

Deno.test("wiring: the drone route actually calls the guard", () => {
  assert(
    DRONE_ROUTE.length > 500,
    "failed to slice the drone route out of index.ts",
  );
  assertStringIncludes(DRONE_ROUTE, "assertDroneWithinLimits({");
});

Deno.test("wiring: the guard runs BEFORE any quota is charged", () => {
  const guard = DRONE_ROUTE.indexOf("assertDroneWithinLimits({");
  const reservePrice = DRONE_ROUTE.indexOf("droneReservation(estimate)");
  const charge = DRONE_ROUTE.indexOf("await guardGenerate(");
  assert(guard > 0 && charge > 0, "both call sites must exist");
  assert(guard < charge, "assertDroneWithinLimits must precede guardGenerate");
  assert(
    guard < reservePrice && reservePrice < charge,
    "the conservative reservation price must exist before allowance admission",
  );
});

Deno.test("wiring: the guard runs BEFORE the provider is called", () => {
  const guard = DRONE_ROUTE.indexOf("assertDroneWithinLimits({");
  const submit = DRONE_ROUTE.indexOf("await submitReservedVideo(");
  assert(guard > 0 && submit > 0, "both call sites must exist");
  assert(
    guard < submit,
    "nothing may reach a provider before the cost ceilings run",
  );
});

Deno.test("wiring: the projected cost is composed with the org's monthly ceiling", () => {
  // Passed into guardGenerate so the check lands after the plan boundary and
  // before every meter — see guardGenerate's own comment.
  assertStringIncludes(
    DRONE_ROUTE,
    'guardGenerate(user, req, "drone", reservation.cents, asset.org_id, asset.listing_id ?? undefined)',
  );
  assertStringIncludes(INDEX_SRC, "assertMonthlyHeadroom({");
  // The ceiling and the spend total are the SAME two the RPC compares, read
  // rather than re-implemented.
  assertStringIncludes(INDEX_SRC, "org_month_spend_cents");
  assertStringIncludes(INDEX_SRC, "ceilingCents: ent.cogs_ceiling_cents");
});

Deno.test("wiring: the estimate is returned on the SUCCESS path", () => {
  // The 202 the app decodes. `estimated_cost` is a NEW key on the existing
  // object, never a rename — AIVideoJobDTO decodes only the fields it names.
  assertStringIncludes(DRONE_ROUTE, "estimated_cost: estimate,");
  assertStringIncludes(DRONE_ROUTE, "reserved_cost: reservation,");
  for (
    const shipped of [
      "kind:",
      "model_id:",
      "tier,",
      "target_fps:",
      "upscale_factor:",
      "interpolated:",
      "source: {",
    ]
  ) {
    assertStringIncludes(DRONE_ROUTE, shipped);
  }
});

Deno.test("wiring: a priced submission uses the durable cost reservation and atomic settlement", () => {
  // The helper commits a hold before POST. It atomically settles a receipt or
  // retains that hold if the ledger is unavailable, rather than losing spend.
  assertStringIncludes(DRONE_ROUTE, "submitReservedVideo({");
  assertStringIncludes(DRONE_ROUTE, "minHoldCents: reservation.cents");
  assertStringIncludes(
    DRONE_ROUTE,
    "unitCentsOverride: () => reservation.unit_cents",
  );
  assert(!DRONE_ROUTE.includes("recordRoutedAiCost(adminClient(), {"));
  assert(
    !DRONE_ROUTE.includes("F-E-15 residual gap)"),
    "the unpriced-submit branch must not come back",
  );
});

Deno.test("trimNumber: a rate is said the way a person says it", () => {
  assertEquals(trimNumber(16.0), "16");
  assertEquals(trimNumber(4.8), "4.8");
  assertEquals(trimNumber(8), "8");
});

Deno.test("centsToUsd / affordableSeconds: the two numbers the copy quotes", () => {
  assertEquals(centsToUsd(4800), "48.00");
  assertEquals(centsToUsd(6560), "65.60");
  assertEquals(affordableSeconds(32.0), 150); // floor(4800/32) — never rounds up
  assertEquals(affordableSeconds(16.0), 300); // a full-length tour, by derivation
  // Clamped to the duration cap: never advise trimming TO a length the other
  // guard would refuse anyway (4800/8 = 600 s, but 300 s is the rule).
  assertEquals(affordableSeconds(8.0), DRONE_MAX_SOURCE_SECONDS);
  assertEquals(affordableSeconds(4.0), DRONE_MAX_SOURCE_SECONDS);
  assertEquals(affordableSeconds(0), 0); // no divide-by-zero on a $0 unit price
});
