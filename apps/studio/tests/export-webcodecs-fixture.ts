import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {draftMedia, timelineDuration, type EditDraft} from "../src/editor/model";
import {inspectFile, type LocalMedia} from "../src/editor/media";
import {makeExportFixtureDraft, type ExportFixtureScenario, type ExportFixtureSources} from "./export-webcodecs-draft";

type Summary = {type?: string; sequence?: number; startFrame?: number; frameCount?: number;
  workletPhase?: string; windowIndex?: number; outputBase?: number};
type PCMPhase = {type: string; windowIndex?: number; outputBase?: number};
function armedContentPlayback(events: readonly PCMPhase[] | undefined): PCMPhase | undefined {
  const phase = events?.at(-1);
  return phase?.type === "armed" && phase.windowIndex === 1 && phase.outputBase === 24_000 ? phase : undefined;
}
type FixtureFault = "none" | "missing-source" | "music-mismatch" | "narration-invalid" |
  "cancel-before" | "cancel-second-window" | "revision-second-window" |
  "suspend-second-window" | "cancel-frame" | "worker-post-failure" |
  "late-play-promise" | "delay-native-play" | "cancel-finalize" | "output-limit";
type PlainErrorValue = null | boolean | number | string | PlainErrorValue[] |
  {[key: string]: PlainErrorValue};
type ErrorDetails = {name: string; message: string; cause?: PlainErrorValue};
// Preserve the production error's existing passive clock operands. This runs
// only after settlement; it does not sample clocks or install an observer.
function errorDetails(error: unknown): ErrorDetails {
  const plain = (value: unknown, depth = 0): PlainErrorValue | undefined => {
    if (depth > 6) return undefined;
    if (value === null || typeof value === "boolean") return value;
    if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
    if (typeof value === "string") return value.slice(0, 2000);
    if (Array.isArray(value) && value.length <= 32)
      return value.map(item => plain(item, depth + 1) ?? null);
    if (typeof value === "object" && value && Object.getPrototypeOf(value) === Object.prototype) {
      const entries = Object.entries(value);
      if (entries.length > 32) return undefined;
      return Object.fromEntries(entries.flatMap(([key, item]) => {
        const copied = plain(item, depth + 1);
        return copied === undefined ? [] : [[key, copied]];
      }));
    }
    return undefined;
  };
  return error instanceof Error ? {name: error.name, message: error.message,
    cause: plain(error.cause)} : {name: "ThrownValue", message: String(error)};
}
type FixtureResult = {ok: true; bytes: number; duration: number; audio: string; narration?: boolean; music?: boolean} |
  {ok: false; error: string; errorDetails?: ErrorDetails};
type FixtureState = {scenario: ExportFixtureScenario; fault: FixtureFault; prepared: boolean;
  settled: boolean; revision: number; result: FixtureResult | null; injected: boolean;
  injectionEvidence: Summary | null; draft: EditDraft | null;
  plannedSeconds: number; controller: AbortController | null};
declare global {
  interface Window {
    exportWebCodecsFixture: FixtureState;
    exportTestControl?: {beforeWorkerInput?: (row: Summary) => void; afterWorkerInput?: (row: Summary) => void;
      onTestWorkerProbe?: (probe: string) => void};
    exportBackendOwners: {contexts: AudioContext[]; tracks: MediaStreamTrack[]; workers: Worker[]};
    exportBackendObservation: {pcmWindowEvents: PCMPhase[]};
    exportPlayEvidence: Array<{phase: string; wallMs: number; sourceSeconds: number}>;
  }
}
const state: FixtureState = {scenario: "combined", fault: "none", prepared: false,
  settled: false, revision: 0, result: null, injected: false, injectionEvidence: null,
  draft: null, plannedSeconds: 0, controller: null};
