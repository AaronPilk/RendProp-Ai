// Cloudflare R2 (S3-compatible) helpers.
//
// We presign PUT URLs so the iOS DirectUploader streams video straight to R2 —
// bytes never touch Supabase (its egress is the one cost trap; see AI-COST-MODEL).
// Signing uses aws4fetch (SigV4, region "auto"). We deliberately do NOT sign the
// Content-Type header, so the uploader can PUT with whatever type it likes.

import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";
import { HttpError } from "./http.ts";

const ACCOUNT_ID = Deno.env.get("CLOUDFLARE_ACCOUNT_ID");
const ACCESS_KEY_ID = Deno.env.get("R2_ACCESS_KEY_ID");
const SECRET_ACCESS_KEY = Deno.env.get("R2_SECRET_ACCESS_KEY");

export const R2_BUCKET_UPLOADS = Deno.env.get("R2_BUCKET_UPLOADS") ?? "rendprop-uploads";
export const R2_BUCKET_RENDERS = Deno.env.get("R2_BUCKET_RENDERS") ?? "rendprop-renders";
export const R2_BUCKET_PUBLIC = Deno.env.get("R2_BUCKET_PUBLIC") ?? "rendprop-public";

// Optional public base (a custom domain or r2.dev subdomain mapped to the
// renders/public bucket). When unset, publicR2Url returns null rather than a
// non-public S3 endpoint URL.
const R2_PUBLIC_BASE_URL = Deno.env.get("R2_PUBLIC_BASE_URL")?.replace(/\/+$/, "");

// Cloudflare Stream customer subdomain code, e.g. "abcd1234" in
// https://customer-abcd1234.cloudflarestream.com/<uid>/manifest/video.m3u8
const STREAM_CUSTOMER_CODE = Deno.env.get("CLOUDFLARE_STREAM_CUSTOMER_CODE");

function endpoint(): string {
  if (!ACCOUNT_ID) throw new HttpError(500, "Missing env var: CLOUDFLARE_ACCOUNT_ID");
  return `https://${ACCOUNT_ID}.r2.cloudflarestorage.com`;
}

