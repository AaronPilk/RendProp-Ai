// uploads — create capture_assets + hand back R2 upload URLs (owner).
//
// Bytes never pass through Supabase; the app streams straight to R2.
//
// Audit P0-2 hardening (round 2 — the presigned-URL TOCTOU is now closed):
//   • aws4fetch's signQuery signs ONLY `host`, so a presigned PUT can bind
//     neither content-type nor content-length. Enforcement is therefore
//     server-side: single PUTs land on a STAGING key, /complete HEAD-verifies
//     it (exists, size == declared, content-type in the allowlist), then
//     server-side-COPIES it to the final key and deletes staging. The final key
//     never gets a PUT URL, so the still-valid staging URL can only overwrite an
//     orphan that is never served — no post-verification swap.
//   • Only owner/admin/agent may upload (marketing is read-only, audit P0-7).
//   • Ticket limits are charged PER FILE, plus a per-org daily BYTE budget.
//   • Multipart: part numbers bounded to 1…parts_total, completion requires the
//     exact unique part set; the object assembles at the final key under an
//     uploadId with no outstanding single-PUT URL, so it is verified in place.
//   • Membership is verified with the user client (RLS), then rows are written
//     with the service client — direct Data-API writes on capture_assets are
//     revoked in migration 0007, so this function is the only write path.
//   • Residual (manual gate): an R2 lifecycle rule on the `_staging/` prefix to
//     reap abandoned staged objects.
//
//   POST /uploads
//     { listing_id, filename, bytes, sha256?, kind, content_type?, multipart? }
//     video>64MB (or multipart:true) -> { asset_id, mode:"multipart", upload_id, storage_key, part_size, part_count }
//     otherwise                      -> { asset_id, mode:"single", put_url, storage_key }
//
//   POST /uploads/batch
//     { listing_id, kind:"photo", files:[{filename,bytes,sha256?,content_type?}] }
//     -> { assets:[{ index, asset_id, put_url, storage_key }] }
//
//   POST /uploads/:asset_id/part-urls   { numbers:[1,2,…] } -> { urls:[{ number, url }] }
//   POST /uploads/:asset_id/complete    multipart: { parts:[{number,etag}], … } | single: { … } -> asset
//   POST /uploads/:asset_id/abort       { } -> { ok:true }

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient, getUser, userClient } from "../_shared/supabase.ts";
import {
  abortMultipartUpload,
  choosePartSize,
  completeMultipartUpload,
  copyObject,
  createMultipartUpload,
  deleteObject,
  extFromFilename,
  headObject,
  presignPut,
  presignUploadPart,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
  R2_MAX_PARTS,
} from "../_shared/r2.ts";

/** Map a capture_assets.bucket tag → the actual R2 bucket name. */
function r2BucketFor(bucket: unknown): string {
  return bucket === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS;
}

// Single-PUT uploads land on a STAGING key first; /complete verifies the staged
// object and server-side-copies it to the final key, which never receives a
// presigned PUT URL. This is the real close of the audit's TOCTOU: aws4fetch's
// signQuery only signs `host`, so content-type/content-length can't be bound
// into a presigned URL — the object must be verified server-side AND made
// unreachable to the still-valid PUT URL afterward. Abandoned staging objects
// are reaped by an R2 lifecycle rule on the `_staging/` prefix (manual gate).
const stagingKey = (finalKey: string) => `_staging/${finalKey}`;

/** Marketing is read-only (audit P0-7): only owner/admin/agent may upload. */
// deno-lint-ignore no-explicit-any
async function requireWriteRole(admin: any, userId: string, orgId: string) {
  const { data, error } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (error) throw new HttpError(500, `Role lookup failed: ${error.message}`);
  const role = data?.role;
  if (!role || role === "marketing") {
    throw new HttpError(403, "Your role does not permit uploading media");
  }
}

// Video at/above this size (or an explicit multipart flag) uses multipart.
const MULTIPART_THRESHOLD = 64 * 1024 * 1024; // 64 MB
const MAX_PART_URLS_PER_CALL = 256;
const MAX_PHOTOS_PER_BATCH = 200;