window.exportWebCodecsFixture = state;
const visualIds = ["opening", "sourceOne", "middle", "sourceTwo", "closing", "cutaway", "motion"] as const;
const status = document.querySelector<HTMLElement>("#status")!;
const prepareButton = document.querySelector<HTMLButtonElement>("#prepare")!;
const exportButton = document.querySelector<HTMLButtonElement>("#export")!;
const download = document.querySelector<HTMLAnchorElement>("#download")!;
let locals: LocalMedia[] = [];
let narration: File | undefined, music: File | undefined, changedMusic: Blob | undefined;
let offeredURL: string | undefined;
const selected = (id: string) => document.querySelector<HTMLInputElement>("#" + id)?.files?.[0];
const discard = () => {
  state.controller?.abort(new Error("Integrated fixture reset"));
  state.controller = null;
  for (const local of locals) URL.revokeObjectURL(local.url);
  locals = [];
  narration = music = undefined; changedMusic = undefined;
  state.prepared = false; state.draft = null; exportButton.disabled = true;
  if (offeredURL) URL.revokeObjectURL(offeredURL);
  offeredURL = undefined; download.removeAttribute("href"); download.hidden = true;
};
const digest = async (bytes: ArrayBuffer) => Array.from(new Uint8Array(
  await crypto.subtle.digest("SHA-256", bytes)), value => value.toString(16).padStart(2, "0")).join("");

prepareButton.addEventListener("click", async () => {
  discard(); state.result = null; state.settled = false; state.revision = 0;
  const controller = new AbortController(); state.controller = controller;
  status.textContent = "Inspecting synthetic source files";
  try {
    narration = selected("narration"); music = selected("music");
    if (state.scenario !== "seek" && (!narration || !music)) throw new Error("Choose both synthetic WAV files.");
    const requiredIds = state.scenario === "seek" ? ["sourceSeek"] : visualIds;
    for (const id of requiredIds) {
      const file = selected(id);
      if (!file) throw new Error("Missing synthetic file " + id);
      locals.push(await inspectFile(file, controller.signal));
    }
    const sources = Object.fromEntries(requiredIds.map((id, index) =>
      [id, locals[index]!.source])) as ExportFixtureSources;
    const musicBytes = music ? await music.arrayBuffer() : undefined;
    const musicSource = music && musicBytes ? {name: music.name, size: music.size, lastModified: music.lastModified,
      sha256: await digest(musicBytes), duration: 5.4, mime: music.type} : undefined;
    // Same size but different bytes: exercise actual hash custody, not only size.
    if (musicBytes && music) {
      const altered = new Uint8Array(musicBytes.slice(0));
      altered[altered.length - 1] = altered[altered.length - 1]! ^ 1;
      changedMusic = new Blob([altered], {type: music.type});
    }
    state.draft = makeExportFixtureDraft(sources, musicSource, state.scenario);
    state.plannedSeconds = timelineDuration(state.draft.clips);
    state.prepared = true; state.controller = null; exportButton.disabled = false;
    status.textContent = "Ready to export through exportLocalVideo.";
  } catch (error) {
    discard(); state.result = {ok: false, error: String(error), errorDetails: errorDetails(error)}; state.settled = true;
    status.textContent = String(error);
  }
});

