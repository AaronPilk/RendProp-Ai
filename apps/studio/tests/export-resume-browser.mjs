import assert from "node:assert/strict";
import { assertBaselineStall } from "./export-baseline-refusal.mjs";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-export-resume-")), dist = join(artifacts, "dist");
const omitPaintRequest=process.argv.slice(2).includes('--fault=omit-per-paint-request');
const videoStages=process.argv.slice(2).includes('--diagnostic-video-stages');
const diagnosticPair=videoStages||process.argv.slice(2).includes('--diagnostic-late-frames-pair');
const diagnosticModes=videoStages?["getters-on"]:["getters-on","getters-off"];
const onlyFixed=process.argv.slice(2).includes('--only-fixed');
const omitOldAwait=process.argv.slice(2).includes('--fault=omit-old-await');
assert(process.argv.slice(2).every(argument=>argument==='--only-fixed'||argument==='--fault=omit-old-await'||argument==='--diagnostic-late-frames-pair'||argument==='--diagnostic-video-stages'||argument==='--fault=omit-per-paint-request'),"Unknown resume test option");
assert(!omitPaintRequest||videoStages&&!onlyFixed&&!omitOldAwait,"Per-paint omission is only a bounded native-stage diagnostic");
assert(!(onlyFixed&&omitOldAwait),"Historical omission control cannot select the fixed-only suite");
assert(!diagnosticPair || !onlyFixed && !omitOldAwait,"The diagnostic pair cannot select historical controls");
const variants=diagnosticPair?["late-frames"]:omitOldAwait?["baseline"]:onlyFixed?["fixed"]:["baseline", "sequential", "clock-baseline", "cadence-baseline", "fixed", "late-frames"];
// Two one-second notifications leave a clear regression beyond the unchanged
// 400 ms export tolerance, even when a cold encoder compresses its startup.
// The fixed exporter never registers this listener, so it receives no delay.
const resumeNotificationDelayMs = 1000;
const sourceHashes = Object.fromEntries(await Promise.all(["tests/export-resume-browser.mjs", "tests/export-baseline-refusal.mjs", ...["export", "recording-clock", "media", "model", "music", "finishing", "overlay-renderer"].map(name => `src/editor/${name}.ts`)].map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = { sourceHashes, variants, fault:omitPaintRequest?"omit-per-paint-request":omitOldAwait?"omit-old-await":null, historicalRecordingGuardIsolation:["baseline","clock-baseline"], cadenceFault: "Hold only nextExportFrame animation callbacks until cancellation in both cadence-baseline and late-frames; native timers and media playback are unchanged", proof: `Real exportLocalVideo, decoded synthetic originals and actual MP4/AAC. Resume notifications are delayed ${resumeNotificationDelayMs} ms, and export decoder readiness is delayed 600 ms. Independent negative controls restore the former resume await and per-boundary loading; fixed build uses the production exporter. Only the historical resume-await and photo-clock controls isolate the later per-segment RecordingClock; both retain startup readiness and original-audio loss admission. Actual frame PTS, audio timing and preparation cleanup are verified. No external requests or provider use.`, checks: [], attempts: [], runs: [], preparationFailures: [], errors: [], externalRequests: [], status: "running" };
if(diagnosticPair){
  receipt.proof="Exactly two synthetic late-frames+narrated exports in fixed getters-on/getters-off order. Every current late-frame MP4, PCM, timing, transition and cleanup assertion stays strict. Historical controls, preparation negatives and other variants are NOT executed in this diagnostic mode. Passing alone cannot establish a hosted plateau cause or full CI acceptance.";
  if(videoStages)receipt.proof="One cold synthetic late-frames+narrated export with the candidate per-composite capture request, or its exact compiled omission, plus Chrome153 native video-stage/audio spans and bounded passive paint observations. All existing media and clock oracles stay strict. No prewarm; missing stages/incomplete evidence remain inconclusive and RED.";
  receipt.historicalRecordingGuardIsolation=[];
}
let browser, server;
const persist = () => writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
async function startLateFrameNativeTrace(context, page, observerMode) {
  assert(["getters-on", "getters-off"].includes(observerMode));
  const syncId = observerMode === "getters-on" ? "resume-late-frames-getters-on-before-click" : "resume-late-frames-getters-off-before-click";
  const categories = ["webaudio", "disabled-by-default-webaudio.audionode", "audio", ...(videoStages?["media"]:[])];
  const optionalNames = ["AudioDestination::Render", "SetDetectSilenceIfNecessary", "RealtimeAudioDestinationHandler::SetSinkDescriptor", "RealtimeAudioDestinationHandler::SetSinkDescriptor_Status", "RealtimeAudioDestinationHandler::SetSinkDescriptor_Swap", "RendererWebAudioDeviceImpl::CreateAudioRendererSink", "AudioDestination::Start", "AudioDestination::Stop", "AudioDestination::Pause", "AudioDestination::Resume"];
  const instantNames = ["SilentSinkSuspender::TransitionSinks - fake_sink_.Start()", "SilentSinkSuspender::TransitionSinks - fake_sink_.Stop()", "RealtimeAudioDestinationHandler::SetSinkDescriptor_Swap"];
  const names = ["AudioDestination::RequestRender", "RealtimeAudioDestinationHandler::Render", "MediaStreamAudioDestinationHandler::Process"];
  const videoNames = ["VideoTrackRecorderImpl::VideoTrackRecorderImpl", "VideoTrackRecorderImpl::OnVideoFrame", "VideoTrackRecorderImpl::OnEncoderSupportKnown", "VideoTrackRecorderImpl::ProcessOneVideoFrame", "VideoTrackRecorderImpl::InitializeEncoder", "Encoder::StartFrameEncode", "MediaRecorderEncoderWrapper::EncodeFrame", "MediaRecorderEncoderWrapper::CreateAndInitialize", "MediaRecorderEncoderWrapper::InitizalizeDone", "MediaRecorderEncoderWrapper::OutputEncodeData", "VideoEncodeAcceleratorAdapter::EncodeOnAcceleratorThread"];
  const videoRequiredNames = ["VideoTrackRecorderImpl::VideoTrackRecorderImpl", "VideoTrackRecorderImpl::OnVideoFrame", "VideoTrackRecorderImpl::OnEncoderSupportKnown", "VideoTrackRecorderImpl::ProcessOneVideoFrame", "VideoTrackRecorderImpl::InitializeEncoder", "Encoder::StartFrameEncode", "MediaRecorderEncoderWrapper::EncodeFrame", "MediaRecorderEncoderWrapper::CreateAndInitialize", "MediaRecorderEncoderWrapper::InitizalizeDone", "MediaRecorderEncoderWrapper::OutputEncodeData"];
  const limits = {bufferKiB: 4096, rawBytes: 8 * 1024 * 1024, events: 40000, captureMs: 20000, finishMs: 10000};
  const facts = {status: "initializing", passiveOnly: true, observationMayPerturbTiming: true,
    categories, requiredSpanNames: names, ...(videoStages?{videoStageNames:videoNames,requiredVideoStageNames:videoRequiredNames}:{}), limits, issues: [], sourceHashes: {...receipt.sourceHashes}};
  (receipt.nativeTraces ??= {})[observerMode] = facts;
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
      // the selected case has settled (including its original refusal).
      const chunks = []; let bytes = 0, eof = false, reads = 0;
      while (!eof) {
        if (Date.now() >= deadline) throw new Error("Native trace drain deadline");
        if (++reads > 140) throw new Error("Native trace chunk limit");
        const part = await bounded(session.send("IO.read", {handle: stream, size: 65536}), remaining());
        const data = Buffer.from(part.data, part.base64Encoded ? "base64" : "utf8");
        if (!data.length && part.eof !== true) throw new Error("Native trace made no progress");
        const room = limits.rawBytes - bytes;
        chunks.push(data.subarray(0, room)); bytes += Math.min(room, data.length); eof = part.eof === true;
        if (data.length > room || bytes === limits.rawBytes && !eof) {facts.rawByteLimitReached = true; break;}
      }
      const raw = Buffer.concat(chunks, bytes), path = join(artifacts, `native-trace-late-frames-${observerMode}.raw.private.json`);
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
      const admittedSpan = event => [...names, ...optionalNames, ...(videoStages?videoNames:[])].includes(event.name) && typeof event.cat === "string" &&
        event.cat.split(",").includes(videoNames.includes(event.name)?"media":event.name === "MediaStreamAudioDestinationHandler::Process" ? "disabled-by-default-webaudio.audionode" : "webaudio");
      const numericFrames = event => {
        const fields = event.name === "AudioDestination::RequestRender" ? ["frames_requested", "frames_to_render"] :
          ["AudioDestination::Render", "RealtimeAudioDestinationHandler::Render"].includes(event.name) ? ["frames"] : [];
        return Object.fromEntries(fields.map(key => [key, Number.isSafeInteger(event.args?.[key]) && event.args[key] >= 0 && event.args[key] <= 32768 ? event.args[key] : null]));
      };
      for (const event of [...parsed.traceEvents].sort((a, b) => a.ts - b.ts)) {
        if (!Number.isFinite(event.ts) || !Number.isInteger(event.pid) || !Number.isInteger(event.tid)) continue;
        const key = `${event.pid}:${event.tid}`, stack = stacks.get(key) ?? [];
        const add = (first, end) => {if (admittedSpan(first) && Number.isFinite(end) && end >= first.ts) spans.push({name: first.name, pid: first.pid, tid: first.tid, startUs: first.ts, durationUs: end - first.ts, frameParameters: numericFrames(first)});};
        if (event.ph === "B") {stack.push(event); stacks.set(key, stack);}
        else if (event.ph === "E") {const first = stack.pop(); if (first) add(first, event.ts);}
        else if (event.ph === "X" && Number.isFinite(event.dur)) add(event, event.ts + event.dur);
      }
      facts.instants = parsed.traceEvents.filter(event => ["I", "i"].includes(event.ph) && instantNames.includes(event.name) && Number.isFinite(event.ts) && Number.isInteger(event.pid) && Number.isInteger(event.tid))
        .map(event => ({name:event.name, pid:event.pid, tid:event.tid, atUs:event.ts}));
      facts.optionalSpanCounts = Object.fromEntries(optionalNames.map(name => [name, spans.filter(span => span.name === name).length]));
      if(videoStages)facts.videoInstants=parsed.traceEvents.filter(event=>event.name==="PreEncodeFrame" && typeof event.cat==="string" && event.cat.split(",").includes("media") && ["I","i"].includes(event.ph) && Number.isFinite(event.ts) && Number.isInteger(event.pid) && Number.isInteger(event.tid))
        .map(event=>({name:event.name,pid:event.pid,tid:event.tid,atUs:event.ts,converted:typeof event.args?.converted==="boolean"?event.args.converted:null}));
      facts.sinkEventMeaning = "Optional events are source-backed observations only; missing events do not prove a transition was impossible, particularly with incomplete capture.";
      facts.spans = spans;
      // All grouping and sorting is after native recording has stopped. These
      // are callback-entry gaps, never invented missing-sample counts.
      const percentile = (values, p) => values.length ? [...values].sort((a,b)=>a-b)[Math.ceil(p * values.length)-1] : null;
      const distribution = values => ({count:values.length,minUs:values.length?Math.min(...values):null,
        medianUs:percentile(values,.5),p95Us:percentile(values,.95),maxUs:values.length?Math.max(...values):null});
      const groups = new Map();
      for(const span of spans) {
        if(!names.includes(span.name) && span.name!=="AudioDestination::Render")continue;
        const key=JSON.stringify([span.name,span.pid,span.tid]),values=groups.get(key)??[];
        values.push(span);groups.set(key,values);
      }
      facts.callbackGroups=[...groups.values()].map(values=>{
        values.sort((a,b)=>a.startUs-b.startUs);
        const intervals=values.slice(1).map((span,index)=>({previousStartUs:values[index].startUs,startUs:span.startUs,
          startGapUs:span.startUs-values[index].startUs,previousDurationUs:values[index].durationUs,
          idleAfterPreviousEndUs:Math.max(0,span.startUs-values[index].startUs-values[index].durationUs)}));
        return {name:values[0].name,pid:values[0].pid,tid:values[0].tid,spanCount:values.length,
          durations:distribution(values.map(span=>span.durationUs)),startGaps:distribution(intervals.map(row=>row.startGapUs)),
          longestIntervals:[...intervals].sort((a,b)=>b.startGapUs-a.startGapUs).slice(0,16),
          frameParameterAvailability:values.some(span=>Object.values(span.frameParameters).some(value=>value!==null))?"numeric-native-arguments-present":"unavailable-or-filtered"};
      });
      if(videoStages){
        facts.videoStageGroups=videoNames.flatMap(name=>{
          const groups=new Map();
          for(const span of spans.filter(span=>span.name===name)){const key=JSON.stringify([span.pid,span.tid]),values=groups.get(key)??[];values.push(span);groups.set(key,values);}
          return [...groups.values()].map(values=>{values.sort((a,b)=>a.startUs-b.startUs);const gaps=values.slice(1).map((span,index)=>span.startUs-values[index].startUs);return {name,pid:values[0].pid,tid:values[0].tid,count:values.length,firstStartUs:values[0].startUs,lastStartUs:values.at(-1).startUs,durations:distribution(values.map(span=>span.durationUs)),startGaps:distribution(gaps)};});
        });
        facts.videoStageCounts=Object.fromEntries(videoNames.map(name=>[name,spans.filter(span=>span.name===name).length]));
        facts.unmatchedVideoBegins=[...stacks.values()].flat().filter(event=>admittedSpan(event)&&videoNames.includes(event.name)).length;
        facts.videoStageStatus=facts.dataLossOccurred!==false || facts.stopReason!=="case-finished" || !facts.clockAlignment.available || facts.unmatchedVideoBegins || videoRequiredNames.some(name=>!facts.videoStageCounts[name])?"captured-incomplete":"captured-required-video-stages";
        facts.videoStageMeaning="Method spans distinguish input arrival, initialization callback and encoded output; they do not themselves prove OS wait/lock ownership or map one encoded chunk to one painted frame. Optional VEA absence may mean software encoding.";
      }
      facts.destinationSampleContinuity="UNKNOWN: Process trace has no sample-count/timestamp argument. Entry-gap distribution and partial encoded PCM may narrow continuity; neither proves OS descheduling or graph-lock ownership.";
      facts.spanCounts = Object.fromEntries(names.map(name => [name, spans.filter(span => span.name === name).length]));
      facts.unmatchedRequiredBegins = [...stacks.values()].flat().filter(event => admittedSpan(event) && names.includes(event.name)).length;
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
    if (categories.some(category => !facts.categorySupport[category])) {facts.status = "unavailable-required-category"; return {finish, facts};}
    attempted = true;
    await bounded(session.send("Tracing.start", {transferMode: "ReturnAsStream", streamFormat: "json", streamCompression: "none",
      bufferUsageReportingInterval: 100, traceConfig: {recordMode: "recordUntilFull", traceBufferSizeInKb: limits.bufferKiB,
        enableSampling: false, enableSystrace: false, enableArgumentFilter: true, includedCategories: categories}}), 2500);
    started = true; facts.status = "recording";
    timer = setTimeout(() => {void endOnce("capture-deadline");}, limits.captureMs);
    // The bracket maps the trace marker to page wall time without rewriting
    // either clock. Unsupported markers remain explicitly unavailable.
    try {
      // Use the fixed case/mode-specific marker declared above.
      const before = await bounded(page.evaluate(() => performance.now()), 1000);
      await bounded(session.send("Tracing.recordClockSyncMarker", {syncId}), 1000);
      const after = await bounded(page.evaluate(() => performance.now()), 1000);
      facts.clockMarker = {syncId, pageWallBeforeMs: before, pageWallAfterMs: after, exactMappingClaim: false};
    } catch (error) {issue("clock-marker", error);}
  } catch (error) {issue("start", error); facts.status = "unavailable-start";}
  return {finish, facts};
}

// BEGIN pure capture-supply observation
function observeCaptureSupply(attempt) {
  const native=attempt.nativeTrace,bridge=native?.clockAlignment;
  const frames=native?.videoStageGroups?.filter(group=>group.name==="VideoTrackRecorderImpl::OnVideoFrame")??[];
  const start=attempt.trace?.find(event=>event.event==="start.call"),pause=attempt.trace?.find(event=>event.event==="pause.call");
  const request=attempt.diagnosticRequests?.find(event=>event.phase==="recorder-start");
  const available=native?.videoStageStatus==="captured-required-video-stages" && bridge?.available===true && frames.length===1 &&
    [frames[0].firstStartUs,bridge.traceMarkerUs,bridge.pageWallBeforeMs,bridge.pageWallAfterMs,start?.at,pause?.at,request?.afterMs].every(Number.isFinite);
  if(!available)return {available:false,openingInputObserved:null,meaning:"Incomplete native/marker/page evidence; never assume first-frame supply."};
  const delta=(frames[0].firstStartUs-bridge.traceMarkerUs)/1000;
  const firstInputPageBracketMs=[bridge.pageWallBeforeMs+delta,bridge.pageWallAfterMs+delta];
  return {available:true,firstInputPageBracketMs,firstPauseMs:pause.at,initialRequestAfterMs:request.afterMs,
    requestToFirstInputBracketMs:firstInputPageBracketMs.map(value=>value-request.afterMs),
    openingInputObserved:firstInputPageBracketMs[1]<pause.at,
    completedOpeningPaintsBeforeFirstInput:(attempt.diagnosticPaints??[]).filter(paint=>paint.index===0&&paint.afterMs>start.at&&paint.afterMs<firstInputPageBracketMs[0]).length,
    meaning:"Native input reached this recorder before first pause only when the entire clock-bridge bracket precedes it. No point clock rebasing or encoder/PCM guarantee."};
}
// END pure capture-supply observation

// Stop-flushed native bytes are diagnostic evidence only. Never assign these
// bytes to fixture.result or the product download link, even after refusal.
async function retainDiagnosticPartial(page, observerMode) {
  try {
  const value = await page.evaluate(async () => {
    const f=window.fixture;
    if(f.exporting || f.tracks.some(track=>track.readyState!=="ended"))return {status:"unavailable-before-cleanup"};
    if(f.partialCapped)return {status:"incomplete-byte-or-chunk-limit",observedBytes:f.partialBytes};
    const blob=new Blob(f.partialChunks,{type:f.partialChunks.find(chunk=>chunk.type)?.type??"video/mp4"});
    if(!blob.size)return {status:"unavailable-no-native-data"};
    if(blob.size>8*1024*1024)return {status:"incomplete-byte-limit",observedBytes:blob.size};
    return {status:"stop-flushed-native-bytes",mime:blob.type,bytes:Array.from(new Uint8Array(await blob.arrayBuffer())),
      productResultStillNull:f.result===null,downloadStillHidden:document.querySelector("#download").hidden};
  });
  if(!value.bytes)return value;
  const raw=Buffer.from(value.bytes);assert(raw.length<=8*1024*1024);
  const directory=join(artifacts,"private-diagnostics");await mkdir(directory,{recursive:true,mode:0o700});
  const path=join(directory,`late-frames-${observerMode}.partial.mp4`);await writeFile(path,raw,{flag:"wx",mode:0o600});
  const {bytes,...facts}=value;
  return {...facts,path,bytes:raw.length,sha256:createHash("sha256").update(raw).digest("hex"),
    disposition:"Synthetic diagnostic partial only; never a product result/download. The dedicated diagnostic workflow explicitly uploads this file; repository artifact access applies, not a filename privacy guarantee."};
  } catch(error) {return {status:"unavailable-diagnostic-retention",errorClass:error?.name??"Error"};}
}


try {
  await writeFile(join(artifacts, "fixture.html"), '<!doctype html><html><head><meta charset="utf-8"></head><body><input id="sources" type="file" multiple><input id="voice" type="file"><button id="run">Export</button><a id="download" download="export.mp4" hidden>Download</a><script type="module" src="./fixture.ts"></script></body></html>');
  await writeFile(join(artifacts, "fixture.ts"), `
import {exportLocalVideo,exportFormats} from ${JSON.stringify(join(root, "src/editor/export.ts"))};
import {inspectFile} from ${JSON.stringify(join(root, "src/editor/media.ts"))};
import {validateDraft} from ${JSON.stringify(join(root, "src/editor/model.ts"))};
let sources=[],voice,narrated=false,url,exportController,decodeIndex=0;
const fixture=window.fixture={ready:false,error:null,result:null,trace:[],exporting:false,decodeDelays:[],revision:1,configure:(value,photoClockControl=false)=>{narrated=value;fixture.photoClockControl=photoClockControl;},cancel:()=>exportController?.abort(new Error("Fixture export cancelled")),
  delayDecode:async(signal,kind)=>{
    const index=decodeIndex++,delay=fixture.decodeDelays[index]??0;
    log("decode.start",{index,kind,delay});
    // Invalidate at the actual lookahead entry, before the current clip can
    // start another recording-clock interval. A host-side polling round trip
    // can arrive after an unrelated timing refusal on a busy runner.
    if(fixture.staleDecodeIndex===index){fixture.revision++;log("revision.changed",{index,revision:fixture.revision});}
    if(delay)await new Promise((resolve,reject)=>{
      const abort=()=>{clearTimeout(timer);signal.removeEventListener("abort",abort);log("decode.aborted",{index});reject(signal.reason);};
      const timer=setTimeout(()=>{signal.removeEventListener("abort",abort);log("decode.ready",{index});resolve();},delay);
      signal.addEventListener("abort",abort,{once:true});
    });
    if(fixture.decodeErrorIndex===index)throw new Error("Fixture decoder failure");
  }};
const nativeRAF=window.requestAnimationFrame.bind(window),nativeCancel=window.cancelAnimationFrame.bind(window),frameHandles=new Map();let frameID=0;
window.requestAnimationFrame=callback=>{
  if(!fixture.exporting||!(fixture.delayPhotoFrames&&fixture.frameClipIsPhoto))return nativeRAF(callback);
  const id=++frameID+1000000,handles={};frameHandles.set(id,handles);
  handles.frame=nativeRAF(time=>{handles.timer=setTimeout(()=>{frameHandles.delete(id);callback(time);},120);});return id;
};
window.cancelAnimationFrame=id=>{const handles=frameHandles.get(id);if(handles){if(handles.frame!==undefined)nativeCancel(handles.frame);clearTimeout(handles.timer);frameHandles.delete(id);if(handles.held)log("export.frame.cancelled",{id,index:handles.index});}else nativeCancel(id);};
// Model a throttled export animation scheduler without retiming media, decoder
// events or the timer path. Both paired variants receive the identical fault.
fixture.requestExportFrame=callback=>{
  if(!fixture.holdExportFrames)return window.requestAnimationFrame(time=>{log("export.frame.delivered",{index:fixture.frameClipIndex,time});callback(time);});
  const id=++frameID+1000000,handles={held:true,index:fixture.frameClipIndex};frameHandles.set(id,handles);
  log("export.frame.held",{id,index:handles.index});return id;
};
const NativeRecorder=MediaRecorder;
function log(event,extra={}){fixture.trace.push({event,at:performance.now(),...extra});}
// Read-only diagnostics: no extra timers, clock substitution or audio resume.
// Keep only the preceding read/wait; the existing trace retains each snapshot.
fixture.clockDiagnostics=(index,audio,phase)=>{
  const at=performance.now(),previous=fixture.previousClockRead;
  let outputTimestamp=null,outputTimestampUnavailable=false,outputTimestampCostMs=null,outputLatencyCostMs=null;
  const omitObserverAPIs=fixture.clockObserverMode==="getters-off";
  const timestampBegin=fixture.clockObserverMode==="default"?0:performance.now();
  try{
    const value=omitObserverAPIs?null:audio?.getOutputTimestamp?.();
    if(value&&Number.isFinite(value.contextTime)&&Number.isFinite(value.performanceTime))
      outputTimestamp={contextTime:value.contextTime,performanceTime:value.performanceTime};
  }catch{outputTimestampUnavailable=true;}
  if(fixture.clockObserverMode!=="default")outputTimestampCostMs=performance.now()-timestampBegin;
  const latencyBegin=fixture.clockObserverMode==="default"?0:performance.now(),outputLatency=fixture.clockObserverMode==="default"?null:omitObserverAPIs?null:audio?.outputLatency??null;
  if(fixture.clockObserverMode!=="default")outputLatencyCostMs=performance.now()-latencyBegin;
  const result={audioState:audio?.state??null,sampleRate:audio?.sampleRate??null,
    baseLatency:audio?.baseLatency??null,outputLatency:fixture.clockObserverMode==="default"?audio?.outputLatency??null:outputLatency,
    outputTimestamp,outputTimestampUnavailable,observerMode:fixture.clockObserverMode,outputTimestampCostMs,outputLatencyCostMs,observerAPIsIntentionallyOmitted:omitObserverAPIs,visibilityState:document.visibilityState,
    interReadMs:phase==="read"&&previous?.index===index?at-previous.at:null,
    frameWaitElapsedMs:phase==="read"&&fixture.clockWait?.index===index?at-fixture.clockWait.at:null,
    remainingAtWaitMs:phase==="read"&&fixture.clockWait?.index===index?fixture.clockWait.remainingMs:null};
  if(phase==="start")fixture.previousClockRead=undefined;
  if(phase==="read")fixture.previousClockRead={index,at};
  return result;
};
fixture.observeClockWait=(index,remainingMs)=>{fixture.clockWait={index,remainingMs,at:performance.now()};};
fixture.observeComposite=value=>{if(fixture.diagnosticPaints.length<256)fixture.diagnosticPaints.push(value);else fixture.diagnosticPaintsCapped=true;};
fixture.observeCaptureRequest=value=>{fixture.diagnosticRequestCount++;if(fixture.diagnosticRequests.length<256)fixture.diagnosticRequests.push(value);else fixture.diagnosticRequestsCapped=true;};
fixture.originalAudioLoss=(audio,audioStart,media,mediaStart,rate,info)=>{
  const loss=audio-audioStart-Math.max(0,media-mediaStart)/rate;
  log("original.audio.loss",{...info,audio,audioStart,media,mediaStart,rate,loss});
  return loss;
};
const NativeAudioContext=AudioContext;
window.AudioContext=class extends NativeAudioContext {constructor(...args){super(...args);fixture.audio=this;
  this.addEventListener("statechange",()=>{if(fixture.exporting)log("audio.statechange",{state:this.state,visibilityState:document.visibilityState});});
}};
// The exporter uses detached video elements, so observe them directly without
// retiming events, from the moment the export decoder creates them so that
// readiness before playback and the element state at each event are retained.
// A refused export has no MP4 to inspect; keep its media state.
const observedVideo=new WeakSet();
fixture.observe=video=>observeVideo(video);
function observeVideo(video){
  if(!(video instanceof HTMLVideoElement)||observedVideo.has(video))return;
  observedVideo.add(video);
  for(const event of ["waiting","stalled","playing","canplay","canplaythrough","ended","loadeddata","seeking","seeked","pause","emptied"])
    video.addEventListener(event,()=>{
      if(!fixture.exporting)return;
      log("media."+event,{sourceTime:video.currentTime,duration:video.duration,rate:video.playbackRate,
        readyState:video.readyState,networkState:video.networkState,paused:video.paused,ended:video.ended,
        buffered:Array.from({length:video.buffered.length},(_,index)=>[video.buffered.start(index),video.buffered.end(index)])});
    });
}
window.MediaRecorder=class extends NativeRecorder {
  constructor(...args){super(...args);fixture.tracks.push(...args[0].getTracks());
    if(fixture.collectDiagnosticPartial)super.addEventListener("dataavailable",event=>{
      if(!fixture.collectDiagnosticPartial || !event.data.size)return;
      if(fixture.partialEventCount<64){fixture.partialEventCount++;log("diagnostic.dataavailable",{bytes:event.data.size,recorderState:this.state});}
      fixture.partialBytes+=event.data.size;
      if(fixture.partialBytes>8*1024*1024 || fixture.partialChunks.length>=64){fixture.partialCapped=true;fixture.partialChunks=[];return;}
      if(!fixture.partialCapped)fixture.partialChunks.push(event.data);
    });for(const event of ["start","resume","pause","stop"])
    super.addEventListener(event,()=>log(event+".native",{state:this.state}));}
  start(...args){log("start.call",{state:this.state});const result=super.start(...args);log("start.return",{state:this.state});return result;}
  resume(...args){log("resume.call",{state:this.state});const result=super.resume(...args);log("resume.return",{state:this.state});return result;}
  pause(...args){log("pause.call",{state:this.state,sourceTime:fixture.playingMedia?.currentTime});return super.pause(...args);}
  stop(...args){log("stop.call",{state:this.state});return super.stop(...args);}
  addEventListener(event,callback,options){
    if(event==="resume"&&typeof callback==="function")return super.addEventListener(event,eventObject=>setTimeout(()=>{log("resume.delivered");callback.call(this,eventObject);},${resumeNotificationDelayMs}),options);
    return super.addEventListener(event,callback,options);
  }
};
const nativePlay=HTMLMediaElement.prototype.play;
HTMLMediaElement.prototype.play=function(...args){observeVideo(this);fixture.playingMedia=this;log("play.call",{time:this.currentTime,rate:this.playbackRate});return nativePlay.apply(this,args).then(result=>{log("play.resolved",{time:this.currentTime,rate:this.playbackRate});return result;});};
document.querySelector("#sources").onchange=async event=>{fixture.ready=false;try{sources=[];for(const file of event.target.files)sources.push(await inspectFile(file,new AbortController().signal));fixture.ready=true;}catch(error){fixture.error=error.message;}};
document.querySelector("#voice").onchange=event=>{voice=event.target.files[0];};
document.querySelector("#run").onclick=async()=>{
  fixture.error=null;fixture.errorName=null;fixture.errorCause=null;fixture.result=null;fixture.trace=[];fixture.previousClockRead=undefined;fixture.clockWait=undefined;fixture.resources=[];fixture.tracks=[];if(fixture.collectDiagnosticPartial){fixture.partialChunks=[];fixture.partialBytes=0;fixture.partialCapped=false;fixture.partialEventCount=0;}fixture.exporting=true;fixture.revision=1;decodeIndex=0;exportController=new AbortController();document.querySelector("#download").hidden=true;
  if(url)URL.revokeObjectURL(url);
  try{
    const draft=validateDraft({schema:1,id:"resume-regression",revision:1,ratio:"9:16",title:"",audio:fixture.muteStaleLookahead?"muted":"original",clips:sources.map((local,index)=>({id:"clip-"+index,source:local.source,start:0,end:index===1?(fixture.photoClockControl?2:4):.5,speed:index===1?(fixture.photoClockControl?1:2):1,caption:"",focusX:.5,focusY:.5,transition:index===1?"dissolve":index===2?"whip":"cut"})),...(narrated?{narration:{resultId:"10000000-0000-4000-8000-000000000001",label:"Synthetic narration",offset:.15,volume:1,wordCaptions:false,words:[]}}:{})});
    const result=await exportLocalVideo({draft,media:new Map(sources.map((local,index)=>["clip-"+index,local])),narrationBlob:narrated?voice:undefined,format:exportFormats().find(format=>format.extension==="mp4"),signal:exportController.signal,currentDraft:()=>({...draft,revision:fixture.revision}),onProgress:()=>{}});
    url=URL.createObjectURL(result.blob);const download=document.querySelector("#download");download.href=url;download.hidden=false;fixture.result={duration:result.duration,bytes:result.blob.size};
  }catch(error){fixture.error=error.message;fixture.errorName=error.name;fixture.errorCause=error.cause;}finally{fixture.exporting=false;}
};
`);
  const oldAwaitPlugin = { name: "negative-control-original-resume-await", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /        \/\/ resume\(\) changes state synchronously[\s\S]*?track\?\.requestFrame\?\.\(\);/;
    assert.equal([...code.matchAll(new RegExp(seam.source,"g"))].length,1,"Negative control must match the audited resume fix exactly once");
    const guard='const recordingClock = new RecordingClock();';
    assert.equal(code.split(guard).length-1,1,"Historical resume control must isolate only the main segment recording guard");
    // As in the historical photo-clock control, exclude the later independent
    // recording guard only in this deliberately faulty compiled variant. Keep
    // actual startup readiness, original-audio loss admission and all clocks.
    const isolated=code.replace(guard,'const recordingClock = {read() {}};');
    return omitOldAwait?isolated:isolated.replace(seam, '        const resumed = waitForEvent(recorder, "resume", renderSignal);\n        recorder.resume();\n        await resumed;');
  } };
  // Delay only export-time decoder readiness, never file inspection or source
  // playback. The sequential negative control restores the former per-boundary
  // loading behavior while using exactly the same source media and assertions.
  const delayedDecodePlugin = { name: "forced-export-decoder-latency", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/media.ts")) return;
    const seam = /export async function decodeMedia\([\s\S]*?throwIfAborted\(signal\);/;
    assert(seam.test(code), "Decoder delay must match the real decode entry");
    return code.replace(seam, match => match + '\n  if ((window as any).fixture?.exporting) await (window as any).fixture.delayDecode(signal, kind);')
      .replace('return { element: image, dispose };', 'if ((window as any).fixture?.exporting) (window as any).fixture.resources.push(image); return { element: image, dispose };')
      .replace('return { element: video, dispose };', 'if ((window as any).fixture?.exporting) { (window as any).fixture.resources.push(video); (window as any).fixture.observe(video); } return { element: video, dispose };');
  } };
  const sequentialPreparationPlugin = { name: "negative-control-sequential-decode", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /      const next = draft.clips\[index \+ 1\];[\s\S]*?if \("error" in preparedNext\) throw preparedNext.error;\n        }\n      }/;
    assert(seam.test(code), "Sequential control must remove only successor preloading");
    code = code.replace(seam, "");
    const handoff = "      if (!lookahead?.result)";
    assert(code.includes(handoff));
    return code.replace(handoff, "      if (index > 0) { lookahead = prepare(clip); await lookahead.settled; }\n" + handoff);
  } };
  const clockObservationPlugin = { name: "export-clock-observation", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    if(omitPaintRequest){
      const block="          // Request each completed 30 Hz composite alongside its paint,\n          // retaining timed capture when requestFrame is unavailable.\n          const track = stream!.getVideoTracks()[0] as\n            CanvasCaptureMediaStreamTrack | undefined;\n          track?.requestFrame?.();\n";
      assert.equal(code.split(block).length,2,"Remove only the exact new per-composite request block");
      const before=code;code=code.replace(block,"");
      assert.equal(createHash("sha256").update(code).digest("hex"),"f9a6aa712267fb30932d609694e103e7f820701bdfcae60a92651b767d21b774","Omission must restore exact original product source");
      receipt.compiledControl={name:"omit-per-paint-request",candidateSHA256:createHash("sha256").update(before).digest("hex"),restoredProductSHA256:createHash("sha256").update(code).digest("hex"),removedBlockSHA256:createHash("sha256").update(block).digest("hex")};
    }
    const seam = "const start = originalWallStart ?? performance.now();";
    assert(code.includes(seam));
    const schedule = "const frame = requestAnimationFrame(done);";
    assert(code.includes(schedule), "Cadence fault must intercept only the actual export-frame animation branch");
    const audioLoss = "audio.currentTime - mediaClockStart - Math.max(0, video.currentTime - mediaTimeStart) / (clip.speed ?? 1)";
    const refusal = "            refuseStall();";
    assert.equal(code.split(audioLoss).length - 1, 1, "Observe the exact existing original-audio loss calculation once");
    assert.equal(code.split(refusal).length - 1, 1, "Identify only the original-audio refusal call site");
    code = code.replace(audioLoss, "(window as any).fixture.originalAudioLoss(audio.currentTime, mediaClockStart, video.currentTime, mediaTimeStart, (clip.speed ?? 1), {index, elapsed, duration, ended:video.ended, limit:MAX_ORIGINAL_AUDIO_LOSS_SECONDS})")
      .replace(refusal, '            (window as any).fixture.trace.push({event:"original.audio.refusal",kind:"original_audio_stall",at:performance.now()});\n' + refusal);
    const clockWait = "const now = await nextExportFrame(renderSignal, (duration - elapsedAtWait) * 1000);";
    assert.equal(code.split(clockWait).length - 1, 1, "Observe only the existing export-frame wait without changing it");
    if(videoStages){
      const composites=/([ ]+)(drawFrame\(canvas,[^\n]+\);\n)([ ]+await overlays\.paint\(canvas, ([^)]+)\);)/g;
      assert.equal([...code.matchAll(composites)].length,4,"Observe all four actual composite sites");
      let compositeSite=0;
      code=code.replace(composites,(_match,indent,draw,paint,time)=>{
        const site=compositeSite++,phase=["prepared","startup-readiness","recorder-start","segment-frame"][site];
        return indent+"const diagnosticCompositeStart"+site+" = performance.now();\n"+indent+draw+paint+
          "\n"+indent+"(window as any).fixture.observeComposite({index,timeline:"+time+",localTime:"+(site===3?"elapsed":"0")+",phase:"+JSON.stringify(phase)+",beforeMs:diagnosticCompositeStart"+site+",afterMs:performance.now(),explicitRequestCount:(window as any).fixture.diagnosticRequestCount});";
      });
      const requests=/([ ]+)track\?\.requestFrame\?\.\(\);/g;
      assert.equal([...code.matchAll(requests)].length,omitPaintRequest?2:3,"Observe every actual capture request site");
      let requestSite=0;
      code=code.replace(requests,(_match,indent)=>{const site=requestSite++,phase=["recorder-start","resume","segment-frame"][site];return indent+"const diagnosticRequestBefore = performance.now();\n"+indent+"track?.requestFrame?.();\n"+indent+
        "(window as any).fixture.observeCaptureRequest({index,timeline:elapsedBefore"+(site===2?"+elapsed":"")+",phase:"+JSON.stringify(phase)+",beforeMs:diagnosticRequestBefore,afterMs:performance.now(),available:typeof track?.requestFrame===\"function\",trackLive:track?.readyState===\"live\"});";});
    }
    return code.replace(seam, seam + ' (window as any).fixture.frameClipIsPhoto = !video; (window as any).fixture.frameClipIndex = index; (window as any).fixture.trace.push({event:"clip.clock.start",at:start,index,diagnostics:(window as any).fixture.clockDiagnostics(index,audio,"start")}); if(index===1 && (window as any).fixture.interruptAudio) setTimeout(()=>{const sound=(window as any).fixture.audio; sound.suspend().then(()=>setTimeout(()=>{if(sound.state!=="closed")sound.resume();},180));},250);')
      .replace(clockWait, '(window as any).fixture.observeClockWait(index, (duration - elapsedAtWait) * 1000); ' + clockWait)
      .replace('recordingClock.read((now - start)', '(window as any).fixture.trace.push({event:"clip.clock.read",at:performance.now(),index,wall:(now-start)/1000,timeline:elapsed,audio:audio?.currentTime,media:video?.currentTime,diagnostics:(window as any).fixture.clockDiagnostics(index,audio,"read")}); recordingClock.read((now - start)')
      .replace(schedule, "const frame = (window as any).fixture.requestExportFrame(done);");
  } };
  const oldFrameClockPlugin = { name: "negative-control-animation-only-clock", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = /export function nextExportFrame\([\s\S]*?\n}\n/;
    assert(seam.test(code), "Frame-clock control must match the actual deadline helper");
    assert(!code.match(seam)[0].includes("awaitAudioStartup"), "Frame-clock control must preserve independent startup readiness");
    // Reproduce the historical exporter, including its missing capture/audio
    // guard. The fixed and late-frames variants always use the actual guard.
    return code.replace('const recordingClock = new RecordingClock();', 'const recordingClock = {read() {}};').replace(seam, `export function nextExportFrame(signal: AbortSignal, _remainingMs: number): Promise<number> {
      throwIfAborted(signal);
      return new Promise((resolve, reject) => {
        const aborted = () => {cancelAnimationFrame(frame); reject(signal.reason);};
        const frame = requestAnimationFrame(time => {signal.removeEventListener("abort", aborted); resolve(time);});
        signal.addEventListener("abort", aborted, {once:true});
      });
    }
`);
  } };
  const deadlineOnlyPlugin = { name: "negative-control-deadline-only-cadence", enforce: "pre", transform(code, id) {
    if (!id.endsWith("/src/editor/export.ts")) return;
    const seam = "Math.min(remainingMs, 1000 / 30)";
    assert(code.includes(seam), "Cadence control must remove only the frame interval ceiling");
    return code.replace(seam, "remainingMs");
  } };
  for (const variant of variants) await build({ root: artifacts, configFile: false, publicDir: false, base: "./", logLevel: "error", plugins: [clockObservationPlugin, delayedDecodePlugin, ...(variant === "baseline" ? [oldAwaitPlugin] : variant === "sequential" ? [sequentialPreparationPlugin] : variant === "clock-baseline" ? [oldFrameClockPlugin] : variant === "cadence-baseline" ? [deadlineOnlyPlugin] : [])], build: { outDir: join(dist, variant), rollupOptions: { input: join(artifacts, "fixture.html") } } });
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  const source = join(artifacts, "opening-tone-video.mp4"), narration = join(artifacts, "narration.wav");
  // Distinct opening phoneme surrogate: 990 Hz for the first .30 source seconds,
  // then 440 Hz. At 2x playback the opening still has .15 timeline seconds.
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30:d=4", "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,0.3)\\,0.2*sin(2*PI*990*t)\\,0.2*sin(2*PI*440*t)):s=48000:d=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source]);
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=660:duration=4", "-c:a", "pcm_s16le", narration]);
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  if(diagnosticPair){
    receipt.diagnosticRuntime={node:process.version,platform:process.platform,arch:process.arch,browserVersion:browser.version(),headless:true};
    assert.equal(browser.version(),"153.0.8010.12","Use the same locked Chrome153 toolchain, never substitute a browser");
    try{
      const session=await browser.newBrowserCDPSession();
      try{
        const info=await session.send("Browser.getVersion");
        receipt.diagnosticRuntime.browserRevision=typeof info.revision==="string"&&/^[a-zA-Z0-9@._-]{1,100}$/.test(info.revision)?info.revision:null;
        const args=await session.send("Browser.getBrowserCommandLine");
        receipt.diagnosticRuntime.muteAudioArgumentPresent=Array.isArray(args.arguments)?args.arguments.includes("--mute-audio"):null;
      }finally{await session.detach();}
    }catch(error){receipt.diagnosticRuntime.commandLineObservation={status:"unavailable",errorClass:error?.name??"Error"};}
  }
  const sample = (path, start, duration) => {
    const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", path, "-ss", String(start), "-t", String(duration), "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1"]);
    let power = 0, crossings = 0; const count = pcm.length / 2;
    for (let index = 0; index < pcm.length; index += 2) { const value = pcm.readInt16LE(index) / 32768; power += value * value; if (index && pcm.readInt16LE(index - 2) < 0 && value >= 0) crossings++; }
    // A short opening window includes encoder priming silence. Zero-crossings
    // divided by its whole duration understates pitch; measure spectral energy
    // independently so silence cannot masquerade as lost opening speech.
    let dominantHz = 0, peakPower = 0;
    for (let hz = 300; hz <= 1200; hz += 10) {
      const coefficient = 2 * Math.cos(2 * Math.PI * hz / 48000); let previous = 0, prior = 0;
      for (let index = 0; index < pcm.length; index += 2) { const next = pcm.readInt16LE(index) / 32768 + coefficient * previous - prior; prior = previous; previous = next; }
      const energy = previous * previous + prior * prior - coefficient * previous * prior;
      if (energy > peakPower) { peakPower = energy; dominantHz = hz; }
    }
    return { rms: Math.sqrt(power / count), hz: crossings / (count / 48000), dominantHz, samples: count };
  };
  const frameCache = new Map();
  const frames = (path, x) => {
    const key = `${path}:${x}`;
    if (!frameCache.has(key)) {
      const timestamps = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", path], { encoding: "utf8" })).frames;
      const rgb = execFileSync("ffmpeg", ["-v", "error", "-i", path, "-vf", `format=rgb24,crop=1:1:${x}:400`, "-fps_mode", "passthrough", "-f", "rawvideo", "pipe:1"]);
      assert.equal(rgb.length, timestamps.length * 3);
      frameCache.set(key, timestamps.map((frame, index) => ({ time: Number(frame.best_effort_timestamp_time), rgb: [...rgb.subarray(index * 3, index * 3 + 3)] })));
    }
    return frameCache.get(key);
  };
  // Input seeking selects the next future frame and can conceal an encoded
  // gap. Sample the last frame actually displayed at each requested timestamp.
  const pixel = (path, time, x = 100) => frames(path, x).findLast(frame => frame.time <= time)?.rgb ?? frames(path, x)[0].rgb;
  const isOpeningTone = value => value.rms > .04 && value.dominantHz > 900 && value.dominantHz < 1100;
  const isWhip = ({ left, right }) => left[2] > 200 && left[0] < 30 && right[0] > 200 && right[2] < 30;
  const whipPixels = (path, time) => ({ time, left: pixel(path, time, 100), right: pixel(path, time, 650) });
  receipt.diagnosticPair=diagnosticPair?{status:"running",order:diagnosticModes,strictFailures:[],videoStages,
    scope:videoStages?"One exact late-frames+narrated case per fresh browser process; the hosted wrapper separately executes candidate then exact omission. Not full-suite or hosted-clock-cause acceptance.":"Two exact late-frames+narrated cases, fresh contexts and one browser. Only the two optional diagnostic API calls differ; not full-suite or hosted-cause acceptance."}:null;
  for (const variant of variants) {
   for(const observerMode of diagnosticPair?diagnosticModes:["default"]){
    let diagnosticContext;
    try {
    const context = await browser.newContext({ serviceWorkers: "block", acceptDownloads: true });
    diagnosticContext=context;
    await context.route("**/*", route => { const url = new URL(route.request().url()); if (url.origin === origin || ["blob:", "data:"].includes(url.protocol)) return route.continue(); receipt.externalRequests.push(url.href); return route.abort(); });
    const page = await context.newPage(); page.on("pageerror", error => receipt.errors.push(error.message)); await page.goto(`${origin}/${variant}/fixture.html`);
    const png = await page.evaluate(() => ["#77509c", "red"].map(color => { const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 450; const ctx = canvas.getContext("2d"); ctx.fillStyle = color; ctx.fillRect(0, 0, 800, 450); return canvas.toDataURL().split(",")[1]; }));
    await page.locator("#sources").setInputFiles([{ name: "opening.png", mimeType: "image/png", buffer: Buffer.from(png[0], "base64") }, { name: "original.mp4", mimeType: "video/mp4", buffer: await readFile(source) }, { name: "closing.png", mimeType: "image/png", buffer: Buffer.from(png[1], "base64") }]);
    await page.locator("#voice").setInputFiles(narration); await expect.poll(() => page.evaluate(() => window.fixture.ready)).toBe(true);
    // Isolate the historical photo-clock control from live 2x audio decoding:
    // its first two source seconds play at 1x through the real buffered-original
    // path, retaining the same two-second video span and three-second timeline.
    // Every other variant keeps the complete four-second source at 2x, including
    // the fixed/cadence/late-frame audio, timing, transition and cleanup oracles.
    for (const narrated of diagnosticPair?[true]:[true, false]) {
      await page.evaluate(({ narrated, variant, observerMode, diagnosticPair }) => { window.fixture.diagnosticPaints=[];window.fixture.diagnosticPaintsCapped=false;window.fixture.diagnosticRequests=[];window.fixture.diagnosticRequestsCapped=false;window.fixture.diagnosticRequestCount=0;window.fixture.clockObserverMode=observerMode;window.fixture.collectDiagnosticPartial=diagnosticPair;window.fixture.configure(narrated, variant === "clock-baseline"); window.fixture.delayPhotoFrames = variant === "clock-baseline"; window.fixture.holdExportFrames = ["cadence-baseline", "late-frames"].includes(variant); window.fixture.decodeDelays = variant === "baseline" ? [] : [0, 600, 600]; }, { narrated, variant, observerMode, diagnosticPair });
      const nativeTrace=diagnosticPair?await startLateFrameNativeTrace(context,page,observerMode):undefined;
      let attempt;
      try {
        await page.locator("#run").click();
        const outcome = async () => {
          const value=await page.evaluate(() => window.fixture.error ?? (window.fixture.result ? "done" : "pending"));
          // Stop at actual settlement, including refusal, while preserving the
          // unchanged 20-second positive assertion and its original failure.
          if(nativeTrace && value!=="pending")await nativeTrace.finish();
          return value;
        };
        if (variant === "baseline") await expect.poll(outcome, { timeout: 20000 }).not.toBe("pending");
        else await expect.poll(outcome, { timeout: 20000 }).toBe("done");
      } finally {
        // Retain failures before rethrowing the unchanged completion assertion.
        // In particular, a broken control must never erase the event that caused
        // a genuine production stall refusal. Only the restored old-await
        // baseline may classify a fully evidenced refusal as a detected fault;
        // every current-exporter variant must finish and pass its media oracles.
        if(nativeTrace)await nativeTrace.finish();
        attempt = await page.evaluate(() => ({ error: window.fixture.error, errorName: window.fixture.errorName, errorCause: window.fixture.errorCause, result: window.fixture.result,
          trace: window.fixture.trace, downloadHidden: document.querySelector("#download").hidden,
          tracks: window.fixture.tracks.map(track => track.readyState), ...(window.fixture.diagnosticPaints?.length?{diagnosticPaints:window.fixture.diagnosticPaints,diagnosticPaintsCapped:window.fixture.diagnosticPaintsCapped,diagnosticRequests:window.fixture.diagnosticRequests,diagnosticRequestsCapped:window.fixture.diagnosticRequestsCapped}:{}) }));
        attempt = { ...attempt, variant, narrated, ...(diagnosticPair?{observerMode,nativeTrace:nativeTrace?.facts,
          diagnosticPartial:await retainDiagnosticPartial(page,observerMode)}:{}) };
        if(videoStages)attempt.captureSupplyObservation=observeCaptureSupply(attempt);
        receipt.attempts.push(attempt); await persist();
      }
      if (variant === "baseline" && attempt.error) {
        assertBaselineStall(attempt, resumeNotificationDelayMs);
        receipt.checks.push(`Old resume-await negative control (${narrated ? "narrated" : "original"}) is detected by an evidenced original-audio stall refusal, with no download and all tracks stopped`);
        await persist();
        continue;
      }
      const download = page.waitForEvent("download"); await page.locator("#download").click(); const output = join(artifacts, `${variant}-${narrated ? "narrated" : "original"}${diagnosticPair?"-"+observerMode:""}.mp4`); await (await download).saveAs(output);
      const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", output], { encoding: "utf8" }));
      const trace = await page.evaluate(() => window.fixture.trace), duration = Number(probe.format.duration);
      // AAC startup can shift the .15s opening tone by a few encoded frames.
      // Require it in two adjacent 90ms samples between .53s and .74s, well
      // before the injected old-await delay. Amplitude, pitch, total duration,
      // leading silence and the independent playback trace remain enforced.
      const audio = { opening: [.53, .57, .61, .65].map(start => ({ start, ...sample(output, start, .09) })), middle: sample(output, 1, .7), leading: sample(output, .02, .08) };
      // MediaRecorder timestamps vary by a few encoded frames on busy macOS
      // runners. The 180 ms whip starts at timeline 2.5 s; look for its actual
      // spatial split in this bounded window, not one exact timestamp. A hard
      // cut cannot satisfy the split, and the delayed-resume control must miss
      // this window. Keep the independent duration and audio timing bounds.
      const pixels = {
        dissolve: { before: pixel(output, .4), samples: [.54, .58, .62, .66, .70, .74, .78, .82, .86].map(time => ({ time, rgb: pixel(output, time) })), after: pixel(output, 1.1) },
        beforeWhip: whipPixels(output, 2.4),
        whip: [2.54, 2.58, 2.62, 2.66, 2.70, 2.74].map(time => whipPixels(output, time)),
        afterWhip: whipPixels(output, 2.9),
      };
      receipt.runs.push({ variant, narrated, ...(diagnosticPair?{observerMode}:{}), plannedSeconds: 3, duration, trace, audio, pixels, decodedFrames: frames(output, 100), output, probe }); await persist();
      assert(probe.streams.some(stream => stream.codec_name === "h264")); assert(probe.streams.some(stream => stream.codec_name === "aac"));
      if (["fixed", "late-frames"].includes(variant)) {
        const audioTrack = probe.streams.find(stream => stream.codec_type === "audio");
        const videoTrack = probe.streams.find(stream => stream.codec_type === "video");
        const avDurationGap = Math.abs(Number(audioTrack.duration) - Number(videoTrack.duration));
        receipt.runs.at(-1).avDurationGap = avDurationGap; await persist();
        assert(Number.isFinite(avDurationGap) && avDurationGap <= 2 / 30,
          `Audio and picture stream durations must agree within two frames: ${avDurationGap}s`);
      }
      assert.equal(trace.find(event => event.event === "play.call")?.rate, variant === "clock-baseline" ? 1 : 2,
        "Only the photo-clock negative control uses 1x; all other exports must exercise actual 2x playback");
      assert.equal(trace.filter(event => event.event === "resume.return").length, 2);
      assert(trace.filter(event => event.event === "resume.return").every(event => event.state === "recording"));
      if (["cadence-baseline", "late-frames"].includes(variant)) {
        const held = trace.filter(event => event.event === "export.frame.held");
        const cancelled = trace.filter(event => event.event === "export.frame.cancelled");
        assert(held.some(event => event.index === 1), "Paired cadence fault must intercept the actual dissolving video segment");
        assert.equal(cancelled.length, held.length, "Every held export animation request must be cancelled by the actual timer path");
        assert(held.every(event => cancelled.some(value => value.id === event.id)), "Timer wakeups must cancel the exact held animation handles");
        assert.equal(trace.filter(event => event.event === "export.frame.delivered").length, 0, "Paired cadence fault must deliver no export animation callbacks");
      }
      if (variant === "baseline") {
        assert(duration > 3.4, `Negative control must reproduce drift with the old await: ${duration}`);
        const resumed = trace.filter(event => event.event === "resume.return");
        const delivered = trace.filter(event => event.event === "resume.delivered");
        assert.equal(delivered.length, 2);
        assert(delivered.every((event, index) => event.at - resumed[index].at >= resumeNotificationDelayMs - 1), "Both negative-control resumptions must include the injected notification delay");
        assert(trace.find(event => event.event === "play.call").at >= delivered[0].at, "The old await must stall original playback until the delayed notification arrives");
        assert(!pixels.whip.some(isWhip), "Delayed-resume negative control must put the whip outside the fixed timeline window");
        if (!narrated) assert(!audio.opening.some(isOpeningTone), "The old-await control must put the original opening tone outside the bounded audio window");
      } else if (variant === "sequential") {
        assert.equal(trace.filter(event => event.event === "resume.delivered").length, 0);
        const ready = trace.filter(event => event.event === "decode.ready");
        assert.equal(ready.length, 2);
        assert(ready.every(event => event.at > trace.find(event => event.event === "start.call").at), "Both sequential decoder delays must occur after recording starts");
        const pauses = trace.filter(event => event.event === "pause.call"), resumes = trace.filter(event => event.event === "resume.call");
        assert(ready.every((event, index) => event.at > pauses[index].at && event.at < resumes[index].at), "Sequential control must finish each decoder at its paused boundary, violating readiness before handoff");
      } else if (variant === "clock-baseline") {
        const clocks = trace.filter(event => event.event === "clip.clock.start");
        const firstPause = trace.find(event => event.event === "pause.call");
        assert(firstPause.at - clocks[0].at > 600, "Animation-only photo clock must overrun its 500 ms segment under late callback delivery");
        assert(!pixels.whip.some(isWhip), "Animation-only clock must miss the unchanged whip timing window");
      } else if (variant === "cadence-baseline") {
        assert(Math.abs(duration - 3) < .4, "Deadline-only control still corrects total segment duration");
        const blends = pixels.dissolve.samples.filter(({rgb}) => rgb[0] > 20 && rgb[0] < 100 && rgb[2] > 170 && rgb[2] < 245);
        assert(!blends.some((sample, index) => blends.slice(index + 1).some(later => sample.rgb[0] - later.rgb[0] >= 8 && later.rgb[2] - sample.rgb[2] >= 8)), "Deadline-only cadence control must miss the unchanged progressing-dissolve criterion when export animation callbacks are held");
      } else {
        const start = trace.find(event => event.event === "start.call");
        const ready = trace.filter(event => event.event === "decode.ready");
        assert.equal(ready.length, 2);
        assert(ready[0].at < start.at, "The second source must be decoded/seeked before recording starts");
        const pauses = trace.filter(event => event.event === "pause.call");
        assert(pauses[1].sourceTime >= 3.999, "Deadline wakeup must still consume the complete four-second source at its selected speed");
        const thirdPreparation = trace.find(event => event.event === "decode.start" && event.index === 2);
        assert(thirdPreparation.at >= pauses[0].at && ready[1].at < pauses[1].at, "The third source must be prepared after the first segment and ready before the second segment ends");
        assert(Math.abs(duration - 3) < .4, `Fixed real MP4 must retain the existing duration tolerance: ${duration}`);
        assert.equal(trace.filter(event => event.event === "resume.delivered").length, 0);
        // Match the fixed, bounded cloud-editor criterion: a real dissolve
        // progresses through multiple blends; a cut or frozen blend cannot pass.
        const dissolve = pixels.dissolve;
        const blends = dissolve.samples.filter(({ rgb }) => rgb[0] > 20 && rgb[0] < 100 && rgb[2] > 170 && rgb[2] < 245);
        assert(blends.some((sample, index) => blends.slice(index + 1).some(later => sample.rgb[0] - later.rgb[0] >= 8 && later.rgb[2] - sample.rgb[2] >= 8)), `Dissolve must progress within the bounded window: ${JSON.stringify(dissolve.samples)}`);
        assert(dissolve.before[0] > 100 && dissolve.before[0] < 135 && dissolve.before[1] > 65 && dissolve.before[1] < 95 && dissolve.before[2] > 135 && dissolve.before[2] < 175, "The preceding shot must still be purple before the dissolve");
        assert(dissolve.after[0] < 10 && dissolve.after[1] < 10 && dissolve.after[2] > 240, "The following shot must be fully blue after the dissolve");
        assert(pixels.whip.some(isWhip), `Actual whip must move blue and red across the frame within the bounded timeline window: ${JSON.stringify(pixels.whip)}`);
        assert(pixels.beforeWhip.left[2] > 200 && pixels.beforeWhip.right[2] > 200 && !isWhip(pixels.beforeWhip), "The preceding shot must still be blue before the whip");
        assert(pixels.afterWhip.left[0] > 200 && pixels.afterWhip.right[0] > 200 && !isWhip(pixels.afterWhip), "The closing shot must be fully red after the whip");
        if (narrated) assert(audio.middle.rms > .02 && audio.middle.hz > 610 && audio.middle.hz < 710, `Narration stays at 660 Hz: ${JSON.stringify(audio.middle)}`);
        else {
          assert(audio.leading.rms < .005, "Leading photo stays silent; video speech does not shift to time zero");
          assert(audio.opening.some((value, index) => index > 0 && isOpeningTone(value) && isOpeningTone(audio.opening[index - 1])), `The distinct first .15 seconds of original audio must survive resume in adjacent bounded samples: ${JSON.stringify(audio.opening)}`);
          assert(audio.middle.rms > .04 && audio.middle.hz > 400 && audio.middle.hz < 480, `The rest of the original recording stays continuous at 440 Hz: ${JSON.stringify(audio.middle)}`);
        }
      }
    }
    if (variant === "fixed") {
      await page.evaluate(() => {window.fixture.configure(true);window.fixture.decodeDelays=[];window.fixture.interruptAudio=true;});
      await page.locator("#run").click();
      await expect.poll(() => page.evaluate(() => window.fixture.exporting), {timeout:10000}).toBe(false);
      const interruption=await page.evaluate(()=>({error:window.fixture.error,cause:window.fixture.errorCause,result:window.fixture.result,
        downloadHidden:document.querySelector("#download").hidden,tracks:window.fixture.tracks.map(track=>track.readyState)}));
      receipt.clockInterruption=interruption;await persist();
      assert.match(interruption.error,/Audio and picture timing drifted/);
      assert.equal(interruption.result,null,"An actual audio-clock suspension cannot offer a downloadable export");
      assert(interruption.downloadHidden&&interruption.tracks.every(state=>state==="ended"));
      assert(interruption.cause.maxLossSeconds>2/30&&interruption.cause.readings.slice(-2).every(reading=>reading.drift>2/30));
      await page.evaluate(()=>{window.fixture.interruptAudio=false;});
      receipt.checks.push("An actual AudioContext suspension rejects the export before a download and retains the clock readings; removing the recording guard makes this assertion fail");
      for (const scenario of ["late-successor", "abort-initial-successor", "stale-during-lookahead", "failed-initial-successor"]) {
        await page.evaluate(scenario => {
          window.fixture.configure(false);
          // This case tests revision admission and pending-decoder cleanup, not
          // audio capture. Keep its real media, timers and RecordingClock while
          // excluding an unrelated cold Web Audio startup refusal before index2.
          // The MP4 variants and interruption test above retain all audio guards.
          window.fixture.muteStaleLookahead = scenario === "stale-during-lookahead";
          window.fixture.decodeDelays = scenario === "abort-initial-successor" ? [0, 5000] : scenario === "failed-initial-successor" ? [] : [0, 0, 5000];
          window.fixture.decodeErrorIndex = scenario === "failed-initial-successor" ? 1 : undefined;
          window.fixture.staleDecodeIndex = scenario === "stale-during-lookahead" ? 2 : undefined;
        }, scenario);
        await page.locator("#run").click();
        if (scenario === "abort-initial-successor") {
          await expect.poll(() => page.evaluate(() => window.fixture.trace.some(event => event.event === "decode.start" && event.index === 1))).toBe(true);
          await page.evaluate(() => window.fixture.cancel());
        }
        await expect.poll(() => page.evaluate(() => window.fixture.exporting), { timeout: 10000 }).toBe(false);
        const evidence = await page.evaluate(() => ({ error: window.fixture.error, errorCause: window.fixture.errorCause, revision: window.fixture.revision, result: window.fixture.result, trace: window.fixture.trace, resourceCount: window.fixture.resources.length, remainingSources: window.fixture.resources.filter(element => element.hasAttribute("src")).length, liveTracks: window.fixture.tracks.filter(track => track.readyState !== "ended").length }));
        receipt.preparationFailures.push({ scenario, ...evidence }); await persist();
        assert.equal(evidence.result, null, "Preparation failure must never offer an export blob");
        assert.equal(evidence.remainingSources, 0, "All current and prepared decoders must release their source");
        assert.equal(evidence.liveTracks, 0, "Failed exports must stop their recording tracks");
        assert(evidence.resourceCount > 0, "Cleanup assertion must inspect real decoded resources");
        if (scenario === "late-successor") assert.match(evidence.error, /could not prepare the next clip in time/);
        if (scenario === "abort-initial-successor") assert.match(evidence.error, /Fixture export cancelled/);
        if (scenario === "stale-during-lookahead") {
          assert.match(evidence.error, /changed/i);
          const clockReads = evidence.trace.filter(event => event.event === "clip.clock.read");
          assert(clockReads.length > 0 && clockReads.every(event => event.diagnostics.audioState === null),
            "Only this revision-cleanup case must use an explicitly muted draft with the real recording clock");
          assert(!evidence.trace.some(event => event.event === "audio.statechange"),
            "The stale-lookahead case must not start an unrelated audio capture context");
          assert.equal(evidence.revision, 2, "The actual currentDraft revision must change exactly once");
          const changed = evidence.trace.filter(event => event.event === "revision.changed");
          assert.equal(changed.length, 1, "Exactly one source-side lookahead invalidation must execute");
          assert.equal(changed[0].index, 2, "Only the pending third decoder changes the draft");
          assert(changed[0].at > evidence.trace.find(event => event.event === "start.call").at,
            "The revision must become stale during an actual recording, not before export admission");
          assert(!evidence.trace.some(event => event.event === "decode.ready" && event.index === 2),
            "Stale lookahead must be refused before its delayed source becomes ready");
        }
        if (scenario === "failed-initial-successor") {
          assert.match(evidence.error, /Fixture decoder failure/);
          assert(!evidence.trace.some(event => event.event === "start.call"), "Known initial preparation failure must precede recording");
        } else assert(evidence.trace.some(event => event.event === "decode.aborted"), "Pending preparation must be aborted and settled before returning");
      }
    }
    await context.close();
    }catch(error){
      if(!diagnosticPair)throw error;
      receipt.diagnosticPair.strictFailures.push({observerMode,error:error.stack??String(error)});
      await persist();
    }finally{if(diagnosticPair)await diagnosticContext?.close();}
   }
  }
  if(!diagnosticPair){
  if(!onlyFixed){
  receipt.checks.push("Held export animation callbacks retain the same MP4 timing, held-frame transitions and opening speech; the animation-only clock misses whip timing and the deadline-only control misses progressing dissolve frames");
  receipt.checks.push("Late decoder readiness, cancellation during initial preparation, stale revision during lookahead and decoder failure reject without a blob, source handles or live tracks");
  receipt.checks.push("Old resume-await negative control is detected by the unchanged bad-MP4 timing/audio oracles or by its exact original-audio refusal with two distinct >2/30s loss readings, no download and stopped tracks; fixed and late-frames still require all MP4/AAC quality oracles");
  receipt.checks.push("Sequential-decoder negative control violates readiness before handoff; fixed export prepares the second source before start and third during the second segment despite identical 600 ms decoder delays");
  }
  receipt.checks.push("Fixed exports keep the existing 400 ms duration tolerance without cutting source spans or changing playback speed");
  receipt.checks.push("Decoded MP4 frames retain the real dissolve and whip at their intended timeline positions");
  receipt.checks.push("AAC retains 660 Hz narration, leading photo silence, the distinctive 990 Hz opening sound in adjacent bounded samples after resume, and continuous 440 Hz original audio");
  }
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []);
  if(diagnosticPair){
    receipt.diagnosticPair.status=receipt.diagnosticPair.strictFailures.length?"strict-positive-failure":"declared-strict-positives-passed-cause-still-unknown";
    await persist();
    assert.equal(receipt.attempts.length,diagnosticModes.length,"Exactly the declared diagnostic cases, never retry a case");
    assert.equal(receipt.diagnosticPair.strictFailures.length,0,"A matched diagnostic case failed its unchanged positive oracle; never accept safety refusal as PASS");
    assert.equal(receipt.runs.length,diagnosticModes.length,"All declared diagnostic positives must reach every unchanged MP4/media oracle");
    if(videoStages){
      assert(receipt.attempts.every(attempt=>attempt.nativeTrace?.videoStageStatus==="captured-required-video-stages"),"Missing native video stages are inconclusive, never readiness evidence");
      assert(receipt.attempts.every(attempt=>attempt.captureSupplyObservation?.available),"Native initial capture supply evidence is incomplete");
      assert(receipt.attempts.every(attempt=>attempt.captureSupplyObservation.openingInputObserved===true),"Native canvas input did not reach the recorder before its first clip paused");
      assert(receipt.attempts.every(attempt=>attempt.diagnosticPaints?.length && attempt.diagnosticPaintsCapped===false && attempt.diagnosticRequests?.length===(omitPaintRequest?3:attempt.diagnosticPaints.filter(paint=>paint.phase==="segment-frame").length+3) && attempt.diagnosticRequestsCapped===false),"Bounded completed paint observations are required, never assumed");
    }
    assert(receipt.attempts.every(attempt=>attempt.nativeTrace?.status==="captured-required-spans"),
      "Incomplete native observation is diagnostic-inconclusive and must keep this diagnostic job red");
    assert(receipt.attempts.every(attempt=>attempt.diagnosticPartial?.status==="stop-flushed-native-bytes"),
      "Incomplete partial capture is diagnostic-inconclusive and must keep this diagnostic job red");
  }
  receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack ?? String(error); throw error; }
finally {
  await persist(); await browser?.close(); await new Promise(done => server ? server.close(done) : done());
  // Persist every decoded frame, pixel and trace in the receipt; keep CI output
  // compact enough that an intended-control failure remains visible.
  console.log(JSON.stringify({ artifacts, receipt: join(artifacts, "receipt.json"), status: receipt.status,
    checks: receipt.checks.length, preparationFailures: receipt.preparationFailures.length,
    runs: receipt.runs.map(({variant,narrated,duration,trace}) => ({variant,narrated,duration,
      heldFrames: trace.filter(value => value.event === "export.frame.held").length,
      cancelledFrames: trace.filter(value => value.event === "export.frame.cancelled").length,
      deliveredFrames: trace.filter(value => value.event === "export.frame.delivered").length})),
    failure: receipt.failure?.split("\n")[0], errors: receipt.errors, externalRequests: receipt.externalRequests }, null, 2));
}
