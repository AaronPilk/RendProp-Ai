// Cloudflare R2 (S3-compatible) helpers.
//
// We presign PUT URLs so the iOS DirectUploader streams video straight to R2 —
// bytes never touch Supabase (its egress is the one cost trap; see AI-COST-MODEL).
// Signing uses aws4fetch (SigV4, region "auto"). We deliberately do NOT sign the
// Content-Type header, so the uploader can PUT with whatever type it likes.

import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";
import { HttpError } from "./http.ts";

// TRIM every credential. A single trailing newline in the R2 access key (from a
// `echo`-piped `supabase secrets set`) took the ENTIRE storage layer down in
// production on 2026-09-04: the key became 33 bytes, presigned PUTs reached R2
// and were rejected with `Credential access key has length 33, should be 32`,
// and every header-signed call (head/copy/delete/multipart) threw
// "Invalid header value" inside Deno before it left the function. Nothing could
// upload, so nothing could publish. One character of invisible whitespace must
// never be able to do that again.
const trimmedEnv = (name: string): string | undefined => {
  const raw = Deno.env.get(name);
  if (raw === undefined) return undefined;
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
};

const ACCOUNT_ID = trimmedEnv("CLOUDFLARE_ACCOUNT_ID");
const ACCESS_KEY_ID = trimmedEnv("R2_ACCESS_KEY_ID");
const SECRET_ACCESS_KEY = trimmedEnv("R2_SECRET_ACCESS_KEY");

export const R2_BUCKET_UPLOADS = trimmedEnv("R2_BUCKET_UPLOADS") ?? "rendprop-uploads";
export const R2_BUCKET_RENDERS = trimmedEnv("R2_BUCKET_RENDERS") ?? "rendprop-renders";
export const R2_BUCKET_PUBLIC = trimmedEnv("R2_BUCKET_PUBLIC") ?? "rendprop-public";

// Optional public base (a custom domain or r2.dev subdomain mapped to the
// renders/public bucket). When unset, publicR2Url returns null rather than a
// non-public S3 endpoint URL.
const R2_PUBLIC_BASE_URL = trimmedEnv("R2_PUBLIC_BASE_URL")?.replace(/\/+$/, "");

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

/** One journal claim means ONE dispatch. AwsClient.fetch retries some statuses;
 * sign + native fetch deliberately does not. A timeout is an uncertain write,
 * not permission to dispatch or charge again. Only uploads uses these helpers. */
