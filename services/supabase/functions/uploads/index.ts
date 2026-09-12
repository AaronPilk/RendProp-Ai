// Upload transport v2: service-only reservations authorize one exact-size
// gateway dispatch per journaled operation. No reusable R2 PUT URL fallback.
// Requires 0037 + 0042 + configured gateway and drained legacy URLs before rollout.
// Cancellation releases only undispatched held bytes; cleanup is journaled,
// asynchronous, and does not refund physical writes or promise zero ingress cost.

import { handleOptions } from "../_shared/cors.ts";
import {
  assert,
  HttpError,
  json,
  pathSegments,
  readJson,
  respondError,
} from "../_shared/http.ts";
import {
  adminClient,
  assertNotDeleting,
  getUser,
  isServiceRole,
  userClient,
} from "../_shared/supabase.ts";
import {
  baseMediaType,
  isContentTypeDeclared,
  requireBareContentType,
} from "./content_type.ts";
import { canonicalParts, sameParts } from "./publication.ts";
import {
  confirmedTransfers,
  recordedOperation,
  reserveAssets,
  row,
  settleReservation,
  transferURL,
  transportConfiguration,
  uploadRPC,
} from "./transport.ts";
import { sweepUploads } from "./maintenance.ts";
import {
  choosePartSize,
  completeMultipartUpload,
  copyObject,
  createMultipartUpload,
  extFromFilename,
  headObject,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
} from "../_shared/r2.ts";

/** Map a capture_assets.bucket tag → the actual R2 bucket name. */
function r2BucketFor(bucket: unknown): string {
  return bucket === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS;
}

// All terminal transitions compete on the same row predicate. In particular,
// abort/mismatch must win THIS fence before deleting any assembled object.
// deno-lint-ignore no-explicit-any
function pendingAsset(
  admin: any,
  asset: Record<string, unknown>,
  patch: Record<string, unknown>,
) {
  return admin.from("capture_assets").update(patch).eq("id", asset.id)
    .eq("storage_key", asset.storage_key).eq("uploaded", false).eq(
      "upload_aborted",
      false,
    );
}

// deno-lint-ignore no-explicit-any
async function reloadAsset(
  admin: any,
  assetId: string,
): Promise<Record<string, unknown>> {
  const { data, error } = await admin.from("capture_assets").select("*").eq(
    "id",
    assetId,
  ).maybeSingle();
  if (error || !data) {
    throw new HttpError(
      503,
      "Upload state could not be confirmed — retry completion",
    );
  }
  return data;
}

/** Marketing is read-only (audit P0-7): only owner/admin/agent may upload. */
// deno-lint-ignore no-explicit-any
async function requireWriteRole(admin: any, userId: string, orgId: string) {
  const { data, error } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq(
      "org_id",
      orgId,
    ).maybeSingle();
  if (error) throw new HttpError(500, `Role lookup failed: ${error.message}`);
  const role = data?.role;
  if (!role || role === "marketing") {
    throw new HttpError(403, "Your role does not permit uploading media");
  }
}

/**
 * Same gate for the ASSET-scoped routes (part-urls / complete / abort). RLS
 * proves the caller is in the asset's org, but not that their role may write —
 * without this a marketing member could mint part URLs for, complete, or abort
 * another member's in-flight multipart upload (audit: gate was only on the
 * ticket-creating routes).
 */
// deno-lint-ignore no-explicit-any
async function requireAssetWriteRole(
  db: any,
  admin: any,
  userId: string,
  asset: Record<string, unknown>,
) {
  const { data, error } = await db
    .from("listings").select("org_id").eq("id", asset.listing_id as string)
    .maybeSingle();
  if (error) {
    throw new HttpError(400, `Listing lookup failed: ${error.message}`);
  }
  if (!data) throw new HttpError(404, "Listing not found");
  await requireWriteRole(admin, userId, data.org_id as string);
}

// Video at/above this size (or an explicit multipart flag) uses multipart.
const MULTIPART_THRESHOLD = 64 * 1024 * 1024; // 64 MB
const MAX_PART_URLS_PER_CALL = 256;
const MAX_PHOTOS_PER_BATCH = 200;

