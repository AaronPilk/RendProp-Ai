#!/usr/bin/env node
// Operational admission only: low observed load does not prove native audio
// timing, and this helper never starts or retries a media test.
import { createHash } from "node:crypto";
import { open, readFile } from "node:fs/promises";
import os from "node:os";
import { resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

export const POLICY = Object.freeze({
  totalMilliseconds: 300_000,
  sampleIntervalMilliseconds: 5_000,
  requiredConsecutiveSamples: 3,
  maximumSamples: 61,
  maximumOneMinuteLoadPerCPU: 8 / 3,
  supportedPlatform: "darwin",
});

const SAMPLE_KEYS = Object.freeze([
  "loadavg", "freemem", "totalmem", "cpus", "platform", "nodeVersion",
]);

export function nativeSample() {
  return {
    loadavg: os.loadavg(),
    freemem: os.freemem(),
    totalmem: os.totalmem(),
    cpus: os.cpus().length,
    platform: process.platform,
    nodeVersion: process.version,
  };
}

export function validateSample(sample) {
  if (!sample || typeof sample !== "object" || Array.isArray(sample)
    || Object.keys(sample).length !== SAMPLE_KEYS.length
    || !SAMPLE_KEYS.every(key => Object.hasOwn(sample, key))) return "MALFORMED_SAMPLE";
  if (sample.platform !== POLICY.supportedPlatform) return "UNSUPPORTED_PLATFORM";
  if (!Number.isSafeInteger(sample.cpus) || sample.cpus < 1) return "INVALID_CPU_COUNT";
  if (!Array.isArray(sample.loadavg) || sample.loadavg.length !== 3
    || !sample.loadavg.every(value => Number.isFinite(value) && value >= 0)) return "INVALID_LOAD_AVERAGE";
  if (!Number.isFinite(sample.totalmem) || sample.totalmem <= 0
    || !Number.isFinite(sample.freemem) || sample.freemem < 0
    || sample.freemem > sample.totalmem) return "INVALID_MEMORY_FACTS";
  if (typeof sample.nodeVersion !== "string"
    || !/^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(sample.nodeVersion)) return "INVALID_NODE_VERSION";
  return null;
}

// Preserve non-JSON numeric/type failures explicitly, rather than silently
// serializing NaN/Infinity as null in a failed sample's evidence.
export function receiptJSON(value) {
  return JSON.stringify(value, (_key, item) => {
    if (typeof item === "number" && !Number.isFinite(item)) return { invalidNumber: String(item) };
    if (typeof item === "bigint") return { invalidType: "bigint", value: String(item) };
    if (typeof item === "undefined") return { invalidType: "undefined" };
    if (typeof item === "function" || typeof item === "symbol") return { invalidType: typeof item };
    return item;
  }, 2) + "\n";
}

function recordRaw(sample) {
  try { return JSON.parse(receiptJSON(sample)); }
  catch { return { rawEncoding: "UNSERIALIZABLE", type: typeof sample }; }
}

/** Dependencies are a closed-test seam, never CLI/environment policy options. */
export async function assessReadiness({
  sample = nativeSample,
  now = () => performance.now(),
  sleep = milliseconds => delay(milliseconds),
  timestamp = () => new Date().toISOString(),
} = {}) {
  const samples = [];
  let started, lastClock, deadline, consecutive = 0, lastBusy = null;
  const finish = (passed, reason, observedClock) => ({
    schema: "rendprop-media-runner-readiness-v1",
    passed,
    status: passed ? "passed" : "failed",
    reason,
    policy: POLICY,
    startedMonotonicMilliseconds: started ?? null,
    originalDeadlineMonotonicMilliseconds: deadline ?? null,
    elapsedMilliseconds: Number.isFinite(observedClock) && Number.isFinite(started)
      ? observedClock - started : null,
    deadlineReached: Number.isFinite(observedClock) && Number.isFinite(deadline) && observedClock >= deadline,
    busy: lastBusy,
    consecutiveValidEligibleSamples: consecutive,
    samples,
    scope: "Operational admission only; native-clock causality and export timing are not proven.",
    mediaTestInvocations: 0,
  });
  const clock = () => {
    const value = now();
    if (!Number.isFinite(value) || value < 0) throw new Error("INVALID_MONOTONIC_CLOCK");
    return value;
  };
  try {
    started = clock();
    lastClock = started;
    deadline = started + POLICY.totalMilliseconds;
    if (!Number.isFinite(deadline) || deadline <= started) return finish(false, "INVALID_ORIGINAL_DEADLINE", started);
    for (let index = 0; index < POLICY.maximumSamples; index++) {
      const before = clock();
      if (before < lastClock) return finish(false, "MONOTONIC_CLOCK_MOVED_BACKWARDS", before);
      if (index > 0 && before === lastClock) return finish(false, "MONOTONIC_CLOCK_STALLED", before);
      if (before >= deadline) return finish(false, "ORIGINAL_DEADLINE_REACHED", before);
      let raw;
      try { raw = await sample(); }
      catch (error) {
        samples.push({ index, atUTC: timestamp(), elapsedBeforeMilliseconds: before - started,
          sampleError: String(error?.message ?? error).slice(0, 500), valid: false });
        return finish(false, "NATIVE_SAMPLE_FAILED", before);
      }
      const entry = { index, atUTC: timestamp(), elapsedBeforeMilliseconds: before - started,
        raw: recordRaw(raw), valid: false };
      samples.push(entry);
      const after = clock();
      entry.elapsedAfterMilliseconds = after - started;
      if (after < before) return finish(false, "MONOTONIC_CLOCK_MOVED_BACKWARDS", after);
      const invalid = validateSample(raw);
      if (invalid) { entry.validationError = invalid; return finish(false, invalid, after); }
      entry.valid = true;
      entry.oneMinuteLoadPerCPU = raw.loadavg[0] / raw.cpus;
      lastBusy = entry.oneMinuteLoadPerCPU > POLICY.maximumOneMinuteLoadPerCPU;
      entry.busy = lastBusy;
      // A healthy sample completing at/after the original deadline cannot pass.
      if (after >= deadline) return finish(false, "ORIGINAL_DEADLINE_REACHED", after);
      consecutive = lastBusy ? 0 : consecutive + 1;
      entry.consecutiveValidEligibleSamples = consecutive;
      if (consecutive === POLICY.requiredConsecutiveSamples) return finish(true, "THREE_CONSECUTIVE_ELIGIBLE_SAMPLES", after);
      if (index + 1 === POLICY.maximumSamples) return finish(false, "MAXIMUM_SAMPLE_COUNT_REACHED", after);
      lastClock = after;
      // The deadline is fixed above; overload never extends it. A delayed timer
      // is checked before another native sample and cannot create a late pass.
      await sleep(Math.min(POLICY.sampleIntervalMilliseconds, deadline - after));
    }
    return finish(false, "MAXIMUM_SAMPLE_COUNT_REACHED", lastClock);
  } catch (error) {
    const reason = error?.message === "INVALID_MONOTONIC_CLOCK"
      ? "INVALID_MONOTONIC_CLOCK" : "READINESS_DEPENDENCY_FAILED";
    return { ...finish(false, reason, lastClock), dependencyError: String(error?.message ?? error).slice(0, 500) };
  }
}

export function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== "--output" || typeof argv[1] !== "string"
    || !argv[1].trim() || argv[1].startsWith("--") || argv[1].includes("\0")) {
    throw new Error("Usage: node tools/ci/media-runner-ready.mjs --output FILE");
  }
  return resolve(argv[1]);
}

