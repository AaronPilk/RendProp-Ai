import { canonical, check, hash } from "./common.ts";
import {
  parseAgentReel,
  planWindows,
} from "../../services/supabase/functions/ai-copy/agentreel.ts";
import {
  bindAssets,
  blindAssignments,
  DEFECTS,
  expectedAssets,
  METRICS,
  preregister,
  STRATA,
} from "./experiment.ts";
import { catalogRefs } from "./policy.ts";
export function equal(actual: unknown, expected: unknown): void {
  check(canonical(actual) === canonical(expected), "values differ");
}
export function throws(fn: () => unknown): void {
  let failed = false;
  try {
    fn();
  } catch {
    failed = true;
  }
  check(failed, "defective input unexpectedly accepted");
}
export async function rejects(fn: () => Promise<unknown>): Promise<void> {
  let failed = false;
  try {
    await fn();
  } catch {
    failed = true;
  }
  check(failed, "defective input unexpectedly accepted");
}
export function agentFixture() {
  const phrases = [
    0,
    3.2,
    6.4,
    10.1,
    13.3,
    17,
    20.2,
    24,
    27.2,
    31,
    34.2,
    38,
    41.2,
    45,
    48.2,
    52,
    55.2,
  ].map((t) => ({ t, text: "A synthetic room detail." }));
  const photos = ["kitchen", "living", "bathroom", "bedroom", "exterior"].map((
    room,
    i,
  ) => ({ id: `photo-${i}`, room, caption_hint: "Visible detail" }));
  const windows = planWindows(phrases, 60, photos.length);
  const answer = parseAgentReel(
    JSON.stringify({
      windows: windows.map((w, i) => ({
        window_id: w.window_id,
        photo_id: photos[i].id,
        on_screen_text: "Visible detail",
      })),
    }),
    windows,
    photos,
  );
  check(answer, "actual planner must produce fixture");
  return {
    schema_version: 1,
    mode: "recorded_agent",
    clip_seconds: 60,
    original_audio_sha256: "a".repeat(64),
    phrase_boundaries: phrases.map((p) => p.t),
    photos: photos.map(({ id, room }) => ({ id, room })),
    cutaways: answer.cutaways,
  };
}
export function photoFixture() {
  return {
    schema_version: 1,
    mode: "photo_sequence",
    shots: [{
      photo_id: "photo-1",
      room: "bathroom",
      motion: "orbit_left",
      seconds: 5,
      on_screen_text: "Visible detail",
    }],
  };
}
export async function registrationFixture() {
  return {
    schema_version: 1,
    experiment_id: "synthetic-pilot",
    seed: "0".repeat(64),
    evidence_kind: "synthetic",
    baseline_config_sha256: "1".repeat(64),
    candidate_config_sha256: "2".repeat(64),
    candidate_style: (await catalogRefs())[0],
    raters: ["rater-a", "rater-b", "rater-c"],
    fixtures: await Promise.all(
      Array.from(
        { length: 24 },
        async (_, i) => ({
          listing_id: `listing-${i}`,
          input_sha256: await hash(["synthetic-input", i]),
          stratum: STRATA[Math.floor(i / 4)],
          rights_reference: "synthetic-generated-locally",
        }),
      ),
    ),
  };
}
export async function experimentFixture() {
  const seal = await preregister(await registrationFixture());
  const privateAssets = await expectedAssets(seal);
  const assets = await Promise.all(
    privateAssets.map(async (a) => ({
      asset_id: a.asset_id,
      input_sha256: a.input_sha256,
      config_sha256: a.config_sha256,
      sha256: await hash(["synthetic-output", a.asset_id]),
    })),
  );
  const bound = await bindAssets(seal, assets);
  const packet = await blindAssignments(bound);
  const rating = (value: number) => ({
    metrics: Object.fromEntries(METRICS.map((m) => [m, value])),
    defects: Object.fromEntries(DEFECTS.map((d) => [d, false])),
  });
  const scores = packet.assignments.map((slot) => {
    const candidateA = privateAssets.find((a) =>
      a.asset_id === slot.A
    )!.variant === "candidate";
    return {
      pair_id: slot.pair_id,
      rater_id: slot.rater_id,
      A: rating(candidateA ? 5 : 3),
      B: rating(candidateA ? 3 : 5),
      preference: candidateA ? "A" : "B",
    };
  });
  return {
    seal,
    bound,
    packet,
    privateAssets,
    input: {
      commitment: seal.commitment,
      asset_manifest_sha256: bound.asset_manifest_sha256,
      assets,
      scores,
    },
  };
}
