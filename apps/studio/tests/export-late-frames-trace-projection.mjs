import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {join} from "node:path";
const root = import.meta.dirname, path = join(root, "export-resume-browser.mjs");
const source = readFileSync(path, "utf8"), before = createHash("sha256").update(source).digest("hex");
const a = "      // BEGIN pure native trace projection\n", b = "      // END pure native trace projection\n";
assert.equal(source.split(a).length, 2); assert.equal(source.split(b).length, 2);
const projection = source.split(a)[1].split(b)[0];
const names = ["AudioDestination::RequestRender", "RealtimeAudioDestinationHandler::Render", "MediaStreamAudioDestinationHandler::Process"];
const videoNames=["VideoTrackRecorderImpl::VideoTrackRecorderImpl", "VideoTrackRecorderImpl::OnVideoFrame", "VideoTrackRecorderImpl::OnEncoderSupportKnown", "VideoTrackRecorderImpl::ProcessOneVideoFrame", "VideoTrackRecorderImpl::InitializeEncoder", "Encoder::StartFrameEncode", "MediaRecorderEncoderWrapper::EncodeFrame", "MediaRecorderEncoderWrapper::CreateAndInitialize", "MediaRecorderEncoderWrapper::InitizalizeDone", "MediaRecorderEncoderWrapper::OutputEncodeData", "VideoEncodeAcceleratorAdapter::EncodeOnAcceleratorThread"];
const videoRequiredNames=["VideoTrackRecorderImpl::VideoTrackRecorderImpl", "VideoTrackRecorderImpl::OnVideoFrame", "VideoTrackRecorderImpl::OnEncoderSupportKnown", "VideoTrackRecorderImpl::ProcessOneVideoFrame", "VideoTrackRecorderImpl::InitializeEncoder", "Encoder::StartFrameEncode", "MediaRecorderEncoderWrapper::EncodeFrame", "MediaRecorderEncoderWrapper::CreateAndInitialize", "MediaRecorderEncoderWrapper::InitizalizeDone", "MediaRecorderEncoderWrapper::OutputEncodeData"];
const syncId="resume-late-frames-getters-on-before-click";
const optionalNames=["AudioDestination::Render","SetDetectSilenceIfNecessary","RealtimeAudioDestinationHandler::SetSinkDescriptor","RealtimeAudioDestinationHandler::SetSinkDescriptor_Status","RealtimeAudioDestinationHandler::SetSinkDescriptor_Swap","RendererWebAudioDeviceImpl::CreateAudioRendererSink","AudioDestination::Start","AudioDestination::Stop","AudioDestination::Pause","AudioDestination::Resume"];
const instantNames=["SilentSinkSuspender::TransitionSinks - fake_sink_.Start()","SilentSinkSuspender::TransitionSinks - fake_sink_.Stop()","RealtimeAudioDestinationHandler::SetSinkDescriptor_Swap"];
const category=name=>name===names[2]?"disabled-by-default-webaudio.audionode":"webaudio";
const marker = {name: "clock_sync", ph: "c", ts: 1000000, pid: 1, tid: 2, args: {sync_id: "resume-late-frames-getters-on-before-click"}};
const events = [marker, ...names.map((name, i) => ({name, cat:category(name), ph: "X", ts: 1001000 + i * 10, dur: 100 - i * 20, pid: 1, tid: 2,
  args: {frames:128,frames_requested:256,frames_to_render:128,ignored: "SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT"}}))];
