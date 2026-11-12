/*
 * External three-second diagnostic only. Captures original HTML-media sound
 * through the shipping-style Web Audio graph, before offline explicit video.
 */
import {AudioSample, type AudioSampleSource} from "mediabunny";
import workletURL from "./audible-pcm-worklet.js?url";
import {AudioStartupClock, RecordingClock} from "./recording-clock";
import {nextExportFrame, MAX_ORIGINAL_AUDIO_LOSS_SECONDS} from "./export";
import {assertCurrentRevision, type EditDraft} from "./model";
import {awaitMediaOperation, decodeMedia, seekMedia, throwIfAborted, type LocalMedia} from "./media";

const RATE = 48_000;
const CHANNELS = 2;
const BLOCK = 1024;
const CREDITS = 8;
const FRAMES = 3 * RATE;
const BLOCKS = Math.ceil(FRAMES / BLOCK);
const OPENING_SECONDS = .5;
const VIDEO_END_SECONDS = 2.5;
const ARM_LEAD_FRAMES = 8192;
const MIN_ARM_LEAD_FRAMES = 4096;
const epochNow = (): number | null => {
  try {
    return typeof Date !== "undefined" && typeof Date.now === "function"
      ? Date.now() : null;
  } catch { return null; }
};

type Arm = {
  type: "armed"; sampleRate: number; startFrame: number; endFrame: number;
  channels: number; blockFrames: number; credits: number;
};
type Chunk = {
  type: "chunk"; sequence: number; startFrame: number; frameCount: number;
  channels: number; buffer: ArrayBuffer;
};
type Done = {type: "done"; frames: number; blocks: number; outstanding: number};
type Fault = {
  type: "fault"; code: string; relativeFrame: number; sequence: number;
  outstanding: number; sampleFrame: number; credits: number;
  totalRecycles: number; maxOutstanding: number; poolLength: number;
  maxPoolLength: number; currentPresent: boolean; conservedCredits: number;
  lastRecycleFrame: number; lastFlushFrame: number;
  lastRecycleEpochMs: number | null; lastFlushEpochMs: number | null;
  faultEpochMs: number | null;
};
type Message = Arm | Chunk | Done | Fault;
type PhasePoint = {
  kind: string; wallMs: number; epochMs: number | null; audioSeconds: number;
  sequence: number | null;
  received: number; returned: number; queueDepth: number;
};
type AudioTimingSnapshot = {
  sampleRate: number; baseLatencySeconds: number | null;
  outputLatencySeconds: number | null; outputContextSeconds: number | null;
  outputPerformanceMs: number | null;
};
type ClockReadInput = {
  site: "loop" | "target"; targetSeconds: number;
  wallSeconds: number; timelineSeconds: number; audioSeconds: number;
  absoluteWallMs: number;
};
type FiniteClockReading = {
  wall: number | null; timeline: number | null;
  audio: number | null; drift: number | null;
};
type ClockFailure = {
  name: string; message: string; maxLossSeconds: number | null;
  readings: FiniteClockReading[];
};
type StartupReading = {wall: number; audio: number};
type StartupTrace = {
  startedWallMs: number | null; deadlineWallMs: number | null;
  polls: number; lastInput: StartupReading | null;
  readings: StartupReading[];
  failure: {name: string; message: string; causeReadings: StartupReading[]} | null;
};
type PlayTiming = {
  beforeCallWallMs: number | null; beforeCallAudioSeconds: number | null;
  afterCallWallMs: number | null; afterCallAudioSeconds: number | null;
  promiseSettledWallMs: number | null; promiseSettledAudioSeconds: number | null;
  promiseOutcome: "resolved" | "rejected" | null;
};
export type AudibleTrace = {
  kind: "audible-original-pcm-proof";
  workletStartFrame: number; workletEndFrame: number;
  frames: number; blocks: number; maxQueueDepth: number;
  maxAddMilliseconds: number; sampleRate: number; channels: number;
  firstVideoPlayAudioSeconds: number; finalVideoSourceSeconds: number;
  clockReadings: number; audioStateAtEnd: AudioContextState;
  mediaLossReadings: number; queueOverflow: boolean;
};

