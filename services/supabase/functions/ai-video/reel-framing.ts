import type { RouteStep } from "../_shared/router.ts";
import { assert } from "../_shared/http.ts";
import { GUARDRAILS } from "../_shared/fairhousing.ts";
import type { REEL_PRESETS } from "./motion.ts";

/** The reel canvas is chosen by the app. It must not force a crop on the
 * supplier's photographic source. Absent preserves installed-client behavior. */
export function parseReelFraming(value: unknown): "preserve_photo" | undefined {
  if (value === undefined) return undefined;
  assert(value === "preserve_photo", 400, "Choose supported photo framing.", "validation");
  return "preserve_photo";
}

export function reelStepPreservesPhoto(step: RouteStep): boolean {
  const model = step.model.replace(/^fal-ai\//, "");
  return (step.provider === "fal" && model === "bytedance/seedance/v1/pro/fast/image-to-video") ||
    (step.provider === "kie" && model === "kling-3.0/video");
}

export function reelFramingSteps(steps: RouteStep[], framing?: "preserve_photo"): RouteStep[] {
  if (!framing) return steps;
  const eligible = steps.filter(reelStepPreservesPhoto);
  // Real owned KIE Seedance Fast returned landscape from portrait sources.
  // Its API exposes no aspect control; do not pretend it supports this contract.
  assert(eligible.length > 0, 503, "Photo-preserving motion is unavailable for this model. Please retry shortly.", "upstream");
  return eligible;
}

export function buildPhotoPreservingReelPrompt(sceneNoun: string, motion: typeof REEL_PRESETS[number]): string {
  const camera = {
    fly_through: "One stabilized, short forward-and-right diagonal camera track through the visible space, like a calm indoor drone glide. The camera body translates; foreground objects shift gently against the distant background. Keep the lens focal length and field of view fixed, horizon level, height and speed constant. Do not imitate travel with a digital zoom or a crop-in. Stop before entering unseen space or passing through any object.",
    push_in: "One very slow, shallow physical forward track with gentle depth parallax, fixed focal length and a level horizon. Keep the room readable; no digital zoom, sudden crop or jump.",
    side_glide: "One smooth, shallow lateral camera track to the right with gentle depth parallax, constant height, fixed focal length and a level horizon. Keep the room readable; no zoom or orbit revealing hidden sides.",
    pull_back: "One gentle backward camera feel inside the photographed scene, with a fixed focal length and a level horizon. Do not extend the photograph's borders, outpaint or invent unseen surfaces.",
  }[motion];
  return `Animate this exact photographed ${sceneNoun} in one continuous five-second shot. Begin with the entire supplied photograph at its original aspect ratio and composition. ${camera} ` +
    "Retain the wide scene, including the pictured ceiling, floor and side edges; do not force landscape or portrait framing. The delivery canvas will be added separately. " +
    "Preserve the architecture, layout, straight lines, proportions, doors, windows, fixed finishes and colors, fixtures, furniture and visible exterior exactly. Every object remains stationary. No added or removed objects, repainting, renovation, unseen rooms, warped geometry, flicker, cuts, text, people, logos or music. " + GUARDRAILS;
}