const baseFacts = () => ({clockMarker: {syncId: "resume-late-frames-getters-on-before-click", pageWallBeforeMs: 50, pageWallAfterMs: 52}, dataLossOccurred: false, stopReason: "case-finished"});
const execute = (input = events, change = () => {}, code = projection, videoStages = false) => {
  const facts = baseFacts(); change(facts); new Function("parsed", "facts", "names", "limits", "optionalNames", "instantNames", "syncId", "videoNames", "videoRequiredNames", "videoStages", code)({traceEvents: structuredClone(input)}, facts, names, {events: 40000}, optionalNames, instantNames, syncId, videoNames, videoRequiredNames, videoStages); return facts;
};
const rows = [];
function test(name, fn) {fn(); rows.push({name, status: "PASS"});}
test("Native fixed marker and all three X spans establish the finite time bridge", () => {
  const f = execute(); assert.equal(f.status, "captured-required-spans"); assert.deepEqual(f.spanCounts, Object.fromEntries(names.map(name => [name, 1])));
  assert.equal(f.clockAlignment.traceMarkerUs, 1000000); assert.equal(f.clockAlignment.uncertaintyMs, 2);
  assert.equal(f.clockAlignment.pageWallBeforeMs, 50); assert.equal(f.clockAlignment.pageWallAfterMs, 52);
});
const paired = [marker, ...names.map((name, i) => ({name, cat:category(name), ph: "B", ts: 1001000 + i * 10, pid: 1, tid: 2})),
  {ph: "E", ts: 1001060, pid: 1, tid: 2}, {ph: "E", ts: 1001090, pid: 1, tid: 2}, {ph: "E", ts: 1001100, pid: 1, tid: 2}];
