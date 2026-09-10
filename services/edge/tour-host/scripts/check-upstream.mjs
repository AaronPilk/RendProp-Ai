#!/usr/bin/env node
// Executes the actual Worker with synthetic fetch/stream responses. Never sends
// a network request. Accelerated timers still assert the production 8s deadline.
import { buildSrc } from "./build-src.mjs";

const load = buildSrc("upstream-check");
const worker = (await load("index")).default;
const { buildDemoTour, buildDemoPortfolio } = await load("demo");
const LIMIT = 4 * 1024 * 1024;
const ENV = {
  SUPABASE_FUNCTIONS_URL: "https://upstream.invalid/functions/v1",
  SUPABASE_ANON_KEY: "SYNTHETIC-PRIVATE-UPSTREAM-KEY",
  TOUR_CACHE_TTL: "60",
};
const encoder = new TextEncoder();
const realSetTimeout = globalThis.setTimeout;
const realClearTimeout = globalThis.clearTimeout;
let checks = 0;
let cases = 0;
const failures = [];
function expect(value, message) { checks++; if (!value) failures.push(message); }
globalThis.caches = { default: { async match() { return undefined; }, async put() {} } };
const ctx = { waitUntil() {}, passThroughOnException() {} };

function streamed(bytes, { stalled = false, error = false, cancelStalls = false, chunkSize = Infinity, emptyChunks = 0 } = {}) {
  let offset = 0;
  const state = { cancelled: false, reads: 0 };
  const body = new ReadableStream({
    pull(controller) {
      state.reads++;
      if (error) { controller.error(new Error("SYNTHETIC-PRIVATE-BODY-ERROR")); return; }
      if (emptyChunks-- > 0) { controller.enqueue(new Uint8Array(0)); return; }
      if (offset < (bytes?.length || 0)) {
        const end = Math.min(bytes.length, offset + chunkSize);
        controller.enqueue(bytes.subarray(offset, end)); offset = end; return;
      }
      if (!stalled) controller.close();
    },
    cancel() { state.cancelled = true; if (cancelStalls) return new Promise(() => {}); },
  });
  return { response: new Response(body, { headers: { "Content-Type": "application/json", "Content-Length": "1" } }), state };
}

async function run(path, label, expectedStatus, factory, verify = () => {}) {
  cases++;
  const timers = new Set();
  const delays = [];
  let fetches = 0;
  let requestInit;
  let watchdog;
  const specimen = factory();
  globalThis.setTimeout = (fn, ms, ...args) => {
    delays.push(ms);
    const timer = realSetTimeout(fn, 5, ...args);
    timers.add(timer);
    return timer;
  };
  globalThis.clearTimeout = (timer) => { timers.delete(timer); realClearTimeout(timer); };
  globalThis.fetch = async (_url, init) => {
    fetches++;
    requestInit = init;
    return typeof specimen.fetch === "function" ? specimen.fetch(init) : specimen.response;
  };
  try {
    const response = await Promise.race([
      worker.fetch(new Request(`https://rendprop.com${path}`), ENV, ctx),
      new Promise((_, reject) => { watchdog = realSetTimeout(() => reject(new Error("outer test watchdog")), 1000); }),
    ]);
    const text = await response.text();
    expect(response.status === expectedStatus, `[${path} ${label}] expected ${expectedStatus}, got ${response.status}`);
    expect(response.headers.get("cache-control") === "no-store", `[${path} ${label}] no-store`);
    expect(fetches === 1, `[${path} ${label}] exactly one upstream request, no retries`);
    expect(requestInit.signal instanceof AbortSignal, `[${path} ${label}] real abort signal passed to fetch`);
    expect(requestInit.redirect === "manual", `[${path} ${label}] never forward auth through upstream redirects`);
    expect(delays.length === 1 && delays[0] === 8000, `[${path} ${label}] one 8000ms header+body deadline`);
    expect(timers.size === 0, `[${path} ${label}] deadline timer cleared`);
    if (expectedStatus !== 200) {
      expect(!text.includes("SYNTHETIC-PRIVATE") && !text.includes("upstream.invalid"), `[${path} ${label}] upstream bytes/secrets absent`);
      if (path.startsWith("/u/")) {
        expect(!/rendprop|<form|mailto:/i.test(text), `[${path} ${label}] MLS-neutral failure`);
        expect(response.headers.get("x-robots-tag") === "noindex, nofollow", `[${path} ${label}] MLS noindex retained`);
      } else expect(text.includes("RENDPROP"), `[${path} ${label}] branded failure`);
    }
    await verify({ specimen, response, text, requestInit });
  } catch (error) {
    failures.push(`[${path} ${label}] handler did not complete correctly: ${error.message}`);
  } finally {
    realClearTimeout(watchdog);
    for (const timer of timers) realClearTimeout(timer);
    globalThis.setTimeout = realSetTimeout;
    globalThis.clearTimeout = realClearTimeout;
  }
}