// Hard size ceilings + a content-type allowlist so a caller can't presign an
// arbitrary-type or absurdly large object.
const MAX_VIDEO_BYTES = 12 * 1024 * 1024 * 1024; // 12 GB (a 4K / 9-min walkthrough is ~8 GB)
const MAX_PHOTO_BYTES = 50 * 1024 * 1024; // 50 MB
const ALLOWED_VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v"];
const ALLOWED_PHOTO_TYPES = ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"];

// Per-org daily budgets. Tickets are charged per FILE; bytes per MiB declared.
// A heavy team (20 listings/day × 70 photos + a few walkthroughs) stays well
// under both; an abusive account hits a wall.
const MAX_UPLOAD_TICKETS_PER_ORG_PER_DAY = 2000;
const MAX_UPLOAD_MB_PER_ORG_PER_DAY = 204_800; // 200 GB/day

const MB = 1024 * 1024;

/** Charge the org's daily ticket + byte budgets atomically-ish (two counters). */
async function chargeUploadBudget(orgId: string, fileCount: number, totalBytes: number) {
  const tickets = await durableRateLimit(
    `uploads:${orgId}`,
    MAX_UPLOAD_TICKETS_PER_ORG_PER_DAY,
    86400,
    fileCount,
  );
  if (!tickets) throw new HttpError(429, "Daily upload limit reached for this workspace");
  const mb = Math.max(1, Math.ceil(totalBytes / MB));
  const bytesOk = await durableRateLimit(
    `uploadmb:${orgId}`,
    MAX_UPLOAD_MB_PER_ORG_PER_DAY,
    86400,
    mb,
  );
  if (!bytesOk) throw new HttpError(429, "Daily upload data budget reached for this workspace");
}

/** Bound + validate one file's claimed size/type for its kind. */
function validateFileMeta(kind: "video" | "photo", bytes: number | null | undefined, contentType: string, label = "") {
  const maxBytes = kind === "photo" ? MAX_PHOTO_BYTES : MAX_VIDEO_BYTES;
  assert(bytes != null && Number.isFinite(bytes) && bytes > 0 && bytes <= maxBytes, 400,
    `bytes is required and must be between 1 and ${maxBytes} for a ${kind}${label}`);
  const allowed = kind === "photo" ? ALLOWED_PHOTO_TYPES : ALLOWED_VIDEO_TYPES;
  assert(allowed.includes(contentType), 400,
    `content_type "${contentType}" is not an allowed ${kind} type${label}`);
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
  if (typeof body.codec === "string" && body.codec.length <= 32) patch.codec = body.codec;
  if (typeof body.is_drone === "boolean") patch.is_drone = body.is_drone;
  if (typeof body.has_gyro === "boolean") patch.has_gyro = body.has_gyro;
  if (typeof body.sha256 === "string" && /^[a-f0-9]{64}$/i.test(body.sha256)) patch.sha256 = body.sha256.toLowerCase();
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
  /** "render" = the app's on-device rendered mp4 → public renders bucket.
   *  default "capture" = raw walkthrough/photo → private uploads bucket. */
  role?: "capture" | "render";
}

interface BatchBody {
  listing_id: string;
  kind?: "photo" | "video";
  files?: Array<{ filename?: string; bytes?: number; sha256?: string; content_type?: string }>;
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
    const user = await getUser(req); // auth required; membership enforced via RLS reads below
    const db = userClient(req); // READS (RLS-scoped) — proves membership
    const admin = adminClient(); // WRITES (0007 revokes the direct path)
    const seg = pathSegments(req, "uploads");

    // ---- POST /uploads/batch (photos) ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "batch") {
      const body = await readJson<BatchBody>(req);
      assert(body.listing_id, 400, "listing_id is required");
      const files = body.files ?? [];
      assert(files.length > 0, 400, "files[] is required");
      assert(files.length <= MAX_PHOTOS_PER_BATCH, 400, `at most ${MAX_PHOTOS_PER_BATCH} files per batch`);
      const kind: "video" | "photo" = body.kind === "video" ? "video" : "photo";

