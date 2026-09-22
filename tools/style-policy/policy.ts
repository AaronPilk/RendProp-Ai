import {
  REEL_MOTIONS,
  type ReelMotion,
} from "../../services/supabase/functions/ai-video/motion.ts";
import {
  check,
  digest,
  frozen,
  hash,
  id,
  list,
  number,
  object,
  oneOf,
  text,
  unique,
} from "./common.ts";

export interface StylePolicy {
  schema_version: 1;
  id: string;
  version: number;
  status: "draft";
  grammar_version: "reel-motion-v1";
  timing: "preserve-planner";
  recorded_edl: "preserve-exact";
  photo_motion_rank: readonly ReelMotion[];
  presentation: {
    transition: "cut" | "dissolve";
    caption: "lowerThird" | "highlightBox";
    music: "none";
    grade: "identity";
  };
  intent: { opening_three_seconds: string; pacing: string };
  provenance: {
    basis: "generic-editorial-conventions";
    copied_assets: false;
    review_status: "pending";
  };
}
export interface StyleRef {
  id: string;
  version: number;
  sha256: string;
}

export function validateCatalog(
  raw: unknown,
): readonly Readonly<StylePolicy>[] {
  const policies = list(raw, 1, 64).map((item) => {
    const p = object(item, [
      "schema_version",
      "id",
      "version",
      "status",
      "grammar_version",
      "timing",
      "recorded_edl",
      "photo_motion_rank",
      "presentation",
      "intent",
      "provenance",
    ]);
    check(p.schema_version === 1, "unknown schema version");
    id(p.id);
    number(p.version, 1, 1_000_000, true);
    check(p.status === "draft", "offline catalog cannot approve styles");
    check(
      p.grammar_version === "reel-motion-v1" &&
        p.timing === "preserve-planner" && p.recorded_edl === "preserve-exact",
      "unsupported policy contract",
    );
    const rank = list(p.photo_motion_rank, 1, REEL_MOTIONS.length);
    rank.forEach((m) => oneOf(m, REEL_MOTIONS));
    unique(rank);
    const presentation = object(p.presentation, [
      "transition",
      "caption",
      "music",
      "grade",
    ]);
    oneOf(presentation.transition, ["cut", "dissolve"]);
    oneOf(presentation.caption, ["lowerThird", "highlightBox"]);
    check(
      presentation.music === "none" && presentation.grade === "identity",
      "unsupported music or grading",
    );
    const intent = object(p.intent, ["opening_three_seconds", "pacing"]);
    text(intent.opening_three_seconds, 1, 500);
    text(intent.pacing, 1, 500);
    const provenance = object(p.provenance, [
      "basis",
      "copied_assets",
      "review_status",
    ]);
    check(
      provenance.basis === "generic-editorial-conventions" &&
        provenance.copied_assets === false &&
        provenance.review_status === "pending",
      "unsupported provenance claim",
    );
    return frozen(p) as unknown as Readonly<StylePolicy>;
  });
  unique(policies.map((p) => `${p.id}@${p.version}`));
  return Object.freeze(policies);
}

function seed(
  styleId: string,
  transition: "cut" | "dissolve",
  caption: "lowerThird" | "highlightBox",
  rank: ReelMotion[],
  opening: string,
  pacing: string,
): StylePolicy {
  return {
    schema_version: 1,
    id: styleId,
    version: 1,
    status: "draft",
    grammar_version: "reel-motion-v1",
    timing: "preserve-planner",
    recorded_edl: "preserve-exact",
    photo_motion_rank: rank,
    presentation: { transition, caption, music: "none", grade: "identity" },
    intent: { opening_three_seconds: opening, pacing },
    provenance: {
      basis: "generic-editorial-conventions",
      copied_assets: false,
      review_status: "pending",
    },
  };
}

// Original generic editorial descriptions, not copied creator templates or assets.
export const CATALOG = validateCatalog([
  seed(
    "clear-tour",
    "cut",
    "lowerThird",
    [
      "push_in",
      "static_parallax",
      "tilt_down",
      "tilt_up",
      "rack_focus",
      "pull_back",
    ],
    "Identify the property context plainly.",
    "Clear hierarchy; existing planner timing stays unchanged.",
  ),
  seed(
    "editorial-calm",
    "dissolve",
    "lowerThird",
    [
      "static_parallax",
      "push_in",
      "rack_focus",
      "tilt_down",
      "tilt_up",
      "pull_back",
    ],
    "Keep information legible without altering the face lead.",
    "Calm transition intent, not slower speech or longer holds.",
  ),
  seed(
    "concise-highlights",
    "cut",
    "highlightBox",
    [
      "tilt_down",
      "push_in",
      "static_parallax",
      "rack_focus",
      "tilt_up",
      "pull_back",
    ],
    "Emphasize a visible feature, not a new property claim.",
    "Concise visual hierarchy, not faster clips.",
  ),
]);

export function catalogRefs(): Promise<readonly StyleRef[]> {
  return Promise.all(
    CATALOG.map(async (p) => ({
      id: p.id,
      version: p.version,
      sha256: await hash(p),
    })),
  );
}
export async function resolveStyle(raw: unknown) {
  if (raw === null) {
    return frozen({ kind: "legacy" as const, offline_only: true as const });
  }
  const ref = object(raw, ["id", "version", "sha256"]);
  id(ref.id);
  number(ref.version, 1, 1_000_000, true);
  digest(ref.sha256);
  const policy = CATALOG.find((p) =>
    p.id === ref.id && p.version === ref.version
  );
  check(policy, "unknown style version");
  check(await hash(policy) === ref.sha256, "style digest mismatch");
  return frozen({
    kind: "selected" as const,
    offline_only: true as const,
    ref,
    policy,
  });
}
