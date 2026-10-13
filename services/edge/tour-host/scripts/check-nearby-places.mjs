#!/usr/bin/env node
// Execute the real adapter with a closed atomic R2 and provider fixture. No
// real coordinates, accounts, keys, provider calls or production resources.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import ts from "typescript";
import { buildSrc, ROOT } from "./build-src.mjs";

const adapter = await buildSrc("check-nearby-places")("nearby-places");
const sourcePath = join(ROOT, "src/nearby-places.ts");
const source = readFileSync(sourcePath, "utf8");
const hash = createHash("sha256").update(source).digest("hex");
const evidenceArg = process.argv.indexOf("--evidence-dir");
const out = evidenceArg < 0 ? null : resolve(process.argv[evidenceArg + 1]);
if (out) mkdirSync(out, { recursive: true });
let checks = 0;
const equal = (a, b, why) => { assert.deepEqual(a, b, why); checks++; };
const ok = (value, why) => { assert.ok(value, why); checks++; };
const BASE_TIME = Date.parse("2026-10-13T12:00:00Z");
const prefix = "public-location-v1/";
const origin = { lat: 35.2272499, lng: -80.8431799 };
function tour(point = origin) {
  return { space_type: "real_estate", published_at: "2026-10-13T11:00:00Z", listing: { ...point, address: "DO NOT SEND THIS PRIVATE FIXTURE ADDRESS" } };
}
const cacheKey = (point = origin) => `${prefix}pois/${(Math.round(point.lat * 1000) / 1000).toFixed(3)},${(Math.round(point.lng * 1000) / 1000).toFixed(3)}.json`;
const budgetKey = `${prefix}budget/2026-10-13.json`;
class Bucket {
  objects = new Map(); sequence = 0; writes = [];
  seed(key, value) { this.objects.set(key, { text: JSON.stringify(value), etag: `e${++this.sequence}` }); }
  value(key) { return JSON.parse(this.objects.get(key).text); }
  async get(key) {
    const v = this.objects.get(key);
    return v ? { etag: v.etag, size: Buffer.byteLength(v.text), body: new Response(v.text).body } : null;
  }
  async put(key, text, options = {}) {
    const v = this.objects.get(key), condition = options.onlyIf;
    if (condition instanceof Headers && condition.get("If-None-Match") === "*" && v) return null;
    if (condition?.etagMatches !== undefined && condition.etagMatches !== v?.etag) return null;
    const etag = `e${++this.sequence}`;
    this.objects.set(key, { text, etag }); this.writes.push({ key, options });
    return { etag };
  }
}
const node = (id, name, tags = {}, point = { lat: 35.227, lon: -80.843 }) => ({ type: "node", id, ...point, tags: { name, ...tags } });
function fixture(point = origin) {
  const bucket = new Bucket(), calls = [];
  let raw = { elements: [node(1, "Actual Fixture Restaurant", { amenity: "restaurant" })] };
  let provider = async (_url, _options) => new Response(JSON.stringify(raw), { headers: { "Content-Type": "application/json" } });
  let time = BASE_TIME;
  const deps = { now: () => time, timeoutMs: 200, fetch: async (url, options) => { calls.push({ url, options }); return provider(url, options); } };
  return { bucket, calls, deps, point, input: tour(point), env: { MEDIA_RENDERS: bucket },
    setRaw(v) { raw = v; }, setProvider(v) { provider = v; }, setTime(v) { time = v; } };
}
const lookup = (f, module = adapter) => module.lookupNearbyPlaces(f.input, f.env, f.deps);

async function basic(module = adapter) {
  const f = fixture();
  f.setRaw({ elements: [
    node(1, "Actual <Restaurant>", { amenity: "restaurant" }),
    node(2, "Actual Cafe", { amenity: "cafe" }, { lat: 35.228, lon: -80.843 }),
    node(3, "Actual Shop", { shop: "supermarket" }, { lat: 35.229, lon: -80.843 }),
    node(4, "Private venue", { amenity: "restaurant", access: "private" }),
    node(5, "Unknown category", { shop: "vacant" }),
    node(6, "Outside radius", { amenity: "cafe" }, { lat: 36, lon: -80.843 }),
    node(7, "Missing geometry", { amenity: "restaurant" }, { lat: null, lon: -80.843 }),
    node(-1, "Bad identity", { amenity: "restaurant" }),
    { type: "way", id: 20, center: { lat: 35.227, lon: -80.843 }, tags: { name: "Actual <Restaurant>", amenity: "restaurant" } },
  ] });
  const result = await lookup(f, module);
  equal(result.status, "available"); equal(result.places.length, 3);
  equal(result.places.map(p => p.category), ["Restaurant", "Cafe", "Shop"]);
  equal(result.places[0].name, "Actual <Restaurant>", "adapter supplies literal data; renderer must escape it");
  equal(result.places[0].source_url, "https://www.openstreetmap.org/node/1");
  equal(result.places[0].distance_m, 0, "distance uses only rounded origin");
  ok(result.places.every(p => Number.isFinite(p.distance_m) && p.distance_m <= 1500));
  equal(result.attribution, "© OpenStreetMap contributors");
  equal(f.calls.length, 1);
  equal(f.calls[0].url, "https://overpass.private.coffee/api/interpreter");
  equal(f.calls[0].options.redirect, "manual"); equal(f.calls[0].options.cache, "no-store");
  const query = new URLSearchParams(f.calls[0].options.body).get("data");
  ok(query.includes("around:1500,35.227,-80.843"), "only rounded origin reaches provider");
  ok(!query.includes("35.2272499") && !query.includes("PRIVATE FIXTURE"));
  ok(query.startsWith("[out:json][timeout:4][maxsize:16777216]"));
  equal(f.bucket.value(budgetKey).count, 1);
  equal(f.bucket.value(cacheKey()).expires_at - BASE_TIME, 7 * 24 * 3600 * 1000);
  equal(f.bucket.value(cacheKey()).license, "https://www.openstreetmap.org/copyright");
  const again = await lookup(f, module);
  equal(again, result); equal(f.calls.length, 1, "cached visits do not query provider");
}

