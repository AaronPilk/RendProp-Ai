import { assert, HttpError } from "../_shared/http.ts";
export type Row = Record<string, unknown>;
export const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
export const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function roomLabel(value: unknown): string {
  assert(
    typeof value === "string" && value.trim().length >= 1 &&
      value.length <= 80 && !/[\u0000-\u001f\u007f]/.test(value),
    400,
    "Name this room without control characters",
  );
  return value.trim();
}
export function object(v: unknown): Row {
  assert(
    v != null && typeof v === "object" && !Array.isArray(v),
    400,
    "Expected a JSON object",
  );
  return v as Row;
}
export function uuid(v: unknown): string {
  assert(typeof v === "string" && UUID.test(v), 400, "Expected a UUID");
  return v.toLowerCase();
}
export function integer(v: unknown, min: number, max: number): number {
  assert(
    typeof v === "number" && Number.isSafeInteger(v) && v >= min && v <= max,
    400,
    `Expected an integer between ${min} and ${max}`,
  );
  return v;
}
function finite(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}
function vector(v: unknown, n = 3): number[] {
  assert(
    Array.isArray(v) && v.length === n && v.every(finite),
    400,
    "Invalid measured vector",
  );
  return v;
}
function matrix(v: unknown, n: number): number[][] {
  assert(Array.isArray(v) && v.length === n, 400, "Invalid measured matrix");
  return v.map((r) => vector(r, n));
}
export function captureManifest(value: unknown, capture: string): Row {
  const v = object(value);
  assert(
    JSON.stringify(v).length <= 65536,
    413,
    "Capture manifest is too large",
  );
  assert(
    v.schema_version === 1 && v.format === "rendprop-arkit-capture" &&
      uuid(v.session_id) === capture && v.status === "complete",
    400,
    "Capture must be complete",
  );
  assert(
    v.coordinate_system === "arkit-right-handed-y-up-camera-minus-z-forward" &&
      v.matrix_layout === "row-major" && v.pose_type === "camera-to-world" &&
      v.units === "metres" && v.image_orientation === "sensor-native-exif-1",
    400,
    "Unsupported capture geometry",
  );
  assert(
    Array.isArray(v.frames) && v.frames.length >= 20 && v.frames.length <= 400,
    400,
    "Capture requires 20..400 frames",
  );
  integer(v.image_bytes, 1, 2147483648);
  integer(v.feature_point_observations, 1, 20000000);
  assert(
    v.frames.every((f, i) =>
      f === `frames/${String(i + 1).padStart(6, "0")}.json`
    ),
    400,
    "Capture frame coverage must be exact and ordered",
  );
  return { ...v, session_id: capture };
}
export function inputFiles(value: unknown): Row[] {
  assert(
    Array.isArray(value) && value.length >= 1 && value.length <= 16,
    400,
    "Expected 1..16 input frames",
  );
  const result = value.map((raw) => {
    const v = object(raw), frame = object(v.frame), path = v.relative_path;
    assert(
      new TextEncoder().encode(JSON.stringify(frame)).byteLength <= 1048576,
      413,
      "One frame's metadata exceeds 1 MiB",
    );
    assert(
      typeof path === "string" && /^images\/[0-9]{6}\.jpg$/.test(path) &&
        frame.image === path,
      400,
      "Frame path does not match image",
    );
    assert(
      frame.schema_version === 1 &&
        object(frame.tracking_state).state === "normal" &&
        finite(frame.timestamp) && frame.timestamp >= 0,
      400,
      "Invalid capture frame",
    );
    const pose = matrix(frame.camera_to_world, 4),
      K = matrix(frame.intrinsics, 3),
      resolution = object(frame.image_resolution);
    assert(
      pose[3].every((x, i) => Math.abs(x - (i === 3 ? 1 : 0)) < 0.0001),
      400,
      "Invalid camera homogeneous row",
    );
    for (let a = 0; a < 3; a++) {
      for (let b = 0; b < 3; b++) {
        assert(
          Math.abs(
            pose.reduce((s, r, i) => i < 3 ? s + r[a] * r[b] : s, 0) -
              (a === b ? 1 : 0),
          ) < 0.01,
          400,
          "Camera rotation is not rigid",
        );
      }
    }
    const det =
      pose[0][0] * (pose[1][1] * pose[2][2] - pose[1][2] * pose[2][1]) -
      pose[0][1] * (pose[1][0] * pose[2][2] - pose[1][2] * pose[2][0]) +
      pose[0][2] * (pose[1][0] * pose[2][1] - pose[1][1] * pose[2][0]);
    assert(
      Math.abs(det - 1) < 0.01 && K[0][0] > 0 && K[1][1] > 0 &&
        K[2].every((x, i) => x === (i === 2 ? 1 : 0)),
      400,
      "Invalid calibration",
    );
    integer(resolution.width, 1, 4096);
    integer(resolution.height, 1, 4096);
    assert(
      Array.isArray(frame.raw_feature_points) &&
        frame.raw_feature_points.length <= 50000,
      400,
      "Too many feature points",
    );
    for (const p of frame.raw_feature_points) {
      const point = object(p);
      assert(
        typeof point.id === "string" && /^[0-9]{1,20}$/.test(point.id),
        400,
        "Invalid feature identifier",
      );
      vector(point.position);
    }
    return {
      ticket_id: uuid(v.ticket_id),
      relative_path: path,
      frame: { ...frame, session_id: uuid(frame.session_id) },
    };
  });
  assert(
    new Set(result.map((x) => x.relative_path)).size === result.length &&
      new Set(result.map((x) => x.ticket_id)).size === result.length,
    400,
    "Duplicate input frame/ticket",
  );
  return result;
}
export function sceneManifest(value: unknown, job: Row): Row {
  function sceneVector(raw: unknown) {
    const result = vector(raw);
    assert(
      result.every((x) => Math.abs(x) <= 10000),
      400,
      "Scene position is out of bounds",
    );
    return result;
  }
  const v = object(value),
    bounds = object(v.bounds),
    min = sceneVector(bounds.min),
    max = sceneVector(bounds.max);
  assert(
    v.schema_version === 1 && v.format === "sog" &&
      v.provenance === "captured" && uuid(v.scene_id) === job.id &&
      uuid(v.artifact_revision) === job.artifact_revision,
    400,
    "Invalid reconstructed artifact identity",
  );
  assert(
    v.bytes === job.output_bytes && v.sha256 === job.output_sha256,
    400,
    "Manifest does not describe the sealed object",
  );
  integer(v.gaussian_count, 1, Number(job.max_gaussians));
  assert(
    min.every((x, i) => max[i] > x && max[i] - x <= 200),
    400,
    "Invalid scene bounds",
  );
  assert(
    finite(v.floor_y) && finite(v.eye_height) && v.eye_height >= 0.5 &&
      v.eye_height <= 2.5 && v.floor_y >= min[1] && v.floor_y <= max[1] &&
      v.floor_y + v.eye_height <= max[1],
    400,
    "Invalid walking height",
  );
  function camera(raw: unknown) {
    const p = object(raw),
      position = sceneVector(p.position),
      target = sceneVector(p.target);
    assert(
      position.every((x, i) => x >= min[i] && x <= max[i]) &&
        Math.hypot(...target.map((x, i) => x - position[i])) >= 0.01,
      400,
      "Camera lies outside the room",
    );
    return { position, target };
  }
  const initial = camera(v.initial_camera);
  assert(
    Array.isArray(v.rooms) && v.rooms.length <= 32,
    400,
    "Invalid room anchors",
  );
  const rooms = v.rooms.map((raw) => {
    const r = object(raw);
    assert(
      typeof r.id === "string" && /^[a-zA-Z0-9_-]{1,64}$/.test(r.id) &&
        typeof r.label === "string" && r.label.trim().length >= 1 &&
        r.label.length <= 80 && !/[\u0000-\u001f\u007f]/.test(r.label),
      400,
      "Invalid room label",
    );
    return { id: r.id, label: r.label, ...camera(r) };
  });
  assert(
    new Set(rooms.map((r) => r.id)).size === rooms.length,
    400,
    "Duplicate room anchor",
  );
  assert(
    v.floor_source === "capture_estimate" || v.floor_source === "roomplan",
    400,
    "Floor provenance is required",
  );
  assert(
    v.navigation_bounds_source === "capture_estimate",
    400,
    "Navigation bounds provenance is required",
  );
  return {
    schema_version: 1,
    scene_id: job.id,
    artifact_revision: job.artifact_revision,
    format: "sog",
    bytes: job.output_bytes,
    sha256: job.output_sha256,
    gaussian_count: v.gaussian_count,
    bounds: { min, max },
    floor_y: v.floor_y,
    eye_height: v.eye_height,
    floor_source: v.floor_source,
    navigation_bounds_source: "capture_estimate",
    initial_camera: initial,
    rooms,
    provenance: "captured",
    privacy_reviewed: false,
  };
}
export function privacyReview(value: unknown): Row {
  const v = object(value);
  assert(
    typeof v.approved === "boolean" && typeof v.exclude_room === "boolean" &&
      Array.isArray(v.redactions) && v.redactions.length <= 64,
    400,
    "Invalid privacy review",
  );
  const redactions = v.redactions.map((raw) => {
    const r = object(raw), min = vector(r.min), max = vector(r.max);
    assert(
      min.every((x, i) => max[i] > x && max[i] - x <= 200),
      400,
      "Invalid redaction region",
    );
    return { min, max };
  });
  return {
    artifact_revision: uuid(v.artifact_revision),
    approved: v.approved,
    exclude_room: v.exclude_room,
    redactions,
  };
}
export async function bytesLimited(
  req: Request,
  limit: number,
): Promise<Uint8Array<ArrayBuffer>> {
  const declared = req.headers.get("content-length");
  if (declared !== null) {
    assert(
      /^\d+$/.test(declared) && Number(declared) <= limit,
      413,
      "Output exceeds its byte budget",
    );
  }
  assert(req.body, 400, "Output body is required");
  const reader = req.body.getReader(), chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        await reader.cancel();
        throw new HttpError(413, "Output exceeds its byte budget");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}
export async function digest(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  ).map((n) => n.toString(16).padStart(2, "0")).join("");
}
