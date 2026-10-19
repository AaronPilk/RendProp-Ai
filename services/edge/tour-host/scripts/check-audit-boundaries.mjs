import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { buildSrc } from "./build-src.mjs";

const load = buildSrc("audit-boundaries-20261005");
const { default: worker } = await load("index");
const { absolutize } = await load("html");
const ctx = { waitUntil() {}, passThroughOnException() {} };
const env = { SUPABASE_FUNCTIONS_URL: "https://backend.fixture.invalid/functions/v1", SUPABASE_ANON_KEY: "synthetic-public" };
let upstream = 0, assets = 0;
globalThis.fetch = async () => { throw new Error("Unmodeled network call"); };
globalThis.caches = { default: { async match() {}, async put() {} } };

for (const path of ["/join/%", "/join/%GG", "/join/%E0%A4%A", "/join?code=%25"]) {
  const res = await worker.fetch(new Request(`https://rendprop.com${path}`), env, ctx);
  assert.equal(res.status, 404); assert.doesNotMatch(await res.text(), /URIError|stack trace/);
}
assert.equal(absolutize("//images.fixture.invalid/cover.jpg", "https://rendprop.com/f/test"), "https://images.fixture.invalid/cover.jpg");
assert.equal(absolutize("/assets/demo.jpg", "https://rendprop.com/f/test"), "https://rendprop.com/assets/demo.jpg");
env.ASSETS = { async fetch(req) { assets++; assert.equal(req.headers.get("range"), "bytes=0-3"); return new Response("test", { status: 206, headers: { "content-type": "video/mp4", "content-range": "bytes 0-3/100", etag: '"fixture"' } }); } };
for (const origin of ["http://rendprop.com", "https://www.rendprop.com", "http://www.rendprop.com"]) {
  for (const path of ["/", "/assets/site.js", "/pricing.html"]) {
    const res = await worker.fetch(new Request(origin + path), env, ctx);
    assert.equal(res.status, 301); assert.equal(res.headers.get("location"), "https://rendprop.com" + path);
  }
}
assert.equal(assets, 0, "Static files cannot bypass canonical origin");
const media = await worker.fetch(new Request("https://rendprop.com/assets/clip.mp4", { headers: { range: "bytes=0-3" } }), env, ctx);
assert.equal(media.status, 206); assert.equal(media.headers.get("content-range"), "bytes 0-3/100"); assert.equal(await media.text(), "test");
delete env.ASSETS;
for (const path of ["/healthz", "/terms", "/privacy", "/spatial-viewer.js", "/s/22266fc8-ae97-481c-baf4-1694ec14e7f2", "/u/demo"]) {
  const res = await worker.fetch(new Request("https://rendprop.com" + path), env, ctx);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("strict-transport-security"), "max-age=31536000; includeSubDomains");
  assert.equal(res.headers.get("permissions-policy"), "camera=(), microphone=(), geolocation=()");
  if (path.startsWith("/u/")) { assert.equal(res.headers.get("x-frame-options"), null); assert.match(res.headers.get("content-security-policy"), /frame-ancestors \*/); }
  else assert.equal(res.headers.get("x-frame-options"), "SAMEORIGIN");
}

const token = "a".repeat(64);
for (const method of ["GET", "HEAD"]) {
  const res = await worker.fetch(new Request(`https://rendprop.com/verify-client-email?token=${token}`, { method }), env, ctx);
  assert.equal(res.status, 200); assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(res.headers.get("referrer-policy"), "no-referrer"); assert.doesNotMatch(await res.text(), new RegExp(token));
}
globalThis.fetch = async (url, init) => {
  upstream++;
  assert.equal(url, env.SUPABASE_FUNCTIONS_URL + "/leads/verify-client-recipient");
  assert.equal(init.method, "POST"); assert.equal(init.redirect, "error"); assert.deepEqual(JSON.parse(init.body), { token });
  return new Response(JSON.stringify({ ok: true }));
};
const post = (body, origin = "https://rendprop.com", headers = {}) => new Request("https://rendprop.com/verify-client-email", { method: "POST", headers: { origin, "content-type": "application/x-www-form-urlencoded", ...headers }, body });
for (const [req, status] of [[post("token="+token,"https://foreign.fixture.invalid"),400],[post("token=invalid"),400],[post("token="+token+"&token="+token),400],[post("token="+token,""),400],[post("token="+token,undefined,{"content-length":"5000"}),413],[post("token="+token+"&pad="+"x".repeat(5000)),413]]) {
  const res=await worker.fetch(req,env,ctx);assert.equal(res.status,status);assert.doesNotMatch(await res.text(),new RegExp(token));
}
assert.equal(upstream,0,"Invalid, oversized and cross-origin confirmation requests never reach backend");
const confirmed=await worker.fetch(post("token="+token),env,ctx);assert.equal(confirmed.status,200);assert.match(await confirmed.text(),/Email confirmed/);assert.equal(upstream,1);

const script=readFileSync(new URL("../public/recipient-confirmation.js",import.meta.url),"utf8");
const controls={token:{value:""},confirm:{disabled:true},message:{textContent:""}};
let clean;
runInNewContext(script,{URLSearchParams,window:{location:{hash:"#token="+token,pathname:"/verify-client-email"},history:{replaceState(_state,_title,path){clean=path;}}},document:{getElementById(id){return controls[id];}}});
assert.equal(controls.token.value,token);assert.equal(controls.confirm.disabled,false);assert.equal(clean,"/verify-client-email");
assert.doesNotMatch(script,/localStorage|sessionStorage|console\.|fetch\(|sendBeacon/);
console.log("Audit boundaries passed: actual Worker routing, canonical static assets and ranges, spatial headers, MLS embedding, bounded recipient verification and fragment handling; no real network.");
