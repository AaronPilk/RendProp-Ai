import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {inspectFile} from "../src/editor/media";
import {newDraft, validateDraft} from "../src/editor/model";

// Hold the first observed startup clock read independently of capture/recorder
// construction. Native Web Audio, capture timestamps and encoded samples stay
// real; this is a controlled startup trace, not the unknown hosted failure cause.
const fixture = {mode: "freeze", extension: "mp4", result: null as unknown,
  events: [] as Array<Record<string, unknown>>};
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
  const observedTime = () => audio ? held ? frozenTime : nativeTime.call(audio) : undefined;
  const event = (kind: string) => fixture.events.push({kind, wall: performance.now(), held,
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
  try {
    local = await inspectFile((document.querySelector("input") as HTMLInputElement).files![0], controller.signal);
    window.AudioContext = class extends NativeAudio {
      constructor(options?: AudioContextOptions) {
        super(options); audio = this;
        Object.defineProperty(this, "currentTime", {get: () => { holdStartup(); return observedTime(); }});
      }
      createMediaStreamDestination(): MediaStreamAudioDestinationNode {
        const node = super.createMediaStreamDestination();
        for (const track of node.stream.getTracks()) tracks.add(track);
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
        event("recorder.construct");
      }
      start(timeslice?: number): void { event("recorder.start"); super.start(timeslice); }
    };
    HTMLMediaElement.prototype.play = function (...args) {
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
    fixture.result = {ok: true, base64: btoa(binary), duration: result.duration};
  } catch (error) {
    fixture.result = {ok: false, error: String(error), cause: error instanceof Error ? error.cause : undefined};
  } finally {
    for (const timer of timers) clearTimeout(timer);
    window.AudioContext = NativeAudio; window.MediaRecorder = NativeRecorder; HTMLMediaElement.prototype.play = nativePlay;
    HTMLCanvasElement.prototype.captureStream = nativeCapture;
    if (local) URL.revokeObjectURL(local.url);
    controller.abort();
    fixture.result = {...fixture.result as object, tracks: [...tracks].map(track => track.readyState), trackKinds: [...tracks].map(track => track.kind), audioState: audio?.state};
  }
});
