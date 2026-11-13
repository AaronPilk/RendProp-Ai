import {createHash} from "node:crypto";
import {writeFile} from "node:fs/promises";
import {join} from "node:path";

// First fixed-original export only, behind --media-trace. This observes native
// recorder phases; it never supplies an export clock, frame, or verdict.
export const MEDIA_TRACE_NAMES = [
  "VideoTrackRecorderImpl::OnEncoderSupportKnown",
  "VideoTrackRecorderImpl::OnVideoFrame",
  "VideoTrackRecorderImpl::ProcessOneVideoFrame",
  "VideoTrackRecorderImpl::InitializeEncoder",
  "Encoder::StartFrameEncode",
  "PreEncodeFrame",
  "MediaRecorderEncoderWrapper::CreateAndInitialize",
  "MediaRecorderEncoderWrapper::InitizalizeDone",
  "MediaRecorderEncoderWrapper::EncodeFrame",
  "MediaRecorderEncoderWrapper::OutputEncodeData",
];
export const MEDIA_TRACE_LIMITS = Object.freeze({bufferKiB: 4096, rawBytes: 8 * 1024 * 1024,
  events: 32000, phaseProjection: 1000, stdoutPhaseEvents: 120, captureMs: 20000,
  finishMs: 6000, sessionMs: 2500, startMs: 2500, chunkBytes: 262144, chunkReads: 40});
const nameSet = new Set(MEDIA_TRACE_NAMES);
const startPhases = new Set(["B", "X", "I", "i"]);

const errorClass = error => {
  try {return typeof error?.name === "string" ? error.name.slice(0, 40) : "Error";}
  catch {return "UnknownError";}
};
const finite = value => typeof value === "number" && Number.isFinite(value);
const timed = async (promise, ms) => {
  let timer;
  try {return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("Media trace deadline")), Math.max(1, ms));
  })]);}
  finally {clearTimeout(timer);}
};

// Pure projection of a complete CDP trace. It counts exact source phase names
// and preserves at most 1000 scalar events in the private receipt. A missing
// clock bracket means no first-recorder-start attribution can be claimed.
export function projectMediaTrace(trace, syncId, clockMarker, limits = MEDIA_TRACE_LIMITS) {
  if (!Array.isArray(trace?.traceEvents)) return {status: "invalid-event-shape"};
  const eventCount = trace.traceEvents.length;
  if (eventCount > limits.events) return {status: "incomplete-event-limit", eventCount};
  const markers = trace.traceEvents.filter(event => event?.name === "clock_sync" &&
    event.args?.sync_id === syncId && finite(event.ts));
  const validBracket = finite(clockMarker?.beforeMs) && finite(clockMarker?.afterMs) &&
    clockMarker.afterMs >= clockMarker.beforeMs && clockMarker.afterMs - clockMarker.beforeMs <= 2 * 1000 / 30;
  const alignment = {available: markers.length === 1 && validBracket,
    markerCount: markers.length, uncertaintyMs: validBracket ? clockMarker.afterMs - clockMarker.beforeMs : null,
    exactMappingClaim: false};
  const counts = Object.fromEntries(MEDIA_TRACE_NAMES.map(name => [name, 0]));
  const edges = Object.fromEntries(MEDIA_TRACE_NAMES.map(name => [name, {firstUs: null, lastUs: null}]));
  const phases = [];
  let matched = 0;
  for (const event of trace.traceEvents) {
    if (!nameSet.has(event?.name) || !startPhases.has(event.ph) || !finite(event.ts) ||
      typeof event.cat !== "string" || !event.cat.split(",").includes("media")) continue;
    counts[event.name]++;
    edges[event.name].firstUs = Math.min(edges[event.name].firstUs ?? Infinity, event.ts);
    edges[event.name].lastUs = Math.max(edges[event.name].lastUs ?? -Infinity, event.ts);
    matched++;
    phases.push({name: event.name, ph: event.ph, tsUs: event.ts,
      pid: Number.isInteger(event.pid) ? event.pid : null,
      tid: Number.isInteger(event.tid) ? event.tid : null});
  }
  phases.sort((a, b) => a.tsUs - b.tsUs);
  return {status: "projected", eventCount, matchedPhaseEvents: matched, phaseCounts: counts,
    phaseEdges: edges, phaseProjectionTruncated: matched > limits.phaseProjection, alignment,
    traceMarkerUs: alignment.available ? markers[0].ts : null,
    pageMarkerBeforeMs: alignment.available ? clockMarker.beforeMs : null,
    phaseEvents: phases.slice(0, limits.phaseProjection)};
}