exportButton.addEventListener("click", () => {
  const draft = state.draft;
  if (!draft || (state.scenario !== "seek" && (!music || !narration)) || !state.prepared || state.controller) return;
  if (offeredURL) URL.revokeObjectURL(offeredURL);
  offeredURL = undefined; download.removeAttribute("href"); download.hidden = true;
  state.result = null; state.settled = false; state.injected = false; state.injectionEvidence = null;
  const controller = new AbortController(); state.controller = controller;
  exportButton.disabled = true; status.textContent = "Exporting actual Studio edit";
  window.exportPlayEvidence = [];
  const nativePlay = HTMLMediaElement.prototype.play;
  const timers: ReturnType<typeof setTimeout>[] = [];
  let playInjected = false;
  if (state.fault === "late-play-promise" || state.fault === "delay-native-play") {
    HTMLMediaElement.prototype.play = function (...args) {
      // Priming runs outside the capture window. Inject only after the real
      // worklet has armed the second, original-video content window.
      const phase = armedContentPlayback(window.exportBackendObservation?.pcmWindowEvents);
      if (playInjected || !phase) return Reflect.apply(nativePlay, this, args);
      playInjected = true;
      const evidence = (phase: string) => window.exportPlayEvidence.push({
        phase, wallMs: performance.now(), sourceSeconds: this.currentTime});
      evidence("call");
      state.injected = true; state.injectionEvidence = {type: state.fault,
        workletPhase: phase.type, windowIndex: phase.windowIndex, outputBase: phase.outputBase};
      if (state.fault === "delay-native-play")
        return new Promise<void>((resolve, reject) => timers.push(setTimeout(() => {
          evidence("actual-native-play");
          (Reflect.apply(nativePlay, this, args) as Promise<void>).then(resolve, reject);
        }, 150)));
      const started = Reflect.apply(nativePlay, this, args) as Promise<void>;
      return started.then(() => new Promise<void>(resolve => timers.push(setTimeout(() => {
        evidence("delayed-promise-resolved"); resolve();
      }, 250))));
    };
  }
  const media = new Map(draftMedia(draft).map(item => {
    const local = locals.find(candidate => candidate.source.sha256 === item.source.sha256);
    if (!local) throw new Error("Fixture source map is incomplete");
    return [item.id, local];
  }));
  const inject = (row: Summary) => {
    if (state.injected) return false;
    state.injected = true; state.injectionEvidence = {...row}; return true;
  };
  window.exportTestControl = {
    onTestWorkerProbe(probe) {
      if (state.fault === "cancel-finalize" && probe === "finalize-entered" &&
          inject({type: "test-only.finalize-entered"}))
        controller.abort(new Error("Synthetic finalization cancellation"));
    },
    beforeWorkerInput(row) {
      if (state.fault === "worker-post-failure" && row.type === "video" &&
          (row.sequence ?? 0) >= 4 && inject(row))
        throw new Error("Synthetic worker post failure");
    },
    afterWorkerInput(row) {
      if (row.type === "audio" && (row.startFrame ?? 0) >= 24_000) {
        const phase = armedContentPlayback(window.exportBackendObservation?.pcmWindowEvents);
        const inLiveWindow = phase && {...row, workletPhase: phase.type,
          windowIndex: phase.windowIndex, outputBase: phase.outputBase};
        if (state.fault === "cancel-second-window" && inLiveWindow && inject(inLiveWindow))
          controller.abort(new Error("Synthetic second-window cancellation"));
        if (state.fault === "revision-second-window" && inLiveWindow && inject(inLiveWindow)) state.revision++;
        if (state.fault === "suspend-second-window" && inLiveWindow && inject(inLiveWindow)) {
          const audio = window.exportBackendOwners.contexts[0];
          if (!audio) throw new Error("No actual AudioContext to suspend");
          void audio.suspend();
        }
      }
      if (state.fault === "cancel-frame" && row.type === "video" &&
          (row.sequence ?? 0) >= 4 && inject(row))
        controller.abort(new Error("Synthetic frame cancellation"));
    },
  };
  if (state.fault === "missing-source") {media.delete("sourceTwo"); inject({type: "fixture.source.delete"});}
  if (state.fault === "music-mismatch" || state.fault === "narration-invalid") inject({type: state.fault});
  if (state.fault === "output-limit") inject({type: "test-only.capacity.256"});
  if (state.fault === "cancel-before") {
    inject({type: "fixture.abort.before"});
    controller.abort(new Error("Synthetic pre-export cancellation"));
  }
  const format = exportFormats().find(value => value.extension === "mp4");
  if (!format) {
    HTMLMediaElement.prototype.play = nativePlay;
    for (const timer of timers) clearTimeout(timer);
    state.result = {ok: false, error: "MP4 is unavailable"}; state.settled = true;
    state.controller = null; return;
  }
  // The public call is synchronous with the original click, before any await.
  const operation = exportLocalVideo({draft, media, format,
    musicBlob: state.fault === "music-mismatch" ? changedMusic : music,
    narrationBlob: state.fault === "narration-invalid" ?
      new Blob(["invalid synthetic narration"], {type: "audio/wav"}) : narration,
    signal: controller.signal, currentDraft: () => ({...draft, revision: draft.revision + state.revision}),
    onProgress: () => undefined});
  void operation.then(result => {
    offeredURL = URL.createObjectURL(result.blob);
    download.href = offeredURL; download.hidden = false;
    state.result = {ok: true, bytes: result.blob.size, duration: result.duration,
      audio: result.audio, narration: result.narration, music: result.music};
    status.textContent = "Integrated export ready";
  }, error => {
    state.result = {ok: false, error: String(error), errorDetails: errorDetails(error)};
    status.textContent = String(error);
  }).finally(() => {
    HTMLMediaElement.prototype.play = nativePlay;
    for (const timer of timers) clearTimeout(timer);
    window.exportTestControl = undefined;
    if (state.controller === controller) state.controller = null;
    exportButton.disabled = false; state.settled = true;
  });
});
window.addEventListener("pagehide", discard);