export type BegunAudio = {context: AudioContext; resumeStarted: Promise<void>};
type DiagnosticFault = "none" | "drop-first-block" | "withhold-credits";
const diagnosticFault = (): DiagnosticFault => {
  const raw = (window as typeof window & {audibleProofFault?: unknown}).audibleProofFault;
  if (raw === undefined || raw === "none") return "none";
  if (raw === "drop-first-block" || raw === "withhold-credits") return raw;
  throw new Error("Unknown diagnostic fault mode. No download was created.");
};

/** Call synchronously from the user's Export gesture, before codec/decode awaits. */
export function beginAudibleProofAudio(): BegunAudio {
  const context = new AudioContext({sampleRate: RATE});
  const resumeStarted = context.resume();
  // Capability and file checks run after the gesture. Keep the same rejection
  // for the eventual await without an early unhandled-rejection report.
  void resumeStarted.catch(() => undefined);
  return {context, resumeStarted};
}

async function readyAudioClock(audio: AudioContext, signal: AbortSignal,
  requireCurrent: () => void, trace: StartupTrace): Promise<void> {
  const clock = new AudioStartupClock();
  const started = performance.now(), deadline = started + 2000;
  trace.startedWallMs = started;
  trace.deadlineWallMs = deadline;
  try {
    while (true) {
      requireCurrent();
      if (audio.state !== "running")
        throw new Error("Audio stopped before proof capture. No download was created.");
      const now = performance.now();
      if (now >= deadline)
        throw new Error("Audio clock did not advance before proof capture. No download was created.",
          {cause: {readings: [...clock.readings]}});
      const input = {wall: now / 1000, audio: audio.currentTime};
      trace.lastInput = input;
      trace.polls++;
      const ready = clock.read(input.wall, input.audio);
      trace.readings = [...clock.readings];
      if (ready) return;
      // Match shipping pre-content readiness: one owned timer, independent
      // of the RAF-or-timer helper used after the capture origin is fixed.
      await new Promise<void>((resolve, reject) => {
        const cleanup = () => {clearTimeout(timer); signal.removeEventListener("abort", aborted);};
        const aborted = () => {
          cleanup();
          reject(signal.reason instanceof Error ? signal.reason :
            new DOMException("Operation cancelled.", "AbortError"));
        };
        const timer = setTimeout(() => {cleanup(); resolve();},
          Math.min(1000 / 30, deadline - now));
        signal.addEventListener("abort", aborted, {once: true});
        if (signal.aborted) aborted();
      });
    }
  } catch (error) {
    trace.readings = [...clock.readings];
    const cause = error instanceof Error && error.cause &&
      typeof error.cause === "object" ? error.cause as Record<string, unknown> : null;
    const rows = Array.isArray(cause?.readings) ? cause.readings.slice(-8) : [];
    trace.failure = {
      name: error instanceof Error ? error.name : "UnknownStartupError",
      message: error instanceof Error ? error.message : String(error),
      causeReadings: rows.filter((row: unknown): row is StartupReading =>
        Boolean(row && typeof row === "object" &&
          typeof (row as StartupReading).wall === "number" &&
          Number.isFinite((row as StartupReading).wall) &&
          typeof (row as StartupReading).audio === "number" &&
          Number.isFinite((row as StartupReading).audio))),
    };
    throw error;
  }
}

async function closeAudio(audio: AudioContext): Promise<void> {
  if (audio.state === "closed") return;
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const closed = await Promise.race([
    audio.close().then(() => true, () => false),
    new Promise<false>(resolve => {timeout = setTimeout(() => resolve(false), 2000);}),
  ]);
  if (timeout !== undefined) clearTimeout(timeout);
  const finalState = (): AudioContextState => audio.state;
  if (!closed || finalState() !== "closed")
    throw new Error("The proof AudioContext did not close. No download was created.");
}