test("Nested native B/E pairs retain exact 100/80/40 microsecond spans", () => {
  const f = execute(paired); assert.equal(f.status, "captured-required-spans");
  assert.deepEqual(Object.fromEntries(f.spans.map(span => [span.name, span.durationUs])), Object.fromEntries(names.map((name, i) => [name, [100, 80, 40][i]])));
});
test("Out-of-order event serialization is sorted by native timestamp", () => assert.equal(execute([...paired].reverse()).status, "captured-required-spans"));
test("Missing native marker is incomplete", () => {const f = execute(events.slice(1)); assert.equal(f.status, "captured-incomplete"); assert.equal(f.clockAlignment.available, false);});
test("Filtered sync_id is explicitly unavailable", () => {const f = execute([{...marker, args: {sync_id: "__stripped__"}}, ...events.slice(1)]); assert.equal(f.status, "captured-incomplete"); assert.equal(f.clockAlignment.matchedMarkers, 0);});
test("Duplicate native markers cannot invent one mapping", () => {const f = execute([...events, marker]); assert.equal(f.status, "captured-incomplete"); assert.equal(f.clockAlignment.available, false);});
test("Another marker ID is never admitted", () => assert.equal(execute([{...marker, args: {sync_id: "other"}}, ...events.slice(1)]).status, "captured-incomplete"));
test("Marker timestamp must be finite", () => assert.equal(execute([{...marker, ts: NaN}, ...events.slice(1)]).status, "captured-incomplete"));
test("Native marker without a requested page bracket is incomplete", () => assert.equal(execute(events, f => {delete f.clockMarker;}).status, "captured-incomplete"));
test("Nonfinite page bracket is incomplete", () => assert.equal(execute(events, f => {f.clockMarker.pageWallBeforeMs = NaN;}).status, "captured-incomplete"));
test("Backward page bracket is incomplete", () => assert.equal(execute(events, f => {f.clockMarker.pageWallBeforeMs = 60;}).status, "captured-incomplete"));
test("A wide round trip cannot claim precise plateau alignment", () => assert.equal(execute(events, f => {f.clockMarker.pageWallAfterMs = 150;}).status, "captured-incomplete"));
test("Native data loss stays incomplete", () => assert.equal(execute(events, f => {f.dataLossOccurred = true;}).status, "captured-incomplete"));
test("Missing data-loss boolean is not silently false", () => assert.equal(execute(events, f => {delete f.dataLossOccurred;}).status, "captured-incomplete"));
test("Observer budget stop stays incomplete", () => assert.equal(execute(events, f => {f.stopReason = "buffer-or-event-budget";}).status, "captured-incomplete"));
test("Missing required native processing span stays incomplete", () => assert.equal(execute(events.slice(0, -1)).status, "captured-incomplete"));
test("An unmatched native begin is retained as incomplete", () => {const f = execute([...events, {name: names[0], cat:"webaudio", ph: "B", ts: 1002000, pid: 1, tid: 2}]); assert.equal(f.status, "captured-incomplete"); assert.equal(f.unmatchedRequiredBegins, 1);});
test("Negative native duration cannot substitute for a real span", () => assert.equal(execute(events.map((event, i) => i === 3 ? {...event, dur: -1} : event)).status, "captured-incomplete"));
test("Arbitrary native arguments and device strings never reach projected facts", () => {const f = execute(); assert(!JSON.stringify(f).includes("SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT")); assert(!JSON.stringify(f.spans).includes("args"));});
const many = count => [...events, ...Array.from({length: count - events.length}, (_, i) => ({name: "unrelated", ph: "I", ts: 2000000 + i, pid: 1, tid: 2}))];
test("Exactly 40,000 events is admitted without expanding the span projection", () => {const f = execute(many(40000)); assert.equal(f.status, "captured-required-spans"); assert.equal(f.spans.length, 3);});
test("40,001 events refuses projection at the actual event-volume guard", () => assert.equal(execute(many(40001)).status, "incomplete-event-limit"));
test("Empty native trace is not evidence of missing source work", () => assert.equal(execute([]).status, "captured-incomplete"));
// Execute the actual source byte-cap guard separately; no transport/browser is imported.
const byteGuard = '      if (!eof) {facts.status = "incomplete-byte-limit"; return;}';
assert.equal(source.split(byteGuard).length, 2);
const guard = new Function("eof", "facts", byteGuard + '\n facts.completedBytes = true;');
test("An incomplete bounded raw stream never proceeds to complete-byte evidence", () => {const f = {}; guard(false, f); assert.equal(f.status, "incomplete-byte-limit"); assert.equal(f.completedBytes, undefined);});
test("Complete stream proceeds after the exact byte-cap guard", () => {const f = {}; guard(true, f); assert.equal(f.completedBytes, true);});
// Native callback gaps are grouped by exact process/thread/name, not pooled.
test("Native duration and inter-callback gap distributions remain distinct",()=>{
  const input=[...events,...events.slice(1).map(e=>({...e,ts:e.ts+5000}))];
  const f=execute(input),g=f.callbackGroups.find(g=>g.name===names[0]);
  assert.equal(g.spanCount,2);assert.equal(g.durations.maxUs,100);assert.equal(g.startGaps.maxUs,5000);
  assert.deepEqual(g.longestIntervals[0],{previousStartUs:1001000,startUs:1006000,startGapUs:5000,previousDurationUs:100,idleAfterPreviousEndUs:4900});
});
test("Process and thread identities cannot create one false giant callback gap",()=>{
  const f=execute([...events,...events.slice(1).map(e=>({...e,pid:9,tid:8,ts:e.ts+90000}))]);
  const g=f.callbackGroups.filter(g=>g.name===names[0]);assert.equal(g.length,2);assert(g.every(g=>g.startGaps.count===0));
});
test("Long native Render work is retained separately from callback start gaps",()=>{
  const f=execute(events.map(e=>e.name===names[1]?{...e,dur:90000}:e));
  assert.equal(f.callbackGroups.find(g=>g.name===names[1]).durations.maxUs,90000);
});
test("Matching name in the channel-change category is not a destination processing quantum",()=>{
  const f=execute(events.map(e=>e.name===names[2]?{...e,cat:"webaudio"}:e));
  assert.equal(f.spanCounts[names[2]],0);assert.equal(f.status,"captured-incomplete");
});
test("Only bounded source-backed native frame arguments are projected",()=>{
  const f=execute();assert.deepEqual(f.spans.find(s=>s.name===names[0]).frameParameters,{frames_requested:256,frames_to_render:128});
  assert.deepEqual(f.spans.find(s=>s.name===names[2]).frameParameters,{});
  assert.equal(f.callbackGroups.find(g=>g.name===names[1]).frameParameterAvailability,"numeric-native-arguments-present");
  assert(f.destinationSampleContinuity.startsWith("UNKNOWN:"));
});
test("Filtered or malformed frame counts remain unavailable, never assumed quantum size",()=>{
  const f=execute(events.map(e=>({...e,args:{frames:1e12,frames_requested:-1,frames_to_render:"128"}})));
  assert(f.callbackGroups.every(g=>g.frameParameterAvailability==="unavailable-or-filtered"));
});
test("Only exact source-backed sink instant names and safe times/IDs survive",()=>{
  const instant={name:instantNames[0],ph:"I",ts:1000500,pid:1,tid:3,args:{unsafe:"SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT"}};
  const f=execute([...events,instant,{...instant,name:"unreviewed sink event"}]);
  assert.deepEqual(f.instants,[{name:instantNames[0],pid:1,tid:3,atUs:1000500}]);
});
test("Optional hardware Render spans retain their own callback group",()=>{
  const f=execute([...events,{name:"AudioDestination::Render",cat:"webaudio",ph:"X",ts:1001000,dur:200,pid:1,tid:4,args:{frames:256}}]);
  assert.equal(f.callbackGroups.find(g=>g.name==="AudioDestination::Render").durations.maxUs,200);
});

