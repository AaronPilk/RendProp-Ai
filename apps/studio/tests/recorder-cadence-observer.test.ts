import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdtemp, readFile, readdir, rm, stat} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import {recorderCadenceInit, installRecorderCadenceObserver,
  retainRecorderCadenceEvidence} from "./recorder-cadence-observer.mjs";

function fakeRealm({backendFirst = false, delayedResumeOverride = false} = {}) {
  const native = {calls: [], reads: 0, clock: 0, chunk: null,
    throwRequest: null, throwPause: null, throwConstructor: null,
    overrideRegistrations: [], scheduledTimers: 0};
  class TestBlob extends Blob {
    async arrayBuffer() { native.reads++; return super.arrayBuffer(); }
  }
  class Track {
    requestFrame(...args) {
      native.calls.push({method: "requestFrame", receiver: this, args});
      if (native.throwRequest) throw native.throwRequest;
      return native.requestResult;
    }
  }
  class NativeEventTarget {
    constructor() { this.listeners = new Map(); }
    addEventListener(type, callback) {
      const list = this.listeners.get(type) || [];
      list.push(callback); this.listeners.set(type, list);
    }
    emit(type, data = {}) {
      for (const callback of this.listeners.get(type) || []) callback({type, ...data});
    }
  }
  class Recorder extends NativeEventTarget {
    constructor(stream, options) {
      super();
      native.calls.push({method: "construct", receiver: this, args: [stream, options]});
      if (native.throwConstructor) throw native.throwConstructor;
      this.stream = stream;
      this.mimeType = "video/mp4;codecs=avc1.42e01e";
      this.stopResult = {nativeStop: true};
    }
    start(...args) {
      native.calls.push({method: "start", receiver: this, args});
      this.emit("start"); return native.startResult;
    }
    pause(...args) {
      native.calls.push({method: "pause", receiver: this, args});
      if (native.throwPause) throw native.throwPause;
      this.emit("pause"); return native.pauseResult;
    }
    resume(...args) {
      native.calls.push({method: "resume", receiver: this, args});
      this.emit("resume"); return native.resumeResult;
    }
    stop(...args) {
      native.calls.push({method: "stop", receiver: this, args});
      if (native.chunk) this.emit("dataavailable", {data: native.chunk});
      this.emit("stop"); return this.stopResult;
    }
  }
  const sandbox = {MediaRecorder: Recorder, EventTarget: NativeEventTarget,
    CanvasCaptureMediaStreamTrack: Track,
    Blob: TestBlob, fixture: {exporting: true},
    performance: {now: () => ++native.clock},
    btoa: binary => Buffer.from(binary, "binary").toString("base64")};
  const installDelayedOverride = () => {
    const Base = sandbox.MediaRecorder;
    sandbox.MediaRecorder = class DelayedResumeRecorder extends Base {
      addEventListener(type, callback) {
        native.overrideRegistrations.push(type);
        if (type === "resume") {
          native.scheduledTimers++;
          return super.addEventListener(type, event => callback(event));
        }
        return super.addEventListener(type, callback);
      }
    };
  };
  if (backendFirst) sandbox.MediaRecorder = class BackendRecorder extends sandbox.MediaRecorder {};
  if (backendFirst && delayedResumeOverride) installDelayedOverride();
  const context = vm.createContext(sandbox);
  vm.runInContext(`(${recorderCadenceInit.toString()})()`, context);
  if (!backendFirst) sandbox.MediaRecorder = class BackendRecorder extends sandbox.MediaRecorder {};
  if (!backendFirst && delayedResumeOverride) installDelayedOverride();
  const track = new Track();
  const stream = {getVideoTracks: () => [track]};
  return {native, sandbox, track, stream,
    make: () => new sandbox.MediaRecorder(stream, {mimeType: "video/mp4"}),
    product: blob => sandbox.__rendpropRecorderCadence.onProductBlob(blob),
    finish: retain => sandbox.__rendpropRecorderCadence.finishEpoch(retain),
    state: () => sandbox.__rendpropRecorderCadence.scalarState()};
}

function completedRecording(realm, bytes = "video") {
  const {native, sandbox, track} = realm;
  native.chunk = new sandbox.Blob([bytes], {type: "video/mp4"});
  const recorder = realm.make();
  recorder.start(500);
  track.requestFrame();
  recorder.stop();
  const product = new sandbox.Blob([native.chunk], {type: "video/mp4"});
  realm.product(product);
  sandbox.fixture.exporting = false;
  return {recorder, product};
}

