import {
  EDIT_LIMITS, clipDuration, draftMedia, timelineDuration, validateDraft,
  type CaptionStyle, type EditClip, type EditDraft, type EditOverlay, type Ratio,
} from "./model";

export type RecipeId = "listing-highlight" | "agent-tour" | "market-update";
export const RECIPE_CATALOG = [
  { id: "listing-highlight", name: "Listing highlight", description: "A short property sequence in your selected order, with gentle photo motion.", needsRecording: false },
  { id: "agent-tour", name: "Agent tour", description: "Keep your presentation and speech together, with property photos over the recording.", needsRecording: true },
  { id: "market-update", name: "Market update", description: "Keep your commentary intact, with a few supporting photos or chart images.", needsRecording: true },
] as const;
export type RecipeOptions = {
  primaryClipId?: string;
  /** Source seconds, explicitly selected by the editor. Never inferred from words. */
  primaryRange?: { start: number; end: number };
  shotSeconds?: number;
  /** A highlight pacing hint; never trims a presentation to meet a target. */
  targetSeconds?: 30 | 45 | 60;
  captionStyle?: CaptionStyle;
  ratio?: Ratio;
};
export type RecipeResult = {
  recipe: RecipeId;
  draft: EditDraft;
  reviewNotes: string[];
  omittedSourceIds: string[];
};

/** A deterministic guided edit, not visual analysis, transcription or generation.
 * Source IDs survive moving photos between the sequence and cutaway track, so
 * the editor and its cloud wrapper can retain their exact media associations. */
export function buildRecipeDraft(input: EditDraft, recipe: RecipeId, options: RecipeOptions = {}): RecipeResult {
  const source = validateDraft(input);
  if (!RECIPE_CATALOG.some(item => item.id === recipe)) throw new Error("Choose a supported guided draft.");
  if (!source.clips.length) throw new Error("Add your property photos or a recording before choosing a guided draft.");
  if (options.targetSeconds !== undefined && ![30, 45, 60].includes(options.targetSeconds)) throw new Error("Choose a target of 30, 45 or 60 seconds.");
  const mediaCount = draftMedia(source).length;
  const shotSeconds = options.shotSeconds ?? (recipe === "listing-highlight" && options.targetSeconds ? Math.max(1, Math.min(8, options.targetSeconds / mediaCount)) : recipe === "market-update" ? 5 : 4);
  if (!Number.isFinite(shotSeconds) || shotSeconds < 1 || shotSeconds > 8) throw new Error("Choose a shot length between 1 and 8 seconds.");
  const captionStyle = options.captionStyle ?? "clean";
  const reviewNotes = ["Only your existing captions are used. Review every claim and the complete preview before sharing."];
  let clips: EditClip[], overlays: EditOverlay[] = [], narration = source.narration, audio = source.audio;
  if (recipe === "listing-highlight") {
    const sequence: EditClip[] = [...source.clips, ...(source.overlays ?? []).map(item => ({ ...item, start: 0, end: shotSeconds }))];
    if (sequence.length > EDIT_LIMITS.clips) throw new Error("Choose at most 12 sequence items before applying the listing highlight.");
    clips = sequence.map((clip, index) => ({
      ...clip,
      // Video highlights stay inside the chosen source span, including speed.
      end: clip.source.kind === "image" ? shotSeconds : clip.start + Math.min(clipDuration(clip), shotSeconds) * (clip.speed ?? 1),
      captionStyle,
      transition: index ? "dissolve" : "cut",
      motion: clip.source.kind === "image" ? "push_in" : clip.motion,
    }));
    reviewNotes.push("Selected order and source trim starts are retained. Video spans may be shortened; listen for incomplete speech.");
    if (source.overlays?.length) reviewNotes.push("Existing photo cutaways become sequence shots after the main clips.");
    if (narration) reviewNotes.push("Saved narration is retained. Check that the shorter picture sequence covers its complete message.");
  } else {
    const primary = source.clips.find(clip => clip.id === options.primaryClipId && clip.source.kind === "video");
    if (!primary) throw new Error("Choose the recording containing the agent’s presentation or market commentary.");
    const start = options.primaryRange?.start ?? primary.start, end = options.primaryRange?.end ?? primary.end;
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end > primary.source.duration || end - start < .5) throw new Error("Choose a valid source range within the selected recording.");
    if (end - start > EDIT_LIMITS.timelineSeconds) throw new Error("Trim the selected recording to 3 minutes or less before building this draft.");
    clips = [{ ...primary, start, end, speed: 1, transition: "cut", captionStyle }];
    audio = "original";
    narration = undefined;
    const photos = draftMedia(source).filter(item => item.source.kind === "image");
    const duration = end - start, maxCutaways = recipe === "agent-tour" ? 6 : 3;
    // Reserve an opening and closing view of the speaker. Fit only complete
    // cutaways with a one-second return to the speaker between them.
    const usable = Math.max(0, duration - 4);
    const count = Math.min(photos.length, maxCutaways, Math.max(0, Math.floor((usable - 1) / (shotSeconds + 1))));
    if (count) {
      const gap = (usable - count * shotSeconds) / (count + 1);
      overlays = photos.slice(0, count).map((photo, index) => {
        const at = 2 + gap + index * (shotSeconds + gap);
        return { id: photo.id, source: photo.source, start: at, end: at + shotSeconds, caption: photo.caption, focusX: photo.focusX, focusY: photo.focusY, motion: recipe === "agent-tour" ? "push_in" : "still" };
      });
    }
    reviewNotes.push("The selected recording plays at normal speed with its original audio. No words or silence are automatically removed.");
    reviewNotes.push("Cutaways use spacing only. Move them to the matching spoken feature or claim; no transcript matching is implied.");
    if (source.narration) reviewNotes.push("Saved narration is removed from this version so it does not speak over the presenter. Undo restores it.");
    if (recipe === "market-update") reviewNotes.push("Add and verify the market, reporting period, data source and figures yourself. No statistics or chart images are generated.");
    if (duration < 15) reviewNotes.push("This recording range is under 15 seconds. Expand its source range if you need the rest of the presentation.");
  }
  const draft = validateDraft({ ...source, clips, overlays, narration, audio, ratio: options.ratio ?? source.ratio });
  if (options.targetSeconds) {
    if (recipe === "listing-highlight") reviewNotes.push(`Target ${options.targetSeconds} seconds; this draft is ${Number(timelineDuration(clips).toFixed(1))} seconds using your selected footage. No source span is extended or repeated to fill time.`);
    else reviewNotes.push(`Target ${options.targetSeconds} seconds is a planning guide. The explicitly selected recording range is retained; adjust its source range yourself after reviewing the speech.`);
  }
  const retained = new Set(draftMedia(draft).map(item => item.id));
  const omittedSourceIds = draftMedia(source).filter(item => !retained.has(item.id)).map(item => item.id);
  if (omittedSourceIds.length) reviewNotes.push(`${omittedSourceIds.length} selected item${omittedSourceIds.length === 1 ? " is" : "s are"} not used in this version. Original files are not deleted; undo may require file reselection.`);
  if (timelineDuration(clips) < 20 && recipe === "listing-highlight") reviewNotes.push("This is a short sequence. Add more real footage if you need a longer property story.");
  return { recipe, draft, reviewNotes, omittedSourceIds };
}