const videoEvents=videoNames.map((name,i)=>({name,cat:"media",ph:"X",ts:1010000+i*100,dur:5+i,pid:3,tid:4,args:{unsafe:"SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT"}}));
const videoExecute=(input=[...events,...videoEvents],code=projection)=>execute(input,()=>{},code,true);
test("All exact media stage names retain source process/thread identity",()=>{const f=videoExecute();assert.equal(f.videoStageStatus,"captured-required-video-stages");assert.equal(f.videoStageGroups.length,11);assert(f.videoStageGroups.every(g=>g.pid===3&&g.tid===4&&g.count===1));});
test("Audio evidence does not impersonate missing video-stage evidence",()=>{const f=videoExecute(events);assert.equal(f.status,"captured-required-spans");assert.equal(f.videoStageStatus,"captured-incomplete");});
test("Matching video method in the wrong category is excluded",()=>{const f=videoExecute([...events,...videoEvents.map(e=>({...e,cat:"webaudio"}))]);assert.equal(f.videoStageStatus,"captured-incomplete");assert.equal(f.videoStageGroups.length,0);});
test("Missing encoded output remains video-incomplete despite successful initialize",()=>{const f=videoExecute([...events,...videoEvents.filter(e=>e.name!=="MediaRecorderEncoderWrapper::OutputEncodeData")]);assert.equal(f.videoStageStatus,"captured-incomplete");});
test("Software path need not emit optional hardware accelerator stage",()=>{const f=videoExecute([...events,...videoEvents.filter(e=>e.name!=="VideoEncodeAcceleratorAdapter::EncodeOnAcceleratorThread")]);assert.equal(f.videoStageStatus,"captured-required-video-stages");});
test("Distinct encoder threads never create one pooled false gap",()=>{const f=videoExecute([...events,...videoEvents,...videoEvents.map(e=>({...e,tid:8,ts:e.ts+999999}))]);const g=f.videoStageGroups.filter(g=>g.name===videoNames[0]);assert.equal(g.length,2);assert(g.every(g=>g.startGaps.count===0));});
test("Video method duration and callback-start gap remain separately measured",()=>{const f=videoExecute([...events,...videoEvents,{...videoEvents[0],ts:1020000,dur:50}]);const g=f.videoStageGroups.find(g=>g.name===videoNames[0]);assert.equal(g.durations.maxUs,50);assert.equal(g.startGaps.maxUs,10000);});
test("Unmatched video begin makes video evidence incomplete",()=>{const f=videoExecute([...events,...videoEvents,{...videoEvents[0],ph:"B",ts:1030000}]);assert.equal(f.videoStageStatus,"captured-incomplete");assert.equal(f.unmatchedVideoBegins,1);});
test("PreEncodeFrame keeps only boolean conversion and safe time/identity",()=>{const f=videoExecute([...events,...videoEvents,{name:"PreEncodeFrame",cat:"media",ph:"I",ts:1010050,pid:3,tid:4,args:{converted:true,unsafe:"SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT"}}]);assert.deepEqual(f.videoInstants,[{name:"PreEncodeFrame",pid:3,tid:4,atUs:1010050,converted:true}]);assert(!JSON.stringify(f).includes("SYNTHETIC_ARGUMENT_MUST_NOT_PROJECT"));});
test("Video data loss cannot become required-stage evidence",()=>{const f=execute([...events,...videoEvents],f=>{f.dataLossOccurred=true;},projection,true);assert.equal(f.videoStageStatus,"captured-incomplete");});

