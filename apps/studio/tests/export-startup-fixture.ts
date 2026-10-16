import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {inspectFile} from "../src/editor/media";
import {newDraft, validateDraft} from "../src/editor/model";

// Only the observed startup getter is held. Native AudioContext processing,
// MediaRecorder, source playback and encoded samples stay real. Native time is
// retained separately: this models the observed failure, not its unknown cause.
const fixture = {mode: "freeze", extension: "mp4", result: null as unknown,
  events: [] as Array<Record<string, unknown>>};
Object.assign(window, {startupFixture: fixture});
document.querySelector("button")!.addEventListener("click", async () => {
  fixture.result = null; fixture.events = [];
  const controller = new AbortController(), timers: ReturnType<typeof setTimeout>[] = [];
  const NativeAudio = window.AudioContext, NativeRecorder = window.MediaRecorder;
  const nativeTime = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, "currentTime")!.get!;
  const nativePlay = HTMLMediaElement.prototype.play;
  let audio: AudioContext | undefined, held = false, frozenTime = 0, revision = 1;
  const tracks: MediaStreamTrack[] = [];
  const event = (kind: string) => fixture.events.push({kind, wall: performance.now(), held,
    audio: audio?.currentTime, nativeAudio: audio ? nativeTime.call(audio) : undefined,
    state: audio?.state});
  let local: Awaited<ReturnType<typeof inspectFile>> | undefined;
  try {
    local = await inspectFile((document.querySelector("input") as HTMLInputElement).files![0], controller.signal);
    window.AudioContext = class extends NativeAudio {
      constructor(options?: AudioContextOptions) {
        super(options); audio = this;
        Object.defineProperty(this, "currentTime", {get: () => held ? frozenTime : nativeTime.call(this)});
      }
      createBufferSource(): AudioBufferSourceNode {
        const node = super.createBufferSource(), start = node.start;
        node.start = (...args: Parameters<AudioBufferSourceNode["start"]>) => {
          event("user.buffer.start"); return Reflect.apply(start, node, args);
        };
        return node;
      }
    };
    window.MediaRecorder = class extends NativeRecorder {
      constructor(stream: MediaStream, options?: MediaRecorderOptions) {
        super(stream, options); tracks.push(...stream.getTracks());
        if (fixture.mode !== "normal") {
          frozenTime = nativeTime.call(audio); held = true; event("startup.held");
          if (fixture.mode !== "permanent") timers.push(setTimeout(() => { held = false; event("startup.released"); }, 180));
          if (fixture.mode === "abort") timers.push(setTimeout(() => controller.abort(new Error("Fixture startup cancelled")), 70));
          if (fixture.mode === "stale") timers.push(setTimeout(() => { revision = 2; event("revision.changed"); }, 70));
          if (fixture.mode === "suspended") void audio!.suspend();
        }
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
    if (local) URL.revokeObjectURL(local.url);
    controller.abort();
    fixture.result = {...fixture.result as object, tracks: tracks.map(track => track.readyState), audioState: audio?.state};
  }
});
