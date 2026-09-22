import { canonical, check, hash } from "./common.ts";
import {
  bindAssets,
  blindAssignments,
  preregister,
  scoreExperiment,
  validateSeal,
} from "./experiment.ts";
import {
  equal,
  experimentFixture,
  registrationFixture,
  rejects,
} from "./test_helpers.ts";

Deno.test("blind allocation is deterministic, complete and counterbalanced per rater", async () => {
  const { seal, bound, packet, privateAssets } = await experimentFixture();
  equal(packet, await blindAssignments(bound));
  equal(packet.assignments.length, 72);
  for (const rater of seal.registration.raters) {
    const slots = packet.assignments.filter((s) => s.rater_id === rater);
    equal(slots.length, 24);
    equal(
      slots.filter((s) =>
        privateAssets.find((a) => a.asset_id === s.A)!.variant === "candidate"
      ).length,
      12,
    );
    const firstHalfCandidateA = slots.slice(0, 12).filter((s) =>
      privateAssets.find((a) =>
        a.asset_id === s.A
      )!.variant === "candidate"
    ).length;
    check(
      firstHalfCandidateA > 0 && firstHalfCandidateA < 12,
      "display position reveals balanced candidate sides",
    );
  }
  check(
    !canonical(packet).includes("clear-tour") &&
      !canonical(packet).includes("baseline_config"),
    "blind packet leaks policy identity",
  );
});
Deno.test("synthetic perfect scores cannot claim a real quality win", async () => {
  const { bound, input } = await experimentFixture();
  const result = await scoreExperiment(bound, input);
  equal(result.candidate_majority_pairs, 24);
  equal(result.protocol_threshold_met, true);
  equal(result.quality_win_claimed, false);
  equal(result.publication_ready, false);
  equal(result.media_bytes_verified, false);
  check(
    result.interpretation.startsWith("SYNTHETIC"),
    "synthetic warning absent",
  );
});
Deno.test("ties never count as candidate wins", async () => {
  const { bound, input } = await experimentFixture();
  input.scores.forEach((s) => s.preference = "tie");
  const result = await scoreExperiment(bound, input);
  equal(result.candidate_majority_pairs, 0);
  equal(result.protocol_threshold_met, false);
});
Deno.test("new critical defect blocks advancement despite perfect preference", async () => {
  const { bound, input, privateAssets, packet } = await experimentFixture();
  const side =
    privateAssets.find((a) => a.asset_id === packet.assignments[0].A)!
        .variant === "candidate"
      ? "A"
      : "B";
  input.scores[0][side].defects.geometry = true;
  const result = await scoreExperiment(bound, input);
  equal(result.new_critical_defects, 1);
  equal(result.protocol_threshold_met, false);
});
Deno.test("locked rubric cannot be changed even with a recomputed seal", async () => {
  const { seal } = await experimentFixture();
  const changed = JSON.parse(canonical(seal));
  changed.protocol.candidate_majority_threshold = 1;
  changed.commitment = await hash({
    registration: changed.registration,
    protocol: changed.protocol,
  });
  await rejects(() => validateSeal(changed));
});
Deno.test("registration edits invalidate the original commitment", async () => {
  const { seal } = await experimentFixture();
  const changed = JSON.parse(canonical(seal));
  changed.registration.seed = "9".repeat(64);
  await rejects(() => validateSeal(changed));
});
Deno.test("lower property fidelity blocks candidate even with unanimous preference", async () => {
  const { bound, input, privateAssets, packet } = await experimentFixture();
  for (let i = 0; i < input.scores.length; i++) {
    const candidateSide = privateAssets.find((a) =>
        a.asset_id === packet.assignments[i].A
      )!.variant === "candidate"
      ? "A"
      : "B";
    input.scores[i][candidateSide].metrics.property_fidelity = 1;
  }
  const result = await scoreExperiment(bound, input);
  equal(result.candidate_majority_pairs, 24);
  equal(result.protocol_threshold_met, false);
});
for (
  const name of [
    "missing-fixture",
    "duplicate-fixture",
    "duplicate-input",
    "strata",
    "missing-rater",
    "duplicate-rater",
    "same-config",
    "seed",
    "unknown-field",
  ] as const
) {
  Deno.test(`registration rejects ${name}`, async () => {
    const r = await registrationFixture();
    if (name === "missing-fixture") r.fixtures.pop();
    if (name === "duplicate-fixture") r.fixtures[1] = r.fixtures[0];
    if (name === "duplicate-input") {
      r.fixtures[1].input_sha256 = r.fixtures[0].input_sha256;
    }
    if (name === "strata") r.fixtures[0].stratum = "mixed";
    if (name === "missing-rater") r.raters.pop();
    if (name === "duplicate-rater") r.raters[1] = r.raters[0];
    if (name === "same-config") {
      r.candidate_config_sha256 = r.baseline_config_sha256;
    }
    if (name === "seed") r.seed = "guess";
    if (name === "unknown-field") Object.assign(r, { paid_generation: true });
    await rejects(() => preregister(r));
  });
}
for (
  const name of [
    "missing-score",
    "duplicate-score",
    "unknown-rater",
    "unknown-pair",
    "missing-metric",
    "extra-metric",
    "fractional",
    "zero",
    "nonfinite",
    "boolean-metric",
    "nonboolean-defect",
    "invalid-preference",
    "missing-asset",
    "duplicate-asset",
    "wrong-input",
    "wrong-config",
    "same-bytes",
    "wrong-commitment",
  ] as const
) {
  Deno.test(`scoring rejects ${name}`, async () => {
    const { bound, input } = await experimentFixture();
    if (name === "missing-score") input.scores.pop();
    if (name === "duplicate-score") {
      input.scores[1] = structuredClone(input.scores[0]);
    }
    if (name === "unknown-rater") input.scores[0].rater_id = "outsider";
    if (name === "unknown-pair") input.scores[0].pair_id = "missing";
    if (name === "missing-metric") delete input.scores[0].A.metrics.pacing;
    if (name === "extra-metric") input.scores[0].A.metrics.extra = 5;
    if (name === "fractional") input.scores[0].A.metrics.pacing = 4.5;
    if (name === "zero") input.scores[0].A.metrics.pacing = 0;
    if (name === "nonfinite") input.scores[0].A.metrics.pacing = NaN;
    if (name === "boolean-metric") {
      Object.assign(input.scores[0].A.metrics, { pacing: true });
    }
    if (name === "nonboolean-defect") {
      Object.assign(input.scores[0].A.defects, { geometry: 0 });
    }
    if (name === "invalid-preference") {
      input.scores[0].preference = "candidate";
    }
    if (name === "missing-asset") input.assets.pop();
    if (name === "duplicate-asset") {
      input.assets[1] = structuredClone(input.assets[0]);
    }
    if (name === "wrong-input") input.assets[0].input_sha256 = "f".repeat(64);
    if (name === "wrong-config") input.assets[0].config_sha256 = "f".repeat(64);
    if (name === "same-bytes") input.assets[1].sha256 = input.assets[0].sha256;
    if (name === "wrong-commitment") input.commitment = "f".repeat(64);
    await rejects(() => scoreExperiment(bound, input));
  });
}
Deno.test("changed output declarations cannot reuse old blind score packet", async () => {
  const { seal, bound, input } = await experimentFixture();
  input.assets[0].sha256 = "f".repeat(64);
  await rejects(() => scoreExperiment(bound, input));
  const rebound = await bindAssets(seal, input.assets);
  check(
    rebound.asset_manifest_sha256 !== bound.asset_manifest_sha256,
    "changed output not committed",
  );
  await rejects(() => scoreExperiment(rebound, input));
});
Deno.test("bound output hash tampering fails before assignment", async () => {
  const { bound } = await experimentFixture();
  const changed = JSON.parse(canonical(bound));
  changed.assets[0].sha256 = "f".repeat(64);
  await rejects(() => blindAssignments(changed));
});
for (
  const kind of [
    "missing",
    "duplicate",
    "wrong-input",
    "wrong-config",
    "same-bytes",
  ] as const
) {
  Deno.test(`binding rejects ${kind}`, async () => {
    const { seal, input } = await experimentFixture();
    if (kind === "missing") input.assets.pop();
    if (kind === "duplicate") input.assets[1] = input.assets[0];
    if (kind === "wrong-input") input.assets[0].input_sha256 = "f".repeat(64);
    if (kind === "wrong-config") input.assets[0].config_sha256 = "f".repeat(64);
    if (kind === "same-bytes") input.assets[1].sha256 = input.assets[0].sha256;
    await rejects(() => bindAssets(seal, input.assets));
  });
}
