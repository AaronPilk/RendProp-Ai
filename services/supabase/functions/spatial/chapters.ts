import type { Row } from "./contract.ts";
export interface SpatialChapter {
  label: string;
  t_ms: number;
  sort: number;
  spatial_anchor?: { scene_id: string; room_id: string };
}
const labelKey = (label: string) =>
  label.trim().replace(/\s+/g, " ").toLocaleLowerCase("en-US");
/** Late binding leaves an existing video untouched. Duplicate labels on either
 * side stay inert: entering the wrong real room is worse than no 3D shortcut. */
export function bindSpatialChapters(
  chapters: SpatialChapter[],
  jobs: Row[],
): SpatialChapter[] {
  const anchors = new Map<
      string,
      Array<{ scene_id: string; room_id: string }>
    >(),
    counts = new Map<string, number>();
  for (const c of chapters) {
    const key = labelKey(c.label);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  for (const job of jobs) {
    if (
      job.status !== "ready" || job.approved !== true ||
      job.excluded !== false || !job.published_at || !job.artifact_revision ||
      job.review_revision !== job.artifact_revision ||
      job.output_state !== "stored" || !Array.isArray(job.redactions) ||
      job.redactions.length
    ) continue;
    const rooms = (job.scene_manifest as Row | undefined)?.rooms;
    if (!Array.isArray(rooms)) continue;
    for (const raw of rooms) {
      if (!raw || typeof raw !== "object") continue;
      const room = raw as Row;
      if (typeof room.label !== "string" || typeof room.id !== "string") {
        continue;
      }
      const key = labelKey(room.label), values = anchors.get(key) ?? [];
      values.push({ scene_id: String(job.id), room_id: room.id });
      anchors.set(key, values);
    }
  }
  return chapters.map((c) => {
    const candidates = anchors.get(labelKey(c.label));
    return counts.get(labelKey(c.label)) === 1 && candidates?.length === 1
      ? { ...c, spatial_anchor: candidates[0] }
      : { label: c.label, t_ms: c.t_ms, sort: c.sort };
  });
}
