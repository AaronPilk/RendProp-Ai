import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { Listing, ListingMedia, Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { cancelListingUpload, uploadListingAsset, validateUpload } from "./uploads";
import type { UploadJournal } from "./uploads";
import { canPublishAsset, decodeListingState, EMPTY_STATE, formatChapters, listingPayload, orderedGallery, parseChapterText, safeHTTPS, tourLinks } from "./model";
import type { ListingState, Published } from "./model";
import SpatialWorkflow from "./SpatialWorkflow";
import GalleryPhotoCard from "./GalleryPhotoCard";
import { downloadTourQR } from "./qr";
import "./listings.css";
import { FeatureCards } from "../home/Dashboard";
import { FEATURES, homeWords, type FeatureId } from "../home/features";
import FinishListing from "./FinishListing";
import ListingKit from "./ListingKit";
import { canEditListing, listingFinish } from "./readiness";
import type { ListingDestination } from "./readiness";

export type ListingEntryRequest = {id:string;listingId:string;tab:Tab};
type Props = { entryRequest?:ListingEntryRequest; createRequest?:string; onOpenFeature?:(feature:FeatureId,listingId:string)=>void; services: StudioServices; workspace: Workspace; listings: Listing[]; listingId?: string; onChanged: () => void; onSelectListing?: (id: string) => void };
type Tab = "media" | "tour" | "floorplan" | "details";
const terminal = new Set(["ready", "failed", "completed", "published", "cancelled"]);
const message = (error: unknown) => error instanceof Error ? error.message : "This action could not finish. Please try again.";
function readJournals(key: string): UploadJournal[] {
  try {
    const raw = localStorage.getItem(key);
    if (!raw || raw.length > 200_000) return [];
    const value = JSON.parse(raw);
    return Array.isArray(value) ? value.filter((v) => v?.version === 1 && typeof v.filename === "string" && typeof v.operationId === "string").slice(0, 200) : [];
  } catch { return []; }
}
function probeVideoMetadata(file: File, signal: AbortSignal): Promise<{ duration_s?: number; width?: number; height?: number }> {
  if (!file.type.startsWith("video/")) return Promise.resolve({});
  return new Promise((resolve) => {
    const video = document.createElement("video"), url = URL.createObjectURL(file);
    const finish = (result: { duration_s?: number; width?: number; height?: number }) => {
      clearTimeout(timeout); signal.removeEventListener("abort", abort); video.removeAttribute("src"); video.load(); URL.revokeObjectURL(url); resolve(result);
    };
    const abort = () => finish({});
    const timeout = setTimeout(() => finish({}), 15_000);
    signal.addEventListener("abort", abort, { once: true });
    video.onloadedmetadata = () => finish(Number.isFinite(video.duration) && video.duration > 0 ? { duration_s: video.duration, width: video.videoWidth, height: video.videoHeight } : {});
    video.onerror = () => finish({}); video.preload = "metadata"; video.src = url;
  });
}

export default function ListingWorkflow(props: Props) {
  const [selected, setSelected] = useState(props.listingId ?? props.listings[0]?.id ?? "");
  const [creating, setCreating] = useState(false);
  useEffect(() => { if (props.listingId) setSelected(props.listingId); }, [props.listingId]);
  const requests=useRef({create:"",entry:""});
  useEffect(()=>{
    if(props.createRequest&&requests.current.create!==props.createRequest){requests.current.create=props.createRequest;setCreating(true);}
    if(props.entryRequest&&requests.current.entry!==props.entryRequest.id){requests.current.entry=props.entryRequest.id;setCreating(false);setSelected(props.entryRequest.listingId);}
  },[props.createRequest,props.entryRequest]);
  const words=homeWords(props.workspace.org.spaceType);
  const listing = props.listings.find((item) => item.id === selected);
  const choose = (id: string) => { setCreating(false); setSelected(id); props.onSelectListing?.(id); };
  return <section className="listing-workflow" aria-label="Property workspace">
    <div className="lw-title"><div><p className="eyebrow">From your phone to your desk</p><h1>{words.collection}</h1><p>Every uploaded photo, walkthrough, and published tour belongs to the same workspace.</p></div><button className="primary" disabled={props.workspace.memberships.find((m) => m.orgId === props.workspace.org.id)?.role === "marketing"} onClick={() => setCreating(true)}>＋ New property</button></div>
    <div className="lw-property-switch"><label htmlFor="property-workspace-select">Working on</label><select id="property-workspace-select" value={listing?.id ?? ""} onChange={(event) => choose(event.target.value)}><option value="" disabled>Choose a property</option>{props.listings.map((item) => <option key={item.id} value={item.id}>{item.address || item.tagline || "Untitled property"}</option>)}</select><span className="lw-sync-dot">Same account as your iPhone</span></div>
    {creating ? <PropertyForm services={props.services} workspace={props.workspace} onSaved={(id) => { props.onChanged(); choose(id); }} onCancel={() => setCreating(false)} /> : listing ? <PropertyWorkspace key={`${props.workspace.user.id}:${props.workspace.org.id}:${listing.id}`} {...props} listing={listing} /> : <div className="lw-empty"><h2>Start with a property</h2><p>Create it here or in the Rendprop iPhone app. Sign in to the same Apple account on both devices to pick up where you left off.</p><button className="primary" onClick={() => setCreating(true)}>Create your first property</button></div>}
  </section>;
}

function PropertyForm({ services, workspace, listing, onSaved, onCancel }: { services: StudioServices; workspace: Workspace; listing?: Listing; onSaved: (id: string) => void; onCancel?: () => void }) {
  const readOnly = !canEditListing(workspace);
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  const [lookupBusy, setLookupBusy] = useState(false), [lookupMessage, setLookupMessage] = useState("");
  const [facts, setFacts] = useState<Record<string, unknown> | null>(null);
  const [dirty, setDirty] = useState(false), [remoteChanged, setRemoteChanged] = useState(false);
  const form = useRef<HTMLFormElement>(null);
  const values = { address: listing?.address ?? "", tagline: listing?.tagline ?? "", space_type: listing?.spaceType ?? workspace.org.spaceType, price: listing?.priceCents == null ? "" : listing.priceCents / 100, beds: listing?.beds ?? "", baths: listing?.baths ?? "", sqft: listing?.sqft ?? "" };
  const signature = JSON.stringify(values), previous = useRef(signature);
  const loadValues = () => { for (const [name, value] of Object.entries(values)) { const element = form.current?.elements.namedItem(name); if (element instanceof HTMLInputElement || element instanceof HTMLSelectElement) element.value = String(value); } };
  useEffect(() => {
    if (previous.current === signature) return;
    previous.current = signature;
    if (dirty) setRemoteChanged(true); else loadValues();
  }, [signature, dirty]);
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  const save = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); if (busy || readOnly || remoteChanged) return;
    const values = new FormData(event.currentTarget);
    controller.current?.abort(); const action = new AbortController(); controller.current = action;
    setBusy(true); setError("");
    try {
      const body = listingPayload(values, listing);
      const row = await services.api(`/functions/v1/listings${listing ? `/${listing.id}` : ""}`, { method: listing ? "PATCH" : "POST", orgId: workspace.org.id, body, signal: action.signal }) as { id?: string; org_id?: string };
      if (!action.signal.aborted) { if (!row.id || row.org_id !== workspace.org.id) throw new Error("The saved property could not be confirmed. Refresh your properties."); setDirty(false); onSaved(row.id); }
    } catch (reason) { if (!action.signal.aborted) setError(message(reason)); }
    finally { if (!action.signal.aborted) setBusy(false); }
  };
  const lookup = async () => {
    const address = String(new FormData(form.current!).get("address") ?? "").trim();
    if (address.length < 6 || address.length > 300) { setError("Enter a full street address to look up property records."); return; }
    controller.current?.abort(); const action = new AbortController(); controller.current = action;
    setLookupBusy(true); setError(""); setFacts(null); setLookupMessage("");
    try {
      const raw = await services.api(`/functions/v1/property?${new URLSearchParams({ address })}`, { orgId: workspace.org.id, signal: action.signal, timeoutMs: 120_000 }) as { configured?: boolean; facts?: Record<string, unknown> | null };
      if (action.signal.aborted) return;
      if (raw.configured !== true) setLookupMessage("Property records aren’t connected for this workspace. You can enter all details manually.");
      else if (!raw.facts) setLookupMessage("No matching public record was found. Add the details you know below.");
      else { setFacts(raw.facts); setLookupMessage("Review the matched address and facts before using them."); }
    } catch (reason) { if (!action.signal.aborted) setError(message(reason)); }
    finally { if (!action.signal.aborted) setLookupBusy(false); }
  };
  return <form ref={form} className="lw-card lw-property-form" onInput={() => setDirty(true)} onSubmit={save}><h2>{listing ? "Property details" : "A new property"}</h2><p>Save once. These details appear in the app and on your published tour.</p>{error && <p role="alert" className="lw-error">{error}</p>}{remoteChanged && <div role="alert" className="lw-notice">This property changed on another device while you were editing. Your field edits are still visible.<button type="button" onClick={() => { loadValues(); setDirty(false); setRemoteChanged(false); }}>Reload latest details and discard these field edits</button></div>}<fieldset className="lw-form-grid" disabled={readOnly}>
    <label className="lw-span-2">Address or property name<input autoFocus={!listing} required name="address" maxLength={500} defaultValue={listing?.address ?? ""} placeholder="123 Oak Street, Austin, TX" /></label>
    <div className="lw-span-2"><button type="button" disabled={busy || lookupBusy} onClick={() => void lookup()}>{lookupBusy ? "Finding public records…" : "Look up property facts"}</button>{lookupMessage && <p role="status">{lookupMessage}</p>}{facts && <div className="lw-facts"><strong>Matched address: {typeof facts.matchedAddress === "string" ? facts.matchedAddress : "Not provided — verify before using"}</strong><p>{[["beds", "beds"], ["baths", "baths"], ["sqft", "sq ft"], ["yearBuilt", "year built"]].filter(([key]) => typeof facts[key] === "number" && Number.isFinite(facts[key])).map(([key, title]) => `${Number(facts[key]).toLocaleString()} ${title}`).join(" · ")}</p>{typeof facts.lastSalePriceCents === "number" && <p>Last recorded sale: ${(facts.lastSalePriceCents / 100).toLocaleString()}. Your asking price stays separate.</p>}<button type="button" onClick={() => { for (const key of ["beds", "baths", "sqft"]) { const value = facts[key]; const field = form.current?.elements.namedItem(key); if (typeof value === "number" && Number.isFinite(value) && value >= 0 && field instanceof HTMLInputElement) field.value = String(key === "baths" ? value : Math.round(value)); } setDirty(true); setLookupMessage("Facts added to this form. Check them, then save the property."); }}>Use these facts</button></div>}</div>
    <label className="lw-span-2">Headline<input name="tagline" maxLength={500} defaultValue={listing?.tagline ?? ""} placeholder="Light-filled living, inside and out" /></label>
    <label>Property type<select name="space_type" defaultValue={listing?.spaceType ?? workspace.org.spaceType}>{[["real_estate", "Real estate"], ["venue", "Venue"], ["restaurant", "Restaurant"], ["retail", "Retail"], ["fitness", "Fitness"], ["other", "Other"]].map(([value, title]) => <option value={value} key={value}>{title}</option>)}</select></label>
    <label>Asking price ($)<input name="price" type="number" min="0" step="0.01" defaultValue={listing?.priceCents == null ? "" : listing.priceCents / 100} /></label><label>Bedrooms<input name="beds" type="number" min="0" step="1" defaultValue={listing?.beds ?? ""} /></label><label>Bathrooms<input name="baths" type="number" min="0" max="99" step="0.5" defaultValue={listing?.baths ?? ""} /></label><label>Square feet<input name="sqft" type="number" min="0" step="1" defaultValue={listing?.sqft ?? ""} /></label>
  </fieldset><div className="lw-actions"><button className="primary" type="submit" disabled={busy || lookupBusy || readOnly || remoteChanged}>{busy ? "Saving…" : listing ? "Save property" : "Create property"}</button>{onCancel && <button type="button" onClick={onCancel} disabled={busy}>Cancel</button>}</div></form>;
}

