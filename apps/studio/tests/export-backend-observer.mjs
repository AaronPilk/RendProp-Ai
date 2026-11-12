import assert from "node:assert/strict";

export function simulatedUnsupportedEncoderPlugin() {
  let matches = 0;
  return {
    name: "test-only-simulated-unsupported-encoder-response",
    enforce: "pre",
    transform(code, id) {
      if (!id.split("?")[0].endsWith("/src/editor/encoder-worker.ts")) return;
      const seam = "if (!await isEncoderConfigurationSupported(config))";
      assert.equal(code.split(seam).length, 2,
        "Simulated unsupported response must match the sole real capability admission");
      matches++;
      return code.replace(seam,
        "if (!await isEncoderConfigurationSupported(config).then(() => false))");
    },
    // Worker builds may use a separate Vite plugin container. The harness
    // additionally requires an actual ENCODER_UNSUPPORTED reply and recorder.
    get matchedSourceCount() {return matches;},
  };
}

export function simulatedFinalizeHangPlugin() {
  let matches = 0;
  return {name: "test-only-owned-worker-finalize-hang", enforce: "pre",
    transform(code, id) {
      if (!id.split("?")[0].endsWith("/src/editor/encoder-worker.ts")) return;
      const seam = "await output!.finalize();";
      assert.equal(code.split(seam).length, 2, "Finalize control must match the sole actual worker finalization");
      matches++;
      return code.replace(seam,
        'self.postMessage({__rendpropExportTest:"finalize-entered"}); await new Promise<void>(()=>{});');
    },
    get matchedSourceCount() {return matches;},
  };
}

export function reducedOutputCapacityPlugin() {
  let matches = 0;
  return {name: "test-only-reduced-worker-output-capacity", enforce: "pre",
    transform(code, id) {
      if (!id.split("?")[0].endsWith("/src/editor/encoder-output.ts")) return;
      const seam = "MAX_EXTENT=PAGE_BYTES*MAX_PAGES";
      assert.equal(code.split(seam).length, 2, "Capacity control must match the sole actual extent ceiling");
      matches++; return code.replace(seam, "MAX_EXTENT=256");
    },
    get matchedSourceCount() {return matches;},
  };
}

