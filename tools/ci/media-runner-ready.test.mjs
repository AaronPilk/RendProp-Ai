import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { assessReadiness, parseArguments, POLICY, receiptJSON, runCLI, validateSample } from "./media-runner-ready.mjs";

const sample = changes => ({
  loadavg: [3, 2, 1], freemem: 700_000_000, totalmem: 7_516_192_768,
  cpus: 3, platform: "darwin", nodeVersion: "v22.23.3", ...changes,
});
const pins = {
  "tools/ci/media-runner-ready.mjs": "1".repeat(64),
  ".github/workflows/ci.yml": "2".repeat(64),
};

function fake({ sequence = [sample()], start = 0, onSample, onSleep } = {}) {
  let time = start, calls = 0;
  const sleeps = [];
  const readiness = {
    now: () => time,
    timestamp: () => "2026-10-19T00:00:00.000Z",
    sample: async () => {
      const index = calls++;
      if (onSample) time = onSample({ index, time });
      return structuredClone(sequence[Math.min(index, sequence.length - 1)]);
    },
    sleep: async milliseconds => {
      sleeps.push(milliseconds);
      time = onSleep ? onSleep({ time, milliseconds, calls }) : time + milliseconds;
    },
  };
  return { readiness, sleeps, calls: () => calls, time: () => time };
}

test("three consecutive eligible samples pass only after two fixed intervals", async () => {
  const f = fake();
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, true);
  assert.equal(result.reason, "THREE_CONSECUTIVE_ELIGIBLE_SAMPLES");
  assert.equal(result.samples.length, 3);
  assert.deepEqual(f.sleeps, [5_000, 5_000]);
  assert.equal(result.elapsedMilliseconds, 10_000);
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 300_000);
  assert.deepEqual(result.samples.map(s => s.consecutiveValidEligibleSamples), [1, 2, 3]);
  assert.equal(result.mediaTestInvocations, 0);
});

test("transient overload resets the streak rather than extending the original deadline", async () => {
  const f = fake({ sequence: [sample(), sample({ loadavg: [9, 1, 1] }), sample({ loadavg: [8, 4, 2] })] });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, true);
  assert.deepEqual(result.samples.map(s => s.consecutiveValidEligibleSamples), [1, 0, 1, 2, 3]);
  assert.equal(result.elapsedMilliseconds, 20_000);
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 300_000);
});

test("sustained overload past the old cutoff passes only after three eligible samples", async () => {
  const busy = sample({ loadavg: [9, 1, 1] });
  const f = fake({ sequence: [...Array.from({ length: 37 }, () => busy), sample()] });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, true);
  assert.equal(result.reason, "THREE_CONSECUTIVE_ELIGIBLE_SAMPLES");
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 300_000);
  assert.equal(result.elapsedMilliseconds, 195_000);
  assert.equal(result.samples.length, 40);
  assert(result.samples.slice(0, 37).every(entry => entry.busy === true));
  assert.deepEqual(result.samples.slice(-3).map(entry => entry.consecutiveValidEligibleSamples), [1, 2, 3]);
  assert(result.samples.slice(-3).every(entry => entry.oneMinuteLoadPerCPU <= POLICY.maximumOneMinuteLoadPerCPU));
});

test("the fixed load boundary is inclusive and scales only with valid CPU count", async () => {
  assert.equal((await assessReadiness(fake({ sequence: [sample({ cpus: 6, loadavg: [16, 0, 0] })] }).readiness)).passed, true);
  const f = fake({ sequence: [sample({ loadavg: [8.000001, 0, 0] })] });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, false);
  assert.equal(result.busy, true);
});

