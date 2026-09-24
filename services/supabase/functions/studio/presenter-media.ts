// All URLs here are resolved from private server records, never request bodies.
import { assert } from "../_shared/http.ts";
import { probeMP4Timing } from "../ai-video/mp4duration.ts";

export const PRESENTER_VIDEO_BYTES = 48 * 1024 * 1024;
export const PRESENTER_PHOTO_BYTES = 12 * 1024 * 1024;
export type PresenterAsset = { id: string; listing_id: string; bucket: string; storage_key: string; sha256: string; bytes: number; duration_s?: number };
export type PresenterProbe = { sha256: string; bytes: number; duration_s: number };
export type MediaFetch = (url: string, init: RequestInit) => Promise<Response>;
export type MediaSign = (key: string, seconds: number) => Promise<string>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function originalAsset(value: unknown, org: string): PresenterAsset {
  const a = value as PresenterAsset;
  assert(!!a && UUID.test(a.id) && UUID.test(a.listing_id) && a.bucket === "uploads" &&
    typeof a.storage_key === "string" && a.storage_key.startsWith(`uploads/${org}/${a.listing_id}/`) &&
    !a.storage_key.includes("..") && !/[\\%?#]/.test(a.storage_key) && ![...a.storage_key].some((c) => c.charCodeAt(0) < 32) &&
    /^[0-9a-f]{64}$/.test(a.sha256) && Number.isSafeInteger(a.bytes) && a.bytes > 0,
    422, "The approved original could not be verified.");
  return a;
}

export function privateOutputKey(org: string, job: string, value: unknown): string {
  assert(UUID.test(org) && UUID.test(job) && value === `presenter-private/${org}/${job}/output.mp4`, 503, "Private presenter storage could not be verified.");
  return value as string;
}

export async function mediaBytes(response: Response, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  assert(response.ok, 502, "The media is not ready to read. Check this job again shortly.");
  const size = response.headers.get("content-length");
  if (size !== null && (!/^\d+$/.test(size) || Number(size) > limit)) {
    await response.body?.cancel();
    assert(false, 422, "The clip is too large for presenter generation. Export a smaller clip and upload it again.");
  }
  const reader = response.body?.getReader();
  assert(reader, 422, "The media is empty.");
  const chunks: Uint8Array[] = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      assert(length <= limit, 422, "The media exceeds the presenter size limit.");
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  assert(length > 0 && (size === null || Number(size) === length), 422, "The media is incomplete.");
  const bytes = new Uint8Array(length); let at = 0;
  for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
  return bytes;
}

export async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((n) => n.toString(16).padStart(2, "0")).join("");
}

/** Run the existing strict movie/track/sample timeline probe over the exact
 * downloaded bytes; probing another GET could measure a different object. */
export async function videoProbe(bytes: Uint8Array<ArrayBuffer>, purpose: "source" | "output" = "source"): Promise<PresenterProbe> {
  const timing = await probeMP4Timing("https://verified-memory.rendprop.com/video.mp4", (_url, init) => {
    const range = /^bytes=(\d+)-(\d+)$/.exec(new Headers(init.headers).get("range") ?? "");
    assert(range, 422, "Invalid video probe range.");
    const first = Number(range[1]), last = Number(range[2]);
    assert(last < bytes.length, 422, "Incomplete MP4 metadata.");
    return Promise.resolve(new Response(bytes.slice(first, last + 1), { status: 206, headers: { "content-range": `bytes ${first}-${last}/${bytes.length}` } }));
  });
  assert(purpose === "source" ? timing.duration_s >= 4 && timing.duration_s <= 30 : timing.duration_s >= 1 && timing.duration_s <= 31, 422,
    purpose === "source" ? "Use a complete source performance between 4 and 30 seconds." : "The generated video is outside the supported output duration range.");
  return { sha256: await sha256(bytes), bytes: bytes.length, duration_s: timing.duration_s };
}

function photoSignature(bytes: Uint8Array): boolean {
  return (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) ||
    [137, 80, 78, 71, 13, 10, 26, 10].every((n, i) => bytes[i] === n) ||
    (new TextDecoder().decode(bytes.subarray(0, 4)) === "RIFF" && new TextDecoder().decode(bytes.subarray(8, 12)) === "WEBP");
}

export async function verifyPresenterOriginal(asset: PresenterAsset, video: boolean, sign: MediaSign, fetcher: MediaFetch): Promise<{ url: string; probe: PresenterProbe }> {
  const limit = video ? PRESENTER_VIDEO_BYTES : PRESENTER_PHOTO_BYTES;
  assert(asset.bytes <= limit, 422, video ? "Export a source clip under 48 MiB before requesting a presenter quote." : "Use reference photos under 12 MiB.");
  const url = await sign(asset.storage_key, 600);
  const response = await fetcher(url, { redirect: "error", credentials: "omit", signal: AbortSignal.timeout(60_000) });
  const bytes = await mediaBytes(response, limit);
  const digest = await sha256(bytes);
  assert(bytes.length === asset.bytes && digest === asset.sha256, 409, "The approved original changed. Upload it again and renew approval.");
  if (!video) assert(photoSignature(bytes), 422, "Use JPEG, PNG or WebP reference photos. HEIC photos must be exported to one of these formats first.");
  const probe = video ? await videoProbe(bytes) : { sha256: digest, bytes: bytes.length, duration_s: 0 };
  return { url, probe };
}

/** Vendor output hosts are deployment configuration verified against the
 * account's real response. Official examples do not establish a CDN host. */
export function presenterOutputUrl(value: string, allowedHosts: readonly string[]): string {
  let url: URL | undefined;
  try { url = new URL(value); } catch { /* fail closed below */ }
  assert(url && url.protocol === "https:" && !url.username && !url.password && !url.port && !url.hash &&
    allowedHosts.length > 0 && allowedHosts.every((host) => /^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}$/.test(host)) &&
    allowedHosts.includes(url.hostname), 502, "The generated video's storage host has not been approved.");
  return value;
}
