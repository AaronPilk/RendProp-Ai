import assert from "node:assert/strict";
import {startNativeTraceObserver} from "./native-trace-observer.mjs";
import {startNodeSchedulingProbe, startPageSchedulingProbe, stopPageSchedulingProbe} from "./scheduling-probe.mjs";

// Diagnostic observers are deliberately separate from every export oracle.
// Even observation can compete with real capture on a small hosted runner.
export function testExportDiagnosticsOption(args, allowedArgs) {
  const selected = args.filter(argument => argument === "--diagnostics");
  assert(selected.length <= 1, "Duplicate --diagnostics option");
  const remaining = args.filter(argument => argument !== "--diagnostics");
  assert(remaining.every(argument => allowedArgs.includes(argument)), "Unknown export test option");
  return {args: remaining, diagnostics: {enabled: selected.length === 1, optInFlag: "--diagnostics", testOnly: true}};
}

export async function startExportDiagnostics({diagnostics, context, page, native, scheduling = false, readLoad,
  factories = {native: startNativeTraceObserver, node: startNodeSchedulingProbe, page: startPageSchedulingProbe, stopPage: stopPageSchedulingProbe}}) {
  const facts = {enabled: diagnostics.enabled, optInFlag: "--diagnostics", testOnly: true};
  // Do not read browser state, load counters, start tracing or create workers.
  if (!diagnostics.enabled) return {facts, finish: async () => facts};

  let trace, node, pageAcquired = false, finished;
  // Own cleanup before acquiring anything. One failed stop must not strand
  // another observer, and a setup error must retain its original identity.
  const owner = {facts, finish: () => finished ??= (async () => {
    let firstError;
    const stop = async operation => {
      try {await operation();} catch (error) {firstError ??= error;}
    };
    if (trace) await stop(() => trace.finish());
    if (pageAcquired) await stop(async () => {facts.schedulingProbe.page = await factories.stopPage(page, facts.schedulingProbe.page);});
    if (node) await stop(async () => {facts.schedulingProbe.node = await node.stop();});
    if (firstError) throw firstError;
    return facts;
  })()};
  try {
    trace = native ? await factories.native({context, page, ...native}) : undefined;
    if (trace) facts.nativeTrace = trace.facts;
    if (scheduling) {
      facts.schedulingProbe = {};
      node = factories.node();
      facts.schedulingProbe.node = node.facts;
      facts.schedulingProbe.page = await factories.page(page);
      pageAcquired = true;
      facts.schedulingProbe.loadBeforeRun = readLoad?.();
    }
    return owner;
  } catch (error) {
    try {await owner.finish();} catch (cleanupError) {facts.cleanupFailure = {name: cleanupError?.name ?? "Error"};}
    throw error;
  }
}
