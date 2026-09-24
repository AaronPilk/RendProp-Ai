import {OverlayPainter} from "./overlay-renderer";
import { RecipePanel, type RecipeRequest } from "./RecipePanel";
import { RECIPE_CATALOG, type RecipeResult } from "./recipes";
import { splitVideoAtTime } from "./edit-actions";
import {
  useEffect,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
  type KeyboardEvent,
} from "react";
import {
  EDIT_LIMITS,
  draftMedia,
  type EditOverlay,
  assertCurrentRevision,
  assertSourceMatch,
  clipDuration,
  formatTime,
  locateTime,
  moveClip,
  newDraft,
  parseDraft,
  renderDimensions,
  reviseDraft,
  serializeDraft,
  timelineDuration,
  validateDraft,
  validateFileBatch,
  type EditClip,
  type EditDraft,
  type Ratio,
  type Narration,
  type CaptionStyle,
  type Transition,
} from "./model";
import {
  awaitMediaOperation,
  decodeMedia,
  drawFrame,
  inspectFile,
  nextFrame,
  seekMedia,
  throwIfAborted,
  type DecodedMedia,
  type LocalMedia,
} from "./media";
import {
  exportFormats,
  exportLocalVideo,
  supportsOriginalAudio,
  type LocalExport,
} from "./export";
import "./editor.css";
import {
  HISTORY_LIMITS,
  closeHistoryGroup,
  createHistory,
  editHistory,
  redoHistory,
  releasedMediaIds,
  undoHistory,
  type EditHistory,
} from "./history";

export type EditorSettings = {ratio: Ratio; title: string; captionStyle?: CaptionStyle; transition: Transition; narration?: Narration; clearCaptions?: boolean};
export type VideoEditorProps = {
  active?: boolean;
  initialDraft?: EditDraft;
  /** Optional observer only; the editor already renders and announces its notices. */
  onNotice?: (message: string) => void;
  onDraftChange?: (draft: EditDraft) => void;
  importRequest?: { id: string; files: File[]; listingId?: string; sourceMedia?: {id: string; kind: "photo" | "video"}[] };
  relinkRequest?: { id: string; files: File[] };
  onSourcesChange?: (sources: { file: File; sha256: string }[]) => void;
  onSaveOutput?: (output: LocalExport) => Promise<void>;
  narrationChoices?: {id: string; label: string; words: Narration["words"]}[];
  resolveNarration?: (id: string, signal: AbortSignal) => Promise<Blob>;
  planRequest?: {id: string; files: File[]; clips: {seconds: number; caption: string; motion: EditClip["motion"]}[]; narration?: Narration; settings?: EditorSettings};
  settingsRequest?: EditorSettings & {id: string};
  onSettingsApplied?: () => void;
  agentRequest?: {id: string; baseFile: File; photos: File[]; overlays: {start: number; end: number; caption: string; motion?: EditOverlay["motion"]}[]};
  onPlanApplied?: (draft: EditDraft) => void;
  onPlanFailed?: (message: string) => void;
  onSwitchBlockChange?: (reason: string | null) => void;
  /** Opens an explicit recipe review; never applies a replacement without review. */
  recipeRequest?: RecipeRequest;
  onRecipeApplied?: (result: RecipeResult) => void;
  initialMode?: "simple" | "pro";
  readOnly?: boolean;
  seekRequest?: { id: string; time: number };
  onPlayheadChange?: (time: number) => void;
};

