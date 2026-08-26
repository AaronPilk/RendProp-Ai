// uploads — create capture_assets + hand back R2 upload URLs (owner).
//
// Bytes never pass through Supabase; the app streams straight to R2.
//
// Large video (a 9-min 4K walkthrough is 2–8 GB) uses RESUMABLE MULTIPART — a
// single PUT can't resume a dropped connection and R2 caps single PUTs at 5 GB.
// Photos (a listing can carry 70+) use a batched single-PUT path.
//
//   POST /uploads
//     { listing_id, filename, bytes, sha256?, kind, content_type?, multipart? }
//     video>64MB (or multipart:true) -> { asset_id, mode:"multipart", upload_id, storage_key, part_size, part_count }
//     otherwise                      -> { asset_id, mode:"single", put_url, storage_key }
//
//   POST /uploads/batch
//     { listing_id, kind:"photo", files:[{filename,bytes?,sha256?,content_type?}] }
//     -> { assets:[{ index, asset_id, put_url, storage_key }] }
//
//   POST /uploads/:asset_id/part-urls
//     { numbers:[1,2,…] }            -> { urls:[{ number, url }] }   (presigned, 1h)
//
//   POST /uploads/:asset_id/complete
//     multipart: { parts:[{number,etag}], duration_s?, fps?, width?, height?, codec?, is_drone?, has_gyro?, sha256?, bytes? }
//     single:    { duration_s?, … , sha256?, bytes? }
//     -> asset
//
//   POST /uploads/:asset_id/abort   { } -> { ok:true }   (abort an in-flight multipart)

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { getUser, userClient } from "../_shared/supabase.ts";
import {
  abortMultipartUpload,
  choosePartSize,
  completeMultipartUpload,
  createMultipartUpload,
  extFromFilename,
  presignPut,
  presignUploadPart,
  R2_BUCKET_RENDERS,
  R2_BUCKET_UPLOADS,
} from "../_shared/r2.ts";

/** Map a capture_assets.bucket tag → the actual R2 bucket name. */
function r2BucketFor(bucket: unknown): string {
  return bucket === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS;
}

// Video at/above this size (or an explicit multipart flag) uses multipart.
const MULTIPART_THRESHOLD = 64 * 1024 * 1024; // 64 MB
const MAX_PART_URLS_PER_CALL = 256;
const MAX_PHOTOS_PER_BATCH = 200;

// #16 restrict uploads: hard size ceilings + a content-type allowlist so a
// caller can't presign an arbitrary-type or absurdly large object.
const MAX_VIDEO_BYTES = 12 * 1024 * 1024 * 1024; // 12 GB (a 4K / 9-min walkthrough is ~8 GB)
const MAX_PHOTO_BYTES = 50 * 1024 * 1024;        // 50 MB
const ALLOWED_VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/x-m4v"];
const ALLOWED_PHOTO_TYPES = ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"];

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

