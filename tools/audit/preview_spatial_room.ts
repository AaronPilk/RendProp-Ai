/** Loopback-only real-room acceptance harness. Never deploy this fixture server.
 * Reuses the production viewer/decoder/SOG guard; the only module substitution
 * is its pinned engine's URL, served locally with the identical SRI bytes.
 * No Supabase auth, production budget, review, or publishing path is exercised.
 */
import { spatialModule, spatialPage, SPATIAL_HEADERS } from "../../services/edge/tour-host/src/spatial.ts";
import { decodeSpatialManifest } from "../../services/edge/tour-host/src/spatial-manifest.ts";
import { inspectSpatialSog } from "../../services/edge/tour-host/src/spatial-sog.ts";

const [manifestPath, modelPath, portText = "8098"] = Deno.args;
if (!manifestPath || !modelPath) throw new Error("Provide exact private manifest and SOG paths");
const port = Number(portText);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid port");
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
const source = await spatialModule().text();
if (!source.includes(`sha384-${engineHash}`)) throw new Error("Pinned engine SRI mismatch");
const engineURL = "https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js";
if (source.split(engineURL).length !== 2) throw new Error("Expected exactly one engine URL substitution");
const module = source.replace(engineURL, "/private-engine.js");
const base = "/s/" + manifest.scene_id;
const origin = `http://127.0.0.1:${port}`;
// This local-only capability prevents an unrelated page from reading the room
// through a browser. It is not a replacement for production authorization.
const token = crypto.randomUUID();
const headers = { ...SPATIAL_HEADERS, "Cross-Origin-Resource-Policy": "same-origin" };
const page = spatialPage(manifest.scene_id);
const tokenLine = "const token = new URLSearchParams(location.hash.slice(1)).get('access') || '';";
const pageSource = await page.text();
if (pageSource.split(tokenLine).length !== 2) throw new Error("Unexpected page token binding");
// Only the loopback page receives this fixture credential; never print it in
// a console/URL/receipt. The production viewer's private-state gate is unchanged.
const localPage = pageSource.replace(tokenLine, `const token = ${JSON.stringify(token)};`);
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