let _client: AwsClient | null = null;
function client(): AwsClient {
  if (_client) return _client;
  if (!ACCESS_KEY_ID || !SECRET_ACCESS_KEY) {
    throw new HttpError(500, "Missing R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY");
  }
  _client = new AwsClient({
    accessKeyId: ACCESS_KEY_ID,
    secretAccessKey: SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  return _client;
}

/** Encode each path segment but keep the "/" separators (safe for S3 SigV4). */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

export interface PresignArgs {
  bucket: string;
  key: string;
  /** URL lifetime in seconds (default 15 min). */
  expiresIn?: number;
  /** If set, binds the upload to this exact Content-Type. */
  contentType?: string;
}

/** Presign an R2 PUT URL for a direct browser/app upload. */
export async function presignPut(args: PresignArgs): Promise<string> {
  const { bucket, key, expiresIn = 900, contentType } = args;
  const url = new URL(`${endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));

  const signed = await client().sign(url.toString(), {
    method: "PUT",
    aws: { signQuery: true },
    headers: contentType ? { "content-type": contentType } : undefined,
  });
  return signed.url;
}

/** Public HTTPS URL for an R2 object, or null if no public base is configured. */
export function publicR2Url(key: string | null | undefined): string | null {
  if (!key || !R2_PUBLIC_BASE_URL) return null;
  return `${R2_PUBLIC_BASE_URL}/${encodeKey(key)}`;
}

/** Cloudflare Stream HLS manifest URL for a Stream UID, or null if not configured. */
export function streamHlsUrl(streamUid: string | null | undefined): string | null {
  if (!streamUid || !STREAM_CUSTOMER_CODE) return null;
  return `https://customer-${STREAM_CUSTOMER_CODE}.cloudflarestream.com/${streamUid}/manifest/video.m3u8`;
}

/** Derive a safe file extension from an upload filename. */
export function extFromFilename(filename: string | undefined, kind: "video" | "photo"): string {
  const m = /\.([A-Za-z0-9]{1,8})$/.exec(filename ?? "");
  const ext = m ? m[1].toLowerCase() : "";
  if (ext) return ext;
  return kind === "photo" ? "jpg" : "mov";
}

// ─────────────────────────────────────────────────────────────────────────────
// Multipart upload (S3/R2) — resumable, multi-GB safe.
//
// A single presigned PUT cannot resume after a dropped connection and R2 caps
// single-object PUTs at 5 GB. Large video (a 9-minute 4K walkthrough is 2–8 GB)
// therefore uses S3 multipart: CreateMultipartUpload → UploadPart ×N → Complete
// (or Abort). Create / Complete / Abort are signed server-side here; each
// UploadPart URL is PRESIGNED so the iOS background URLSession streams chunks
// straight to R2. Parts (except the last) must be uniform and ≥ 5 MiB.
// ─────────────────────────────────────────────────────────────────────────────

/** R2/S3 multipart minimums/maximums (S3 spec). */
export const R2_MIN_PART_BYTES = 5 * 1024 * 1024;      // 5 MiB floor (except last part)
export const R2_MAX_PARTS = 10_000;

function firstTag(xml: string, tag: string): string | null {
  const m = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(xml);
  return m ? m[1] : null;
}

/** ETags are returned quoted (e.g. "\"abc\""). Complete requires the quotes. */
function normalizeEtag(etag: string): string {
  const t = etag.trim();
  return t.startsWith('"') && t.endsWith('"') ? t : `"${t.replace(/^"|"$/g, "")}"`;
}

function escapeXml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** Begin a multipart upload; returns the R2 UploadId. */
export async function createMultipartUpload(
  args: { bucket: string; key: string; contentType?: string },
): Promise<string> {
  const { bucket, key, contentType } = args;
  const url = `${endpoint()}/${bucket}/${encodeKey(key)}?uploads`;
  const res = await client().fetch(url, {
    method: "POST",
    headers: contentType ? { "content-type": contentType } : undefined,
  });
  const text = await res.text();
  if (!res.ok) {
    throw new HttpError(502, `R2 CreateMultipartUpload failed (${res.status}): ${text.slice(0, 300)}`);
  }
  const uploadId = firstTag(text, "UploadId");
  if (!uploadId) throw new HttpError(502, "R2 CreateMultipartUpload: no UploadId in response");
  return uploadId;
}

/** Presign a single UploadPart URL (app PUTs the chunk, reads the ETag header). */
export async function presignUploadPart(
  args: { bucket: string; key: string; uploadId: string; partNumber: number; expiresIn?: number },
): Promise<string> {
  const { bucket, key, uploadId, partNumber, expiresIn = 3600 } = args;
  const url = new URL(`${endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("partNumber", String(partNumber));
  url.searchParams.set("uploadId", uploadId);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signed = await client().sign(url.toString(), { method: "PUT", aws: { signQuery: true } });
  return signed.url;
}

export interface CompletedPart {
  partNumber: number;
  etag: string;
}

/** Finalize a multipart upload from the collected part ETags. */
export async function completeMultipartUpload(
  args: { bucket: string; key: string; uploadId: string; parts: CompletedPart[] },
): Promise<void> {
  const { bucket, key, uploadId, parts } = args;
  if (parts.length === 0) throw new HttpError(400, "completeMultipartUpload: no parts");
  const sorted = [...parts].sort((a, b) => a.partNumber - b.partNumber);
  const body = `<CompleteMultipartUpload>${
    sorted
      .map((p) =>
        `<Part><PartNumber>${p.partNumber}</PartNumber><ETag>${escapeXml(normalizeEtag(p.etag))}</ETag></Part>`
      )
      .join("")
  }</CompleteMultipartUpload>`;

  const url = new URL(`${endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("uploadId", uploadId);
  const res = await client().fetch(url.toString(), {
    method: "POST",
    body,
    headers: { "content-type": "application/xml" },
  });
  const text = await res.text();
  if (!res.ok) {
    throw new HttpError(502, `R2 CompleteMultipartUpload failed (${res.status}): ${text.slice(0, 300)}`);
  }
  // S3/R2 can return 200 with an <Error> body when completion actually failed.
  if (/<Error>/.test(text)) {
    throw new HttpError(502, `R2 CompleteMultipartUpload error: ${text.slice(0, 300)}`);
  }
}

/** Abort a multipart upload (cleanup); 404 is treated as already-gone. */
export async function abortMultipartUpload(
  args: { bucket: string; key: string; uploadId: string },
): Promise<void> {
  const { bucket, key, uploadId } = args;
  const url = new URL(`${endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("uploadId", uploadId);
  const res = await client().fetch(url.toString(), { method: "DELETE" });
  if (!res.ok && res.status !== 404) {
    const text = await res.text();
    throw new HttpError(502, `R2 AbortMultipartUpload failed (${res.status}): ${text.slice(0, 200)}`);
  }
}

/**
 * Pick a uniform part size that keeps part_count within S3 limits.
 * Starts at 32 MiB and doubles until ceil(bytes/size) ≤ 8000 (headroom under 10k).
 */
export function choosePartSize(bytes: number): number {
  const BASE = 32 * 1024 * 1024;
  let size = BASE;
  while (Math.ceil(bytes / size) > 8000) size *= 2;
  return Math.max(size, R2_MIN_PART_BYTES);
}