/**
 * A three-second fixed window only. The Worklet owns absolute sampleFrame
 * capture; main-thread message arrival never determines AAC timestamps.
 */
export async function captureAudibleOriginalProof(options: {
  begun: BegunAudio;
  draft: EditDraft;
  media: Map<string, LocalMedia>;
  audioSource: AudioSampleSource;
  signal: AbortSignal;
  currentDraft: () => EditDraft;
  fail: (error: Error) => void;
}): Promise<AudibleTrace> {
  const {begun, draft, media, audioSource, signal, currentDraft, fail} = options;
  const audio = begun.context;
  const faultMode = diagnosticFault();
  const clip = draft.clips[1]!;
  const local = media.get(clip.id)!;
  let decoded: Awaited<ReturnType<typeof decodeMedia>> | undefined;
  let source: MediaElementAudioSourceNode | undefined;
  let originalGain: GainNode | undefined;
  let bus: GainNode | undefined;
  let tap: AudioWorkletNode | undefined;
  let sink: MediaStreamAudioDestinationNode | undefined;
  let zero: ConstantSourceNode | undefined;
  let zeroStarted = false;
  let resolveArm!: (value: Arm) => void;
  let rejectArm!: (error: Error) => void;
  let resolveDone!: (value: Done) => void;
  let rejectDone!: (error: Error) => void;
  const armed = new Promise<Arm>((resolve, reject) => {resolveArm = resolve; rejectArm = reject;});
  const done = new Promise<Done>((resolve, reject) => {resolveDone = resolve; rejectDone = reject;});
  // Rejections can precede awaitMediaOperation's attachment; retain handlers.
  void armed.catch(() => undefined);
  void done.catch(() => undefined);
  let nextSequence = 0, nextFrame = 0, queueDepth = 0, maxQueueDepth = 0;
  let maxAddMilliseconds = 0, mediaLossReadings = 0, clockReadings = 0;
  let pump: Promise<void> = Promise.resolve();
  let finishedWorklet = false;
  const playTiming: PlayTiming = {
    beforeCallWallMs: null, beforeCallAudioSeconds: null,
    afterCallWallMs: null, afterCallAudioSeconds: null,
    promiseSettledWallMs: null, promiseSettledAudioSeconds: null,
    promiseOutcome: null,
  };
  const observation = {kind: "audible-original-pcm-proof", phase: "preparing",
    frames: 0, blocks: 0, maxQueueDepth: 0, maxAddMilliseconds: 0,
    errors: [] as string[], workletStartFrame: -1, workletEndFrame: -1,
    audioStateAfterClose: "unknown", ownedTracksAfterClose: -1,
    mainReceivedCount: 0, mainReturnedCount: 0,
    workletFault: null as Fault | null, playTiming,
    audioTimingBeforeArm: null as AudioTimingSnapshot | null,
    predictedOrigin: null as {
      armStartFrame: number; armEndFrame: number; originAudioSeconds: number;
      sampledWallMs: number; sampledAudioSeconds: number;
      predictedWallOriginMs: number;
    } | null,
    clockReadInputs: [] as ClockReadInput[],
    clockFailure: null as ClockFailure | null,
    startupClock: {startedWallMs: null, deadlineWallMs: null,
      polls: 0, lastInput: null, readings: [], failure: null} as StartupTrace,
    phaseTimeline: [] as PhasePoint[]};
  (window as typeof window & {audiblePCMProof?: typeof observation}).audiblePCMProof = observation;
  const audioTiming = (): AudioTimingSnapshot => {
    let outputContextSeconds: number | null = null;
    let outputPerformanceMs: number | null = null;
    let baseLatencySeconds: number | null = null;
    let outputLatencySeconds: number | null = null;
    try {
      const stamp = audio.getOutputTimestamp?.();
      const contextTime = stamp?.contextTime;
      const performanceTime = stamp?.performanceTime;
      if (typeof contextTime === "number" && Number.isFinite(contextTime))
        outputContextSeconds = contextTime;
      if (typeof performanceTime === "number" && Number.isFinite(performanceTime))
        outputPerformanceMs = performanceTime;
    } catch { /* Output timestamp is observational and may be unavailable. */ }
    try {
      if (Number.isFinite(audio.baseLatency)) baseLatencySeconds = audio.baseLatency;
    } catch { /* Optional latency observation. */ }
    try {
      if (Number.isFinite(audio.outputLatency)) outputLatencySeconds = audio.outputLatency;
    } catch { /* Optional latency observation. */ }
    return {sampleRate: audio.sampleRate,
      baseLatencySeconds, outputLatencySeconds,
      outputContextSeconds, outputPerformanceMs};
  };
  const mark = (kind: string, sequence: number | null = null) => {
    // A fixed-size passive ring retains recent credit handoffs; playTiming
    // separately retains the native play edge. No timers or awaits are added.
    observation.phaseTimeline.push({kind, wallMs: performance.now(),
      epochMs: epochNow(),
      audioSeconds: audio.currentTime, sequence,
      received: observation.mainReceivedCount,
      returned: observation.mainReturnedCount, queueDepth});
    if (observation.phaseTimeline.length > 40) observation.phaseTimeline.shift();
  };
  const diagnosticControl = {suspend: () => audio.suspend(), state: () => audio.state};
  (window as typeof window & {audibleProofAudioControl?: typeof diagnosticControl}).audibleProofAudioControl = diagnosticControl;
  const requireCurrent = () => {
    throwIfAborted(signal);
    assertCurrentRevision(draft, currentDraft(), signal);
    if (document.hidden) throw new Error("The tab was hidden during proof capture. No download was created.");
  };
  const reject = (error: Error) => {
    if (observation.errors.length < 8) observation.errors.push(error.message);
    if (!signal.aborted) fail(error);
    rejectArm(error); rejectDone(error);
  };
  const handleChunk = (row: Chunk) => {
    observation.mainReceivedCount++;
    mark("chunk-received", row.sequence);
    if (finishedWorklet || !Number.isSafeInteger(row.sequence) || row.sequence !== nextSequence++ ||
        !Number.isSafeInteger(row.startFrame) || row.startFrame !== nextFrame ||
        !Number.isSafeInteger(row.frameCount) || row.frameCount < 1 || row.frameCount > BLOCK ||
        row.channels !== CHANNELS || !(row.buffer instanceof ArrayBuffer) ||
        row.buffer.byteLength !== CHANNELS * BLOCK * 4 ||
        nextFrame + row.frameCount > FRAMES) {
      reject(new Error("Worklet PCM sequence or window changed. No download was created."));
      return;
    }
    nextFrame += row.frameCount;
    observation.frames = nextFrame; observation.blocks = nextSequence;
    queueDepth++;
    maxQueueDepth = Math.max(maxQueueDepth, queueDepth);
    observation.maxQueueDepth = maxQueueDepth;
    if (queueDepth > CREDITS) {
      reject(new Error("Worklet PCM queue overflowed. No download was created."));
      return;
    }
    pump = pump.then(async () => {
      requireCurrent();
      const planar = new Float32Array(row.buffer);
      const exact = row.frameCount === BLOCK ? planar : (() => {
        const tail = new Float32Array(row.frameCount * CHANNELS);
        for (let channel = 0; channel < CHANNELS; channel++)
          tail.set(planar.subarray(channel * BLOCK, channel * BLOCK + row.frameCount),
            channel * row.frameCount);
        return tail;
      })();
      for (const sample of exact)
        if (!Number.isFinite(sample))
          throw new Error("Worklet PCM contains a nonfinite sample. No download was created.");
      const item = new AudioSample({
        format: "f32-planar", data: exact, numberOfChannels: CHANNELS,
        sampleRate: RATE, timestamp: row.startFrame / RATE,
      });
      const began = performance.now();
      try {
        await awaitMediaOperation(audioSource.add(item), signal, "Encoding proof original audio");
      } finally {item.close();}
      maxAddMilliseconds = Math.max(maxAddMilliseconds, performance.now() - began);
      observation.maxAddMilliseconds = maxAddMilliseconds;
      requireCurrent();
      if (faultMode !== "withhold-credits") {
        tap?.port.postMessage({type: "recycle", buffer: row.buffer}, [row.buffer]);
        if (tap) {
          observation.mainReturnedCount++;
          mark("recycle-posted", row.sequence);
        }
      }
      queueDepth--;
    }).catch(error => {
      reject(error instanceof Error ? error : new Error(String(error)));
    });
  };
  try {
    requireCurrent();
    decoded = await decodeMedia(local.url, "video", signal);
    const video = decoded.element;
    if (!(video instanceof HTMLVideoElement))
      throw new Error("The proof source is not a video. No download was created.");
    await seekMedia(video, clip.start, signal);
    video.playbackRate = 2;
    if (!video.preservesPitch)
      throw new Error("This browser does not preserve original pitch at 2×. No download was created.");
    video.muted = false;
    video.volume = 1;
    await awaitMediaOperation(begun.resumeStarted, signal, "Starting proof audio");
    await awaitMediaOperation(audio.audioWorklet.addModule(workletURL), signal, "Loading proof PCM tap");
    sink = audio.createMediaStreamDestination();
    bus = audio.createGain();
    bus.gain.value = 1;
    bus.channelCount = CHANNELS;
    bus.channelCountMode = "explicit";
    originalGain = audio.createGain();
    originalGain.gain.value = 1;
    source = audio.createMediaElementSource(video);
    source.connect(originalGain);
    originalGain.connect(bus);
    zero = audio.createConstantSource();
    zero.offset.value = 0;
    zero.connect(bus);
    tap = new AudioWorkletNode(audio, "rendprop-audible-proof-tap", {
      numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [CHANNELS],
      channelCount: CHANNELS, channelCountMode: "explicit",
      processorOptions: {faultMode},
    });
    tap.addEventListener("processorerror", () =>
      reject(new Error("Proof PCM processor failed. No download was created.")));
    bus.connect(tap);
    tap.connect(sink);
    zero.start();
    zeroStarted = true;
    tap.port.onmessage = ({data}: MessageEvent<Message>) => {
      if (data?.type === "armed") resolveArm(data);
      else if (data?.type === "chunk") handleChunk(data);
      else if (data?.type === "done") {
        finishedWorklet = true;
        resolveDone(data);
      } else if (data?.type === "fault") {
        observation.workletFault = data;
        mark("worklet-fault", data.sequence);
        reject(new Error(`Worklet PCM refused ${data.code}. No download was created.`));
      }
      else reject(new Error("Worklet returned an unknown message. No download was created."));
    };
    // Optional output/latency getters may lock the Web Audio graph. Query
    // before the active capture window and never inside the play bracket.
    observation.audioTimingBeforeArm = audioTiming();
    await readyAudioClock(audio, signal, requireCurrent, observation.startupClock);
    requireCurrent();
    mark("arm-request");
    tap.port.postMessage({type: "arm"});
    const arm = await awaitMediaOperation(armed, signal, "Arming proof PCM tap");
    mark("arm-ack");
    if (arm.sampleRate !== RATE || arm.channels !== CHANNELS ||
        arm.blockFrames !== BLOCK || arm.credits !== CREDITS ||
        arm.endFrame - arm.startFrame !== FRAMES ||
        !Number.isSafeInteger(arm.startFrame))
      throw new Error("Worklet capture origin changed. No download was created.");
    // The async arm acknowledgement must arrive before the exact sample window.
    if (arm.startFrame - Math.round(audio.currentTime * RATE) < MIN_ARM_LEAD_FRAMES ||
        arm.startFrame - Math.round(audio.currentTime * RATE) > ARM_LEAD_FRAMES)
      throw new Error("Worklet armed too late for an exact no-prefix origin. No download was created.");
    observation.phase = "capturing";
    observation.workletStartFrame = arm.startFrame;
    observation.workletEndFrame = arm.endFrame;
    mark("capture-armed");
    const origin = arm.startFrame / RATE;
    // Preserve the original evaluation order and wall-origin calculation;
    // retain its two sampled inputs for the passive clock diagnosis.
    const sampledWallMs = performance.now();
    const sampledAudioSeconds = audio.currentTime;
    const wallOrigin = sampledWallMs + (origin - sampledAudioSeconds) * 1000;
    observation.predictedOrigin = {
      armStartFrame: arm.startFrame, armEndFrame: arm.endFrame,
      originAudioSeconds: origin, sampledWallMs, sampledAudioSeconds,
      predictedWallOriginMs: wallOrigin,
    };
    const clock = new RecordingClock();
    const finite = (value: unknown): number | null =>
      typeof value === "number" && Number.isFinite(value) ? value : null;
    const readClock = (site: ClockReadInput["site"], target: number,
      wall: number, timeline: number): void => {
      observation.clockReadInputs.push({site, targetSeconds: target,
        wallSeconds: wall, timelineSeconds: timeline, audioSeconds: timeline,
        absoluteWallMs: wallOrigin + wall * 1000});
      if (observation.clockReadInputs.length > 8) observation.clockReadInputs.shift();
      try {
        clock.read(wall, timeline, timeline);
        clockReadings++;
      } catch (error) {
        const cause = error instanceof Error && error.cause &&
          typeof error.cause === "object" ?
          error.cause as Record<string, unknown> : null;
        const rows = Array.isArray(cause?.readings) ? cause.readings.slice(-8) : [];
        observation.clockFailure = {
          name: error instanceof Error ? error.name : "UnknownClockError",
          message: error instanceof Error ? error.message : String(error),
          maxLossSeconds: finite(cause?.maxLossSeconds),
          readings: rows.map((row: unknown): FiniteClockReading => {
            const value = row && typeof row === "object" ?
              row as Record<string, unknown> : {};
            return {wall: finite(value.wall), timeline: finite(value.timeline),
              audio: finite(value.audio), drift: finite(value.drift)};
          }),
        };
        throw error;
      }
    };
    const waitTo = async (target: number) => {
      while (audio.currentTime < origin + target) {
        requireCurrent();
        if (audio.state !== "running")
          throw new Error("Audio stopped during proof capture. No download was created.");
        const wall = (performance.now() - wallOrigin) / 1000;
        const timeline = audio.currentTime - origin;
        if (timeline >= 0) readClock("loop", target, wall, timeline);
        await nextExportFrame(signal, Math.min(1000 / 30, (origin + target - audio.currentTime) * 1000));
      }
      requireCurrent();
      if (audio.state !== "running")
        throw new Error("Audio stopped during proof capture. No download was created.");
      const wall = (performance.now() - wallOrigin) / 1000;
      const timeline = audio.currentTime - origin;
      readClock("target", target, wall, timeline);
      if (timeline - target > 2 / 30)
        throw new Error("Proof source boundary was late by more than two frames. No download was created.");
    };
    await waitTo(OPENING_SECONDS);
    mark("opening-boundary");
    const playAt = audio.currentTime;
    // Do not await the promise before measuring media progress: native playback
    // can start well before promise delivery, including the shipping 250 ms test.
    playTiming.beforeCallAudioSeconds = audio.currentTime;
    playTiming.beforeCallWallMs = performance.now();
    const played = video.play();
    playTiming.afterCallWallMs = performance.now();
    playTiming.afterCallAudioSeconds = audio.currentTime;
    mark("native-play-after-call");
    void played.then(() => {
      playTiming.promiseSettledWallMs = performance.now();
      playTiming.promiseSettledAudioSeconds = audio.currentTime;
      playTiming.promiseOutcome = "resolved";
      mark("native-play-resolved");
    }, () => {
      playTiming.promiseSettledWallMs = performance.now();
      playTiming.promiseSettledAudioSeconds = audio.currentTime;
      playTiming.promiseOutcome = "rejected";
      mark("native-play-rejected");
    });
    void played.catch(error => reject(error instanceof Error ? error : new Error(String(error))));
    let previousMedia = video.currentTime;
    let lastAdvance = performance.now();
    let markedFirstAdvance = false;
    while (audio.currentTime < origin + VIDEO_END_SECONDS) {
      await waitTo(Math.min(VIDEO_END_SECONDS, audio.currentTime - origin + 1 / 30));
      const now = performance.now();
      if (video.currentTime > previousMedia + .001) {
        previousMedia = video.currentTime;
        lastAdvance = now;
        if (!markedFirstAdvance) {mark("first-video-progress"); markedFirstAdvance = true;}
      }
      if (now - lastAdvance > 10_000)
        throw new Error("Proof source video stalled. No download was created.");
      if (audio.currentTime - playAt -
          Math.max(0, video.currentTime - clip.start) / 2 > MAX_ORIGINAL_AUDIO_LOSS_SECONDS) {
        if (++mediaLossReadings > 1)
          throw new Error("Original audio playback stalled during proof. No download was created.");
      } else mediaLossReadings = 0;
    }
    video.pause();
    await awaitMediaOperation(played, signal, "Playing proof original source");
    if (video.currentTime < clip.end - .1)
      throw new Error("The proof source did not reach its selected end. No download was created.");
    await waitTo(3);
    const complete = await awaitMediaOperation(done, signal, "Completing proof PCM window");
    await pump;
    requireCurrent();
    if (complete.frames !== FRAMES || complete.blocks !== BLOCKS ||
        nextFrame !== FRAMES || nextSequence !== BLOCKS || queueDepth !== 0)
      throw new Error("Worklet PCM frame count changed. No download was created.");
    observation.phase = "encoded-audio";
    return {kind: "audible-original-pcm-proof", workletStartFrame: arm.startFrame,
      workletEndFrame: arm.endFrame, frames: nextFrame, blocks: nextSequence,
      maxQueueDepth, maxAddMilliseconds, sampleRate: RATE, channels: CHANNELS,
      firstVideoPlayAudioSeconds: playAt - origin,
      finalVideoSourceSeconds: video.currentTime, clockReadings,
      audioStateAtEnd: audio.state, mediaLossReadings, queueOverflow: false};
  } catch (error) {
    // All exit paths end the producer and release a pending AAC add before
    // its buffer can be transferred back to a closed worklet port.
    if (!signal.aborted)
      fail(error instanceof Error ? error : new Error(String(error)));
    await pump.catch(() => undefined);
    throw error;
  } finally {
    try {tap?.port.postMessage({type: "stop"});} catch { /* Port may already be closed. */ }
    if (tap) {tap.port.onmessage = null; tap.port.close(); tap.disconnect();}
    source?.disconnect();
    originalGain?.disconnect();
    bus?.disconnect();
    if (zeroStarted) zero?.stop();
    zero?.disconnect();
    sink?.stream.getTracks().forEach(track => track.stop());
    decoded?.dispose();
    try {await closeAudio(audio);} finally {
      observation.audioStateAfterClose = audio.state;
      observation.ownedTracksAfterClose = sink?.stream.getTracks().filter(track => track.readyState !== "ended").length ?? 0;
      observation.phase = audio.state === "closed" && observation.ownedTracksAfterClose === 0
        ? "closed" : "cleanup-failed";
      delete (window as typeof window & {audibleProofAudioControl?: typeof diagnosticControl}).audibleProofAudioControl;
    }
  }
}