// Hard size ceilings + a content-type allowlist so a caller can't presign an
// arbitrary-type or absurdly large object.
const MAX_VIDEO_BYTES = 12 * 1024 * 1024 * 1024; // 12 GB (a 4K / 9-min walkthrough is ~8 GB)
const MAX_PHOTO_BYTES = 50 * 1024 * 1024; // 50 MB
const MAX_POSTER_BYTES = 10 * 1024 * 1024; // 10 MB — a 1280px JPEG is ~300 KB
const ALLOWED_VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v"];
const ALLOWED_PHOTO_TYPES = [
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif",
  "image/webp",
];
// Posters are served to browsers as og:image / <video poster>: HEIC is out.
const ALLOWED_POSTER_TYPES = ["image/jpeg", "image/png", "image/webp"];
const POSTER_EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

/** Bound + validate one file's claimed size/type for its kind. */
function validateFileMeta(
  kind: "video" | "photo",
  bytes: number | null | undefined,
  contentType: string,
  label = "",
  opts: { poster?: boolean; original?: boolean } = {},
) {
  // An `original` is served to a browser like a poster (so: jpeg|png|webp) but
  // it is a full-resolution photo, so it gets the photo ceiling, not the 10 MB
  // poster one (W2-B4).
  const what = opts.original ? "original" : opts.poster ? "poster" : kind;
  const maxBytes = opts.poster
    ? MAX_POSTER_BYTES
    : kind === "photo"
    ? MAX_PHOTO_BYTES
    : MAX_VIDEO_BYTES;
  assert(
    bytes != null && Number.isSafeInteger(bytes) && bytes > 0 &&
      bytes <= maxBytes,
    400,
    `bytes is required and must be between 1 and ${maxBytes} for a ${what}${label}`,
  );
  const allowed = (opts.poster || opts.original)
    ? ALLOWED_POSTER_TYPES
    : kind === "photo"
    ? ALLOWED_PHOTO_TYPES
    : ALLOWED_VIDEO_TYPES;
  assert(
    allowed.includes(contentType),
    400,
    `content_type "${contentType}" is not an allowed ${what} type${label} (allowed: ${
      allowed.join(", ")
    })`,
  );
}

/** Sanitize optional completion metadata (client-claimed, bounded). */
function metadataPatch(body: CompleteBody): Record<string, unknown> {
  const patch: Record<string, unknown> = {};
  if (body.duration_s !== undefined) {
    const d = Number(body.duration_s);
    if (Number.isFinite(d) && d > 0 && d <= 7200) patch.duration_s = d;
  }
  if (body.fps !== undefined) {
    const f = Number(body.fps);
    if (Number.isFinite(f) && f > 0 && f <= 240) patch.fps = f;
  }
  for (const k of ["width", "height"] as const) {
    if (body[k] !== undefined) {
      const v = Number(body[k]);
      if (Number.isInteger(v) && v > 0 && v <= 16384) patch[k] = v;
    }
  }
  if (typeof body.codec === "string" && body.codec.length <= 32) {
    patch.codec = body.codec;
  }
  if (typeof body.is_drone === "boolean") patch.is_drone = body.is_drone;
  if (typeof body.has_gyro === "boolean") patch.has_gyro = body.has_gyro;
  if (typeof body.sha256 === "string" && /^[a-f0-9]{64}$/i.test(body.sha256)) {
    patch.sha256 = body.sha256.toLowerCase();
  }
  return patch;
}

interface CreateBody {
  listing_id: string;
  filename?: string;
  bytes?: number;
  sha256?: string;
  kind?: "video" | "photo";
  content_type?: string;
  multipart?: boolean;
  /** "render" = the app's on-device rendered mp4 (kind video) or its poster
   *  (kind photo) → public renders bucket. "original" = the untouched source of
   *  an AI-altered photo → public renders bucket, key `original-<asset>.<ext>`
   *  (always kind photo; CA AB 723 access-to-the-original). default "capture" =
   *  raw walkthrough/photo → private uploads bucket. */
  role?: "capture" | "render" | "original" | "gallery";
}

interface BatchBody {
  listing_id: string;
  kind?: "photo" | "video";
  files?: Array<
    {
      filename?: string;
      bytes?: number;
      sha256?: string;
      content_type?: string;
    }
  >;
}

interface PartUrlsBody {
  numbers?: number[];
}