function PropertyWorkspace({ services, workspace, listing, onChanged, entryRequest, onOpenFeature }: Props & { listing: Listing }) {
  const [tab, setTab] = useState<Tab>("media"), [state, setState] = useState<ListingState>(EMPTY_STATE);
  const appliedEntry=useRef("");
  useEffect(()=>{if(entryRequest?.listingId===listing.id&&appliedEntry.current!==entryRequest.id){appliedEntry.current=entryRequest.id;setTab(entryRequest.tab);}},[entryRequest,listing.id]);
  const [media, setMedia] = useState<ListingMedia | null>(null), [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);
  const [error, setError] = useState(""), [notice, setNotice] = useState(""), [busy, setBusy] = useState("");
  const [progress, setProgress] = useState(0), [uploadingName, setUploadingName] = useState("");
  const [assetId, setAssetId] = useState(""), [tier, setTier] = useState("smooth"), [duration, setDuration] = useState("");
  const [posterAssetId, setPosterAssetId] = useState("");
  const [chapters, setChapters] = useState(""), [editTour, setEditTour] = useState<Published | null>(null);
  const [deleteText, setDeleteText] = useState(""), [showDelete, setShowDelete] = useState(false), [soldBusy, setSoldBusy] = useState(false);
  const alive = useRef(true), action = useRef<AbortController | null>(null), load = useRef<AbortController | null>(null);
  const journalKey = `rendprop-studio-uploads:${workspace.user.id}:${workspace.org.id}:${listing.id}`;
  const [journals, setJournals] = useState<UploadJournal[]>(() => readJournals(journalKey));
  const journalsRef = useRef(journals);
  const input = useRef<HTMLInputElement>(null), masterInput = useRef<HTMLInputElement>(null), floorInput = useRef<HTMLInputElement>(null), resumeInput = useRef<HTMLInputElement>(null);
  const resumeJournal = useRef<UploadJournal | undefined>(undefined);
  const canWrite = canEditListing(workspace);
  const refresh = useCallback(async (showLoading = false) => {
    load.current?.abort(); const current = new AbortController(); load.current = current;
    if (showLoading) setLoading(true);
    try {
      const statePromise = (async () => {
        let all: ListingState = { ...EMPTY_STATE, assets: [], jobs: [], renders: [], chapters: [] }, offset = 0;
        do {
          const query = new URLSearchParams({ org_id: workspace.org.id, listing_id: listing.id, offset: String(offset) });
          const page = decodeListingState(await services.api(`/functions/v1/studio/listing-state?${query}`, { orgId: workspace.org.id, signal: current.signal }), workspace.org.id, listing.id, offset);
          all = { assets: [...all.assets, ...page.assets], jobs: [...all.jobs, ...page.jobs], renders: [...all.renders, ...page.renders], photos: [...all.photos, ...page.photos], chapters: [...all.chapters, ...page.chapters], nextOffset: page.nextOffset };
          offset = page.nextOffset ?? 0;
          if (all.assets.length + all.jobs.length + all.renders.length + all.photos.length > 10_000) throw new Error("This property has too much activity to open at once. Contact support.");
        } while (all.nextOffset !== null);
        all.chapters = [...new Map(all.chapters.map(chapter => [`${chapter.asset_id}:${chapter.t_ms}:${chapter.sort}`, chapter])).values()];
        return all;
      })();
      const mediaPromise = (async () => {
        let page = await services.listMedia(workspace.org.id, listing.id, current.signal);
        const all = { ...page, photos: [...page.photos], videos: [...page.videos] };
        while (page.nextOffset !== null) {
          if (all.photos.length + all.videos.length > 5000) throw new Error("This property has too much media to open at once.");
          page = await services.listMedia(workspace.org.id, listing.id, current.signal, page.nextOffset);
          all.photos.push(...page.photos); all.videos.push(...page.videos); all.unavailableCount += page.unavailableCount;
        }
        all.nextOffset = null; return all;
      })();
      const [activity, previews] = await Promise.all([statePromise, mediaPromise]);
      if (!current.signal.aborted && alive.current) { setState(activity); setMedia(previews); setError(""); setLoadFailed(false); }
    } catch (reason) { if (!current.signal.aborted && alive.current) { setError(message(reason)); setLoadFailed(true); } }
    finally { if (!current.signal.aborted && alive.current) setLoading(false); }
  }, [services, workspace.org.id, listing.id]);
  useEffect(() => {
    alive.current = true; void refresh(true);
    const focus = () => { if (document.visibilityState === "visible") void refresh(); };
    window.addEventListener("focus", focus); document.addEventListener("visibilitychange", focus);
    const timer = setInterval(focus, 30_000);
    return () => { alive.current = false; action.current?.abort(); load.current?.abort(); clearInterval(timer); window.removeEventListener("focus", focus); document.removeEventListener("visibilitychange", focus); };
  }, [refresh]);
  const persist = (next: UploadJournal[]) => {
    // Metadata only: no file bytes, signed capabilities, or tokens enter the recovery journal.
    localStorage.setItem(journalKey, JSON.stringify(next)); journalsRef.current = next; setJournals(next);
  };
  const saveJournal = (journal: UploadJournal) => persist([...journalsRef.current.filter((j) => j.operationId !== journal.operationId), journal]);
  const run = async (name: string, work: (signal: AbortSignal) => Promise<void>) => {
    if (!canWrite) { setError("Your workspace role can view media. An owner, admin or agent can make changes."); return; }
    if (action.current) return;
    const controller = new AbortController(); action.current = controller; setBusy(name); setError(""); setNotice("");
    try { await work(controller.signal); }
    catch (reason) { if (alive.current && !controller.signal.aborted) setError(message(reason)); }
    finally { if (action.current === controller) action.current = null; if (alive.current) { setBusy(""); setUploadingName(""); } }
  };
  const upload = async (files: File[], purpose: "media" | "master" | "floorplan", resume?: UploadJournal) => run("upload", async (signal) => {
    if (files.length > 200) throw new Error("Import up to 200 files at a time.");
    for (const file of files) {
      if (signal.aborted) break;
      const meta = validateUpload(file);
      const role = resume?.role ?? (purpose === "master" ? "render" : purpose === "floorplan" ? "gallery" : meta.kind === "photo" && file.size <= 10 * 1024 ** 2 && !/hei[cf]/.test(meta.contentType) ? "gallery" : "capture");
      if (purpose === "master" && meta.kind !== "video") throw new Error("Choose an exported MP4, MOV, or M4V tour.");
      if (purpose === "floorplan" && meta.kind !== "photo") throw new Error("Choose a JPG, PNG, or WebP floor plan.");
      setUploadingName(file.name); setProgress(0);
      const metadata = await probeVideoMetadata(file, signal);
      let operationId = resume?.operationId;
      const result = await uploadListingAsset(services, { orgId: workspace.org.id, listingId: listing.id, file, role, signal, metadata, resume, onJournal: (journal) => { operationId = journal.operationId; saveJournal({ ...journal, purpose }); }, onProgress: (n, total) => setProgress(total ? n / total : 0) });
      if (signal.aborted) return;
      if (purpose === "floorplan") await services.api("/functions/v1/studio/floorplan", { method: "POST", orgId: workspace.org.id, body: { listing_id: listing.id, asset_id: result.assetId }, signal });
      else if (result.kind === "photo" && role === "gallery") await services.api("/functions/v1/studio/photos", { method: "POST", orgId: workspace.org.id, body: { listing_id: listing.id, asset_id: result.assetId, caption: file.name.replace(/\.[^.]+$/, "") }, signal });
      if (signal.aborted) return;
      persist(journalsRef.current.filter((j) => j.operationId !== operationId));
      if (purpose === "master") { setAssetId(result.assetId); setDuration(String(metadata.duration_s ?? "")); setChapters(""); setPosterAssetId(""); setTab("tour"); }
    }
    if (!signal.aborted) { setNotice(purpose === "floorplan" ? "Floor plan saved to this property." : "Your media is uploaded and available in the workspace."); onChanged(); await refresh(); }
  });
  const photos = media?.photos ?? [], videos = media?.videos ?? [];
  const gallery = orderedGallery(state.photos);
  const galleryKey = (photo: typeof gallery[number]) => photo.enhanced_key || photo.original_key;
  const galleryPreviews = new Map(gallery.map(photo => {
    const key = galleryKey(photo);
    const aliases = new Set([...state.photos.filter(other => galleryKey(other) === key).map(other => other.id), ...state.assets.filter(asset => asset.storage_key === key).map(asset => asset.id)]);
    return [photo.id, photos.find(preview => preview.id === photo.id) ?? photos.find(preview => aliases.has(preview.id))];
  }));
  const galleryPreviewIds = new Set([...galleryPreviews.values()].map(photo => photo?.id));
  const sourcePhotos = photos.filter(photo => !galleryPreviewIds.has(photo.id));
  const videoAssets = state.assets.filter((asset) => asset.uploaded && asset.kind === "video");
  const chosenAsset = videoAssets.find((asset) => asset.id === assetId);
  const published = state.renders.filter((render) => render.published_at);
  const activeJobs = state.jobs.filter((job) => !terminal.has(job.status));
  const floorplanPhoto = photos.find((photo) => photo.id === listing.details.floorplan_asset_id);
  const floorplanURL = floorplanPhoto?.url ?? safeHTTPS(listing.details.floorplan_url);
  const api = (path: string, body: unknown, signal: AbortSignal, method: "POST" | "PATCH" | "DELETE" = "POST", idempotencyKey?: string) => services.api(`/functions/v1/${path}`, { method, orgId: workspace.org.id, body, signal, idempotencyKey, timeoutMs: 120_000 });
  const changeGallery = async (body: Record<string, unknown>, success: string): Promise<boolean> => {
    let saved = false;
    await run("gallery", async signal => {
      await api("studio/photos", { listing_id: listing.id, ...body }, signal, "PATCH");
      if (!signal.aborted) { saved = true; onChanged(); await refresh(); if (!signal.aborted) setNotice(success); }
    });
    return saved;
  };
  const movePhoto = (photoId: string, direction: -1 | 1) => {
    const order = gallery.map(photo => photo.id), index = order.indexOf(photoId), target = index + direction;
    if (index < 0 || target < 0 || target >= order.length) return;
    const next = [...order]; [next[index], next[target]] = [next[target], next[index]];
    void changeGallery({ action: "reorder", expected_order: order, photo_ids: next }, "Gallery order saved for every device and the property tour.");
  };
  const finish = listingFinish({ listing, state, media, loading, loadFailed, pendingUploads: journals.length, canWrite, hasCreativeTools: Boolean(onOpenFeature) });
  const navigateFinish = (destination: ListingDestination) => {
    if ("refresh" in destination) { void refresh(true); return; }
    if ("feature" in destination) { if (canWrite) onOpenFeature?.(destination.feature, listing.id); return; }
    setTab(destination.tab);
    requestAnimationFrame(() => document.getElementById(`lw-tab-${destination.tab}`)?.focus());
  };
  return <div className="lw-property">
    <header className="lw-property-heading"><div><h2>{listing.address || "Untitled property"}</h2><p>{listing.tagline || "Everything you need to bring this property to market."}</p></div><button onClick={() => { onChanged(); void refresh(true); }} disabled={loading}>↻ {loading ? "Refreshing…" : "Refresh"}</button></header>
    <FinishListing finish={finish} canWrite={canWrite} busy={!!busy} onNavigate={navigateFinish} onPhotos={onOpenFeature ? () => onOpenFeature("studio", listing.id) : undefined} />
    <ListingKit services={services} workspace={workspace} listingId={listing.id} />
    {onOpenFeature && <fieldset className="lw-creation-tools" disabled={!canWrite}><section className="app-property-tools" aria-label="Create with this home"><h2>Make something with this {homeWords(workspace.org.spaceType).noun}</h2><FeatureCards features={FEATURES.filter(f=>["studio","reel","tour","aerial"].includes(f.id))} onOpen={id=>onOpenFeature(id,listing.id)}/></section></fieldset>}
    <div className="lw-tabs" role="tablist" aria-label="Property tasks">{([["media", "1", "Media"], ["tour", "2", "Create & publish"], ["floorplan", "3", "Floor plan & 3D"], ["details", "", "Details"]] as const).map(([value, number, title]) => <button key={value} role="tab" aria-selected={tab === value} aria-controls={`lw-${value}`} id={`lw-tab-${value}`} onClick={() => setTab(value)}><span>{number}</span>{title}</button>)}</div>
    {error && <div role="alert" className="lw-error">{error}<button onClick={() => void refresh()}>Refresh property</button></div>}{notice && <p role="status" className="lw-notice">✓ {notice}</p>}
    {!canWrite && <p className="lw-notice">Your workspace role lets you view media. An owner, admin, or agent can make changes.</p>}
    {busy === "upload" && <div className="lw-upload-progress" role="status"><div><strong>{uploadingName ? `Uploading ${uploadingName}` : "Checking your files…"}</strong><span>{Math.round(progress * 100)}%</span></div><progress max={1} value={progress} /><button onClick={() => { action.current?.abort(); setNotice("Upload paused. Select the original file below to resume."); }}>Pause upload</button></div>}
    {journals.length > 0 && <details className="lw-card lw-recovery" open><summary>{journals.length} upload{journals.length === 1 ? "" : "s"} to finish</summary><p>Select the original file to continue. Confirmed parts are kept, so an interrupted upload can resume safely.</p>{journals.map((journal) => <div className="lw-recovery-row" key={journal.operationId}><span>{journal.filename}</span><button disabled={!!busy} onClick={() => { resumeJournal.current = journal; resumeInput.current?.click(); }}>Resume</button><button disabled={!!busy} onClick={() => void run("cancel", async (signal) => { await cancelListingUpload(services, journal, signal); if (!signal.aborted) persist(journalsRef.current.filter((j) => j.operationId !== journal.operationId)); })}>Cancel upload</button></div>)}</details>}
    <input ref={input} type="file" accept=".jpg,.jpeg,.png,.webp,.heic,.heif,.mp4,.mov,.m4v" multiple hidden onChange={(e) => { const files = [...e.target.files ?? []]; e.target.value = ""; void upload(files, "media"); }} />
    <input ref={masterInput} type="file" accept=".mp4,.mov,.m4v" hidden onChange={(e) => { const files = [...e.target.files ?? []]; e.target.value = ""; void upload(files, "master"); }} />
    <input ref={floorInput} type="file" accept=".jpg,.jpeg,.png,.webp" hidden onChange={(e) => { const files = [...e.target.files ?? []]; e.target.value = ""; void upload(files, "floorplan"); }} />
    <input ref={resumeInput} type="file" hidden onChange={(e) => { const files = [...e.target.files ?? []]; e.target.value = ""; const journal = resumeJournal.current; if (journal) void upload(files, journal.purpose ?? (journal.role === "render" ? "master" : "media"), journal); }} />
    <section id={`lw-${tab}`} role="tabpanel" aria-labelledby={`lw-tab-${tab}`}>
      {tab === "media" && <><div className="lw-next-step"><div><h3>Bring the property into focus</h3><p>Import from your computer, or finish an upload on your phone. This page refreshes when you return.</p></div><button className="primary" disabled={!!busy || !canWrite} onClick={() => input.current?.click()}>Import photos & video</button></div><div className="lw-stat-strip"><span><strong>{photos.length}</strong> Photos</span><span><strong>{videos.length}</strong> Videos</span><span><strong>{published.length}</strong> Live tours</span></div>
        {loading && !media ? <p role="status">Loading property media…</p> : photos.length + videos.length + gallery.length === 0 ? <div className="lw-empty"><h3>Your next walkthrough starts here</h3><p>Open Rendprop on your iPhone, choose <strong>{listing.address || "this property"}</strong>, and capture a walkthrough or photos. Complete the upload, then continue here.</p><button disabled={!!busy || !canWrite} onClick={() => input.current?.click()}>Choose files from this computer</button></div> : <div className="lw-media-grid">{gallery.map((photo, index) => <GalleryPhotoCard key={photo.id} photo={photo} preview={galleryPreviews.get(photo.id)} index={index} count={gallery.length} busy={!!busy} canWrite={canWrite} isCover={gallery.some(item => item.is_main) ? photo.is_main : galleryKey(photo) === listing.mainPhotoKey} onSaveCaption={(caption, expected) => changeGallery({ action: "caption", photo_id: photo.id, caption, expected_caption: expected }, "Photo caption saved for every device.")} onCover={() => void changeGallery({ action: "cover", photo_id: photo.id, expected_main_photo_key: listing.mainPhotoKey }, "Cover photo saved for every device.")} onMove={direction => movePhoto(photo.id, direction)} />)}{sourcePhotos.map((photo) => <article className="lw-media-card" key={`p-${photo.id}`}><img src={photo.url} alt={photo.caption || "Property photo"} loading="lazy" referrerPolicy="no-referrer" /><div><strong>{photo.caption || "Property photo"}</strong><span>Source photo</span>{(photo.isStaged || photo.isAltered) && <span className="lw-disclosure">AI altered · original retained</span>}<a href={photo.url} target="_blank" rel="noreferrer">Open photo ↗</a>{state.assets.some(asset => asset.id === photo.id && asset.bucket === "renders" && asset.uploaded) && <button disabled={!!busy || !canWrite} onClick={() => void run("gallery", async signal => { await api("studio/photos", { listing_id: listing.id, asset_id: photo.id, caption: photo.caption ?? "" }, signal); if (!signal.aborted) { onChanged(); await refresh(); setNotice("Photo added to the tour gallery."); } })}>Add to tour gallery</button>}</div></article>)}{videos.map((video) => <article className="lw-media-card" key={`v-${video.id}`}><video src={video.url} controls preload="metadata" playsInline /><div><strong>Property video</strong><span>{video.durationSeconds ? `${Math.round(video.durationSeconds)} seconds` : "Uploaded walkthrough"}</span><a href={video.url} target="_blank" rel="noreferrer">Open video ↗</a>{videoAssets.some((asset) => asset.id === video.id) && <button onClick={() => { setAssetId(video.id); setDuration(String(video.durationSeconds ?? "")); setChapters(formatChapters(state.chapters.filter(c => c.asset_id === video.id))); setPosterAssetId(""); setEditTour(null); setTab("tour"); }}>Create a tour</button>}</div></article>)}</div>}{!!media?.unavailableCount && <p className="lw-muted">{media.unavailableCount} older media item(s) need a fresh upload from the original device.</p>}
        <p className="lw-help">Gallery captions, cover selection, and photo order are saved to this property. Original captures remain available as source photos. {gallery.length > 500 && "This gallery exceeds 500 photos; contact support to reorder it."}</p><p className="lw-help">Videos up to 2 GB. Photos up to 50 MB; JPG, PNG, and WebP images up to 10 MB also join the published gallery. HEIC stays available as an original download.</p>
      </>}
      {tab === "tour" && <><div className="lw-two-column"><div className="lw-card"><p className="eyebrow">Make it shareable</p><h3>Create your property tour</h3><p>Choose a walkthrough to process, or upload an edited tour to publish with no render charge.</p><label>Source video<select aria-label="Source video" value={assetId} onChange={(e) => { setAssetId(e.target.value); const asset = videoAssets.find((a) => a.id === e.target.value); setDuration(String(asset?.duration_s ?? "")); setChapters(formatChapters(state.chapters.filter(c => c.asset_id === asset?.id))); setPosterAssetId(""); setEditTour(null); }}><option value="">Choose an uploaded video</option>{videoAssets.map((asset, index) => <option key={asset.id} value={asset.id} disabled={!canPublishAsset(asset)}>{asset.bucket === "renders" ? "Edited tour" : "Walkthrough"}{!canPublishAsset(asset) ? " · accuracy review needed" : ""} {index + 1} · {new Date(asset.created_at).toLocaleDateString()}{asset.duration_s ? ` · ${Math.round(asset.duration_s)}s` : ""}</option>)}</select></label><button disabled={!!busy || !canWrite} onClick={() => masterInput.current?.click()}>Upload an edited tour</button>
          {chosenAsset && <>
            {!canPublishAsset(chosenAsset) && <p className="lw-error">{chosenAsset.qc_message || "Review this generated video’s property accuracy in AI tools before publishing it."}</p>}
            {chosenAsset.bucket === "uploads" ? <>
              <label>Render quality<select value={tier} onChange={(e) => setTier(e.target.value)}><option value="smooth">Smooth HD</option><option value="premium4k">4K Premium</option><option value="cinematic">Cinematic AI</option></select></label>
              <p className="lw-help">Room tags recorded on your phone stay with this walkthrough. You can edit chapters on the finished tour below.</p>
              {!!state.chapters.filter(c => c.asset_id === chosenAsset.id).length && <p className="lw-help">Saved rooms: {state.chapters.filter(c => c.asset_id === chosenAsset.id).sort((a, b) => a.t_ms - b.t_ms).map(c => c.label).join(" · ")}</p>}
              <p className="lw-help">Processing uses your workspace’s render allowance and publishes the finished tour and listing details automatically.</p>
            </> : <>
              <label>Video duration (seconds)<input type="number" min="0.1" max="7200" step="0.1" value={duration} onChange={(e) => setDuration(e.target.value)} /></label>
              <label>Tour cover photo<select aria-label="Tour cover photo" value={posterAssetId} onChange={(e) => setPosterAssetId(e.target.value)}><option value="">Use the video’s first frame</option>{state.assets.filter((a) => a.uploaded && a.kind === "photo" && a.bucket === "renders" && a.id !== listing.details.floorplan_asset_id).map((a, index) => <option key={a.id} value={a.id}>Property photo {index + 1}</option>)}</select></label>
              <label>Room chapters (optional)<textarea aria-label="Room chapters (optional)" rows={5} value={chapters} onChange={(e) => setChapters(e.target.value)} placeholder={"0:00 Entry\n0:12 Living room\n0:32 Kitchen"} /></label>
              <p className="lw-help">Use time + room name, one per line. Publishing makes this tour and its listing details public.</p>
            </>}
            <button className="primary" disabled={!!busy || !canWrite || !canPublishAsset(chosenAsset)} onClick={() => void run("render", async (signal) => {
              if (!canPublishAsset(chosenAsset)) throw new Error("Complete this video’s property accuracy review in AI tools before publishing.");
              if (chosenAsset.bucket === "renders") {
                const seconds = Number(duration); if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 7200) throw new Error("Enter the video’s duration in seconds before publishing.");
                await api("renders/publish-app", { listing_id: listing.id, asset_id: chosenAsset.id, duration_s: seconds, speed_factor: 1, tier: "smooth", enhancements: { declutter: false, style: "as_is" }, chapters: parseChapterText(chapters, seconds), ...(posterAssetId ? { poster_asset_id: posterAssetId } : {}) }, signal, "POST", `publish:${listing.id}:${chosenAsset.id}`);
              } else await api("renders", { listing_id: listing.id, asset_id: chosenAsset.id, tier, enhancements: { declutter: false, style: "as_is" } }, signal, "POST", `studio-render:${listing.id}:${chosenAsset.id}:${tier}`);
              if (!signal.aborted) { setNotice(chosenAsset.bucket === "renders" ? "Your tour is live. Share its branded or MLS link below." : "Rendering started. The finished tour will publish automatically; you can check progress on either device."); onChanged(); await refresh(); }
            })}>{busy === "render" ? "Working…" : chosenAsset.bucket === "renders" ? "Publish tour" : "Render & publish tour"}</button>
          </>}

        </div><aside className="lw-card lw-guide"><h3>A smooth phone-to-office workflow</h3><ol><li><strong>Capture on site.</strong> Film your walkthrough and room tags in the iPhone app.</li><li><strong>Complete the upload.</strong> Original videos and photos appear in this property’s media.</li><li><strong>Finish at your desk.</strong> Edit your video, refine photos, and review the property details.</li><li><strong>Publish and share.</strong> Use the branded link for marketing and the unbranded link for the MLS.</li></ol></aside></div>
        {state.jobs.length > 0 && <div className="lw-card"><h3>Renders across your devices</h3>{state.jobs.map((job) => <div className="lw-job" key={job.id}><div><strong>{job.tier === "premium4k" ? "4K Premium" : job.tier === "cinematic" ? "Cinematic AI" : "Smooth tour"}</strong><span>{job.current_step?.replaceAll("_", " ") || job.status.replaceAll("_", " ")}</span></div>{!terminal.has(job.status) && <progress max={1} value={Math.max(0, Math.min(1, job.progress > 1 ? job.progress / 100 : job.progress))} />}{job.error && <p className="lw-error">{job.error}</p>}{job.status === "ready" && !state.renders.some((render) => render.job_id === job.id && render.published_at) && <button disabled={!!busy || !canWrite || state.assets.some(a => a.id === job.capture_asset_id && !canPublishAsset(a))} onClick={() => void run("publish", async (signal) => { await api(`renders/${job.id}/publish`, { chapters: state.chapters.filter(c => c.asset_id === job.capture_asset_id).sort((a, b) => a.t_ms - b.t_ms).map((c, sort) => ({ label: c.label, t_ms: c.t_ms, sort })), speed_factor: 1 }, signal); if (!signal.aborted) { setNotice("Your tour is live."); onChanged(); await refresh(); } })}>Publish finished tour</button>}</div>)}{activeJobs.length > 0 && <p className="lw-help">Progress refreshes automatically. Rendering continues after you close Studio.</p>}</div>}
        <div className="lw-card"><h3>Published tours</h3>{published.length === 0 ? <p>Your branded and MLS links will appear here when you publish.</p> : published.map((tour) => { const links = tourLinks(tour.slug); return links ? <div className="lw-published" key={tour.id}><div><strong>Live tour · {new Date(tour.published_at!).toLocaleDateString()}</strong>{tour.staged && <span>Altered media disclosure included</span>}</div><div className="lw-share-links"><a href={links.branded} target="_blank" rel="noreferrer">Open branded tour ↗</a><button onClick={() => void navigator.clipboard.writeText(links.branded).then(() => setNotice("Branded tour link copied."), () => setError("Copy was unavailable. Open the tour and copy the address from your browser."))}>Copy marketing link</button><a href={links.unbranded} target="_blank" rel="noreferrer">Open MLS tour ↗</a><button onClick={() => void navigator.clipboard.writeText(links.unbranded).then(() => setNotice("Unbranded MLS link copied."), () => setError("Copy was unavailable. Open the tour and copy its address."))}>Copy MLS link</button></div><button onClick={() => void downloadTourQR(tour.slug).then(() => setNotice("Marketing QR code downloaded."), (reason) => setError(message(reason)))}>Download marketing QR</button><button onClick={() => void downloadTourQR(tour.slug, "unbranded").then(() => setNotice("Unbranded MLS QR code downloaded."), (reason) => setError(message(reason)))}>Download MLS QR</button><button disabled={!canWrite} onClick={() => { const job = state.jobs.find((j) => j.id === tour.job_id); setEditTour(tour); setChapters(formatChapters(state.chapters.filter((c) => c.asset_id === job?.capture_asset_id))); }}>Edit room chapters</button></div> : null; })}</div>
        {editTour && <form className="lw-card" onSubmit={(e) => { e.preventDefault(); void run("chapters", async (signal) => { await api(`renders/${editTour.id}/chapters`, { chapters: parseChapterText(chapters, editTour.duration_s) }, signal, "PATCH"); if (!signal.aborted) { setEditTour(null); setNotice("Room chapters updated on the live tour."); await refresh(); } }); }}><h3>Edit live room chapters</h3><label>Time and room name<textarea aria-label="Time and room name" value={chapters} rows={7} onChange={(e) => setChapters(e.target.value)} /></label><div className="lw-actions"><button className="primary" disabled={!!busy}>Save chapters</button><button type="button" onClick={() => setEditTour(null)}>Cancel</button></div></form>}
      </>}
      {tab === "floorplan" && <><div className="lw-two-column"><div className="lw-card"><h3>Floor plan</h3><p>Add a plan to the property so it is available with the tour. Export PDFs as a JPG or PNG first.</p>{floorplanURL ? <><a href={floorplanURL} target="_blank" rel="noreferrer"><img className="lw-floorplan" src={floorplanURL} alt="Property floor plan" /></a><a href={floorplanURL} target="_blank" rel="noreferrer">Open full floor plan ↗</a></> : <div className="lw-empty"><span className="lw-plan-icon">⌑</span><p>No floor plan attached yet.</p></div>}<button className="primary" disabled={!!busy || !canWrite} onClick={() => floorInput.current?.click()}>{floorplanURL ? "Replace floor plan" : "Upload floor plan"}</button></div><aside className="lw-card lw-guide"><h3>Capture a measured plan on iPhone</h3><p>Open this property in Rendprop, then choose <strong>Make a floor plan</strong>. On a supported iPhone, RoomPlan scans rooms and creates the 2D plan and 3D model.</p><p>Keep the original scan on your phone. Export its plan image and upload it here to attach it to the property’s tour.</p><a href="https://apps.apple.com/us/app/id6808982413" target="_blank" rel="noreferrer">Get Rendprop for iPhone ↗</a></aside></div><SpatialWorkflow services={services} workspace={workspace} listing={listing} canWrite={canWrite} /></>}
      {tab === "details" && <><PropertyForm key={listing.id} services={services} workspace={workspace} listing={listing} onSaved={() => { setNotice("Property details saved for every device."); onChanged(); }} /><div className="lw-card"><h3>Property status</h3><p>{listing.soldAt ? `Sold on ${new Date(listing.soldAt).toLocaleDateString()}. Clear the sold status if the property returns to market.` : "Keep your portfolio current without losing the property’s media."}</p><div className="lw-actions"><button disabled={!!busy || !canWrite} onClick={() => void run("archive", async (signal) => { await api(`listings/${listing.id}`, { status: listing.status === "archived" ? "ready" : "archived" }, signal, "PATCH"); if (!signal.aborted) { onChanged(); setNotice(listing.status === "archived" ? "Property restored." : "Property archived. Its existing public tour remains available until you remove the property."); } })}>{listing.status === "archived" ? "Restore property" : "Archive property"}</button><button disabled={!!busy || !canWrite || soldBusy} onClick={() => void run("sold", async (signal) => { setSoldBusy(true); try { await api(`listings/${listing.id}`, { sold_at: listing.soldAt ? null : new Date().toISOString() }, signal, "PATCH"); if (!signal.aborted) { onChanged(); setNotice(listing.soldAt ? "Sold status cleared. The property is back on the market." : "Property marked sold."); } } finally { if (alive.current) setSoldBusy(false); } })}>{listing.soldAt ? "Clear sold status" : "Mark sold"}</button><button className="lw-danger" disabled={!canWrite} onClick={() => setShowDelete(!showDelete)}>Remove property…</button></div>{showDelete && <form onSubmit={(e) => { e.preventDefault(); void run("delete", async (signal) => { if (deleteText !== (listing.address || "REMOVE")) throw new Error("Type the property name exactly to confirm removal."); await api(`listings/${listing.id}`, undefined, signal, "DELETE"); if (!signal.aborted) onChanged(); }); }}><p>Removing this property takes its hosted tours offline. Type <strong>{listing.address || "REMOVE"}</strong> to confirm.</p><label>Confirm property name<input value={deleteText} onChange={(e) => setDeleteText(e.target.value)} /></label><button className="lw-danger" disabled={!!busy || deleteText !== (listing.address || "REMOVE")}>Remove property and unpublish tours</button></form>}</div></>}
    </section>
  </div>;
}
