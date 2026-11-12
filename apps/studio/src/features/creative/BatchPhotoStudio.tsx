import {PHOTO_OUTPUT_BASE64_CHARS} from "../../data/photo-output";
import { STAGING_STYLE_CHOICES, ACCEPTED_STAGING_STYLES } from "./staging-styles";
import { useEffect, useRef, useState } from "react";
import type { Listing, StudioPhoto, Workspace } from "../../data/contracts";
import { uuid, canEditListing } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { businessApi } from "../business/api";
import { uploadListingAsset } from "../listings/uploads";
import type { UploadedAsset, UploadJournal } from "../listings/uploads";
import { editedImage } from "./media";
import { inputForEdit, photoDelivery, propertyOriginalPhoto, type PhotoSource, type PhotoDelivery } from "./photo-lineage";
import PhotoExportPanel from "./PhotoExportPanel";
import CustomPhotoPromptHelp, { analyzeCustomPhotoPrompt } from "./CustomPhotoPromptHelp";
import { PRESETS, record, requiredText, text } from "./model";
import type { Edit } from "./model";
import {retainedPhotoRequest,resumePhotoRequest} from "./creative-request";
import {savedPhotoRequests,matchingPhotoRequest,finishPhotoRequest,type SavedPhotoRequest} from "./photo-request-journal";

export const MAX_BATCH_PHOTOS = 6;
export type BatchEdit = { edit: Edit; style: string; prompt: string };
export type BatchPhotoResult = PhotoDelivery & {
  file: File; preview: string; originalAssetId: string;
  provenanceId: string | null; disclosure: string;
};
export type BatchPhotoEntry = {
  photo: StudioPhoto; requestKey: string;
  state: "queued" | "preparing" | "generating" | "ready" | "saving" | "saved" | "failed" | "stopped";
  choice?:BatchEdit; error: string | null; result?: BatchPhotoResult; output?: UploadedAsset; journal?: UploadJournal; reviewed?: boolean;
};
type RecoveredPhoto={retained:true;raw:unknown;source:PhotoSource;originalId:string;key:string;choice:BatchEdit};
type BatchDependencies = {
  assertScope: () => void;
  prepare: (photo: StudioPhoto, signal: AbortSignal) => Promise<PhotoSource>;
  upload: (file: File, role: "original" | "gallery", signal: AbortSignal, resume?: UploadJournal, onJournal?: (journal: UploadJournal) => void) => Promise<UploadedAsset>;
  generate: (source: PhotoSource, originalId: string, choice: BatchEdit, key: string, caption: string, signal: AbortSignal, photoId:string) => Promise<unknown>;
  recover?: (photo:StudioPhoto,signal:AbortSignal)=>Promise<RecoveredPhoto|null>;
  recoverSource?: (source:PhotoSource,signal:AbortSignal)=>Promise<RecoveredPhoto|null>;
  finished?: (entry:BatchPhotoEntry)=>Promise<void>;
  attach: (entry: BatchPhotoEntry, signal: AbortSignal) => Promise<void>;
};
const describe = (value: unknown) => value instanceof Error ? value.message : "This photo could not be completed.";
export function batchEligible(photo: StudioPhoto, listingId: string) {
  return photo.listingId === listingId && (!(photo.isAltered || photo.isStaged) || !!photo.originalUrl);
}