async function uploadDispatch(url: string, init: Parameters<AwsClient["sign"]>[1], timeout=120_000): Promise<Response> {
  const request = await client().sign(url, init);
  return await fetch(request, { signal: AbortSignal.timeout(timeout), redirect: "error" });
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
  /** Advisory only. aws4fetch's signQuery signs just `host`, so this does NOT
   *  bind the upload to a Content-Type — the uploads function verifies the
   *  observed type server-side at /complete instead (audit F-supabase-31). */
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
  const res = await uploadDispatch(url, {
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
  const res = await uploadDispatch(url.toString(), {
    method: "POST",
    body,
    headers: { "content-type": "application/xml" },
  });
  const text = await res.text();
  // The session is gone: R2 already assembled it on an earlier attempt (or it
  // was aborted). Surfaced distinctly so /complete can HEAD the final object
  // and treat an already-assembled upload as done instead of 502-ing forever
  // (audit F-supabase-18).
  if (/NoSuchUpload/.test(text)) {
    throw new HttpError(409, "The multipart session no longer exists", "conflict", { r2_code: "NoSuchUpload" });
  }
  if (!res.ok) {
    throw new HttpError(502, `R2 CompleteMultipartUpload failed (${res.status}): ${text.slice(0, 300)}`);
  }
  // S3/R2 can return 200 with an <Error> body when completion actually failed.
  if (/<Error>/.test(text)) {
    throw new HttpError(502, `R2 CompleteMultipartUpload error: ${text.slice(0, 300)}`);
  }
}

/** True when an error is the "multipart session no longer exists" signal above. */
export function isNoSuchUpload(err: unknown): boolean {
  return err instanceof HttpError && err.details?.r2_code === "NoSuchUpload";
}

function xmlValue(value: string): string {
  return value.replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&lt;/g,"<")
    .replace(/&gt;/g,">").replace(/&amp;/g,"&");
}
async function boundedXML(url: URL,timeout=120_000): Promise<string | null> {
  const response=await uploadDispatch(url.toString(),{method:"GET"},timeout);
  if(response.status===404){await response.body?.cancel();return null;}
  if(!response.ok){await response.body?.cancel();throw new HttpError(503,"Recorded upload inventory unavailable");}
  if(!response.body)throw new HttpError(503,"Recorded upload inventory is empty");
  const reader=response.body.getReader(),decoder=new TextDecoder();let count=0,text="";
  try{while(true){const r=await reader.read();if(r.done)break;count+=r.value.byteLength;
    if(count>131072)throw new HttpError(503,"Recorded upload inventory exceeds bound");
    text+=decoder.decode(r.value,{stream:true});}return text+decoder.decode();}
  finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
}

/** Read-only lost-receipt recovery. These exact keys/sessions were registered
 * BEFORE their one dispatch. Never enumerate arbitrary prefixes or re-upload. */
export async function recoverMultipartPart(args:{bucket:string;key:string;uploadId:string;part:number;bytes:number}):Promise<string|null>{
  const url=new URL(`${endpoint()}/${args.bucket}/${encodeKey(args.key)}`);
  url.searchParams.set("uploadId",args.uploadId);url.searchParams.set("part-number-marker",String(args.part-1));
  url.searchParams.set("max-parts","1");
  const text=await boundedXML(url);if(text===null)return null;
  const parts=[...text.matchAll(/<Part>([\s\S]*?)<\/Part>/g)];
  if(parts.length===0)return null;
  if(parts.length!==1)throw new HttpError(503,"Ambiguous recorded part inventory");
  const part=parts[0][1],number=Number(firstTag(part,"PartNumber")),size=Number(firstTag(part,"Size"));
  if(number!==args.part)return null;
  const etag=firstTag(part,"ETag");
  if(size!==args.bytes || !etag || etag.length>256)throw new HttpError(503,"Recorded part does not match its byte authority");
  return normalizeEtag(xmlValue(etag));
}
export async function recoverMultipartInitialization(bucket:string,key:string,timeout=120_000):Promise<string|null>{
  const url=new URL(`${endpoint()}/${bucket}`);
  url.searchParams.set("uploads","");url.searchParams.set("prefix",key);url.searchParams.set("max-uploads","2");
  const text=await boundedXML(url,timeout);if(text===null)return null;
  const sessions=[...text.matchAll(/<Upload>([\s\S]*?)<\/Upload>/g)]
    .filter(m=>xmlValue(firstTag(m[1],"Key")??"")===key);
  if(sessions.length===0)return null;
  if(sessions.length!==1 || firstTag(text,"IsTruncated")==="true")throw new HttpError(503,"Ambiguous recorded multipart initialization");
  const id=firstTag(sessions[0][1],"UploadId");
  if(!id || id.length>2048)throw new HttpError(503,"Recorded multipart ID is invalid");
  return xmlValue(id);
}

/** Cleanup only an already claimed journal entry; no caller-shaped keys.
 * Each HTTP dispatch is bounded, non-retrying and acknowledged before marking
 * it deleted. Failure remains in the durable queue. */
export async function deleteRecordedUpload(op:Record<string,unknown>):Promise<boolean>{
  if(!["uploads","renders"].includes(String(op.bucket))||!["single","copy","init","part","assemble"].includes(String(op.kind))||
    typeof op.object_key!=="string"||op.object_key.length>1024||op.object_key.includes("..")||
    !(op.object_key.startsWith(`${op.bucket}/`)||op.object_key.startsWith(`_staging/${op.bucket}/`)))
    throw new HttpError(503,"Invalid journaled cleanup identity");
  if(op.claim==null)return true; // No external write was ever authorized.
  const bucket=op.bucket==="renders"?R2_BUCKET_RENDERS:R2_BUCKET_UPLOADS,key=String(op.object_key);
  let uploadId=typeof op.upload_id==="string"?op.upload_id:null;
  if(op.kind==="init" && !uploadId){
    uploadId=await recoverMultipartInitialization(bucket,key,10_000);
    if(!uploadId)return false; // Unknown session remains an explicit unresolved record.
  }
  if(["init","part","assemble"].includes(String(op.kind)) && uploadId){
    const abort=new URL(`${endpoint()}/${bucket}/${encodeKey(key)}`);abort.searchParams.set("uploadId",uploadId);
    const response=await uploadDispatch(abort.toString(),{method:"DELETE"},10_000);
    await response.body?.cancel();if(!response.ok && response.status!==404)return false;
  }
  const response=await uploadDispatch(`${endpoint()}/${bucket}/${encodeKey(key)}`,{method:"DELETE"},10_000);
  await response.body?.cancel();return response.ok || response.status===404;
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

// ─────────────────────────────────────────────────────────────────────────────
// Object deletion — used by DELETE /me so "delete your account" actually
// removes the media, not just the rows (the privacy policy promises this).
// Signed server-side requests (aws4fetch header signing); a 404 counts as
// deleted so retries stay idempotent.

export interface R2Object {
  bucket: string;
  key: string;
}

/** Server-observed truth about an uploaded object (audit P0-2: completion must
 * verify the object actually exists and match its real size/type, not trust
 * client-claimed metadata). */
export interface HeadResult {
  exists: boolean;
  bytes: number | null;
  contentType: string | null;
  etag: string | null;
}

/** HEAD one object — signed server-side. 404 → { exists: false }. */
export async function headObject(bucket: string, key: string): Promise<HeadResult> {
  const url = `${endpoint()}/${bucket}/${encodeKey(key)}`;
  const resp = await client().fetch(url, { method: "HEAD" });
  if (resp.status === 404) return { exists: false, bytes: null, contentType: null, etag: null };
  if (!resp.ok) throw new HttpError(502, `R2 HEAD ${bucket}/${key} failed (${resp.status})`);
  const len = resp.headers.get("content-length");
  return {
    exists: true,
    bytes: len != null ? Number(len) : null,
    contentType: resp.headers.get("content-type"),
    etag: resp.headers.get("etag"),
  };
}

/** Delete one object. Returns true if gone (204 or already absent). */
export async function deleteObject(bucket: string, key: string): Promise<boolean> {
  const url = `${endpoint()}/${bucket}/${encodeKey(key)}`;
  const resp = await client().fetch(url, { method: "DELETE" });
  // R2/S3 returns 204 on delete; 404 means it was never there / already gone.
  if (resp.ok || resp.status === 404) return true;
  throw new Error(`R2 DELETE ${bucket}/${key} -> ${resp.status}`);
}

/**
 * Server-side copy within a bucket (SigV4 HEADER-signed, so x-amz-copy-source
 * IS covered by the signature — unlike presigned query URLs, which aws4fetch
 * only signs `host` for). Used by the upload flow to promote a verified staging
 * object to a unique completion-attempt key. This helper alone does NOT make
 * a shared destination immutable: the caller must publish only the DB winner
 * and never copy another attempt to that key. ≤5 GB
 * per single copy (S3 limit); all single-PUT objects here are ≤64 MB.
 */
export async function copyObject(
  bucket: string,
  srcKey: string,
  destKey: string,
  /** ETag observed by the caller's HEAD. When given, the copy is conditional:
   * R2 fails with 412 if the body's ETag changed since that HEAD. This does NOT
   * bind metadata: identical bytes can be re-PUT with a different Content-Type. */
  ifMatchEtag?: string | null,
  /** Already policy-validated, canonical bare media type. When provided, replace
   * source metadata rather than inherit a mutable Content-Type. Omission keeps
   * the helper's original COPY behavior for non-publication uses. */
  verifiedContentType?: string,
): Promise<void> {
  const url = `${endpoint()}/${bucket}/${encodeKey(destKey)}`;
  const headers: Record<string, string> = {
    "x-amz-copy-source": `/${bucket}/${encodeKey(srcKey)}`,
  };
  if (ifMatchEtag) headers["x-amz-copy-source-if-match"] = ifMatchEtag;
  if (verifiedContentType !== undefined) {
    // The upload caller enforces its role-specific allowlist; this is only a
    // fail-closed shape guard for a trusted, already-canonical header value.
    if (typeof verifiedContentType !== "string" || verifiedContentType.length > 127 ||
      !/^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/.test(verifiedContentType)) {
      throw new HttpError(500, "Invalid verified copy content-type");
    }
    headers["x-amz-metadata-directive"] = "REPLACE";
    headers["content-type"] = verifiedContentType;
  }
  // aws4fetch 1.0.20 excludes Content-Type from signing by default, including
  // header-signed requests. Opt in for this verified metadata replacement.
  const res = await uploadDispatch(url, { method: "PUT", headers,
    aws: { allHeaders: verifiedContentType !== undefined } });
  if (res.status === 412) {
    throw new HttpError(409, "The staged upload changed during verification — re-upload and try again");
  }
  const text = await res.text();
  if (!res.ok) throw new HttpError(502, `R2 CopyObject failed (${res.status}): ${text.slice(0, 300)}`);
  // S3/R2 can return 200 with an <Error> body when the copy actually failed.
  if (/<Error>/.test(text)) throw new HttpError(502, `R2 CopyObject error: ${text.slice(0, 300)}`);
}

/**
 * Best-effort bulk delete with bounded concurrency and a hard cap (edge
 * functions shouldn't fan out unbounded work). Never throws — failures come
 * back as messages so the caller can surface them as warnings.
 */
export async function deleteObjects(
  objects: R2Object[],
  concurrency = 8,
  cap = 5000,
): Promise<{ deleted: number; errors: string[] }> {
  const todo = objects.slice(0, cap);
  const errors: string[] = [];
  if (objects.length > cap) {
    errors.push(`object count ${objects.length} exceeds cap ${cap}; ${objects.length - cap} left for the batch cleaner`);
  }
  let deleted = 0;
  let i = 0;
  async function workerLoop() {
    while (i < todo.length) {
      const obj = todo[i++];
      try {
        if (await deleteObject(obj.bucket, obj.key)) deleted++;
      } catch (e) {
        errors.push(e instanceof Error ? e.message : String(e));
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, todo.length) }, workerLoop));
  return { deleted, errors };
}

// ─────────────────────────────────────────────────────────────────────────────
// Credential probe — ADDITIVE (2026-09-05, admin "Test all keys").
//
// Everything above this line is untouched, deliberately: one stray character in
// this file took the entire storage layer down on 2026-09-04, so the probe is
// appended rather than woven in.
//
// GET /admin/providers/probe needs to prove the R2 credentials AUTHENTICATE,
// not merely that three env vars are non-empty. It has to do that through the
// SAME signer every presign, HEAD, copy and delete already uses — a second copy
// of the signing code could pass while the real one fails, which is worse than
// no check at all. Hence this lives here, next to client(), instead of in
// admin/probe.ts.
//
// The call is a ListObjectsV2 capped at ONE key: it moves no object bytes,
// creates nothing, deletes nothing, and is safe to repeat. The response body is
// discarded without being read into the probe — an object listing is customer
// filenames, and no admin response has any business carrying those.

/** What probeBucket observed. Deliberately carries no body and no key material. */
export interface R2ProbeResult {
  /** HTTP status R2 answered. 200 = signed in; 403 = credentials rejected. */
  status: number;
  ok: boolean;
  /** The bucket NAME that was listed (a config value, never a secret). */
  bucket: string;
}

/**
 * Signed ListObjectsV2 (max-keys=1) against `bucket`. Throws the same
 * HttpError(500) as every other helper here when the credentials are absent.
 */
export async function probeBucket(bucket: string = R2_BUCKET_UPLOADS): Promise<R2ProbeResult> {
  const url = new URL(`${endpoint()}/${bucket}`);
  url.searchParams.set("list-type", "2");
  url.searchParams.set("max-keys", "1");
  const res = await client().fetch(url.toString(), { method: "GET" });
  // Release the connection WITHOUT reading the listing. cancel() on an already
  // settled/absent body throws; that is not a probe failure.
  try {
    await res.body?.cancel();
  } catch { /* body already disposed */ }
  return { status: res.status, ok: res.ok, bucket };
}
