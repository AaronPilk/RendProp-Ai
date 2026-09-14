import {EDIT_LIMITS, type EditClip} from "../../editor/model";
import type {Shot, ShotPlanHandoff} from "../creative/model";
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function reviewShotPlan(plan: ShotPlanHandoff, allowRepeatedPhotos = false): Shot[] {
  if (!UUID.test(plan.listingId) || !Array.isArray(plan.shots) || !plan.shots.length || plan.shots.length > EDIT_LIMITS.clips) throw new Error("Choose a saved plan with 1–12 property photos.");
  const seen = new Set<string>();
  const shots = plan.shots.map(shot => {
    if (!UUID.test(shot.photoId) || (!allowRepeatedPhotos && seen.has(shot.photoId))) throw new Error("The shot plan repeats a photo or has an invalid source. Review it in AI tools.");
    seen.add(shot.photoId);
    if (!Number.isFinite(shot.order) || !Number.isFinite(shot.seconds) || shot.seconds < 0.5 || shot.seconds > 30 || typeof shot.caption !== "string" || shot.caption.length > EDIT_LIMITS.captionCharacters || typeof shot.motion !== "string" || shot.motion.length > 200) throw new Error("A shot’s timing or caption is invalid. Review the saved plan before applying it.");
    return {...shot};
  }).sort((a, b) => a.order - b.order);
  if (shots.reduce((total, shot) => total + shot.seconds, 0) > EDIT_LIMITS.timelineSeconds) throw new Error("The shot plan exceeds the 3-minute edit limit.");
  if (plan.narrationResultId !== null && !UUID.test(plan.narrationResultId)) throw new Error("Choose a saved narration result.");
  return shots;
}
export function mapShotMotion(value: string): EditClip["motion"] {
  const motion = value.toLowerCase().replaceAll("_", " ");
  if (/push|zoom in|dolly in/.test(motion)) return "push_in";
  if (/pull|zoom out|dolly out/.test(motion)) return "pull_out";
  if (/left/.test(motion)) return "pan_left";
  if (/right/.test(motion)) return "pan_right";
  return "still";
}