export function summarizeMediaTrace(facts, attemptTrace, limits = MEDIA_TRACE_LIMITS) {
  const start = Array.isArray(attemptTrace) ? attemptTrace.find(row => row?.event === "start.call")?.at : null;
  const aligned = facts?.clockAlignment?.available === true && finite(start);
  const relative = event => Number(((facts.clockMarker.beforeMs +
    (event.tsUs - facts.clockAlignment.traceMarkerUs) / 1000) - start).toFixed(3));
  const first = aligned ? (facts.phaseEvents ?? []).filter(event => {
    const ms = relative(event); return ms >= 0 && ms <= 2000;
  }).slice(0, limits.stdoutPhaseEvents).map(event => ({name: event.name, atMs: relative(event)})) : [];
  const phaseTiming = aligned ? Object.fromEntries(MEDIA_TRACE_NAMES.map(name => {
    const edge = facts.phaseEdges?.[name];
    const toRelative = tsUs => finite(tsUs) ? Number(((facts.clockMarker.beforeMs +
      (tsUs - facts.clockAlignment.traceMarkerUs) / 1000) - start).toFixed(3)) : null;
    const bins = Array.from({length: 20}, () => 0);
    for (const event of facts.phaseEvents ?? []) if (event.name === name) {
      const ms = relative(event);
      if (ms >= 0 && ms < 2000) bins[Math.floor(ms / 100)]++;
    }
    return [name, {firstMs: toRelative(edge?.firstUs), lastMs: toRelative(edge?.lastUs),
      firstTwoSeconds100MsBins: bins}];
  })) : null;
  return {status: facts?.status ?? "unavailable", stopReason: facts?.stopReason ?? null,
    traceComplete: facts?.traceComplete === true, dataLossOccurred: facts?.dataLossOccurred ?? null,
    cleanupComplete: facts?.cleanupComplete === true,
    eventCount: facts?.eventCount ?? null, matchedPhaseEvents: facts?.matchedPhaseEvents ?? null,
    phaseCounts: facts?.phaseCounts ?? null, phaseProjectionTruncated: facts?.phaseProjectionTruncated === true,
    firstRecorderStartAligned: aligned, bracketUncertaintyMs: facts?.clockAlignment?.uncertaintyMs ?? null,
    phaseTiming, timingBinsComplete: aligned && facts.phaseProjectionTruncated !== true,
    firstTwoSeconds: first, firstTwoSecondsTruncated: aligned &&
      (facts.phaseEvents ?? []).filter(event => {const ms = relative(event); return ms >= 0 && ms <= 2000;}).length > first.length,
    issues: (facts?.issues ?? []).slice(0, 8)};
}

