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
