import { useCallback, useEffect, useRef, useState } from "react";
import VideoEditor from "../../editor/VideoEditor";
import type { VideoEditorProps, EditorSettings } from "../../editor/VideoEditor";
import { EDIT_LIMITS, draftMedia, validateDraft, validateFileBatch, type EditDraft } from "../../editor/model";
import type { LocalExport } from "../../editor/export";
import { canonicalDocument, DocumentSync, type SyncState } from "../../data/documents";
import type { StudioServices, Workspace, Listing } from "../../data";
import { fingerprintFile, uploadListingAsset, type UploadJournal } from "../listings/uploads";
import { scopeKey } from "../../workspace";
import SyncStatus from "./SyncStatus";
import {resolvePhotoAliases, type ReadableMedia} from "./media-aliases";
import { decodeResult, type ShotPlanHandoff, type AgentPlanHandoff } from "../creative/model";
import {decodeNativeReel, nativeReelShots, nativeCaptionStyle, type NativeReel} from "./native-reel";
import { mapShotMotion, reviewShotPlan } from "./shot-plan";
import ReelMediaPicker from "./ReelMediaPicker";
import "./reel.css";
import { earlierReels, propertyReelKey, reelPayload, type EarlierReel, type ReelPayload } from "./property-reels";
import {downloadNarration} from "./narration";
import CapturePlan from "../production/CapturePlan";
import ReviewPanel from "../production/ReviewPanel";
import VersionHistory from "../production/VersionHistory";
import type {VersionChoice} from "../production/versions";
import type {ProductionPlan} from "../production/model";

