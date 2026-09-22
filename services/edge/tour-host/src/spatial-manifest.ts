/** Wire-only scene metadata. No storage keys, URLs, credentials or camera sidecars. */
export interface SpatialManifest {
  schema_version: 1;
  scene_id: string;
  artifact_revision: string;
  format: "sog";
  bytes: number;
  sha256: string;
  gaussian_count: number;
  bounds: { min: number[]; max: number[] };
  floor_y: number;
  floor_source: "capture_estimate" | "roomplan";
  navigation_bounds_source: "capture_estimate";
  eye_height: number;
  initial_camera: { position: number[]; target: number[] };
  rooms: { id: string; label: string; position: number[]; target: number[] }[];
  provenance: "captured" | "synthetic";
  privacy_reviewed: boolean;
}

/** Self-contained so the SAME decoder can be emitted into the browser module. */
export function decodeSpatialManifest(raw: unknown): SpatialManifest {
  const fail = (): never => { throw new Error("Invalid spatial scene manifest"); };
  const record = (v: unknown): Record<string, unknown> => {
    if (!v || typeof v !== "object" || Array.isArray(v)) return fail();
    return v as Record<string, unknown>;
  };
  const uuid = (v: unknown): string => {
    if (typeof v !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)) return fail();
    return v;
  };
  const number = (v: unknown, low: number, high: number): number => {
    if (typeof v !== "number" || !Number.isFinite(v) || v < low || v > high) return fail();
    return v;
  };
  const vector = (v: unknown): number[] => {
    if (!Array.isArray(v) || v.length !== 3) return fail();
    return v.map((x) => number(x, -10000, 10000));
  };
  const m = record(raw), bounds = record(m.bounds);
  const min = vector(bounds.min), max = vector(bounds.max);
  if (max.some((x, i) => x <= min[i] || x - min[i] > 200)) return fail();
  const pose = (v: unknown): { position: number[]; target: number[] } => {
    const p = record(v), position = vector(p.position), target = vector(p.target);
    if (position.some((x, i) => x < min[i] || x > max[i]) ||
        Math.hypot(...position.map((x, i) => x - target[i])) < .01) return fail();
    return { position, target };
  };
  const floor = number(m.floor_y, min[1], max[1]), eye = number(m.eye_height, .5, 2.5);
  if (floor + eye > max[1]) return fail();
  const bytes = number(m.bytes, 1, 32 * 1024 * 1024);
  const count = number(m.gaussian_count, 1, 500000);
  if (!Number.isSafeInteger(bytes) || !Number.isSafeInteger(count) || m.schema_version !== 1 || m.format !== "sog" ||
      typeof m.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(m.sha256) ||
      !["captured", "synthetic"].includes(String(m.provenance)) || typeof m.privacy_reviewed !== "boolean" ||
      !["capture_estimate", "roomplan"].includes(String(m.floor_source)) || m.navigation_bounds_source !== "capture_estimate" ||
      !Array.isArray(m.rooms) || m.rooms.length > 32) return fail();
  const ids = new Set<string>();
  const rooms = m.rooms.map((v) => {
    const r = record(v);
    if (typeof r.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(r.id) || ids.has(r.id) ||
        typeof r.label !== "string" || !r.label.trim() || r.label.length > 80 || /[\u0000-\u001f]/.test(r.label)) return fail();
    ids.add(r.id);
    return { id: r.id, label: r.label, ...pose(r) };
  });
  return { schema_version: 1, scene_id: uuid(m.scene_id), artifact_revision: uuid(m.artifact_revision), format: "sog",
    bytes, sha256: m.sha256, gaussian_count: count, bounds: { min, max }, floor_y: floor, eye_height: eye,
    floor_source: m.floor_source as "capture_estimate" | "roomplan", navigation_bounds_source: "capture_estimate",
    initial_camera: pose(m.initial_camera), rooms, provenance: m.provenance as "captured" | "synthetic",
    privacy_reviewed: m.privacy_reviewed };
}

export function spatialAnchor(value: unknown): { scene_id: string; room_id: string } | null {
  if (!value || typeof value !== "object") return null;
  const a = value as Record<string, unknown>;
  return typeof a.scene_id === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(a.scene_id) &&
    typeof a.room_id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(a.room_id)
    ? { scene_id: a.scene_id, room_id: a.room_id } : null;
}
