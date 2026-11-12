import workletURL from "./export-pcm-worklet.js?url";
import {AudioStartupClock, RecordingClock, MAX_RECORDING_DRIFT_SECONDS} from "./recording-clock";
import {awaitMediaOperation, throwIfAborted} from "./media";
import type {ExportAudioBootstrap} from "./export-audio-bootstrap";

const RATE = 48_000;
const CHANNELS = 2;
const BLOCK = 1024;
const CREDITS = 8;
const LEAD = 8192;
const MIN_REMAINING_LEAD = 4096;
// A second live clip may use a new, independently owned tap on the same
// AudioContext. Register the processor module once; registering its name again
// in the same worklet global scope can refuse an otherwise valid edit.
const loadedWorkletModules = new WeakMap<AudioContext, Promise<void>>();

function loadWorkletModule(audio: AudioContext): Promise<void> {
  let loaded = loadedWorkletModules.get(audio);
  if (!loaded) {
    loaded = audio.audioWorklet.addModule(workletURL);
    loadedWorkletModules.set(audio, loaded);
  }
  return loaded;
}

type Armed = {type: "armed"; windowIndex: number; outputBase: number;
  frameCount: number; sampleRate: number; channels: number; blockFrames: number;
  credits: number; startFrame: number; endFrame: number};
type Chunk = {type: "chunk"; windowIndex: number; outputBase: number;
  sequence: number; startFrame: number; frameCount: number;
  channels: number; buffer: ArrayBuffer};
type Done = {type: "done"; windowIndex: number; outputBase: number;
  frames: number; blocks: number; outstanding: number; nextOutputBase: number};
type Fault = {type: "fault"; code: string; windowIndex: number;
  sampleFrame: number; relativeFrame: number; sequence: number;
  outstanding: number; conservedCredits: number};
type WorkletMessage = Armed | Chunk | Done | Fault;

type Active = {
  index: number; base: number; frames: number; nextSequence: number;
  nextFrame: number; queueDepth: number; returned: number;
  pump: Promise<void>; armed: Promise<Armed>; done: Promise<Done>;
  resolveArmed: (value: Armed) => void; rejectArmed: (error: Error) => void;
  resolveDone: (value: Done) => void; rejectDone: (error: Error) => void;
  armSeen: boolean; doneSeen: boolean; failure: Error | null;
};
export type PCMWindow = {
  index: number; outputBase: number; frameCount: number;
  /** Schedule sources at the fixed absolute AudioContext origin. */
  startAt(originSeconds: number): void;
  /** Observe media progress without moving the origin or padding samples. */
  watch(originSeconds: number, waitTo: (seconds: number) => Promise<void>): Promise<void>;
};
export type PCMWindowResult = {index: number; outputBase: number;
  frameCount: number; blocks: number; startFrame: number; endFrame: number};

type AudioEncoderCredit = {
  addAudio(buffer: ArrayBuffer, startFrame: number, frameCount: number): Promise<ArrayBuffer>;
};
const asError = (value: unknown): Error =>
  value instanceof Error ? value : new Error(String(value));

function waitOwned(signal: AbortSignal, milliseconds: number): Promise<void> {
  throwIfAborted(signal);
  return new Promise<void>((resolve, reject) => {
    const cleanup = () => {clearTimeout(timer); signal.removeEventListener("abort", aborted);};
    const aborted = () => {
      cleanup();
      reject(signal.reason instanceof Error ? signal.reason :
        new DOMException("Operation cancelled.", "AbortError"));
    };
    const timer = setTimeout(() => {cleanup(); resolve();}, Math.max(1, milliseconds));
    signal.addEventListener("abort", aborted, {once: true});
    if (signal.aborted) aborted();
  });
}

