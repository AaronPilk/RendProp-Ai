// dronecost.test.ts — the /ai-video/drone cost ceilings.
//
//   deno test --allow-env --allow-read services/supabase/functions/ai-video/dronecost.test.ts
//
// (`--allow-env` only because _shared/ledger.ts, where the rate card lives,
// reads MAX_GEN_COST_PER_JOB_CENTS from the environment at module load;
// `--allow-read` only for the WIRING section at the bottom, which greps
// index.ts's own source. Nothing here touches the network or a Supabase
// client, and the guard itself is pure.)
//
// These cover the guard that would have stopped the 4,000 sq ft field test: a
// 410 s 4K60 tour that billed ~$48 from one tap, accepted by the route without
// a ceiling, a confirmation or an estimate. Pure module, no Deno.serve — see
// dronecost.ts's header for why this lives apart from index.ts.

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
  DRONE_MAX_SOURCE_SECONDS,
  DRONE_MAX_SUBMISSION_CENTS,
  DRONE_TIER_CENTS,
  DRONE_TIERS,
  estimateDroneCents,
  formatDuration,
  formatDurationLimit,
  trimNumber,
} from "./dronecost.ts";

/** A submission at the tier's own nominal frame rate — the ordinary case. */
function submit(tier: string, seconds: number, outputFps = DRONE_TIERS[tier].fps) {
  return assertDroneWithinLimits({ tier, durationS: seconds, outputFps, assetId: "asset-1" });
}

// ── The rate card the limits are derived from ────────────────────────────────
//
// If any of these move, every arithmetic comment in dronecost.ts is stale and
// the limits need re-deriving — which is the point of asserting them here.

Deno.test("rate card: the tier prices are the committed APP_AI_UNIT_CENTS numbers", () => {
  assertEquals(DRONE_TIER_CENTS["1080p60"], 4.0);
  assertEquals(DRONE_TIER_CENTS["4k30"], 8.0);
  assertEquals(DRONE_TIER_CENTS["4k60"], 16.0);
  // Not merely equal by coincidence — they ARE the ledger's constants, so the
  // three-way lockstep with costs.py and the admin inventory still holds.
  assertEquals(DRONE_TIER_CENTS["1080p60"], APP_AI_UNIT_CENTS.topaz_1080p60_per_s);
  assertEquals(DRONE_TIER_CENTS["4k30"], APP_AI_UNIT_CENTS.topaz_4k30_per_s);
  assertEquals(DRONE_TIER_CENTS["4k60"], APP_AI_UNIT_CENTS.topaz_4k60_per_s);
});

Deno.test("limits: the per-submission ceiling is DERIVED from the duration cap", () => {
  // 300 s x 16.0c = 4,800c = $48.00 — what the duration cap already implies at
  // the most expensive tier, so the two guards cannot contradict each other.
  assertEquals(DRONE_MAX_SUBMISSION_CENTS, 4800);
  assertEquals(
    DRONE_MAX_SUBMISSION_CENTS,
    DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS["4k60"],
    "the ceiling must stay a derivation, never a separately-picked number",
  );
});

Deno.test("limits: 300 s is the rule, and no tier's full-length tour contradicts it", () => {
  assertEquals(DRONE_MAX_SOURCE_SECONDS, 300);
  assertEquals(DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS["1080p60"], 1200); // $12.00
  assertEquals(DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS["4k30"], 2400); // $24.00 nominal
  assertEquals(DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS["4k60"], 4800); // $48.00 worst case
  // The property the derivation buys: a full-length tour at ANY tier passes the
  // cost ceiling, so the duration rule is what binds every legitimate submission.
  for (const tier of Object.keys(DRONE_TIERS)) {
    assert(
      DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS[tier] <= DRONE_MAX_SUBMISSION_CENTS,
      `${tier} at the duration cap must not be refused on price`,
    );
  }
});

// ── Under the limit: it passes, and the estimate is right ────────────────────

Deno.test("under the limit: a 90 s 4k30 tour passes and is priced at $7.20", () => {
  // 90 s is the canonical tour the whole cost model is built on ("Topaz 90s
  // @4K30 $7.20", migration 0010's header).
  const est = submit("4k30", 90);
  assertEquals(est.cents, 720);
  assertEquals(est.usd, "7.20");
  assertEquals(est.seconds, 90);
  assertEquals(est.unit_cents, 8.0);
  assertEquals(est.tier, "4k30");
  assertEquals(est.ceiling_cents, 4800);
});

