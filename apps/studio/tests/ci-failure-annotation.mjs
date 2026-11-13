// Node-only, post-verdict reporting. Never copy arbitrary receipt strings into
// workflow commands: private URLs and source paths belong in retained receipts.
const SUITES = new Set(["cloud-editor", "export-resume"]);
const VARIANTS = new Set(["fixed", "baseline", "sequential", "clock-baseline", "cadence-baseline", "late-frames"]);
const EXPECTED_CONTROLS = new Set(["baseline", "clock-baseline", "cadence-baseline"]);
const CODES = new Map([
  ["Audio and picture timing drifted during export. No download was created. Close other busy tabs and retry.", "AUDIO_TIMELINE_DRIFT"],
  ["Video frames were skipped while exporting. No download was created. Close other busy tabs and retry.", "CAPTURE_CADENCE_REFUSAL"],
  ["Encoded video frames were skipped. No download was created. Close other busy tabs and retry.", "ENCODED_CADENCE_REFUSAL"],
  ["The audio startup clock moved backwards.", "AUDIO_STARTUP_CLOCK_REFUSAL"],
]);
const CAUSE_NUMBERS = ["gapMilliseconds", "maxGapMilliseconds", "maxTransitionGapMilliseconds",
  "transitionMilliseconds", "framesCaptured", "minFrames", "windowMilliseconds", "maxLossSeconds",
  "frameIndex", "frameCount", "observed", "limit"];
const count = value => Array.isArray(value) ? Math.min(value.length, 1_000_000) : 0;
const numeric = (value, keys) => Object.fromEntries(keys.flatMap(key =>
  Number.isFinite(value?.[key]) && Math.abs(value[key]) <= 1_000_000_000
    ? [[key, Math.round(value[key] * 1_000_000) / 1_000_000]] : []));
export const escapeWorkflowData = value => value.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");

function observedRefusal(suite, receipt) {
  let observation;
  if (suite === "export-resume") {
    const attempt = (Array.isArray(receipt.attempts) ? receipt.attempts : []).slice(0, 32).find(value => typeof value?.error === "string");
    if (attempt) observation = { message: attempt.error, cause: attempt.errorCause,
      variant: VARIANTS.has(attempt.variant) ? attempt.variant : "unknown",
      mayBeExpectedControl: EXPECTED_CONTROLS.has(attempt.variant) };
  } else {
    for (const device of (Array.isArray(receipt.mediaTiming) ? receipt.mediaTiming : []).slice(0, 8)) {
      observation = [...(Array.isArray(device.clockRefusals) ? device.clockRefusals : []).slice(0, 4),
        ...(Array.isArray(device.cadenceRefusals) ? device.cadenceRefusals : []).slice(0, 4)]
        .find(value => typeof value?.message === "string");
      if (observation) break;
    }
  }
  if (!observation) return undefined;
  const cause = observation.cause;
  return { label: "first-observed-refusal-not-terminal-cause", code: CODES.get(observation.message) ?? "UNCLASSIFIED_OBSERVATION",
    ...(suite === "export-resume" ? { variant: observation.variant, mayBeExpectedControl: observation.mayBeExpectedControl } : {}),
    cause: numeric(cause, CAUSE_NUMBERS),
    ...(cause?.kind === "encoded-frame-cadence" ? { kind: "encoded-frame-cadence" } : {}),
    ...(["sample-duration", "start-gap", "density"].includes(cause?.rule) ? { rule: cause.rule } : {}),
    ...(["milliseconds", "frames-per-500ms"].includes(cause?.unit) ? { unit: cause.unit } : {}),
    readings: (Array.isArray(cause?.readings) ? cause.readings : []).slice(-2)
      .map(value => numeric(value, ["wall", "timeline", "audio", "drift"])) };
}

export function buildFailureAnnotation(suite, receipt) {
  if (!SUITES.has(suite)) return null;
  let failed = false;
  try {
    if (receipt?.status !== "failed") return null;
    failed = true;
    const failure = typeof receipt.failure === "string" ? receipt.failure.slice(0, 16_000) : "";
    const summary = { suite, status: "failed", checks: count(receipt.checks),
      completedExports: count(receipt.exportProbes), attempts: count(receipt.attempts), decodedRuns: count(receipt.runs),
      failureKind: /^locator\.click: Timeout \d+ms exceeded\./.test(failure) ? "UI_ACTION_TIMEOUT" : "TEST_FAILURE",
      ...(failure.includes("Advanced desktop editor") ? { locatorMention: "advanced-editor" } : {}),
      evidenceStage: suite === "export-resume"
        ? count(receipt.runs) ? "decoded-run-recorded" : count(receipt.attempts) ? "attempt-recorded" : "no-attempt-recorded"
        : count(receipt.exportProbes) ? "completed-export-recorded" : count(receipt.loadBeforeExport) ? "export-observation-recorded" : "no-completed-export-recorded",
      ...(typeof receipt.sourceBoundAtEnd === "boolean" ? { sourceBoundAtEnd: receipt.sourceBoundAtEnd } : {}),
      observedRefusal: observedRefusal(suite, receipt) };
    let data = JSON.stringify(summary);
    if (data.length > 1800) { delete summary.observedRefusal; summary.observationOmittedForSize = true; data = JSON.stringify(summary); }
    return `::error title=Rendprop Studio ${suite}::${escapeWorkflowData(data)}`;
  } catch {
    return failed ? `::error title=Rendprop Studio ${suite}::{"suite":"${suite}","status":"failed","diagnostics":"unavailable"}` : null;
  }
}

export function emitFailureAnnotation(suite, receipt, { githubActions = process.env.GITHUB_ACTIONS, write = console.log } = {}) {
  try {
    if (githubActions !== "true") return false;
    const line = buildFailureAnnotation(suite, receipt);
    if (!line) return false;
    write(line);
    return true;
  } catch { return false; } // Reporting cannot replace the suite's original failure.
}