interface CompleteBody {
  parts?: Array<{ number: number; etag: string }>;
  duration_s?: number;
  fps?: number;
  width?: number;
  height?: number;
  codec?: string;
  is_drone?: boolean;
  has_gyro?: boolean;
  sha256?: string;
  bytes?: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    const route = pathSegments(req, "uploads");
    if (req.method === "POST" && route.length === 1 && route[0] === "sweep") {
      if (!isServiceRole(req)) {
        throw new HttpError(403, "Service role required");
      }
      const receipt = await sweepUploads(adminClient());
      return json(receipt, receipt.failed ? 503 : 200);
    }
    const user = await getUser(req),
      db = userClient(req),
      admin = adminClient();
    const seg = pathSegments(req, "uploads");
    if (req.method !== "POST") throw new HttpError(405, "POST required");

    if (!seg.length || (seg.length === 1 && seg[0] === "batch")) {
      // No presigned R2 fallback: a missing gateway is a pre-reservation error.
      transportConfiguration();
      const body = await readJson<CreateBody & BatchBody>(req);
      const listing = await requireListing(db, body.listing_id);
      await requireWriteRole(admin, user.id, listing.org_id);
      await assertNotDeleting(user.id);
      const batch = seg[0] === "batch";
      const files = batch ? body.files : [body];
      assert(
        Array.isArray(files) && files.length > 0 &&
          files.length <= MAX_PHOTOS_PER_BATCH,
        400,
        "files[] must contain 1..200 photos",
      );
      if (batch) {
        assert(
          body.kind !== "video",
          400,
          "Use one multipart ticket per video",
        );
      }
      const specs = files.map((file) =>
        uploadSpec(
          batch ? { ...file, listing_id: listing.id, kind: "photo" } : body,
          listing.id,
          listing.org_id,
          batch ? null : idempotencyKey(req),
        )
      );
      // Every asset and its budget reservation commit in one DB transaction.
      // A partial batch error cannot leave rows whose allowance was refunded.
      const assets = await reserveAssets(admin, user.id, specs);
      const tickets = [];
      for (const asset of assets) {
        tickets.push(await ticketResponse(admin, asset));
      }
      return batch
        ? json({ assets: tickets.map((t, index) => ({ ...t, index })) }, 201)
        : json(tickets[0], assets[0].replayed === true ? 200 : 201);
    }

