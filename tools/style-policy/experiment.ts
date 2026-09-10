import {
  canonical,
  check,
  digest,
  frozen,
  hash,
  id,
  list,
  number,
  object,
  oneOf,
  unique,
} from "./common.ts";
import { resolveStyle } from "./policy.ts";

export const METRICS = Object.freeze(
  [
    "property_fidelity",
    "speech_visual_match",
    "pacing",
    "caption_legibility",
    "opening_clarity",
    "temporal_stability",
  ] as const,
);
export const DEFECTS = Object.freeze(
  [
    "property_facts",
    "geometry",
    "privacy",
    "fair_housing",
    "original_audio_timeline",
  ] as const,
);
export const STRATA = Object.freeze(
  ["tight", "reflective", "broad", "exterior", "detail", "mixed"] as const,
);
export const PROTOCOL = frozen({
  schema_version: 1,
  pairs: 24,
  raters: 3,
  judgments: 72,
  variants: 48,
  strata: STRATA,
  per_stratum: 4,
  metrics: METRICS,
  metric_range: [1, 5],
  critical_defects: DEFECTS,
  weights: [1, 1, 1, 1, 1, 1],
  candidate_majority_threshold: 18,
  ties_are_wins: false,
  no_new_critical_defects: true,
  property_fidelity_median_must_not_decrease: true,
  early_stopping: false,
  quality_win_claimed: false,
});
type Registration = {
  schema_version: 1;
  experiment_id: string;
  seed: string;
  evidence_kind: "synthetic" | "cleared-existing";
  baseline_config_sha256: string;
  candidate_config_sha256: string;
  candidate_style: { id: string; version: number; sha256: string };
  raters: string[];
  fixtures: {
    listing_id: string;
    input_sha256: string;
    stratum: string;
    rights_reference: string;
  }[];
};
type Seal = {
  registration: Registration;
  protocol: typeof PROTOCOL;
  commitment: string;
};