test("permanent overload fails at the absolute original deadline with a bounded sample count", async () => {
  const f = fake({ start: 1_234, sequence: [sample({ loadavg: [49.9, 33.9, 14.6] })] });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, false);
  assert.equal(result.reason, "ORIGINAL_DEADLINE_REACHED");
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 301_234);
  assert.equal(result.elapsedMilliseconds, 300_000);
  assert.equal(result.deadlineReached, true);
  assert.equal(result.busy, true);
  assert(result.samples.length <= 61);
  assert.equal(f.sleeps.reduce((a, b) => a + b, 0), 300_000);
  assert(f.sleeps.every(value => value > 0 && value <= 5_000));
});

test("a third healthy sample completing at the deadline cannot pass", async () => {
  const f = fake({ onSample: ({ index, time }) => index === 2 ? 300_000 : time });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.samples.length, 3);
  assert.equal(result.samples.at(-1).valid, true);
  assert.equal(result.samples.at(-1).busy, false);
  assert.equal(result.consecutiveValidEligibleSamples, 2);
  assert.equal(result.passed, false);
  assert.equal(result.reason, "ORIGINAL_DEADLINE_REACHED");
});

test("a late timer fails before another sample and does not reset the deadline", async () => {
  const f = fake({ onSleep: () => 320_000 });
  const result = await assessReadiness(f.readiness);
  assert.equal(f.calls(), 1);
  assert.equal(result.passed, false);
  assert.equal(result.reason, "ORIGINAL_DEADLINE_REACHED");
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 300_000);
});

test("remaining time bounds the last requested delay", async () => {
  const f = fake({ sequence: [sample({ loadavg: [9, 0, 0] })],
    onSample: ({ index, time }) => index === 0 ? 298_999 : time });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, false);
  assert.deepEqual(f.sleeps, [1_001]);
  assert.equal(result.reason, "ORIGINAL_DEADLINE_REACHED");
});

test("slow or anomalous clock progress cannot exceed the immutable 61-sample bound", async () => {
  const f = fake({ sequence: [sample({ loadavg: [9, 0, 0] })], onSleep: ({ time }) => time + 1 });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.reason, "MAXIMUM_SAMPLE_COUNT_REACHED");
  assert.equal(result.passed, false);
  assert.equal(f.calls(), 61);
  assert.equal(result.samples.length, 61);
  assert.equal(f.sleeps.length, 60);
  assert.equal(result.originalDeadlineMonotonicMilliseconds, 300_000);
});

test("a stalled monotonic clock fails after the first requested interval", async () => {
  const f = fake({ onSleep: ({ time }) => time });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.reason, "MONOTONIC_CLOCK_STALLED");
  assert.equal(result.passed, false);
  assert.equal(f.calls(), 1);
});

test("a backwards clock fails between samples", async () => {
  const f = fake({ start: 1_000, onSleep: () => 999 });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.reason, "MONOTONIC_CLOCK_MOVED_BACKWARDS");
  assert.equal(result.passed, false);
  assert.equal(f.calls(), 1);
});

test("a backwards clock inside sample collection fails before admission", async () => {
  const f = fake({ start: 1_000, onSample: () => 999 });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.reason, "MONOTONIC_CLOCK_MOVED_BACKWARDS");
  assert.equal(result.passed, false);
  assert.equal(result.samples.length, 1);
});

for (const value of [NaN, Infinity, -1]) test(`invalid initial clock ${String(value)} refuses without samples`, async () => {
  const f = fake();
  const result = await assessReadiness({ ...f.readiness, now: () => value });
  assert.equal(result.passed, false);
  assert.equal(result.reason, "INVALID_MONOTONIC_CLOCK");
  assert.equal(f.calls(), 0);
});

test("every valid sample retains all three loads, memory, CPU, platform and Node facts", async () => {
  const raw = sample({ loadavg: [1.125, 99.25, 0.0625] });
  const result = await assessReadiness(fake({ sequence: [raw] }).readiness);
  assert(result.samples.every(entry => JSON.stringify(entry.raw) === JSON.stringify(raw)));
  assert(result.samples.every(entry => entry.atUTC === "2026-10-19T00:00:00.000Z"));
});