async function exhausted(module = adapter) {
  const f = fixture(); f.bucket.seed(budgetKey, { count: 100 });
  equal((await lookup(f, module)).status, "unavailable"); equal(f.calls.length, 0, "daily budget refuses before provider");
}
async function stampede(module = adapter) {
  const f = fixture();
  const results = await Promise.all(Array.from({ length: 20 }, () => lookup(f, module)));
  equal(f.calls.length, 1, "cross-request area lease permits exactly one provider call");
  equal(f.bucket.value(budgetKey).count, 1);
  equal(results.filter(r => r.status === "available").length, 1);
}
async function oversized(module = adapter) {
  const f = fixture(); const text = JSON.stringify({ elements: [node(1, "R", { amenity: "restaurant" })] });
  f.setProvider(async () => new Response(text + " ".repeat(256 * 1024 + 1 - text.length)));
  equal((await lookup(f, module)).status, "unavailable", "decoded byte cap is enforced");
}
async function poison(module = adapter) {
  const f = fixture(); f.bucket.seed(cacheKey(), {
    version: 1, expires_at: BASE_TIME + 60000, license: "https://www.openstreetmap.org/copyright",
    result: { status: "available", attribution: "© OpenStreetMap contributors", places: [
      { name: "Impossible distance", category: "Cafe", lat: 35.229, lng: -80.843, distance_m: 0, source_url: "https://www.openstreetmap.org/node/123" },
    ] },
  });
  equal((await lookup(f, module)).places[0].name, "Actual Fixture Restaurant", "corrupt cached distance is never displayed");
  equal(f.calls.length, 1);
}

