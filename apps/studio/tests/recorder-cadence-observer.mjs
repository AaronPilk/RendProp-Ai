import assert from "node:assert/strict";
import {createHash, randomUUID} from "node:crypto";
import {mkdir, unlink, writeFile} from "node:fs/promises";
import path from "node:path";

// This function is serialized into the page before its fixture loads. Keep it
// self-contained: the browser must never import Node code or change an export.
export function recorderCadenceInit() {
  const scope = globalThis;
  const MAX_RECORDERS = 4;
  const MAX_EVENTS = 8192;
  const MAX_CHUNKS = 512;
  const MAX_BYTES = 4 * 1024 * 1024;
  const nativeRecorder = scope.MediaRecorder;
  const nativeTrack = scope.CanvasCaptureMediaStreamTrack;
  const nativeBlob = scope.Blob;
  let epoch = 1;
  let sequence = 0;
  let records = [];
  let events = [];
  let droppedEvents = 0;
  let incomplete = [];
  let candidate = null;
  let trackOwners = new WeakMap();
  let draining = false;

  const now = () => { try { return scope.performance.now(); } catch { return null; } };
  const fault = reason => {
    try {
      if (!incomplete.includes(reason)) incomplete.push(reason);
      // A partial trace must not retain media bytes for a later claim.
      for (const record of records) record.chunks = [];
      candidate = null;
    } catch { /* Observations never change the export. */ }
  };
  const mark = (kind, detail = {}) => {
    try {
      const row = {sequence: ++sequence, epoch, kind, wallMs: now(), ...detail};
      if (events.length < MAX_EVENTS) events.push(row);
      else { droppedEvents++; fault("event-cap"); }
      return row;
    } catch { fault("observer-mark"); return null; }
  };
  const safeField = (row, key, value) => {
    try { if (row) row[key] = value; } catch { fault("observer-field"); }
  };
  const safeErrorName = error => {
    try { return String(error?.name || "Error").slice(0, 80); }
    catch { fault("observer-error-name"); return "unavailable"; }
  };
  const finishCall = (row, outcome, error) => {
    safeField(row, "afterMs", now());
    safeField(row, "outcome", outcome);
    if (outcome === "threw") safeField(row, "errorName", safeErrorName(error));
  };
  const active = record => record.epoch === epoch;
  let nativeAddEventListener;
  try { nativeAddEventListener = scope.EventTarget?.prototype?.addEventListener; }
  catch { fault("native-listener-unavailable"); }
  if (typeof nativeAddEventListener !== "function") fault("native-listener-unavailable");

  // The native prototype method is called once with the exact receiver and
  // arguments. The observer's own bookkeeping is fail-open.
  let nativeRequest;
  try { nativeRequest = nativeTrack?.prototype?.requestFrame; }
  catch { fault("requestFrame-wrapper-unavailable"); }
  if (typeof nativeRequest === "function") {
    try {
      nativeTrack.prototype.requestFrame = new Proxy(nativeRequest, {
        apply(target, thisArg, args) {
          const record = trackOwners.get(thisArg);
          if (record && active(record)) record.requestCount++;
          const row = record && active(record) ? mark("requestFrame.call", {recorderId: record.id}) : null;
          try {
            const result = Reflect.apply(target, thisArg, args);
            if (record && active(record)) record.requestReturnedCount++;
            finishCall(row, "returned");
            return result;
          } catch (error) {
            finishCall(row, "threw", error);
            throw error;
          }
        },
      });
    } catch { fault("requestFrame-wrapper-unavailable"); }
  } else fault("requestFrame-unavailable");

  const observeRecorder = (recorder, args) => {
    if (records.length >= MAX_RECORDERS) { fault("recorder-cap"); return; }
    const record = {id: records.length + 1, epoch, stopped: false, chunks: [],
      requestCount: 0, requestReturnedCount: 0,
      startCalls: 0, startReturnedCount: 0, stopCalls: 0, stopReturnedCount: 0,
      startEvents: 0, stopEvents: 0,
      chunkCount: 0, chunkBytes: 0, zeroChunkCount: 0,
      mimeType: typeof recorder.mimeType === "string" ? recorder.mimeType : ""};
    records.push(record);
    mark("recorder.constructed", {recorderId: record.id, mimeType: record.mimeType});
    try {
      const tracks = args[0]?.getVideoTracks?.() || [];
      for (const track of tracks) if (track && typeof track.requestFrame === "function")
        trackOwners.set(track, record);
      if (tracks.length !== 1 || typeof tracks[0]?.requestFrame !== "function")
        fault("recorder-canvas-track-unavailable");
    } catch { fault("recorder-track-inspection"); }
    for (const type of ["start", "pause", "resume", "stop", "dataavailable", "error"]) {
      try {
        if (typeof nativeAddEventListener !== "function") break;
        // Call the genuine EventTarget method captured before the fixture
        // loads. The resume fixture intentionally overrides the instance
        // method to delay its own callback; observational listeners must not
        // enter that override or schedule an additional timer.
        Reflect.apply(nativeAddEventListener, recorder, [type, event => {
          try {
            if (!active(record)) return;
            if (type === "start") record.startEvents++;
            if (type === "stop") { record.stopped = true; record.stopEvents++; }
            if (type === "dataavailable") {
              if (record.stopped) fault("dataavailable-after-stop");
              const blob = event.data;
              const size = Number(blob?.size);
              if (!Number.isSafeInteger(size) || size < 0 || !(blob instanceof nativeBlob)) {
                fault("dataavailable-invalid-blob");
              } else if (size === 0) {
                record.zeroChunkCount++;
              } else {
                record.chunkCount++;
                record.chunkBytes += size;
                if (record.chunkCount > MAX_CHUNKS || record.chunkBytes > MAX_BYTES)
                  fault("chunk-cap");
                else if (incomplete.length === 0) record.chunks.push(blob);
              }
              mark("recorder.dataavailable", {recorderId: record.id,
                size: Number.isSafeInteger(size) && size >= 0 ? size : null});
            } else {
              let errorName;
              if (type === "error") {
                try { errorName = safeErrorName(event.error); }
                catch { fault("observer-event-error-name"); errorName = "unavailable"; }
              }
              mark("recorder.event", {recorderId: record.id, type, errorName});
            }
          } catch { fault("recorder-event-observation"); }
        }]);
      } catch { fault("recorder-listener-unavailable"); }
    }
    for (const name of ["start", "pause", "resume", "stop"]) {
      try {
        const native = recorder[name];
        Object.defineProperty(recorder, name, {configurable: true, value: new Proxy(native, {
          apply(target, thisArg, methodArgs) {
            if (active(record) && name === "start") record.startCalls++;
            if (active(record) && name === "stop") record.stopCalls++;
            const row = active(record) ? mark("recorder.call", {recorderId: record.id, method: name}) : null;
            try {
              const result = Reflect.apply(target, thisArg, methodArgs);
              if (active(record) && name === "start") record.startReturnedCount++;
              if (active(record) && name === "stop") record.stopReturnedCount++;
              finishCall(row, "returned");
              return result;
            } catch (error) {
              finishCall(row, "threw", error);
              throw error;
            }
          },
        })});
      } catch { fault("recorder-method-wrapper-unavailable"); }
    }
  };

  if (typeof nativeRecorder === "function") {
    try {
      scope.MediaRecorder = new Proxy(nativeRecorder, {
        construct(target, args, newTarget) {
          const row = mark("recorder.construct.call");
          try {
            const recorder = Reflect.construct(target, args, newTarget);
            finishCall(row, "returned");
            try { observeRecorder(recorder, args); } catch { fault("recorder-observation"); }
            return recorder;
          } catch (error) {
            finishCall(row, "threw", error);
            throw error;
          }
        },
      });
    } catch { fault("recorder-constructor-wrapper-unavailable"); }
  } else fault("recorder-unavailable");

  const reset = () => {
    for (const record of records) record.chunks = [];
    candidate = null; records = []; events = []; droppedEvents = 0; incomplete = [];
    trackOwners = new WeakMap(); epoch++;
  };
  const snapshot = () => ({epoch, sequence, events: events.map(row => ({...row})),
    droppedEvents, incomplete: [...incomplete],
    recorders: records.map(record => ({id: record.id, stopped: record.stopped,
      requestCount: record.requestCount, requestReturnedCount: record.requestReturnedCount,
      startCalls: record.startCalls, startReturnedCount: record.startReturnedCount,
      stopCalls: record.stopCalls, stopReturnedCount: record.stopReturnedCount,
      startEvents: record.startEvents, stopEvents: record.stopEvents,
      chunkCount: record.chunkCount, chunkBytes: record.chunkBytes,
      zeroChunkCount: record.zeroChunkCount, mimeType: record.mimeType})),
    candidate: candidate && {recorderId: candidate.recordId, size: candidate.blob.size,
      type: candidate.blob.type, source: "direct-post-stop-product-object"}});

  scope.__rendpropRecorderCadence = {
    onProductBlob(blob) {
      try {
        const matches = records.filter(record => active(record) && record.stopped &&
          record.chunkCount > 0 && record.chunkBytes === blob?.size &&
          record.chunks.length === record.chunkCount);
        const valid = incomplete.length === 0 && blob instanceof nativeBlob &&
          Number.isSafeInteger(blob.size) && blob.size > 0 && blob.size <= MAX_BYTES &&
          typeof blob.type === "string" && blob.type.startsWith("video/mp4") &&
          matches.length === 1 && records.length === 1;
        mark("productBlob.hook", {matchedRecorders: matches.length,
          size: Number.isSafeInteger(blob?.size) ? blob.size : null, accepted: valid});
        if (!valid) { fault("product-blob-custody-unverified"); return; }
        if (candidate) { fault("product-blob-duplicate"); return; }
        candidate = {blob, recordId: matches[0].id};
        // The direct product object is enough after static binding of the
        // sole new Blob(chunks, ...) source anchor. No chunk refs are needed.
        for (const record of records) record.chunks = [];
      } catch { fault("product-blob-hook-error"); }
    },
    async finishEpoch(retainBytes) {
      if (draining) return {status: "incomplete-busy", complete: false, ...snapshot()};
      if (scope.exportWebCodecsFixture && !scope.exportWebCodecsFixture.settled ||
          scope.fixture && scope.fixture.exporting)
        return {status: "incomplete-pending", complete: false, ...snapshot()};
      draining = true;
      try {
        const facts = snapshot();
        const observed = records.length === 1 && records[0].stopped &&
          records[0].requestReturnedCount > 0 && records[0].chunkCount > 0 &&
          candidate?.blob.size === records[0].chunkBytes && candidate?.recordId === records[0].id &&
          records[0].startCalls === 1 && records[0].startReturnedCount === 1 &&
          records[0].stopCalls === 1 && records[0].stopReturnedCount === 1 &&
          records[0].startEvents === 1 && records[0].stopEvents === 1;
        const complete = incomplete.length === 0 && droppedEvents === 0 &&
          !!candidate && observed;
        let encodedBytes;
        if (complete && retainBytes) {
          try {
            const raw = await candidate.blob.arrayBuffer();
            if (raw.byteLength !== candidate.blob.size || raw.byteLength > MAX_BYTES)
              throw new Error("candidate-size-changed");
            const bytes = new Uint8Array(raw);
            let binary = "";
            for (let i = 0; i < bytes.length; i += 32768)
              binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
            encodedBytes = scope.btoa(binary);
          } catch { facts.incomplete.push("post-settlement-read-failed"); }
        }
        return {status: !complete || facts.incomplete.length ? "incomplete" :
          retainBytes ? "complete-with-private-bytes" : "complete-metadata-only",
          complete: complete && facts.incomplete.length === 0,
          ...facts, ...(encodedBytes ? {encodedBytes} : {})};
      } finally {
        reset(); draining = false;
      }
    },
    // Fake-realm controls use this to verify no media references survive a
    // settled drain. It contains no Blob, AudioBuffer or other media object.
    scalarState() { return {epoch, recorders: records.length, events: events.length,
      hasCandidate: !!candidate, retainedChunks: records.reduce((sum, row) => sum + row.chunks.length, 0)}; },
  };
}