/** The browser must deliver a paint/clock turn while the finite PCM window runs. */
function nextFrame(signal: AbortSignal, remainingMs: number): Promise<void> {
  throwIfAborted(signal);
  return new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      cancelAnimationFrame(frame);
      clearTimeout(timer);
      signal.removeEventListener("abort", aborted);
    };
    const done = () => {cleanup(); resolve();};
    const aborted = () => {
      cleanup();
      reject(signal.reason instanceof Error ? signal.reason :
        new DOMException("Operation cancelled.", "AbortError"));
    };
    const frame = requestAnimationFrame(done);
    const timer = setTimeout(done, Math.max(1, Math.min(remainingMs, 1000 / 30)));
    signal.addEventListener("abort", aborted, {once: true});
    if (signal.aborted) aborted();
  });
}

/** One worklet and one AAC timeline; every clip re-arms an exact finite window. */
export async function createExportPCMCapture(options: {
  begun: ExportAudioBootstrap; encoder: AudioEncoderCredit; signal: AbortSignal;
  initialIndex: number; initialBase: number;
  requireCurrent(): void; fail(error: Error): void;
}) {
  const {begun, encoder, signal, requireCurrent, fail,
    initialIndex, initialBase} = options;
  if (!Number.isSafeInteger(initialIndex) || initialIndex < 0 || initialIndex >= 12 ||
      !Number.isSafeInteger(initialBase) || initialBase < 0 ||
      initialBase >= 180 * RATE)
    throw new Error("The first PCM window is invalid. No download was created.");
  const audio = begun.context;
  let disposed = false;
  let active: Active | null = null;
  let nextIndex = initialIndex;
  let nextBase = initialBase;
  let fault: Fault | null = null;
  const bus = audio.createGain();
  bus.gain.value = 1;
  bus.channelCount = CHANNELS;
  bus.channelCountMode = "explicit";
  const zero = audio.createConstantSource();
  zero.offset.value = 0;
  let zeroStarted = false;
  let tap: AudioWorkletNode | null = null;

  const check = () => {
    if (disposed) throw new Error("Audio capture was disposed. No download was created.");
    throwIfAborted(signal);
    requireCurrent();
    if (audio.state !== "running")
      throw new Error("Audio stopped during export. No download was created.");
    if (fault) throw new Error(`PCM capture refused ${fault.code}. No download was created.`);
    if (active?.failure) throw active.failure;
  };
  const reject = (error: Error) => {
    if (active && !active.failure) {
      active.failure = error;
      active.rejectArmed(error);
      active.rejectDone(error);
    }
    if (!signal.aborted) fail(error);
  };
  const handleChunk = (row: Chunk) => {
    const state = active;
    if (!state || !state.armSeen || state.doneSeen || state.failure ||
        row.windowIndex !== state.index || row.outputBase !== state.base ||
        !Number.isSafeInteger(row.sequence) || row.sequence !== state.nextSequence ||
        !Number.isSafeInteger(row.startFrame) || row.startFrame !== state.nextFrame ||
        !Number.isSafeInteger(row.frameCount) || row.frameCount < 1 ||
        row.frameCount > BLOCK || state.nextFrame + row.frameCount > state.frames ||
        row.channels !== CHANNELS || !(row.buffer instanceof ArrayBuffer) ||
        row.buffer.byteLength !== CHANNELS * BLOCK * 4) {
      reject(new Error("PCM sequence or window changed. No download was created."));
      return;
    }
    state.nextSequence++;
    state.nextFrame += row.frameCount;
    state.queueDepth++;
    if (state.queueDepth > CREDITS) {
      reject(new Error("PCM queue overflowed. No download was created."));
      return;
    }
    state.pump = state.pump.then(async () => {
      check();
      const planar = new Float32Array(row.buffer);
      for (let channel = 0; channel < CHANNELS; channel++)
        for (let offset = 0; offset < row.frameCount; offset++)
          if (!Number.isFinite(planar[channel * BLOCK + offset]))
            throw new Error("PCM contained a nonfinite sample. No download was created.");
      // The worker owns this exact fixed block during add and returns the same
      // transferred credit. It packs a short tail without padding output PCM.
      const returned = await encoder.addAudio(row.buffer, state.base + row.startFrame,
        row.frameCount);
      check();
      if (!(returned instanceof ArrayBuffer) || returned.byteLength !== CHANNELS * BLOCK * 4)
        throw new Error("The audio encoder did not return its buffer. No download was created.");
      tap?.port.postMessage({type: "recycle", buffer: returned}, [returned]);
      state.returned++;
      state.queueDepth--;
    }).catch(error => {reject(asError(error));});
  };

  try {
    await awaitMediaOperation(begun.resumeStarted, signal, "Starting export audio");
    await awaitMediaOperation(loadWorkletModule(audio), signal,
      "Loading export audio capture");
    tap = new AudioWorkletNode(audio, "rendprop-export-pcm-tap", {
      numberOfInputs: 1, numberOfOutputs: 1,
      outputChannelCount: [CHANNELS], channelCount: CHANNELS,
      channelCountMode: "explicit",
      processorOptions: {initialIndex, initialBase},
    });
    tap.addEventListener("processorerror", () =>
      reject(new Error("Audio capture processor failed. No download was created.")));
    zero.connect(bus);
    bus.connect(tap);
    tap.connect(begun.sink);
    zero.start();
    zeroStarted = true;
    tap.port.onmessage = ({data}: MessageEvent<WorkletMessage>) => {
      if (data?.type === "fault") {
        fault = data;
        reject(new Error(`PCM capture refused ${data.code}. No download was created.`));
      } else if (data?.type === "armed") {
        if (!active || active.armSeen)
          reject(new Error("Unexpected PCM arm. No download was created."));
        else {active.armSeen = true; active.resolveArmed(data);}
      } else if (data?.type === "chunk") handleChunk(data);
      else if (data?.type === "done") {
        if (!active || !active.armSeen || active.doneSeen ||
            data.windowIndex !== active.index || data.outputBase !== active.base)
          reject(new Error("Unexpected PCM completion. No download was created."));
        else {active.doneSeen = true; active.resolveDone(data);}
      } else reject(new Error("Unknown PCM message. No download was created."));
    };
    const clock = new AudioStartupClock();
    const deadline = performance.now() + 2000;
    while (true) {
      check();
      const now = performance.now();
      if (now >= deadline)
        throw new Error("Audio did not begin advancing before export. No download was created.",
          {cause: {readings: [...clock.readings]}});
      if (clock.read(now / 1000, audio.currentTime)) break;
      await waitOwned(signal, Math.min(1000 / 30, deadline - now));
    }
  } catch (error) {
    if (tap) {tap.port.onmessage = null; tap.port.close(); tap.disconnect();}
    bus.disconnect();
    if (zeroStarted) zero.stop();
    zero.disconnect();
    throw error;
  }

  return {
    bus,
    async captureWindow(window: PCMWindow): Promise<PCMWindowResult> {
      check();
      if (active || window.index !== nextIndex || window.outputBase !== nextBase ||
          !Number.isSafeInteger(window.frameCount) || window.frameCount < 1 ||
          window.frameCount > 180 * RATE || nextBase + window.frameCount > 180 * RATE)
        throw new Error("PCM window order changed. No download was created.");
      let resolveArmed!: Active["resolveArmed"], rejectArmed!: Active["rejectArmed"];
      let resolveDone!: Active["resolveDone"], rejectDone!: Active["rejectDone"];
      const armed = new Promise<Armed>((resolve, rejectPromise) => {
        resolveArmed = resolve; rejectArmed = rejectPromise;
      });
      const done = new Promise<Done>((resolve, rejectPromise) => {
        resolveDone = resolve; rejectDone = rejectPromise;
      });
      void armed.catch(() => undefined);
      void done.catch(() => undefined);
      const state: Active = {index: window.index, base: window.outputBase,
        frames: window.frameCount, nextSequence: 0, nextFrame: 0,
        queueDepth: 0, returned: 0, pump: Promise.resolve(), armed, done,
        resolveArmed, rejectArmed, resolveDone, rejectDone,
        armSeen: false, doneSeen: false, failure: null};
      active = state;
      try {
        tap!.port.postMessage({type: "arm", windowIndex: state.index,
          outputBase: state.base, frameCount: state.frames});
        const arm = await awaitMediaOperation(armed, signal, "Arming export PCM window");
        check();
        if (arm.windowIndex !== state.index || arm.outputBase !== state.base ||
            arm.frameCount !== state.frames || arm.sampleRate !== RATE ||
            arm.channels !== CHANNELS || arm.blockFrames !== BLOCK ||
            arm.credits !== CREDITS || arm.endFrame - arm.startFrame !== state.frames ||
            !Number.isSafeInteger(arm.startFrame))
          throw new Error("PCM origin changed. No download was created.");
        const remaining = arm.startFrame - Math.round(audio.currentTime * RATE);
        if (remaining < MIN_REMAINING_LEAD || remaining > LEAD)
          throw new Error("PCM armed too late. No download was created.");
        const origin = arm.startFrame / RATE;
        const sampledWall = performance.now();
        const sampledAudio = audio.currentTime;
        const wallOrigin = sampledWall + (origin - sampledAudio) * 1000;
        const clock = new RecordingClock();
        const readClock = () => clock.read((performance.now() - wallOrigin) / 1000,
          audio.currentTime - origin, audio.currentTime - origin);
        const waitTo = async (seconds: number) => {
          if (!Number.isFinite(seconds) || seconds < 0 ||
              seconds > state.frames / RATE)
            throw new Error("Invalid PCM target. No download was created.");
          while (audio.currentTime < origin + seconds) {
            check();
            if (audio.currentTime >= origin) readClock();
            await nextFrame(signal, Math.min(1000 / 30,
              (origin + seconds - audio.currentTime) * 1000));
          }
          check();
          readClock();
          if (audio.currentTime - origin - seconds > MAX_RECORDING_DRIFT_SECONDS)
            throw new Error("PCM boundary was late by more than two frames. No download was created.");
        };
        window.startAt(origin);
        check();
        if (audio.currentTime - origin > MAX_RECORDING_DRIFT_SECONDS)
          throw new Error("Audio setup missed its window origin. No download was created.");
        await window.watch(origin, waitTo);
        await waitTo(state.frames / RATE);
        const result = await awaitMediaOperation(done, signal, "Finishing export PCM window");
        await state.pump;
        check();
        const blocks = Math.ceil(state.frames / BLOCK);
        if (result.frames !== state.frames || result.blocks !== blocks ||
            result.nextOutputBase !== state.base + state.frames ||
            state.nextFrame !== state.frames || state.nextSequence !== blocks ||
            state.returned !== blocks || state.queueDepth !== 0)
          throw new Error("PCM window dropped or shifted sound. No download was created.");
        nextIndex++;
        nextBase += state.frames;
        return {index: state.index, outputBase: state.base,
          frameCount: state.frames, blocks,
          startFrame: arm.startFrame, endFrame: arm.endFrame};
      } catch (error) {
        reject(asError(error));
        await state.pump.catch(() => undefined);
        throw error;
      } finally {active = null;}
    },
    async dispose(): Promise<void> {
      if (disposed) return;
      disposed = true;
      if (active) reject(new Error("PCM capture was disposed. No download was created."));
      try {tap?.port.postMessage({type: "stop"});} catch { /* closed port */ }
      if (tap) {tap.port.onmessage = null; tap.port.close(); tap.disconnect();}
      bus.disconnect();
      if (zeroStarted) zero.stop();
      zero.disconnect();
    },
  };
}