Deno.test("under the limit: 90 s at each tier matches migration 0010's own numbers", () => {
  assertEquals(submit("1080p60", 90).usd, "3.60"); // "Topaz 90s @1080p60 $3.60"
  assertEquals(submit("4k30", 90).usd, "7.20"); // "@4K30 $7.20"
  assertEquals(submit("4k60", 90).usd, "14.40"); // "@4K60 $14.40"
});

Deno.test("under the limit: exactly at the duration cap is ALLOWED, not off by one", () => {
  const est = submit("4k30", DRONE_MAX_SOURCE_SECONDS);
  assertEquals(est.cents, 2400);
  assertEquals(est.usd, "24.00");
});

Deno.test("under the limit: a full-length 4K60 tour sits exactly ON the ceiling and passes", () => {
  // 300 s x 16.0 = 4,800c = $48.00 — the derivation, met exactly. This is the
  // case the old $25.00 ceiling refused, and the reason it was replaced: a
  // 4,000 sq ft walk renders to a 240-300 s master and has to keep working.
  const est = submit("4k60", DRONE_MAX_SOURCE_SECONDS);
  assertEquals(est.cents, DRONE_MAX_SUBMISSION_CENTS);
  assertEquals(est.usd, "48.00");
});

Deno.test("under the limit: the 4,000 sq ft master passes on BOTH paid tiers", () => {
  // A 240-300 s master at the 16.0c/s both paid tiers really run at (the app
  // renders 60 fps, so "4k30" emits 4K60 — see the tier-nominal note).
  for (const seconds of [240, 270, 300]) {
    assertEquals(
      assertDroneWithinLimits({ tier: "4k30", durationS: seconds, outputFps: 60, assetId: "a" })
        .unit_cents,
      16.0,
    );
    submit("4k60", seconds);
  }
});

// ── Over the DURATION limit ──────────────────────────────────────────────────

Deno.test("over the duration limit: the field test's 410 s tour is refused, at every tier", () => {
  // The incident: a 410 s 4K60 tour billed ~$48 from one tap. At the rate card
  // this repo commits it is 410 x 16.0c = 6,560c = $65.60.
  for (const tier of Object.keys(DRONE_TIERS)) {
    const err = assertThrows(() => submit(tier, 410), HttpError, undefined, tier);
    assertEquals(err.status, 400, tier);
    assertEquals(err.code, "validation", tier);
  }
});

Deno.test("over the duration limit: the message is the sentence a human can act on", () => {
  const err = assertThrows(() => submit("4k60", 410), HttpError);
  // 410 s = 6 min 50 s — said in the copy the app shows verbatim.
  assertEquals(
    err.message,
    "This tour is 6 min 50 s. AI enhance is limited to 5 minutes — " +
      "trim the tour or publish the standard version.",
  );
});

Deno.test("over the duration limit: the refusal carries the numbers, not just prose", () => {
  const err = assertThrows(() => submit("4k60", 410), HttpError);
  assertEquals(err.details?.limit_seconds, 300);
  assertEquals(err.details?.source_seconds, 410);
  // 410 x 16.0 = 6,560c — what the field test would have cost at the committed
  // rate card, handed to the client so it can say so.
  assertEquals(err.details?.estimate_cents, 6560);
  assertEquals(err.details?.estimate_usd, "65.60");
});

Deno.test("over the duration limit: one second over is refused (the boundary is exact)", () => {
  const err = assertThrows(() => submit("1080p60", DRONE_MAX_SOURCE_SECONDS + 1), HttpError);
  assertEquals(err.status, 400);
  // Even though 301 s of 1080p60 is only $12.04 — the duration cap is a product
  // rule, not a price one, so a cheap tier does not buy past it.
  assertEquals(err.details?.estimate_usd, "12.04");
});

Deno.test("over the duration limit: 301 s of 4K60 is refused on DURATION, not on cost", () => {
  // 301 x 16.0 = 4,816c, sixteen cents over the ceiling — so BOTH guards would
  // fire and the ORDER decides which sentence the agent reads. Length is the
  // one they can act on by trimming, so the duration check runs first.
  const err = assertThrows(() => submit("4k60", DRONE_MAX_SOURCE_SECONDS + 1), HttpError);
  assertEquals(err.status, 400);
  assertStringIncludes(err.message, "AI enhance is limited to 5 minutes");
  assertEquals(err.details?.limit_seconds, DRONE_MAX_SOURCE_SECONDS);
  assertEquals(err.details?.limit_cents, undefined, "this is a length refusal, not a price one");
  assertEquals(err.details?.estimate_cents, 4816);
});

// ── Over the COST ceiling ────────────────────────────────────────────────────