export async function preregister(raw: unknown): Promise<Readonly<Seal>> {
  const r = object(raw, [
    "schema_version",
    "experiment_id",
    "seed",
    "evidence_kind",
    "baseline_config_sha256",
    "candidate_config_sha256",
    "candidate_style",
    "raters",
    "fixtures",
  ]);
  check(r.schema_version === 1, "unknown registration version");
  id(r.experiment_id);
  digest(r.seed);
  oneOf(r.evidence_kind, ["synthetic", "cleared-existing"]);
  digest(r.baseline_config_sha256);
  digest(r.candidate_config_sha256);
  check(
    r.baseline_config_sha256 !== r.candidate_config_sha256,
    "no declared treatment contrast",
  );
  const style = await resolveStyle(r.candidate_style);
  check(style.kind === "selected", "candidate style must be pinned");
  const raters = list(r.raters, 3, 3).map(id);
  unique(raters);
  const fixtures = list(r.fixtures, 24, 24).map((item) => {
    const f = object(item, [
      "listing_id",
      "input_sha256",
      "stratum",
      "rights_reference",
    ]);
    id(f.listing_id);
    digest(f.input_sha256);
    oneOf(f.stratum, STRATA);
    id(f.rights_reference);
    return f;
  });
  unique(fixtures.map((f) => f.listing_id));
  unique(fixtures.map((f) => f.input_sha256));
  for (const stratum of STRATA) {
    check(
      fixtures.filter((f) => f.stratum === stratum).length === 4,
      "stratum count must be four",
    );
  }
  const payload = {
    registration: frozen(r) as unknown as Registration,
    protocol: PROTOCOL,
  };
  return frozen({ ...payload, commitment: await hash(payload) });
}
export async function validateSeal(raw: unknown): Promise<Readonly<Seal>> {
  const s = object(raw, ["registration", "protocol", "commitment"]);
  digest(s.commitment);
  check(
    canonical(s.protocol) === canonical(PROTOCOL),
    "locked protocol changed",
  );
  const expected = await preregister(s.registration);
  check(
    expected.commitment === s.commitment,
    "registration commitment mismatch",
  );
  return expected;
}
type Slot = { pair_id: string; rater_id: string; A: string; B: string };
async function assetId(
  seal: Readonly<Seal>,
  listing: string,
  variant: string,
): Promise<string> {
  return `asset-${
    (await hash([
      "asset-label",
      seal.registration.seed,
      seal.commitment,
      listing,
      variant,
    ])).slice(0, 32)
  }`;
}
async function assignments(seal: Readonly<Seal>): Promise<Slot[]> {
  const result: Slot[] = [];
  for (const rater of seal.registration.raters) {
    const ranked = await Promise.all(
      seal.registration.fixtures.map(async (f) => ({
        fixture: f,
        order: await hash([
          "side-allocation",
          seal.registration.seed,
          rater,
          f.listing_id,
        ]),
      })),
    );
    ranked.sort((a, b) => a.order < b.order ? -1 : a.order > b.order ? 1 : 0);
    const perRater: { slot: Slot; display: string }[] = [];
    for (const [i, { fixture }] of ranked.entries()) {
      const baseline = await assetId(seal, fixture.listing_id, "baseline");
      const candidate = await assetId(seal, fixture.listing_id, "candidate");
      perRater.push({
        slot: {
          pair_id: `pair-${
            (await hash([seal.commitment, fixture.listing_id])).slice(0, 32)
          }`,
          rater_id: rater,
          A: i < 12 ? candidate : baseline,
          B: i < 12 ? baseline : candidate,
        },
        display: await hash([
          "display-order",
          seal.registration.seed,
          rater,
          fixture.listing_id,
        ]),
      });
    }
    // Side balance is NOT display order: first-half position must not reveal A/B.
    perRater.sort((a, b) =>
      a.display < b.display ? -1 : a.display > b.display ? 1 : 0
    );
    result.push(...perRater.map((entry) => entry.slot));
  }
  return result;
}
export async function blindAssignments(raw: unknown) {
  const bound = await validateBound(raw);
  const seal = bound.seal;
  // Reviewers receive only this packet and opaque media, NOT the registration.
  return frozen({
    commitment: seal.commitment,
    asset_manifest_sha256: bound.asset_manifest_sha256,
    rubric: PROTOCOL,
    assignments: await assignments(seal),
    notice:
      "Offline review packet. Assignment labels hide policy identity, not visible stylistic differences.",
  });
}
export async function expectedAssets(raw: unknown) {
  const seal = await validateSeal(raw);
  const assets = [];
  for (const fixture of seal.registration.fixtures) {
    for (const variant of ["baseline", "candidate"] as const) {
      assets.push({
        asset_id: await assetId(seal, fixture.listing_id, variant),
        listing_id: fixture.listing_id,
        variant,
        input_sha256: fixture.input_sha256,
        config_sha256: seal.registration[`${variant}_config_sha256`],
      });
    }
  }
  return frozen(assets);
}
type Rating = {
  metrics: Record<string, number>;
  defects: Record<string, boolean>;
};
function rating(raw: unknown): Rating {
  const r = object(raw, ["metrics", "defects"]);
  const metrics = object(r.metrics, METRICS);
  for (const metric of METRICS) number(metrics[metric], 1, 5, true);
  const defects = object(r.defects, DEFECTS);
  for (const defect of DEFECTS) {
    check(typeof defects[defect] === "boolean", "defect score must be boolean");
  }
  return {
    metrics: metrics as Record<string, number>,
    defects: defects as Record<string, boolean>,
  };
}
function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return (sorted[(sorted.length - 1) >> 1] + sorted[sorted.length >> 1]) / 2;
}
export async function bindAssets(rawSeal: unknown, rawAssets: unknown) {
  const seal = await validateSeal(rawSeal);
  const expected = await expectedAssets(seal);
  const assets = list(rawAssets, 48, 48).map((item) => {
    const a = object(item, [
      "asset_id",
      "sha256",
      "input_sha256",
      "config_sha256",
    ]);
    id(a.asset_id);
    digest(a.sha256);
    digest(a.input_sha256);
    digest(a.config_sha256);
    const target = expected.find((e) => e.asset_id === a.asset_id);
    check(
      target && target.input_sha256 === a.input_sha256 &&
        target.config_sha256 === a.config_sha256,
      "unknown asset or same-listing/config mismatch",
    );
    return a;
  });
  unique(assets.map((a) => a.asset_id));
  for (let i = 0; i < expected.length; i += 2) {
    check(
      assets.find((a) => a.asset_id === expected[i].asset_id)!.sha256 !==
        assets.find((a) => a.asset_id === expected[i + 1].asset_id)!.sha256,
      "identical output bytes: no treatment contrast",
    );
  }
  // Bind output declarations BEFORE issuing review packets. This is not a byte read.
  const asset_manifest_sha256 = await hash({
    commitment: seal.commitment,
    assets,
  });
  return frozen({ seal, assets, asset_manifest_sha256 });
}
export async function validateBound(raw: unknown) {
  const b = object(raw, ["seal", "assets", "asset_manifest_sha256"]);
  digest(b.asset_manifest_sha256);
  const expected = await bindAssets(b.seal, b.assets);
  check(
    expected.asset_manifest_sha256 === b.asset_manifest_sha256,
    "bound output manifest changed",
  );
  return expected;
}
export async function scoreExperiment(rawBound: unknown, rawScores: unknown) {
  const bound = await validateBound(rawBound);
  const seal = bound.seal;
  const input = object(rawScores, [
    "commitment",
    "asset_manifest_sha256",
    "assets",
    "scores",
  ]);
  check(
    input.commitment === seal.commitment,
    "scores belong to another registration",
  );
  check(
    input.asset_manifest_sha256 === bound.asset_manifest_sha256 &&
      canonical(input.assets) === canonical(bound.assets),
    "scores reference a different output manifest",
  );
  const expected = await expectedAssets(seal);
  const slots = await assignments(seal);
  const scores = list(input.scores, 72, 72).map((item) => {
    const s = object(item, ["pair_id", "rater_id", "A", "B", "preference"]);
    id(s.pair_id);
    id(s.rater_id);
    oneOf(s.preference, ["A", "B", "tie"]);
    check(
      slots.some((slot) =>
        slot.pair_id === s.pair_id && slot.rater_id === s.rater_id
      ),
      "unknown reviewer assignment",
    );
    return {
      pair_id: s.pair_id as string,
      rater_id: s.rater_id as string,
      A: rating(s.A),
      B: rating(s.B),
      preference: s.preference,
    };
  });
  const scoreKeys = scores.map((s) => `${s.pair_id}/${s.rater_id}`);
  unique(scoreKeys);
  let candidateMajorities = 0, newCriticalDefects = 0;
  const baselineFidelity: number[] = [], candidateFidelity: number[] = [];
  const meanDeltas: number[] = [];
  for (let i = 0; i < expected.length; i += 2) {
    const baselineId = expected[i].asset_id;
    let wins = 0;
    const baselinePair: number[] = [],
      candidatePair: number[] = [],
      pairDeltas: number[] = [];
    for (
      const slot of slots.filter((s) =>
        s.A === baselineId || s.B === baselineId
      )
    ) {
      const s = scores.find((s) =>
        s.pair_id === slot.pair_id && s.rater_id === slot.rater_id
      )!;
      const candidateSide = slot.A === baselineId ? "B" : "A";
      const baseline = candidateSide === "A" ? s.B : s.A,
        candidate = s[candidateSide];
      if (s.preference === candidateSide) wins++;
      baselinePair.push(baseline.metrics.property_fidelity);
      candidatePair.push(candidate.metrics.property_fidelity);
      pairDeltas.push(
        METRICS.reduce(
          (n, metric) =>
            n + candidate.metrics[metric] - baseline.metrics[metric],
          0,
        ) /
          METRICS.length,
      );
      newCriticalDefects += DEFECTS.filter((d) =>
        candidate.defects[d] && !baseline.defects[d]
      ).length;
    }
    if (wins >= 2) candidateMajorities++;
    baselineFidelity.push(median(baselinePair));
    candidateFidelity.push(median(candidatePair));
    meanDeltas.push(pairDeltas.reduce((a, b) => a + b, 0) / 3);
  }
  const threshold = candidateMajorities >= 18 && newCriticalDefects === 0 &&
    median(candidateFidelity) >= median(baselineFidelity);
  return frozen({
    commitment: seal.commitment,
    asset_manifest_sha256: bound.asset_manifest_sha256,
    evidence_kind: seal.registration.evidence_kind,
    pairs: 24,
    variants_declared: 48,
    judgments: 72,
    media_bytes_verified: false,
    candidate_majority_pairs: candidateMajorities,
    new_critical_defects: newCriticalDefects,
    baseline_fidelity_median: median(baselineFidelity),
    candidate_fidelity_median: median(candidateFidelity),
    paired_mean_score_deltas: meanDeltas,
    protocol_threshold_met: threshold,
    quality_win_claimed: false,
    publication_ready: false,
    interpretation: seal.registration.evidence_kind === "synthetic"
      ? "SYNTHETIC protocol exercise only; no evidence of perceptual quality or real independent raters."
      : "Exploratory declared local review only; rights, media bytes and rater independence need external verification. No population or publication claim.",
  });
}