    assert(seg.length === 2, 405, "Unsupported uploads path");
    const assetId = seg[0], asset = await requireAsset(db, assetId);
    await requireAssetWriteRole(db, admin, user.id, asset);
    const bucket = r2BucketFor(asset.bucket);
    if (seg[1] === "renew") {
      // Lookup by immutable asset id, not the POST /uploads idempotency index:
      // that index excludes completed rows, so completion racing a re-ticket
      // request could otherwise allocate and charge for a second reservation.
      if (asset.uploaded === true) return json(await ticketResponse(admin, asset));
      transportConfiguration();
      assert(asset.transport_version === 2, 409,
        "Legacy upload must be reticketed after rollout cleanup");
      return json(await recoveryTicket(admin, await uploadRPC(admin, "upload_restart_state", {
        p_asset: assetId, p_actor: user.id,
      })));
    }
    if (seg[1] === "restart") {
      const body = await readJson<Record<string, unknown>>(req);
      assert(body?.confirm_new_attempt === true && Object.keys(body).length === 1, 400,
        "Explicit confirm_new_attempt:true is required; upload specification cannot be changed");
      const restartKey = req.headers.get("Idempotency-Key") ?? "";
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(restartKey), 400,
        "A stable UUID Idempotency-Key is required for an explicit restart");
      assert(asset.transport_version === 2, 409,
        "Legacy upload must be reticketed after rollout cleanup");
      // Validate configuration before spending or retiring the old reservation.
      // SQL rechecks completion and ownership under the same publication lock;
      // an HTTP read made before a concurrent completion is not authority.
      transportConfiguration();
      return json(await recoveryTicket(admin, await uploadRPC(admin, "restart_upload_asset", {
        p_asset: assetId, p_actor: user.id, p_restart: restartKey,
      })));
    }
    if (seg[1] === "abort") {
      assert(
        asset.uploaded !== true,
        409,
        "This upload is already complete and cannot be aborted",
      );
      const cancelled = asset.transport_version === 2
        ? await settleReservation(admin, assetId, false)
        : row(
          await uploadRPC(admin, "cancel_legacy_upload", {
            p_asset: assetId,
            p_actor: user.id,
          }),
        );
      // Honest cancellation receipt. Storage cleanup is durable and asynchronous;
      // it is NOT reported as already deleted or refunded physical bytes.
      return json({
        ok: true,
        upload_aborted: cancelled.upload_aborted,
        cleanup_pending: true,
      });
    }
    if (seg[1] === "part-urls") {
      transportConfiguration();
      assert(
        asset.transport_version === 2 && asset.uploaded !== true &&
          asset.upload_aborted !== true,
        409,
        "This upload is no longer accepting parts",
      );
      assert(asset.upload_id, 409, "Multipart initialization is not confirmed");
      const body = await readJson<PartUrlsBody>(req), numbers = body.numbers;
      const count = Number(asset.parts_total);
      assert(
        Array.isArray(numbers) && numbers.length > 0 &&
          numbers.length <= MAX_PART_URLS_PER_CALL &&
          new Set(numbers).size === numbers.length && numbers.every((n) =>
            Number.isInteger(n) && n >= 1 && n <= count
          ),
        400,
        `numbers[] must be unique members of 1…${count}`,
      );
      return json({
        urls: await Promise.all(numbers.map(async (number) => ({
          number,
          url: await transferURL(admin, assetId, "part", number),
        }))),
      });
    }
    assert(seg[1] === "complete", 405, "Unsupported uploads path");
    if (asset.uploaded === true) return json(await reloadAsset(admin, assetId));
    assert(
      asset.transport_version === 2,
      409,
      "Legacy upload must be reticketed after rollout cleanup",
    );
    assert(
      asset.upload_aborted !== true,
      409,
      "This upload was aborted — create a new ticket",
    );
    const body = await readJson<CompleteBody>(req);
    const transfers = await confirmedTransfers(admin, assetId);
    const isMultipart = asset.parts_total != null;
    let completed: Record<string, unknown>;
    if (isMultipart) {
      const actual = canonicalParts(
        transfers.map((t) => ({ number: t.part, etag: t.etag })),
        Number(asset.parts_total),
      );
      const requested = canonicalParts(body.parts, Number(asset.parts_total));
      assert(
        sameParts(actual, requested),
        409,
        "Completion must match the server-confirmed part receipts",
      );
      const { data, error } = await pendingAsset(admin, asset, {
        completion_parts: actual,
      })
        .is("completion_parts", null).select().maybeSingle();
      if (error) {
        throw new HttpError(503, "Multipart manifest could not be confirmed");
      }
      const frozen = data ?? await reloadAsset(admin, assetId);
      if (frozen.uploaded === true) return json(frozen);
      assert(
        frozen.upload_aborted !== true &&
          sameParts(
            canonicalParts(frozen.completion_parts, Number(asset.parts_total)),
            actual,
          ),
        409,
        "Multipart manifest changed before assembly",
      );
      completed = await recordedOperation(
        admin,
        assetId,
        "assemble",
        async () => {
          await completeMultipartUpload({
            bucket,
            key: String(asset.storage_key),
            uploadId: String(asset.upload_id),
            parts: actual.map((p) => ({ partNumber: p.number, etag: p.etag })),
          });
          const head = await headObject(bucket, String(asset.storage_key));
          assert(
            head.exists && head.bytes === Number(asset.bytes) && head.etag &&
              ALLOWED_VIDEO_TYPES.includes(baseMediaType(head.contentType)) &&
              baseMediaType(head.contentType) === asset.content_type,
            502,
            "Assembly receipt could not be verified",
          );
          return { etag: head.etag };
        },
      );
    } else {
      const transfer = transfers[0],
        head = await headObject(bucket, String(transfer.object_key));
      const type = baseMediaType(head.contentType),
        declared = baseMediaType(asset.content_type);
      const maximum = asset.kind === "photo"
        ? (asset.bucket === "renders" &&
            !String(asset.storage_key).split("/").pop()?.startsWith("original-")
          ? MAX_POSTER_BYTES
          : MAX_PHOTO_BYTES)
        : MAX_VIDEO_BYTES;
      const kind = asset.kind === "photo" ? "photo" : "video";
      const publicPhoto = kind === "photo" && asset.bucket === "renders";
      const allowed = publicPhoto
        ? ALLOWED_POSTER_TYPES
        : kind === "photo"
        ? ALLOWED_PHOTO_TYPES
        : ALLOWED_VIDEO_TYPES;
      if (
        !head.exists || Number(asset.bytes) > maximum ||
        head.bytes !== Number(asset.bytes) || head.etag !== transfer.etag ||
        !allowed.includes(type) ||
        (asset.content_type_declared === true && declared !== type)
      ) {
        try {
          await settleReservation(admin, assetId, false);
        } catch (error) {
          const winner = await reloadAsset(admin, assetId);
          if (winner.uploaded === true) return json(winner);
          throw error;
        }
        throw new HttpError(
          400,
          "Stored upload does not match its confirmed size, ETag or content type",
        );
      }
      completed = await recordedOperation(
        admin,
        assetId,
        "copy",
        async (op) => {
          await copyObject(
            bucket,
            String(transfer.object_key),
            String(op.object_key),
            head.etag,
            type,
          );
          return { etag: String(head.etag), contentType: type };
        },
      );
    }
    return json(
      await settleReservation(admin, assetId, true, String(completed.id), {
        ...metadataPatch(body),
        content_type: String(completed.content_type ?? asset.content_type),
      }),
    );
  } catch (error) {
    return respondError(error);
  }
});