      const listing = await requireListing(db, body.listing_id);
      await requireWriteRole(admin, user.id, listing.org_id);

      // Validate every file BEFORE charging or creating anything.
      let totalBytes = 0;
      for (let i = 0; i < files.length; i++) {
        const f = files[i];
        const ct = f.content_type ?? (kind === "photo" ? "image/jpeg" : "video/mp4");
        validateFileMeta(kind, f.bytes, ct, ` (files[${i}])`);
        totalBytes += f.bytes ?? 0;
      }

      // Per-file + per-byte budget (audit P0-2: was one unit per batch).
      await chargeUploadBudget(listing.org_id, files.length, totalBytes);

      const assets = [];
      for (let i = 0; i < files.length; i++) {
        const f = files[i];
        const assetId = crypto.randomUUID();
        const ext = extFromFilename(f.filename, kind);
        const contentType = f.content_type ?? (kind === "photo" ? "image/jpeg" : "video/mp4");
        const storageKey = `uploads/${listing.org_id}/${listing.id}/${assetId}.${ext}`;
        const { error } = await admin.from("capture_assets").insert({
          id: assetId,
          listing_id: listing.id,
          kind,
          storage_key: storageKey,
          sha256: f.sha256 ?? null,
          bytes: f.bytes ?? null,
          content_type: contentType,
          uploaded: false,
        });
        if (error) throw new HttpError(400, `Asset create failed (#${i}): ${error.message}`);
        // PUT targets the STAGING key; /complete verifies then copies to the
        // final key. (contentType is passed for the app's own header, but note
        // it is NOT enforced by the signature — /complete's HEAD check is.)
        const putUrl = await presignPut({
          bucket: R2_BUCKET_UPLOADS,
          key: stagingKey(storageKey),
          expiresIn: 3600,
          contentType: kind === "photo" ? contentType : undefined,
        });
        assets.push({ index: i, asset_id: assetId, put_url: putUrl, storage_key: storageKey });
      }
      return json({ assets }, 201);
    }

    // ---- POST /uploads/:asset_id/part-urls ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "part-urls") {
      const assetId = seg[0];
      const body = await readJson<PartUrlsBody>(req);
      const asset = await requireAsset(db, assetId);
      assert(asset.upload_id, 409, "Asset is not a multipart upload");

      const partsTotal = Number(asset.parts_total ?? R2_MAX_PARTS);
      const numbers = (body.numbers ?? []).filter((n) =>
        Number.isInteger(n) && n >= 1 && n <= partsTotal
      );
      assert(numbers.length > 0, 400, `numbers[] is required (1…${partsTotal})`);
      assert(numbers.length <= MAX_PART_URLS_PER_CALL, 400, `at most ${MAX_PART_URLS_PER_CALL} part numbers per call`);

      const bucket = r2BucketFor(asset.bucket);
      const urls = [];
      for (const number of numbers) {
        const url = await presignUploadPart({
          bucket,
          key: asset.storage_key as string,
          uploadId: asset.upload_id as string,
          partNumber: number,
          expiresIn: 3600,
        });
        urls.push({ number, url });
      }
      return json({ urls });
    }

    // ---- POST /uploads/:asset_id/complete ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "complete") {
      const assetId = seg[0];
      const body = await readJson<CompleteBody>(req);
      const asset = await requireAsset(db, assetId);
      const bucket = r2BucketFor(asset.bucket);
      const key = asset.storage_key as string;
      const kind: "video" | "photo" = asset.kind === "photo" ? "photo" : "video";
      const claimedBytes = asset.bytes != null ? Number(asset.bytes) : null;
      const isMultipart = !!asset.upload_id;

      // Multipart assembles at the FINAL key under an uploadId that is now being
      // completed — there is no outstanding single-PUT URL to that key, so it is
      // verified in place. Single PUTs land on the STAGING key and are verified
      // there, then copied to the final key (which never had a PUT URL).
      const verifyKey = isMultipart ? key : stagingKey(key);

      if (isMultipart) {
        const partsTotal = Number(asset.parts_total ?? 0);
        assert(partsTotal >= 1, 409, "Asset has no recorded part count");
        const parts = (body.parts ?? []).filter((p) =>
          p && Number.isInteger(p.number) && p.number >= 1 && p.number <= partsTotal &&
          typeof p.etag === "string" && p.etag.length > 0 && p.etag.length <= 256
        );
        const nums = [...new Set(parts.map((p) => p.number))].sort((a, b) => a - b);
        assert(
          parts.length === partsTotal && nums.length === partsTotal &&
            nums[0] === 1 && nums[nums.length - 1] === partsTotal,
          400,
          `parts[] must contain each part 1…${partsTotal} exactly once`,
        );
        await completeMultipartUpload({
          bucket,
          key,
          uploadId: asset.upload_id as string,
          parts: parts.map((p) => ({ partNumber: p.number, etag: p.etag })),
        });
      }

      // Server-side verification: the object must exist and match what the
      // ticket declared. Client claims stop here (audit P0-2).
      const head = await headObject(bucket, verifyKey);
      if (!head.exists) {
        throw new HttpError(409, "No uploaded object found for this asset — upload the file, then complete");
      }
      const maxBytes = kind === "photo" ? MAX_PHOTO_BYTES : MAX_VIDEO_BYTES;
      const sizeOk = head.bytes != null && head.bytes > 0 && head.bytes <= maxBytes &&
        (claimedBytes == null || head.bytes === claimedBytes);
      const allowed = kind === "photo" ? ALLOWED_PHOTO_TYPES : ALLOWED_VIDEO_TYPES;
      const observedType = (head.contentType ?? "").split(";")[0].trim().toLowerCase();
      const typeOk = allowed.includes(observedType);
      if (!sizeOk || !typeOk) {
        // The staged/assembled object doesn't match its ticket — remove it so a
        // lying client can't park arbitrary content behind a validated row.
        await deleteObject(bucket, verifyKey).catch(() => {});
        await admin.from("capture_assets").update({ uploaded: false, upload_id: null }).eq("id", assetId);
        throw new HttpError(
          400,
          !sizeOk
            ? `Uploaded object size ${head.bytes ?? "?"} does not match the declared ${claimedBytes ?? "?"} bytes`
            : `Uploaded object content-type "${observedType}" is not an allowed ${kind} type`,
        );
      }

      // Single PUT: promote the verified staging object to the final key (which
      // has no presigned PUT URL) and delete staging. The still-valid staging
      // PUT URL can now only overwrite an orphan that is never served — the
      // TOCTOU the audit flagged is closed. Multipart is already at the final key.
      if (!isMultipart) {
        await copyObject(bucket, verifyKey, key);
        await deleteObject(bucket, verifyKey).catch(() => {});
      }

      const patch: Record<string, unknown> = {
        ...metadataPatch(body),
        uploaded: true,
        upload_id: null,
        bytes: head.bytes, // server-observed truth
        content_type: observedType,
      };
      const { data, error } = await admin
        .from("capture_assets")
        .update(patch)
        .eq("id", assetId)
        .select()
        .maybeSingle();
      if (error) throw new HttpError(400, `Complete failed: ${error.message}`);
      if (!data) throw new HttpError(404, "Asset not found");
      return json(data);
    }

    // ---- POST /uploads/:asset_id/abort ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "abort") {
      const assetId = seg[0];
      const asset = await requireAsset(db, assetId);
      if (asset.upload_id) {
        await abortMultipartUpload({
          bucket: r2BucketFor(asset.bucket),
          key: asset.storage_key as string,
          uploadId: asset.upload_id as string,
        });
      } else {
        // Single PUT: drop any staged bytes so an aborted upload leaves nothing.
        await deleteObject(r2BucketFor(asset.bucket), stagingKey(asset.storage_key as string)).catch(() => {});
      }
      await admin.from("capture_assets").update({ upload_id: null, uploaded: false }).eq("id", assetId);
      return json({ ok: true });
    }

    // ---- POST /uploads (single or multipart init) ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<CreateBody>(req);
      assert(body.listing_id, 400, "listing_id is required");
      const role: "capture" | "render" = body.role === "render" ? "render" : "capture";
      const kind: "video" | "photo" =
        role === "render" ? "video" : (body.kind === "photo" ? "photo" : "video");
      const bucketTag = role === "render" ? "renders" : "uploads";
      const r2Bucket = r2BucketFor(bucketTag);

      const listing = await requireListing(db, body.listing_id);
      await requireWriteRole(admin, user.id, listing.org_id);

      const assetId = crypto.randomUUID();
      const ext = role === "render" ? "mp4" : extFromFilename(body.filename, kind);
      const storageKey = `${bucketTag}/${listing.org_id}/${listing.id}/${assetId}.${ext}`;
      const contentType = body.content_type ??
        (role === "render" ? "video/mp4" : (kind === "photo" ? "image/jpeg" : "video/quicktime"));

      // Bound the size and require a known media type BEFORE charging.
      validateFileMeta(kind, body.bytes, contentType);
      await chargeUploadBudget(listing.org_id, 1, body.bytes ?? 0);

      const useMultipart =
        kind === "video" && (body.multipart === true || (body.bytes ?? 0) > MULTIPART_THRESHOLD);

      if (useMultipart) {
        assert(body.bytes && body.bytes > 0, 400, "bytes is required for a multipart upload");
        const partSize = choosePartSize(body.bytes!);
        const partCount = Math.ceil(body.bytes! / partSize);
        const uploadId = await createMultipartUpload({ bucket: r2Bucket, key: storageKey, contentType });

        const { data: asset, error } = await admin
          .from("capture_assets")
          .insert({
            id: assetId,
            listing_id: listing.id,
            kind,
            bucket: bucketTag,
            storage_key: storageKey,
            sha256: body.sha256 ?? null,
            bytes: body.bytes ?? null,
            content_type: contentType,
            upload_id: uploadId,
            part_size: partSize,
            parts_total: partCount,
            uploaded: false,
          })
          .select()
          .single();
        if (error) {
          await abortMultipartUpload({ bucket: r2Bucket, key: storageKey, uploadId }).catch(() => {});
          throw new HttpError(400, `Asset create failed: ${error.message}`);
        }
        return json({
          asset_id: asset.id,
          mode: "multipart",
          upload_id: uploadId,
          storage_key: storageKey,
          part_size: partSize,
          part_count: partCount,
        }, 201);
      }

      // Single PUT (photos + small video/render).
      const { data: asset, error } = await admin
        .from("capture_assets")
        .insert({
          id: assetId,
          listing_id: listing.id,
          kind,
          bucket: bucketTag,
          storage_key: storageKey,
          sha256: body.sha256 ?? null,
          bytes: body.bytes ?? null,
          content_type: contentType,
          uploaded: false,
        })
        .select()
        .single();
      if (error) throw new HttpError(400, `Asset create failed: ${error.message}`);

      // PUT targets the STAGING key; /complete verifies then copies to the
      // final key (which never gets a PUT URL — closes the TOCTOU).
      const putUrl = await presignPut({
        bucket: r2Bucket,
        key: stagingKey(storageKey),
        expiresIn: 3600,
        contentType: kind === "photo" ? contentType : undefined,
      });
      return json({ asset_id: asset.id, mode: "single", put_url: putUrl, storage_key: storageKey }, 201);
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});

// ── helpers ───────────────────────────────────────────────────────────────────
// Reads run on the USER client: RLS returns rows only for orgs the caller is a
// member of, so a passing read IS the membership check.

// deno-lint-ignore no-explicit-any
async function requireListing(db: any, listingId: string) {
  const { data, error } = await db
    .from("listings")
    .select("id, org_id")
    .eq("id", listingId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Listing lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Listing not found");
  return data as { id: string; org_id: string };
}

// deno-lint-ignore no-explicit-any
async function requireAsset(db: any, assetId: string) {
  const { data, error } = await db
    .from("capture_assets")
    .select("id, listing_id, storage_key, upload_id, part_size, parts_total, kind, bucket, bytes")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  return data as Record<string, unknown>;
}