test("preserves constructor, method, track receiver/arguments/results and native errors", async () => {
  for (const backendFirst of [false, true]) {
    const realm = fakeRealm({backendFirst});
    const {native, track} = realm;
    native.startResult = {start: true}; native.pauseResult = {pause: true};
    native.resumeResult = {resume: true}; native.requestResult = {frame: true};
    const recorder = realm.make();
    assert.equal(recorder.start(321), native.startResult);
    assert.equal(track.requestFrame("native-arg"), native.requestResult);
    assert.equal(recorder.pause("native-pause"), native.pauseResult);
    assert.equal(recorder.resume("native-resume"), native.resumeResult);
    native.chunk = new realm.sandbox.Blob(["abc"], {type: "video/mp4"});
    assert.equal(recorder.stop("native-stop"), recorder.stopResult);
    const nativeCalls = native.calls;
    assert.deepEqual(nativeCalls.map(row => row.method),
      ["construct", "start", "requestFrame", "pause", "resume", "stop"]);
    assert(nativeCalls.slice(1).every(row => row.receiver ===
      (row.method === "requestFrame" ? track : recorder)));
    assert.deepEqual(nativeCalls[1].args, [321]);
    assert.deepEqual(nativeCalls[2].args, ["native-arg"]);
    const pauseError = new Error("same error object"); native.throwPause = pauseError;
    assert.throws(() => recorder.pause(), error => error === pauseError);
    const requestError = new Error("same track error"); native.throwRequest = requestError;
    assert.throws(() => track.requestFrame(), error => error === requestError);
    const constructorError = new Error("same constructor error");
    native.throwConstructor = constructorError;
    assert.throws(() => realm.make(), error => error === constructorError);
    const result = await realm.finish(false);
    assert.equal(result.complete, false);
    assert(result.events.some(row => row.kind === "recorder.call" && row.outcome === "threw"));
  }
});

test("retains the direct product object only after settlement and resets for the next export", async () => {
  const realm = fakeRealm();
  const {recorder, product} = completedRecording(realm, "first-encoded-mp4");
  const {native} = realm;
  realm.sandbox.fixture.exporting = true;
  const pending = await realm.finish(true);
  assert.equal(pending.status, "incomplete-pending");
  assert.equal(native.reads, 0);
  assert.equal(realm.state().hasCandidate, true);
  realm.sandbox.fixture.exporting = false;
  const first = await realm.finish(true);
  assert.equal(first.status, "complete-with-private-bytes");
  assert.equal(first.complete, true);
  assert.equal(first.candidate.size, product.size);
  assert.equal(Buffer.from(first.encodedBytes, "base64").toString(), "first-encoded-mp4");
  assert.equal(native.reads, 1);
  assert.equal(realm.state().hasCandidate, false);
  assert.equal(realm.state().retainedChunks, 0);
  const nextEpoch = realm.state().epoch;
  recorder.emit("dataavailable", {data: new realm.sandbox.Blob(["late"], {type: "video/mp4"})});
  completedRecording(realm, "second");
  const second = await realm.finish(false);
  assert.equal(second.status, "complete-metadata-only");
  assert.equal(second.complete, true);
  assert.equal(second.epoch, nextEpoch);
  assert.equal(second.recorders.length, 1);
  assert.equal(second.recorders[0].chunkBytes, 6);
  assert.equal(native.reads, 1, "metadata-only success must never read bytes");
});

test("refuses unrelated or partial Blob custody and drops references on bounded overflow", async () => {
  for (const mismatch of ["partial", "non-mp4", "oversize"]) {
    const realm = fakeRealm();
    const {native, sandbox, track} = realm;
    native.chunk = new sandbox.Blob([mismatch === "oversize" ? Buffer.alloc(4 * 1024 * 1024 + 1) : "abcd"],
      {type: "video/mp4"});
    const recorder = realm.make(); recorder.start(); track.requestFrame(); recorder.stop();
    const product = mismatch === "partial" ? new sandbox.Blob(["ab"], {type: "video/mp4"}) :
      mismatch === "non-mp4" ? new sandbox.Blob(["abcd"], {type: "video/webm"}) :
      new sandbox.Blob([native.chunk], {type: "video/mp4"});
    realm.product(product); sandbox.fixture.exporting = false;
    const result = await realm.finish(true);
    assert.equal(result.complete, false);
    assert.equal(result.encodedBytes, undefined);
    assert.equal(native.reads, 0);
    assert(result.incomplete.length > 0);
    assert.equal(realm.state().retainedChunks, 0);
  }
  const realm = fakeRealm();
  const recorder = realm.make(); recorder.start();
  for (let index = 0; index < 8193; index++) realm.track.requestFrame();
  recorder.stop(); realm.sandbox.fixture.exporting = false;
  const overflow = await realm.finish(true);
  assert.equal(overflow.complete, false);
  assert(overflow.droppedEvents > 0);
  assert(overflow.incomplete.includes("event-cap"));
});