for (const path of ["/f/customer", "/u/customer", "/a/customer"]) {
  const payload = path.startsWith("/a/") ? buildDemoPortfolio() : { ...buildDemoTour(), slug: "customer" };
  const json = JSON.stringify(payload);
  await run(path, "valid JSON", 200, () => ({ response: new Response(json, { headers: { "Content-Type": "application/json; charset=utf-8" } }) }));
  await run(path, "real absent", 404, () => ({ response: new Response("SYNTHETIC-PRIVATE-404", { status: 404 }) }));
  for (const status of [429, 500, 503]) {
    await run(path, `upstream ${status}`, 503, () => ({ response: new Response("SYNTHETIC-PRIVATE-UPSTREAM-FAILURE", { status }) }));
  }
  await run(path, "transport failure", 503, () => ({ fetch() { throw new Error("SYNTHETIC-PRIVATE-TRANSPORT"); } }));
  await run(path, "redirect refused", 502, () => ({ response: new Response(null, { status: 302, headers: { Location: "https://SYNTHETIC-PRIVATE-redirect.invalid/" } }) }));
  await run(path, "invalid JSON", 502, () => ({ response: new Response("{SYNTHETIC-PRIVATE-BAD-JSON", { headers: { "Content-Type": "application/json" } }) }));
  for (const malformed of ["null", "[]", "{}", '{"slug":7,"agent_card":[]}']) {
    await run(path, `invalid shape ${malformed}`, 502, () => ({ response: new Response(malformed, { headers: { "Content-Type": "application/json" } }) }));
  }
  await run(path, "invalid UTF-8", 502, () => ({ response: new Response(new Uint8Array([0xff]), { headers: { "Content-Type": "application/json" } }) }));
  await run(path, "empty 204", 502, () => ({ response: new Response(null, { status: 204 }) }));
  const broken = path.startsWith("/a/") ? { ...payload, tours: [null] } : { ...payload, chapters: [null] };
  await run(path, "malformed collection entries", 502, () => ({ response: new Response(JSON.stringify(broken)) }));

  // Exact cap is valid JSON padded with whitespace, not an enormous image or
  // object graph. Same multibyte payload proves counting bytes, not JS chars.
  const padded = encoder.encode(json + " ".repeat(LIMIT - encoder.encode(json).length));
  await run(path, "exact decoded cap", 200, () => streamed(padded, { chunkSize: 32 * 1024 }));
  await run(path, "one byte over decoded cap, false Content-Length", 502,
    () => streamed(encoder.encode(json + " ".repeat(LIMIT + 1 - encoder.encode(json).length)), { stalled: true }),
    ({ specimen }) => expect(specimen.state.cancelled, `[${path}] oversized body cancelled before parsing`));
  await run(path, "cumulative cap across small chunks", 502,
    () => streamed(encoder.encode(json + " ".repeat(LIMIT + 1 - encoder.encode(json).length)), { stalled: true, chunkSize: 32 * 1024 }),
    ({ specimen }) => expect(specimen.state.cancelled, `[${path}] cumulative oversized body cancelled`));
  await run(path, "multibyte body over cap", 502,
    () => streamed(encoder.encode(json + "é".repeat(LIMIT / 2)), { stalled: true }),
    ({ specimen }) => expect(specimen.state.cancelled, `[${path}] oversized multibyte body cancelled`));
  await run(path, "body read error", 503, () => streamed(null, { error: true }));
  await run(path, "finite empty chunks preserve valid JSON", 200, () => streamed(encoder.encode(json), { emptyChunks: 64 }));
  await run(path, "too many no-progress chunks", 502, () => streamed(encoder.encode(json), { emptyChunks: 65 }),
    ({ specimen }) => expect(specimen.state.cancelled, `[${path}] no-progress stream cancelled`));
  await run(path, "headers never arrive", 503, () => ({ fetch: () => new Promise(() => {}) }),
    ({ requestInit }) => expect(requestInit.signal.aborted, `[${path}] timed-out fetch aborted`));
  await run(path, "late response after deadline", 503, () => {
    const late = streamed(encoder.encode(json));
    late.fetch = () => new Promise((resolve) => { late.resolve = resolve; });
    return late;
  }, async ({ specimen, requestInit }) => {
    expect(requestInit.signal.aborted, `[${path}] late fetch was aborted`);
    specimen.resolve(specimen.response);
    await new Promise((resolve) => realSetTimeout(resolve, 1));
    expect(specimen.state.cancelled, `[${path}] late response is cancelled, never parsed/rendered`);
  });
  await run(path, "body stalls and cancel never settles", 503,
    () => streamed(encoder.encode("{"), { stalled: true, cancelStalls: true }),
    ({ specimen, requestInit }) => {
      expect(specimen.state.cancelled, `[${path}] stalled body cancellation attempted`);
      expect(requestInit.signal.aborted, `[${path}] body deadline aborts original fetch`);
    });
}

expect(cases === 75, `expected all 75 actual-handler cases, got ${cases}`);
if (failures.length) {
  console.error(`FAIL upstream checks: ${failures.length} failures / ${checks} assertions / ${cases} cases`);
  for (const failure of failures) console.error(`  ${failure}`);
  process.exitCode = 1;
} else console.log(`PASS upstream checks: ${checks} assertions / ${cases} cases / 0 skipped`);
