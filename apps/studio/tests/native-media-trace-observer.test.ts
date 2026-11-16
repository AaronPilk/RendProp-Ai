import assert from "node:assert/strict";
import test from "node:test";
import {EventEmitter} from "node:events";
import {mkdtemp, readFile, rm, stat} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {MEDIA_TRACE_LIMITS, projectMediaTrace, startMediaTraceObserver,
  summarizeMediaTrace} from "./native-media-trace-observer.mjs";

const syncId = "fixed-original-media-before-click";
const trace = {traceEvents: [
  {name: "clock_sync", ts: 1_000_000, args: {sync_id: syncId}},
  {name: "VideoTrackRecorderImpl::OnVideoFrame", cat: "media", ph: "X", ts: 1_010_000, dur: 50, pid: 1, tid: 2},
  {name: "VideoTrackRecorderImpl::ProcessOneVideoFrame", cat: "media", ph: "B", ts: 1_011_000, pid: 1, tid: 2},
  {name: "VideoTrackRecorderImpl::ProcessOneVideoFrame", cat: "media", ph: "E", ts: 1_012_000, pid: 1, tid: 2},
  {name: "Encoder::StartFrameEncode", cat: "media", ph: "X", ts: 1_020_000, dur: 50, pid: 1, tid: 3,
    args: {sensitive: "must-never-appear-in-projection"}},
  {name: "MediaRecorderEncoderWrapper::OutputEncodeData", cat: "media", ph: "X", ts: 1_030_000, dur: 50, pid: 4, tid: 5},
  {name: "Encoder::StartFrameEncode", cat: "other", ph: "X", ts: 1_040_000, dur: 50, pid: 1, tid: 3},
]};

class FakeSession extends EventEmitter {
  calls: Array<{method: string; params?: Record<string, unknown>}> = [];
  detached = 0;
  startNever = false;
  closeThrows = false;
  detachThrows = false;
  raw: string;
  constructor(raw = JSON.stringify(trace)) {super(); this.raw = raw;}
  async send(method: string, params?: Record<string, unknown>) {
    this.calls.push({method, params});
    if (method === "Tracing.getCategories") return {categories: ["media"]};
    if (method === "Tracing.start" && this.startNever) return await new Promise<never>(() => {});
    if (method === "Tracing.end") {
      queueMicrotask(() => this.emit("Tracing.tracingComplete", {stream: "owned-stream", traceFormat: "json",
        streamCompression: "none", dataLossOccurred: false}));
      return {};
    }
    if (method === "IO.read") return {data: this.raw, eof: true, base64Encoded: false};
    if (method === "IO.close" && this.closeThrows) throw new Error("diagnostic-stream-close");
    return {};
  }
  async detach() {this.detached++; if (this.detachThrows) throw new Error("diagnostic-detach");}
}

test("native media projection counts exact phase entry events without arbitrary arguments or other categories", () => {
  const result = projectMediaTrace(trace, syncId, {beforeMs: 5000, afterMs: 5001});
  assert.equal(result.status, "projected");
  assert.equal(result.phaseCounts["VideoTrackRecorderImpl::OnVideoFrame"], 1);
  assert.equal(result.phaseCounts["VideoTrackRecorderImpl::ProcessOneVideoFrame"], 1);
  assert.equal(result.phaseCounts["Encoder::StartFrameEncode"], 1);
  assert.equal(result.phaseCounts["MediaRecorderEncoderWrapper::OutputEncodeData"], 1);
  assert.equal(result.alignment.available, true);
  assert.equal(JSON.stringify(result).includes("sensitive"), false);
  const summary = summarizeMediaTrace({...result, status: "captured", stopReason: "outcome-observed",
    traceComplete: true, clockAlignment: {...result.alignment, traceMarkerUs: result.traceMarkerUs},
    clockMarker: {beforeMs: 5000, afterMs: 5001}}, [{event: "start.call", at: 5000}]);
  assert.equal(summary.firstRecorderStartAligned, true);
  assert.equal(summary.firstTwoSeconds[0].atMs, 10);
  assert.equal(summary.firstTwoSeconds.length, 4);
  assert.equal(summary.phaseTiming["VideoTrackRecorderImpl::OnVideoFrame"].firstMs, 10);
  assert.equal(summary.phaseTiming["MediaRecorderEncoderWrapper::OutputEncodeData"].lastMs, 30);
  assert.equal(summary.phaseTiming["Encoder::StartFrameEncode"].firstTwoSeconds100MsBins[0], 1);
  assert.equal(summary.timingBinsComplete, true);
});

test("observer stops on first terminal observation, privately retains bounded raw trace, and detaches once", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-test-"));
  try {
    const session = new FakeSession();
    const browser = {newBrowserCDPSession: async () => session};
    const page = {evaluate: async () => 5000};
    const owner = await startMediaTraceObserver({browser, page, artifacts, syncId, sourceHashes: {fixture: "abc"}});
    assert.equal(owner.facts.status, "recording");
    const start = session.calls.find(row => row.method === "Tracing.start");
    assert.deepEqual(start?.params?.traceConfig?.includedCategories, ["media"]);
    assert.equal(start?.params?.traceConfig?.enableSampling, false);
    owner.stopCapture("outcome-observed");
    owner.stopCapture("poll-finished");
    await owner.finish();
    assert.equal(owner.facts.status, "captured");
    assert.equal(owner.facts.cleanupComplete, true);
    assert.equal(session.calls.filter(row => row.method === "Tracing.end").length, 1);
    assert.equal(session.detached, 1);
    assert.equal(owner.facts.raw.completeStream, true);
    assert.equal((await stat(owner.facts.raw.path)).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(await readFile(owner.facts.raw.path, "utf8")), trace);
    assert.equal((await owner.finish()).status, "captured");
    assert.equal(session.detached, 1);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});