const start='fixture.clockDiagnostics=(index,audio,phase)=>{',end='  return result;\n};';
assert.equal(source.split(start).length,2);
const clockBody=source.split(start)[1].split(end)[0]+'  return result;';
const clockFn=new Function("fixture","performance","document","index","audio","phase",clockBody);
function observe(mode){let ticks=0,stamp=0,latency=0;const fixture={clockObserverMode:mode};
  const audio={state:"running",sampleRate:48000,baseLatency:.005333,getOutputTimestamp(){stamp++;return {contextTime:1,performanceTime:2};},get outputLatency(){latency++;return .01;}};
  const value=clockFn(fixture,{now:()=>++ticks},{visibilityState:"visible"},1,audio,"read");return {ticks,stamp,latency,value};}
test("Matched ON mode calls both actual diagnostic APIs once",()=>{const f=observe("getters-on");assert.equal(f.stamp,1);assert.equal(f.latency,1);assert.equal(f.value.observerAPIsIntentionallyOmitted,false);});
test("Matched OFF mode omits only the two diagnostic APIs",()=>{const f=observe("getters-off");assert.equal(f.stamp,0);assert.equal(f.latency,0);assert.equal(f.value.sampleRate,48000);assert.equal(f.value.audioState,"running");assert.equal(f.value.observerAPIsIntentionallyOmitted,true);});
test("Default mode keeps both old APIs and no new performance timing reads",()=>{const f=observe("default");assert.equal(f.stamp,1);assert.equal(f.latency,1);assert.equal(f.ticks,1);});
const partialStart='if(f.exporting || f.tracks.some(track=>track.readyState!=="ended"))return {status:"unavailable-before-cleanup"};';
assert.equal(source.split(partialStart).length,2);
const partialGuard=new Function("f",partialStart+' return {status:"eligible-only"};');
test("Diagnostic bytes cannot be admitted while export is active",()=>assert.equal(partialGuard({exporting:true,tracks:[]}).status,"unavailable-before-cleanup"));
test("Diagnostic bytes cannot be admitted with any live track",()=>assert.equal(partialGuard({exporting:false,tracks:[{readyState:"live"}]}).status,"unavailable-before-cleanup"));
test("Stopped diagnostic bytes remain distinct from product success",()=>assert.equal(partialGuard({exporting:false,tracks:[{readyState:"ended"}]}).status,"eligible-only"));
// Execute the actual bounded dataavailable body without MediaRecorder/browser.
const listenerStart='if(fixture.collectDiagnosticPartial)super.addEventListener("dataavailable",event=>{';
const listenerEnd='\n    });for(const event';
assert.equal(source.split(listenerStart).length,2);
const listenerBody=source.split(listenerStart)[1].split(listenerEnd)[0];
const listenerFn=body=>new Function("fixture","log","event",body);
const freshPartial=()=>({collectDiagnosticPartial:true,partialBytes:0,partialChunks:[],partialCapped:false,partialEventCount:0});
function feedPartial(f,count,size=1,body=listenerBody){const rows=[],fn=listenerFn(body);
  for(let i=0;i<count;i++)fn.call({state:"recording"},f,(event,value)=>rows.push({event,...value}),{data:{size}});
  return rows;}
