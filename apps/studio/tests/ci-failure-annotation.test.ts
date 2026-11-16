import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
// @ts-ignore Test reporting helpers are plain ESM.
import { buildFailureAnnotation, emitFailureAnnotation, escapeWorkflowData } from "./ci-failure-annotation.mjs";
const drift = "Audio and picture timing drifted during export. No download was created. Close other busy tabs and retry.";
const data = (line: string) => JSON.parse(line.slice(line.indexOf("::{") + 2));

test("only hosted failed receipts emit one bounded annotation", () => {
  const lines: string[] = [], write = (line: string) => lines.push(line);
  for (const status of ["passed", "running", undefined]) assert.equal(emitFailureAnnotation("export-resume", { status }, { githubActions: "true", write }), false);
  assert.equal(emitFailureAnnotation("export-resume", { status: "failed" }, { githubActions: "false", write }), false);
  assert.equal(emitFailureAnnotation("unknown", { status: "failed" }, { githubActions: "true", write }), false);
  assert.equal(emitFailureAnnotation("export-resume", { status: "failed", attempts: [] }, { githubActions: "true", write }), true);
  assert.equal(lines.length, 1); assert.equal(data(lines[0]).evidenceStage, "no-attempt-recorded");
});

test("observed clock operands are numeric and are not asserted to be terminal cause", () => {
  const receipt = { status: "failed", failure: "A later pixel assertion failed", runs: [{}], attempts: [{ variant: "baseline", error: drift,
    errorCause: { maxLossSeconds: .1136, readings: [{ wall: 1.9, timeline: 1.8, audio: 1.8, drift: .1 }, { wall: 1.92, timeline: 1.8, audio: 1.8, drift: .12 }] } }] };
  const original = structuredClone(receipt), summary = data(buildFailureAnnotation("export-resume", receipt));
  assert.equal(summary.evidenceStage, "decoded-run-recorded"); assert.equal(summary.failureKind, "TEST_FAILURE");
  assert.equal(summary.observedRefusal.code, "AUDIO_TIMELINE_DRIFT"); assert.equal(summary.observedRefusal.mayBeExpectedControl, true);
  assert.equal(summary.observedRefusal.label, "first-observed-refusal-not-terminal-cause");
  assert.equal(summary.observedRefusal.cause.maxLossSeconds, .1136); assert.equal(summary.observedRefusal.readings[1].audio, 1.8);
  assert.deepEqual(receipt, original);
});

test("cloud annotations distinguish completed evidence from an observed refusal", () => {
  const receipt = { status: "failed", failure: "locator.click: Timeout 10000ms exceeded. Advanced desktop editor", checks: [], exportProbes: [],
    mediaTiming: [{ clockRefusals: [{ message: drift, cause: { maxLossSeconds: .2 } }] }] };
  const summary = data(buildFailureAnnotation("cloud-editor", receipt));
  assert.equal(summary.evidenceStage, "no-completed-export-recorded"); assert.equal(summary.failureKind, "UI_ACTION_TIMEOUT");
  assert.equal(summary.locatorMention, "advanced-editor"); assert.equal(summary.observedRefusal.code, "AUDIO_TIMELINE_DRIFT");
});

test("all deliberately historical variants stay labeled without treating refusal as acceptable", () => {
  for (const variant of ["fixed", "baseline", "sequential", "clock-baseline", "cadence-baseline", "late-frames"]) {
    const summary = data(buildFailureAnnotation("export-resume", { status: "failed", attempts: [{ variant, error: drift }] }));
    assert.equal(summary.status, "failed");
    assert.equal(summary.observedRefusal.mayBeExpectedControl, ["baseline", "clock-baseline", "cadence-baseline"].includes(variant));
    assert(!Object.hasOwn(summary, "sourceBoundAtEnd"), "Missing verification is not reported as false verification");
  }
});

