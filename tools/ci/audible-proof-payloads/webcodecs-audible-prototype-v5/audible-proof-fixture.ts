/* Disposable browser fixture. No remote account, provider, or shipping UI. */
import {exportAudibleWebCodecsProof} from "../src/editor/experimental-webcodecs";
import {exportFormats} from "../src/editor/export";
import {inspectFile, type LocalMedia} from "../src/editor/media";
import {newDraft, validateDraft, type EditDraft} from "../src/editor/model";

type FixtureResult = {ok: true; bytes: number; duration: number} |
  {ok: false; error: string};
type Fixture = {prepared: boolean; result: FixtureResult | null;
  controller: AbortController | null; revision: number; fault: string;
  injected: boolean};

const state: Fixture = {prepared: false, result: null, controller: null,
  revision: 0, fault: "none", injected: false};
(window as typeof window & {audibleProofFixture?: Fixture}).audibleProofFixture = state;
const status = document.querySelector<HTMLParagraphElement>("#status")!;
const prepare = document.querySelector<HTMLButtonElement>("#prepare")!;
const exportButton = document.querySelector<HTMLButtonElement>("#export")!;
const download = document.querySelector<HTMLAnchorElement>("#download")!;
const fields = ["opening", "source", "closing"] as const;
let locals: LocalMedia[] = [];
let draft: EditDraft | undefined;
let offeredURL: string | undefined;

const discard = () => {
  state.controller?.abort(new Error("The local proof was reset."));
  state.controller = null;
  for (const local of locals) URL.revokeObjectURL(local.url);
  locals = [];
  draft = undefined;
  state.prepared = false;
  exportButton.disabled = true;
  if (offeredURL) URL.revokeObjectURL(offeredURL);
  offeredURL = undefined;
  download.removeAttribute("href");
  download.hidden = true;
};

prepare.addEventListener("click", async () => {
  discard();
  state.result = null;
  state.injected = false;
  status.textContent = "Inspecting local synthetic media…";
  const controller = new AbortController();
  state.controller = controller;
  try {
    const files = fields.map(id => document.querySelector<HTMLInputElement>(`#${id}`)!.files?.[0]);
    if (files.some(file => !file)) throw new Error("Choose all three synthetic files.");
    for (const file of files) locals.push(await inspectFile(file!, controller.signal));
    const [opening, source, closing] = locals;
    if (opening!.source.kind !== "image" || source!.source.kind !== "video" ||
        closing!.source.kind !== "image" || source!.source.duration < 4)
      throw new Error("The fixture needs two images and one four-second MP4.");
    const initial = newDraft();
    draft = validateDraft({...initial, ratio: "16:9", audio: "original", clips: [
      {id: "opening", source: opening!.source, start: 0, end: .5,
        caption: "", focusX: .5, focusY: .5, transition: "cut"},
      {id: "source", source: source!.source, start: 0, end: 4, speed: 2,
        caption: "", focusX: .5, focusY: .5, transition: "dissolve"},
      {id: "closing", source: closing!.source, start: 0, end: .5,
        caption: "", focusX: .5, focusY: .5, transition: "whip"},
    ]});
    state.prepared = true;
    exportButton.disabled = false;
    state.controller = null;
    status.textContent = "Local media is ready. Export requires a click.";
  } catch (error) {
    status.textContent = String(error);
    discard();
  }
});