const invalidCases = [
  [null, "MALFORMED_SAMPLE"], [[], "MALFORMED_SAMPLE"], [{ ...sample(), extra: true }, "MALFORMED_SAMPLE"],
  [sample({ platform: "linux" }), "UNSUPPORTED_PLATFORM"], [sample({ platform: "win32" }), "UNSUPPORTED_PLATFORM"],
  ...[0, -1, 1.5, "3", NaN, Infinity].map(cpus => [sample({ cpus }), "INVALID_CPU_COUNT"]),
  ...[[0, 0], [0, 0, 0, 0], [NaN, 0, 0], [0, Infinity, 0], [0, 0, -1], ["0", 0, 0]].map(loadavg => [sample({ loadavg }), "INVALID_LOAD_AVERAGE"]),
  ...[{ freemem: -1 }, { totalmem: 0 }, { totalmem: NaN }, { freemem: Infinity }, { freemem: 8_000_000_000 }].map(change => [sample(change), "INVALID_MEMORY_FACTS"]),
  ...[null, 22, "22", "v22.bad.1"].map(nodeVersion => [sample({ nodeVersion }), "INVALID_NODE_VERSION"]),
];
for (const [index, [raw, reason]] of invalidCases.entries()) test(`invalid native facts ${index}: ${reason} fail closed`, async () => {
  assert.equal(validateSample(raw), reason);
  const f = fake({ sequence: [raw] });
  const result = await assessReadiness(f.readiness);
  assert.equal(result.passed, false);
  assert.equal(result.reason, reason);
  assert.equal(result.samples.length, 1);
  assert.equal(f.sleeps.length, 0);
});

test("a native read exception is recorded and never retried", async () => {
  let calls = 0;
  const f = fake();
  const result = await assessReadiness({ ...f.readiness, sample: () => { calls++; throw new Error("CLOSED_SAMPLE_FAILURE"); } });
  assert.equal(result.passed, false);
  assert.equal(result.reason, "NATIVE_SAMPLE_FAILED");
  assert.equal(calls, 1);
  assert.equal(result.samples[0].sampleError, "CLOSED_SAMPLE_FAILURE");
});

test("a timer dependency failure is fail-closed and not retried", async () => {
  const f = fake();
  const result = await assessReadiness({ ...f.readiness, sleep: () => { throw new Error("CLOSED_TIMER_FAILURE"); } });
  assert.equal(result.passed, false);
  assert.equal(result.reason, "READINESS_DEPENDENCY_FAILED");
  assert.equal(f.calls(), 1);
});

test("policy is frozen and environment or extra injected options do not weaken it", async () => {
  assert(Object.isFrozen(POLICY));
  assert.throws(() => { POLICY.totalMilliseconds = 1; }, TypeError);
  const previous = process.env.MEDIA_RUNNER_MAX_LOAD;
  process.env.MEDIA_RUNNER_MAX_LOAD = "999999";
  try {
    const f = fake({ sequence: [sample({ loadavg: [9, 0, 0] })] });
    const result = await assessReadiness({ ...f.readiness, policy: { maximumOneMinuteLoadPerCPU: 999999 } });
    assert.equal(result.passed, false);
    assert.equal(result.policy.maximumOneMinuteLoadPerCPU, 8 / 3);
    assert.equal(result.policy.totalMilliseconds, 300_000);
    assert.equal(result.policy.requiredConsecutiveSamples, 3);
    assert.equal(result.policy.maximumSamples, 61);
  } finally {
    if (previous === undefined) delete process.env.MEDIA_RUNNER_MAX_LOAD;
    else process.env.MEDIA_RUNNER_MAX_LOAD = previous;
  }
});