export async function installRecorderCadenceObserver(context) {
  await context.addInitScript(recorderCadenceInit);
}

export async function retainRecorderCadenceEvidence({page, artifacts, label, retainBytes = true}) {
  assert(page && typeof page.evaluate === "function", "A live page is required");
  assert(typeof artifacts === "string" && artifacts.length > 0, "An artifact directory is required");
  assert(typeof label === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(label), "A short safe label is required");
  const id = randomUUID();
  const stem = `${label}-${id}.recorder-diagnostic`;
  const metadataPath = path.join(artifacts, stem + ".json");
  const mediaPath = path.join(artifacts, stem + ".mp4");
  let result;
  try {
    result = await page.evaluate(retain => globalThis.__rendpropRecorderCadence?.finishEpoch(retain) ||
      {status: "incomplete-observer-unavailable"}, Boolean(retainBytes));
  } catch (error) {
    result = {status: "incomplete-page-evaluation", incomplete: [String(error?.message || error).slice(0, 160)]};
  }
  const {encodedBytes, ...facts} = result || {status: "incomplete-null-result"};
  if (typeof facts.complete !== "boolean") facts.complete = false;
  let media;
  if (encodedBytes !== undefined) {
    try {
      assert.equal(facts.status, "complete-with-private-bytes");
      assert(typeof encodedBytes === "string" && encodedBytes.length <= Math.ceil(4 * 1024 * 1024 / 3) * 4);
      media = Buffer.from(encodedBytes, "base64");
      assert(media.length > 0 && media.length <= 4 * 1024 * 1024);
      assert.equal(media.toString("base64"), encodedBytes);
      assert.equal(media.length, facts.candidate?.size);
    } catch { media = undefined; facts.status = "incomplete-invalid-private-bytes"; facts.complete = false; }
  }
  if (retainBytes && facts.complete && !media) {
    facts.status = "incomplete-missing-private-bytes";
    facts.complete = false;
  }
  await mkdir(artifacts, {recursive: true});
  let mediaEvidence;
  if (media) {
    await writeFile(mediaPath, media, {flag: "wx", mode: 0o600});
    mediaEvidence = {path: mediaPath, bytes: media.length,
      sha256: createHash("sha256").update(media).digest("hex")};
  }
  const metadata = {schema: "rendprop-recorder-cadence-diagnostic-v1", label,
    ...facts, media: mediaEvidence || null,
    custody: "Direct reference to the product Blob at the bound post-stop source hook. " +
      "Matching native event byte totals are observed; source binding, not this observer, " +
      "establishes the constructor's chunk identities. No bytes are read before settlement."};
  const serialized = JSON.stringify(metadata, null, 2) + "\n";
  try { await writeFile(metadataPath, serialized, {flag: "wx", mode: 0o600}); }
  catch (error) { if (mediaEvidence) await unlink(mediaPath).catch(() => {}); throw error; }
  return {status: facts.status, complete: facts.complete, metadataPath,
    metadataSha256: createHash("sha256").update(serialized).digest("hex"), media: mediaEvidence};
}
