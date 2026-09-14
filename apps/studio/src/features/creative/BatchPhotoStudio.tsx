import { useEffect, useRef, useState } from "react";
import type { Listing, StudioPhoto, Workspace } from "../../data/contracts";
import { uuid } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { businessApi } from "../business/api";
import { uploadListingAsset } from "../listings/uploads";
import type { UploadedAsset, UploadJournal } from "../listings/uploads";
import { editedImage, imageFromURL } from "./media";
import type { SourceImage } from "./media";
import { PRESETS, record, requiredText, text } from "./model";
import type { Edit } from "./model";

export const MAX_BATCH_PHOTOS = 6;
export type BatchEdit = { edit: Edit; style: string; prompt: string };
export type BatchPhotoResult = {
  file: File; preview: string; originalPreview: string; originalAssetId: string;
  provenanceId: string | null; disclosure: string;
};
export type BatchPhotoEntry = {
  photo: StudioPhoto; requestKey: string;
  state: "queued" | "preparing" | "generating" | "ready" | "saving" | "saved" | "failed" | "stopped";
  error: string | null; result?: BatchPhotoResult; output?: UploadedAsset; journal?: UploadJournal;
};
type BatchDependencies = {
  assertScope: () => void;
  prepare: (photo: StudioPhoto, signal: AbortSignal) => Promise<SourceImage>;
  upload: (file: File, role: "original" | "gallery", signal: AbortSignal, resume?: UploadJournal, onJournal?: (journal: UploadJournal) => void) => Promise<UploadedAsset>;
  generate: (source: SourceImage, originalId: string, choice: BatchEdit, key: string, caption: string, signal: AbortSignal) => Promise<unknown>;
  attach: (entry: BatchPhotoEntry, signal: AbortSignal) => Promise<void>;
};
const describe = (value: unknown) => value instanceof Error ? value.message : "This photo could not be completed.";
export function batchEligible(photo: StudioPhoto, listingId: string) {
  return photo.listingId === listingId && (!(photo.isAltered || photo.isStaged) || !!photo.originalUrl);
}

/** One explicit run, one paid dispatch per entry. Native /ai-photo only has a
 * short dedupe window, so an ambiguous generation is never retried here. Save
 * recovery retains the actual result and upload receipt instead. */
export class PhotoBatch {
  readonly entries: BatchPhotoEntry[];
  readonly choice: BatchEdit;
  private abort = new AbortController();
  private running = false;
  private saving = false;
  private stopped = false;
  private started = false;
  constructor(photos: readonly StudioPhoto[], listingId: string, choice: BatchEdit, private deps: BatchDependencies, private changed: () => void = () => {}) {
    if (!photos.length || photos.length > MAX_BATCH_PHOTOS || new Set(photos.map(p => p.id)).size !== photos.length || photos.some(p => !batchEligible(p, listingId))) throw new Error(`Choose 1–${MAX_BATCH_PHOTOS} photos with their originals from this property.`);
    if (!PRESETS.some(p => p.id === choice.edit) || choice.edit === "custom" && (!choice.prompt.trim() || choice.prompt.trim().length > 600) || choice.edit === "stage" && !["modern", "rustic", "minimalist", "scandinavian"].includes(choice.style)) throw new Error("Choose an edit and review its settings first.");
    this.choice = { ...choice, prompt: choice.prompt.trim() };
    const batchId = crypto.randomUUID();
    this.entries = photos.map(photo => ({ photo: { ...photo }, requestKey: `studio-photo-batch:${batchId}:${crypto.randomUUID()}`, state: "queued", error: null }));
  }
  get busy() { return this.running || this.saving; }
  get stopRequested() { return this.stopped; }
  private check() { this.abort.signal.throwIfAborted(); this.deps.assertScope(); }
  private emit() { if (!this.abort.signal.aborted) this.changed(); }
  stop() { this.stopped = true; this.emit(); }
  dispose() { this.stopped = true; this.abort.abort(); }
  async run() {
    if (this.started) return;
    this.check(); this.started = true; this.running = true; this.emit();
    try {
      for (const entry of this.entries) {
        this.check();
        if (this.stopped) { entry.state = "stopped"; continue; }
        try {
          entry.state = "preparing"; this.emit();
          const source = await this.deps.prepare(entry.photo, this.abort.signal);
          this.check();
          if (this.stopped) { entry.state = "stopped"; continue; }
          const original = await this.deps.upload(source.file, "original", this.abort.signal);
          this.check();
          if (this.stopped) { entry.state = "stopped"; continue; }
          entry.state = "generating"; this.emit();
          const raw = record(await this.deps.generate(source, original.assetId, this.choice, entry.requestKey, entry.photo.caption || "Property photo", this.abort.signal));
          this.check();
          const base64 = requiredText(raw.image_b64, "an edited photo", 32 * 1024 * 1024), mime = text(raw.mime, 50) || "image/png";
          const file = editedImage(base64, mime);
          let provenanceId: string | null = null;
          try { const proof = raw.provenance ? record(raw.provenance) : {}; if (proof.recorded === true) provenanceId = uuid(proof.id, "photo disclosure"); }
          catch { /* Keep the paid preview available; an invalid proof cannot authorize gallery save. */ }
          entry.result = { file, preview: `data:${mime};base64,${base64}`, originalPreview: source.preview, originalAssetId: original.assetId,
            provenanceId,
            disclosure: requiredText(raw.disclosure, "the photo disclosure", 1000) };
          entry.state = "ready";
          if (!entry.result.provenanceId) entry.error = "The preview is ready, but its disclosure could not be saved. Download it; it cannot join the gallery yet.";
        } catch (error) {
          if (this.abort.signal.aborted) throw error;
          this.check();
          const dispatched = entry.state === "generating";
          entry.state = "failed";
          entry.error = `${describe(error)}${dispatched ? " No automatic retry was made. A request with a lost response may still count against your allowance." : " No AI edit was started for this photo."}`;
          const status = (error as { status?: number })?.status;
          if ([401, 402, 403, 429].includes(status ?? 0)) this.stopped = true;
        }
        this.emit();
      }
    } finally { this.running = false; this.emit(); }
  }
  async save(index: number) {
    const entry = this.entries[index];
    if (this.busy || !entry?.result?.provenanceId || entry.state !== "ready") return;
    this.check(); this.saving = true; entry.state = "saving"; entry.error = null; this.emit();
    try {
      if (!entry.output) entry.output = await this.deps.upload(entry.result.file, "gallery", this.abort.signal, entry.journal, journal => { this.check(); entry.journal = journal; });
      this.check();
      await this.deps.attach(entry, this.abort.signal);
      this.check(); entry.state = "saved";
    } catch (error) {
      if (this.abort.signal.aborted) throw error;
      this.check(); entry.state = "ready"; entry.error = `${describe(error)} Your preview is kept. Save again to finish; this does not generate another edit.`;
    } finally { this.saving = false; this.emit(); }
  }
}