const METADATA_KEYS = [
  "duration_s", "fps", "width", "height", "codec", "is_drone", "has_gyro", "sha256", "bytes",
] as const;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    await getUser(req); // auth required; row access enforced by RLS on the user client
    const db = userClient(req);
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

      const assets = [];
      for (let i = 0; i < files.length; i++) {
        const f = files[i];
        const assetId = crypto.randomUUID();
        const ext = extFromFilename(f.filename, kind);
        const storageKey = `uploads/${listing.org_id}/${listing.id}/${assetId}.${ext}`;
        const { error } = await db.from("capture_assets").insert({
          id: assetId,
          listing_id: listing.id,
          kind,
          storage_key: storageKey,
          sha256: f.sha256 ?? null,
          bytes: f.bytes ?? null,
          content_type: f.content_type ?? null,
          uploaded: false,
        });
        if (error) throw new HttpError(400, `Asset create failed (#${i}): ${error.message}`);
        const putUrl = await presignPut({ bucket: R2_BUCKET_UPLOADS, key: storageKey, expiresIn: 3600 });
        assets.push({ index: i, asset_id: assetId, put_url: putUrl, storage_key: storageKey });
      }
      return json({ assets }, 201);
    }

    // ---- POST /uploads/:asset_id/part-urls ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "part-urls") {
      const assetId = seg[0];
      const body = await readJson<PartUrlsBody>(req);
      const numbers = (body.numbers ?? []).filter((n) => Number.isInteger(n) && n >= 1);
      assert(numbers.length > 0, 400, "numbers[] is required");
      assert(numbers.length <= MAX_PART_URLS_PER_CALL, 400, `at most ${MAX_PART_URLS_PER_CALL} part numbers per call`);

      const asset = await requireAsset(db, assetId);
      assert(asset.upload_id, 409, "Asset is not a multipart upload");

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

      // Multipart finalize (if this asset was started as multipart).
      if (asset.upload_id) {
        const parts = (body.parts ?? []).filter((p) => p && Number.isInteger(p.number) && p.etag);
        assert(parts.length > 0, 400, "parts[] with {number, etag} is required to complete a multipart upload");
        await completeMultipartUpload({
          bucket: r2BucketFor(asset.bucket),
          key: asset.storage_key as string,
          uploadId: asset.upload_id as string,
          parts: parts.map((p) => ({ partNumber: p.number, etag: p.etag })),
        });
      }

      const patch: Record<string, unknown> = { uploaded: true, upload_id: null };
      for (const k of METADATA_KEYS) {
        if (body[k] !== undefined) patch[k] = body[k];
      }
      const { data, error } = await db
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
      }
      await db.from("capture_assets").update({ upload_id: null, uploaded: false }).eq("id", assetId);
      return json({ ok: true });
    }

    // ---- POST /uploads (single or multipart init) ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<CreateBody>(req);
      assert(body.listing_id, 400, "listing_id is required");
      const role: "capture" | "render" = body.role === "render" ? "render" : "capture";
      // The app's on-device rendered tour is an mp4 destined for the PUBLIC renders
      // bucket; raw capture (video/photo) goes to the private uploads bucket.
      const kind: "video" | "photo" =
        role === "render" ? "video" : (body.kind === "photo" ? "photo" : "video");
      const bucketTag = role === "render" ? "renders" : "uploads";
      const r2Bucket = r2BucketFor(bucketTag);

      const listing = await requireListing(db, body.listing_id);

      const assetId = crypto.randomUUID();
      const ext = role === "render" ? "mp4" : extFromFilename(body.filename, kind);
      const storageKey = `${bucketTag}/${listing.org_id}/${listing.id}/${assetId}.${ext}`;
      const contentType = body.content_type ??
        (role === "render" ? "video/mp4" : (kind === "photo" ? "image/jpeg" : "video/quicktime"));

      // #16 restrict uploads: bound the size and require a known media type.
      const maxBytes = kind === "photo" ? MAX_PHOTO_BYTES : MAX_VIDEO_BYTES;
      if (body.bytes != null) {
        assert(body.bytes > 0 && body.bytes <= maxBytes, 400,
          `bytes must be between 1 and ${maxBytes} for a ${kind}`);
      }
      const allowedTypes = kind === "photo" ? ALLOWED_PHOTO_TYPES : ALLOWED_VIDEO_TYPES;
      assert(allowedTypes.includes(contentType), 400,
        `content_type "${contentType}" is not an allowed ${kind} type`);

      // Decide single vs multipart. Photos are always single; video goes multipart
      // when explicitly requested or when it's large enough that resumability matters.
      const useMultipart =
        kind === "video" && (body.multipart === true || (body.bytes ?? 0) > MULTIPART_THRESHOLD);

      if (useMultipart) {
        assert(body.bytes && body.bytes > 0, 400, "bytes is required for a multipart upload");
        const partSize = choosePartSize(body.bytes!);
        const partCount = Math.ceil(body.bytes! / partSize);
        const uploadId = await createMultipartUpload({ bucket: r2Bucket, key: storageKey, contentType });

        const { data: asset, error } = await db
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
          // Roll back the R2 session so we don't leak an orphaned multipart upload.
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
      const { data: asset, error } = await db
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

      const putUrl = await presignPut({ bucket: r2Bucket, key: storageKey, expiresIn: 3600 });
      return json({ asset_id: asset.id, mode: "single", put_url: putUrl, storage_key: storageKey }, 201);
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});

// ── helpers ───────────────────────────────────────────────────────────────────

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
    .select("id, listing_id, storage_key, upload_id, part_size, parts_total, kind, bucket")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  return data as Record<string, unknown>;
}