test("raw byte and event budgets fail diagnostic completeness while closing owned CDP resources", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-budget-"));
  try {
    const raw = JSON.stringify(trace);
    const session = new FakeSession(raw);
    const owner = await startMediaTraceObserver({browser: {newBrowserCDPSession: async () => session},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {},
      limits: {...MEDIA_TRACE_LIMITS, rawBytes: 100}});
    owner.stopCapture("outcome-observed");
    await owner.finish();
    assert.equal(owner.facts.status, "incomplete-byte-limit", JSON.stringify(owner.facts));
    assert.equal(owner.facts.raw.bytes, 100);
    assert.equal(session.detached, 1);
    assert.equal(session.calls.filter(row => row.method === "IO.close").length, 1);

    const second = new FakeSession(raw);
    const eventOwner = await startMediaTraceObserver({browser: {newBrowserCDPSession: async () => second},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {}, rawFileName: "events.raw.private.json",
      limits: {...MEDIA_TRACE_LIMITS, events: 2}});
    eventOwner.stopCapture("outcome-observed");
    await eventOwner.finish();
    assert.equal(eventOwner.facts.status, "incomplete-event-limit");
    assert.equal(second.detached, 1);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});

test("malformed stream and synchronous end failure remain separate diagnostic errors", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-failure-"));
  try {
    const session = new FakeSession("{not-json");
    const original = session.send.bind(session);
    session.send = async (method: string, params?: Record<string, unknown>) => {
      if (method === "Tracing.end") {
        queueMicrotask(() => session.emit("Tracing.tracingComplete", {stream: "owned-stream", traceFormat: "json",
          streamCompression: "none", dataLossOccurred: false}));
        throw new Error("diagnostic-only-end-failure");
      }
      return original(method, params);
    };
    const owner = await startMediaTraceObserver({browser: {newBrowserCDPSession: async () => session},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {}});
    assert.doesNotThrow(() => owner.stopCapture("outcome-observed"));
    await owner.finish();
    assert.equal(owner.facts.status, "unavailable-or-incomplete");
    assert.equal(owner.facts.issues.some(issue => issue.stage === "end"), true);
    assert.equal(session.detached, 1);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});

test("timed-out start still sends one best-effort end and detaches a possibly late trace", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-late-start-"));
  try {
    const session = new FakeSession(); session.startNever = true;
    const owner = await startMediaTraceObserver({browser: {newBrowserCDPSession: async () => session},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {},
      limits: {...MEDIA_TRACE_LIMITS, startMs: 15}});
    assert.equal(owner.facts.status, "unavailable-start");
    owner.stopCapture("poll-finished");
    await owner.finish();
    assert.equal(session.calls.filter(row => row.method === "Tracing.end").length, 1);
    assert.equal(session.calls.filter(row => row.method === "IO.close").length, 1,
      "a late-start trace can still hand back an owned stream");
    assert.equal(session.detached, 1);
    assert.equal(owner.facts.cleanupComplete, true);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});

test("CDP cleanup failure never becomes a captured diagnostic; zero native phases stays inconclusive", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-cleanup-"));
  try {
    const session = new FakeSession(); session.closeThrows = true; session.detachThrows = true;
    const owner = await startMediaTraceObserver({browser: {newBrowserCDPSession: async () => session},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {}});
    owner.stopCapture("outcome-observed");
    await owner.finish();
    assert.equal(owner.facts.status, "captured-incomplete");
    assert.equal(owner.facts.cleanupComplete, false);
    assert.deepEqual(owner.facts.issues.map(issue => issue.stage), ["stream-close", "detach"]);
    const empty = projectMediaTrace({traceEvents: [trace.traceEvents[0]]}, syncId, {beforeMs: 5000, afterMs: 5001});
    assert.equal(empty.matchedPhaseEvents, 0);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});

test("a CDP session acquired after its deadline is detached later and cannot claim complete custody", async () => {
  const artifacts = await mkdtemp(join(tmpdir(), "native-media-observer-late-session-"));
  try {
    const session = new FakeSession();
    const owner = await startMediaTraceObserver({browser: {newBrowserCDPSession: () =>
      new Promise(resolve => setTimeout(() => resolve(session), 35))},
      page: {evaluate: async () => 5000}, artifacts, syncId, sourceHashes: {},
      limits: {...MEDIA_TRACE_LIMITS, sessionMs: 10}});
    assert.equal(owner.facts.status, "unavailable-start");
    await owner.finish();
    assert.equal(owner.facts.cleanupComplete, false);
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(session.detached, 1);
    assert.equal(owner.facts.lateSessionDetached, true);
  } finally {await rm(artifacts, {recursive: true, force: true});}
});
