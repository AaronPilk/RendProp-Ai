import assert from "node:assert/strict";
import test from "node:test";
// @ts-ignore Test helpers are plain ESM.
import {testExportDiagnosticsOption, startExportDiagnostics} from "./export-diagnostics.mjs";

test("export diagnostics require an explicit known flag and preserve fixture controls", () => {
  const allowed = ["--only-fixed", "--fault=omit-old-await"];
  const ordinary = testExportDiagnosticsOption(["--fault=omit-old-await"], allowed);
  assert.equal(ordinary.diagnostics.enabled, false);
  assert.deepEqual(ordinary.args, ["--fault=omit-old-await"]);
  const selected = testExportDiagnosticsOption(["--diagnostics", "--only-fixed"], allowed);
  assert.equal(selected.diagnostics.enabled, true);
  assert.deepEqual(selected.args, ["--only-fixed"]);
  assert.throws(() => testExportDiagnosticsOption(["--diagnostics", "--diagnostics"], allowed), /Duplicate/);
  assert.throws(() => testExportDiagnosticsOption(["--diagnostic"], allowed), /Unknown/);
  assert.throws(() => testExportDiagnosticsOption(["--diagnostics", "--skip-clock"], allowed), /Unknown/);
});

test("default starts zero tracing sessions and diagnostic workers, with no browser or load reads", async () => {
  const fail = () => { throw new Error("Disabled diagnostics touched a side effect"); };
  const unobservable = new Proxy({}, {get: fail});
  const {diagnostics} = testExportDiagnosticsOption([], []);
  const owner = await startExportDiagnostics({diagnostics, context: unobservable, page: unobservable,
    native: {artifacts: "unused"}, scheduling: true, readLoad: fail, factories: unobservable});
  assert.equal(owner.facts.enabled, false);
  assert.equal(owner.facts.nativeTrace, undefined);
  assert.equal(owner.facts.schedulingProbe, undefined);
  assert.equal(await owner.finish(), owner.facts);
  assert.equal(await owner.finish(), owner.facts);
});

test("opt-in owns each observer once and retains its facts through idempotent cleanup", async () => {
  const calls: string[] = [];
  const traceFacts = {status: "recording"};
  const nodeFacts = {status: "running"};
  const pageFacts = {status: "running"};
  const factories = {
    native: async () => { calls.push("native.start"); return {facts: traceFacts,
      finish: async () => { calls.push("native.finish"); traceFacts.status = "captured-required-spans"; }}; },
    node: () => { calls.push("node.start"); return {facts: nodeFacts,
      stop: async () => { calls.push("node.stop"); return {status: "stopped", maxGapMs: 41}; }}; },
    page: async () => { calls.push("page.start"); return pageFacts; },
    stopPage: async () => { calls.push("page.stop"); return {status: "stopped", maxGapMs: 45}; },
  };
  const owner = await startExportDiagnostics({diagnostics: {enabled: true}, context: {}, page: {}, native: {},
    scheduling: true, readLoad: () => { calls.push("load.read"); return {loadavg: [0, 0, 0]}; }, factories});
  assert.equal(owner.facts.nativeTrace, traceFacts);
  const [first, second] = await Promise.all([owner.finish(), owner.finish()]);
  assert.equal(first, second);
  assert.equal(first.nativeTrace.status, "captured-required-spans");
  assert.equal(first.schedulingProbe.page.maxGapMs, 45);
  assert.equal(first.schedulingProbe.node.maxGapMs, 41);
  assert.deepEqual(calls, ["native.start", "node.start", "page.start", "load.read", "native.finish", "page.stop", "node.stop"]);
});

for (const failure of ["page", "load"] as const) {
  test(`partial observer setup at ${failure} stops all acquired owners and preserves the setup error`, async () => {
    const calls: string[] = [], original = new Error(`setup-${failure}`);
    const factories = {
      native: async () => ({facts: {}, finish: async () => {calls.push("native.finish");}}),
      node: () => ({facts: {}, stop: async () => {calls.push("node.stop"); return {};}}),
      page: async () => {calls.push("page.start"); if (failure === "page") throw original; return {};},
      stopPage: async () => {calls.push("page.stop"); return {};},
    };
    await assert.rejects(startExportDiagnostics({diagnostics: {enabled: true}, context: {}, page: {}, native: {},
      scheduling: true, factories, readLoad: () => {calls.push("load.read"); throw original;}}), error => error === original);
    assert.deepEqual(calls, failure === "page"
      ? ["page.start", "native.finish", "node.stop"]
      : ["page.start", "load.read", "native.finish", "page.stop", "node.stop"]);
  });
}

test("rejecting observer cleanup still attempts every later stop exactly once", async () => {
  const calls: string[] = [], original = new Error("native-stop");
  const factories = {
    native: async () => ({facts: {}, finish: async () => {calls.push("native.finish"); throw original;}}),
    node: () => ({facts: {}, stop: async () => {calls.push("node.stop"); return {};}}),
    page: async () => ({}),
    stopPage: async () => {calls.push("page.stop"); return {};},
  };
  const owner = await startExportDiagnostics({diagnostics: {enabled: true}, context: {}, page: {}, native: {}, scheduling: true, factories});
  await assert.rejects(owner.finish(), error => error === original);
  await assert.rejects(owner.finish(), error => error === original);
  assert.deepEqual(calls, ["native.finish", "page.stop", "node.stop"]);
});

test("partial setup preserves its error even if cleanup rejects", async () => {
  const calls: string[] = [], original = new Error("page-start"), cleanup = new Error("native-stop");
  const factories = {
    native: async () => ({facts: {}, finish: async () => {calls.push("native.finish"); throw cleanup;}}),
    node: () => ({facts: {}, stop: async () => {calls.push("node.stop"); return {};}}),
    page: async () => {throw original;},
    stopPage: async () => {calls.push("page.stop"); return {};},
  };
  await assert.rejects(startExportDiagnostics({diagnostics: {enabled: true}, context: {}, page: {}, native: {},
    scheduling: true, factories}), error => error === original);
  assert.deepEqual(calls, ["native.finish", "node.stop"]);
});