test("private retention writes a full hash and never reads bytes on metadata-only success", async () => {
  const artifacts = await mkdtemp(path.join(os.tmpdir(), "rendprop-recorder-control-"));
  try {
    const realm = fakeRealm();
    completedRecording(realm, "private-product-mp4");
    const page = {evaluate: (_function, retain) => realm.finish(retain)};
    const privateEvidence = await retainRecorderCadenceEvidence({page, artifacts, label: "failed-case"});
    assert.equal(privateEvidence.status, "complete-with-private-bytes");
    assert.equal(privateEvidence.complete, true);
    const bytes = await readFile(privateEvidence.media.path);
    assert.equal(bytes.toString(), "private-product-mp4");
    assert.equal(privateEvidence.media.sha256, createHash("sha256").update(bytes).digest("hex"));
    const json = JSON.parse(await readFile(privateEvidence.metadataPath, "utf8"));
    assert.equal(json.complete, true);
    assert.equal(json.encodedBytes, undefined);
    assert.equal((await stat(privateEvidence.media.path)).mode & 0o077, 0);
    assert.equal((await stat(privateEvidence.metadataPath)).mode & 0o077, 0);
    completedRecording(realm, "offered-product");
    const offered = await retainRecorderCadenceEvidence({page, artifacts, label: "offered-case", retainBytes: false});
    assert.equal(offered.status, "complete-metadata-only");
    assert.equal(offered.complete, true);
    assert.equal(offered.media, undefined);
    assert.equal((await readdir(artifacts)).filter(name => name.endsWith(".mp4")).length, 1);
    assert.equal(realm.native.reads, 1);
  } finally { await rm(artifacts, {recursive: true, force: true}); }
});

test("install uses exactly one initialization callback and keeps source self-contained", async () => {
  const scripts = [];
  await installRecorderCadenceObserver({addInitScript: callback => {scripts.push(callback);}});
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0], recorderCadenceInit);
  const realm = fakeRealm();
  assert.equal(realm.state().recorders, 0);
});

test("hostile error-name and native event getters never replace an original throw", async () => {
  const realm = fakeRealm();
  const recorder = realm.make();
  const hostile = Object.defineProperty({}, "name", {
    get() { throw new Error("hostile diagnostic name getter"); },
  });
  realm.native.throwPause = hostile;
  assert.throws(() => recorder.pause(), error => error === hostile);
  realm.native.throwRequest = hostile;
  assert.throws(() => realm.track.requestFrame(), error => error === hostile);
  realm.native.throwConstructor = hostile;
  assert.throws(() => realm.make(), error => error === hostile);
  assert.doesNotThrow(() => {
    const listeners = recorder.listeners.get("error");
    for (const listener of listeners) listener({get error() { throw new Error("hostile event getter"); }});
  });
  realm.sandbox.fixture.exporting = false;
  const evidence = await realm.finish(false);
  assert.equal(evidence.complete, false);
  assert(evidence.incomplete.includes("observer-error-name"));
  assert(evidence.incomplete.includes("observer-event-error-name"));
});

test("native listener registration bypasses delayed recorder subclass overrides", async () => {
  for (const backendFirst of [false, true]) {
    const realm = fakeRealm({backendFirst, delayedResumeOverride: true});
    const recorder = realm.make();
    assert.deepEqual(realm.native.overrideRegistrations, [],
      "Observer listeners must use captured EventTarget, not instance override");
    assert.equal(realm.native.scheduledTimers, 0);
    recorder.start(); realm.track.requestFrame(); recorder.resume();
    realm.sandbox.fixture.exporting = false;
    const evidence = await realm.finish(false);
    assert(evidence.events.some(row => row.kind === "recorder.event" && row.type === "resume"),
      "Native resume event must be observed promptly without the fixture delay");
    assert.equal(realm.native.scheduledTimers, 0);
  }
});