let failed = null;
const controls = [];
try {
  await basic(); await exhausted(); await stampede(); await oversized(); await poison();
  for (const input of [
    { ...tour(), space_type: "venue" }, { ...tour(), published_at: null }, { ...tour(), published_at: "2099-01-01" },
    tour({ lat: null, lng: null }), tour({ lat: 91, lng: 0 }), tour({ lat: 0, lng: Infinity }),
  ]) { const f = fixture(); f.input = input; equal((await lookup(f)).status, "unavailable"); equal(f.calls.length, 0); }
  { const f = fixture(); f.env = {}; equal((await lookup(f)).status, "unavailable"); equal(f.calls.length, 0); }
  { const f = fixture(); f.setRaw({ elements: [] }); equal((await lookup(f)).status, "empty");
    equal(f.bucket.value(cacheKey()).expires_at - BASE_TIME, 24 * 3600 * 1000);
    equal((await lookup(f)).status, "empty"); equal(f.calls.length, 1); }
  { const f = fixture(); f.setRaw({ elements: [], remark: "runtime timeout" }); equal((await lookup(f)).status, "unavailable");
    equal(f.bucket.value(cacheKey()).expires_at - BASE_TIME, 10 * 60 * 1000); }
  for (const code of [301, 401, 429, 500, 504]) {
    const f = fixture(); f.setProvider(async () => new Response("private error body", { status: code }));
    const r = await lookup(f); equal(r.status, "unavailable"); equal(r.places, []); equal(f.calls.length, 1);
    ok(!JSON.stringify(r).includes("private error body"));
  }
  for (const body of ["bad JSON", new Uint8Array([0xff, 0xfe]), JSON.stringify({ notElements: [] })]) {
    const f = fixture(); f.setProvider(async () => new Response(body)); equal((await lookup(f)).status, "unavailable");
  }
  { const f = fixture(); f.setRaw({ elements: Array.from({ length: 20 }, (_, i) => node(i + 1, `Cafe${i}`, { amenity: "cafe" })) });
    equal((await lookup(f)).places.length, 3); }
  { const f = fixture(); f.setRaw({ elements: [node(1, "\u0000 Clean \nName ", { amenity: "cafe" })] });
    equal((await lookup(f)).places[0].name, "Clean Name"); }
  { const f = fixture(); f.bucket.get = async () => { throw new Error("storage unavailable"); };
    equal((await lookup(f)).status, "unavailable"); equal(f.calls.length, 0); }
  { const f = fixture(); f.bucket.put = async () => null;
    equal((await lookup(f)).status, "unavailable"); equal(f.calls.length, 0); }
  { const f = fixture(); f.bucket.seed(budgetKey, { count: "invalid" });
    equal((await lookup(f)).status, "unavailable"); equal(f.calls.length, 0); }
  // Independent cells share the same atomic final permit.
  { const bucket = new Bucket(); bucket.seed(budgetKey, { count: 99 });
    const fixtures = Array.from({ length: 15 }, (_, i) => fixture({ lat: 35.227 + i / 1000, lng: -80.843 }));
    for (const f of fixtures) { f.bucket = bucket; f.env.MEDIA_RENDERS = bucket; }
    await Promise.all(fixtures.map(f => lookup(f)));
    equal(fixtures.reduce((n, f) => n + f.calls.length, 0), 1); equal(bucket.value(budgetKey).count, 100); }
  // A service which ignores AbortSignal still cannot hold the public request.
  { const f = fixture(); f.deps.timeoutMs = 25; f.setProvider(async () => new Promise(() => {}));
    const start = performance.now(); equal((await lookup(f)).status, "unavailable");
    ok(performance.now() - start < 250); equal(f.calls.length, 1); }
  { const f = fixture(); f.deps.timeoutMs = 25;
    f.setProvider(async () => new Response(new ReadableStream({ start() {} })));
    const start = performance.now(); equal((await lookup(f)).status, "unavailable"); ok(performance.now() - start < 250); }
  { const f = fixture(); f.deps.timeoutMs = 25; f.bucket.get = async () => new Promise(() => {});
    const start = performance.now(); equal((await lookup(f)).status, "unavailable"); ok(performance.now() - start < 250); equal(f.calls.length, 0); }
  { const f = fixture(); f.setProvider(async () => new Response(new ReadableStream({ pull(c) { c.enqueue(new Uint8Array()); } })));
    equal((await lookup(f)).status, "unavailable", "immediately empty stream cannot starve deadline forever"); }
  { const f = fixture(); await lookup(f); f.setTime(BASE_TIME + 7 * 24 * 3600 * 1000 + 1); await lookup(f);
    equal(f.calls.length, 2, "positive cache refreshes only after seven days"); }
  // Each negative control executes compiled mutated production, and must fail
  // its intended oracle. A compile error or unrelated exception is not proof.
  const mutations = [
    ["precise-origin", "Math.round(tour.listing.lat * 1000) / 1000", "tour.listing.lat", basic, /only rounded origin/],
    ["daily-cap", "count >= NEARBY_DAILY_LOOKUPS", "false", exhausted, /unavailable/],
    ["area-lease", "if (!alive() || !locked) return unavailable();", "if (!alive()) return unavailable();", stampede, /exactly one provider call/],
    ["body-cap", "export const NEARBY_MAX_BYTES = 256 * 1024;", "export const NEARBY_MAX_BYTES = 1024 * 1024;", oversized, /decoded byte cap/],
    ["cached-distance", "Math.abs(distance(lat, lng, p.lat, p.lng) - p.distance_m) > 1", "false", poison, /corrupt cached distance/],
  ];
  for (const [name, before, after, test, reason] of mutations) {
    equal(source.split(before).length, 2, `${name}: exact mutation anchor`);
    const js = ts.transpileModule(source.replace(before, after), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText;
    const path = join(ROOT, "node_modules/.cache/check-nearby-places", `${name}.mjs`); writeFileSync(path, js);
    const mutated = await import(pathToFileURL(path));
    let caught = null; try { await test(mutated); } catch (e) { caught = e; }
    ok(caught instanceof assert.AssertionError && reason.test(caught.message), `${name}: must fail classified assertion, got ${caught?.message}`);
    controls.push({ name, caught: true, assertion: caught.message.split("\n")[0] });
  }
} catch (error) { failed = error; }
const receipt = { passed: failed === null, assertions: checks, compiled_controls: controls, source_sha256: hash,
  source_binding_matches: createHash("sha256").update(readFileSync(sourcePath)).digest("hex") === hash,
  network: "closed mocked provider; no live availability or POI accuracy proof", r2: "closed atomic conditional fixture; real runtime CAS checked separately",
  failure: failed ? String(failed.stack || failed) : null };
if (out) writeFileSync(join(out, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
console.log(JSON.stringify(receipt, null, 2));
if (failed) process.exitCode = 1;
