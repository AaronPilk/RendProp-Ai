import {Worker} from "node:worker_threads";

// Test-only scheduling probes. They answer one question about a clock
// refusal: did only the audio/media pipeline stop, or did every thread stop?
// A dedicated Web Worker inside the renderer and a worker_thread inside the
// Node runner each keep a short loop going and record how late each
// iteration woke up. Neither touches the export, its clocks or any oracle.
// Both report in epoch milliseconds so their gaps can be placed next to the
// page's performance.now() readings (page ms = epoch ms - page timeOrigin).
export const SCHEDULING_GAP_THRESHOLDS_MS = [16, 33, 100];
const RETAINED_GAPS = 64;

// Shared loop body for both probes. `wait` is the per-iteration pause; the
// page worker uses a short spin then a timer yield (so it does not take a
// whole core from a 3-vCPU runner), the Node worker sleeps 1 ms via
// Atomics.wait. Wake-up lateness, not CPU use, is the measurement.
const PROBE_LOOP = `
const thresholds = ${JSON.stringify(SCHEDULING_GAP_THRESHOLDS_MS)}, retained = ${RETAINED_GAPS};
const buckets = {under1Ms: 0, under4Ms: 0, under16Ms: 0, over16Ms: 0, over33Ms: 0, over100Ms: 0};
const gaps = {over16Ms: [], over33Ms: [], over100Ms: []};
const summary = {iterations: 0, maxGapMs: 0, maxGapAtEpochMs: null, startedAtEpochMs: null, stoppedAtEpochMs: null,
  timeOriginEpochMs: performance.timeOrigin, thresholdsMs: thresholds, retainedPerBucket: retained, buckets, gaps, truncated: {over16Ms: 0, over33Ms: 0, over100Ms: 0}};
let previous = null, stopped = false;
function record(now) {
  summary.iterations++;
  if (previous !== null) {
    const gap = now - previous, epoch = performance.timeOrigin + now;
    if (gap < 1) buckets.under1Ms++; else if (gap < 4) buckets.under4Ms++; else if (gap < 16) buckets.under16Ms++;
    else { buckets.over16Ms++; if (gap > 33) buckets.over33Ms++; if (gap > 100) buckets.over100Ms++; }
    if (gap > summary.maxGapMs) { summary.maxGapMs = gap; summary.maxGapAtEpochMs = epoch; }
    for (const [limit, key] of [[16, "over16Ms"], [33, "over33Ms"], [100, "over100Ms"]]) {
      if (gap <= limit) continue;
      if (gaps[key].length < retained) gaps[key].push({gapMs: gap, fromEpochMs: epoch - gap, toEpochMs: epoch}); else summary.truncated[key]++;
    }
  }
  previous = now;
}
function finish() { stopped = true; summary.stoppedAtEpochMs = performance.timeOrigin + performance.now(); return summary; }
summary.startedAtEpochMs = performance.timeOrigin + performance.now();
`;

const PAGE_WORKER_SOURCE = `${PROBE_LOOP}
// Spin for about one millisecond, then yield through a timer. Chromium clamps
// nested timers to 4 ms, so the nominal cadence is ~1-5 ms and a gap above
// 16 ms means this worker thread was not scheduled, whatever the cause.
function spin() {
  if (stopped) return;
  const until = performance.now() + 1;
  do { record(performance.now()); } while (performance.now() < until);
  setTimeout(spin, 0);
}
self.onmessage = event => { if (event.data === "stop") self.postMessage(finish()); };
spin();
`;

const NODE_WORKER_SOURCE = `${PROBE_LOOP}
const {parentPort} = require("node:worker_threads");
const cell = new Int32Array(new SharedArrayBuffer(4));
parentPort.on("message", message => { if (message === "stop") { parentPort.postMessage(finish()); parentPort.close(); } });
// Sleep one millisecond per iteration; the loop itself costs almost nothing,
// so a late wake-up is scheduler or hypervisor lateness, not self-inflicted.
(function tick() { if (stopped) return; Atomics.wait(cell, 0, 0, 1); record(performance.now()); setImmediate(tick); })();
`;

function bucketsOverview(summary) {
  return summary ? {iterations: summary.iterations, maxGapMs: summary.maxGapMs, over16Ms: summary.buckets.over16Ms,
    over33Ms: summary.buckets.over33Ms, over100Ms: summary.buckets.over100Ms} : null;
}

