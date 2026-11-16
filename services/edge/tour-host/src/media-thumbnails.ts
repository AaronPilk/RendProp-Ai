import type { Env } from "./types";

/** One fixed preview policy; never replaces, edits or uploads the master. */
export const THUMBNAIL_POLICY = "gallery-jpeg-1280-q82-v1";
export const THUMBNAIL_INPUT_BYTES = 20_000_000;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS = 30_000;
const MIME = new Set(["image/jpeg", "image/png", "image/webp", "image/avif"]);
const RESPONSE_HEADERS = {
  "Content-Type": "image/jpeg", "Cache-Control": "no-store, max-age=0",
  "CDN-Cache-Control": "no-store", "Cloudflare-CDN-Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow", "Access-Control-Allow-Origin": "https://studio.rendprop.com",
  "Access-Control-Expose-Headers": "Content-Length, ETag, Content-Type",
};
const refusal = (status: number) => new Response(null, { status, headers: RESPONSE_HEADERS });
function matches(header: string | null, etag: string, weak = true): boolean {
  return !!header && header.split(",").some(value => value.trim() === "*" || (weak ? value.trim().replace(/^W\//, "") : value.trim()) === etag);
}
async function boundedImage(response: Response): Promise<Uint8Array> {
  const length = response.headers.get("Content-Length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > MAX_OUTPUT_BYTES)) throw new Error("Preview exceeds bound");
  const reader = response.body?.getReader(); if (!reader) throw new Error("Preview body unavailable");
  const buffer = new Uint8Array(MAX_OUTPUT_BYTES); let size = 0, empty = 0;
  try {
    for (;;) { const part = await reader.read(); if (part.done) break;
      if (!part.value.byteLength) { if (++empty > 64) throw new Error("Preview stalled"); continue; }
      empty = 0; if (part.value.byteLength > MAX_OUTPUT_BYTES - size) throw new Error("Preview exceeds bound"); buffer.set(part.value, size); size += part.value.byteLength;
    }
    if (size < 3 || length !== null && size !== Number(length)) throw new Error("Preview length changed");
    const bytes = buffer.slice(0, size);
    if (bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) throw new Error("Preview must be JPEG");
    return bytes;
  } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
}

/** Exact published key and fresh R2 HEAD have been admitted by the caller.
 * Every cache hit, conditional response and HEAD rechecks current publication. */
export async function thumbnailResponse(
  req: Request, env: Env, key: string, head: R2Object,
  readSource: () => Promise<ReadableStream<Uint8Array> | null>,
  revalidate: (bytes?: number) => Promise<number>,
): Promise<Response> {
  const mime = head.httpMetadata?.contentType?.split(";")[0].trim().toLowerCase();
  if (!mime || !MIME.has(mime) || head.size > THUMBNAIL_INPUT_BYTES) return refusal(404);
  if (!env.IMAGES) return refusal(503);
  const identity = JSON.stringify([THUMBNAIL_POLICY, key, head.etag, head.size, mime]);
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity))), x => x.toString(16).padStart(2, "0")).join("");
  const etag = `"${hash}"`, headers = new Headers(RESPONSE_HEADERS); headers.set("ETag", etag);
  const conditional = req.headers.get("If-Match");
  const early = req.headers.has("Range") ? 416 : conditional && !matches(conditional, etag, false) ? 412 : matches(req.headers.get("If-None-Match"), etag) ? 304 : req.method === "HEAD" ? 200 : null;
  if (early !== null) { const current = await revalidate(); return current === 200 ? new Response(null, { status: early, headers }) : refusal(current); }
  // Internal identity includes immutable master ETag and the fixed policy;
  // caller width/quality/format variations cannot create new transformations.
  const cacheKey = new Request(new URL(`/__rendprop-derived-cache/${THUMBNAIL_POLICY}/${hash}`, req.url));
  const cache = typeof caches === "undefined" ? null : caches.default;
  let bytes: Uint8Array | null = null;
  try { const hit = await cache?.match(cacheKey); if (hit?.headers.get("ETag") === etag && hit.headers.get("Content-Type") === "image/jpeg") bytes = await boundedImage(hit); } catch { /* Cache failure cannot change source authority. */ }
  if (!bytes) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const active: { stream: ReadableStream<Uint8Array> | null } = { stream: null };
    try {
      const deadline = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("Preview deadline exceeded")), TIMEOUT_MS); });
      bytes = await Promise.race([(async () => {
        active.stream = await readSource(); if (!active.stream) throw new Error("Published source unavailable");
        const transformed = await env.IMAGES!.input(active.stream)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/jpeg", quality: 82, anim: false });
        return boundedImage(transformed.response());
      })(), deadline]);
    } catch { try { await active.stream?.cancel(); } catch { /* Transformer may own the reader. */ } return refusal(503); }
    finally { if (timer !== undefined) clearTimeout(timer); }
    // These cache headers never leave this function. Viewers receive no-store.
    if (cache) { try { await cache.put(cacheKey, new Response(bytes, { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length), "Cache-Control": "public, max-age=2592000", "ETag": etag } })); } catch { /* Eviction is safe; an authorized read can regenerate. */ } }
  }
  // Also charge actual outgoing preview bytes before exposure. Revocation or
  // a new selected photo cannot be bypassed through previously cached pixels.
  const current = await revalidate(bytes.length); if (current !== 200) return refusal(current);
  headers.set("Content-Length", String(bytes.length));
  return new Response(bytes, { headers });
}
