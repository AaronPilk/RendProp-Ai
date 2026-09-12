import {
  useEffect,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
} from "react";
import {
  EDIT_LIMITS,
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

export type VideoEditorProps = {
  active?: boolean;
  initialDraft?: EditDraft;
  onNotice?: (message: string) => void;
  onDraftChange?: (draft: EditDraft) => void;
  importRequest?: { id: string; files: File[] };
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
}: VideoEditorProps) {
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
  const [draft, setDraft] = useState<EditDraft>(initial.draft);
  const activeRef = useRef(active);
  activeRef.current = active;
  const draftRef = useRef(draft);
  const media = useRef(new Map<string, LocalMedia>());
  const [mediaVersion, setMediaVersion] = useState(0);
  const [selectedId, setSelectedId] = useState(draft.clips[0]?.id ?? "");
  const [message, setMessage] = useState(initial.issue);
  const [importing, setImporting] = useState(false);
  const importAbort = useRef<AbortController | null>(null);
  const [exporting, setExporting] = useState(false);
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
  const selected =
    draft.clips.find((clip) => clip.id === selectedId) ?? draft.clips[0];
  const selectedIndex = selected ? draft.clips.indexOf(selected) : -1;
  const missing = draft.clips.filter((clip) => !media.current.has(clip.id));
  const needsAudio =
    draft.audio === "original" &&
    draft.clips.some((clip) => clip.source.kind === "video");
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
  const replaceDraft = (next: EditDraft) => {
    invalidateExport();
    setPlaying(false);
    draftRef.current = next;
    setDraft(next);
    timeRef.current = Math.min(timeRef.current, timelineDuration(next.clips));
    setTime(timeRef.current);
  };
  const update = (patch: Parameters<typeof reviseDraft>[1]) => {
    try {
      replaceDraft(reviseDraft(draftRef.current, patch));
    } catch (error) {
      notice(errorText(error));
    }
  };
  const updateClip = (
    id: string,
    patch: Partial<
      Pick<EditClip, "start" | "end" | "caption" | "focusX" | "focusY">
    >,
  ) => {
    update({
      clips: draftRef.current.clips.map((clip) =>
        clip.id === id ? { ...clip, ...patch } : clip,
      ),
    });
  };

  useEffect(() => {
    callbacks.current.onDraftChange?.(draft);
  }, [draft]);
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
    if (!files.length) return;
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
      const next = reviseDraft(snapshot, {
        clips: [...snapshot.clips, ...staged.map((item) => item.clip)],
      });
      for (const item of staged) media.current.set(item.clip.id, item.local);
      accepted = true;
      replaceDraft(next);
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
    if (!importRequest || consumedRequest.current.has(importRequest.id)) return;
    consumedRequest.current.add(importRequest.id);
    void importFiles(importRequest.files);
    // Each stable request ID is consumed once; local changes must not replay an import.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [importRequest]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !active) return;
    const controller = new AbortController();
    const signal = controller.signal;
    let decoded: DecodedMedia | undefined;
    setPreviewError("");
    const paint = async () => {
      const position = locateTime(draft.clips, timeRef.current);
      if (!position) {
        canvas.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
        return;
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
          await seekMedia(video, clip.start + offset, signal);
          video.muted = draft.audio === "muted";
        }
        drawFrame(canvas, decoded, clip, draft);
        if (!playing) return;
        if (video)
          await awaitMediaOperation(video.play(), signal, "Starting preview");
        throwIfAborted(signal);
        const start = performance.now();
        const before = timelineDuration(draft.clips.slice(0, index));
        while (true) {
          const now = await nextFrame(signal);
          const elapsed = video
            ? Math.max(0, video.currentTime - clip.start)
            : offset + (now - start) / 1000;
          drawFrame(canvas, decoded, clip, draft);
          timeRef.current = Math.min(
            total,
            before + Math.min(elapsed, clipDuration(clip)),
          );
          setTime(timeRef.current);
          if (elapsed >= clipDuration(clip) || video?.ended) break;
        }
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
      .finally(() => decoded?.dispose());
    return () => {
      controller.abort();
      decoded?.dispose();
    };
  }, [active, draft, mediaVersion, playing, scrubVersion, total]);

  const scrubTo = (seconds: number) => {
    setPlaying(false);
    timeRef.current = seconds;
    setTime(seconds);
    setScrubVersion((version) => version + 1);
  };
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
    update({ clips: draft.clips.filter((clip) => clip.id !== id) });
    const local = media.current.get(id);
    if (local) URL.revokeObjectURL(local.url);
    media.current.delete(id);
    setMediaVersion((version) => version + 1);
    setSelectedId(draft.clips.find((clip) => clip.id !== id)?.id ?? "");
  };
  const openPlan = async (file?: File) => {
    if (!file) return;
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
      for (const clip of next.clips) {
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
      replaceDraft(next);
      setSelectedId(next.clips[0]?.id ?? "");
      setMediaVersion((version) => version + 1);
      scrubTo(0);
      notice(
        "Edit plan opened. Reselect any missing original media; every file is verified by its full SHA-256 hash.",
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
    const clip = draftRef.current.clips.find(
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
        !draftRef.current.clips.some(
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
      notice(
        `Your local ${result.extension.toUpperCase()} is ready to download. ${result.audio === "muted" ? "Audio is muted." : "Original clip audio is included where the source has audio."}`,
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
    <section className="rp-editor" aria-label="Local video editor">
      <div className="rp-editor-heading">
        <div>
          <p className="rp-editor-eyebrow">YOUR FOOTAGE. YOUR STORY.</p>
          <h2>Make the listing move.</h2>
          <p>
            Arrange your media, refine the details, and create a video right
            here.
          </p>
        </div>
        <div className="rp-editor-plan-actions">
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
        </div>
      </div>
      <input
        ref={filesInput}
        className="rp-editor-file-input"
        aria-label="Add photos or videos"
        type="file"
        accept="image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime"
        multiple
        onChange={handleFileInput}
      />
      <input
        ref={planInput}
        className="rp-editor-file-input"
        aria-label="Open saved edit plan"
        type="file"
        accept=".json,application/json"
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
        <p className="rp-editor-notice" role="status">
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
      <div className="rp-editor-workspace">
        <div className="rp-editor-main">
          <div className="rp-editor-preview-panel">
            <div className="rp-editor-panel-bar">
              <span>Video preview</span>
              <span className="rp-editor-audio-badge">
                {draft.audio === "muted" ? "Audio muted" : "Original audio"}
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
                  <p>Drop in your listing photos and video clips.</p>
                  <button
                    type="button"
                    className="rp-editor-primary"
                    disabled={importing}
                    onClick={() => filesInput.current?.click()}
                  >
                    {importing ? "Checking media…" : "Add photos & videos"}
                  </button>
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
              <button
                type="button"
                disabled={importing || draft.clips.length >= EDIT_LIMITS.clips}
                onClick={() => filesInput.current?.click()}
              >
                {importing ? "Checking media…" : "+ Add media"}
              </button>
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
              Local limits: 12 clips · 32 MiB each · 160 MiB total · 3-minute
              edit. Videos open with their first 6 seconds.
            </p>
          </div>
        </div>
        <aside className="rp-editor-inspector" aria-label="Edit controls">
          <div className="rp-editor-settings">
            <div className="rp-editor-panel-bar">
              <h3>Video settings</h3>
              <span className="rp-editor-revision">Rev {draft.revision}</span>
            </div>
            <label>
              Aspect ratio
              <select
                value={draft.ratio}
                disabled={importing}
                onChange={(event) =>
                  update({ ratio: event.target.value as Ratio })
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
                onChange={(event) => update({ title: event.target.value })}
                placeholder="e.g. A new perspective on home"
              />
            </label>
            <label>
              Audio
              <select
                value={draft.audio}
                disabled={importing}
                onChange={(event) =>
                  update({ audio: event.target.value as EditDraft["audio"] })
                }
              >
                <option value="original">Keep original clip audio</option>
                <option value="muted">Mute audio</option>
              </select>
            </label>
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
                <label>
                  Clip caption
                  <textarea
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
                      })
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
                      })
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
              {draft.audio === "muted"
                ? "Audio will be muted."
                : "Keeps original audio within each video trim; photos are silent."}{" "}
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
              >
                Download {output.extension.toUpperCase()} ·{" "}
                {(output.blob.size / 1024 / 1024).toFixed(1)} MiB
              </a>
            )}
          </div>
        </aside>
      </div>
    </section>
  );
}

export default VideoEditor;
