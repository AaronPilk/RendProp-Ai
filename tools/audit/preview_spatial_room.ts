/** Loopback-only real-room acceptance harness. Never deploy this fixture server.
 * Requires a Wrangler-emitted Worker, not the TypeScript viewer source. The
 * only browser-module substitution is its pinned engine's URL, served locally
 * with identical SRI bytes. Source decoders below validate input files only.
 * No Supabase auth, production budget, review, or publishing path is exercised.
 */
import { decodeSpatialManifest } from "../../services/edge/tour-host/src/spatial-manifest.ts";
import { inspectSpatialSog } from "../../services/edge/tour-host/src/spatial-sog.ts";

const [manifestPath, modelPath, workerBundlePath, portText = "8098"] = Deno.args;
if (!manifestPath || !modelPath || !workerBundlePath || Deno.args.length > 4)
  throw new Error("Provide private manifest, SOG, Wrangler-emitted Worker path, and optional port");
const port = Number(portText);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid port");
async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map(x => x.toString(16).padStart(2, "0")).join("");
}
const bundleInfo = await Deno.stat(workerBundlePath);
if (!bundleInfo.isFile || bundleInfo.size <= 0 || bundleInfo.size > 16 * 1024 * 1024)
  throw new Error("Expected a bounded emitted Worker file");
const bundleSHA256 = await sha256(await Deno.readFile(workerBundlePath));
const bundleURL = new URL("file:///");
bundleURL.pathname = await Deno.realPath(workerBundlePath);
const bundle = await import(bundleURL.href);
if (!bundle.default || typeof bundle.default.fetch !== "function")
  throw new Error("Emitted Worker has no fetch handler");
// Request actual built routes: serializing source functions here previously
// skipped Wrangler's __name transformation and produced a false release signal.
// No production bindings are provided, and the CLI permits only loopback net.
async function builtRoute(path: string, contentType: string): Promise<Response> {
  const response: unknown = await bundle.default.fetch(new Request("https://rendprop.com" + path), {}, {
    waitUntil: () => { throw new Error("Fixture route must not schedule background work"); },
  });
  if (!(response instanceof Response) || response.status !== 200 ||
      !response.headers.get("Content-Type")?.includes(contentType) ||
      response.headers.get("Cache-Control") !== "no-store" ||
      !response.headers.get("X-Robots-Tag")?.includes("noindex"))
    throw new Error("Emitted Worker route contract failed");
  return response;
}
if ((await Deno.stat(manifestPath)).size > 65536) throw new Error("Manifest too large");
const manifest = decodeSpatialManifest(JSON.parse(await Deno.readTextFile(manifestPath)));
if (manifest.privacy_reviewed || manifest.provenance !== "captured") throw new Error("Unpublished captured-room test required");
if ((await Deno.stat(modelPath)).size !== manifest.bytes) throw new Error("Model size mismatch");
const model = await Deno.readFile(modelPath);
const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", model))].map(x => x.toString(16).padStart(2, "0")).join("");
if (digest !== manifest.sha256) throw new Error("Model digest mismatch");
inspectSpatialSog(model, manifest.gaussian_count);
const engine = await Deno.readFile(new URL("../spatial-spike/viewer/node_modules/playcanvas/build/playcanvas.min.js", import.meta.url));
const engineHash = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-384", engine))));
const moduleResponse = await builtRoute("/spatial-viewer.js", "javascript");
const source = await moduleResponse.text();
if (new TextEncoder().encode(source).length > 1024 * 1024) throw new Error("Browser module too large");
const browserModuleSHA256 = await sha256(new TextEncoder().encode(source));
if (!source.includes(`sha384-${engineHash}`)) throw new Error("Pinned engine SRI mismatch");
const engineURL = "https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js";
if (source.split(engineURL).length !== 2) throw new Error("Expected exactly one engine URL substitution");
const module = source.replace(engineURL, "/private-engine.js");
const base = "/s/" + manifest.scene_id;
const origin = `http://127.0.0.1:${port}`;
// This local-only capability prevents an unrelated page from reading the room
// through a browser. It is not a replacement for production authorization.
const token = crypto.randomUUID();
const headers = {
  "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
  "X-Robots-Tag": "noindex, nofollow", "Cross-Origin-Resource-Policy": "same-origin",
};
const page = await builtRoute(base, "text/html");
const tokenLine = "const token = new URLSearchParams(location.hash.slice(1)).get('access') || '';";
const pageSource = await page.text();
if (pageSource.split(tokenLine).length !== 2) throw new Error("Unexpected page token binding");
// Only the loopback page receives this fixture credential; never print it in
// a console/URL/receipt. The production viewer's private-state gate is unchanged.
const localPage = pageSource.replace(tokenLine, `const token = ${JSON.stringify(token)};`);
if (await sha256(await Deno.readFile(workerBundlePath)) !== bundleSHA256)
  throw new Error("Worker bundle changed during fixture preparation");
console.log(JSON.stringify({ proof: "wrangler-emitted-worker-routes", bundleSHA256, browserModuleSHA256,
  note: "Prepared only; browser execution and room quality still require verification" }));
Deno.serve({hostname:"127.0.0.1", port, onListen:() => console.log(`PRIVATE_LOCAL_PREVIEW ${origin}${base}`)}, request => {
  const url = new URL(request.url);
  if (url.origin !== origin || request.headers.get("Origin") && request.headers.get("Origin") !== origin)
    return new Response("Invalid origin", {status:403, headers});
  if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, {status:405, headers});
  let response: Response;
  if (url.pathname === base) response = new Response(localPage, {headers:page.headers});
  else if (url.pathname === "/spatial-viewer.js") response = new Response(module, {headers:{...headers,"Content-Type":"text/javascript"}});
  else if (url.pathname === "/private-engine.js") response = new Response(engine, {headers:{...headers,"Content-Type":"text/javascript"}});
  else if (request.headers.get("Authorization") !== "Bearer " + token) response = new Response(null, {status:401, headers});
  else if (url.pathname === base + "/manifest") response = Response.json(manifest, {headers});
  else if (url.pathname === base + "/model" && url.searchParams.get("revision") === manifest.artifact_revision)
    response = new Response(model, {headers:{...headers,"Content-Type":"application/octet-stream","Content-Length":String(model.length)}});
  else response = new Response(null, {status:404, headers});
  return request.method === "HEAD" ? new Response(null, response) : response;
});