Deno.test("over the cost ceiling: a legal-length tour with an out-of-line PRICE is refused", () => {
  // 300 s is exactly at the duration cap, so the length guard passes it. Asking
  // for 120 fps on the 4k30 tier prices it at 8.0 x (120/30) = 32.0c/s — four
  // times the rate a 5-minute tour should carry — so 300 x 32.0 = 9,600c =
  // $96.00 and the COST ceiling is what stops it. This is the job only the cost
  // ceiling can do now that the duration cap is the binding rule elsewhere.
  const err = assertThrows(
    () => assertDroneWithinLimits({ tier: "4k30", durationS: 300, outputFps: 120, assetId: "a" }),
    HttpError,
  );
  assertEquals(err.status, 400);
  assertEquals(err.code, "validation");
  assertEquals(err.details?.estimate_cents, 9600);
  assertEquals(err.details?.limit_cents, 4800);
  assertStringIncludes(err.message, "$96.00");
  assertStringIncludes(err.message, "capped at $48.00");
  // The rate that produced the price is named, not just the total.
  assertStringIncludes(err.message, "120 fps output at 32¢ per second");
  // It names the length that WOULD fit, so the agent can trim to it.
  assertEquals(err.details?.fits_seconds, 150);
  assertStringIncludes(err.message, "2 min 30 s");
});

Deno.test("over the cost ceiling: the same 300 s tour PASSES at the tier's own frame rate", () => {
  // The refusal says "pick a lower tier" — it has to actually be true.
  assertEquals(submit("4k30", 300).usd, "24.00");
  assertEquals(submit("1080p60", 300).usd, "12.00");
});

Deno.test("over the cost ceiling: a frame-rate override cannot buy the cheap tier's price", () => {
  // {tier:"4k30", target_fps:120} renders four times the output pixel-frames
  // Topaz charges for, at the 4K30 rate. Priced on the tier alone a 200 s tour
  // is 200 x 8.0 = $16.00 and sails through; priced on the OUTPUT frame rate it
  // is 200 x (8.0 x 120/30) = 200 x 32.0 = 6,400c = $64.00 and is refused.
  // The multiplier is the whole reason the cost ceiling still has teeth.
  const cheap = estimateDroneCents({ tier: "4k30", seconds: 200, outputFps: 30 });
  assertEquals(cheap.cents, 1600);

  const err = assertThrows(
    () => assertDroneWithinLimits({ tier: "4k30", durationS: 200, outputFps: 120, assetId: "a" }),
    HttpError,
  );
  assertEquals(err.status, 400);
  assertEquals(err.details?.estimate_cents, 6400);
  assertStringIncludes(err.message, "$64.00");
  // The message has to explain WHY a "4k30" tap priced at four times the 4K30
  // rate, or "pick a lower tier" is unactionable advice.
  assertEquals(err.details?.estimate_unit_cents, 32);
  assertEquals(err.details?.estimate_fps, 120);
  assertStringIncludes(err.message, "120 fps output at 32¢ per second");
});

Deno.test("estimate: a 60 fps master on the \"4k30\" tier is priced as the 4K60 job it is", () => {
  // The shipped app renders its master at 60 fps (RenderEngine.outputFPS) and
  // the 4K Premium tier asks for target_fps 30 — which index.ts turns into NO
  // interpolation request, because the source already runs at/above it. Topaz
  // then emits 4K at 60 fps and fal charges the 4K60 pixel-frame rate, while
  // the tier price says 8.0c/s. The estimate follows the OUTPUT, which is why
  // the ceiling is derived from 16.0c/s: at BOTH paid tiers that is the real
  // rate, so a 3 min tour costs $28.80 and must PASS, not be refused.
  const est = estimateDroneCents({ tier: "4k30", seconds: 180, outputFps: 60 });
  assertEquals(est.unit_cents, 16.0);
  assertEquals(est.cents, 2880);
  assertEquals(
    assertDroneWithinLimits({ tier: "4k30", durationS: 180, outputFps: 60, assetId: "a" }).usd,
    "28.80",
  );
});

Deno.test("estimate: a BELOW-tier frame rate never discounts under the rate card", () => {
  // A 24 fps source with no interpolation on the 4k60 tier must still be priced
  // at 16.0c/s, not 16.0 x 24/60 = 6.4c/s. The multiplier is floored at 1x.
  const est = estimateDroneCents({ tier: "4k60", seconds: 100, outputFps: 24 });
  assertEquals(est.unit_cents, 16.0);
  assertEquals(est.cents, 1600);
});

Deno.test("estimate: an unknown tier prices at the most expensive tier, never cheap", () => {
  // index.ts rejects unknown tiers before this is reached; this is the
  // fail-closed branch, asserted so a future tier cannot default to $0.
  const est = estimateDroneCents({ tier: "8k120", seconds: 10, outputFps: 60 });
  assertEquals(est.unit_cents, APP_AI_UNIT_CENTS.topaz_4k60_per_s);
});

