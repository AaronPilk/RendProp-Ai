import {writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {join} from "node:path";

// Passive native Web Audio tracing shared by the Studio export suites. This
// owns no product clock/source/graph and never turns an export refusal into
// success. It was extracted unchanged from export-startup-browser.mjs; the
// only additions are the parameters (sync id, raw file name, source hashes)
// and the pure render-gap summary derived from the projected spans.
export const NATIVE_TRACE_CATEGORIES = ["webaudio", "disabled-by-default-webaudio.audionode"];
export const NATIVE_TRACE_SPAN_NAMES = ["AudioDestination::RequestRender", "RealtimeAudioDestinationHandler::Render", "MediaStreamAudioDestinationHandler::Process"];
export const NATIVE_TRACE_LIMITS = {bufferKiB: 1024, rawBytes: 2 * 1024 * 1024, events: 10000, captureMs: 20000, finishMs: 10000};
// A guarded editor export runs for seconds, not the startup case's ~2 s; the
// hosted startup trace reached 10 053 events (1.96 MB) in that window. These
// bounds keep the same policy (recordUntilFull, bounded drain, private raw
// file) with room for one whole export. Still bounded; still local-only.
export const NATIVE_TRACE_EXPORT_LIMITS = {bufferKiB: 16384, rawBytes: 48 * 1024 * 1024, events: 250000, captureMs: 45000, finishMs: 20000,
  chunkBytes: 1024 * 1024, chunkReads: 96};
const RENDER_GAP_THRESHOLDS_MS = [33, 100];

// Pure: longest idle gap between consecutive AudioDestination::RequestRender
// spans on one render thread, with counts above the fixed thresholds. The
// page-wall placement uses the clock-sync bracket only when it is available
// and carries that bracket's uncertainty. Evidence, not a verdict.
export function summarizeRenderGaps(spans, clockAlignment) {
  const name = NATIVE_TRACE_SPAN_NAMES[0];
  const threads = new Map();
  for (const span of spans) {
    if (span.name !== name) continue;
    const key = `${span.pid}:${span.tid}`;
    (threads.get(key) ?? threads.set(key, []).get(key)).push(span);
  }
  const summary = {spanName: name, thresholdsMs: RENDER_GAP_THRESHOLDS_MS, threads: [], longestGap: null};
  for (const [thread, list] of threads) {
    list.sort((a, b) => a.startUs - b.startUs);
    const counts = Object.fromEntries(RENDER_GAP_THRESHOLDS_MS.map(limit => [`over${limit}Ms`, 0]));
    let longest = null, longestInterval = 0;
    for (let index = 1; index < list.length; index++) {
      const previous = list[index - 1], current = list[index];
      const gapMs = (current.startUs - (previous.startUs + previous.durationUs)) / 1000;
      const intervalMs = (current.startUs - previous.startUs) / 1000;
      longestInterval = Math.max(longestInterval, intervalMs);
      for (const limit of RENDER_GAP_THRESHOLDS_MS) if (gapMs > limit) counts[`over${limit}Ms`]++;
      if (!longest || gapMs > longest.gapMs) longest = {gapMs, intervalMs, previousEndUs: previous.startUs + previous.durationUs, nextStartUs: current.startUs, index};
    }
    const entry = {thread, spans: list.length, longestGapMs: longest?.gapMs ?? null, longestStartToStartMs: list.length > 1 ? longestInterval : null, ...counts};
    summary.threads.push(entry);
    if (longest && (!summary.longestGap || longest.gapMs > summary.longestGap.gapMs)) summary.longestGap = {thread, ...longest};
  }
  if (summary.longestGap && clockAlignment?.available) {
    const {traceMarkerUs, pageWallBeforeMs, uncertaintyMs} = clockAlignment;
    const toPage = us => pageWallBeforeMs + (us - traceMarkerUs) / 1000;
    summary.longestGap.pageWall = {fromMs: toPage(summary.longestGap.previousEndUs), toMs: toPage(summary.longestGap.nextStartUs),
      bracketUncertaintyMs: uncertaintyMs, exactMappingClaim: false};
  }
  return summary;
}

// Returns {facts, finish}. `onFacts` runs synchronously before any await so a
// caller can attach the facts object to its receipt exactly as the startup
// suite did when this code lived there.
export async function startNativeTraceObserver({context, page, artifacts, syncId, rawFileName, sourceHashes, onFacts, limits = NATIVE_TRACE_LIMITS}) {
  const categories = NATIVE_TRACE_CATEGORIES;
  const names = NATIVE_TRACE_SPAN_NAMES;
  const chunkBytes = limits.chunkBytes ?? 65536, chunkReads = limits.chunkReads ?? 40;
  const facts = {status: "initializing", passiveOnly: true, observationMayPerturbTiming: true,
    categories, requiredSpanNames: names, limits, issues: [], sourceHashes: {...sourceHashes}};
  onFacts?.(facts);
  let session, attempted = false, started = false, timer, completeEvent, completeResolve, ending, finishing, stream;
  const completed = new Promise(resolve => {completeResolve = resolve;});
  const bounded = async (promise, ms) => {
    let timeout;
    try {return await Promise.race([promise, new Promise((_, reject) => {timeout = setTimeout(() => reject(new Error("Native trace observation deadline")), Math.max(1, ms));})]);}
    finally {clearTimeout(timeout);}
  };
  // Never persist protocol error text, trace arguments or device identifiers in
  // the receipt. Raw bytes use a bounded owned 0600 local file; current CI
  // artifact patterns do not upload it. No screenshots, network, stack
  // sampling, system tracing or arbitrary categories are enabled.
  const issue = (stage, error) => {if (facts.issues.length < 8) facts.issues.push({stage, errorClass: error?.name ?? "Error"});};
  const endOnce = reason => {
    if (!ending) {facts.stopReason = reason; ending = bounded(session.send("Tracing.end"), 2500).catch(error => issue("end", error));}
    return ending;
  };
  const finish = () => finishing ??= (async () => {
    clearTimeout(timer);
    const deadline = Date.now() + limits.finishMs;
    const remaining = () => Math.max(1, deadline - Date.now());
    try {
      if (attempted) await endOnce("case-finished");
      if (!started) return;
      completeEvent = await bounded(completed, remaining()); stream = completeEvent.stream;
      facts.dataLossOccurred = completeEvent.dataLossOccurred;
      if (typeof facts.dataLossOccurred !== "boolean" || typeof stream !== "string" || !stream || completeEvent.traceFormat !== "json" || completeEvent.streamCompression && completeEvent.streamCompression !== "none") {
        facts.status = "unavailable-stream-format"; return;
      }
      // No stream retrieval, JSON parsing or disk serialization happens until
      // the observed export has produced its result (or its poll failed).
      const chunks = []; let bytes = 0, eof = false, reads = 0;
      while (!eof) {
        if (Date.now() >= deadline) throw new Error("Native trace drain deadline");
        if (++reads > chunkReads) throw new Error("Native trace chunk limit");
        const part = await bounded(session.send("IO.read", {handle: stream, size: chunkBytes}), remaining());
        const data = Buffer.from(part.data, part.base64Encoded ? "base64" : "utf8");
        if (!data.length && part.eof !== true) throw new Error("Native trace made no progress");
        const room = limits.rawBytes - bytes;
        chunks.push(data.subarray(0, room)); bytes += Math.min(room, data.length); eof = part.eof === true;
        if (data.length > room || bytes === limits.rawBytes && !eof) {facts.rawByteLimitReached = true; break;}
      }
      const raw = Buffer.concat(chunks, bytes), path = join(artifacts, rawFileName);
      await writeFile(path, raw, {flag: "wx", mode: 0o600});
      facts.raw = {path, bytes, sha256: createHash("sha256").update(raw).digest("hex"), completeStream: eof};
      if (!eof) {facts.status = "incomplete-byte-limit"; return;}
      const parsed = JSON.parse(raw.toString("utf8"));
      if (!Array.isArray(parsed.traceEvents)) {facts.status = "unavailable-event-shape"; return;}
      // BEGIN pure native trace projection
      facts.eventCount = parsed.traceEvents.length;
      if (facts.eventCount > limits.events) {facts.status = "incomplete-event-limit"; return;}
      const markers = parsed.traceEvents.filter(event => event.name === "clock_sync" &&
        event.args?.sync_id === syncId && Number.isFinite(event.ts));
      const bridge = facts.clockMarker, maximumBracketMs = 2 * 1000 / 30;
      const bracketValid = bridge && Number.isFinite(bridge.pageWallBeforeMs) && Number.isFinite(bridge.pageWallAfterMs) &&
        bridge.pageWallAfterMs >= bridge.pageWallBeforeMs;
      facts.clockAlignment = {matchedMarkers: markers.length,
        available: markers.length === 1 && !!bracketValid && bridge.pageWallAfterMs - bridge.pageWallBeforeMs <= maximumBracketMs,
        maximumBracketMs, ...(bracketValid ? {pageWallBeforeMs: bridge.pageWallBeforeMs, pageWallAfterMs: bridge.pageWallAfterMs,
          uncertaintyMs: bridge.pageWallAfterMs - bridge.pageWallBeforeMs} : {}),
        ...(markers.length === 1 ? {traceMarkerUs: markers[0].ts} : {})};
      const spans = [], stacks = new Map();
      for (const event of [...parsed.traceEvents].sort((a, b) => a.ts - b.ts)) {
        if (!Number.isFinite(event.ts) || !Number.isInteger(event.pid) || !Number.isInteger(event.tid)) continue;
        const key = `${event.pid}:${event.tid}`, stack = stacks.get(key) ?? [];
        const add = (first, end) => {if (names.includes(first.name) && Number.isFinite(end) && end >= first.ts) spans.push({name: first.name, pid: first.pid, tid: first.tid, startUs: first.ts, durationUs: end - first.ts});};
        if (event.ph === "B") {stack.push(event); stacks.set(key, stack);}
        else if (event.ph === "E") {const first = stack.pop(); if (first) add(first, event.ts);}
        else if (event.ph === "X" && Number.isFinite(event.dur)) add(event, event.ts + event.dur);
      }
      facts.spans = spans;
      facts.spanCounts = Object.fromEntries(names.map(name => [name, spans.filter(span => span.name === name).length]));
      facts.unmatchedRequiredBegins = [...stacks.values()].flat().filter(event => names.includes(event.name)).length;
      facts.renderGapSummary = summarizeRenderGaps(spans, facts.clockAlignment);
      facts.status = facts.dataLossOccurred !== false || facts.stopReason !== "case-finished" || !facts.clockAlignment.available || facts.unmatchedRequiredBegins ||
        names.some(name => !facts.spanCounts[name]) ? "captured-incomplete" : "captured-required-spans";
      facts.causalConclusion = "UNKNOWN: native spans require time-aligned offline review; a passing export is not a plateau repair";
      // END pure native trace projection
    } catch (error) {issue("finish", error); facts.status = "unavailable-or-incomplete";}
    finally {
      if (stream) await bounded(session.send("IO.close", {handle: stream}), 1000).catch(error => issue("stream-close", error));
      if (session) await bounded(session.detach(), 1500).catch(error => issue("detach", error));
    }
  })();
  try {
    session = await bounded(context.newCDPSession(page), 2500);
    session.on("Tracing.tracingComplete", value => {completeEvent = value; completeResolve(value);});
    session.on("Tracing.bufferUsage", value => {
      const fullness = Math.max(value.percentFull ?? 0, value.value ?? 0);
      facts.maximumBufferFullness = Math.max(facts.maximumBufferFullness ?? 0, fullness);
      if (fullness >= .8 || (value.eventCount ?? 0) >= limits.events) void endOnce("buffer-or-event-budget");
    });
    const available = await bounded(session.send("Tracing.getCategories"), 2500);
    facts.categorySupport = Object.fromEntries(categories.map(category => [category, available.categories.includes(category)]));
    if (categories.some(category => !facts.categorySupport[category])) {facts.status = "unavailable-required-category"; return {facts, finish};}
    attempted = true;
    await bounded(session.send("Tracing.start", {transferMode: "ReturnAsStream", streamFormat: "json", streamCompression: "none",
      bufferUsageReportingInterval: 100, traceConfig: {recordMode: "recordUntilFull", traceBufferSizeInKb: limits.bufferKiB,
        enableSampling: false, enableSystrace: false, enableArgumentFilter: true, includedCategories: categories}}), 2500);
    started = true; facts.status = "recording";
    timer = setTimeout(() => {void endOnce("capture-deadline");}, limits.captureMs);
    // The bracket maps the trace marker to page wall time without rewriting
    // either clock. Unsupported markers remain explicitly unavailable.
    try {
      const before = await bounded(page.evaluate(() => performance.now()), 1000);
      await bounded(session.send("Tracing.recordClockSyncMarker", {syncId}), 1000);
      const after = await bounded(page.evaluate(() => performance.now()), 1000);
      facts.clockMarker = {syncId, pageWallBeforeMs: before, pageWallAfterMs: after, exactMappingClaim: false};
    } catch (error) {issue("clock-marker", error);}
  } catch (error) {issue("start", error); facts.status = "unavailable-start";}
  return {facts, finish};
}