/** Explicit new runs and durable same-operation recovery share this controller.
 * Unknown work retains its saved request; recovery never invents a paid key. */
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
    if (!PRESETS.some(p => p.id === choice.edit) || choice.edit === "custom" && (!choice.prompt.trim() || choice.prompt.trim().length > 600) || choice.edit === "stage" && !ACCEPTED_STAGING_STYLES.includes(choice.style)) throw new Error("Choose an edit and review its settings first.");
    if (choice.edit === "custom") {
      const decision = analyzeCustomPhotoPrompt(choice.prompt, "real_estate");
      if (decision.status !== "ready") throw new Error(decision.message);
    }
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
          entry.state="preparing";this.emit();
          let recovered=await this.deps.recover?.(entry.photo,this.abort.signal),source!:PhotoSource,originalId!:string,raw!:Record<string,unknown>,choice=this.choice;
          this.check();
          if(!recovered){
            source=await this.deps.prepare(entry.photo,this.abort.signal);this.check();
            if(this.stopped){entry.state="stopped";continue;}
            if(!source.originalVerified||!source.original)throw new Error("Review and confirm the paired unedited original before editing this photo.");
            recovered=await this.deps.recoverSource?.(source,this.abort.signal);this.check();
            if(!recovered){
              const original=await this.deps.upload(source.original.file,"original",this.abort.signal);this.check();
              if(this.stopped){entry.state="stopped";continue;}
              entry.state="generating";this.emit();
              const response=await this.deps.generate(inputForEdit(source,this.choice.edit),original.assetId,this.choice,entry.requestKey,entry.photo.caption||"Property photo",this.abort.signal,entry.photo.id);
              if(response&&typeof response==="object"&&(response as RecoveredPhoto).retained===true)recovered=response as RecoveredPhoto;
              else{raw=record(response);originalId=original.assetId;}
            }
          }
          if(recovered){source=recovered.source;originalId=recovered.originalId;entry.requestKey=recovered.key;choice=recovered.choice;raw=record(recovered.raw);}
          entry.choice={...choice};
          this.check();
          const base64 = requiredText(raw.image_b64, "an edited photo",PHOTO_OUTPUT_BASE64_CHARS), mime = text(raw.mime, 50) || "image/png";
          const file = editedImage(base64, mime);
          let provenanceId: string | null = null;
          try { const proof = raw.provenance ? record(raw.provenance) : {}; if (proof.recorded === true) provenanceId = uuid(proof.id, "photo disclosure"); }
          catch { /* Keep the paid preview available; an invalid proof cannot authorize gallery save. */ }
          const disclosure = requiredText(raw.disclosure, "the photo disclosure", 1000);
          entry.result = { ...photoDelivery(source, file, choice.edit, disclosure, provenanceId),
            preview: `data:${mime};base64,${base64}`, originalAssetId: originalId,
            disclosure: [...inputForEdit(source, choice.edit).disclosures, disclosure].join("\n") };
          entry.state = "ready";
          if (!entry.result.provenanceId) entry.error = "The preview is ready, but its disclosure could not be saved. Download it; it cannot join the gallery yet.";
        } catch (error) {
          if (this.abort.signal.aborted) throw error;
          this.check();
          const dispatched = entry.state === "generating";
          const code = (error as { code?: string })?.code ?? "";
          const refusal = ["photo_clarification_required", "unsupported_edit"].includes(code);
          const qualityWaiting = ["photo_quality_pending", "photo_quality_hold"].includes(code);
          const qualityClosed = code === "photo_quality_closed";
          entry.state = "failed";
          entry.error = `${describe(error)}${qualityClosed ? " This operation is closed and remains private. Start a new edit only when you choose; it may use another allowance." : qualityWaiting ? " This saved edit is retained. The remaining photos were stopped while its review is unresolved." : dispatched && !refusal ? " No automatic retry was made. A request with a lost response may still count against your allowance." : " No AI edit was started for this photo."}`;
          const status = (error as { status?: number })?.status;
          if (qualityWaiting || qualityClosed || refusal || [401, 402, 403, 429].includes(status ?? 0)) this.stopped = true;
        }
        this.emit();
      }
    } finally { this.running = false; this.emit(); }
  }
  async save(index: number) {
    const entry = this.entries[index];
    if (this.busy || !entry?.result?.provenanceId || entry.state !== "ready") return;
    if ((entry.choice??this.choice).edit === "custom" && !entry.reviewed) throw new Error("Compare this preview with its original and confirm the fixed features before saving it.");
    this.check(); this.saving = true; entry.state = "saving"; entry.error = null; this.emit();
    try {
      if (!entry.output) entry.output = await this.deps.upload(entry.result.file, "gallery", this.abort.signal, entry.journal, journal => { this.check(); entry.journal = journal; });
      this.check();
      await this.deps.attach(entry, this.abort.signal);
      this.check();await this.deps.finished?.(entry);this.check(); entry.state = "saved";
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
  const [confirmedOriginals, setConfirmedOriginals] = useState<string[]>([]);
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
    if (!alive.current || current.identityVersion !== version || current.status !== "signed-in" || current.identity?.userId !== workspace.user.id || current.identity.isAnonymous || !canEditListing(workspace, listing)) throw new Error("Your account or editing access changed. Reopen this property before editing.");
  }
  async function refreshAllowance(signal?: AbortSignal) {
    try {
      const account = await businessApi(services, workspace).account(signal);
      assertScope(); const trial = account.trialUsage;
      const meter = trial ? { ...trial.photoEdits, cap: trial.status === "active" ? trial.photoEdits.cap : 0 } : account.meters.find(m => m.key === "photo_edits");
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
  async function reset() {
    if (busy || unsaved && !window.confirm("Discard these unsaved previews? Download or save any photos you want to keep first.")) return;
    assertScope();const keys=new Set(batchRef.current?.entries.map(entry=>entry.requestKey));
    const rows=await savedPhotoRequests({actor:workspace.user.id,library:workspace.libraryOrgId??workspace.org.id,listing:listing.id});assertScope();
    for(const row of rows)if(row.state==="ready"&&keys.has(row.requestKey)){await finishPhotoRequest(row);assertScope();}
    batchRef.current?.dispose(); batchRef.current = null; setBatch(null); setError(null);
  }
  async function start(recovering?:SavedPhotoRequest[]) {
    if (batchRef.current || disabled || !canCreate) return;
    try {
      assertScope();
      const dispatch = (path: string, body: unknown, signal: AbortSignal, extra: Partial<Parameters<StudioServices["api"]>[1]> = {}) => services.api(`/functions/v1/${path}`, { orgId: workspace.org.id, signal, method: "POST", body, ...extra });
      const identity={actor:workspace.user.id,library:workspace.libraryOrgId??workspace.org.id,listing:listing.id};
      const recovered=(saved:{row:SavedPhotoRequest;result:unknown}):RecoveredPhoto=>({retained:true,raw:saved.result,source:saved.row.context.source,originalId:saved.row.context.originalAssetId,key:saved.row.requestKey,choice:{edit:saved.row.context.edit,style:saved.row.context.style,prompt:saved.row.context.prompt}});
      const assertDispatch=()=>{assertScope();if(batchRef.current?.stopRequested)throw new Error("This batch was stopped. Its saved operations are retained.");};
      const resume=async(row:SavedPhotoRequest,signal:AbortSignal)=>recovered(await resumePhotoRequest(services,identity,row,assertDispatch,signal));
      const selectedChoice=recovering?.[0]?.context;
      const selected=recovering?recovering.map(row=>({id:row.context.photoId!,listingId:listing.id,url:row.context.source.preview,expiresAt:"",caption:String(JSON.parse(row.requestJSON).label??"Saved photo"),isStaged:false,sort:0} satisfies StudioPhoto)):choices;
      const batchId=selectedChoice?.batchId??crypto.randomUUID();
      const next = new PhotoBatch(selected, listing.id, selectedChoice?{edit:selectedChoice.edit,style:selectedChoice.style,prompt:selectedChoice.prompt}:{ edit, style, prompt }, {
        assertScope,
        prepare: async (photo, signal) => {
          const source = await propertyOriginalPhoto(photo, signal);
          return { ...source, originalVerified: source.originalVerified || confirmedOriginals.includes(photo.id) };
        },
        upload: (file, role, signal, resume, onJournal) => uploadListingAsset(services, { orgId: workspace.org.id, listingId: listing.id, file, role, signal, resume, onJournal }),
        recover:async(photo,signal)=>{const rows=await savedPhotoRequests(identity);assertScope();const row=rows.find(r=>r.context.channel==="batch"&&r.context.photoId===photo.id);return row?await resume(row,signal):null;},
        recoverSource:async(source,signal)=>{const row=await matchingPhotoRequest(identity,source);assertScope();return row?await resume(row,signal):null;},
        generate:async(source,originalId,choice,_key,caption,signal,photoId)=>recovered(await retainedPhotoRequest(services,identity,{listing_id:listing.id,original_asset_id:originalId,image_b64:source.base64,mime:source.mime,edit:choice.edit,space_type:listing.spaceType,label:caption.slice(0,80),...(choice.edit==="stage"?{style:choice.style}:{}),...(choice.edit==="custom"?{prompt:choice.prompt}:{})},{channel:"batch",source,edit:choice.edit,style:choice.style,prompt:choice.prompt,originalAssetId:originalId,photoId,batchId},assertDispatch,signal)),
        finished:async(entry)=>{const rows=await savedPhotoRequests(identity);assertScope();const row=rows.find(r=>r.requestKey===entry.requestKey);if(row)await finishPhotoRequest(row);},
        attach: async (entry, signal) => {
          if ((entry.photo.caption?.length ?? 0) > 400) throw new Error("This edit history is too long for a gallery caption. Download its complete photo package instead.");
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
  useEffect(()=>{
    let cancelled=false;const identity={actor:workspace.user.id,library:workspace.libraryOrgId??workspace.org.id,listing:listing.id};
    void savedPhotoRequests(identity).then(rows=>{if(cancelled||!alive.current||batchRef.current)return;const first=rows.find(r=>r.context.channel==="batch");if(first)return start(rows.filter(r=>r.context.channel==="batch"&&r.context.batchId===first.context.batchId));}).catch(reason=>{if(!cancelled&&alive.current)setError(describe(reason));});
    return()=>{cancelled=true;};
  },[services,workspace.user.id,workspace.org.id,workspace.libraryOrgId,listing.id]);
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
        {edit === "stage" && <div className="creative-actions" aria-label="Staging style">{STAGING_STYLE_CHOICES.map(value => <button type="button" key={value} aria-pressed={style === value} onClick={() => setStyle(value)}>{value[0]!.toUpperCase() + value.slice(1)}</button>)}</div>}
        {edit === "custom" && <label>Describe the change<textarea value={prompt} onChange={event => setPrompt(event.target.value)} maxLength={600} placeholder="Remove the moving boxes and preserve the room." /></label>}
        {edit === "custom" && <CustomPhotoPromptHelp prompt={prompt} onPrompt={setPrompt} space={listing.spaceType} disabled={!!disabled || !canCreate} />}
      </fieldset>
      <fieldset disabled={!!disabled || !canCreate}><legend>2. Choose the photos to change</legend>
        {!eligible.length ? <p>Add photos to this property first. Edited photos need their untouched original before another edit.</p> : <div className="batch-photo-grid">{eligible.map((photo, index) => <label className="batch-photo-choice" key={photo.id}><input type="checkbox" checked={selected.includes(photo.id)} disabled={!selected.includes(photo.id) && choices.length >= MAX_BATCH_PHOTOS} onChange={event => setSelected(ids => event.target.checked ? [...ids, photo.id] : ids.filter(id => id !== photo.id))} /><img src={photo.url} alt="" loading="lazy" referrerPolicy="no-referrer" /><span>{photo.caption || `Photo ${index + 1}`}</span></label>)}</div>}
      </fieldset>
      {choices.filter(photo => (photo.isAltered || photo.isStaged) && !photo.originalVerified).map(photo => <details key={photo.id}><summary>Verify the original for {photo.caption || "this edited photo"}</summary><img src={photo.originalUrl!} alt="Paired source to verify" style={{ maxWidth: "100%", maxHeight: 240 }} /><p>A new edit uses this original; it does not edit the saved result.</p><label><input type="checkbox" checked={confirmedOriginals.includes(photo.id)} onChange={event => setConfirmedOriginals(ids => event.target.checked ? [...ids, photo.id] : ids.filter(id => id !== photo.id))} />This is the actual unedited original.</label></details>)}
      <p>{choices.length} selected. This starts {choices.length} separate AI edit{choices.length === 1 ? "" : "s"}. Review and save the previews below before leaving this property.</p>
      <button className="creative-primary" disabled={!!disabled || !canCreate || !choices.length || choices.some(photo => (photo.isAltered || photo.isStaged) && !photo.originalVerified && !confirmedOriginals.includes(photo.id)) || !!allowance && choices.length > Math.max(0, allowance.cap - allowance.used) || edit === "custom" && analyzeCustomPhotoPrompt(prompt, listing.spaceType).status !== "ready"} onClick={() => void start()}>Generate {choices.length || "selected"} photo previews</button>
    </> : <>
      <div className="creative-actions"><p role="status">{batch.entries.filter(e => e.state === "saved").length} saved · {batch.entries.filter(e => e.state === "ready").length} ready to review · {batch.entries.filter(e => e.state === "failed").length} failed · {batch.entries.filter(e => e.state === "stopped").length} not started</p>{busy ? <button disabled={batch.stopRequested} onClick={() => batch.stop()}>{batch.stopRequested ? "Stopping after this photo…" : "Stop remaining photos"}</button> : <button onClick={()=>void reset().catch(reason=>setError(describe(reason)))}>Choose another batch</button>}</div>
      {busy && <p>Keep this property open. Stopping leaves an edit already sent to AI running; no further photo will be sent.</p>}
      {batch.entries.some(entry => entry.result) && <PhotoExportPanel photos={batch.entries.flatMap(entry => entry.result && (batch.choice.edit !== "custom" || entry.reviewed) ? [entry.result] : [])} assertScope={assertScope} disabled={busy || !!disabled} />}
      <div className="batch-photo-results">{batch.entries.map((entry, index) => <article className="batch-photo-result" key={entry.requestKey}><h3>{index + 1}. {entry.photo.caption || "Property photo"}</h3><p className="batch-photo-status">{({ queued: "Waiting", preparing: "Preparing your photo and original…", generating: "Creating your preview…", ready: "Review your preview", saving: "Saving the photo and disclosure…", saved: "Version saved to property history", failed: "This photo needs attention", stopped: "Not started" })[entry.state]}</p>{entry.error && <p role="alert">{entry.error}</p>}{entry.result && <><div className="creative-comparison"><figure><img src={entry.result.originalPreview ?? undefined} alt="Untouched original" /><figcaption>Original</figcaption></figure><figure><img src={entry.result.preview} alt="AI edited preview" /><figcaption>AI edited</figcaption></figure></div><p>{entry.result.disclosure}</p>{(entry.choice??batch.choice).edit === "custom" && <label className="creative-review-confirmation"><input type="checkbox" checked={!!entry.reviewed} disabled={busy || !!disabled} onChange={event => { entry.reviewed = event.target.checked; redraw(value => value + 1); }} />I compared this preview with the original: paint and garage/trim finishes, fixed features, layout and property condition are unchanged.</label>}<div className="creative-actions"><PhotoExportPanel photos={[entry.result]} assertScope={assertScope} disabled={busy || !!disabled || (entry.choice??batch.choice).edit === "custom" && !entry.reviewed} />{entry.state !== "saved" && <button className="creative-primary" disabled={busy || !!disabled || !canCreate || !entry.result.provenanceId || (entry.choice??batch.choice).edit === "custom" && !entry.reviewed} onClick={() => void save(index)}>{entry.error && entry.result.provenanceId ? "Retry saving this preview" : "Save version"}</button>}</div></>}</article>)}</div>
    </>}
  </section>;
}
