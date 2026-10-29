#!/usr/bin/env node
// check-asset-range.mjs — byte ranges for self-hosted media (iOS playback).
//
// iOS WebKit/AVFoundation refuse to play an MP4 whose server ignores Range.
// The static-assets binding answers ranges with a 200, so the Worker slices
// video/audio answers itself (src/asset-range.ts). This gate drives the real
// Worker with a stub ASSETS binding and checks: 206 + Content-Range for a
// single range, suffix and open-ended ranges, 416 for unsatisfiable ones,
// Accept-Ranges on plain GET and HEAD, untouched non-media and 404 answers,
// and the safety headers still applied.
//
// Run: npm test

import { buildSrc } from "./build-src.mjs";

const load = buildSrc("asset-range-check");
const worker = (await load("index")).default;
const { parseRange } = await load("asset-range");

const failures = [];
let checks = 0;
function expect(cond, msg) { checks++; if (!cond) failures.push(msg); else if (process.env.VERBOSE) console.log(`  ok  ${msg}`); }

const VIDEO = new Uint8Array(1000).map((_, i) => i % 251);
const assets = {
  async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/assets/demo-tour.mp4") {
      return new Response(req.method === "HEAD" ? null : VIDEO.slice(), {
        status: 200, headers: { "Content-Type": "video/mp4", "Content-Length": String(VIDEO.length), "ETag": '"demo"', "Cache-Control": "public, max-age=86400" },
      });
    }
    if (path === "/assets/site.css") {
      return new Response("body{}", { status: 200, headers: { "Content-Type": "text/css" } });
    }
    return new Response("not found", { status: 404 });
  },
};
const env = { ASSETS: assets, SUPABASE_FUNCTIONS_URL: "https://example.supabase.co/functions/v1", SUPABASE_ANON_KEY: "anon", TOUR_CACHE_TTL: "60" };
const ctx = { waitUntil() {}, passThroughOnException() {} };
const get = (path, headers = {}, method = "GET") => worker.fetch(new Request(`https://rendprop.com${path}`, { method, headers }), env, ctx);
const bytes = async (res) => new Uint8Array(await res.arrayBuffer());

// parseRange unit cases
expect(JSON.stringify(parseRange("bytes=0-1", 1000)) === '{"start":0,"end":1}', "first two bytes");
expect(JSON.stringify(parseRange("bytes=990-", 1000)) === '{"start":990,"end":999}', "open-ended range");
expect(JSON.stringify(parseRange("bytes=-10", 1000)) === '{"start":990,"end":999}', "suffix range");
expect(JSON.stringify(parseRange("bytes=900-5000", 1000)) === '{"start":900,"end":999}', "end clamps to size");
expect(parseRange("bytes=1000-", 1000) === "unsatisfiable", "start at size is unsatisfiable");
expect(parseRange("bytes=5-4", 1000) === "unsatisfiable", "reversed range is unsatisfiable");
expect(parseRange("bytes=-0", 1000) === "unsatisfiable", "zero suffix is unsatisfiable");
expect(parseRange("bytes=0-1,5-6", 1000) === null, "multi-range is ignored");
expect(parseRange("items=0-1", 1000) === null, "other units are ignored");
expect(parseRange("bytes=-", 1000) === null, "empty range is ignored");
expect(parseRange(null, 1000) === null, "no header");

// Worker behaviour
let res = await get("/assets/demo-tour.mp4", { Range: "bytes=0-1" });
let body = await bytes(res);
expect(res.status === 206, `bytes=0-1 → 206 (got ${res.status})`);
expect(res.headers.get("Content-Range") === "bytes 0-1/1000", `Content-Range (got ${res.headers.get("Content-Range")})`);
expect(res.headers.get("Content-Length") === "2", "Content-Length 2");
expect(res.headers.get("Accept-Ranges") === "bytes", "Accept-Ranges on 206");
expect(body.length === 2 && body[0] === 0 && body[1] === 1, "first two bytes delivered");
expect(res.headers.get("ETag") === '"demo"' && res.headers.get("Content-Type") === "video/mp4", "ETag and type kept");
expect(res.headers.get("Strict-Transport-Security") !== null && res.headers.get("X-Content-Type-Options") === "nosniff", "safety headers still applied");

res = await get("/assets/demo-tour.mp4", { Range: "bytes=500-509" });
body = await bytes(res);
expect(res.status === 206 && res.headers.get("Content-Range") === "bytes 500-509/1000", "middle range");
expect(body.length === 10 && body.every((b, i) => b === (500 + i) % 251), "middle bytes exact");

res = await get("/assets/demo-tour.mp4", { Range: "bytes=-5" });
body = await bytes(res);
expect(res.status === 206 && res.headers.get("Content-Range") === "bytes 995-999/1000" && body.length === 5, "suffix range served");

res = await get("/assets/demo-tour.mp4", { Range: "bytes=2000-" });
expect(res.status === 416 && res.headers.get("Content-Range") === "bytes */1000", `unsatisfiable → 416 (got ${res.status})`);

res = await get("/assets/demo-tour.mp4");
body = await bytes(res);
expect(res.status === 200 && res.headers.get("Accept-Ranges") === "bytes" && body.length === 1000, "plain GET: 200 full body, Accept-Ranges");

res = await get("/assets/demo-tour.mp4", { Range: "bytes=0-1,4-5" });
body = await bytes(res);
expect(res.status === 200 && body.length === 1000, "multi-range falls back to full 200");

res = await get("/assets/demo-tour.mp4", {}, "HEAD");
expect(res.status === 200 && res.headers.get("Accept-Ranges") === "bytes", "HEAD advertises ranges");

res = await get("/assets/site.css", { Range: "bytes=0-1" });
expect(res.status === 200 && res.headers.get("Accept-Ranges") === null && (await res.text()) === "body{}", "non-media asset untouched");

if (failures.length) {
  console.error(`check-asset-range: ${failures.length} of ${checks} checks FAILED`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`check-asset-range: ${checks} checks passed`);