test("Metadata stays capped64 after the chunk cap clears its array repeatedly",()=>{
  const f=freshPartial(),rows=feedPartial(f,1024);
  assert.equal(rows.length,64);assert.equal(f.partialEventCount,64);assert.equal(f.partialBytes,1024);
  assert.equal(f.partialCapped,true);assert.equal(f.partialChunks.length,0);
});
test("Metadata stays capped64 after byte-cap refusal independently of chunk count",()=>{
  const f=freshPartial();assert.equal(feedPartial(f,1,8*1024*1024+1).length,1);
  assert.equal(f.partialCapped,true);assert.equal(f.partialChunks.length,0);
  assert.equal(feedPartial(f,1024).length,63);assert.equal(f.partialEventCount,64);
});
test("Exactly8MiB is retained but next byte refuses and clears Blob references",()=>{
  const f=freshPartial();feedPartial(f,1,8*1024*1024);
  assert.equal(f.partialCapped,false);assert.equal(f.partialChunks.length,1);
  feedPartial(f,1);assert.equal(f.partialCapped,true);assert.equal(f.partialChunks.length,0);
});
test("Empty events or disabled diagnostic collection create no metadata or Blob refs",()=>{
  const f=freshPartial();assert.equal(feedPartial(f,10,0).length,0);assert.equal(f.partialEventCount,0);
  f.collectDiagnosticPartial=false;assert.equal(feedPartial(f,10).length,0);assert.equal(f.partialBytes,0);assert.equal(f.partialChunks.length,0);
});
const resetCode='if(fixture.collectDiagnosticPartial){fixture.partialChunks=[];fixture.partialBytes=0;fixture.partialCapped=false;fixture.partialEventCount=0;}';
assert.equal(source.split(resetCode).length,2);
const reset=new Function("fixture",resetCode);
test("Actual per-export reset restarts cap once for the next export",()=>{
  const f=freshPartial();feedPartial(f,1024);reset(f);
  assert.equal(f.partialEventCount,0);assert.equal(f.partialBytes,0);assert.equal(f.partialCapped,false);
  assert.equal(feedPartial(f,1).length,1);assert.equal(f.partialEventCount,1);assert.equal(f.partialChunks.length,1);
});
const controls = [];
function control(name, mutant, input, change, expected, witness) {
  assert.notEqual(mutant, projection); let failure;
  try {assert.equal(execute(input, change, mutant).status, expected, witness);} catch (error) {failure = String(error);}
  assert(failure?.includes(witness), `${name} did not fail at its intended parser witness`); controls.push({name, status: "INTENDED_ASSERTION_REFUSAL", witness});
}
control("omit-time-bridge-completeness", projection.replace("!facts.clockAlignment.available || facts.unmatchedRequiredBegins", "facts.unmatchedRequiredBegins"), events.slice(1), () => {}, "captured-incomplete", "Missing native marker must refuse a complete trace");
control("omit-native-data-loss-completeness", projection.replace("facts.dataLossOccurred !== false || ", ""), events, f => {f.dataLossOccurred = true;}, "captured-incomplete", "Native data loss must refuse a complete trace");
control("omit-event-volume-cap", projection.replace('      if (facts.eventCount > limits.events) {facts.status = "incomplete-event-limit"; return;}\n', ""), many(40001), () => {}, "incomplete-event-limit", "Oversized native event input must refuse projection");
control("omit-required-native-category",projection.replace('event.cat.split(",").includes(videoNames.includes(event.name)?"media":event.name === "MediaStreamAudioDestinationHandler::Process" ? "disabled-by-default-webaudio.audionode" : "webaudio")','true'),events.map(e=>e.name===names[2]?{...e,cat:"webaudio"}:e),()=>{},"captured-incomplete","A channel-change event cannot substitute for destination processing");
let groupFailure;
try {
  const mutant=projection.replace('JSON.stringify([span.name,span.pid,span.tid])','JSON.stringify([span.name])');
  assert.notEqual(mutant,projection);
  const f=execute([...events,...events.slice(1).map(e=>({...e,pid:9,tid:8,ts:e.ts+90000}))],()=>{},mutant);
  assert.equal(f.callbackGroups.filter(g=>g.name===names[0]).length,2,"Different native threads must remain separate callback groups");
}catch(error){groupFailure=String(error);}
assert(groupFailure?.includes("Different native threads must remain separate callback groups"));
controls.push({name:"omit-native-thread-grouping",status:"INTENDED_ASSERTION_REFUSAL",witness:"Different native threads must remain separate callback groups"});
let counterFailure,resetFailure;
const boundedMetadata='if(fixture.partialEventCount<64){fixture.partialEventCount++;log("diagnostic.dataavailable",{bytes:event.data.size,recorderState:this.state});}';
assert.equal(listenerBody.split(boundedMetadata).length,2);
const oldMetadata='if(fixture.partialChunks.length<64)log("diagnostic.dataavailable",{bytes:event.data.size,recorderState:this.state});';
const oldBody=listenerBody.replace(boundedMetadata,oldMetadata);
try{assert.equal(feedPartial(freshPartial(),1024,1,oldBody).length,64,"Metadata must remain capped after chunk-array clearing");}catch(error){counterFailure=String(error);}
assert(counterFailure?.includes("Metadata must remain capped after chunk-array clearing"));
controls.push({name:"restore-old-resettable-metadata-cap",status:"INTENDED_ASSERTION_REFUSAL",witness:"Metadata must remain capped after chunk-array clearing",observedOldMetadataEvents:1024});
try{const f=freshPartial();feedPartial(f,1024);new Function("fixture",resetCode.replace('fixture.partialEventCount=0;',''))(f);
  assert.equal(feedPartial(f,1).length,1,"New export must reset its independent metadata counter");}catch(error){resetFailure=String(error);}