export async function sourceHashes() {
  const locations = {
    "tools/ci/media-runner-ready.mjs": new URL(import.meta.url),
    ".github/workflows/ci.yml": new URL("../../.github/workflows/ci.yml", import.meta.url),
  };
  return Object.fromEntries(await Promise.all(Object.entries(locations).map(async ([name, url]) =>
    [name, createHash("sha256").update(await readFile(url)).digest("hex")])));
}

export async function runCLI(argv, { readiness = {}, hashes = sourceHashes, errorOutput = message => console.error(message) } = {}) {
  let output;
  try { output = parseArguments(argv); }
  catch (error) { errorOutput(error.message); return 1; }
  let file;
  try { file = await open(output, "wx", 0o600); }
  catch (error) {
    errorOutput(error.code === "EEXIST" ? "Readiness output already exists; nothing was overwritten." : "Readiness output could not be created.");
    return 1;
  }
  try {
    await file.chmod(0o600);
    let report;
    try {
      const pins = await hashes();
      const expected = ["tools/ci/media-runner-ready.mjs", ".github/workflows/ci.yml"];
      if (!pins || Object.keys(pins).length !== 2 || !expected.every(name => /^[a-f0-9]{64}$/.test(pins[name] ?? ""))) {
        throw new Error("SOURCE_HASHES_INVALID");
      }
      report = { ...await assessReadiness(readiness), sourceHashes: pins };
    } catch (error) {
      report = { schema: "rendprop-media-runner-readiness-v1", status: "failed", passed: false,
        reason: "SOURCE_HASHES_UNAVAILABLE", sourceHashes: null, policy: POLICY,
        samples: [], busy: null, deadlineReached: false, mediaTestInvocations: 0,
        error: String(error?.message ?? error).slice(0, 500) };
    }
    await file.writeFile(receiptJSON(report));
    await file.sync();
    return report.passed ? 0 : 1;
  } catch {
    errorOutput("Readiness receipt could not be completed; admission failed.");
    return 1;
  } finally { await file.close(); }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = await runCLI(process.argv.slice(2));
}