export async function installExportBackendObserver(context) {
  await context.addInitScript(() => {
    const observation = {workers: 0, terminations: 0, recorderConstructions: 0,
      unsupportedReplies: 0, videoInputs: 0, audioInputs: 0, endInputs: 0,
      postedVideoInputs: 0, postedAudioInputs: 0, postedEndInputs: 0,
      postedAudioFrames: 0, maximumPendingVideo: 0, maximumPendingAudio: 0, workerConfigs: [],
      contexts: 0, contentStarts: 0, tracks: [], events: [], dropped: 0,
      playCalls: 0, playEvents: [], playDropped: 0,
      pcmWindowEvents: [], pcmWindowDropped: 0,
      workletModuleCalls: 0, workletModuleFulfilled: 0, workletModuleRejected: 0,
      workletNodes: 0, workletPortCloses: 0, workletDisconnects: 0, workletLifetimes: []};
    const owners = {workers: [], contexts: [], tracks: []};
    window.exportBackendObservation = observation;
    window.exportBackendOwners = owners;
    const record = row => {
      if (observation.events.length < 256) observation.events.push({wallMs: performance.now(), ...row});
      else observation.dropped++;
    };
    const retain = (key, dropped, row) => {
      if (observation[key].length === 32) {observation[key].shift(); observation[dropped]++;}
      observation[key].push(row);
    };
    if (typeof HTMLMediaElement === "function") {
      const nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function (...args) {
        // Return the exact native result. Observe its existing settlement
        // without delaying the call, awaiting it or replacing its Promise.
        const wallBeforeMs = performance.now();
        let result;
        try {result = Reflect.apply(nativePlay, this, args);}
        catch (error) {
          const wallAfterMs = performance.now();
          retain("playEvents", "playDropped", {call: ++observation.playCalls,
            wallBeforeMs, wallAfterMs, outcome: "threw", errorName: error?.name});
          throw error;
        }
        const wallAfterMs = performance.now();
        const row = {call: ++observation.playCalls, wallBeforeMs, wallAfterMs, outcome: "returned"};
        retain("playEvents", "playDropped", row);
        if (result instanceof Promise) void Promise.prototype.then.call(result,
          () => {row.wallSettledMs = performance.now(); row.settlement = "fulfilled";},
          error => {row.wallSettledMs = performance.now(); row.settlement = "rejected";
            row.errorName = error?.name;});
        return result;
      };
    }
    if (typeof AudioWorkletNode === "function") {
      const NativeWorklet = AudioWorkletNode;
      window.AudioWorkletNode = class extends NativeWorklet {
        constructor(...args) {
          super(...args);
          if (args[1] !== "rendprop-export-pcm-tap") return;
          observation.workletNodes++;
          const lifetime = {id: observation.workletNodes, portCloses: 0, disconnects: 0};
          if (observation.workletLifetimes.length < 12) observation.workletLifetimes.push(lifetime);
          const close = this.port.close, disconnect = this.disconnect;
          this.port.close = function (...args) {
            const result = Reflect.apply(close, this, args);
            observation.workletPortCloses++; lifetime.portCloses++; return result;
          };
          this.disconnect = function (...args) {
            const result = Reflect.apply(disconnect, this, args);
            observation.workletDisconnects++; lifetime.disconnects++; return result;
          };
          // Listen alongside the production handler; do not start the port,
          // read clocks, touch PCM buffers or retain chunk messages.
          this.port.addEventListener("message", event => {
            const source = event.data;
            if (!["armed", "done", "fault"].includes(source?.type)) return;
            const row = {type: source.type};
            for (const key of ["windowIndex", "outputBase", "frameCount", "sampleRate", "channels",
              "blockFrames", "credits", "startFrame", "endFrame", "frames", "blocks", "outstanding",
              "nextOutputBase", "sampleFrame", "relativeFrame", "sequence", "conservedCredits"])
              if (Number.isFinite(source[key])) row[key] = source[key];
            if (typeof source.code === "string") row.code = source.code.slice(0, 100);
            retain("pcmWindowEvents", "pcmWindowDropped", row);
          });
        }
      };
    }
    if (typeof Worker === "function") {
      const NativeWorker = Worker;
      window.Worker = class extends NativeWorker {
        constructor(...args) {
          super(...args); observation.workers++; owners.workers.push(this);
          this.observedPending = {video: new Set(), audio: new Set()};
          this.addEventListener("message", event => {
            const row = event.data;
            if (row?.__rendpropExportTest === "finalize-entered") {
              // Only the explicitly mutated control build emits this probe.
              // Keep it out of the unmodified production message protocol.
              event.stopImmediatePropagation();
              record({kind: "test-only.finalize-entered"});
              window.exportTestControl?.onTestWorkerProbe?.(row.__rendpropExportTest);
              return;
            }
            if (row?.type === "ack") this.observedPending[row.track]?.delete(row.sequence);
            if (row?.code === "ENCODER_UNSUPPORTED") observation.unsupportedReplies++;
            const summary = {kind: "worker.reply", type: row?.type, code: row?.code};
            record(summary); window.exportTestControl?.onWorkerReply?.(summary);
          });
        }
        postMessage(...args) {
          const row = args[0];
          const summary = {kind: "worker.input", type: row?.type, sequence: row?.sequence,
            startFrame: row?.startFrame, frameCount: row?.frameCount,
            config: row?.type === "init" ? row.config : undefined};
          if (row?.type === "video") observation.videoInputs++;
          if (row?.type === "audio") observation.audioInputs++;
          if (row?.type === "end") observation.endInputs++;
          record(summary);
          window.exportTestControl?.beforeWorkerInput?.(summary);
          const result = Reflect.apply(NativeWorker.prototype.postMessage, this, args);
          if (row?.type === "init") observation.workerConfigs.push(structuredClone(row.config));
          if (row?.type === "video") {
            observation.postedVideoInputs++; this.observedPending.video.add(row.sequence);
            observation.maximumPendingVideo = Math.max(observation.maximumPendingVideo, this.observedPending.video.size);
          }
          if (row?.type === "audio") {
            observation.postedAudioInputs++; observation.postedAudioFrames += row.frameCount;
            this.observedPending.audio.add(row.sequence);
            observation.maximumPendingAudio = Math.max(observation.maximumPendingAudio, this.observedPending.audio.size);
          }
          if (row?.type === "end") observation.postedEndInputs++;
          window.exportTestControl?.afterWorkerInput?.(summary);
          return result;
        }
        terminate() {
          observation.terminations++; record({kind: "worker.terminate"});
          return super.terminate();
        }
      };
    }
    if (typeof AudioContext === "function") {
      const NativeAudio = AudioContext;
      window.AudioContext = class extends NativeAudio {
        constructor(...args) {
          super(...args); observation.contexts++; owners.contexts.push(this);
          const worklet = this.audioWorklet;
          if (worklet && typeof worklet.addModule === "function") {
            const addModule = worklet.addModule;
            worklet.addModule = function (...args) {
              const result = Reflect.apply(addModule, this, args); observation.workletModuleCalls++;
              if (result instanceof Promise) void Promise.prototype.then.call(result,
                () => {observation.workletModuleFulfilled++;},
                () => {observation.workletModuleRejected++;});
              return result;
            };
          }
        }
        createMediaStreamDestination() {
          const node = super.createMediaStreamDestination();
          for (const track of node.stream.getTracks()) owners.tracks.push(track);
          return node;
        }
        createBufferSource() {
          const node = super.createBufferSource(), start = node.start;
          node.start = (...args) => {
            observation.contentStarts++; record({kind: "content.buffer.start"});
            return Reflect.apply(start, node, args);
          };
          return node;
        }
      };
    }
    if (typeof MediaRecorder === "function") {
      const NativeRecorder = MediaRecorder;
      window.MediaRecorder = class extends NativeRecorder {
        constructor(...args) {
          super(...args); observation.recorderConstructions++;
          for (const track of args[0].getTracks()) owners.tracks.push(track);
          record({kind: "recorder.construct"});
        }
      };
    }
  });
}

export async function exportBackendSnapshot(page) {
  return page.evaluate(() => ({
    ...window.exportBackendObservation,
    contextStates: window.exportBackendOwners.contexts.map(value => value.state),
    trackStates: window.exportBackendOwners.tracks.map(value => value.readyState),
  }));
}