// ── Missing duration: fails CLOSED ───────────────────────────────────────────

Deno.test("missing duration: null is REFUSED, never submitted unpriced", () => {
  const err = assertThrows(
    () => assertDroneWithinLimits({ tier: "4k30", durationS: null, outputFps: 30, assetId: "a-7" }),
    HttpError,
  );
  // Same shape /ai-video/declutter already uses for the same missing field, so
  // the app has one behaviour to handle rather than two.
  assertEquals(err.status, 409);
  assertEquals(err.code, "conflict");
  assertStringIncludes(err.message, "duration_s");
  assertStringIncludes(err.message, "a-7"); // names the row for an operator
});

Deno.test("missing duration: undefined, 0, negative and NaN are all refused", () => {
  for (const bad of [undefined, 0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    const err = assertThrows(
      () => assertDroneWithinLimits({ tier: "4k30", durationS: bad, outputFps: 30, assetId: "a" }),
      HttpError,
      undefined,
      String(bad),
    );
    assertEquals(err.status, 409, String(bad));
  }
});

Deno.test("missing duration: the refusal is NOT a plan/quota error the app would paywall", () => {
  // 402 would push the StoreKit paywall at someone whose upload metadata is
  // simply incomplete. It has to read as "this asset can't be used", not
  // "you need a bigger plan".
  const err = assertThrows(
    () => assertDroneWithinLimits({ tier: "4k30", durationS: null, outputFps: 30, assetId: "a" }),
    HttpError,
  );
  assert(err.status !== 402);
  assert(err.code !== "plan_required" && err.code !== "quota_exceeded");
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

Deno.test("monthly ceiling: two maxed default taps still fit inside the team budget", () => {
  // The sizing claim from dronecost.ts, asserted: 2 x $24.00 = $48.00 of $60.00.
  const tap = DRONE_MAX_SOURCE_SECONDS * DRONE_TIER_CENTS["4k30"];
  assertEquals(tap * 2, 4800);
  assertMonthlyHeadroom({
    monthSpentCents: tap,
    ceilingCents: 6000,
    projectedCents: tap,
    plan: "team",
    feature: "drone-glide render",
  });
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

Deno.test("monthly ceiling: an unreadable spend total is treated as 0, never as headroom", () => {
  // index.ts fails closed with a 503 before this is reached; if a NaN ever does
  // arrive, it must not silently satisfy the comparison.
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
  INDEX_SRC.indexOf('seg[0] === "drone"'),
  INDEX_SRC.indexOf('seg[0] === "declutter"'),
);

Deno.test("wiring: the drone route actually calls the guard", () => {
  assert(DRONE_ROUTE.length > 500, "failed to slice the drone route out of index.ts");
  assertStringIncludes(DRONE_ROUTE, "assertDroneWithinLimits({");
});

Deno.test("wiring: the guard runs BEFORE any quota is charged", () => {
  const guard = DRONE_ROUTE.indexOf("assertDroneWithinLimits({");
  const charge = DRONE_ROUTE.indexOf("await guardGenerate(");
  assert(guard > 0 && charge > 0, "both call sites must exist");
  assert(guard < charge, "assertDroneWithinLimits must precede guardGenerate");
});

Deno.test("wiring: the guard runs BEFORE the provider is called", () => {
  const guard = DRONE_ROUTE.indexOf("assertDroneWithinLimits({");
  const submit = DRONE_ROUTE.indexOf("await runChain(");
  assert(guard > 0 && submit > 0, "both call sites must exist");
  assert(guard < submit, "nothing may reach a provider before the cost ceilings run");
});

Deno.test("wiring: the projected cost is composed with the org's monthly ceiling", () => {
  // Passed into guardGenerate so the check lands after the plan boundary and
  // before every meter — see guardGenerate's own comment.
  assertStringIncludes(DRONE_ROUTE, 'guardGenerate(user.id, req, "drone", estimate.cents)');
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
  for (const shipped of ["kind:", "model_id:", "tier,", "target_fps:", "upscale_factor:", "interpolated:", "source: {"]) {
    assertStringIncludes(DRONE_ROUTE, shipped);
  }
});

Deno.test("wiring: a priced submission always writes its cost_ledger row", () => {
  // The old F-E-15 residual gap — submit anyway, console.warn, record nothing —
  // is gone, because a submission with no duration is now refused outright.
  assertStringIncludes(DRONE_ROUTE, "recordRoutedAiCost(adminClient(), {");
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