assert(resetFailure?.includes("New export must reset its independent metadata counter"));
controls.push({name:"omit-per-export-metadata-reset",status:"INTENDED_ASSERTION_REFUSAL",witness:"New export must reset its independent metadata counter"});

function videoControl(name,mutant,input,witness){
  assert.notEqual(mutant,projection);let failure;
  try{assert.equal(videoExecute(input,mutant).videoStageStatus,"captured-incomplete",witness);}catch(error){failure=String(error);}
  assert(failure?.includes(witness),`${name} did not expose its intended parser defect`);controls.push({name,status:"INTENDED_ASSERTION_REFUSAL",witness});
}
videoControl("omit-required-video-output",projection.replace('videoRequiredNames.some(name=>!facts.videoStageCounts[name])','false'),[...events,...videoEvents.filter(e=>e.name!=="MediaRecorderEncoderWrapper::OutputEncodeData")],"Missing encoded output cannot become complete video evidence");
videoControl("omit-video-category",projection.replace('event.cat.split(",").includes(videoNames.includes(event.name)?"media":event.name === "MediaStreamAudioDestinationHandler::Process" ? "disabled-by-default-webaudio.audionode" : "webaudio")','true'),[...events,...videoEvents.map(e=>({...e,cat:"webaudio"}))],"Wrong-category names cannot become native video evidence");
const compositePrefix='fixture.observeComposite=value=>{',requestPrefix='fixture.observeCaptureRequest=value=>{';
assert.equal(source.split(compositePrefix).length,2);assert.equal(source.split(requestPrefix).length,2);
const paintBody=source.split(compositePrefix)[1].split('};')[0];
const requestBody=source.split(requestPrefix)[1].split('};')[0];
const paintFn=body=>new Function('fixture','value',body);
const paintFixture=()=>({diagnosticPaints:[],diagnosticPaintsCapped:false,diagnosticRequests:[],diagnosticRequestsCapped:false,diagnosticRequestCount:0});
function feedPaint(f,n,body=paintBody){for(let i=0;i<n;i++)paintFn(body)(f,{index:1,timeline:.7,localTime:.2,phase:'segment-frame',beforeMs:100,afterMs:102,explicitRequestCount:1});return f;}
test("Completed paint observations retain bounded scalar timing and request count",()=>{const f=feedPaint(paintFixture(),1);assert.deepEqual(f.diagnosticPaints,[{index:1,timeline:.7,localTime:.2,phase:'segment-frame',beforeMs:100,afterMs:102,explicitRequestCount:1}]);assert.equal(f.diagnosticPaintsCapped,false);});
test("Paint observation cap is monotonic256 and honestly marks incomplete",()=>{const f=feedPaint(paintFixture(),513);assert.equal(f.diagnosticPaints.length,256);assert.equal(f.diagnosticPaintsCapped,true);});
test("Capture requests remain independently counted and capped256",()=>{const f=paintFixture(),fn=paintFn(requestBody);for(let i=0;i<513;i++)fn(f,{index:1,timeline:.5,beforeMs:100,afterMs:101,available:true,trackLive:true});assert.equal(f.diagnosticRequestCount,513);assert.equal(f.diagnosticRequests.length,256);assert.equal(f.diagnosticRequestsCapped,true);});
let paintFailure;
try{const f=feedPaint(paintFixture(),513,paintBody.replace('.diagnosticPaints.length<256','.diagnosticPaints.length<999'));assert.equal(f.diagnosticPaints.length,256,'Paint metadata cannot silently exceed its bound');}catch(error){paintFailure=String(error);}
assert(paintFailure?.includes('Paint metadata cannot silently exceed its bound'));controls.push({name:'omit-paint-observation-cap',status:'INTENDED_ASSERTION_REFUSAL',witness:'Paint metadata cannot silently exceed its bound'});
const supplySource=source.split('// BEGIN pure capture-supply observation\n')[1].split('// END pure capture-supply observation')[0];
const supply=new Function(supplySource+';return observeCaptureSupply;')();
const supplyFixture=()=>({nativeTrace:{videoStageStatus:'captured-required-video-stages',clockAlignment:{available:true,traceMarkerUs:1000000,pageWallBeforeMs:50,pageWallAfterMs:52},videoStageGroups:[{name:'VideoTrackRecorderImpl::OnVideoFrame',firstStartUs:1010000}]},trace:[{event:'start.call',at:50},{event:'pause.call',at:100}],diagnosticRequests:[{phase:'recorder-start',afterMs:50}],diagnosticPaints:[{index:0,afterMs:55},{index:0,afterMs:90}]});
test('Native first input bracket entirely before first pause establishes opening supply',()=>{const f=supply(supplyFixture());assert.equal(f.available,true);assert.deepEqual(f.firstInputPageBracketMs,[60,62]);assert.equal(f.openingInputObserved,true);assert.equal(f.completedOpeningPaintsBeforeFirstInput,1);});
test('Late native first input retains missed opening despite completed paints',()=>{const a=supplyFixture();a.nativeTrace.videoStageGroups[0].firstStartUs=1200000;const f=supply(a);assert.equal(f.openingInputObserved,false);assert.equal(f.completedOpeningPaintsBeforeFirstInput,2);});
test('Clock uncertainty straddling pause cannot be called opening supply',()=>{const a=supplyFixture();a.trace[1].at=61;assert.equal(supply(a).openingInputObserved,false);});
test('Missing marker/native stage or request remains unknown',()=>{const a=supplyFixture();a.nativeTrace.clockAlignment.available=false;assert.equal(supply(a).openingInputObserved,null);const b=supplyFixture();b.diagnosticRequests=[];assert.equal(supply(b).available,false);});
test('Multiple native input identities cannot invent one recorder supply',()=>{const a=supplyFixture();a.nativeTrace.videoStageGroups.push({...a.nativeTrace.videoStageGroups[0]});assert.equal(supply(a).available,false);});
let supplyFailure;
try{const mutant=new Function(supplySource.replace('firstInputPageBracketMs[1]<pause.at','true')+';return observeCaptureSupply;')(),a=supplyFixture();a.nativeTrace.videoStageGroups[0].firstStartUs=1200000;assert.equal(mutant(a).openingInputObserved,false,'Late first native input cannot pretend to precede opening pause');}catch(error){supplyFailure=String(error);}
assert(supplyFailure?.includes('Late first native input cannot pretend to precede opening pause'));controls.push({name:'omit-native-opening-supply-admission',status:'INTENDED_ASSERTION_REFUSAL',witness:'Late first native input cannot pretend to precede opening pause'});

assert.equal(createHash("sha256").update(readFileSync(path)).digest("hex"), before);
const result = {status: "PASS_CLOSED_EXTRACTED_PROJECTION", source: "apps/studio/tests/export-resume-browser.mjs", sourceSHA256: before,
  projectionSHA256: createHash("sha256").update(projection).digest("hex"), tests: rows, compiledControls: controls,
  totals: {checks: rows.length, intendedCompiledRefusals: controls.length}, browserRuns: 0, cdpCalls: 0, networkCalls: 0,
  limits: "Only extracted actual projection, clock diagnostics and cleanup admission guards execute with synthetic values. Native protocol/transport/buffer callbacks, partial file serialization and actual export/refusal remain unexecuted."};
console.log(JSON.stringify(result, null, 2));