test("CLI allows only one required output argument, never policy overrides", () => {
  assert(parseArguments(["--output", "receipt.json"]).endsWith("/receipt.json"));
  for (const args of [[], ["--help"], ["--output"], ["--output", ""], ["--output=receipt.json"],
    ["--output", "a", "--output", "b"], ["--output", "a", "--budget", "999"], ["--max-load", "99"],
    ["--output", "--threshold"], ["--output", "a\0b"]]) assert.throws(() => parseArguments(args), /Usage:/);
});

test("failed numeric evidence is explicit JSON rather than NaN silently becoming null", async () => {
  const result = await assessReadiness(fake({ sequence: [sample({ loadavg: [NaN, 0, 0] })] }).readiness);
  const json = JSON.parse(receiptJSON(result));
  assert.deepEqual(json.samples[0].raw.loadavg[0], { invalidNumber: "NaN" });
  assert.equal(json.passed, false);
});

test("CLI writes one exclusive 0600 JSON with fixed policy and both source pins", async () => {
  const root = await mkdtemp(join(tmpdir(), "closed-media-ready-"));
  try {
    const file = join(root, "receipt.json"), f = fake();
    const result = await runCLI(["--output", file], { readiness: f.readiness, hashes: async () => pins, errorOutput: () => {} });
    assert.equal(result, 0);
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    const text = await readFile(file, "utf8"), report = JSON.parse(text);
    assert.equal(report.passed, true);
    assert.equal(report.samples.length, 3);
    assert.deepEqual(report.sourceHashes, pins);
    assert.deepEqual(report.policy, POLICY);
    assert.equal(report.mediaTestInvocations, 0);
    let read = false;
    const second = await runCLI(["--output", file], { hashes: async () => { read = true; return pins; }, errorOutput: () => {} });
    assert.equal(second, 1);
    assert.equal(read, false);
    assert.equal(await readFile(file, "utf8"), text);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("CLI overload failure exits1 while retaining deadline, busy state and all raw samples", async () => {
  const root = await mkdtemp(join(tmpdir(), "closed-media-ready-"));
  try {
    const file = join(root, "receipt.json"), f = fake({ sequence: [sample({ loadavg: [49.9, 33.9, 14.6] })] });
    assert.equal(await runCLI(["--output", file], { readiness: f.readiness, hashes: async () => pins, errorOutput: () => {} }), 1);
    const report = JSON.parse(await readFile(file, "utf8"));
    assert.equal(report.passed, false);
    assert.equal(report.deadlineReached, true);
    assert.equal(report.busy, true);
    assert.equal(report.samples.length, f.calls());
    assert.deepEqual(report.samples[0].raw.loadavg, [49.9, 33.9, 14.6]);
    assert.deepEqual(report.sourceHashes, pins);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source-hash failure records refusal without sampling", async () => {
  const root = await mkdtemp(join(tmpdir(), "closed-media-ready-"));
  try {
    const file = join(root, "receipt.json"), f = fake();
    assert.equal(await runCLI(["--output", file], { readiness: f.readiness, hashes: async () => ({}), errorOutput: () => {} }), 1);
    const report = JSON.parse(await readFile(file, "utf8"));
    assert.equal(report.reason, "SOURCE_HASHES_UNAVAILABLE");
    assert.equal(report.passed, false);
    assert.equal(f.calls(), 0);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("an existing output or symlink is never overwritten or chmodded", async () => {
  const root = await mkdtemp(join(tmpdir(), "closed-media-ready-"));
  try {
    const original = join(root, "original.json"), link = join(root, "link.json");
    await writeFile(original, "ORIGINAL", { mode: 0o640 });
    await symlink(original, link);
    let calls = 0;
    const options = { hashes: async () => { calls++; return pins; }, errorOutput: () => {} };
    assert.equal(await runCLI(["--output", original], options), 1);
    assert.equal(await runCLI(["--output", link], options), 1);
    assert.equal(calls, 0);
    assert.equal(await readFile(original, "utf8"), "ORIGINAL");
    assert.equal((await stat(original)).mode & 0o777, 0o640);
  } finally { await rm(root, { recursive: true, force: true }); }
});
