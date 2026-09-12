import type { Env } from "./types";
import { decodeSpatialManifest } from "./spatial-manifest";
import { SPATIAL_RUNTIME } from "./spatial-runtime";

export const SPATIAL_HEADERS = {
  "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
  "X-Robots-Tag": "noindex, nofollow", "Cross-Origin-Resource-Policy": "same-origin",
};
const failure = (status: number) => Response.json({ error: "Spatial scene unavailable", status }, { status, headers: SPATIAL_HEADERS });

/** No cache, redirects, arbitrary URLs or new credential store. The authoritative
 * spatial service rechecks the viewer capability / published revision per read. */
export async function spatialData(request: Request, env: Env, scene: string, kind: "manifest" | "model"): Promise<Response> {
  if (request.signal.aborted) return failure(503);
  const url = new URL(request.url);
  const revision = url.searchParams.get("revision");
  if (kind === "model" && (!revision || !/^[0-9a-f-]{36}$/i.test(revision))) return failure(400);
  const authorization = request.headers.get("Authorization");
  if (authorization && (authorization.length > 4096 || !/^Bearer [A-Za-z0-9_.-]+$/.test(authorization))) return failure(401);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), kind === "manifest" ? 8000 : 90000);
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let done = false;
  const finish = () => {
    if (done) return;
    done = true; clearTimeout(timer); controller.abort();
    if (reader) void reader.cancel().catch(() => {});
  };
  const abort = () => finish();
  request.signal.addEventListener("abort", abort, { once: true });
  const end = () => { request.signal.removeEventListener("abort", abort); finish(); };
  try {
    const base = env.SUPABASE_FUNCTIONS_URL.replace(/\/+$/, "");
    const headers: Record<string, string> = { apikey: env.SUPABASE_ANON_KEY || "", Accept: kind === "manifest" ? "application/json" : "application/octet-stream" };
    if (authorization) headers.Authorization = authorization;
    const response = await fetch(`${base}/spatial/${scene}/${kind}${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`, {
      method: "GET", headers, redirect: "manual", signal: controller.signal, cf: { cacheTtl: 0, cacheEverything: false },
    });
    if (!response.ok || response.status !== 200 || !response.body) {
      if (response.body) void response.body.cancel().catch(() => {});
      end(); return failure([401, 403, 404, 409, 429].includes(response.status) ? response.status : 503);
    }
    reader = response.body.getReader();
    if (kind === "manifest") {
      const parts = new Uint8Array(64 * 1024); let size = 0, empty = 0;
      while (true) {
        const result = await reader.read();
        if (result.done) break;
        if (result.value.length > parts.length - size || (!result.value.length && ++empty > 64)) throw new Error("manifest bound");
        if (result.value.length) empty = 0;
        parts.set(result.value, size); size += result.value.length;
      }
      const manifest = decodeSpatialManifest(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(parts.subarray(0, size))));
      if (manifest.scene_id !== scene || (!authorization && !manifest.privacy_reviewed)) throw new Error("manifest authority mismatch");
      end(); return Response.json(manifest, { headers: SPATIAL_HEADERS });
    }
    const length = response.headers.get("Content-Length") || "";
    const bytes = Number(length);
    if (!/^[1-9][0-9]*$/.test(length) || !Number.isSafeInteger(bytes) || bytes > 32 * 1024 * 1024 ||
        response.headers.get("Content-Type")?.split(";")[0].trim() !== "application/octet-stream") throw new Error("model bound");
    if (request.method === "HEAD") { end(); return new Response(null, { headers: { ...SPATIAL_HEADERS, "Content-Length": length, "Content-Type": "application/octet-stream" } }); }
    let size = 0, empty = 0;
    const source = reader;
    const body = new ReadableStream<Uint8Array>({
      async pull(output) {
        try {
          const part = await source.read();
          if (part.done) { if (size !== bytes) throw new Error("incomplete model"); output.close(); end(); return; }
          if (part.value.length > bytes - size || (!part.value.length && ++empty > 64)) throw new Error("model bound");
          if (part.value.length) empty = 0;
          size += part.value.length; output.enqueue(part.value);
        } catch { output.error(new Error("Spatial model transfer failed")); end(); }
      },
      cancel() { end(); },
    });
    return new Response(body, { headers: { ...SPATIAL_HEADERS, "Content-Type": "application/octet-stream", "Content-Length": length } });
  } catch { end(); return failure(503); }
}

export function spatialModule(): Response {
  // Serving a prebuilt module preserves its complete dependency graph. Worker
  // minification and name helpers must never become browser dependencies.
  return new Response(SPATIAL_RUNTIME, {
    headers: { ...SPATIAL_HEADERS, "Content-Type": "text/javascript; charset=utf-8" },
  });
}

/** An inert shell contains no private artifact. Fragment capabilities never reach
 * Worker access logs and are removed before the first third-party script load. */
export function spatialPage(scene: string): Response {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>3D room</title><meta name="robots" content="noindex,nofollow"></head><body style="margin:0;background:#0e0d14;color:white;font-family:system-ui"><main id="spatial-root"><p role="status">Opening 3D room…</p></main><script type="module">
const token = new URLSearchParams(location.hash.slice(1)).get('access') || '';
history.replaceState(null, '', location.pathname);
import('/spatial-viewer.js').then(({mountSpatial}) => mountSpatial(document.getElementById('spatial-root'), {sceneId:'${scene}',token})).catch(() => { document.getElementById('spatial-root').textContent='3D viewer unavailable. Please reopen this room from the app.'; });
</script></body></html>`, { headers: { ...SPATIAL_HEADERS, "Content-Type": "text/html; charset=utf-8",
    "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' blob:; worker-src blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'self'" } });
}
