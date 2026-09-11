// Spatial is a measured-capture pipeline, not an ai_routes provider task. All
// transitions are durable RPCs; Deno never owns a long-running GPU promise.
import { handleOptions } from "../_shared/cors.ts";
import {
  assert,
  HttpError,
  json,
  pathSegments,
  readJsonLimited,
  respondError,
} from "../_shared/http.ts";
import {
  adminClient,
  getBearer,
  getUser,
  isServiceRole,
} from "../_shared/supabase.ts";
import {
  bytesLimited,
  captureManifest,
  digest,
  inputFiles,
  integer,
  MAX_OUTPUT_BYTES,
  object,
  privacyReview,
  roomLabel,
  type Row,
  sceneManifest,
  uuid,
} from "./contract.ts";
import { signCapability, verifyCapability } from "./capability.ts";
import { getOutput, readURL, storedOutput, storeOutput } from "./storage.ts";

// Dependencies expose real route execution to tests without pretending a mock
// service client proves PostgreSQL locks or actual R2 writes.
export interface Dependencies {
  admin: ReturnType<typeof adminClient>;
  user: (req: Request) => Promise<{ id: string }>;
  service: (req: Request) => boolean;
  sign: typeof signCapability;
  verify: typeof verifyCapability;
  readURL: typeof readURL;
  store: typeof storeOutput;
  head: typeof storedOutput;
  get: typeof getOutput;
  tourOrigin: () => string;
  functionOrigin: () => string;
}
function origin(raw: string | undefined, label: string) {
  assert(raw, 503, `${label} is not configured`);
  const u = new URL(raw);
  assert(
    u.protocol === "https:" && !u.username && !u.password,
    503,
    `${label} must use HTTPS`,
  );
  return u.toString().replace(/\/+$/, "");
}
function defaults(): Dependencies {
  return {
    admin: adminClient(),
    user: getUser,
    service: isServiceRole,
    sign: signCapability,
    verify: verifyCapability,
    readURL,
    store: storeOutput,
    head: storedOutput,
    get: getOutput,
    tourOrigin: () =>
      origin(
        Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com",
        "3D viewer",
      ),
    functionOrigin: () =>
      `${origin(Deno.env.get("SUPABASE_URL"), "3D service")}/functions/v1`,
  };
}
async function rpc(d: Dependencies, name: string, args: Row): Promise<unknown> {
  const { data, error } = await d.admin.rpc(name, args);
  if (error) {
    const match = /RP(400|403|404|409|429|503):\s*(.*)/.exec(error.message);
    throw new HttpError(
      match ? Number(match[1]) : 503,
      match ? match[2] : "3D state could not be confirmed — retry",
    );
  }
  return data;
}
async function job(d: Dependencies, id: string): Promise<Row> {
  const { data, error } = await d.admin.from("spatial_jobs").select("*").eq(
    "id",
    id,
  ).maybeSingle();
  if (error) throw new HttpError(503, "3D state could not be read");
  assert(data, 404, "3D room not found");
  return object(data);
}
async function access(d: Dependencies, actor: string, j: Row, write = false) {
  const org = await rpc(d, "spatial_access", {
    p_actor: actor,
    p_listing: j.listing_id,
    p_write: write,
  });
  assert(org === j.org_id, 403, "Room workspace has changed");
}
async function dto(d: Dependencies, j: Row, actor: string): Promise<Row> {
  let viewer: string | null = null, share: string | null = null;
  if (
    ["review", "ready"].includes(String(j.status)) && j.artifact_revision &&
    j.output_state === "stored"
  ) {
    const cap = await d.sign({
      v: 1,
      kind: "viewer",
      job: String(j.id),
      revision: String(j.artifact_revision),
      actor,
      exp: Math.floor(Date.now() / 1000) + 900,
    });
    viewer = `${d.tourOrigin()}/s/${j.id}#access=${encodeURIComponent(cap)}`;
    if (
      j.status === "ready" && j.published_at && j.approved && !j.excluded &&
      j.review_revision === j.artifact_revision
    ) share = `${d.tourOrigin()}/s/${j.id}`;
  }
  const attempts = Number(j.attempt_number ?? 1),
    deadline = typeof j.deadline_at === "string"
      ? Date.parse(j.deadline_at)
      : NaN;
  const priorStopped = j.started_at == null || j.provider_stopped === true ||
    (Number.isFinite(deadline) && deadline <= Date.now());
  const resumable = j.status === "failed" &&
    j.failure_code === "user_cancelled" && j.started_at == null;
  return {
    id: j.id,
    listing_id: j.listing_id,
    room_label: j.room_label,
    status: j.status,
    progress: Number(j.progress),
    failure_code: j.failure_code ?? null,
    attempt_number: attempts,
    can_retry: j.status === "failed" && !resumable &&
      j.inputs_complete === true && attempts < 3 && priorStopped,
    can_cancel: ["uploading", "queued"].includes(String(j.status)),
    can_resume: resumable,
    retry_after:
      j.status === "failed" && !priorStopped && Number.isFinite(deadline)
        ? new Date(deadline).toISOString()
        : null,
    artifact_revision: j.artifact_revision ?? null,
    privacy_state: j.excluded
      ? "excluded"
      : Array.isArray(j.redactions) && j.redactions.length
      ? "redaction_required"
      : j.approved
      ? "approved"
      : "unreviewed",
    viewer_url: viewer,
    share_url: share,
    created_at: j.created_at,
    updated_at: j.updated_at,
  };
}
async function visibleArtifact(
  d: Dependencies,
  req: Request,
  id: string,
): Promise<Row> {
  const j = await job(d, id), bearer = getBearer(req);
  if (bearer) {
    const cap = await d.verify(bearer, "viewer");
    assert(
      cap.job === id && cap.revision === j.artifact_revision,
      409,
      "3D room changed; open it again",
    );
    await access(d, cap.actor, j);
  } else {
    assert(
      j.status === "ready" && j.approved === true && j.excluded === false &&
        j.published_at && j.review_revision === j.artifact_revision &&
        Array.isArray(j.redactions) && j.redactions.length === 0,
      404,
      "3D room is private",
    );
    // Public access must also disappear when a home or workspace is removed.
    const { data, error } = await d.admin.from("listings").select(
      "id,org_id,deleted_at,orgs!inner(deleted_at)",
    ).eq("id", j.listing_id).eq("org_id", j.org_id).is("deleted_at", null)
      .maybeSingle();
    assert(
      !error && data && object(data.orgs).deleted_at === null,
      404,
      "3D room is unavailable",
    );
  }
  assert(
    ["review", "ready"].includes(String(j.status)) &&
      j.output_state === "stored" && j.scene_manifest,
    404,
    "3D reconstruction is not ready",
  );
  return j;
}
export async function handler(
  req: Request,
  dependencies?: Dependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    const d = dependencies ?? defaults(),
      parts = pathSegments(req, "spatial"),
      method = req.method,
      url = new URL(req.url);
    if (
      parts.length === 2 && ["manifest", "model"].includes(parts[1]) &&
      method === "GET"
    ) {
      const j = await visibleArtifact(d, req, uuid(parts[0]));
      if (parts[1] === "manifest") {
        return json(
          {
            ...object(j.scene_manifest),
            privacy_reviewed: j.approved === true &&
              j.review_revision === j.artifact_revision && !j.excluded,
          },
          200,
          { "cache-control": "no-store" },
        );
      }
      assert(
        url.searchParams.get("revision") === j.artifact_revision,
        409,
        "3D room changed; reload it",
      );
      const response = await d.get(j);
      return new Response(response.body, {
        headers: {
          "content-type": "application/octet-stream",
          "content-length": String(j.output_bytes),
          "cache-control": "no-store",
          "x-content-type-options": "nosniff",
        },
      });
    }
    // Upload capability is narrowly scoped to this lease/revision; the remote
    // sandbox never receives the Supabase service key or ambient R2 credentials.
    if (
      parts.length === 3 && parts[0] === "worker" && parts[2] === "output" &&
      method === "PUT"
    ) {
      const id = uuid(parts[1]),
        cap = await d.verify(getBearer(req) ?? "", "output"),
        j = await job(d, id);
      assert(
        cap.job === id && cap.revision === j.artifact_revision &&
          cap.lease === j.lease_token,
        409,
        "Output lease changed",
      );
      assert(
        req.headers.get("content-type") === "application/octet-stream",
        400,
        "Output must be a SOG byte stream",
      );
      const bytes = await bytesLimited(
        req,
        Math.min(Number(j.output_bytes), MAX_OUTPUT_BYTES),
      );
      assert(
        bytes.length === j.output_bytes &&
          await digest(bytes) === j.output_sha256,
        400,
        "Output does not match its ticket",
      );
      const claimed = object(
        await rpc(d, "spatial_worker_update", {
          p_job: id,
          p_lease: cap.lease,
          p_action: "output_claim",
          p_data: {},
        }),
      );
      const etag = claimed.dispatch === true
        ? await d.store(claimed, bytes)
        : await d.head(claimed);
      await rpc(d, "spatial_worker_update", {
        p_job: id,
        p_lease: cap.lease,
        p_action: "output_stored",
        p_data: { etag },
      });
      return json({ ok: true, artifact_revision: j.artifact_revision });
    }
    if (parts[0] === "worker") {
      assert(d.service(req), 403, "Worker authorization required");
      assert(method === "POST", 405, "Use POST");
      const body = object(await readJsonLimited(req, 256 * 1024));
      if (parts.length === 2 && parts[1] === "sweep") {
        const expired = await rpc(d, "spatial_expire", {});
        return json({ ok: true, expired });
      }
      if (parts.length === 2 && parts[1] === "claim") {
        await rpc(d, "spatial_expire", {});
        const value = await rpc(d, "spatial_claim", {
          p_worker: uuid(body.worker_id),
        });
        if (value === null) return json({ job: null });
        const j = object(value);
        const inputs = await Promise.all(
          (j.inputs as Row[]).map(async (input) => ({
            ...input,
            download_url: await d.readURL(String(input.storage_key)),
          })),
        );
        return json({
          job: {
            id: j.id,
            listing_id: j.listing_id,
            room_label: j.room_label,
            lease_token: j.lease_token,
            lease_expires_at: j.lease_expires_at,
            deadline_at: j.deadline_at,
            max_seconds: j.max_seconds,
            max_training_seconds: j.max_training_seconds,
            max_iterations: j.max_iterations,
            max_gaussians: j.max_gaussians,
            max_cost_cents: j.max_cost_cents,
            inputs,
            manifest: j.capture_manifest,
          },
        });
      }
      assert(parts.length === 3, 404, "Worker route not found");
      const id = uuid(parts[1]),
        lease = uuid(body.lease_token),
        action = parts[2];
      if (action === "output-ticket") {
        integer(body.bytes, 1, MAX_OUTPUT_BYTES);
        assert(
          typeof body.sha256 === "string" && /^[0-9a-f]{64}$/.test(body.sha256),
          400,
          "Output hash is required",
        );
        const j = object(
          await rpc(d, "spatial_worker_update", {
            p_job: id,
            p_lease: lease,
            p_action: "output_ticket",
            p_data: { bytes: body.bytes, sha256: body.sha256 },
          }),
        );
        const exp = Math.min(
          Math.floor(Date.now() / 1000) + 900,
          Math.floor(new Date(String(j.deadline_at)).getTime() / 1000),
        );
        const token = await d.sign({
          v: 1,
          kind: "output",
          job: id,
          revision: String(j.artifact_revision),
          actor: String(j.actor_id),
          lease,
          exp,
        });
        return json({
          upload_url: `${d.functionOrigin()}/spatial/worker/${id}/output`,
          upload_token: token,
          artifact_revision: j.artifact_revision,
          method: "PUT",
          content_type: "application/octet-stream",
          bytes: j.output_bytes,
          expires_at: new Date(exp * 1000).toISOString(),
        });
      }
      assert(
        ["heartbeat", "complete", "fail"].includes(action),
        404,
        "Worker route not found",
      );
      let data: Row = body;
      if (action === "complete") {
        const j = await job(d, id);
        await d.head(j);
        data = {
          cost_cents: body.cost_cents,
          manifest: sceneManifest(body.manifest, j),
        };
      }
      if (
        action === "heartbeat" || action === "complete" || action === "fail"
      ) integer(body.cost_cents, 0, 100000);
      const j = object(
        await rpc(d, "spatial_worker_update", {
          p_job: id,
          p_lease: lease,
          p_action: action,
          p_data: data,
        }),
      );
      return json({
        ok: true,
        id: j.id,
        status: j.status,
        lease_expires_at: j.lease_expires_at,
        deadline_at: j.deadline_at,
      });
    }
    const actor = uuid((await d.user(req)).id);
    if (parts.length === 0 && method === "GET") {
      const listing = uuid(url.searchParams.get("listing_id"));
      await rpc(d, "spatial_access", {
        p_actor: actor,
        p_listing: listing,
        p_write: false,
      });
      await rpc(d, "spatial_expire", { p_listing: listing });
      const { data, error } = await d.admin.from("spatial_jobs").select("*").eq(
        "listing_id",
        listing,
      ).order("created_at", { ascending: false }).limit(100);
      assert(!error && data, 503, "3D rooms could not be loaded");
      return json({
        jobs: await Promise.all(data.map((j) => dto(d, object(j), actor))),
      });
    }
    if (parts.length === 0 && method === "POST") {
      const body = object(await readJsonLimited(req, 128 * 1024)),
        capture = uuid(body.capture_id);
      const label = roomLabel(body.room_label);
      const j = object(
        await rpc(d, "spatial_create", {
          p_actor: actor,
          p_listing: uuid(body.listing_id),
          p_capture: capture,
          p_idem: uuid(req.headers.get("idempotency-key")),
          p_label: label,
          p_manifest: captureManifest(body.manifest, capture),
        }),
      );
      return json(await dto(d, j, actor));
    }
    assert(
      parts.length >= 1 && parts.length <= 2,
      404,
      "Spatial route not found",
    );
    const id = uuid(parts[0]), j = await job(d, id);
    await access(d, actor, j, method !== "GET");
    if (parts.length === 1 && method === "GET") {
      if (j.status === "processing") {
        await rpc(d, "spatial_expire", { p_listing: j.listing_id });
        return json(await dto(d, await job(d, id), actor));
      }
      return json(await dto(d, j, actor));
    }
    assert(
      parts.length === 2 && method === "POST",
      405,
      "Use a supported spatial action",
    );
    const body = object(
      await readJsonLimited(
        req,
        parts[1] === "inputs" ? 8 * 1024 * 1024 : 128 * 1024,
      ),
    );
    let result: unknown;
    if (["retry", "cancel", "resume"].includes(parts[1])) {
      result = await rpc(d, "spatial_recover", {
        p_actor: actor,
        p_job: id,
        p_action: parts[1],
        p_idem: parts[1] === "retry"
          ? uuid(req.headers.get("idempotency-key"))
          : null,
      });
    } else if (parts[1] === "inputs") {
      result = await rpc(d, "spatial_attach_inputs", {
        p_actor: actor,
        p_job: id,
        p_files: inputFiles(body.files),
      });
    } else if (parts[1] === "start") {
      result = await rpc(d, "spatial_start", { p_actor: actor, p_job: id });
    } else if (parts[1] === "review") {
      const review = privacyReview(body);
      result = await rpc(d, "spatial_review", {
        p_actor: actor,
        p_job: id,
        p_revision: review.artifact_revision,
        p_approved: review.approved,
        p_excluded: review.exclude_room,
        p_redactions: review.redactions,
      });
    } else if (parts[1] === "publish") {
      assert(
        uuid(body.artifact_revision) === j.artifact_revision,
        409,
        "Review the current 3D room",
      );
      result = await rpc(d, "spatial_publish", { p_actor: actor, p_job: id });
    } else throw new HttpError(404, "Spatial action not found");
    return json(await dto(d, object(result), actor));
  } catch (error) {
    return respondError(error);
  }
}
if (import.meta.main) Deno.serve((req) => handler(req));