export type BatchPhotoStudioProps = {
  services: StudioServices; workspace: Workspace; listing: Listing; photos: readonly StudioPhoto[];
  canCreate: boolean; onChanged: () => void; onComplete?: () => void; disabled?: boolean; onBusyChange?: (busy: boolean) => void;
};
export default function BatchPhotoStudio(props: BatchPhotoStudioProps) {
  // A property/account change always gets a fresh component, even in callers
  // that do not key the surrounding Creative workspace.
  return <BatchPhotoStudioContent key={`${props.workspace.user.id}:${props.workspace.org.id}:${props.listing.id}`} {...props} />;
}
function BatchPhotoStudioContent({ services, workspace, listing, photos, canCreate, onChanged, onComplete, disabled, onBusyChange }: BatchPhotoStudioProps) {
  const [selected, setSelected] = useState<string[]>([]), [edit, setEdit] = useState<Edit>("declutter"), [style, setStyle] = useState("modern"), [prompt, setPrompt] = useState("");
  const [batch, setBatch] = useState<PhotoBatch | null>(null), [, redraw] = useState(0), [error, setError] = useState<string | null>(null);
  const [allowance, setAllowance] = useState<{ used: number; cap: number } | null>(null), [allowanceRead, setAllowanceRead] = useState(false);
  const alive = useRef(true), batchRef = useRef<PhotoBatch | null>(null), callbacks = useRef({ onChanged, onComplete, onBusyChange });
  callbacks.current = { onChanged, onComplete, onBusyChange };
  const version = useRef(services.getSnapshot().identityVersion).current;
  const eligible = photos.filter(photo => batchEligible(photo, listing.id));
  const choices = eligible.filter(photo => selected.includes(photo.id));
  function assertScope() {
    const current = services.getSnapshot();
    if (!alive.current || current.identityVersion !== version || current.status !== "signed-in" || current.identity?.userId !== workspace.user.id || current.identity.isAnonymous || listing.orgId !== workspace.org.id || !["owner", "admin", "agent"].includes(workspace.memberships.find(m => m.orgId === workspace.org.id)?.role ?? "")) throw new Error("Your account or editing access changed. Reopen this property before editing.");
  }
  async function refreshAllowance(signal?: AbortSignal) {
    try {
      const account = await businessApi(services, workspace).account(signal);
      assertScope(); const meter = account.meters.find(m => m.key === "photo_edits");
      setAllowance(!account.degraded && meter ? { used: meter.used, cap: meter.cap } : null);
    } catch { if (alive.current && !signal?.aborted) setAllowance(null); }
    finally { if (alive.current && !signal?.aborted) setAllowanceRead(true); }
  }
  useEffect(() => {
    alive.current = true;
    const controller = new AbortController();
    void refreshAllowance(controller.signal);
    const unsubscribe = services.subscribe(snapshot => {
      if (snapshot.identityVersion !== version) { batchRef.current?.dispose(); if (alive.current) { setBatch(null); batchRef.current = null; setSelected([]); callbacks.current.onBusyChange?.(false); setError("Your account changed. Reopen this property before editing."); } }
    });
    return () => { alive.current = false; controller.abort(); unsubscribe(); batchRef.current?.dispose(); callbacks.current.onBusyChange?.(false); };
  }, [services, version]);
  const unsaved = !!batch?.entries.some(entry => entry.result && entry.state !== "saved"), busy = batch?.busy ?? false;
  useEffect(() => {
    if (!busy && !unsaved) return;
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [busy, unsaved]);
  function reset() {
    if (busy || unsaved && !window.confirm("Discard these unsaved previews? Download or save any photos you want to keep first.")) return;
    batchRef.current?.dispose(); batchRef.current = null; setBatch(null); setError(null);
  }
  async function start() {
    if (batchRef.current || disabled || !canCreate) return;
    try {
      assertScope();
      const dispatch = (path: string, body: unknown, signal: AbortSignal, extra: Partial<Parameters<StudioServices["api"]>[1]> = {}) => services.api(`/functions/v1/${path}`, { orgId: workspace.org.id, signal, method: "POST", body, ...extra });
      const next = new PhotoBatch(choices, listing.id, { edit, style, prompt }, {
        assertScope,
        prepare: (photo, signal) => imageFromURL((photo.isAltered || photo.isStaged) ? photo.originalUrl! : photo.url, `${photo.caption || "property"}.jpg`, signal),
        upload: (file, role, signal, resume, onJournal) => uploadListingAsset(services, { orgId: workspace.org.id, listingId: listing.id, file, role, signal, resume, onJournal }),
        generate: (source, originalId, choice, key, caption, signal) => dispatch("ai-photo", { listing_id: listing.id, original_asset_id: originalId, image_b64: source.base64, mime: source.mime, edit: choice.edit, space_type: listing.spaceType, label: caption.slice(0, 80), ...(choice.edit === "stage" ? { style: choice.style } : {}), ...(choice.edit === "custom" ? { prompt: choice.prompt } : {}) }, signal, { idempotencyKey: key, timeoutMs: 300_000, maxResponseBytes: 32 * 1024 * 1024 }),
        attach: async (entry, signal) => {
          await services.api(`/functions/v1/me/compliance/${entry.result!.provenanceId}`, { orgId: workspace.org.id, signal, method: "PATCH", body: { original_asset_id: entry.result!.originalAssetId, altered_asset_id: entry.output!.assetId } });
          assertScope();
          const attached = record(await dispatch("studio/photos", { listing_id: listing.id, asset_id: entry.output!.assetId, caption: entry.photo.caption?.slice(0, 400) || PRESETS.find(p => p.id === edit)?.name, provenance_id: entry.result!.provenanceId }, signal));
          const photo = record(attached.photo);
          if (attached.ok !== true || photo.id !== entry.output!.assetId || photo.listing_id !== listing.id) throw new Error("Gallery save could not be confirmed. Save again to check it.");
        },
      }, () => { if (alive.current) { redraw(value => value + 1); callbacks.current.onBusyChange?.(batchRef.current?.busy ?? false); } });
      batchRef.current = next; setBatch(next); setError(null);
      await next.run();
      if (alive.current) void refreshAllowance();
    } catch (reason) { if (alive.current) setError(describe(reason)); }
  }
  async function save(index: number) {
    if (!batch || !canCreate || disabled) return;
    try { await batch.save(index); if (alive.current && batch.entries[index]?.state === "saved") { callbacks.current.onChanged(); callbacks.current.onComplete?.(); } }
    catch (reason) { if (alive.current) setError(describe(reason)); }
  }
  return <section className="creative-card creative-wide batch-photo-studio" aria-label="Edit several photos">
    <h2>One change. Several photos.</h2>
    <p>Choose up to {MAX_BATCH_PHOTOS} photos, apply the same change, then review each result. Originals stay with the property.</p>
    <p className="batch-photo-status">{allowance ? `${Math.max(0, allowance.cap - allowance.used)} of ${allowance.cap} photo edits remaining in your shared allowance.` : allowanceRead ? "Your allowance could not be refreshed. Each photo uses one edit from the same plan as your iPhone." : "Checking your shared photo allowance…"}</p>
    {error && <p role="alert" className="creative-alert">{error}</p>}
    {!batch ? <>
      <fieldset disabled={!!disabled || !canCreate}><legend>1. Choose one change for these photos</legend><div className="creative-preset-grid">{PRESETS.filter(p => listing.spaceType === "real_estate" || p.id !== "lawn").map(p => <button type="button" key={p.id} aria-pressed={edit === p.id} className={edit === p.id ? "selected" : ""} onClick={() => setEdit(p.id)}>{p.name}</button>)}</div>
        {edit === "stage" && <div className="creative-actions" aria-label="Staging style">{["modern", "rustic", "minimalist", "scandinavian"].map(value => <button type="button" key={value} aria-pressed={style === value} onClick={() => setStyle(value)}>{value[0]!.toUpperCase() + value.slice(1)}</button>)}</div>}
        {edit === "custom" && <label>Describe the change<textarea value={prompt} onChange={event => setPrompt(event.target.value)} maxLength={600} placeholder="Remove the moving boxes and preserve the room." /></label>}
      </fieldset>
      <fieldset disabled={!!disabled || !canCreate}><legend>2. Choose the photos to change</legend>
        {!eligible.length ? <p>Add photos to this property first. Edited photos need their untouched original before another edit.</p> : <div className="batch-photo-grid">{eligible.map((photo, index) => <label className="batch-photo-choice" key={photo.id}><input type="checkbox" checked={selected.includes(photo.id)} disabled={!selected.includes(photo.id) && choices.length >= MAX_BATCH_PHOTOS} onChange={event => setSelected(ids => event.target.checked ? [...ids, photo.id] : ids.filter(id => id !== photo.id))} /><img src={photo.url} alt="" loading="lazy" referrerPolicy="no-referrer" /><span>{photo.caption || `Photo ${index + 1}`}</span></label>)}</div>}
      </fieldset>
      <p>{choices.length} selected. This starts {choices.length} separate AI edit{choices.length === 1 ? "" : "s"}. Review and save the previews below before leaving this property.</p>
      <button className="creative-primary" disabled={!!disabled || !canCreate || !choices.length || !!allowance && choices.length > Math.max(0, allowance.cap - allowance.used) || edit === "custom" && !prompt.trim()} onClick={() => void start()}>Generate {choices.length || "selected"} photo previews</button>
    </> : <>
      <div className="creative-actions"><p role="status">{batch.entries.filter(e => e.state === "saved").length} saved · {batch.entries.filter(e => e.state === "ready").length} ready to review · {batch.entries.filter(e => e.state === "failed").length} failed · {batch.entries.filter(e => e.state === "stopped").length} not started</p>{busy ? <button disabled={batch.stopRequested} onClick={() => batch.stop()}>{batch.stopRequested ? "Stopping after this photo…" : "Stop remaining photos"}</button> : <button onClick={reset}>Choose another batch</button>}</div>
      {busy && <p>Keep this property open. Stopping leaves an edit already sent to AI running; no further photo will be sent.</p>}
      <div className="batch-photo-results">{batch.entries.map((entry, index) => <article className="batch-photo-result" key={entry.requestKey}><h3>{index + 1}. {entry.photo.caption || "Property photo"}</h3><p className="batch-photo-status">{({ queued: "Waiting", preparing: "Preparing the original…", generating: "Creating your preview…", ready: "Review your preview", saving: "Saving the photo and disclosure…", saved: "Saved to your property", failed: "This photo needs attention", stopped: "Not started" })[entry.state]}</p>{entry.error && <p role="alert">{entry.error}</p>}{entry.result && <><div className="creative-comparison"><figure><img src={entry.result.originalPreview} alt="Untouched original" /><figcaption>Original</figcaption></figure><figure><img src={entry.result.preview} alt="AI edited preview" /><figcaption>AI edited</figcaption></figure></div><p>{entry.result.disclosure}</p><div className="creative-actions"><a href={entry.result.preview} download={`rendprop-photo-${index + 1}.${entry.result.file.type === "image/jpeg" ? "jpg" : entry.result.file.type === "image/webp" ? "webp" : "png"}`}>Download preview</a>{entry.state !== "saved" && <button className="creative-primary" disabled={busy || !!disabled || !canCreate || !entry.result.provenanceId} onClick={() => void save(index)}>{entry.error && entry.result.provenanceId ? "Retry saving this preview" : "Save to property gallery"}</button>}</div></>}</article>)}</div>
    </>}
  </section>;
}