test("private strings, arbitrary error names and raw paths never reach annotations", () => {
  const secret = "https://private.invalid/file?token=SECRET%\r\n::error::INJECTED";
  const receipt = { status: "failed", failure: secret, visibleText: secret, errors: [secret], externalRequests: [secret], sourceHashes: { [secret]: secret },
    attempts: [{ variant: secret, errorName: secret, error: secret, errorCause: { secret, gapMilliseconds: 234.8, rule: secret, unit: secret,
      readings: [{ wall: 1, sourceURL: secret }] } }] };
  const line = buildFailureAnnotation("export-resume", receipt), summary = data(line);
  assert(!line.includes("SECRET") && !line.includes("private.invalid") && !line.includes("INJECTED"));
  assert.equal(summary.observedRefusal.variant, "unknown"); assert.equal(summary.observedRefusal.code, "UNCLASSIFIED_OBSERVATION");
  assert.deepEqual(summary.observedRefusal.cause, { gapMilliseconds: 234.8 }); assert.deepEqual(summary.observedRefusal.readings, [{ wall: 1 }]);
});

test("encoded cadence rules retain exact enum and finite numeric evidence", () => {
  const receipt = { status: "failed", mediaTiming: [{ cadenceRefusals: [{ message: "Encoded video frames were skipped. No download was created. Close other busy tabs and retry.",
    cause: { kind: "encoded-frame-cadence", rule: "density", unit: "frames-per-500ms", observed: 10, limit: 11, frameIndex: 11, frameCount: 29, gapMilliseconds: Infinity, maxLossSeconds: 1e20 } }] }] };
  const observed = data(buildFailureAnnotation("cloud-editor", receipt)).observedRefusal;
  assert.equal(observed.code, "ENCODED_CADENCE_REFUSAL"); assert.equal(observed.rule, "density"); assert.equal(observed.unit, "frames-per-500ms");
  assert.deepEqual(observed.cause, { frameIndex: 11, frameCount: 29, observed: 10, limit: 11 });
});

test("large observations remain bounded and workflow data cannot split commands", () => {
  const line = buildFailureAnnotation("export-resume", { status: "failed", attempts: [{ error: drift, variant: "fixed",
    errorCause: { readings: Array.from({ length: 10000 }, () => ({ wall: 123456.123456, timeline: 1, audio: 1, drift: 1 })) } }] });
  assert(Buffer.byteLength(line) <= 2048); assert.equal(line.split("\n").length, 1); assert.equal(data(line).observedRefusal.readings.length, 2);
  assert.equal(escapeWorkflowData("%\r\n::error::"), "%25%0D%0A::error::");
});

test("hostile diagnostic getters and failed writers preserve the original thrown error", () => {
  const receipt = { status: "failed", get attempts() { throw Error("SECRET"); } };
  const line = buildFailureAnnotation("export-resume", receipt); assert(!line.includes("SECRET")); assert.equal(data(line).diagnostics, "unavailable");
  const original = Error("original suite failure");
  assert.throws(() => { try { throw original; } finally { emitFailureAnnotation("export-resume", { status: "failed" }, { githubActions: "true", write() { throw Error("writer"); } }); } }, error => error === original);
});

test("both actual final reporters bind the helper and call it after cleanup and persistence", async () => {
  for (const [file, suite] of [["cloud-editor-browser.mjs", "cloud-editor"], ["export-resume-browser.mjs", "export-resume"]]) {
    const source = await readFile(new URL(file, import.meta.url), "utf8"), call = source.lastIndexOf(`emitFailureAnnotation("${suite}", receipt)`);
    assert(call > source.lastIndexOf("await browser?.close()")); assert(call > source.lastIndexOf("server.close("));
    assert(call > (suite === "cloud-editor" ? source.lastIndexOf('await writeFile(join(artifacts, "receipt.json")') : source.lastIndexOf("await persist()")));
    assert(source.includes('"tests/ci-failure-annotation.mjs"')); assert(call > source.lastIndexOf("console.log(JSON.stringify("));
  }
});