exportButton.addEventListener("click", () => {
  // The exporter synchronously creates/resumes AudioContext in this gesture.
  if (!draft || !state.prepared || state.controller) {
    state.result = {ok: false, error: "Local proof is not ready."};
    return;
  }
  state.result = null;
  status.textContent = "Encoding local proof…";
  exportButton.disabled = true;
  const controller = new AbortController();
  state.controller = controller;
  const selected = draft;
  const media = new Map(selected.clips.map((clip, index) => [clip.id, locals[index]!]));
  const format = exportFormats().find(item => item.extension === "mp4")!;
  const fault = state.fault;
  (window as typeof window & {audibleProofFault?: string}).audibleProofFault =
    fault === "drop-first-block" || fault === "withhold-credits" ? fault : "none";
  const nativePlay = HTMLMediaElement.prototype.play;
  const timers: Array<ReturnType<typeof setTimeout>> = [];
  let poll: ReturnType<typeof setInterval> | undefined;
  let playInjected = false;
  if (fault === "delay-native-play") {
    HTMLMediaElement.prototype.play = function (...args) {
      if (playInjected) return Reflect.apply(nativePlay, this, args);
      playInjected = true;
      state.injected = true;
      return new Promise<void>((resolve, reject) => {
        timers.push(setTimeout(() => {
          (Reflect.apply(nativePlay, this, args) as Promise<void>).then(resolve, reject);
        }, 150));
      });
    };
  } else if (fault === "delay-play-promise-only") {
    HTMLMediaElement.prototype.play = function (...args) {
      const started = Reflect.apply(nativePlay, this, args) as Promise<void>;
      if (playInjected) return started;
      playInjected = true;
      state.injected = true;
      return started.then(() => new Promise<void>(resolve =>
        timers.push(setTimeout(resolve, 250))));
    };
  } else if (fault === "stall-original-100ms") {
    HTMLMediaElement.prototype.play = function (...args) {
      const started = Reflect.apply(nativePlay, this, args) as Promise<void>;
      if (playInjected) return started;
      playInjected = true;
      void started.then(() => timers.push(setTimeout(() => {
        state.injected = true;
        this.pause();
        this.dispatchEvent(new Event("waiting"));
        timers.push(setTimeout(() => {
          void Reflect.apply(nativePlay, this, []).catch(() => undefined);
        }, 100));
      }, 700)), () => undefined);
      return started;
    };
  }
  if (fault === "cancel-before-capture")
    timers.push(setTimeout(() => {
      state.injected = true;
      controller.abort(new Error("Synthetic pre-capture cancellation"));
    }, 5));
  if (["cancel-during-capture", "revision-during-capture", "suspend-during-capture"].includes(fault)) {
    poll = setInterval(() => {
      const observed = (window as typeof window & {audiblePCMProof?: {phase: string}}).audiblePCMProof;
      if (observed?.phase !== "capturing") return;
      if (poll !== undefined) clearInterval(poll);
      poll = undefined;
      timers.push(setTimeout(() => {
        state.injected = true;
        if (fault === "cancel-during-capture")
          controller.abort(new Error("Synthetic capture cancellation"));
        else if (fault === "revision-during-capture") state.revision++;
        else void (window as typeof window & {
          audibleProofAudioControl?: {suspend: () => Promise<void>}
        }).audibleProofAudioControl?.suspend().catch(() => undefined);
      }, 300));
    }, 5);
  }
  // No await precedes this call. A later asynchronous gesture would be an
  // invalid proof of browser audio activation and must not be substituted.
  const operation = exportAudibleWebCodecsProof({draft: selected, media, format,
    signal: controller.signal,
    currentDraft: () => state.revision === 0 ? selected :
      {...selected, revision: selected.revision + state.revision},
    onProgress: () => undefined});
  void operation.then(result => {
    if (controller.signal.aborted) return;
    offeredURL = URL.createObjectURL(result.blob);
    download.href = offeredURL;
    download.hidden = false;
    state.result = {ok: true, bytes: result.blob.size, duration: result.duration};
    status.textContent = "Proof output ready.";
  }, error => {
    state.result = {ok: false, error: String(error)};
    status.textContent = String(error);
  }).finally(() => {
    HTMLMediaElement.prototype.play = nativePlay;
    for (const timer of timers) clearTimeout(timer);
    if (poll !== undefined) clearInterval(poll);
    if (state.controller === controller) state.controller = null;
    exportButton.disabled = false;
  });
});

window.addEventListener("pagehide", discard);