function idempotencyKey(req: Request): string | null {
  const key = req.headers.get("idempotency-key");
  if (key === null) return null;
  assert(
    key === key.trim() && key.length >= 8 && key.length <= 128,
    400,
    "Invalid Idempotency-Key",
  );
  return key;
}

function uploadSpec(
  body: CreateBody,
  listingId: string,
  orgId: string,
  idem: string | null,
) {
  const role = body.role ?? "capture";
  assert(
    ["capture", "render", "original", "gallery"].includes(role),
    400,
    "Invalid upload role",
  );
  const publicPhoto = role === "original" || role === "gallery" ||
    role === "render" && body.kind === "photo";
  const kind = publicPhoto || body.kind === "photo" ? "photo" : "video";
  const bucket = role === "capture" ? "uploads" : "renders";
  const declared = isContentTypeDeclared(body.content_type);
  const contentType = declared
    ? requireBareContentType(body.content_type as string, "content_type")
    : kind === "photo"
    ? "image/jpeg"
    : role === "capture"
    ? "video/quicktime"
    : "video/mp4";
  validateFileMeta(kind, body.bytes, contentType, "", {
    poster: publicPhoto && role !== "original",
    original: role === "original",
  });
  const id = crypto.randomUUID();
  const ext = publicPhoto
    ? POSTER_EXT[contentType]
    : role === "render"
    ? "mp4"
    : extFromFilename(body.filename, kind);
  const name = role === "original"
    ? `original-${id}`
    : role === "gallery"
    ? `gallery-${id}`
    : id;
  const multipart = kind === "video" &&
    (body.multipart === true || Number(body.bytes) > MULTIPART_THRESHOLD);
  const partSize = multipart ? choosePartSize(Number(body.bytes)) : null;
  return {
    id,
    listing_id: listingId,
    kind,
    bucket,
    storage_key: `${bucket}/${orgId}/${listingId}/${name}.${ext}`,
    bytes: body.bytes,
    content_type: contentType,
    content_type_declared: declared,
    sha256:
      typeof body.sha256 === "string" && /^[a-f0-9]{64}$/i.test(body.sha256)
        ? body.sha256.toLowerCase()
        : null,
    part_size: partSize,
    parts_total: partSize ? Math.ceil(Number(body.bytes) / partSize) : null,
    idem_key: idem,
  };
}

