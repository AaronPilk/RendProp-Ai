import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {inspectFile} from "../src/editor/media";
import {newDraft, validateDraft} from "../src/editor/model";

// Hold the first observed startup clock read independently of capture/recorder
// construction. Native Web Audio, capture timestamps and encoded samples stay
// real; this is a controlled startup trace, not the unknown hosted failure cause.
const fixture = {mode: "freeze", extension: "mp4", result: null as unknown,
  events: [] as Array<Record<string, unknown>>, diagnostics: {} as unknown};
Object.assign(window, {startupFixture: fixture});
document.querySelector("button")!.addEventListener("click", async () => {
  fixture.result = null; fixture.events = [];
  const controller = new AbortController(), timers: ReturnType<typeof setTimeout>[] = [];
  const NativeAudio = window.AudioContext, NativeRecorder = window.MediaRecorder;
  const nativeTime = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "currentTime")!.get!;
  const nativePlay = HTMLMediaElement.prototype.play;
  const nativeCapture = HTMLCanvasElement.prototype.captureStream;
  let audio: AudioContext | undefined, held = false, holdStarted = false, frozenTime = 0, revision = 1;
  const tracks = new Set<MediaStreamTrack>();
  const partial: Blob[] = [];
  let partialBytes = 0, recorderMime = "", partialCapped = false, lastMetricAt = -Infinity, recordingStarted = false;
  const diagnostics = {clockReads: [] as Array<Record<string, unknown>>, videoFrames: [] as Array<Record<string, unknown>>,
    longTasks: [] as Array<Record<string, unknown>>, contextOptions: undefined as AudioContextOptions | undefined, dropped: {} as Record<string, number>, observerErrors: [] as string[]};
  fixture.diagnostics = diagnostics;
  const push = (name: string, values: Array<Record<string, unknown>>, value: Record<string, unknown>) => {
    if (values.length < 2000) values.push(value);
    else diagnostics.dropped[name] = (diagnostics.dropped[name] ?? 0) + 1;
  };
  let longTaskObserver: PerformanceObserver | undefined;
  if (PerformanceObserver.supportedEntryTypes.includes("longtask")) {
    longTaskObserver = new PerformanceObserver(list => {for (const entry of list.getEntries())
      push("longTasks", diagnostics.longTasks, {start: entry.startTime, duration: entry.duration});});
    longTaskObserver.observe({entryTypes: ["longtask"]});
  }
  const observedVideos = new Map<HTMLVideoElement, number>();
  const observeVideo = (video: HTMLVideoElement) => {
    if (observedVideos.has(video) || !video.requestVideoFrameCallback) return;
    const frame: VideoFrameRequestCallback = (now, metadata) => {
      push("videoFrames", diagnostics.videoFrames, {wall: now, mediaTime: metadata.mediaTime,
        presentationTime: metadata.presentationTime, expectedDisplayTime: metadata.expectedDisplayTime,
        presentedFrames: metadata.presentedFrames});
      observedVideos.set(video, video.requestVideoFrameCallback(frame));
    };
    observedVideos.set(video, video.requestVideoFrameCallback(frame));
  };
  const observedTime = () => audio ? held ? frozenTime : nativeTime.call(audio) : undefined;
  const event = (kind: string) => push("events", fixture.events, {kind, wall: performance.now(), held,
    audio: observedTime(), nativeAudio: audio ? nativeTime.call(audio) : undefined,
    state: audio?.state});
  const holdStartup = () => {
    if (holdStarted || fixture.mode === "normal") return;
    holdStarted = true; frozenTime = nativeTime.call(audio); held = true; event("startup.held");
    if (fixture.mode !== "permanent") timers.push(setTimeout(() => { held = false; event("startup.released"); }, 180));
    if (fixture.mode === "abort") timers.push(setTimeout(() => controller.abort(new Error("Fixture startup cancelled")), 70));
    if (fixture.mode === "stale") timers.push(setTimeout(() => { revision = 2; event("revision.changed"); }, 70));
    if (fixture.mode === "suspended") void audio!.suspend();
  };
  let local: Awaited<ReturnType<typeof inspectFile>> | undefined;
  let finished: Record<string, unknown> | undefined;
  try {
    local = await inspectFile((document.querySelector("input") as HTMLInputElement).files![0], controller.signal);
    window.AudioContext = class extends NativeAudio {
      constructor(options?: AudioContextOptions) {
        super(options); audio = this; diagnostics.contextOptions = options ? {...options} : {};
        this.addEventListener("statechange", () => event("context.statechange"));
        Object.defineProperty(this, "currentTime", {get: () => {
          holdStartup();
          const nativeAudio = nativeTime.call(this), value = held ? frozenTime : nativeAudio;
          const wall = performance.now();
          let output: AudioTimestamp | undefined;
          try {output = this.getOutputTimestamp?.();} catch {if (!diagnostics.observerErrors.length) diagnostics.observerErrors.push("outputTimestamp unavailable");}
          push("clockReads", diagnostics.clockReads, {wall, held, returnedAudio: value, nativeAudio,
            state: this.state, visibility: document.visibilityState, sampleRate: this.sampleRate,
            baseLatency: this.baseLatency, outputLatency: this.outputLatency,
            outputContextTime: output?.contextTime, outputPerformanceTime: output?.performanceTime,
            videos: [...observedVideos.keys()].map(video => ({currentTime: video.currentTime, readyState: video.readyState,
              paused: video.paused, ended: video.ended, playbackRate: video.playbackRate}))});
          // Request at most eight nonblocking post-start CDP samples, driven by existing reads.
          if (recordingStarted && wall - lastMetricAt >= 200) {
            lastMetricAt = wall;
            const hook = (window as unknown as {startupDiagnosticMetric?: (wall: number) => Promise<void>}).startupDiagnosticMetric;
            void hook?.(wall).catch(() => {});
          }
          return value; // Exact existing observed hold logic; no altered native value.
        }});
      }
      createMediaStreamDestination(): MediaStreamAudioDestinationNode {
        const node = super.createMediaStreamDestination();
        for (const track of node.stream.getTracks()) {
          tracks.add(track);
          for (const name of ["mute", "unmute", "ended"]) track.addEventListener(name, () => event("audio.track." + name));
        }
        event("audio.destination.create");
        return node;
      }
      createBufferSource(): AudioBufferSourceNode {
        const node = super.createBufferSource(), start = node.start;
        node.start = (...args: Parameters<AudioBufferSourceNode["start"]>) => {
          event("user.buffer.start"); return Reflect.apply(start, node, args);
        };
        return node;
      }
    };
    HTMLCanvasElement.prototype.captureStream = function (frameRate?: number): MediaStream {
      const stream = Reflect.apply(nativeCapture, this, frameRate === undefined ? [] : [frameRate]);
      for (const track of stream.getTracks()) tracks.add(track);
      event("capture.create");
      return stream;
    };
    window.MediaRecorder = class extends NativeRecorder {
      constructor(stream: MediaStream, options?: MediaRecorderOptions) {
        super(stream, options);
        for (const track of stream.getTracks()) tracks.add(track);
        event("recorder.construct"); recorderMime = this.mimeType;
        for (const name of ["start", "pause", "resume", "stop", "error"]) this.addEventListener(name, () => event("recorder.event." + name));
        this.addEventListener("dataavailable", (e: BlobEvent) => {
          push("events", fixture.events, {kind: "recorder.dataavailable", wall: performance.now(), held,
            bytes: e.data.size, mime: e.data.type, recorderState: this.state});
          partialBytes += e.data.size;
          if (partialBytes <= 128 * 1024 * 1024 && !partialCapped) partial.push(e.data);
          else {partialCapped = true; partial.length = 0;}
        });
      }
      start(timeslice?: number): void { event("recorder.start"); super.start(timeslice); recordingStarted = true; }
      pause(): void {event("recorder.pause.call"); super.pause();}
      resume(): void {event("recorder.resume.call"); super.resume();}
      stop(): void {event("recorder.stop.call"); super.stop(); recordingStarted = false;}
    };
    HTMLMediaElement.prototype.play = function (...args) {
      if (this instanceof HTMLVideoElement) observeVideo(this);
      event("user.video.play"); return Reflect.apply(nativePlay, this, args);
    };
    const draft = validateDraft({...newDraft(), ratio: "16:9", clips: [{id: "source", source: local.source,
      start: 0, end: 1.5, caption: "", focusX: .5, focusY: .5, speed: 1}]});
    revision = draft.revision;
    const format = exportFormats().find(value => value.extension === fixture.extension)!;
    const result = await exportLocalVideo({draft, media: new Map([["source", local]]), format,
      signal: controller.signal, currentDraft: () => ({...draft, revision}), onProgress: () => {}});
    const bytes = new Uint8Array(await result.blob.arrayBuffer()); let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    finished = {ok: true, base64: btoa(binary), duration: result.duration};
  } catch (error) {
    finished = {ok: false, error: String(error), cause: error instanceof Error ? error.cause : undefined};
  } finally {
    longTaskObserver?.disconnect();
    for (const [video, callback] of observedVideos) video.cancelVideoFrameCallback(callback);
    for (const timer of timers) clearTimeout(timer);
    window.AudioContext = NativeAudio; window.MediaRecorder = NativeRecorder; HTMLMediaElement.prototype.play = nativePlay;
    HTMLCanvasElement.prototype.captureStream = nativeCapture;
    if (local) URL.revokeObjectURL(local.url);
    controller.abort();
    // A refused encoder's stop-flushed bytes are diagnostic-only, never a product result.
    let partialBase64: string | undefined;
    if (partial.length && !partialCapped) {
      const bytes = new Uint8Array(await new Blob(partial, {type: recorderMime}).arrayBuffer());
      let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
      partialBase64 = btoa(binary);
    }
    // Publish only after all cleanup/partial serialization; pollers never see a half receipt.
    fixture.result = {...finished, partialBase64, partialMime: recorderMime,
      partialBytes, partialCapped, tracks: [...tracks].map(track => track.readyState), trackKinds: [...tracks].map(track => track.kind), audioState: audio?.state};
  }
});