// Runner-side probe. stop() resolves to the summary; it never throws.
export function startNodeSchedulingProbe() {
  const facts = {kind: "node-worker-thread", wait: "Atomics.wait 1 ms", observationMayPerturbTiming: true, status: "starting", issues: []};
  let worker;
  try {worker = new Worker(NODE_WORKER_SOURCE, {eval: true}); facts.status = "running";}
  catch (error) {facts.status = "unavailable-start"; facts.issues.push({stage: "start", errorClass: error?.name ?? "Error"}); return {facts, stop: async () => facts};}
  const failed = new Promise(resolve => worker.once("error", error => resolve({error})));
  return {facts, stop: async () => {
    if (facts.status !== "running") return facts;
    let timer;
    try {
      const replied = new Promise(resolve => worker.once("message", summary => resolve({summary})));
      const timedOut = new Promise(resolve => {timer = setTimeout(() => resolve({timeout: true}), 2000);});
      worker.postMessage("stop");
      const outcome = await Promise.race([replied, failed, timedOut]);
      if (outcome.summary) {Object.assign(facts, outcome.summary); facts.status = "stopped"; facts.overview = bucketsOverview(outcome.summary);}
      else {facts.status = outcome.timeout ? "unavailable-stop-timeout" : "unavailable-worker-error"; if (outcome.error) facts.issues.push({stage: "run", errorClass: outcome.error?.name ?? "Error"});}
    } catch (error) {facts.status = "unavailable-stop"; facts.issues.push({stage: "stop", errorClass: error?.name ?? "Error"});}
    finally {clearTimeout(timer); await worker.terminate().catch(() => {});}
    return facts;
  }};
}

// Page-side probe. Started from the test process; the worker lives in the
// page under window.__schedulingProbe and is stopped by stopPageSchedulingProbe.
export async function startPageSchedulingProbe(page) {
  const facts = {kind: "page-dedicated-worker", wait: "~1 ms spin then setTimeout(0)", observationMayPerturbTiming: true, status: "starting", issues: []};
  try {
    const started = await page.evaluate(source => {
      const url = URL.createObjectURL(new Blob([source], {type: "text/javascript"}));
      const worker = new Worker(url);
      const probe = {worker, url, errors: 0};
      worker.onerror = () => {probe.errors++;};
      window.__schedulingProbe = probe;
      return {pageTimeOriginEpochMs: performance.timeOrigin, startedAtPageMs: performance.now(), visibilityState: document.visibilityState,
        hardwareConcurrency: navigator.hardwareConcurrency ?? null};
    }, PAGE_WORKER_SOURCE);
    Object.assign(facts, started); facts.status = "running";
  } catch (error) {facts.status = "unavailable-start"; facts.issues.push({stage: "start", errorClass: error?.name ?? "Error"});}
  return facts;
}

export async function stopPageSchedulingProbe(page, facts) {
  if (!facts || facts.status !== "running") return facts;
  try {
    const result = await page.evaluate(() => new Promise(resolve => {
      const probe = window.__schedulingProbe;
      if (!probe) return resolve({missing: true});
      const timer = setTimeout(() => resolve({timeout: true, errors: probe.errors}), 2000);
      probe.worker.onmessage = event => {clearTimeout(timer); resolve({summary: event.data, errors: probe.errors,
        stoppedAtPageMs: performance.now(), visibilityState: document.visibilityState});};
      probe.worker.postMessage("stop");
    }));
    if (result.summary) {
      Object.assign(facts, result.summary, {workerErrors: result.errors, stoppedAtPageMs: result.stoppedAtPageMs, visibilityStateAtStop: result.visibilityState});
      // Page-scale copies of every retained gap so they read directly against
      // clock readings' atMs / trace `at` values.
      const toPage = epoch => epoch - facts.pageTimeOriginEpochMs;
      facts.maxGapAtPageMs = facts.maxGapAtEpochMs === null ? null : toPage(facts.maxGapAtEpochMs);
      for (const key of Object.keys(facts.gaps)) for (const gap of facts.gaps[key]) {gap.fromPageMs = toPage(gap.fromEpochMs); gap.toPageMs = toPage(gap.toEpochMs);}
      facts.status = "stopped"; facts.overview = bucketsOverview(result.summary);
    } else facts.status = result.missing ? "unavailable-missing" : "unavailable-stop-timeout";
    await page.evaluate(() => {const probe = window.__schedulingProbe; if (probe) {probe.worker.terminate(); URL.revokeObjectURL(probe.url); delete window.__schedulingProbe;}}).catch(() => {});
  } catch (error) {facts.status = "unavailable-stop"; facts.issues.push({stage: "stop", errorClass: error?.name ?? "Error"});}
  return facts;
}
