import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";
import { assert, HttpError } from "../_shared/http.ts";
import { MAX_OUTPUT_BYTES, type Row } from "./contract.ts";
function settings() {
  const read = (name: string) => Deno.env.get(name)?.trim();
  const account = read("CLOUDFLARE_ACCOUNT_ID"),
    access = read("R2_ACCESS_KEY_ID"),
    secret = read("R2_SECRET_ACCESS_KEY");
  if (!account || !access || !secret) {
    throw new HttpError(503, "3D storage is not configured");
  }
  return {
    base: `https://${account}.r2.cloudflarestorage.com/${
      read("R2_BUCKET_UPLOADS") ?? "rendprop-uploads"
    }`,
    client: new AwsClient({
      accessKeyId: access,
      secretAccessKey: secret,
      service: "s3",
      region: "auto",
    }),
  };
}
function keyURL(base: string, key: string) {
  assert(
    /^(spatial|uploads)\/[a-zA-Z0-9_./-]+$/.test(key) && !key.includes(".."),
    503,
    "Invalid private object identity",
  );
  return `${base}/${key.split("/").map(encodeURIComponent).join("/")}`;
}
export async function readURL(key: string): Promise<string> {
  const s = settings(), url = new URL(keyURL(s.base, key));
  url.searchParams.set("X-Amz-Expires", "900");
  return (await s.client.sign(url.toString(), {
    method: "GET",
    aws: { signQuery: true },
  })).url;
}
async function dispatch(
  key: string,
  init: Parameters<AwsClient["sign"]>[1],
  timeout = 30000,
) {
  const s = settings(), signed = await s.client.sign(keyURL(s.base, key), init);
  return fetch(signed, {
    redirect: "error",
    signal: AbortSignal.timeout(timeout),
  });
}
export async function storeOutput(
  job: Row,
  bytes: Uint8Array<ArrayBuffer>,
): Promise<string> {
  assert(
    bytes.byteLength === job.output_bytes &&
      bytes.byteLength <= MAX_OUTPUT_BYTES,
    503,
    "Output length binding failed",
  );
  // No presigned PUT exists. The sole journal winner writes these already-hashed
  // bytes, with If-None-Match, to a revision key that is never reused.
  const res = await dispatch(String(job.output_key), {
    method: "PUT",
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(bytes.length),
      "x-amz-meta-sha256": String(job.output_sha256),
      "x-amz-content-sha256": String(job.output_sha256),
      "if-none-match": "*",
    },
    body: bytes,
  }, 120000);
  await res.body?.cancel();
  assert(res.ok, 503, "3D output write needs recovery");
  const etag = res.headers.get("etag");
  assert(etag, 503, "3D output write has no receipt");
  return etag;
}
export async function storedOutput(job: Row): Promise<string> {
  const res = await dispatch(String(job.output_key), { method: "HEAD" });
  await res.body?.cancel();
  assert(
    res.ok && Number(res.headers.get("content-length")) === job.output_bytes &&
      res.headers.get("content-type") === "application/octet-stream" &&
      res.headers.get("x-amz-meta-sha256") === job.output_sha256,
    503,
    "3D output is not yet verifiable",
  );
  const etag = res.headers.get("etag");
  assert(etag, 503, "3D output receipt is missing");
  return etag;
}
export async function getOutput(job: Row): Promise<Response> {
  const res = await dispatch(String(job.output_key), {
    method: "GET",
    headers: { "if-match": String(job.output_etag) },
  });
  assert(
    res.ok && Number(res.headers.get("content-length")) === job.output_bytes,
    503,
    "3D output is unavailable",
  );
  return res;
}
