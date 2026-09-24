import { EDIT_LIMITS, locateTime, validateDraft, type EditDraft } from "./model";

/** Split in timeline seconds, preserving exact source continuity and audio speed. */
export function splitVideoAtTime(input: EditDraft, time: number, newClipId: string): EditDraft {
  const draft = validateDraft(input);
  if (!Number.isFinite(time) || time < 0) throw new Error("Move the playhead inside a video clip.");
  const position = locateTime(draft.clips, time);
  if (!position || position.clip.source.kind !== "video") throw new Error("Move the playhead inside a video clip. Photos use the duration control.");
  const { clip, index, sourceTime } = position;
  if (sourceTime - clip.start < EDIT_LIMITS.minClipSeconds - 1e-8 || clip.end - sourceTime < EDIT_LIMITS.minClipSeconds - 1e-8) throw new Error("Leave at least half a second of source footage on each side of the split.");
  if (draft.clips.length >= EDIT_LIMITS.clips) throw new Error("Remove a clip before splitting; this editor supports 12 clips.");
  return validateDraft({ ...draft, clips: [
    ...draft.clips.slice(0, index),
    { ...clip, end: sourceTime },
    { ...clip, id: newClipId, start: sourceTime, transition: "cut" },
    ...draft.clips.slice(index + 1),
  ] });
}