export async function startMediaTraceObserver({browser, page, artifacts, syncId, sourceHashes,
  rawFileName = "native-media-trace-fixed-original.raw.private.json", limits = MEDIA_TRACE_LIMITS}) {
  const facts = {status: "initializing", category: "media", passiveOnly: true,
    observationMayPerturbTiming: true, limits, sourceHashes: {...sourceHashes}, issues: []};
  let session, acquisitionPromise, acquisitionUncertain = false, attempted = false, started = false,
    stream, captureTimer, finishPromise, endPromise, resolveComplete;
  const complete = new Promise(resolve => {resolveComplete = resolve;});
  const issue = (stage, error) => {if (facts.issues.length < 8) facts.issues.push({stage, errorClass: errorClass(error)});};
  const stopCapture = reason => {
    if (endPromise || !attempted) return;
    facts.stopReason = reason;
    clearTimeout(captureTimer);
    try {endPromise = timed(session.send("Tracing.end"), 2500).catch(error => issue("end", error));}
    catch (error) {issue("end", error); endPromise = Promise.resolve();}
  };
  const finish = () => finishPromise ??= (async () => {
    stopCapture("case-finally");
    const deadline = Date.now() + limits.finishMs;
    const remaining = () => Math.max(1, deadline - Date.now());
    try {
      await endPromise;
      if (!started) {
        if (attempted) {
          try {const event = await timed(complete, Math.min(1000, remaining())); stream = event?.stream ?? stream;}
          catch {facts.streamCompletionUnobserved = true;}
        }
        facts.status = facts.status === "initializing" ? "unavailable-start" : facts.status;
        return facts;
      }
      const completed = await timed(complete, remaining());
      stream = completed?.stream;
      facts.dataLossOccurred = completed?.dataLossOccurred;
      if (typeof stream !== "string" || !stream || completed?.traceFormat !== "json" ||
        completed?.streamCompression && completed.streamCompression !== "none" ||
        typeof facts.dataLossOccurred !== "boolean") {facts.status = "unavailable-stream-format"; return facts;}
      const chunks = [];
      let bytes = 0, reads = 0, eof = false, truncated = false;
      while (!eof) {
        if (Date.now() >= deadline || ++reads > limits.chunkReads) throw new Error("Media trace drain bound");
        const part = await timed(session.send("IO.read", {handle: stream, size: limits.chunkBytes}), remaining());
        const data = Buffer.from(part.data, part.base64Encoded ? "base64" : "utf8");
        if (!data.length && part.eof !== true) throw new Error("Media trace made no progress");
        const room = limits.rawBytes - bytes;
        chunks.push(data.subarray(0, Math.max(0, room)));
        bytes += Math.min(room, data.length);
        eof = part.eof === true;
        if (data.length > room || bytes === limits.rawBytes && !eof) {
          facts.rawByteLimitReached = true;
          truncated = true;
          break;
        }
      }
      const raw = Buffer.concat(chunks, bytes);
      const rawPath = join(artifacts, rawFileName);
      await writeFile(rawPath, raw, {flag: "wx", mode: 0o600});
      facts.raw = {path: rawPath, bytes, sha256: createHash("sha256").update(raw).digest("hex"), completeStream: eof && !truncated};
      facts.traceComplete = eof && !truncated && facts.dataLossOccurred === false;
      if (!eof || truncated) {facts.status = "incomplete-byte-limit"; return facts;}
      const projection = projectMediaTrace(JSON.parse(raw.toString("utf8")), syncId, facts.clockMarker, limits);
      if (projection.status !== "projected") {facts.status = projection.status; facts.eventCount = projection.eventCount; return facts;}
      facts.eventCount = projection.eventCount;
      facts.matchedPhaseEvents = projection.matchedPhaseEvents;
      facts.phaseCounts = projection.phaseCounts;
      facts.phaseEdges = projection.phaseEdges;
      facts.phaseProjectionTruncated = projection.phaseProjectionTruncated;
      facts.phaseEvents = projection.phaseEvents;
      facts.clockAlignment = {...projection.alignment, traceMarkerUs: projection.traceMarkerUs};
      facts.status = projection.matchedPhaseEvents === 0 ? "captured-no-matched-phase" :
        facts.traceComplete && facts.stopReason === "outcome-observed" &&
        projection.alignment.available && !projection.phaseProjectionTruncated ? "captured" : "captured-incomplete";
      facts.causalConclusion = "UNKNOWN: native phase observations do not identify why encoded frames are absent";
      return facts;
    } catch (error) {issue("finish", error); facts.status = "unavailable-or-incomplete"; return facts;}
    finally {
      clearTimeout(captureTimer);
      let cleanupComplete = true;
      if (stream) {
        try {await timed(session.send("IO.close", {handle: stream}), 1000);}
        catch (error) {issue("stream-close", error); cleanupComplete = false;}
      }
      if (session) {
        try {await timed(session.detach(), 1500);}
        catch (error) {issue("detach", error); cleanupComplete = false;}
      }
      facts.cleanupComplete = cleanupComplete && !acquisitionUncertain && !facts.streamCompletionUnobserved;
      if (!facts.cleanupComplete && facts.status === "captured") facts.status = "captured-incomplete";
    }
  })();
  try {
    acquisitionPromise = Promise.resolve().then(() => browser.newBrowserCDPSession());
    try {session = await timed(acquisitionPromise, limits.sessionMs);}
    catch (error) {
      acquisitionUncertain = true;
      // An acquisition may resolve after its deadline. Detach that exact late
      // session when possible; the completed receipt still marks custody
      // uncertain because browser closure is the final backstop.
      void acquisitionPromise.then(late => timed(late.detach(), 1500)
        .then(() => {facts.lateSessionDetached = true;})
        .catch(lateError => issue("late-session-detach", lateError)),
      lateError => issue("late-session-acquisition", lateError));
      throw error;
    }
    session.on("Tracing.tracingComplete", value => {stream = value?.stream ?? stream; resolveComplete(value);});
    session.on("Tracing.bufferUsage", value => {
      const fullness = Math.max(value?.percentFull ?? 0, value?.value ?? 0);
      facts.maximumBufferFullness = Math.max(facts.maximumBufferFullness ?? 0, fullness);
      if (fullness >= .8 || (value?.eventCount ?? 0) >= limits.events)
        stopCapture("buffer-or-event-budget");
    });
    const available = await timed(session.send("Tracing.getCategories"), 2500);
    if (!Array.isArray(available?.categories) || !available.categories.includes("media")) {
      facts.status = "unavailable-required-category";
      return {facts, stopCapture, finish};
    }
    attempted = true;
    await timed(session.send("Tracing.start", {transferMode: "ReturnAsStream", streamFormat: "json",
      streamCompression: "none", bufferUsageReportingInterval: 100,
      traceConfig: {recordMode: "recordUntilFull", traceBufferSizeInKb: limits.bufferKiB,
        enableSampling: false, enableSystrace: false, enableArgumentFilter: true,
        includedCategories: ["media"]}}), limits.startMs);
    started = true;
    facts.status = "recording";
    captureTimer = setTimeout(() => stopCapture("capture-deadline"), limits.captureMs);
    try {
      const beforeMs = await timed(page.evaluate(() => performance.now()), 1000);
      await timed(session.send("Tracing.recordClockSyncMarker", {syncId}), 1000);
      const afterMs = await timed(page.evaluate(() => performance.now()), 1000);
      facts.clockMarker = {beforeMs, afterMs, exactMappingClaim: false};
    } catch (error) {issue("clock-marker", error);}
  } catch (error) {issue("start", error); facts.status = "unavailable-start";}
  return {facts, stopCapture, finish};
}