// deno-lint-ignore no-explicit-any
async function ticketResponse(admin: any, asset: Record<string, unknown>, recovery = false) {
  const base = {
    asset_id: asset.id,
    storage_key: asset.storage_key,
    content_type: asset.content_type,
    replayed: asset.replayed === true,
    transport_version: asset.transport_version,
    uploaded: asset.uploaded === true,
  };
  if (asset.uploaded === true) return {
    ...base, mode: asset.parts_total != null ? "multipart" : "single",
    upload_id: asset.upload_id, part_size: asset.part_size, part_count: asset.parts_total,
  };
  if (asset.parts_total != null) {
    const op = await recordedOperation(
      admin,
      String(asset.id),
      "init",
      async (planned) => {
        const uploadId = await createMultipartUpload({
          bucket: r2BucketFor(asset.bucket),
          key: String(planned.object_key),
          contentType: String(asset.content_type),
        });
        return { etag: "multipart-initialized", uploadId };
      },
    );
    let confirmedParts: Array<{number: number; etag: string}> | undefined;
    if (recovery) {
      const { data, error } = await admin.from("upload_operations")
        .select("part,etag").eq("asset_id", asset.id).eq("kind", "part").eq("state", "stored");
      if (error || !Array.isArray(data)) throw new HttpError(503, "Part receipts could not be recovered");
      confirmedParts = data.map((part: {part: number; etag: string}) => ({ number: part.part, etag: part.etag }));
    }
    return {
      ...base,
      mode: "multipart",
      upload_id: op.upload_id,
      part_size: asset.part_size,
      part_count: asset.parts_total,
      ...(confirmedParts ? { confirmed_parts: confirmedParts } : {}),
    };
  }
  return {
    ...base,
    mode: "single",
    put_url: await transferURL(admin, String(asset.id), "single"),
  };
}

// A durable failure/expiry receipt deliberately has no PUT capability. It lets
// the phone retain its file and ask consent without classifying any generic
// network error as permission to pay for another attempt. "Interrupted" is not
// a claim that the old provider write stopped: its spent bytes remain charged,
// its immutable key remains queued, and the replacement uses a different key.
// deno-lint-ignore no-explicit-any
async function recoveryTicket(admin: any, value: unknown) {
  const state = row(value), asset = row(state.asset);
  assert(typeof state.restart_required === "boolean" &&
    Number.isInteger(state.restart_generation) && Number(state.restart_generation) >= 0 &&
    Number(state.restart_generation) <= 3 &&
    (state.restart_required === true
      ? ["expired", "interrupted", "cancelled"].includes(String(state.restart_reason)) && asset.uploaded !== true
      : state.restart_reason == null) &&
    (state.retry_after_seconds == null ||
      (state.restart_required === false && asset.uploaded !== true && Number.isInteger(state.retry_after_seconds) &&
       Number(state.retry_after_seconds) >= 1 && Number(state.retry_after_seconds) <= 900)),
    503, "Invalid upload recovery receipt");
  const metadata = {
    restart_required: state.restart_required,
    restart_reason: state.restart_reason,
    restart_generation: state.restart_generation,
    ...(state.retry_after_seconds != null ? {retry_after_seconds: state.retry_after_seconds} : {}),
  };
  if (state.restart_required === true || state.retry_after_seconds != null) return {
    asset_id: asset.id, storage_key: asset.storage_key, content_type: asset.content_type,
    transport_version: asset.transport_version, uploaded: false, replayed: true,
    mode: asset.parts_total != null ? "multipart" : "single", upload_id: asset.upload_id,
    part_size: asset.part_size, part_count: asset.parts_total, ...metadata,
  };
  return { ...await ticketResponse(admin, asset, true), ...metadata };
}

// ── helpers ───────────────────────────────────────────────────────────────────
// Reads run on the USER client: RLS returns rows only for orgs the caller is a
// member of, so a passing read IS the membership check.

// deno-lint-ignore no-explicit-any
async function requireListing(db: any, listingId: string) {
  const { data, error } = await db
    .from("listings")
    .select("id, org_id")
    .eq("id", listingId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) {
    throw new HttpError(400, `Listing lookup failed: ${error.message}`);
  }
  if (!data) throw new HttpError(404, "Listing not found");
  return data as { id: string; org_id: string };
}

// deno-lint-ignore no-explicit-any
async function requireAsset(db: any, assetId: string) {
  const { data, error } = await db
    .from("capture_assets")
    .select(
      "id, listing_id, storage_key, upload_id, part_size, parts_total, kind, bucket, bytes, uploaded, content_type, content_type_declared, upload_aborted, completion_parts, transport_version",
    )
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  return data as Record<string, unknown>;
}
