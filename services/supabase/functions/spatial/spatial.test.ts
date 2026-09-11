import { type Dependencies, handler } from "./index.ts";
import {
  bytesLimited,
  captureManifest,
  digest,
  inputFiles,
  type Row,
  sceneManifest,
} from "./contract.ts";
import { signCapability, verifyCapability } from "./capability.ts";
import { bindSpatialChapters } from "./chapters.ts";
function a(value: unknown, label = "assertion failed"): asserts value {
  if (!value) throw new Error(label);
}
async function rejects(fn: () => unknown | Promise<unknown>) {
  let failed = false;
  try {
    await fn();
  } catch {
    failed = true;
  }
  a(failed, "negative case was accepted");
}
const id = "a0400000-0000-4000-8000-000000000001",
  actor = "a0400000-0000-4000-8000-000000000002",
  listing = "a0400000-0000-4000-8000-000000000003",
  revision = "a0400000-0000-4000-8000-000000000004",
  lease = "a0400000-0000-4000-8000-000000000005";
const secret = "synthetic-spatial-test-secret-not-a-credential";
const identity = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]];
function capture(): Row {
  return {
    schema_version: 1,
    format: "rendprop-arkit-capture",
    session_id: id,
    status: "complete",
    coordinate_system: "arkit-right-handed-y-up-camera-minus-z-forward",
    matrix_layout: "row-major",
    pose_type: "camera-to-world",
    units: "metres",
    image_orientation: "sensor-native-exif-1",
    image_bytes: 2000,
    feature_point_observations: 20,
    frames: Array.from(
      { length: 20 },
      (_, i) => `frames/${String(i + 1).padStart(6, "0")}.json`,
    ),
  };
}
function input(): Row {
  return {
    ticket_id: revision,
    relative_path: "images/000001.jpg",
    frame: {
      schema_version: 1,
      session_id: id,
      image: "images/000001.jpg",
      camera_to_world: structuredClone(identity),
      intrinsics: [[1000, 0, 960], [0, 1000, 720], [0, 0, 1]],
      image_resolution: { width: 1920, height: 1440 },
      timestamp: 1,
      tracking_state: { state: "normal" },
      raw_feature_points: [{ id: "1", position: [0, 0, -1] }],
    },
  };
}
function manifest(hash: string): Row {
  return {
    schema_version: 1,
    scene_id: id,
    artifact_revision: revision,
    format: "sog",
    bytes: 3,
    sha256: hash,
    gaussian_count: 1000,
    bounds: { min: [-2, -1, -2], max: [2, 3, 2] },
    floor_y: 0,
    eye_height: 1.6,
    floor_source: "capture_estimate",
    navigation_bounds_source: "capture_estimate",
    initial_camera: { position: [0, 1.6, 0], target: [0, 1.6, -1] },
    rooms: [{
      id: "room",
      label: "Room",
      position: [0, 1.6, 0],
      target: [0, 1.6, -1],
    }],
    provenance: "captured",
    privacy_reviewed: true,
  };
}
function fixture(initial: Partial<Row> = {}) {
  const calls: Array<{ name: string; args: Row }> = [],
    j: Row = {
      id,
      actor_id: actor,
      listing_id: listing,
      org_id: actor,
      room_label: "Room",
      status: "review",
      progress: 1,
      artifact_revision: revision,
      lease_token: lease,
      deadline_at: new Date(Date.now() + 600000).toISOString(),
      output_bytes: 3,
      output_state: "stored",
      output_sha256: "a".repeat(64),
      output_etag: '"receipt"',
      max_gaussians: 500000,
      redactions: [],
      approved: false,
      excluded: false,
      review_revision: null,
      created_at: "2026-09-11T00:00:00Z",
      updated_at: "2026-09-11T00:00:00Z",
      ...initial,
    };
  j.scene_manifest = manifest(String(j.output_sha256));
  let stored = 0;
  const admin = {
    rpc(name: string, args: Row) {
      calls.push({ name, args });
      if (name === "spatial_access") {
        return Promise.resolve({ data: j.org_id, error: null });
      }
      if (name === "spatial_expire") {
        return Promise.resolve({ data: 0, error: null });
      }
      if (name === "spatial_claim") {
        return Promise.resolve({ data: null, error: null });
      }
      if (
        name === "spatial_worker_update" && args.p_action === "output_claim"
      ) {
        const dispatch = j.output_state === "planned";
        j.output_state = "dispatching";
        return Promise.resolve({ data: { ...j, dispatch }, error: null });
      }
      if (
        name === "spatial_worker_update" && args.p_action === "output_stored"
      ) j.output_state = "stored";
      return Promise.resolve({ data: { ...j }, error: null });
    },
    from(table: string) {
      const q = {
        select() {
          return q;
        },
        eq() {
          return q;
        },
        is() {
          return q;
        },
        order() {
          return q;
        },
        limit() {
          return Promise.resolve({ data: [j], error: null });
        },
        maybeSingle() {
          return Promise.resolve({
            data: table === "listings"
              ? {
                id: listing,
                org_id: actor,
                deleted_at: null,
                orgs: { deleted_at: null },
              }
              : j,
            error: null,
          });
        },
      };
      return q;
    },
  };
  const d: Dependencies = {
    admin: admin as unknown as Dependencies["admin"],
    user: async () => ({ id: actor }),
    service: (r) => r.headers.get("x-fixture-worker") === "yes",
    sign: (p) => signCapability(p, secret),
    verify: (t, k) => verifyCapability(t, k, secret),
    readURL: async () => "https://private.invalid/read",
    store: async () => {
      stored++;
      return '"etag"';
    },
    head: async () => String(j.output_etag),
    get: async () => new Response(new Uint8Array([1, 2, 3])),
    tourOrigin: () => "https://tour.invalid",
    functionOrigin: () => "https://functions.invalid/functions/v1",
  };
  return { d, j, calls, stored: () => stored };
}
const request = (
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
) =>
  new Request(`https://functions.invalid/functions/v1/spatial${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
Deno.test("provider journal route remains service-only and preserves distinct paid attempt key", async () => {
  const f = fixture(), body = { lease_token: lease, attempt_key: revision,
    action: "cleanup", data: { sandbox_id: "sb-fixture1234", files_removed: true, terminated: true } };
  a((await handler(request(`/worker/${id}/provider-attempt`, body), f.d)).status === 403);
  a(f.calls.length === 0, "unauthorized receipt reached DB");
  const result = await handler(request(`/worker/${id}/provider-attempt`, body, { "x-fixture-worker": "yes" }), f.d);
  a(result.status === 200);
  const call = f.calls[0];
  a(call.name === "spatial_provider_attempt_update" && call.args.p_job === id
    && call.args.p_lease === lease && call.args.p_attempt === revision && call.args.p_action === "cleanup");
  a(JSON.stringify(call.args.p_data) === JSON.stringify(body.data));
  a((await handler(request(`/worker/${id}/provider-attempt`, { ...body, action: "allocate_again" }, { "x-fixture-worker": "yes" }), f.d)).status === 400);
});
Deno.test("completed capture exact schema and coverage accepted", () =>
  a(captureManifest(capture(), id).session_id === id));
for (
  const [name, patch] of Object.entries({
    "truncated capture": { frames: ["frames/000001.json"] },
    "duplicate frames": { frames: Array(20).fill("frames/000001.json") },
    "different epoch": { session_id: actor },
    "unsupported orientation": { image_orientation: "rotated" },
    "unfinished capture": { status: "recording" },
  })
) {
  Deno.test(
    name,
    () => rejects(() => captureManifest({ ...capture(), ...patch }, id)),
  );
}
Deno.test("valid finite ARKit pose accepted", () =>
  a(inputFiles([input()]).length === 1));
Deno.test("non-homogeneous pose rejected", () => {
  const v = input();
  (v.frame as Row).camera_to_world = [
    [1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0],
    [1, 0, 0, 1],
  ];
  return rejects(() => inputFiles([v]));
});
Deno.test("reflected rotation rejected", () => {
  const v = input();
  (v.frame as Row).camera_to_world = [
    [-1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0],
    [0, 0, 0, 1],
  ];
  return rejects(() => inputFiles([v]));
});
Deno.test("duplicate tickets rejected", () =>
  rejects(() => inputFiles([input(), input()])));
Deno.test("path traversal rejected", () =>
  rejects(() =>
    inputFiles([{ ...input(), relative_path: "../images/000001.jpg" }])
  ));
Deno.test("actual bounded stream rejects surplus body without content length", async () => {
  await rejects(() =>
    bytesLimited(
      new Request("https://fixture.invalid", {
        method: "PUT",
        body: new Uint8Array(4),
      }),
      3,
    )
  );
});
Deno.test("viewer capability MAC bound to kind and expiry", async () => {
  const p = {
    v: 1 as const,
    kind: "viewer" as const,
    job: id,
    revision,
    actor,
    exp: Math.floor(Date.now() / 1000) + 600,
  };
  const cap = await signCapability(p, secret);
  a((await verifyCapability(cap, "viewer", secret)).job === id);
  await rejects(() => verifyCapability(cap, "output", secret));
  await rejects(() => verifyCapability(cap + "x", "viewer", secret));
  await rejects(async () =>
    verifyCapability(
      await signCapability({ ...p, exp: 1 }, secret),
      "viewer",
      secret,
    )
  );
});
Deno.test("GET job executes route and returns fragment private viewer", async () => {
  const f = fixture(),
    r = await handler(request(`/${id}`), f.d),
    body = await r.json();
  a(
    r.status === 200 && body.id === id &&
      body.viewer_url.startsWith(`https://tour.invalid/s/${id}#access=`),
  );
  a(f.calls.some((c) => c.name === "spatial_access"));
  a(body.output_key === undefined && body.lease_token === undefined);
});
Deno.test("POST create executes durable RPC with caller-bound identity", async () => {
  const f = fixture({ status: "uploading", artifact_revision: null }),
    r = await handler(
      request("", {
        listing_id: listing,
        capture_id: id,
        room_label: "Room",
        manifest: capture(),
      }, { "idempotency-key": revision }),
      f.d,
    );
  a(r.status === 200);
  const call = f.calls.find((c) => c.name === "spatial_create");
  a(call?.args.p_actor === actor && call.args.p_idem === revision);
});
Deno.test("missing idempotency key rejected before mutation", async () => {
  const f = fixture(),
    r = await handler(
      request("", {
        listing_id: listing,
        capture_id: id,
        room_label: "Room",
        manifest: capture(),
      }),
      f.d,
    );
  a(r.status === 400 && !f.calls.some((c) => c.name === "spatial_create"));
});
Deno.test("worker route refuses member before any RPC", async () => {
  const f = fixture(),
    r = await handler(request("/worker/claim", { worker_id: actor }), f.d);
  a(r.status === 403 && f.calls.length === 0);
});
Deno.test("worker claim is explicit empty result not fake completed room", async () => {
  const f = fixture(),
    r = await handler(
      request("/worker/claim", { worker_id: actor }, {
        "x-fixture-worker": "yes",
      }),
      f.d,
    );
  a(r.status === 200 && (await r.json()).job === null);
  a(f.calls.map((c) => c.name).join(",") === "spatial_expire,spatial_claim");
});
Deno.test("anonymous public manifest never serves unreviewed artifact", async () => {
  const f = fixture(), r = await handler(request(`/${id}/manifest`), f.d);
  a(r.status === 404);
});
Deno.test("owner manifest strips worker privacy assertion until real approval", async () => {
  const f = fixture(),
    cap = await f.d.sign({
      v: 1,
      kind: "viewer",
      job: id,
      revision,
      actor,
      exp: Math.floor(Date.now() / 1000) + 600,
    }),
    r = await handler(
      request(`/${id}/manifest`, undefined, { authorization: `Bearer ${cap}` }),
      f.d,
    );
  a(r.status === 200);
  a(
    (await r.json()).privacy_reviewed === false &&
      r.headers.get("cache-control") === "no-store",
  );
});
Deno.test("model is bound to revision and requires current owner capability", async () => {
  const f = fixture(),
    cap = await f.d.sign({
      v: 1,
      kind: "viewer",
      job: id,
      revision,
      actor,
      exp: Math.floor(Date.now() / 1000) + 600,
    });
  a(
    (await handler(
      request(`/${id}/model?revision=${actor}`, undefined, {
        authorization: `Bearer ${cap}`,
      }),
      f.d,
    )).status === 409,
  );
  const response = await handler(
    request(`/${id}/model?revision=${revision}`, undefined, {
      authorization: `Bearer ${cap}`,
    }),
    f.d,
  );
  a(response.status === 200 && (await response.arrayBuffer()).byteLength === 3);
});
Deno.test("actual output bytes hash checked before physical storage", async () => {
  const hash = await digest(new Uint8Array([1, 2, 3])),
    f = fixture({
      status: "processing",
      output_state: "planned",
      output_sha256: hash,
    }),
    cap = await f.d.sign({
      v: 1,
      kind: "output",
      job: id,
      revision,
      actor,
      lease,
      exp: Math.floor(Date.now() / 1000) + 600,
    });
  const req = (bytes: number[]) =>
    new Request(
      `https://functions.invalid/functions/v1/spatial/worker/${id}/output`,
      {
        method: "PUT",
        headers: {
          authorization: `Bearer ${cap}`,
          "content-type": "application/octet-stream",
        },
        body: new Uint8Array(bytes),
      },
    );
  a((await handler(req([3, 2, 1]), f.d)).status === 400 && f.stored() === 0);
  a((await handler(req([1, 2, 3]), f.d)).status === 200 && f.stored() === 1);
  a((await handler(req([1, 2, 3]), f.d)).status === 200 && f.stored() === 1);
});
Deno.test("scene manifest refuses over-cap gaussians and invented provenance", async () => {
  const f = fixture(), valid = manifest(String(f.j.output_sha256));
  a(sceneManifest(valid, f.j).privacy_reviewed === false);
  await rejects(() => sceneManifest({ ...valid, gaussian_count: 500001 }, f.j));
  await rejects(() =>
    sceneManifest({ ...valid, provenance: "synthetic" }, f.j)
  );
});
Deno.test("publish request requires currently viewed artifact revision", async () => {
  const f = fixture(),
    r = await handler(
      request(`/${id}/publish`, { artifact_revision: actor }),
      f.d,
    );
  a(r.status === 409 && !f.calls.some((c) => c.name === "spatial_publish"));
});
Deno.test("late chapter binding needs unique current approved room and no render change", () => {
  const f = fixture({
      status: "ready",
      approved: true,
      published_at: "2026-09-11T00:00:00Z",
      review_revision: revision,
    }),
    chapters = [{ label: "  ROOM ", t_ms: 1234, sort: 0 }];
  const bound = bindSpatialChapters(chapters, [f.j]);
  a(bound[0].spatial_anchor?.scene_id === id && bound[0].t_ms === 1234);
  a(!bindSpatialChapters(chapters, [f.j, f.j])[0].spatial_anchor);
  a(!bindSpatialChapters([chapters[0], chapters[0]], [f.j])[0].spatial_anchor);
  a(
    !bindSpatialChapters(chapters, [{ ...f.j, approved: false }])[0]
      .spatial_anchor,
  );
  a(
    !bindSpatialChapters(chapters, [{ ...f.j, review_revision: actor }])[0]
      .spatial_anchor,
  );
});
