import { parseDraft, reviseDraft, validateDraft, type EditDraft, type SourceRef } from "./model";

export const HISTORY_LIMITS = { steps: 20, bytes: 64 * 1024 } as const;
type Snapshot = { label: string; json: string };
export type EditHistory = {
  present: EditDraft;
  past: readonly Snapshot[];
  future: readonly Snapshot[];
  group: string | null;
};
type EditPatch = Parameters<typeof reviseDraft>[1];
const encoder = new TextEncoder();

export function historyBytes(history: Pick<EditHistory, "past" | "future">): number {
  return [...history.past, ...history.future].reduce(
    (bytes, item) => bytes + encoder.encode(item.json).byteLength + encoder.encode(item.label).byteLength,
    0,
  );
}

function snapshot(draft: EditDraft, label: string): Snapshot {
  if (!label.trim() || label.length > 80) throw new Error("Invalid edit history label.");
  return { label, json: JSON.stringify(validateDraft(draft)) };
}

function bounded(present: EditDraft, past: readonly Snapshot[], future: readonly Snapshot[], group: string | null): EditHistory {
  const result = { present, past: [...past], future: [...future], group };
  // Drop the most distant steps first; never retain original files or blob URLs.
  while (result.past.length + result.future.length > HISTORY_LIMITS.steps || historyBytes(result) > HISTORY_LIMITS.bytes) {
    if (result.past.length >= result.future.length && result.past.length) result.past.shift();
    else result.future.shift();
  }
  return result;
}

export function createHistory(draft: EditDraft): EditHistory {
  return { present: validateDraft(draft), past: [], future: [], group: null };
}

export function closeHistoryGroup(history: EditHistory): EditHistory {
  return history.group === null ? history : { ...history, group: null };
}

export function editHistory(history: EditHistory, patch: EditPatch, label: string, group: string | null = null): EditHistory {
  if (group !== null && (!group || group.length > 128)) throw new Error("Invalid edit history group.");
  const next = reviseDraft(history.present, patch);
  // Re-entering the same value neither consumes history nor invalidates an export.
  if (JSON.stringify({ ...next, revision: 0 }) === JSON.stringify({ ...history.present, revision: 0 })) return history;
  const previous = snapshot(history.present, label);
  const merge = group !== null && group === history.group && history.future.length === 0 && history.past.length > 0;
  return bounded(next, merge ? history.past : [...history.past, previous], [], group);
}

function travel(history: EditHistory, direction: "undo" | "redo"): EditHistory {
  const entries = direction === "undo" ? history.past : history.future;
  const entry = entries.at(-1);
  if (!entry) return history;
  const target = parseDraft(entry.json);
  if (target.id !== history.present.id) throw new Error("Edit history belongs to another plan.");
  // Restoring old content is a new revision, never a return to an old export identity.
  const present = reviseDraft(history.present, {
    clips: target.clips, title: target.title, ratio: target.ratio, audio: target.audio,
  });
  const reverse = snapshot(history.present, entry.label);
  return direction === "undo"
    ? bounded(present, history.past.slice(0, -1), [...history.future, reverse], null)
    : bounded(present, [...history.past, reverse], history.future.slice(0, -1), null);
}

export const undoHistory = (history: EditHistory) => travel(history, "undo");
export const redoHistory = (history: EditHistory) => travel(history, "redo");

/** Only current exact source identities may retain live media, regardless of history. */
export function releasedMediaIds(next: EditDraft, sources: ReadonlyMap<string, SourceRef>): string[] {
  const expected = new Map(next.clips.map((clip) => [clip.id, clip.source]));
  return [...sources].filter(([id, source]) => {
    const wanted = expected.get(id);
    return !wanted || wanted.sha256 !== source.sha256 || wanted.size !== source.size ||
      wanted.kind !== source.kind || wanted.width !== source.width || wanted.height !== source.height ||
      Math.abs(wanted.duration - source.duration) > 0.05;
  }).map(([id]) => id);
}