type Source = { sha256: string; assetId: string; listingId: string };
export function activeSourceRefs(draft: EditDraft | undefined, sources: Source[], listingId: string): Source[] {
  if (!draft) return [];
  return [...new Set(draftMedia(draft).map(c => c.source.sha256))].flatMap(sha256 => {
    const source = sources.find(s => s.sha256 === sha256 && s.listingId === listingId) ?? sources.find(s => s.sha256 === sha256);
    return source ? [{ ...source }] : [];
  });
}
export async function downloadSource(url: string, source: EditDraft["clips"][number]["source"], signal: AbortSignal): Promise<File> {
  const response = await fetch(url, { signal, credentials: "omit", redirect: "error", referrerPolicy: "no-referrer" });
  if (!response.ok || !response.body || Number(response.headers.get("content-length")) > EDIT_LIMITS.fileBytes) {
    void response.body?.cancel().catch(() => {});
    throw new Error("A saved source could not be restored. Refresh its listing and try again.");
  }
  const reader = response.body.getReader(), chunks: Uint8Array<ArrayBuffer>[] = []; let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > EDIT_LIMITS.fileBytes || size > source.size) throw new Error("The saved source does not match this edit. Reselect its original file.");
      chunks.push(new Uint8Array(value));
    }
  } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
  if (size !== source.size) throw new Error("A saved source was incomplete. Retry restoring the original file.");
  // The editor independently checks the entire SHA-256 and dimensions before relinking.
  return new File(chunks, source.name, { type: response.headers.get("content-type")?.split(";")[0] ?? "", lastModified: source.lastModified });
}
export type CloudEditorProps = VideoEditorProps & { services: StudioServices; workspace: Workspace; listings: Listing[]; listingId?: string; importPlan?: ShotPlanHandoff & {id: string}; importAgentPlan?: AgentPlanHandoff & {id: string}; entryRequest?: {id: string; listingId: string}; onOpenCreative?: (listingId: string, tool: "voiceover" | "shot-plans") => void; onChanged: () => void; onPrepareSwitch?: (prepare: (() => Promise<void>) | null) => void; onCopyVersion?:(choice:VersionChoice)=>void };
export default function CloudEditor(props: CloudEditorProps) {
  const { services, workspace, listings } = props;
  const [ready, setReady] = useState(false), [initial, setInitial] = useState<EditDraft>(), [state, setState] = useState<SyncState>("loading");
  const [productionPlan,setProductionPlan]=useState<ProductionPlan>(),[recipeRequest,setRecipeRequest]=useState<VideoEditorProps["recipeRequest"]>(),[savedRevision,setSavedRevision]=useState(0),[seekRequest,setSeekRequest]=useState<VideoEditorProps["seekRequest"]>();
  const [earlier, setEarlier] = useState<EarlierReel[]>([]);
  const recoveryChoice = useRef<((payload: ReelPayload | null) => void) | null>(null);
  const editorBlock = useRef<string | null>(null);
  const preparePlan=useRef<(()=>Promise<void>)|null>(null);
  const registerPlanGuard=useCallback((prepare:(()=>Promise<void>)|null)=>{preparePlan.current=prepare;},[]);
  const observeEditorBlock = useCallback((reason: string | null) => {editorBlock.current = reason;}, []);
  const listingId = props.listingId ?? "";
  const [message, setMessage] = useState("");
  const [sourceBusy, setSourceBusy] = useState(false), [relink, setRelink] = useState<VideoEditorProps["relinkRequest"]>();
  const [acceptedImport, setAcceptedImport] = useState<VideoEditorProps["importRequest"]>();
  const [nativeRecipe, setNativeRecipe] = useState<{listingId: string; recipe: NativeReel} | null>(null);
  const [settingsRequest, setSettingsRequest] = useState<VideoEditorProps["settingsRequest"]>();
  const [agentRequest, setAgentRequest] = useState<VideoEditorProps["agentRequest"]>();
  const [planRequest, setPlanRequest] = useState<VideoEditorProps["planRequest"]>();
  const [pickerListingId, setPickerListingId] = useState<string | null>(null);
  const [mediaCount, setMediaCount] = useState({clips: 0, bytes: 0});
  const consumedEntries = useRef(new Set<string>()), editorAnchor = useRef<HTMLDivElement>(null);
  const consumedImports = useRef(new Set<string>()), ignoredPlans = useRef(new Set<string>());
  const importSources = useRef(new Map<File, {assetId: string; listingId: string}>());
  const applyingPlan = useRef<{listingId: string; ids: string[]; requestId: string} | null>(null);
  const [planVersion, setPlanVersion] = useState(0);
  const [narrationChoices, setNarrationChoices] = useState<NonNullable<VideoEditorProps["narrationChoices"]>>([]);
  const [recovery, setRecovery] = useState(false), [outputBusy, setOutputBusy] = useState(false);
  const session = useRef<DocumentSync | null>(null), controller = useRef(new AbortController());
  const currentDraft = useRef<EditDraft | undefined>(undefined), sources = useRef<Source[]>([]), files = useRef<{ file: File; sha256: string }[]>([]);
  const selected = useRef(listingId); selected.current = listingId;
  const uploadFlight = useRef(false), restoring = useRef(false), outputFlight = useRef(false);
  const journals = useRef(new Map<string, UploadJournal>());
  const documentKey = propertyReelKey(props.listingId ?? "");
  const legacyKey = `${scopeKey(workspace.user.id, workspace.org.id)}:edit`;
  const localKey = `${scopeKey(workspace.user.id, workspace.org.id)}:${documentKey}`;
  const queue = useCallback(() => {
    if (!currentDraft.current) return;
    const payload = { draft: currentDraft.current, listingId: selected.current || null, sources: activeSourceRefs(currentDraft.current, sources.current, selected.current) };
    try { localStorage.setItem(`${localKey}:cloud-backup`, JSON.stringify(payload)); }
    catch { setMessage("Browser backup is unavailable. Keep this tab open until cloud saving finishes."); }
    session.current?.queue(payload);
  }, [localKey]);
  const pendingFiles = useCallback((target: string) => {
    const hashes = new Set(currentDraft.current ? draftMedia(currentDraft.current).map(c => c.source.sha256) : []);
    return files.current.filter(source => hashes.has(source.sha256) && !sources.current.some(s => s.sha256 === source.sha256 && s.listingId === target));
  }, []);
  useEffect(() => {
    props.onPrepareSwitch?.(async () => {
      if (controller.current.signal.aborted) throw new Error("This reel session has closed.");
      if (editorBlock.current) throw new Error(editorBlock.current);
      await preparePlan.current?.();
      // No editor is mounted yet, so leaving a pending read/recovery choice
      // simply cancels it. Nothing has been edited or reassigned.
      if (!ready && !currentDraft.current && !sourceBusy && !outputBusy) return;
      if (!ready || sourceBusy || outputBusy || uploadFlight.current || restoring.current || outputFlight.current || pendingFiles(selected.current).length)
        throw new Error("Finish opening or saving this reel's files before switching properties. Your work is kept here.");
      await session.current?.flush();
      if (!session.current || session.current.hasUnsavedWork || session.current.state !== "saved")
        throw new Error("Finish syncing this reel before switching properties. Retry sync or resolve the newer saved version first.");
    });
    return () => props.onPrepareSwitch?.(null);
  }, [props.onPrepareSwitch, ready, sourceBusy, outputBusy, pendingFiles]);
  useEffect(() => {
    const sync = new DocumentSync(services, workspace.org.id, documentKey, value=>{setState(value);if(value==="saved")setSavedRevision(sync.confirmedRevision);}); session.current = sync;
    const abort = new AbortController(); controller.current = abort;
    const unload = (event: BeforeUnloadEvent) => {
      if (sync.hasUnsavedWork || uploadFlight.current || outputFlight.current || pendingFiles(selected.current).length) { event.preventDefault(); event.returnValue = ""; }
    };
    const focus = () => { if (document.visibilityState === "visible") void sync.checkRemote(); };
    window.addEventListener("beforeunload", unload); window.addEventListener("focus", focus); document.addEventListener("visibilitychange", focus);
    void sync.open().then(async doc => {
      if (abort.signal.aborted) return;
      let draft: EditDraft | undefined;
      if (doc) {
        if (doc.listing_id !== selected.current) throw new Error("This saved reel belongs to another property.");
        const saved = reelPayload(doc.payload, selected.current);
        draft = saved.draft; sources.current = saved.sources;
        try {
          const local = localStorage.getItem(localKey);
          if (local && canonicalDocument(validateDraft(JSON.parse(local))) !== canonicalDocument(draft)) { localStorage.setItem(`${localKey}:recovery`, local); setRecovery(true); }
        } catch { setMessage("Browser backup storage is unavailable. Cloud work is still available."); }
      } else {
        let saved: ReelPayload | null = null;
        try {
          const backup = localStorage.getItem(`${localKey}:cloud-backup`), local = localStorage.getItem(localKey);
          if (backup) saved = reelPayload(JSON.parse(backup), selected.current);
          else if (local) saved = reelPayload({draft: JSON.parse(local), listingId: selected.current, sources: []}, selected.current);
        } catch { throw new Error("This property's browser backup needs recovery. Its saved copy is kept intact; do not start a replacement in this browser."); }
        if (!saved) {
          const legacy = await services.api("/functions/v1/studio/documents?key=edit", {orgId: workspace.org.id, signal: abort.signal}) as {document: import("../../data/documents").CloudDocument | null};
          if (abort.signal.aborted) return;
          const available = earlierReels(localStorage, legacyKey, selected.current, legacy.document);
          if (available.unreadable) setMessage("An earlier backup could not be used here. Its original copy is preserved.");
          if (available.copies.length) {
            saved = await new Promise<ReelPayload | null>(resolve => {recoveryChoice.current = resolve; setEarlier(available.copies);});
            recoveryChoice.current = null;
            if (abort.signal.aborted) return;
            setEarlier([]);
          }
        }
        if (saved) {draft = saved.draft; sources.current = saved.sources;}
      }
      currentDraft.current = draft; setInitial(draft);
      if (draft && sources.current.length) {
        restoring.current = true; setSourceBusy(true); setMessage("Restoring saved source files…");
        const restored: File[] = []; let restoreIssue = "";
        try {
          for (const target of new Set(sources.current.map(s => s.listingId))) {
            let offset: number | null = 0;
            const available = new Map<string, ReadableMedia>();
            const required = sources.current.filter(s => s.listingId === target && draftMedia(draft!).some(c => c.source.sha256 === s.sha256));
            while (offset !== null && required.length) {
              const media = await services.listMedia(workspace.org.id, target, abort.signal, offset);
              for (const item of [...media.photos, ...media.videos]) {
                available.set(item.id, item);
                const index = required.findIndex(s => s.assetId === item.id); if (index < 0) continue;
                const source = required.splice(index, 1)[0], clip = draftMedia(draft).find(c => c.source.sha256 === source.sha256); if (!clip) continue;
                try { restored.push(await downloadSource(item.url, clip.source, AbortSignal.any([abort.signal, AbortSignal.timeout(120000)]))); }
                catch (error) { if (abort.signal.aborted) throw error; restoreIssue = "Some saved sources need another download. Reselect the original files shown in the editor."; }
              }
              offset = media.nextOffset;
              if (offset !== null && offset > 10000) throw new Error("Source media exceeded the property paging limit.");
            }
            if (required.length) {
              await resolvePhotoAliases(services, workspace.org.id, target, available, required.map(source=>source.assetId), abort.signal);
              for (const source of [...required]) {
                const item=available.get(source.assetId),clip=draftMedia(draft).find(clip=>clip.source.sha256===source.sha256);if(!item||!clip)continue;
                try {restored.push(await downloadSource(item.url,clip.source,AbortSignal.any([abort.signal,AbortSignal.timeout(120000)])));required.splice(required.indexOf(source),1);}
                catch(error){if(abort.signal.aborted)throw error;restoreIssue="Some saved sources need another download. Reselect the original files shown in the editor.";}
              }
            }
            if (required.length) restoreIssue = "Some original files are unavailable. Reselect those files to finish restoring this edit.";
          }
        } catch (error) { if (!abort.signal.aborted) restoreIssue = error instanceof Error ? error.message : "Saved sources could not be downloaded."; }
        if (!abort.signal.aborted) {
          setRelink({ id: crypto.randomUUID(), files: restored }); setSourceBusy(false);
          setMessage(restoreIssue || "Source files downloaded. Verifying originals before relinking…");
        }
        restoring.current = false;
      }
      if (!abort.signal.aborted) setReady(true);
    }).catch(error => { if (!abort.signal.aborted) { setMessage(error instanceof Error ? error.message : "Saved work could not be restored."); setSourceBusy(false); } });
    return () => { abort.abort(); recoveryChoice.current?.(null); sync.dispose(); window.removeEventListener("beforeunload", unload); window.removeEventListener("focus", focus); document.removeEventListener("visibilitychange", focus); };
  }, [services, workspace.user.id, workspace.org.id, localKey, legacyKey, documentKey, pendingFiles]);
  useEffect(() => {
    if (!listingId || props.active === false) return;
    const abort = new AbortController();
    const refresh = async () => {
      try {
        const choices: NonNullable<VideoEditorProps["narrationChoices"]> = []; let offset: number | null = 0;
        do {
          const raw = await services.api(`/functions/v1/studio/creative-results?listing_id=${listingId}&offset=${offset}`, {orgId: workspace.org.id, signal: abort.signal}) as {results: unknown[]; next_offset: number | null};
          if (!Array.isArray(raw.results)) throw new Error("Saved narration is unavailable. Refresh AI tools and return here.");
          for (const value of raw.results) { const result = decodeResult(value); if (result.kind === "voice" && result.state === "completed") choices.push({id: result.id, label: result.label || result.voiceName || "Saved narration", words: result.words.filter(word => word.start <= 180).slice(0, 600)}); }
          if (raw.next_offset !== null && raw.next_offset !== offset + 100 || choices.length > 1000) throw new Error("Saved narration history is too large to load.");
          offset = raw.next_offset;
        } while (offset !== null);
        if (!abort.signal.aborted) setNarrationChoices(choices);
      } catch (error) { if (!abort.signal.aborted) { setNarrationChoices([]); setMessage(error instanceof Error ? error.message : "Saved narration is unavailable."); } }
    };
    void refresh(); const focus = () => { if (document.visibilityState === "visible") void refresh(); }; window.addEventListener("focus", focus);
    return () => { abort.abort(); window.removeEventListener("focus", focus); };
  }, [services, workspace.org.id, listingId, props.active]);
  const resolveNarration = useCallback(async (id: string, signal: AbortSignal): Promise<Blob> => {
    const raw = await services.api("/functions/v1/studio/sign-media", {method: "POST", orgId: workspace.org.id, body: {result_id: id}, signal}) as {result: unknown};
    return downloadNarration(raw.result,id,signal);
  }, [services, workspace.org.id]);
  const readJournal = (key: string): UploadJournal | undefined => {
    const inMemory = journals.current.get(key); if (inMemory) return inMemory;
    try { const saved = localStorage.getItem(key); return saved ? JSON.parse(saved) : undefined; } catch { return undefined; }
  };
  const recordJournal = (key: string, journal: UploadJournal) => {
    journals.current.set(key, journal);
    try { localStorage.setItem(key, JSON.stringify(journal)); }
    catch { setMessage("Upload recovery is kept in this tab. Keep it open until saving finishes."); }
  };
  const syncSources = useCallback(async () => {
    if (uploadFlight.current || restoring.current || !selected.current || !currentDraft.current || !session.current || session.current.state === "loading") return;
    const target = selected.current;
    if (!pendingFiles(target).length) return;
    uploadFlight.current = true; setSourceBusy(true);
    const signal = controller.current.signal; let finished = false;
    try {
      for (const source of pendingFiles(target)) {
        const journalKey = `${localKey}:source:${target}:${source.sha256}`;
        const resume = readJournal(journalKey);
        setMessage(`Saving ${source.file.name} to your property…`);
        const uploaded = await uploadListingAsset(services, { orgId: workspace.org.id, listingId: target, file: source.file, role: "capture", signal, resume, onJournal: journal => recordJournal(journalKey, journal) });
        if (signal.aborted) return;
        sources.current = [...sources.current.filter(s => !(s.sha256 === source.sha256 && s.listingId === target)), { sha256: source.sha256, assetId: uploaded.assetId, listingId: target }];
        // Keep the complete reservation's metadata: replaying after a lost document save never re-uploads the same source.
        queue();
      }
      finished = true; setMessage("Original files are saved with your property.");
    } catch (error) { if (!signal.aborted) setMessage(error instanceof Error ? error.message : "Source upload paused. Retry to resume."); }
    finally {
      uploadFlight.current = false;
      if (!signal.aborted) { setSourceBusy(false); if (finished && pendingFiles(selected.current).length) queueMicrotask(() => void syncSources()); }
    }
  }, [services, workspace.org.id, localKey, queue, pendingFiles]);
  const sourcesChanged = useCallback((next: { file: File; sha256: string }[]) => {
    files.current = next;
    for (const item of next) {
      const known = importSources.current.get(item.file); if (!known) continue;
      sources.current = [...sources.current.filter(source => !(source.sha256 === item.sha256 && source.listingId === known.listingId)), {sha256: item.sha256, ...known}];
      importSources.current.delete(item.file);
    }
    if (next.length) {
      if (currentDraft.current && draftMedia(currentDraft.current).every(item => next.some(source => source.sha256 === item.source.sha256)) && !pendingFiles(selected.current).length) setMessage("Original files are ready. Continue editing where you left off.");
      queue(); void syncSources();
    }
  }, [syncSources, queue, pendingFiles]);
  async function acceptMedia(request: NonNullable<VideoEditorProps["importRequest"]>) {
    const target = request.listingId || selected.current;
    if (!target) { setMessage("Choose the property for these files before importing."); return false; }
    if (target !== props.listingId) {setMessage("Open that property's reel before adding its files. This reel stays with its property."); return false;}
    setSourceBusy(true);
    try {
      validateFileBatch(request.files, currentDraft.current?.clips ?? []);
      if (request.sourceMedia) {
        if (request.sourceMedia.length !== request.files.length) throw new Error("The selected media changed. Choose it from the library again.");
        const needed = new Set(request.sourceMedia.map(item => item.id)); let offset: number | null = 0;
        do {
          const result = await services.api(`/functions/v1/studio/listing-state?listing_id=${target}&offset=${offset}`, {orgId: workspace.org.id, signal: controller.current.signal}) as {listing_id: string; org_id: string; assets: {id: string}[]; photos: {id: string}[]; next_offset: number | null};
          if (result.org_id !== workspace.org.id || result.listing_id !== target) throw new Error("The selected media belongs to another property.");
          for (const item of [...result.assets, ...result.photos]) needed.delete(item.id);
          if (result.next_offset !== null && (result.next_offset !== offset + 100 || result.next_offset > 10000)) throw new Error("The property media list could not be completed.");
          offset = result.next_offset;
        } while (offset !== null && needed.size);
        if (needed.size) throw new Error("Some selected media is no longer available in this property. Refresh the library and choose it again.");
        request.files.forEach((file, index) => importSources.current.set(file, {assetId: request.sourceMedia![index].id, listingId: target}));
      }
      if (controller.current.signal.aborted) return false;
      setAcceptedImport(request); queue();
      return true;
    } catch (error) { if (!controller.current.signal.aborted) setMessage(error instanceof Error ? error.message : "The media could not be imported."); }
    finally { if (!controller.current.signal.aborted) setSourceBusy(false); }
    return false;
  }
  useEffect(() => {
    const request = props.importRequest; if (!ready || !request || consumedImports.current.has(request.id)) return;
    consumedImports.current.add(request.id);
    void acceptMedia(request);
  }, [props.importRequest, ready]);
  useEffect(() => {
    const request = props.entryRequest;
    if (!ready || props.active === false || sourceBusy || outputBusy || !request || consumedEntries.current.has(request.id)) return;
    consumedEntries.current.add(request.id);
    if (request.listingId !== listingId || !listings.some(listing => listing.id === request.listingId && listing.orgId === workspace.org.id)) { setMessage("Open that property's reel before choosing its files."); return; }
    // Opening a native-style feature card only opens this picker. It must not
    // reassign, reset or queue the currently saved workspace edit.
    setPickerListingId(request.listingId);
  }, [props.entryRequest, props.active, ready, sourceBusy, outputBusy, listings, workspace.org.id]);
  function openPicker() {
    const target = selected.current || props.listingId || listings[0]?.id;
    if (target) setPickerListingId(target);
    else setMessage("Add a property first, then upload photos from your iPhone or computer.");
  }
  async function acceptPickerMedia(request: NonNullable<VideoEditorProps["importRequest"]>) {
    if (controller.current.signal.aborted || session.current?.state === "conflict" || uploadFlight.current || restoring.current || outputFlight.current) throw new Error("Finish the current save or resolve its conflict, then add these files again.");
    validateFileBatch(request.files, currentDraft.current?.clips ?? []);
    if (request.listingId !== selected.current) throw new Error("Open that property's reel before choosing its files.");
    if (await acceptMedia(request)) setPickerListingId(null);
  }
  async function loadPhoneRecipe() {
    if (!selected.current || sourceBusy || outputBusy) return;
    setSourceBusy(true);
    try {
      const target = selected.current, raw = await services.api(`/functions/v1/studio/documents?key=native:${target}`, {orgId: workspace.org.id, signal: controller.current.signal}) as {document: {payload: unknown; listing_id: string} | null};
      if (!raw.document) throw new Error("No iPhone reel setup is saved for this property. Open Reel Studio on your iPhone and choose Save setup, then return here.");
      if (raw.document.listing_id !== target) throw new Error("The phone setup belongs to a different property.");
      const recipe = decodeNativeReel(raw.document.payload);
      if (!controller.current.signal.aborted) {setNativeRecipe({listingId: target, recipe});setMessage("");}
    } catch (error) {if (!controller.current.signal.aborted) setMessage(error instanceof Error ? error.message : "The phone setup could not be opened.");}
    finally {if (!controller.current.signal.aborted) setSourceBusy(false);}
  }
  async function applyPhoneRecipe(restorePhotos: boolean) {
    const saved = nativeRecipe; if (!saved || sourceBusy || outputBusy) return;
    setSourceBusy(true);
    try {
      const {recipe} = saved;
      let narration: EditDraft["narration"];
      if (recipe.voiceMode !== "off" && recipe.voiceResultId) {
        const result = decodeResult((await services.api("/functions/v1/studio/sign-media", {method: "POST", orgId: workspace.org.id, body: {result_id: recipe.voiceResultId}, signal: controller.current.signal}) as {result: unknown}).result);
        if (result.id !== recipe.voiceResultId || result.kind !== "voice" || result.state !== "completed") throw new Error("The phone setup’s saved narration is unavailable. Choose a completed voice result first.");
        await resolveNarration(result.id, controller.current.signal);
        narration = {resultId: result.id, label: result.label || result.voiceName || "Phone narration", offset: 0, volume: 1, wordCaptions: recipe.wordCaptions && result.words.length > 0, words: result.words.filter(word => word.start <= 180).slice(0, 600)};
      }
      const settings: EditorSettings = {ratio: recipe.portrait ? "9:16" : "16:9", title: recipe.titleCard ? (listings.find(listing => listing.id === saved.listingId)?.address ?? "") : "", captionStyle: nativeCaptionStyle(recipe.captionStyle), transition: recipe.transition, clearCaptions: !recipe.shotCaptions || recipe.captionStyle === "off", narration};
      if (controller.current.signal.aborted) return;
      setSourceBusy(false);
      if (restorePhotos) {
        const shots = nativeReelShots(recipe);
        await applyShotPlan({id: crypto.randomUUID(), listingId: saved.listingId, shots, script: recipe.script, narrationResultId: narration?.resultId ?? null}, settings);
      } else setSettingsRequest({...settings, id: crypto.randomUUID()});
      setNativeRecipe(null);
    } catch (error) {if (!controller.current.signal.aborted) {setMessage(error instanceof Error ? error.message : "The phone setup could not be applied.");setSourceBusy(false);}}
  }
  async function applyShotPlan(override?: ShotPlanHandoff & {id:string}, settings?: EditorSettings) {
    const request = override ?? props.importPlan; if (!request || sourceBusy || outputBusy) return;
    if (request.listingId !== props.listingId) {setMessage("Open that property's reel before applying its plan."); return;}
    setSourceBusy(true); setMessage("Restoring the shot plan’s original photos…");
    try {
      const shots = reviewShotPlan(request, !!settings), available = new Map<string, ReadableMedia>(); let offset: number | null = 0;
      do {
        const page = await services.listMedia(workspace.org.id, request.listingId, controller.current.signal, offset);
        page.photos.forEach(photo => available.set(photo.id, photo));
        offset = page.nextOffset; if (offset !== null && offset > 10000) throw new Error("The property has too much media to restore at once.");
      } while (offset !== null && shots.some(shot => !available.has(shot.photoId)));
      await resolvePhotoAliases(services,workspace.org.id,request.listingId,available,shots.map(shot=>shot.photoId),controller.current.signal);
      if (shots.some(shot => !available.has(shot.photoId))) throw new Error("A photo in this shot plan is missing. Refresh AI tools and replace the missing photo before applying the plan. Your current edit is unchanged.");
      const restored: File[] = []; let total = 0;
      for (const [index, shot] of shots.entries()) {
        const response = await fetch(available.get(shot.photoId)!.url, {signal: controller.current.signal, credentials: "omit", redirect: "error", referrerPolicy: "no-referrer"});
        if (!response.ok || !response.body || Number(response.headers.get("content-length")) > EDIT_LIMITS.fileBytes) { void response.body?.cancel().catch(() => {}); throw new Error("A shot plan photo could not be restored."); }
        const reader = response.body.getReader(), chunks: Uint8Array<ArrayBuffer>[] = []; let size = 0;
        try { for (;;) { const {done, value} = await reader.read(); if (done) break; size += value.byteLength; total += value.byteLength; if (size > EDIT_LIMITS.fileBytes || total > EDIT_LIMITS.totalBytes) throw new Error("This shot plan exceeds the browser’s media limit."); chunks.push(new Uint8Array(value)); } }
        finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
        const type = response.headers.get("content-type")?.split(";")[0] || "image/jpeg";
        restored.push(new File(chunks, `shot-${index + 1}.${type === "image/png" ? "png" : type === "image/webp" ? "webp" : "jpg"}`, {type}));
      }
      let narration: EditDraft["narration"];
      if (request.narrationResultId) {
        const result = decodeResult((await services.api("/functions/v1/studio/sign-media", {method: "POST", orgId: workspace.org.id, body: {result_id: request.narrationResultId}, signal: controller.current.signal}) as {result: unknown}).result);
        if (result.id !== request.narrationResultId || result.kind !== "voice" || result.state !== "completed") throw new Error("The saved narration is unavailable. Choose another voice result in AI tools.");
        narration = {resultId: result.id, label: result.label || result.voiceName || "Saved narration", offset: 0, volume: 1, wordCaptions: result.words.length > 0, words: result.words.filter(word => word.start <= 180).slice(0, 600)};
        await resolveNarration(result.id, controller.current.signal);
      }
      if (controller.current.signal.aborted) return;
      applyingPlan.current = {listingId: request.listingId, ids: shots.map(shot => shot.photoId), requestId: request.id};
      setPlanRequest({id: crypto.randomUUID(), files: restored, clips: shots.map(shot => ({seconds: shot.seconds, caption: shot.caption, motion: mapShotMotion(shot.motion)})), narration: settings ? settings.narration : narration, settings});
    } catch (error) { if (!controller.current.signal.aborted) { setMessage(error instanceof Error ? error.message : "The shot plan could not be restored."); setSourceBusy(false); } }
  }
  async function applyAgentPlan() {
    const request = props.importAgentPlan; if (!request || sourceBusy || outputBusy) return;
    if (request.listingId !== props.listingId) {setMessage("Open that property's reel before applying its plan."); return;}
    setSourceBusy(true); setMessage("Restoring the agent video and its cutaway photos…");
    try {
      const validId = (id: string) => /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id);
      if (!validId(request.listingId) || !validId(request.assetId) || !request.cutaways.length || request.cutaways.length > 12 || request.cutaways.some(item => !validId(item.photoId) || !Number.isFinite(item.start) || !Number.isFinite(item.end) || item.start < 0 || item.end <= item.start || item.end > 180)) throw new Error("Choose a saved agent plan with valid photos and cutaways inside the 3-minute edit.");
      const photos = new Map<string, ReadableMedia>(); let base: {url:string}|undefined, offset: number|null = 0;
      do {
        const page = await services.listMedia(workspace.org.id, request.listingId, controller.current.signal, offset);
        page.photos.forEach(photo => photos.set(photo.id,photo)); base ??= page.videos.find(video => video.id === request.assetId);
        offset = page.nextOffset; if (offset !== null && offset > 10000) throw new Error("The property has too much media to restore at once.");
      } while (offset !== null && (!base || request.cutaways.some(item => !photos.has(item.photoId))));
      await resolvePhotoAliases(services,workspace.org.id,request.listingId,photos,request.cutaways.map(item=>item.photoId),controller.current.signal);
      if (!base || request.cutaways.some(item => !photos.has(item.photoId))) throw new Error("The agent recording or a cutaway photo is missing. Refresh AI tools and choose available media. Your current edit is unchanged.");
      let total = 0;
      const download = async (url: string, name: string) => {
        const response = await fetch(url, {signal:controller.current.signal,credentials:"omit",redirect:"error",referrerPolicy:"no-referrer"});
        if (!response.ok || !response.body || Number(response.headers.get("content-length")) > EDIT_LIMITS.fileBytes) {void response.body?.cancel().catch(()=>{});throw new Error("A source file could not be restored within the 128 MiB browser limit.");}
        const reader=response.body.getReader(),chunks:Uint8Array<ArrayBuffer>[]=[];let size=0;
        try {for(;;){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;total+=value.byteLength;if(size>EDIT_LIMITS.fileBytes||total>EDIT_LIMITS.totalBytes)throw new Error("The agent video and cutaways exceed the 512 MiB browser source limit.");chunks.push(new Uint8Array(value));}}
        finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
        const type=response.headers.get("content-type")?.split(";")[0]||"";
        return new File(chunks,`${name}.${type==="image/png"?"png":type==="image/webp"?"webp":type.startsWith("image/")?"jpg":type==="video/quicktime"?"mov":type==="video/webm"?"webm":"mp4"}`,{type});
      };
      const baseFile=await download(base.url,"agent-recording"),files:File[]=[];
      for(const [index,item] of request.cutaways.entries())files.push(await download(photos.get(item.photoId)!.url,`cutaway-${index+1}`));
      if(controller.current.signal.aborted)return;
      applyingPlan.current={listingId:request.listingId,ids:[request.assetId,...request.cutaways.map(item=>item.photoId)],requestId:request.id};
      setAgentRequest({id:crypto.randomUUID(),baseFile,photos:files,overlays:request.cutaways.map(item=>({start:item.start,end:item.end,caption:item.caption,motion:mapShotMotion(item.motion)}))});
    }catch(error){if(!controller.current.signal.aborted){setMessage(error instanceof Error?error.message:"The agent plan could not be restored.");setSourceBusy(false);}}
  }
  function planApplied(draft: EditDraft) {
    const plan = applyingPlan.current; if (!plan) return;
    if (plan.listingId !== selected.current) {setMessage("This plan belongs to another property's reel.");setSourceBusy(false);applyingPlan.current=null;return;}
    sources.current = draftMedia(draft).map((clip, index) => ({sha256: clip.source.sha256, assetId: plan.ids[index], listingId: plan.listingId}));
    currentDraft.current = draft; queue(); applyingPlan.current = null; setSourceBusy(false);
    ignoredPlans.current.add(plan.requestId); setPlanVersion(value => value + 1);
  }

  function draftChanged(draft: EditDraft) {
    currentDraft.current = validateDraft(draft);
    const nextCount = { clips: draft.clips.length, bytes: [...new Map(draftMedia(draft).map(clip=>[clip.source.sha256,clip.source.size])).values()].reduce((total,size)=>total+size,0) };
    setMediaCount(old => old.clips === nextCount.clips && old.bytes === nextCount.bytes ? old : nextCount);
    try { localStorage.setItem(localKey, JSON.stringify(draft)); } catch { setMessage("Browser backup is unavailable. Keep this tab open until cloud saving finishes."); }
    queue();
  }
  async function saveOutput(output: LocalExport) {
    if (outputFlight.current) throw new Error("This video is already being saved.");
    const target = selected.current;
    if (!target) throw new Error("Choose the property for this video first.");
    if (output.extension !== "mp4") throw new Error("Choose MP4 when exporting to save a video to your property. This browser’s WebM file can still be downloaded.");
    const outputDraft = currentDraft.current && validateDraft(currentDraft.current);
    if (!outputDraft || outputDraft.revision !== output.revision) throw new Error("The edit changed. Export the current version before saving.");
    const outputSources = activeSourceRefs(outputDraft, sources.current, target).filter(source => source.listingId === target);
    if (outputSources.length !== new Set(draftMedia(outputDraft).map(clip => clip.source.sha256)).size) throw new Error("Save every original file with this property before saving the finished video.");
    outputFlight.current = true; setOutputBusy(true);
    const signal = controller.current.signal;
    try {
      const fingerprint = await fingerprintFile(output.blob, signal), key = `${localKey}:output:${target}:${fingerprint}`;
      if (pendingFiles(target).length) throw new Error("Finish saving the original files to this property before saving its finished video.");
      const uploaded = await uploadListingAsset(services, { orgId: workspace.org.id, listingId: target, file: new File([output.blob], `studio-edit-${output.revision}.mp4`, { type: "video/mp4" }), role: "render", metadata: { duration_s: output.duration }, signal, resume: readJournal(key), onJournal: journal => recordJournal(key, journal) });
      if (!signal.aborted) {
        const finalized = await services.api("/functions/v1/studio/edit-output", {method: "POST", orgId: workspace.org.id, body: {listing_id: target, asset_id: uploaded.assetId, source_asset_ids: outputSources.map(source => source.assetId), ...(outputDraft.narration ? {narration_result_id: outputDraft.narration.resultId} : {})}, signal}) as {ok: boolean; asset_id: string};
        if (finalized.ok !== true || finalized.asset_id !== uploaded.assetId) throw new Error("The edited video’s disclosure could not be confirmed. Retry Save video to listing.");
        props.onChanged();
      }
    } finally { outputFlight.current = false; if (!signal.aborted) setOutputBusy(false); }
  }
  const editProperty = listings.find(listing => listing.id === listingId);
  const pickerProperty = listings.find(listing => listing.id === pickerListingId && listing.orgId === workspace.org.id);
  return <div className="cloud-editor">
    {editProperty&&<CapturePlan key={`${workspace.user.id}:${workspace.org.id}:${editProperty.id}`} services={services} workspace={workspace} listing={editProperty} onPlan={setProductionPlan} onPrepareSwitch={registerPlanGuard}/>}
    {earlier.length > 0 && <section className="panel" aria-label="Earlier reel recovery"><h2>Continue an earlier reel?</h2><p>Copy an earlier edit into this property's new reel, or start fresh. Every earlier account and browser copy stays unchanged.</p>{earlier.map(copy => <div key={copy.id}><h3>{copy.label}</h3><p>{copy.payload.draft.title || "Untitled reel"} · {copy.payload.draft.clips.length} clips. Files that were never uploaded will need selecting again.</p><button onClick={() => recoveryChoice.current?.(copy.payload)}>Use {copy.label.toLowerCase()}</button></div>)}<button onClick={() => recoveryChoice.current?.(null)}>Start a new property reel</button></section>}
    <section className="reel-start-guide" aria-label="Make a reel in three steps">
      <header><h2>Make a reel{editProperty ? ` · ${editProperty.address || editProperty.tagline || "Your property"}` : ""}</h2><p>Your photos become one video for Reels, TikTok or YouTube. Photos → Voice → Make it.</p></header>
      <div className="reel-step-grid">
        <div className="reel-step"><span>1 · Photos</span><h3>Use your phone’s photos & video</h3><p>Pick uploaded media from this property. Keep the current edit and add the next shots.</p><button disabled={!ready || sourceBusy || outputBusy || state === "conflict"} onClick={openPicker}>Choose property photos & video</button></div>
        <div className="reel-step"><span>2 · Voice</span><h3>Add your voice or a script</h3><p>Choose a saved voiceover below, keep the video’s original sound, or make a new narration.</p>{props.onOpenCreative && <div><button disabled={!ready || !listingId || sourceBusy || outputBusy} onClick={() => props.onOpenCreative?.(listingId, "voiceover")}>Create a voiceover</button><button disabled={!ready || !listingId || sourceBusy || outputBusy} onClick={() => props.onOpenCreative?.(listingId, "shot-plans")}>Help plan my reel</button></div>}</div>
        <div className="reel-step"><span>3 · Make it</span><h3>Review, export & share</h3><p>Arrange the shots, choose a shape and play the preview. Export MP4, then choose “Save video to listing” to see the finished reel on your phone.</p><button disabled={!ready} onClick={() => editorAnchor.current?.scrollIntoView({behavior: "smooth", block: "start"})}>Continue in the editor</button>{productionPlan&&<button disabled={!ready||sourceBusy||outputBusy||state==="conflict"||mediaCount.clips===0} onClick={()=>{setRecipeRequest({id:crypto.randomUUID(),recipe:productionPlan.recipe,options:{targetSeconds:productionPlan.targetSeconds}});editorAnchor.current?.scrollIntoView({behavior:"smooth",block:"start"});}}>Build a guided draft</button>}</div>
      </div>
    </section>
    {pickerProperty && <><p className="reel-picker-context">{listingId && listingId !== pickerProperty.id && mediaCount.clips > 0 ? `Your current edit belongs to ${editProperty?.address || "another property"}. You are choosing files from ${pickerProperty.address || "this property"}; nothing moves until you review the import below.` : "Use the same property on your iPhone and desktop. Finish phone uploads so the files appear here."}</p><ReelMediaPicker services={services} workspace={workspace} listing={pickerProperty} availableSlots={Math.max(0, EDIT_LIMITS.clips - mediaCount.clips)} remainingBytes={Math.max(0, EDIT_LIMITS.totalBytes - mediaCount.bytes)} disabled={!ready || sourceBusy || outputBusy || state === "conflict"} onImport={acceptPickerMedia} onClose={() => setPickerListingId(null)} /></>}
    <section className="sync-toolbar panel">
      <span>Saved with {editProperty?.address || "this property"}</span>
      <button disabled={!ready || !listingId || sourceBusy || outputBusy} onClick={() => void loadPhoneRecipe()}>Load phone reel setup</button>
      <SyncStatus state={state} retry={() => { if (ready) void session.current?.retry(); else window.location.reload(); }} reload={() => window.location.reload()} />
      {message && <p role="status">{message}</p>}
      {!listingId && <p>Choose a property to save original files and finished videos with your phone’s work.</p>}
      {sourceBusy ? <span role="status">Syncing media…</span> : pendingFiles(listingId).length > 0 && listingId ? <button onClick={() => void syncSources()}>Resume source upload</button> : null}
      {recovery && <p>A previous browser draft is preserved. <button onClick={() => {
        try { const saved = localStorage.getItem(`${localKey}:recovery`); if (saved) { const url = URL.createObjectURL(new Blob([saved], { type: "application/json" })); const link = document.createElement("a"); link.href = url; link.download = "rendprop-edit-recovery.json"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); } }
        catch { setMessage("The previous browser backup could not be downloaded. Your current cloud work is still available."); }
      }}>Download previous draft</button></p>}
    </section>
    {nativeRecipe && <section className="panel"><h3>Continue the reel from your phone</h3><p>Saved {new Date(nativeRecipe.recipe.updatedAt).toLocaleString()} · {nativeRecipe.recipe.photos.length} selected photos · {nativeRecipe.recipe.portrait ? "Portrait" : "Landscape"} · {nativeRecipe.recipe.transition} transitions.</p><p>Restoring the sequence uses each selected cloud photo at 3 seconds. Generated shot timings and motion are separate saved AI plans.</p>{nativeRecipe.recipe.photos.some(photo => !photo.sourcePhotoId) && <p>Some photos are still only on your phone. Upload them and save the setup again before restoring the full sequence.</p>}{nativeRecipe.recipe.localExtraClipCount > 0 && <p>{nativeRecipe.recipe.localExtraClipCount} extra clips need an upload from your phone before the complete sequence can be restored.</p>}{nativeRecipe.recipe.voiceMode !== "off" && !nativeRecipe.recipe.voiceResultId && <p>Phone narration has no saved cloud result. Applying this setup leaves narration off so you can choose a saved voice result.</p>}{nativeRecipe.recipe.script && <label>Phone script<textarea aria-label="Phone script" readOnly rows={4} value={nativeRecipe.recipe.script} /></label>}<button disabled={sourceBusy || outputBusy || state === "conflict"} onClick={() => void applyPhoneRecipe(true)}>Restore phone photos and settings</button><button disabled={sourceBusy || outputBusy || state === "conflict"} onClick={() => void applyPhoneRecipe(false)}>Apply settings to current sequence</button><button disabled={sourceBusy} onClick={() => setNativeRecipe(null)}>Keep current edit</button></section>}
    {props.importAgentPlan && !ignoredPlans.current.has(props.importAgentPlan.id) && <section className="panel"><h3>Apply your agent video plan</h3><p>Restore the original agent recording and {props.importAgentPlan.cutaways.length} timed photo cutaways. This replaces the current sequence after every source is checked. Your continuous original speech stays underneath the photos.</p><button disabled={!ready || sourceBusy || outputBusy || state === "conflict"} onClick={() => void applyAgentPlan()}>Replace edit with agent plan</button><button disabled={sourceBusy} onClick={() => {ignoredPlans.current.add(props.importAgentPlan!.id);setPlanVersion(value=>value+1);}}>Keep current edit</button></section>}
    {props.importPlan && !ignoredPlans.current.has(props.importPlan.id) && <section className="panel" key={`${props.importPlan.id}:${planVersion}`}><h3>Apply your saved shot plan</h3><p>{props.importPlan.shots.length} photos for {listings.find(listing => listing.id === props.importPlan!.listingId)?.address || "this property"}. This replaces the current sequence after every original photo is restored. The plan’s order, timing, captions, gentle photo motion, and selected narration are applied.</p><button disabled={!ready || sourceBusy || outputBusy || state === "conflict"} onClick={() => void applyShotPlan()}>Replace edit with this shot plan</button><button disabled={sourceBusy} onClick={() => {ignoredPlans.current.add(props.importPlan!.id);setPlanVersion(value => value + 1);}}>Keep current edit</button></section>}
    <div ref={editorAnchor}>{ready ? <VideoEditor {...props} initialMode={props.initialMode??"simple"} recipeRequest={recipeRequest} seekRequest={seekRequest} onSwitchBlockChange={observeEditorBlock} settingsRequest={settingsRequest} onSettingsApplied={() => setMessage("Phone reel settings applied. Review the sequence before exporting.")} importRequest={acceptedImport} planRequest={planRequest} agentRequest={agentRequest} onPlanApplied={planApplied} onPlanFailed={message => {setMessage(message);setSourceBusy(false);applyingPlan.current=null;}} initialDraft={initial} onDraftChange={draftChanged} onSourcesChange={sourcesChanged} relinkRequest={relink} onSaveOutput={saveOutput} narrationChoices={narrationChoices} resolveNarration={resolveNarration} /> : <p role="status">Opening your saved edit…</p>}</div>
    {listingId&&props.onCopyVersion&&<VersionHistory services={services} workspace={workspace} listingId={listingId} onCopy={props.onCopyVersion}/>}
    {listingId&&<ReviewPanel services={services} workspace={workspace} listingId={listingId} ready={ready&&state==="saved"&&!sourceBusy&&!outputBusy&&pendingFiles(listingId).length===0} savedRevision={savedRevision} prepare={async()=>{await preparePlan.current?.();await session.current?.flush();if(!session.current||session.current.hasUnsavedWork||session.current.state!=="saved"||pendingFiles(listingId).length)throw new Error("Finish saving this edit and its source files before reviewing it.");}} onSeek={time=>{setSeekRequest({id:crypto.randomUUID(),time});editorAnchor.current?.scrollIntoView({behavior:"smooth",block:"start"});}}/>}
  </div>;
}