function errorText(error: unknown): string {
  return error instanceof Error
    ? error.message
    : "The browser could not complete that operation.";
}
function inactiveExportError() {
  return new DOMException(
    "Export cancelled because you left the video editor.",
    "AbortError",
  );
}
function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function VideoEditor({
  active = true,
  initialDraft,
  onNotice,
  onDraftChange,
  importRequest,
  relinkRequest,
  onSourcesChange,
  onSaveOutput,
  narrationChoices,
  resolveNarration,
  planRequest,
  agentRequest,
  onPlanApplied,
  onPlanFailed,
  settingsRequest,
  onSettingsApplied,
  onSwitchBlockChange,
  recipeRequest,
  onRecipeApplied,
  initialMode = "pro",
  readOnly = false,
  seekRequest,
  onPlayheadChange,
}: VideoEditorProps) {
  const [editorMode, setEditorMode] = useState(initialMode);
  const [initial] = useState(() => {
    try {
      return {
        draft: initialDraft ? validateDraft(initialDraft) : newDraft(),
        issue: "",
      };
    } catch (error) {
      return {
        draft: newDraft(),
        issue: `The saved edit could not be opened: ${errorText(error)}`,
      };
    }
  });
  const [history, setHistory] = useState(() => createHistory(initial.draft));
  const historyRef = useRef(history);
  const draft = history.present;
  const activeRef = useRef(active);
  activeRef.current = active;
  const draftRef = useRef(draft);
  const media = useRef(new Map<string, LocalMedia>());
  const [mediaVersion, setMediaVersion] = useState(0);
  const [voice, setVoice] = useState<{id: string; blob: Blob; url: string} | null>(null);
  const [voiceIssue, setVoiceIssue] = useState(""), [voiceRetry, setVoiceRetry] = useState(0);
  const [selectedId, setSelectedId] = useState(draft.clips[0]?.id ?? "");
  const [message, setMessage] = useState(initial.issue);
  const [importing, setImporting] = useState(false);
  const importAbort = useRef<AbortController | null>(null);
  const [exporting, setExporting] = useState(false);
  const [savingOutput, setSavingOutput] = useState(false);
  const [outputKept, setOutputKept] = useState(false);
  const exportAbort = useRef<AbortController | null>(null);
  const [progress, setProgress] = useState(0);
  const [output, setOutput] = useState<(LocalExport & { url: string }) | null>(
    null,
  );
  const outputUrl = useRef<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [time, setTime] = useState(0);
  const timeRef = useRef(0);
  const [scrubVersion, setScrubVersion] = useState(0);
  const [previewError, setPreviewError] = useState("");
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const filesInput = useRef<HTMLInputElement>(null);
  const planInput = useRef<HTMLInputElement>(null);
  const relinkInput = useRef<HTMLInputElement>(null);
  const relinkId = useRef("");
  const consumedRequest = useRef(new Set<string>());
  const callbacks = useRef({ onNotice, onDraftChange });
  callbacks.current = { onNotice, onDraftChange };
  const [formats] = useState(exportFormats);
  const [formatMime, setFormatMime] = useState(formats[0]?.mime ?? "");
  const total = timelineDuration(draft.clips);
  useEffect(() => {
    onSwitchBlockChange?.(importing || exporting || savingOutput ? "Finish importing, exporting or saving before switching properties." : output && !outputKept ? "Download or save this finished video before switching properties. Your export is kept here." : null);
  }, [importing, exporting, savingOutput, output, outputKept, onSwitchBlockChange]);
  const selected =
    draft.clips.find((clip) => clip.id === selectedId) ?? draft.clips[0];
  const selectedIndex = selected ? draft.clips.indexOf(selected) : -1;
  const missing = draftMedia(draft).filter((clip) => !media.current.has(clip.id));
  const needsAudio = !!draft.narration || draft.audio === "original" && draft.clips.some((clip) => clip.source.kind === "video");
  const voiceReady = !draft.narration || voice?.id === draft.narration.resultId;
  const audioUnavailable = needsAudio && !supportsOriginalAudio();
  const dimensions = renderDimensions(draft.ratio);

  const notice = (text: string) => {
    setMessage(text);
    callbacks.current.onNotice?.(text);
  };
  const invalidateExport = () => {
    exportAbort.current?.abort(
      new DOMException(
        "Export cancelled because the edit changed.",
        "AbortError",
      ),
    );
    if (outputUrl.current) URL.revokeObjectURL(outputUrl.current);
    outputUrl.current = null;
    setOutput(null);
  };
  const replaceHistory = (nextHistory: EditHistory) => {
    if (nextHistory === historyRef.current) return false;
    const next = nextHistory.present;
    invalidateExport();
    setMessage("");
    setPlaying(false);
    // Undo restores metadata, not removed files. Release anything that no longer
    // belongs to the current plan instead of growing an unbounded media cache.
    const released = releasedMediaIds(next, new Map(
      [...media.current].map(([id, local]) => [id, local.source]),
    ));
    for (const id of released) {
      URL.revokeObjectURL(media.current.get(id)!.url);
      media.current.delete(id);
    }
    // A split/redo can introduce a second clip for a file already in memory.
    // Give each clip its own URL so releasing one cannot invalidate another.
    let rebound = false;
    for (const item of draftMedia(next)) {
      if (media.current.has(item.id)) continue;
      const match = [...media.current.values()].find(local => {
        try { assertSourceMatch(item.source, local.source); return true; } catch { return false; }
      });
      if (match) { media.current.set(item.id, { ...match, url: URL.createObjectURL(match.file) }); rebound = true; }
    }
    if (released.length || rebound) setMediaVersion((version) => version + 1);
    historyRef.current = nextHistory;
    draftRef.current = next;
    setHistory(nextHistory);
    setSelectedId((id) => next.clips.some((clip) => clip.id === id) ? id : (next.clips[0]?.id ?? ""));
    timeRef.current = Math.min(timeRef.current, timelineDuration(next.clips));
    setTime(timeRef.current);
    return true;
  };
  const finishHistoryGroup = () => {
    historyRef.current = closeHistoryGroup(historyRef.current);
  };
  const update = (patch: Parameters<typeof reviseDraft>[1], label = "edit", group: string | null = null) => {
    if (readOnly || importAbort.current) return false;
    try {
      return replaceHistory(editHistory(historyRef.current, patch, label, group));
    } catch (error) {
      notice(errorText(error));
      return false;
    }
  };
  const updateClip = (
    id: string,
    patch: Partial<
      Pick<EditClip, "start" | "end" | "caption" | "focusX" | "focusY" | "speed" | "captionStyle" | "transition" | "motion">
    >,
  ) => {
    const field = Object.keys(patch)[0] ?? "clip";
    const label = field === "caption" ? "clip caption" : field.startsWith("focus") ? "clip framing" : "clip timing";
    update({
      clips: draftRef.current.clips.map((clip) =>
        clip.id === id ? { ...clip, ...patch } : clip,
      ),
    }, label, `clip:${id}:${field}`);
  };
  const applyRecipe = (result: RecipeResult) => {
    if (importing || exporting || savingOutput) return;
    if (result.draft.id !== draftRef.current.id || result.draft.revision !== draftRef.current.revision) {
      notice("The edit changed. Review the guided draft again before applying it."); return;
    }
    const { clips, overlays, narration, audio, ratio, title } = result.draft;
    if (update({ clips, overlays, narration, audio, ratio, title }, `apply ${result.recipe}`)) {
      const applied = { ...result, draft: draftRef.current };
      onRecipeApplied?.(applied);
      timeRef.current = 0; setTime(0); setScrubVersion(value => value + 1);
      notice(`${RECIPE_CATALOG.find(item => item.id === result.recipe)?.name} applied. Review the complete preview and adjust any timing or captions. Undo restores the previous edit.`);
    } else notice("These guided draft settings are already applied.");
  };
  const splitAtPlayhead = () => {
    if (importing || exporting || savingOutput) return;
    try {
      const next = splitVideoAtTime(draftRef.current, timeRef.current, crypto.randomUUID());
      if (update({ clips: next.clips }, "split video")) notice("Video split at the playhead. Both pieces retain the original source, audio and speed.");
    } catch (error) { notice(errorText(error)); }
  };
  const travelHistory = (direction: "undo" | "redo") => {
    if (readOnly || !activeRef.current || importAbort.current) return;
    try {
      const current = historyRef.current;
      const label = (direction === "undo" ? current.past : current.future).at(-1)?.label;
      const next = direction === "undo" ? undoHistory(current) : redoHistory(current);
      if (!replaceHistory(next)) return;
      const missingCount = draftMedia(next.present).filter((clip) => !media.current.has(clip.id)).length;
      notice(`${direction === "undo" ? "Undid" : "Redid"} ${label}. ${missingCount ? "Reselect missing original media; its full SHA-256 hash must match." : "Your edit is ready."}`);
    } catch (error) {
      notice(errorText(error));
    }
  };
  const historyShortcut = (event: KeyboardEvent<HTMLElement>) => {
    const target = event.target;
    // Leave native text-field undo alone; editor shortcuts operate outside fields.
    if (target instanceof HTMLElement && (target.isContentEditable || target.closest("input, textarea, select"))) return;
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
    const key = event.key.toLowerCase();
    if (key !== "z" && !(key === "y" && event.ctrlKey)) return;
    event.preventDefault();
    travelHistory(key === "y" || event.shiftKey ? "redo" : "undo");
  };

  useEffect(() => {
    if (!readOnly) callbacks.current.onDraftChange?.(draft);
  }, [draft, readOnly]);
  useEffect(() => { onPlayheadChange?.(time); }, [time, onPlayheadChange]);
  useEffect(() => {
    if (readOnly) { exportAbort.current?.abort(); importAbort.current?.abort(); }
  }, [readOnly]);
  useEffect(() => {
    if (!active) {
      setPlaying(false);
      exportAbort.current?.abort(inactiveExportError());
    }
  }, [active]);
  useEffect(
    () => () => {
      exportAbort.current?.abort();
      importAbort.current?.abort();
      for (const local of media.current.values())
        URL.revokeObjectURL(local.url);
      media.current.clear();
      if (outputUrl.current) URL.revokeObjectURL(outputUrl.current);
    },
    [],
  );
  useEffect(() => {
    const pause = () => {
      if (document.hidden) setPlaying(false);
    };
    document.addEventListener("visibilitychange", pause);
    return () => document.removeEventListener("visibilitychange", pause);
  }, []);

  const importFiles = async (files: File[]) => {
    if (readOnly || !files.length) return;
    if (importAbort.current) {
      notice(
        "Wait for the current media import to finish, then add these files again.",
      );
      return;
    }
    const snapshot = draftRef.current;
    const controller = new AbortController();
    importAbort.current = controller;
    setImporting(true);
    setPlaying(false);
    const staged: Array<{ clip: EditClip; local: LocalMedia }> = [];
    let accepted = false;
    try {
      validateFileBatch(files, snapshot.clips);
      for (const file of files) {
        const local = await inspectFile(file, controller.signal);
        staged.push({
          local,
          clip: {
            id: crypto.randomUUID(),
            source: local.source,
            start: 0,
            end:
              local.source.kind === "image"
                ? 3
                : Math.min(6, local.source.duration),
            caption: "",
            focusX: 0.5,
            focusY: 0.5,
          },
        });
      }
      assertCurrentRevision(snapshot, draftRef.current, controller.signal);
      const next = editHistory(historyRef.current, {
        clips: [...snapshot.clips, ...staged.map((item) => item.clip)],
      }, "add media");
      for (const item of staged) media.current.set(item.clip.id, item.local);
      accepted = true;
      replaceHistory(next);
      setSelectedId(staged[0]!.clip.id);
      setMediaVersion((version) => version + 1);
      timeRef.current = timelineDuration(snapshot.clips);
      setTime(timeRef.current);
      setScrubVersion((version) => version + 1);
      notice(
        `Added ${staged.length} ${staged.length === 1 ? "clip" : "clips"}. Photos start at 3 seconds; videos start with up to their first 6 seconds. Adjust the selected clip below.`,
      );
    } catch (error) {
      if (!controller.signal.aborted) notice(errorText(error));
    } finally {
      if (!accepted)
        staged.forEach((item) => URL.revokeObjectURL(item.local.url));
      if (importAbort.current === controller) {
        importAbort.current = null;
        setImporting(false);
      }
    }
  };

  useEffect(() => {
    if (readOnly || !importRequest || consumedRequest.current.has(importRequest.id)) return;
    consumedRequest.current.add(importRequest.id);
    void importFiles(importRequest.files);
    // Each stable request ID is consumed once; local changes must not replay an import.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [importRequest]);

  useEffect(() => {
    if (readOnly || !settingsRequest || consumedRequest.current.has(settingsRequest.id)) return;
    consumedRequest.current.add(settingsRequest.id);
    if (importAbort.current) {onPlanFailed?.("Wait for the media import to finish, then apply phone settings again."); return;}
    const {ratio, title, narration, captionStyle, transition, clearCaptions} = settingsRequest;
    const changed = update({ratio, title, narration, clips: draftRef.current.clips.map((clip, index) => ({...clip, caption: clearCaptions ? "" : clip.caption, captionStyle: captionStyle ?? "clean", transition: index === 0 ? "cut" : transition}))}, "phone reel settings");
    if (changed) {notice("Phone reel settings applied to this sequence. Review the preview before exporting."); onSettingsApplied?.();}
  }, [settingsRequest]);

  useEffect(() => {
    if (readOnly || !planRequest || consumedRequest.current.has(planRequest.id)) return;
    if (importAbort.current) { onPlanFailed?.("Wait for the current import to finish, then apply the shot plan again."); return; }
    consumedRequest.current.add(planRequest.id);
    const controller = new AbortController(), staged: {clip: EditClip; local: LocalMedia}[] = []; let accepted = false;
    importAbort.current = controller; setImporting(true); setPlaying(false);
    const snapshot = draftRef.current;
    void (async () => {
      validateFileBatch(planRequest.files);
      if (planRequest.files.length !== planRequest.clips.length) throw new Error("The shot plan does not match its selected photos.");
      for (let index = 0; index < planRequest.files.length; index++) {
        const local = await inspectFile(planRequest.files[index], controller.signal), item = planRequest.clips[index];
        if (local.source.kind !== "image") { URL.revokeObjectURL(local.url); throw new Error("A shot plan must use the original property photos."); }
        staged.push({local, clip: {id: crypto.randomUUID(), source: local.source, start: 0, end: item.seconds, caption: item.caption, focusX: 0.5, focusY: 0.5, captionStyle: planRequest.settings?.captionStyle ?? "clean", transition: index === 0 ? "cut" : planRequest.settings?.transition ?? "cut", motion: item.motion}});
      }
      assertCurrentRevision(snapshot, draftRef.current, controller.signal);
      const next = editHistory(historyRef.current, {clips: staged.map(item => item.clip), overlays: [], narration: planRequest.narration, ...(planRequest.settings ? {ratio: planRequest.settings.ratio, title: planRequest.settings.title} : {})}, "apply saved shot plan");
      for (const item of staged) media.current.set(item.clip.id, item.local);
      accepted = true; replaceHistory(next); onPlanApplied?.(next.present); setMediaVersion(value => value + 1); scrubTo(0);
      notice("Saved shot plan applied. Review the photos, timing, captions, and narration before exporting.");
    })().catch(error => { if (!controller.signal.aborted) { notice(errorText(error)); onPlanFailed?.(errorText(error)); } })
      .finally(() => { if (!accepted) staged.forEach(item => URL.revokeObjectURL(item.local.url)); if (importAbort.current === controller) { importAbort.current = null; setImporting(false); } });
    return () => controller.abort();
  }, [planRequest]);

  useEffect(() => {
    if (readOnly || !agentRequest || consumedRequest.current.has(agentRequest.id)) return;
    if (importAbort.current) {onPlanFailed?.("Wait for the current import, then apply the agent plan again.");return;}
    consumedRequest.current.add(agentRequest.id);
    const controller = new AbortController(), staged: LocalMedia[] = []; let accepted = false;
    importAbort.current = controller; setImporting(true); setPlaying(false); const snapshot = draftRef.current;
    void (async () => {
      if (agentRequest.photos.length !== agentRequest.overlays.length || agentRequest.photos.length > 12) throw new Error("The cutaway plan does not match its photos.");
      const base = await inspectFile(agentRequest.baseFile, controller.signal); staged.push(base);
      if (base.source.kind !== "video" || base.source.duration > EDIT_LIMITS.timelineSeconds) throw new Error("Choose an agent video up to 3 minutes long. Shorten a longer recording before applying this plan.");
      const clip: EditClip = {id:crypto.randomUUID(),source:base.source,start:0,end:base.source.duration,caption:"",focusX:.5,focusY:.5,speed:1};
      const overlays: EditOverlay[] = [];
      for (let index = 0; index < agentRequest.photos.length; index++) {
        const local = await inspectFile(agentRequest.photos[index], controller.signal); staged.push(local);
        if (local.source.kind !== "image") throw new Error("Choose still photos for the agent’s cutaways.");
        overlays.push({id:crypto.randomUUID(),source:local.source,...agentRequest.overlays[index],focusX:.5,focusY:.5});
      }
      assertCurrentRevision(snapshot, draftRef.current, controller.signal);
      const next = editHistory(historyRef.current, {clips:[clip],overlays,narration:undefined,audio:"original"}, "apply agent cutaways");
      media.current.set(clip.id,base); overlays.forEach((overlay,index)=>media.current.set(overlay.id,staged[index+1]));
      accepted=true;replaceHistory(next);onPlanApplied?.(next.present);setMediaVersion(value=>value+1);scrubTo(0);
      notice("Agent plan applied. The original video and speech continue beneath each photo cutaway.");
    })().catch(error=>{if(!controller.signal.aborted){notice(errorText(error));onPlanFailed?.(errorText(error));}})
      .finally(()=>{if(!accepted)staged.forEach(local=>URL.revokeObjectURL(local.url));if(importAbort.current===controller){importAbort.current=null;setImporting(false);}});
    return ()=>controller.abort();
  }, [agentRequest]);

  useEffect(() => {
    if (!relinkRequest || consumedRequest.current.has(relinkRequest.id)) return;
    consumedRequest.current.add(relinkRequest.id);
    const controller = new AbortController();
    void (async () => {
      for (const file of relinkRequest.files) {
        const local = await inspectFile(file, controller.signal);
        const matches = draftMedia(draftRef.current).filter(clip => clip.source.sha256 === local.source.sha256);
        if (!matches.length) { URL.revokeObjectURL(local.url); continue; }
        let used = false;
        try {
          for (const clip of matches) {
            assertSourceMatch(clip.source, local.source);
            const old = media.current.get(clip.id);
            if (old) URL.revokeObjectURL(old.url);
            media.current.set(clip.id, used ? {...local,url:URL.createObjectURL(file)} : local);
            used=true;
          }
        } finally { if (!used) URL.revokeObjectURL(local.url); }
      }
      if (!controller.signal.aborted) { setMediaVersion(v=>v+1); notice(readOnly ? "Saved source files restored for review." : "Saved source files restored. Continue editing where you left off."); }
    })().catch(error => { if (!controller.signal.aborted) notice(errorText(error)); });
    return () => controller.abort();
  // Request IDs identify immutable deliveries. Parent playback/comment updates
  // can recreate the wrapper object while this delivery is still decoding.
  }, [relinkRequest?.id]);
  useEffect(() => {
    if (!readOnly) onSourcesChange?.([...new Map([...media.current.values()].map(local => [local.source.sha256, {file:local.file,sha256:local.source.sha256}])).values()]);
  }, [mediaVersion, onSourcesChange, readOnly]);

  useEffect(() => {
    const id = draft.narration?.resultId;
    setVoice(null); setVoiceIssue("");
    if (!id) return;
    if (!resolveNarration) { setVoiceIssue("Open this plan in connected Studio to restore its narration."); return; }
    const abort = new AbortController(); let url: string | undefined;
    void resolveNarration(id, abort.signal).then(blob => {
      if (abort.signal.aborted) return;
      if (!blob.size || blob.size > EDIT_LIMITS.narrationBytes) throw new Error("Narration must be under 16 MB.");
      url = URL.createObjectURL(blob); setVoice({id, blob, url});
    }).catch(error => { if (!abort.signal.aborted) setVoiceIssue(errorText(error)); });
    return () => { abort.abort(); if (url) URL.revokeObjectURL(url); };
  }, [draft.narration?.resultId, resolveNarration, voiceRetry]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !active) return;
    const controller = new AbortController();
    const signal = controller.signal;
    let decoded: DecodedMedia | undefined;
    const previous = document.createElement("canvas"); previous.width = canvas.width; previous.height = canvas.height;
    let hasPrevious = false;
    const overlayPainter = new OverlayPainter(draft, media.current, signal);
    const narration = draft.narration && voice?.id === draft.narration.resultId ? new Audio(voice.url) : undefined;
    if (narration && draft.narration) narration.volume = draft.narration.volume;
    setPreviewError("");
    const paint = async () => {
      const position = locateTime(draft.clips, timeRef.current);
      if (!position) {
        canvas.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
        return;
      }
      if (position.index > 0) {
        const outgoing = draft.clips[position.index - 1], local = media.current.get(outgoing.id);
        if (local) {
          const prior = await decodeMedia(local.url, outgoing.source.kind, signal);
          try {
            if (prior.element instanceof HTMLVideoElement) await seekMedia(prior.element, Math.max(outgoing.start, outgoing.end - 0.02), signal);
            drawFrame(previous, prior, outgoing, draft); hasPrevious = true;
          } finally { prior.dispose(); }
        }
      }
      for (let index = position.index; index < draft.clips.length; index++) {
        const clip = draft.clips[index]!;
        const local = media.current.get(clip.id);
        if (!local)
          throw new Error(`Reselect ${clip.source.name} to preview this clip.`);
        decoded = await decodeMedia(local.url, clip.source.kind, signal);
        const offset = index === position.index ? position.localTime : 0;
        const video =
          decoded.element instanceof HTMLVideoElement
            ? decoded.element
            : undefined;
        if (video) {
          await seekMedia(video, clip.start + offset * (clip.speed ?? 1), signal);
          video.playbackRate = clip.speed ?? 1; video.volume = draft.narration ? 0.22 : 1;
          video.muted = draft.audio === "muted";
        }
        const before = timelineDuration(draft.clips.slice(0, index));
        drawFrame(canvas, decoded, clip, draft, {time: before + offset, localTime: offset, previous: hasPrevious ? previous : undefined});
        await overlayPainter.paint(canvas, before + offset);
        if (!playing) return;
        if (video)
          await awaitMediaOperation(video.play(), signal, "Starting preview");
        throwIfAborted(signal);
        const start = performance.now();
        let narrationStarted = false;
        while (true) {
          const now = await nextFrame(signal);
          const elapsed = video
            ? Math.max(0, video.currentTime - clip.start) / (clip.speed ?? 1)
            : offset + (now - start) / 1000;
          if (narration && draft.narration && !narrationStarted && before + elapsed >= draft.narration.offset) {
            narration.currentTime = Math.max(0, before + elapsed - draft.narration.offset);
            await awaitMediaOperation(narration.play(), signal, "Playing narration"); narrationStarted = true;
          }
          drawFrame(canvas, decoded, clip, draft, {time: before + elapsed, localTime: elapsed, previous: hasPrevious ? previous : undefined});
          await overlayPainter.paint(canvas, before + elapsed);
          timeRef.current = Math.min(
            total,
            before + Math.min(elapsed, clipDuration(clip)),
          );
          setTime(timeRef.current);
          if (elapsed >= clipDuration(clip) || video?.ended) break;
        }
        narration?.pause(); previous.getContext("2d")!.drawImage(canvas, 0, 0); hasPrevious = true;
        decoded.dispose();
        decoded = undefined;
      }
      setPlaying(false);
    };
    void paint()
      .catch((error) => {
        if (!signal.aborted) {
          setPreviewError(errorText(error));
          setPlaying(false);
        }
      })
      .finally(() => { decoded?.dispose(); narration?.pause(); overlayPainter.dispose(); });
    return () => {
      controller.abort();
      decoded?.dispose(); overlayPainter.dispose(); narration?.pause(); if (narration) { narration.removeAttribute("src"); narration.load(); }
      previous.width = previous.height = 0;
    };
  }, [active, draft, mediaVersion, playing, scrubVersion, total, voice]);

  const scrubTo = (seconds: number) => {
    if (!Number.isFinite(seconds)) return;
    setPlaying(false);
    const bounded = Math.max(0, Math.min(seconds, total));
    timeRef.current = bounded;
    setTime(bounded);
    setScrubVersion((version) => version + 1);
  };
  useEffect(() => {
    if (!seekRequest || consumedRequest.current.has(`seek:${seekRequest.id}`)) return;
    consumedRequest.current.add(`seek:${seekRequest.id}`);
    scrubTo(seekRequest.time);
  }, [seekRequest]);
  const togglePlayback = () => {
    if (!activeRef.current) return;
    if (!playing && timeRef.current >= total - 0.01) {
      timeRef.current = 0;
      setTime(0);
    }
    setPlaying((value) => !value);
  };
  const selectClip = (clip: EditClip, index: number) => {
    setSelectedId(clip.id);
    scrubTo(timelineDuration(draft.clips.slice(0, index)));
  };
  const removeClip = () => {
    if (!selected) return;
    const id = selected.id;
    if (update({ clips: draft.clips.filter((clip) => clip.id !== id), ...(draft.clips.length === 1 ? {overlays: []} : {}) }, "remove clip"))
      notice("Clip removed. Undo restores its cuts and text; reselect the original file to restore its media.");
  };
  const openPlan = async (file?: File) => {
    if (readOnly || !file) return;
    if (importAbort.current) {
      notice(
        "Wait for the current media import before opening another edit plan.",
      );
      return;
    }
    const controller = new AbortController();
    importAbort.current = controller;
    setImporting(true);
    const rebound = new Map<string, LocalMedia>();
    let accepted = false;
    try {
      if (file.size > EDIT_LIMITS.draftBytes)
        throw new Error("Edit plans must be smaller than 64 KiB.");
      const next = parseDraft(await file.text());
      throwIfAborted(controller.signal);
      // Rebind only full matching hashes from already selected local files.
      for (const clip of draftMedia(next)) {
        const match = [...media.current.values()].find(
          (local) => local.source.sha256 === clip.source.sha256,
        );
        if (match) {
          assertSourceMatch(clip.source, match.source);
          rebound.set(clip.id, {
            ...match,
            url: URL.createObjectURL(match.file),
          });
        }
      }
      for (const local of media.current.values())
        URL.revokeObjectURL(local.url);
      media.current = rebound;
      accepted = true;
      replaceHistory(createHistory(next));
      setSelectedId(next.clips[0]?.id ?? "");
      setMediaVersion((version) => version + 1);
      scrubTo(0);
      notice(
        "Edit plan opened. Undo history was reset. Reselect any missing original media; every file is verified by its full SHA-256 hash.",
      );
    } catch (error) {
      if (!controller.signal.aborted) notice(errorText(error));
    } finally {
      if (!accepted)
        for (const local of rebound.values()) URL.revokeObjectURL(local.url);
      if (importAbort.current === controller) {
        importAbort.current = null;
        setImporting(false);
      }
    }
  };
  const relink = async (file?: File) => {
    const clip = draftMedia(draftRef.current).find(
      (item) => item.id === relinkId.current,
    );
    if (!file || !clip || importAbort.current) return;
    const controller = new AbortController();
    importAbort.current = controller;
    setImporting(true);
    let local: LocalMedia | undefined;
    try {
      local = await inspectFile(file, controller.signal);
      assertSourceMatch(clip.source, local.source);
      if (
        !draftMedia(draftRef.current).some(
          (item) =>
            item.id === clip.id && item.source.sha256 === clip.source.sha256,
        )
      )
        throw new Error("The edit changed while reselecting media. Try again.");
      const prior = media.current.get(clip.id);
      if (prior) URL.revokeObjectURL(prior.url);
      media.current.set(clip.id, local);
      local = undefined;
      setMediaVersion((version) => version + 1);
      notice("Original media verified and reconnected.");
    } catch (error) {
      if (!controller.signal.aborted) notice(errorText(error));
    } finally {
      if (local) URL.revokeObjectURL(local.url);
      if (importAbort.current === controller) {
        importAbort.current = null;
        setImporting(false);
      }
    }
  };
  const startExport = async () => {
    if (readOnly) return;
    const format = formats.find((item) => item.mime === formatMime);
    if (!activeRef.current || !format || exportAbort.current) return;
    invalidateExport();
    setPlaying(false);
    setExporting(true);
    setProgress(0);
    const controller = new AbortController();
    exportAbort.current = controller;
    try {
      const result = await exportLocalVideo({
        draft: draftRef.current,
        media: new Map(media.current),
        narrationBlob: voice?.id === draftRef.current.narration?.resultId ? voice?.blob : undefined,
        format,
        signal: controller.signal,
        currentDraft: () => {
          if (!activeRef.current) throw inactiveExportError();
          return draftRef.current;
        },
        onProgress: setProgress,
      });
      assertCurrentRevision(
        { id: draftRef.current.id, revision: result.revision },
        draftRef.current,
        controller.signal,
      );
      if (!activeRef.current) throw inactiveExportError();
      const url = URL.createObjectURL(result.blob);
      outputUrl.current = url;
      setOutput({ ...result, url });
      setOutputKept(false);
      notice(
        `Your local ${result.extension.toUpperCase()} is ready to download. ${result.narration ? "Saved narration is included." : result.audio === "muted" ? "Audio is muted." : "Original clip audio is included where the source has audio."}`,
      );
    } catch (error) {
      notice(errorText(error));
    } finally {
      if (exportAbort.current === controller) {
        exportAbort.current = null;
        setExporting(false);
      }
    }
  };
  const handleFileInput = (event: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    event.target.value = "";
    void importFiles(files);
  };
  const handleDrop = (event: DragEvent<HTMLElement>) => {
    event.preventDefault();
    if (!importing) void importFiles(Array.from(event.dataTransfer.files));
  };
  const chooseOriginal = (id: string) => {
    relinkId.current = id;
    relinkInput.current?.click();
  };

  return (
    <section className={`rp-editor${readOnly ? " is-readonly" : ""}`} aria-label={readOnly ? "Saved edit review" : "Local video editor"} onBlur={finishHistoryGroup} onPointerUp={finishHistoryGroup} onKeyDown={historyShortcut}>
      <div className="rp-editor-heading">
        <div>
          <p className="rp-editor-eyebrow">YOUR FOOTAGE. YOUR STORY.</p>
          <h2>{readOnly ? "Review the saved edit" : "Bring your story to life."}</h2>
          <p>
            {readOnly ? `Saved revision ${draft.revision}. Playback and comments do not change this edit.` : "Arrange your media, refine the details, and create a video right here."}
          </p>
        </div>
        {!readOnly && <div className="rp-editor-plan-actions">
          <button
            type="button"
            disabled={importing}
            onClick={() => planInput.current?.click()}
          >
            Open edit plan
          </button>
          <button
            type="button"
            disabled={!draft.clips.length}
            onClick={() =>
              downloadBlob(
                new Blob([serializeDraft(draft)], { type: "application/json" }),
                `rendprop-edit-${draft.id}.json`,
              )
            }
          >
            Save edit plan
          </button>
        </div>}
      </div>
      {!readOnly && <>
      <div className="rp-editor-history" role="group" aria-label="Edit history">
        <button type="button" disabled={importing || !history.past.length} title={`Undo ${history.past.at(-1)?.label ?? "last edit"}`} aria-keyshortcuts="Control+Z Meta+Z" onClick={() => travelHistory("undo")}>Undo</button>
        <button type="button" disabled={importing || !history.future.length} title={`Redo ${history.future.at(-1)?.label ?? "last edit"}`} aria-keyshortcuts="Control+Shift+Z Meta+Shift+Z Control+Y" onClick={() => travelHistory("redo")}>Redo</button>
        <p>Up to {HISTORY_LIMITS.steps} recent steps. Undoing a removal requires original-file reselection.</p>
      </div>
      <div className="rp-editor-view-mode" role="group" aria-label="Editor view">
        <button type="button" aria-pressed={editorMode === "simple"} onClick={() => setEditorMode("simple")}>Simple view</button>
        <button type="button" aria-pressed={editorMode === "pro"} onClick={() => setEditorMode("pro")}>Pro view</button>
        <p>{editorMode === "simple" ? "Trim, order and caption the same editable draft. Pro view adds motion and transition controls." : "Full controls for this same editable draft."}</p>
      </div>
      <RecipePanel draft={draft} busy={importing || exporting || savingOutput} request={recipeRequest} onApply={applyRecipe} />
      </>}
      <input
        ref={filesInput}
        className="rp-editor-file-input"
        aria-label="Add photos or videos"
        type="file"
        accept="image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime"
        multiple
        disabled={readOnly}
        onChange={handleFileInput}
      />
      <input
        ref={planInput}
        className="rp-editor-file-input"
        aria-label="Open saved edit plan"
        type="file"
        accept=".json,application/json"
        disabled={readOnly}
        onChange={(event) => {
          const file = event.target.files?.[0];
          event.target.value = "";
          void openPlan(file);
        }}
      />
      <input
        ref={relinkInput}
        className="rp-editor-file-input"
        aria-label="Reselect original media"
        type="file"
        accept="image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime"
        onChange={(event) => {
          const file = event.target.files?.[0];
          event.target.value = "";
          void relink(file);
        }}
      />
      {message && (
        <p className="rp-editor-notice" role="status" aria-atomic="true">
          {message}
        </p>
      )}
      {missing.length > 0 && (
        <div className="rp-editor-missing" role="status">
          <strong>
            {missing.length} original{" "}
            {missing.length === 1 ? "file needs" : "files need"} reselection.
          </strong>{" "}
          Edit plans save your cuts and text. Select each missing clip to
          reconnect its original file.
        </div>
      )}
      {readOnly && draft.narration && (voiceIssue || !voiceReady) && <p className="rp-editor-missing" role="status">{voiceIssue || "Restoring saved narration for this review…"}{voiceIssue && <button type="button" onClick={() => setVoiceRetry(value => value + 1)}>Retry narration</button>}</p>}
      {readOnly && audioUnavailable && <p className="rp-editor-missing" role="status">This browser cannot preview the saved audio. Use a browser with audio playback support before approving the sound.</p>}
      <div className="rp-editor-workspace">
        <div className="rp-editor-main">
          <div className="rp-editor-preview-panel">
            <div className="rp-editor-panel-bar">
              <span>Video preview</span>
              <span className="rp-editor-audio-badge">
                {draft.narration ? "Narration" : draft.audio === "muted" ? "Audio muted" : "Original audio"}
              </span>
            </div>
            <div
              className={`rp-editor-stage ${draft.clips.length ? "has-media" : ""}`}
              onDragOver={(event) => event.preventDefault()}
              onDrop={handleDrop}
            >
              <canvas
                ref={canvasRef}
                width={dimensions.width}
                height={dimensions.height}
                style={{ aspectRatio: draft.ratio.replace(":", "/") }}
                aria-label={`Video preview at ${formatTime(time)}, ${draft.ratio} aspect ratio`}
              />
              {!draft.clips.length && (
                <div className="rp-editor-empty">
                  <span className="rp-editor-film-icon" aria-hidden="true">
                    ▧
                  </span>
                  <h3>A great story starts here.</h3>
                  <p>Drop in your photos and video clips.</p>
                  {!readOnly && <button
                    type="button"
                    className="rp-editor-primary"
                    disabled={importing}
                    onClick={() => filesInput.current?.click()}
                  >
                    {importing ? "Checking media…" : "Add photos & videos"}
                  </button>}
                  <small>JPG, PNG, WebP, MP4, WebM, supported MOV</small>
                </div>
              )}
              {previewError && draft.clips.length > 0 && (
                <div className="rp-editor-preview-error" role="status">
                  {previewError}
                </div>
              )}
            </div>
            <div className="rp-editor-transport">
              <button
                type="button"
                disabled={
                  !draft.clips.length ||
                  missing.length > 0 ||
                  exporting ||
                  importing
                }
                onClick={togglePlayback}
              >
                {playing
                  ? "Pause"
                  : time >= total && total > 0
                    ? "Replay"
                    : "Play"}
              </button>
              <input
                type="range"
                min="0"
                max={total || 1}
                step="0.05"
                value={time}
                disabled={!draft.clips.length || exporting}
                onChange={(event) => scrubTo(Number(event.target.value))}
                aria-label="Scrub video timeline"
                aria-valuetext={`${formatTime(time)} of ${formatTime(total)}`}
              />
              <output>
                {formatTime(time)} <span>/ {formatTime(total)}</span>
              </output>
            </div>
          </div>
          <div
            className="rp-editor-timeline"
            onDragOver={(event) => event.preventDefault()}
            onDrop={handleDrop}
          >
            <div className="rp-editor-panel-bar">
              <h3>
                Your sequence{" "}
                <span>
                  {draft.clips.length} / {EDIT_LIMITS.clips}
                </span>
              </h3>
              {!readOnly && <button
                type="button"
                disabled={importing || draft.clips.length >= EDIT_LIMITS.clips}
                onClick={() => filesInput.current?.click()}
              >
                {importing ? "Checking media…" : "+ Add media"}
              </button>}
            </div>
            {draft.clips.length ? (
              <ol className="rp-editor-clips">
                {draft.clips.map((clip, index) => (
                  <li key={clip.id}>
                    <button
                      type="button"
                      className={`rp-editor-clip ${selected?.id === clip.id ? "is-selected" : ""}`}
                      aria-pressed={selected?.id === clip.id}
                      aria-label={`Select clip ${index + 1}: ${clip.source.name}, ${formatTime(clipDuration(clip))}${media.current.has(clip.id) ? "" : ", original file missing"}`}
                      onClick={() => selectClip(clip, index)}
                    >
                      <div className="rp-editor-thumbnail">
                        {media.current.get(clip.id)?.thumbnail ? (
                          <img
                            src={media.current.get(clip.id)!.thumbnail}
                            alt=""
                          />
                        ) : (
                          <span>Reselect file</span>
                        )}
                        <span className="rp-editor-clip-number">
                          {String(index + 1).padStart(2, "0")}
                        </span>
                        <span className="rp-editor-clip-duration">
                          {formatTime(clipDuration(clip))}
                        </span>
                      </div>
                      <strong>{clip.source.name}</strong>
                      <small>
                        {clip.source.kind === "image" ? "Photo" : "Video"}
                        {clip.caption ? " · Caption" : ""}
                      </small>
                    </button>
                  </li>
                ))}
              </ol>
            ) : (
              <div className="rp-editor-empty-timeline">
                <span aria-hidden="true">＋</span>
                <p>Your clips will appear here in playback order.</p>
              </div>
            )}
            <p className="rp-editor-limit-note">
              Local limits: 12 clips · 128 MiB each · 512 MiB total · 3-minute
              edit. Videos open with their first 6 seconds.
            </p>
          </div>
        </div>
        {!readOnly && <aside className="rp-editor-inspector" aria-label="Edit controls">
          <div className="rp-editor-settings">
            <div className="rp-editor-panel-bar">
              <h3>Video settings</h3>
              <span className="rp-editor-revision">Rev {draft.revision}</span>
            </div>
            <label>
              Aspect ratio
              <select
                aria-label="Aspect ratio"
                value={draft.ratio}
                disabled={importing}
                onChange={(event) =>
                  update({ ratio: event.target.value as Ratio }, "aspect ratio")
                }
              >
                <option value="9:16">9:16 · Reels & stories</option>
                <option value="16:9">16:9 · Landscape</option>
                <option value="1:1">1:1 · Square</option>
              </select>
            </label>
            <label>
              Title overlay
              <input
                type="text"
                value={draft.title}
                maxLength={80}
                disabled={importing}
                onChange={(event) => update({ title: event.target.value }, "title overlay", "title")}
                placeholder="e.g. A fresh perspective"
              />
            </label>
            <label>
              Audio
              <select
                value={draft.audio}
                disabled={importing}
                onChange={(event) =>
                  update({ audio: event.target.value as EditDraft["audio"] }, "audio mode")
                }
              >
                <option value="original">Keep original clip audio</option>
                <option value="muted">Mute audio</option>
              </select>
            </label>
            {(resolveNarration || draft.narration) && <>
              <label>Saved narration<select aria-label="Saved narration" disabled={importing} value={draft.narration?.resultId ?? ""} onChange={event => {
                const choice = narrationChoices?.find(item => item.id === event.target.value);
                update({narration: choice ? {resultId: choice.id, label: choice.label, offset: 0, volume: 1, wordCaptions: choice.words.length > 0, words: choice.words} : undefined}, "narration");
              }}><option value="">No narration</option>{draft.narration && !narrationChoices?.some(item => item.id === draft.narration?.resultId) && <option value={draft.narration.resultId}>{draft.narration.label || "Saved narration"}</option>}{narrationChoices?.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}</select></label>
              {!narrationChoices?.length && <p className="rp-editor-limit-note">Generate narration in AI tools for this property, then return here to use the saved result.</p>}
              {draft.narration && <>
                <label>Narration starts at (seconds)<input aria-label="Narration starts at (seconds)" type="number" min={0} max={180} step={0.1} value={draft.narration.offset} onChange={event => {if(event.target.value !== "") update({narration: {...draft.narration!, offset: Number(event.target.value)}}, "narration start");}} /></label>
                <label>Narration volume<input type="range" min={0} max={1} step={0.05} value={draft.narration.volume} onChange={event => update({narration: {...draft.narration!, volume: Number(event.target.value)}}, "narration volume")} /></label>
                <label><input type="checkbox" checked={draft.narration.wordCaptions} disabled={!draft.narration.words.length} onChange={event => update({narration: {...draft.narration!, wordCaptions: event.target.checked}}, "timed narration captions")} />Timed narration captions</label>
                {voiceIssue ? <p role="status">{voiceIssue} <button onClick={() => setVoiceRetry(v => v + 1)}>Restore narration</button></p> : !voiceReady ? <p role="status">Restoring saved narration…</p> : <p className="rp-editor-limit-note">Narration is ready. Original clip sound is lowered beneath it. Audio beyond the end of the edit is trimmed.</p>}
              </>}
            </>}
          </div>
          <div className="rp-editor-clip-settings">
            <div className="rp-editor-panel-bar">
              <h3>{selected ? `Clip ${selectedIndex + 1}` : "Clip details"}</h3>
              {selected && (
                <span>
                  {selected.source.kind === "image" ? "PHOTO" : "VIDEO"}
                </span>
              )}
            </div>
            {selected ? (
              <>
                <p
                  className="rp-editor-selected-name"
                  title={selected.source.name}
                >
                  {selected.source.name}
                </p>
                {!media.current.has(selected.id) && (
                  <button
                    type="button"
                    className="rp-editor-relink"
                    disabled={importing}
                    onClick={() => chooseOriginal(selected.id)}
                  >
                    Reselect original file
                  </button>
                )}
                {selected.source.kind === "image" ? (
                  <label>
                    Photo duration (seconds)
                    <input
                      type="number"
                      min={0.5}
                      max={30}
                      step={0.5}
                      value={selected.end}
                      disabled={importing}
                      onChange={(event) => {
                        if (event.target.value !== "")
                          updateClip(selected.id, {
                            end: Number(event.target.value),
                          });
                      }}
                    />
                  </label>
                ) : (
                  <div className="rp-editor-trim">
                    <label>
                      Trim start (sec)
                      <input
                        type="number"
                        min={0}
                        max={selected.end - 0.5}
                        step={0.1}
                        value={Number(selected.start.toFixed(2))}
                        disabled={importing}
                        onChange={(event) => {
                          if (event.target.value !== "")
                            updateClip(selected.id, {
                              start: Number(event.target.value),
                            });
                        }}
                      />
                    </label>
                    <label>
                      Trim end (sec)
                      <input
                        type="number"
                        min={selected.start + 0.5}
                        max={selected.source.duration}
                        step={0.1}
                        value={Number(selected.end.toFixed(2))}
                        disabled={importing}
                        onChange={(event) => {
                          if (event.target.value !== "")
                            updateClip(selected.id, {
                              end: Number(event.target.value),
                            });
                        }}
                      />
                    </label>
                    <small>
                      Source {formatTime(selected.source.duration)} · Cut{" "}
                      {formatTime(clipDuration(selected))}
                    </small>
                  </div>
                )}
                {selected.source.kind === "video" && <div className="rp-editor-split-actions"><button type="button" disabled={importing || exporting || savingOutput || draft.clips.length >= EDIT_LIMITS.clips} onClick={splitAtPlayhead}>Split video at playhead</button><small>Move the playhead inside a video. Leave at least 0.5 seconds of source on both sides.</small></div>}
                {editorMode === "pro" && <>
                {selected.source.kind === "video" && <label>Playback speed<select aria-label="Playback speed" value={selected.speed ?? 1} disabled={importing} onChange={event => updateClip(selected.id, {speed: Number(event.target.value)})}><option value={0.25}>0.25× · Quarter speed</option><option value={0.5}>0.5× · Slow</option><option value={1}>1× · Normal</option><option value={1.5}>1.5×</option><option value={2}>2× · Fast</option><option value={4}>4×</option></select></label>}
                <label>Transition into this clip<select aria-label="Transition into this clip" value={selected.transition ?? "cut"} disabled={importing || selectedIndex === 0} onChange={event => updateClip(selected.id, {transition: event.target.value as Transition})}><option value="cut">Cut</option><option value="dissolve">Dissolve · 0.28 seconds</option><option value="whip">Whip · 0.18 seconds</option></select></label>
                {selected.source.kind === "image" && <label>Photo motion<select aria-label="Photo motion" value={selected.motion ?? "still"} disabled={importing} onChange={event => updateClip(selected.id, {motion: event.target.value as EditClip["motion"]})}><option value="still">Still</option><option value="push_in">Gentle push in</option><option value="pull_out">Gentle pull out</option><option value="pan_left">Pan left</option><option value="pan_right">Pan right</option></select></label>}
                <label>Caption style<select aria-label="Caption style" value={selected.captionStyle ?? "clean"} disabled={importing} onChange={event => updateClip(selected.id, {captionStyle: event.target.value as CaptionStyle})}><option value="clean">Clean lower third</option><option value="center">Bold center</option><option value="highlight">Highlight box</option></select></label>
                </>}
                <label>
                  Clip caption
                  <textarea
                    aria-label="Clip caption"
                    rows={3}
                    value={selected.caption}
                    maxLength={EDIT_LIMITS.captionCharacters}
                    disabled={importing}
                    onChange={(event) =>
                      updateClip(selected.id, { caption: event.target.value })
                    }
                    placeholder="A detail worth remembering"
                  />
                  <small>
                    {selected.caption.length} / {EDIT_LIMITS.captionCharacters}
                  </small>
                </label>
                <label>
                  Frame left / right
                  <input
                    type="range"
                    min="0"
                    max="1"
                    step="0.01"
                    value={selected.focusX}
                    disabled={importing}
                    onChange={(event) =>
                      updateClip(selected.id, {
                        focusX: Number(event.target.value),
                      })
                    }
                  />
                </label>
                <label>
                  Frame up / down
                  <input
                    type="range"
                    min="0"
                    max="1"
                    step="0.01"
                    value={selected.focusY}
                    disabled={importing}
                    onChange={(event) =>
                      updateClip(selected.id, {
                        focusY: Number(event.target.value),
                      })
                    }
                  />
                </label>
                <div className="rp-editor-reorder">
                  <button
                    type="button"
                    disabled={selectedIndex === 0 || importing}
                    onClick={() =>
                      update({
                        clips: moveClip(
                          draft.clips,
                          selectedIndex,
                          selectedIndex - 1,
                        ),
                      }, "clip order")
                    }
                  >
                    Move earlier
                  </button>
                  <button
                    type="button"
                    disabled={
                      selectedIndex === draft.clips.length - 1 || importing
                    }
                    onClick={() =>
                      update({
                        clips: moveClip(
                          draft.clips,
                          selectedIndex,
                          selectedIndex + 1,
                        ),
                      }, "clip order")
                    }
                  >
                    Move later
                  </button>
                </div>
                <button
                  type="button"
                  className="rp-editor-remove"
                  disabled={importing}
                  onClick={removeClip}
                >
                  Remove from edit
                </button>
              </>
            ) : (
              <p className="rp-editor-inspector-empty">
                Select a clip to trim it, add a caption, and adjust the framing.
              </p>
            )}
          </div>
          {!!draft.overlays?.length && <div className="rp-editor-clip-settings"><h3>Agent photo cutaways</h3><p>The base video and its speech continue underneath. Cutaways replace only the picture during their selected times.</p>{draft.overlays.map((overlay,index)=><fieldset key={overlay.id} disabled={importing}><legend>Cutaway {index+1} · {overlay.source.name}</legend>{!media.current.has(overlay.id)&&<button onClick={()=>chooseOriginal(overlay.id)}>Reselect cutaway photo</button>}<label>Cutaway {index+1} starts (seconds)<input type="number" min={0} max={total} step={.1} value={overlay.start} onChange={event=>{if(event.target.value!=="")update({overlays:draft.overlays!.map(item=>item.id===overlay.id?{...item,start:Number(event.target.value)}:item)},"cutaway start");}} /></label><label>Cutaway {index+1} ends (seconds)<input type="number" min={0} max={total} step={.1} value={overlay.end} onChange={event=>{if(event.target.value!=="")update({overlays:draft.overlays!.map(item=>item.id===overlay.id?{...item,end:Number(event.target.value)}:item)},"cutaway end");}} /></label><label>Cutaway {index+1} caption<input value={overlay.caption} maxLength={120} onChange={event=>update({overlays:draft.overlays!.map(item=>item.id===overlay.id?{...item,caption:event.target.value}:item)},"cutaway caption")} /></label><button onClick={()=>scrubTo(overlay.start)}>Preview cutaway {index+1}</button><button onClick={()=>update({overlays:draft.overlays!.filter(item=>item.id!==overlay.id)},"remove cutaway")}>Remove cutaway {index+1}</button></fieldset>)}</div>}
          <div className="rp-editor-export">
            <h3>Ready when you are.</h3>
            <p>A local video file, made in this browser.</p>
            {formats.length > 0 ? (
              <label>
                Export format
                <select
                  value={formatMime}
                  disabled={exporting}
                  onChange={(event) => setFormatMime(event.target.value)}
                >
                  {formats.map((format) => (
                    <option key={format.mime} value={format.mime}>
                      {format.label} · Browser encoder
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <p role="status">
                Local recording is unavailable in this browser. You can still
                save the edit plan and open it in a browser with canvas
                recording support.
              </p>
            )}
            {audioUnavailable && (
              <p role="status">
                This browser cannot export original audio. Choose Mute audio
                explicitly or use a browser with Web Audio support.
              </p>
            )}
            {exporting ? (
              <>
                <progress
                  value={progress}
                  max="1"
                  aria-label="Local video export progress"
                />
                <p role="status">
                  Exporting {Math.round(progress * 100)}% · keep this tab
                  visible
                </p>
                <button
                  type="button"
                  onClick={() =>
                    exportAbort.current?.abort(
                      new DOMException(
                        "Export cancelled. Your edit is unchanged.",
                        "AbortError",
                      ),
                    )
                  }
                >
                  Cancel export
                </button>
              </>
            ) : (
              <button
                type="button"
                className="rp-editor-primary rp-editor-export-button"
                disabled={
                  !draft.clips.length ||
                  missing.length > 0 ||
                  !formats.length ||
                  audioUnavailable ||
                  !voiceReady ||
                  importing
                }
                onClick={() => void startExport()}
              >
                Export{" "}
                {formats.find((format) => format.mime === formatMime)?.label ??
                  "video"}
              </button>
            )}
            <p className="rp-editor-export-note">
              {draft.narration ? "Includes saved narration and timed captions when enabled; original sound is lowered beneath it." : draft.audio === "muted"
                ? "Original clip audio will be muted."
                : draft.overlays?.length ? "Original video audio continues through every photo cutaway." : "Keeps original audio within each video trim; photos are silent."}{" "}
              Export takes about the length of your edit. Keep this tab visible.{" "}
              {formats.some((format) => format.extension === "mp4")
                ? "Choose the format supported by your destination."
                : "This browser offers WebM, not MP4."}{" "}
              This is a local draft, not a published tour.
            </p>
            {output && (
              <a
                className="rp-editor-download"
                href={output.url}
                download={`rendprop-local-r${output.revision}.${output.extension}`}
                onClick={() => setOutputKept(true)}
              >
                Download {output.extension.toUpperCase()} ·{" "}
                {(output.blob.size / 1024 / 1024).toFixed(1)} MiB
              </a>
            )}
            {output && onSaveOutput && (
              <button type="button" disabled={savingOutput} onClick={() => {
                setSavingOutput(true);
                void onSaveOutput(output).then(() => {setOutputKept(true); notice("Video saved to your listing. Open Properties to review and publish it.");})
                  .catch(error => notice(errorText(error))).finally(() => setSavingOutput(false));
              }}>{savingOutput ? "Saving to your listing…" : "Save video to listing"}</button>
            )}
          </div>
        </aside>}
      </div>
    </section>
  );
}

export default VideoEditor;
