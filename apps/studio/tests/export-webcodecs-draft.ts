import {newDraft, validateDraft, type EditDraft, type SourceRef} from "../src/editor/model";
import type {AudioSourceRef} from "../src/editor/finishing";

export type ExportFixtureScenario = "combined" | "fractional" | "muted-music" | "silent" | "long" | "seek" | "hybrid-reuse";
export type ExportFixtureSources = Partial<Record<"opening" | "sourceOne" | "middle" | "sourceTwo" | "closing" | "cutaway" | "motion" | "sourceSeek", SourceRef>>;
export const NARRATION_ID = "00000000-0000-4000-8000-000000000660";

// The browser and pure pre-browser metadata gate call the same actual builder.
export function makeExportFixtureDraft(sources: ExportFixtureSources,
  musicSource: AudioSourceRef | undefined, scenario: ExportFixtureScenario): EditDraft {
  const base = newDraft();
  const clip = (id: string, source: SourceRef, start: number, end: number) =>
    ({id, source, start, end, caption: "", focusX: .5, focusY: .5,
      transition: "cut" as const});
  const source = (id: keyof ExportFixtureSources) => {
    const value = sources[id];
    if (!value) throw new Error("Missing synthetic fixture source " + id);
    return value;
  };
  if (scenario === "seek") return validateDraft({...base, ratio: "16:9", audio: "muted",
    clips: [{...clip("sourceSeek", source("sourceSeek"), .2521, .7521), speed: .25}]});
  if (scenario === "hybrid-reuse") return validateDraft({...base, ratio: "16:9", audio: "original",
    clips: [{...clip("reuse-first", source("sourceOne"), 0, 1), speed: 2},
      clip("reuse-photo", source("middle"), 0, .5),
      {...clip("reuse-second", source("sourceOne"), 0, 1), speed: 2}],
    narration: {resultId: NARRATION_ID, label: "Synthetic short narration", offset: .15,
      volume: 1, wordCaptions: false, words: []}});
  if (!musicSource) throw new Error("Missing synthetic fixture music metadata");
  const music = {source: musicSource, start: 0, end: 5.4, offset: .1,
    volume: .5, fadeIn: .3, fadeOut: .3,
    ducking: "original" as const, licensed: true as const};
  if (scenario === "combined") return validateDraft({...base, ratio: "16:9", audio: "original",
    clips: [clip("opening", source("opening"), 0, .5),
      {...clip("sourceOne", source("sourceOne"), 0, 4), speed: 2, transition: "dissolve"},
      {...clip("middle", source("middle"), 0, .5), transition: "whip"},
      clip("sourceTwo", source("sourceTwo"), .5, 2.5),
      clip("closing", source("closing"), 0, .5)],
    narration: {resultId: NARRATION_ID, label: "Synthetic narration", offset: .15,
      volume: 1, wordCaptions: false, words: []}, music,
    overlays: [{id: "cutaway", source: source("cutaway"), start: 3.5, end: 4,
      caption: "", focusX: .5, focusY: .5}]});
  if (scenario === "fractional") return validateDraft({...base, ratio: "9:16", audio: "original",
    title: "Fractional timeline", clips: [
      {...clip("motion", source("motion"), 0, .517), motion: "pan_left", caption: "Moving photo", captionStyle: "highlight"},
      {...clip("sourceTwo", source("sourceTwo"), .431, 1.789), speed: 1.3,
        caption: "Fractional caption", captionStyle: "highlight"},
      {...clip("closing", source("closing"), 0, .683), caption: "Closing caption", captionStyle: "center"}],
    speech: [{sourceSha256: source("sourceTwo").sha256, sourceDuration: source("sourceTwo").duration,
      reviewed: true, words: [{text: "Verified source words", start: .7, end: .9}]}],
    overlays: [{id: "cutaway", source: source("cutaway"), start: .82, end: 1.32,
      caption: "", focusX: .5, focusY: .5}]});
  if (scenario === "muted-music") return validateDraft({...base, ratio: "1:1", audio: "muted",
    clips: [clip("sourceOne", source("sourceOne"), .42, 1.437)],
    music: {...music, ducking: "none"}});
  if (scenario === "silent") return validateDraft({...base, ratio: "1:1", audio: "muted",
    clips: [clip("opening", source("opening"), 0, .517), clip("closing", source("closing"), 0, .683)]});
  return validateDraft({...base, ratio: "16:9", audio: "muted",
    clips: Array.from({length: 12}, (_, index) => ({
      ...clip(`long-${index}`, source(index % 2 ? "middle" : "opening"), 0, 15),
      caption: `Clip ${index + 1}`}))});
}
