import { useCallback, useEffect, useRef, useState } from "react";
import type { Listing, StudioPhoto, Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { uploadListingAsset } from "../listings/uploads";
import { decodeListingState } from "../listings/model";
import {
  downloadText,
  editedImage,
  imageFromURL,
  prepareImage,
  type SourceImage,
  videoFrames,
} from "./media";
import {
  type AgentPlanHandoff,
  type CreativeDraft,
  type CreativeResult,
  decodeChapters,
  decodeCutaways,
  decodeDraft,
  decodeResult,
  decodeShots,
  type Edit,
  EMPTY_DRAFT,
  listingFacts,
  number,
  parseTranscript,
  PRESETS,
  record,
  requiredText,
  rows,
  type ShotPlanHandoff,
  subtitleFile,
  text,
} from "./model";
import "./creative.css";
import { importSubtitleTranscript, TRANSCRIPT_FILE_BYTES } from "./transcript";

type Props = {
  services: StudioServices;
  workspace: Workspace;
  listings: Listing[];
  listingId?: string;
  onChanged: () => void;
  onSelectListing?: (id: string) => void;
  onUseShotPlan?: (plan: ShotPlanHandoff) => void;
  onUseAgentPlan?: (plan: AgentPlanHandoff) => void;
};
type Panel = "photos" | "copy" | "voice" | "video" | "chapters" | "coach";
const PANELS: { id: Panel; label: string }[] = [
  { id: "photos", label: "Photo Studio" },
  { id: "copy", label: "Scripts & shot plans" },
  { id: "voice", label: "Voiceover" },
  { id: "video", label: "AI video" },
  { id: "chapters", label: "Room chapters" },
  { id: "coach", label: "Ask Rendprop" },
];
export default function CreativeWorkspace(props: Props) {
  const [selected, setSelected] = useState(
    props.listingId ?? props.listings[0]?.id ?? "",
  );
  useEffect(() => {
    if (props.listingId) setSelected(props.listingId);
  }, [props.listingId]);
  const listing = props.listings.find((item) => item.id === selected) ??
    props.listings[0];
  return (
    <section className="creative-workspace" aria-label="Creative Studio">
      <header className="creative-heading">
        <div>
          <span className="creative-eyebrow">CREATE WITH YOUR LISTING</span>
          <h1>Creative Studio</h1>
          <p>
            Polish your photos, plan your story and create your next property
            video.
          </p>
        </div>
        <label>
          Property<select
            value={listing?.id ?? ""}
            onChange={(e) => {
              setSelected(e.target.value);
              props.onSelectListing?.(e.target.value);
            }}
          >
            {props.listings.map((item) => (
              <option key={item.id} value={item.id}>
                {item.address || item.tagline || "Untitled property"}
              </option>
            ))}
          </select>
        </label>
      </header>
      {listing
        ? (
          <ListingCreative
            key={`${props.workspace.user.id}:${props.workspace.org.id}:${listing.id}`}
            {...props}
            listing={listing}
          />
        )
        : (
          <div className="creative-empty">
            <h2>Start with a property</h2>
            <p>
              Create a listing or sync one from your phone. Your creative tools
              and saved results will stay with that property.
            </p>
          </div>
        )}
    </section>
  );
}
function ListingCreative(
  {
    services,
    workspace,
    listings,
    listing,
    onChanged,
    onSelectListing,
    onUseShotPlan,
    onUseAgentPlan,
  }:
    & Props
    & { listing: Listing },
) {
  const orgId = workspace.org.id, listingId = listing.id;
  const [panel, setPanel] = useState<Panel>("photos"),
    [busy, setBusy] = useState<string | null>(null),
    [error, setError] = useState<string | null>(null),
    [notice, setNotice] = useState<string | null>(null);
  const [photos, setPhotos] = useState<StudioPhoto[]>([]),
    [mediaOffset, setMediaOffset] = useState<number | null>(null),
    [selectedPhotos, setSelectedPhotos] = useState<string[] | null>(null);
  const [assets, setAssets] = useState<
      ReturnType<typeof decodeListingState>["assets"]
    >([]),
    [renders, setRenders] = useState<
      ReturnType<typeof decodeListingState>["renders"]
    >([]),
    [renderJobs, setRenderJobs] = useState<
      ReturnType<typeof decodeListingState>["jobs"]
    >([]);
  const [source, setSource] = useState<SourceImage | null>(null),
    [edit, setEdit] = useState<Edit>("twilight"),
    [style, setStyle] = useState("modern"),
    [prompt, setPrompt] = useState(""),
    [room, setRoom] = useState("");
  const [suggestions, setSuggestions] = useState<
      { edit: Edit; reason: string }[]
    >([]),
    [photoResult, setPhotoResult] = useState<
      {
        file: File;
        preview: string;
        provenanceId: string | null;
        disclosure: string;
        originalAssetId: string;
        saved: boolean;
      } | null
    >(null);
  const [draft, setDraft] = useState<CreativeDraft>(EMPTY_DRAFT),
    [draftReady, setDraftReady] = useState(false),
    [dirty, setDirty] = useState(false),
    [syncAt, setSyncAt] = useState(""),
    [restoreConflict, setRestoreConflict] = useState(false),
    [cloudDraft, setCloudDraft] = useState<CreativeDraft | null>(null);
  const backupKey =
    `rendprop:creative:v1:${workspace.user.id}:${orgId}:${listingId}`;
  const revision = useRef(0),
    currentDraft = useRef(EMPTY_DRAFT),
    abort = useRef(new AbortController()),
    alive = useRef(true),
    pollBusy = useRef(false),
    operationBusy = useRef(false);
  const [tone, setTone] = useState("warm"),
    [targetSeconds, setTargetSeconds] = useState(30);
  const [voices, setVoices] = useState<
      { id: string; name: string; description: string }[]
    >([]),
    [voiceId, setVoiceId] = useState("");
  const [results, setResults] = useState<CreativeResult[]>([]),
    [videoKind, setVideoKind] = useState("reel"),
    [motion, setMotion] = useState("push_in"),
    [seconds, setSeconds] = useState(5),
    [videoAsset, setVideoAsset] = useState(""),
    [tier, setTier] = useState("1080p60"),
    [quality, setQuality] = useState<
      Record<string, { pass: boolean; message: string }>
    >({});
  const [planNarrationId, setPlanNarrationId] = useState("");
  const [chapterAsset, setChapterAsset] = useState(""),
    [chapterRender, setChapterRender] = useState(""),
    [maxChapters, setMaxChapters] = useState(12);
  const [conversation, setConversation] = useState<
      { role: "user" | "assistant"; content: string }[]
    >([]),
    [question, setQuestion] = useState(""),
    [replies, setReplies] = useState<string[]>([
      "What should I do next for this property?",
      "How do I create a property reel?",
      "How do I share an unbranded tour?",
    ]);
  const role = workspace.memberships.find((m) => m.orgId === orgId)?.role,
    canCreate = role !== "marketing";
  const signal = abort.current.signal;
  const api = useCallback(
    (
      path: string,
      body?: unknown,
      options?: {
        idempotencyKey?: string;
        timeoutMs?: number;
        maxResponseBytes?: number;
      },
    ) =>
      services.api(`/functions/v1/${path}`, {
        orgId,
        signal,
        method: body === undefined ? "GET" : "POST",
        body,
        ...options,
      }),
    [services, orgId, signal],
  );
  useEffect(() => () => {
    alive.current = false;
    abort.current.abort();
  }, []);
  function message(value: unknown) {
    return value instanceof Error
      ? value.message
      : "This action could not finish. Please try again.";
  }
  async function run(label: string, action: () => Promise<void>) {
    if (operationBusy.current) return;
    operationBusy.current = true;
    setBusy(label);
    setError(null);
    setNotice(null);
    try {
      await action();
    } catch (e) {
      if (alive.current && !signal.aborted) setError(message(e));
    } finally {
      operationBusy.current = false;
      if (alive.current) setBusy(null);
    }
  }
  function localBackup(next: CreativeDraft) {
    try {
      localStorage.setItem(
        backupKey,
        JSON.stringify({ revision: revision.current, payload: next }),
      );
    } catch {
      setError(
        "Your browser could not keep a recovery copy. Save your draft before leaving this property.",
      );
    }
  }
  function updateDraft(next: CreativeDraft) {
    currentDraft.current = next;
    setDraft(next);
    setDirty(true);
    localBackup(next);
  }
  useEffect(() => {
    if (!dirty) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);
  async function loadDraft(useCloud = false) {
    const result = record(
      await api(
        `studio/documents?${new URLSearchParams({
          org_id: orgId,
          key: `creative:${listingId}`,
        })}`,
      ),
    );
    const doc = result.document ? record(result.document) : null;
    let next = doc ? decodeDraft(doc.payload) : { ...EMPTY_DRAFT };
    const remoteRevision = doc ? number(doc.revision) : 0;
    let recovered = false, conflict = false;
    setCloudDraft(next);
    try {
      if (useCloud) localStorage.removeItem(backupKey);
      else {
        const raw = localStorage.getItem(backupKey);
        if (raw) {
          const backup = record(JSON.parse(raw));
          const candidate = decodeDraft(backup.payload);
          if (Number.isSafeInteger(backup.revision)) {
            next = candidate;
            recovered = true;
            conflict = backup.revision !== remoteRevision;
          }
        }
      }
    } catch {
      /* An unreadable recovery copy never replaces the server draft. */
    }
    if (!alive.current) return;
    revision.current = remoteRevision;
    currentDraft.current = next;
    setDraft(next);
    setSyncAt(doc ? text(doc.updated_at, 80) : "");
    setDirty(recovered);
    setRestoreConflict(conflict);
    setDraftReady(true);
    if (recovered) {
      setNotice("Recovered your unsaved creative draft from this browser.");
    }
  }
  async function saveDraft(next = currentDraft.current) {
    if (restoreConflict) {
      throw new Error(
        "Your cloud draft changed on another device. Choose which draft to keep before saving.",
      );
    }
    if (!draftReady) {
      throw new Error(
        "Wait for your saved creative draft to load before saving changes.",
      );
    }
    const payload = { ...next, updatedAt: new Date().toISOString() };
    const result = record(
      await api("studio/documents", {
        key: `creative:${listingId}`,
        kind: "creative",
        listing_id: listingId,
        expected_revision: revision.current,
        payload,
      }),
    );
    const doc = record(result.document);
    if (!alive.current) return;
    revision.current = number(doc.revision);
    setSyncAt(text(doc.updated_at, 80));
    if (currentDraft.current === next) {
      currentDraft.current = payload;
      setDraft(payload);
      setDirty(false);
      try {
        localStorage.removeItem(backupKey);
      } catch { /* The saved server copy is authoritative. */ }
    } else {
      localBackup(currentDraft.current);
      setDirty(true);
    }
  }
  async function refreshResults() {
    const found: CreativeResult[] = [];
    let offset = 0;
    for (let page = 0; page <= 100; page++) {
      const result = record(
        await api(
          `studio/creative-results?${new URLSearchParams({
            org_id: orgId,
            listing_id: listingId,
            offset: String(offset),
          })}`,
        ),
      );
      found.push(...rows(result.results, 100).map(decodeResult));
      if (result.next_offset === null || result.next_offset === undefined) {
        break;
      }
      if (result.next_offset !== offset + 100) {
        throw new Error(
          "Creative results returned an invalid page. Refresh this property.",
        );
      }
      offset += 100;
    }
    if (alive.current) setResults(found);
    return found;
  }
  async function loadAssets() {
    let offset = 0,
      allAssets: typeof assets = [],
      allRenders: typeof renders = [],
      allJobs: typeof renderJobs = [];
    for (let page = 0; page < 100; page++) {
      const raw = await api(
        `studio/listing-state?${new URLSearchParams({
          org_id: orgId,
          listing_id: listingId,
          offset: String(offset),
        })}`,
      );
      const data = decodeListingState(raw, orgId, listingId, offset);
      allAssets = [...allAssets, ...data.assets];
      allRenders = [...allRenders, ...data.renders];
      allJobs = [...allJobs, ...data.jobs];
      if (data.nextOffset === null) break;
      offset = data.nextOffset;
    }
    if (alive.current) {
      setAssets(allAssets);
      setRenders(allRenders);
      setRenderJobs(allJobs);
    }
  }
  async function loadPhotos(offset = 0) {
    const media = await services.listMedia(orgId, listingId, signal, offset);
    if (alive.current) {
      setPhotos((old) =>
        offset ? [...old, ...media.photos] : [...media.photos]
      );
      setMediaOffset(media.nextOffset);
    }
  }
  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([
      loadDraft(),
      loadPhotos(),
      loadAssets(),
      refreshResults(),
    ]).then((outcomes) => {
      if (cancelled) return;
      const failed = outcomes.find((outcome) => outcome.status === "rejected");
      if (failed?.status === "rejected") setError(message(failed.reason));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  const pendingResults = results.filter((r) =>
    r.kind === "video" && ["processing", "importing"].includes(r.state)
  ).map((r) => r.id).join(",");
  useEffect(() => {
    if (!pendingResults) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      if (cancelled || signal.aborted) return;
      if (!document.hidden && !pollBusy.current) {
        pollBusy.current = true;
        try {
          for (const id of pendingResults.split(",")) {
            const result = record(
              await api("studio/video-status", { result_id: id }, {
                timeoutMs: 180_000,
              }),
            );
            if (!cancelled) {
              const updated = decodeResult(result.result);
              setResults((old) => old.map((r) => r.id === id ? updated : r));
            }
          }
        } catch (e) {
          if (!cancelled) setError(message(e));
        } finally {
          pollBusy.current = false;
        }
      }
      if (!cancelled) timer = setTimeout(poll, 15_000);
    }
    timer = setTimeout(poll, 3000);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [pendingResults, api, signal]);
  useEffect(() => {
    if (panel !== "voice" || voices.length) return;
    let cancelled = false;
    api("ai-voice/voices").then((raw) => {
      const response = record(raw);
      const list = rows(response.voices, 100).flatMap((rawVoice) => {
        const v = record(rawVoice),
          id = text(v.voice_id, 100),
          name = text(v.name, 100);
        return id && name
          ? [{ id, name, description: text(v.labels, 300) }]
          : [];
      });
      if (!cancelled) {
        setVoices(list);
        setVoiceId(list[0]?.id ?? "");
      }
    }).catch((e) => {
      if (!cancelled) setError(message(e));
    });
    return () => {
      cancelled = true;
    };
  }, [panel, voices.length, api]);
  const chosenPhotos = selectedPhotos !== null
    ? photos.filter((photo) => selectedPhotos.includes(photo.id))
    : photos.slice(0, 20);
  const videos = assets.filter((asset) =>
      asset.kind === "video" && asset.uploaded
    ),
    publicVideos = videos.filter((asset) => asset.bucket === "renders");
  const agentVideos = videos.filter((asset) =>
    asset.duration_s == null || asset.duration_s >= 6 && asset.duration_s <= 180
  );
  const agentBase = agentVideos.find((asset) =>
    asset.id === draft.agentAssetId
  );
  const agentSeconds = agentBase?.duration_s ?? draft.agentDuration ?? 30;
  async function chooseSource(next: SourceImage) {
    setSource(next);
    setPhotoResult(null);
    setSuggestions([]);
  }
  async function ensureOriginal() {
    if (!source) throw new Error("Choose the photo you want to work on first.");
    if (source.originalAssetId) return source.originalAssetId;
    const asset = await uploadListingAsset(services, {
      orgId,
      listingId,
      file: source.file,
      role: "original",
      signal,
    });
    if (alive.current) setSource({ ...source, originalAssetId: asset.assetId });
    return asset.assetId;
  }
  async function generatePhoto() {
    if (!source) throw new Error("Choose a photo first.");
    if (edit === "custom" && !prompt.trim()) {
      throw new Error("Describe the change you want to make.");
    }
    const originalAssetId = await ensureOriginal();
    const response = record(
      await api("ai-photo", {
        listing_id: listingId,
        original_asset_id: originalAssetId,
        image_b64: source.base64,
        mime: source.mime,
        edit,
        space_type: listing.spaceType,
        label: room || "Studio photo",
        ...(edit === "stage" ? { style } : {}),
        ...(edit === "custom" ? { prompt: prompt.trim() } : {}),
      }, {
        idempotencyKey: crypto.randomUUID(),
        timeoutMs: 300_000,
        maxResponseBytes: 32 * 1024 * 1024,
      }),
    );
    const file = editedImage(
        requiredText(response.image_b64, "an edited photo", 32 * 1024 * 1024),
        text(response.mime, 50) || "image/png",
      ),
      preview = `data:${file.type};base64,${String(response.image_b64)}`;
    const provenance = response.provenance ? record(response.provenance) : {};
    setPhotoResult({
      file,
      preview,
      originalAssetId,
      provenanceId: provenance.recorded === true
        ? text(provenance.id, 80) || null
        : null,
      disclosure: requiredText(
        response.disclosure,
        "the photo disclosure",
        1000,
      ),
      saved: false,
    });
    if (provenance.recorded !== true) {
      setNotice(
        "Your edited photo is ready to review, but its disclosure record could not be saved. Download the result and retry later before adding it to a public gallery.",
      );
    }
  }
  async function savePhoto() {
    if (!photoResult) return;
    if (!photoResult.provenanceId) {
      throw new Error(
        "This edit needs its disclosure record before it can be saved to the gallery.",
      );
    }
    const result = await uploadListingAsset(services, {
      orgId,
      listingId,
      file: photoResult.file,
      role: "gallery",
      signal,
    });
    await services.api(
      `/functions/v1/me/compliance/${photoResult.provenanceId}`,
      {
        orgId,
        signal,
        method: "PATCH",
        body: {
          original_asset_id: photoResult.originalAssetId,
          altered_asset_id: result.assetId,
        },
      },
    );
    await api("studio/photos", {
      listing_id: listingId,
      asset_id: result.assetId,
      caption: room || PRESETS.find((p) => p.id === edit)?.name,
      provenance_id: photoResult.provenanceId,
    });
    setPhotoResult({ ...photoResult, saved: true });
    setNotice(
      "Photo saved to this property's cloud gallery with the original and AI disclosure attached.",
    );
    onChanged();
    await loadPhotos();
  }
  async function generateCopy(kind: "script" | "shotlist") {
    const photoList = chosenPhotos.map((p) => ({
      id: p.id,
      room: p.caption || "",
    }));
    if (kind === "shotlist" && !photoList.length) {
      throw new Error("Add property photos before creating a shot plan.");
    }
    const body = {
      listing_id: listingId,
      space_type: listing.spaceType,
      facts: listingFacts(listing),
      target_seconds: targetSeconds,
      tone,
      ...(kind === "script"
        ? {
          photo_count: chosenPhotos.length,
          room_tags: photoList.map((p) => p.room).filter(Boolean),
        }
        : { photos: photoList }),
    };
    const response = record(
      await api(`ai-copy/${kind}`, body, {
        idempotencyKey: crypto.randomUUID(),
        timeoutMs: 180_000,
      }),
    );
    const next = {
      ...currentDraft.current,
      script: requiredText(response.script, "a script", 4000),
      ...(kind === "shotlist"
        ? { shots: decodeShots(response.shots, chosenPhotos.map((p) => p.id)) }
        : {}),
    };
    updateDraft(next);
    await saveDraft(next);
    setNotice("Saved to this property's creative draft.");
  }
  async function generateAgentPlan() {
    if (
      !agentBase || !Number.isFinite(agentSeconds) || agentSeconds < 6 ||
      agentSeconds > 180
    ) {
      throw new Error(
        "Choose your saved on-camera video, between 6 and 180 seconds long.",
      );
    }
    const transcript = parseTranscript(
      currentDraft.current.agentTranscript,
      agentSeconds,
    );
    const response = record(
      await api("ai-copy/agent-reel", {
        listing_id: listingId,
        space_type: listing.spaceType,
        facts: listingFacts(listing),
        tone,
        subject: "listing",
        photos: chosenPhotos.map((p) => ({ id: p.id, room: p.caption || "" })),
        clip_seconds: agentSeconds,
        transcript,
      }, { idempotencyKey: crypto.randomUUID(), timeoutMs: 180_000 }),
    );
    const next = {
      ...currentDraft.current,
      agentAssetId: agentBase.id,
      agentDuration: agentSeconds,
      cutaways: decodeCutaways(
        response.cutaways,
        chosenPhotos.map((p) => p.id),
        agentSeconds,
      ),
    };
    updateDraft(next);
    await saveDraft(next);
    setNotice(
      "Your timed cutaway plan is saved. Use it in the editor to show the property photos over your continuous spoken footage.",
    );
  }
  async function importTranscript(file: File) {
    if (!agentBase) {
      throw new Error(
        "Choose the spoken video before importing its subtitles.",
      );
    }
    const format = file.name.split(".").at(-1)?.toLowerCase();
    if (
      !file.size || file.size > TRANSCRIPT_FILE_BYTES ||
      !["srt", "vtt"].includes(format ?? "")
    ) {
      throw new Error(
        "Choose an .srt or .vtt subtitle file smaller than 256 KiB.",
      );
    }
    let contents: string;
    try {
      contents = new TextDecoder("utf-8", { fatal: true }).decode(
        await file.arrayBuffer(),
      );
    } catch {
      throw new Error(
        "Save the subtitle file as UTF-8 text, then import it again.",
      );
    }
    if (!alive.current || signal.aborted) return;
    const next = {
      ...currentDraft.current,
      agentTranscript: importSubtitleTranscript(
        contents,
        format as "srt" | "vtt",
        agentSeconds,
      ),
      cutaways: [],
    };
    updateDraft(next);
    await saveDraft(next);
    setNotice(
      "Subtitles imported and saved. Review the words, then create your cutaway plan.",
    );
  }
  async function generateVoice() {
    if (!voiceId) throw new Error("Choose a voice first.");
    if (!draft.script.trim() || draft.script.trim().length > 1000) {
      throw new Error("Use a voiceover script between 1 and 1,000 characters.");
    }
    if (dirty) await saveDraft();
    const raw = record(
      await api("studio/voice", {
        listing_id: listingId,
        text: draft.script.trim(),
        voice_id: voiceId,
        label: "Property voiceover",
      }, { idempotencyKey: crypto.randomUUID(), timeoutMs: 360_000 }),
    );
    setResults((old) => [decodeResult(raw.result), ...old]);
    setNotice(
      "Your narration is saved with this property and can be opened again on another device.",
    );
  }
  async function generateVideo() {
    let assetId = videoAsset;
    if (videoKind === "reel" || videoKind === "aerial") {
      assetId = await ensureOriginal();
    }
    if (!assetId) throw new Error("Choose a completed video first.");
    const body = {
      listing_id: listingId,
      kind: videoKind,
      asset_id: assetId,
      space_type: listing.spaceType,
      label: room ||
        ({
          reel: "Property motion clip",
          aerial: "Aerial-style intro",
          drone: "Drone glide",
          declutter: "Decluttered clip",
        }[videoKind]),
      ...(videoKind === "drone"
        ? { tier }
        : videoKind === "declutter"
        ? { prompt }
        : {
          seconds: videoKind === "aerial" ? 6 : seconds,
          motion: videoKind === "aerial" ? "orbit_left" : motion,
          room,
          prompt: prompt.trim() || undefined,
          ...(videoKind === "aerial"
            ? { aspect: "16:9", time_of_day: "day" }
            : {}),
        }),
    };
    const raw = record(
      await api("studio/video", body, {
        idempotencyKey: crypto.randomUUID(),
        timeoutMs: 360_000,
      }),
    );
    setResults((old) => [decodeResult(raw.result), ...old]);
    setNotice(
      "Generation started. You can leave this page and return to this property's saved results.",
    );
  }
  async function reviewVideo(result: CreativeResult) {
    const signed = decodeResult(
      record(await api("studio/sign-media", { result_id: result.id })).result,
    );
    if (!signed.url || !signed.sourceUrl || !signed.requestId) {
      throw new Error(
        "This clip needs its saved source photo before quality review.",
      );
    }
    const [sampled, original] = await Promise.all([
      videoFrames(signed.url, signal),
      imageFromURL(signed.sourceUrl, "original.jpg", signal),
    ]);
    const response = record(
      await api("ai-video/drift", {
        request_id: signed.requestId,
        listing_id: listingId,
        asset_id: signed.sourceAssetId,
        provenance_id: signed.provenanceId,
        kind: signed.videoKind === "aerial" ? "aerial" : "reel",
        source_b64: original.base64,
        source_mime: original.mime,
        frames: sampled.frames,
        seconds: sampled.seconds,
        attempt: 1,
        space_type: listing.spaceType,
      }, { idempotencyKey: `drift:${signed.id}:1`, timeoutMs: 300_000 }),
    );
    const verdict = record(response.drift);
    setQuality((old) => ({
      ...old,
      [result.id]: {
        pass: verdict.status === "pass" && verdict.publishable === true,
        message: text(verdict.message, 1000) ||
          "Quality review could not confirm this clip for publishing.",
      },
    }));
    await refreshResults();
    await loadAssets();
    onChanged();
  }
  async function generateChapters() {
    if (!chapterAsset) {
      throw new Error("Choose the walkthrough you want to chapter.");
    }
    const response = record(
      await api("ai-chapters", {
        listing_id: listingId,
        asset_id: chapterAsset,
        max_chapters: maxChapters,
        language: "en",
      }, { idempotencyKey: crypto.randomUUID(), timeoutMs: 360_000 }),
    );
    const next = {
      ...currentDraft.current,
      chapters: decodeChapters(response.chapters),
      chapterAssetId: chapterAsset,
    };
    updateDraft(next);
    await saveDraft(next);
    setNotice(
      [
        text(response.summary, 1000),
        ...rows(response.warnings, 10).map((w) => text(w, 300)),
      ].filter(Boolean).join(" ") ||
        "Review the suggested room labels and times before applying them.",
    );
  }
  const matchingTours = renders.filter((render) =>
    renderJobs.some((job) =>
      job.id === render.job_id &&
      job.capture_asset_id === (draft.chapterAssetId || chapterAsset)
    )
  );
  async function applyChapters() {
    if (!matchingTours.some((render) => render.id === chapterRender)) {
      throw new Error("Choose the tour that uses this walkthrough.");
    }
    await services.api(`/functions/v1/renders/${chapterRender}/chapters`, {
      orgId,
      signal,
      method: "PATCH",
      body: {
        chapters: draft.chapters.map((c, index) => ({
          label: c.label,
          t_ms: Math.round(c.start_s * 1000),
          sort: index,
        })),
      },
    });
    await saveDraft();
    setNotice("Room chapters updated on the hosted tour.");
    onChanged();
  }
  async function askCoach(input = question) {
    const content = input.trim();
    if (!content) return;
    const messages = [...conversation, { role: "user" as const, content }]
      .slice(-15);
    setConversation(messages);
    setQuestion("");
    const response = record(
      await api("coach", {
        messages,
        space_type: listing.spaceType,
        context: {
          plan: workspace.plan,
          screen: "studio",
          listings: listings.slice(0, 30).map((item) => ({
            id: item.id,
            title: item.tagline || item.address || "Property",
            has_video: item.id === listingId ? videos.length > 0 : false,
            room_tags: item.id === listingId ? draft.chapters.length : 0,
            has_tour: item.status === "ready",
            published: item.status === "ready",
            photos: item.id === listingId ? photos.length : 0,
            edits: item.id === listingId
              ? photos.filter((p) => p.isStaged).length
              : 0,
            reels: item.id === listingId
              ? results.filter((r) => r.kind === "video").length
              : 0,
          })),
        },
      }, { idempotencyKey: crypto.randomUUID(), timeoutMs: 120_000 }),
    );
    setConversation([...messages, {
      role: "assistant",
      content: requiredText(response.reply, "a reply", 4000),
    }]);
    setReplies(
      rows(response.suggested_replies, 3).map((r) => text(r, 250)).filter(
        Boolean,
      ),
    );
  }
  const toolbar = (
    <div className="creative-actions">
      <button
        disabled={!!busy}
        onClick={() =>
          run("Refreshing", async () => {
            await Promise.all([loadPhotos(), loadAssets(), refreshResults()]);
            setNotice("Cloud media and creative results refreshed.");
          })}
      >
        Refresh from cloud
      </button>
      <span className="creative-sync">
        {dirty
          ? "Unsaved draft changes"
          : syncAt
          ? `Draft saved ${
            new Date(syncAt).toLocaleTimeString([], {
              hour: "numeric",
              minute: "2-digit",
            })
          }`
          : draftReady
          ? "Cloud draft ready"
          : "Loading cloud draft…"}
      </span>
      {dirty && (
        <button
          disabled={!!busy || !draftReady || restoreConflict}
          onClick={() => run("Saving draft", () => saveDraft())}
        >
          Save draft
        </button>
      )}
    </div>
  );
  const sourcePicker = (
    <div className="creative-source">
      <label className="creative-upload">
        Import a photo<input
          type="file"
          accept="image/jpeg,image/png,image/webp"
          disabled={!!busy || !canCreate}
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) {
              void run(
                "Preparing photo",
                async () => chooseSource(await prepareImage(file, signal)),
              );
            }
            e.target.value = "";
          }}
        />
      </label>
      {photos.length > 0 && (
        <label>
          Or use a property photo<select
            aria-label="Source property photo"
            value=""
            disabled={!!busy}
            onChange={(e) => {
              const photo = photos.find((p) => p.id === e.target.value);
              if (
                photo &&
                (!(photo.isAltered || photo.isStaged) || photo.originalUrl)
              ) {
                void run("Opening photo", async () => {
                  await chooseSource(
                    await imageFromURL(
                      (photo.isAltered || photo.isStaged)
                        ? photo.originalUrl!
                        : photo.url,
                      `${photo.caption || "property"}.jpg`,
                      signal,
                    ),
                  );
                  setRoom(photo.caption || "");
                });
              }
            }}
          >
            <option value="">Choose a cloud photo</option>
            {photos.filter((p) =>
              (!p.isAltered && !p.isStaged) || !!p.originalUrl
            ).map((p, i) => (
              <option key={p.id} value={p.id}>
                {p.caption || `Photo ${i + 1}`}
                {p.isStaged ? " · AI edited" : ""}
              </option>
            ))}
          </select>
        </label>
      )}
      {source
        ? (
          <figure>
            <img src={source.preview} alt="Selected source property" />
            <figcaption>{source.file.name} · original preserved</figcaption>
          </figure>
        )
        : (
          <div className="creative-source-placeholder">
            Choose a photo from your phone's synced library or import one from
            your computer.
          </div>
        )}
      {source && (
        <label>
          Room or view<input
            maxLength={60}
            value={room}
            placeholder="For example, Kitchen or Front exterior"
            onChange={(e) => setRoom(e.target.value)}
          />
        </label>
      )}
    </div>
  );
  const photoSelection = (
    <fieldset className="creative-photo-picker">
      <legend>
        Photos in this story <span>{chosenPhotos.length} selected</span>
      </legend>
      {photos.length
        ? (
          <>
            <div className="creative-thumbnail-grid">
              {photos.slice(0, 100).map((photo, i) => (
                <label key={photo.id}>
                  <input
                    type="checkbox"
                    checked={selectedPhotos !== null
                      ? selectedPhotos.includes(photo.id)
                      : i < 20}
                    onChange={(e) => {
                      const current = selectedPhotos !== null
                        ? selectedPhotos
                        : photos.slice(0, 20).map((p) => p.id);
                      setSelectedPhotos(
                        e.target.checked
                          ? [...current, photo.id].slice(0, 20)
                          : current.filter((id) => id !== photo.id),
                      );
                    }}
                  />
                  <img
                    loading="lazy"
                    src={photo.url}
                    alt={photo.caption || `Property photo ${i + 1}`}
                  />
                  <span>{photo.caption || `Photo ${i + 1}`}</span>
                </label>
              ))}
            </div>
            {mediaOffset !== null && (
              <button
                disabled={!!busy}
                onClick={() =>
                  run("Loading more photos", () => loadPhotos(mediaOffset))}
              >
                Load more photos
              </button>
            )}
          </>
        )
        : (
          <p>
            Upload property photos in your listing to plan a reel around them.
          </p>
        )}
    </fieldset>
  );
  return (
    <>
      {toolbar}
      {restoreConflict && (
        <div className="creative-alert" role="alert">
          <p>
            This property also has a newer cloud draft. Your recovered edits are
            shown below; choose which version to keep.
          </p>
          {cloudDraft && (
            <details>
              <summary>Review the cloud version</summary>
              <p>{cloudDraft.script || "No script saved."}</p>
              <small>
                {cloudDraft.shots.length} planned shots ·{" "}
                {cloudDraft.chapters.length} room markers
              </small>
            </details>
          )}
          <div className="creative-actions">
            <button
              disabled={!!busy}
              onClick={() => {
                setRestoreConflict(false);
                setNotice(
                  "Your recovered draft is ready to save over the current cloud version.",
                );
              }}
            >
              Keep my recovered edits
            </button>
            <button
              disabled={!!busy}
              onClick={() => run("Opening cloud draft", () => loadDraft(true))}
            >
              Use the cloud draft
            </button>
            <button
              onClick={() =>
                downloadText(
                  "recovered-creative-draft.json",
                  JSON.stringify(currentDraft.current, null, 2),
                  "application/json",
                )}
            >
              Download recovered draft
            </button>
          </div>
        </div>
      )}
      <nav className="creative-tabs" aria-label="Creative tools">
        {PANELS.map((item) => (
          <button
            key={item.id}
            aria-current={panel === item.id ? "page" : undefined}
            onClick={() => setPanel(item.id)}
          >
            {item.label}
          </button>
        ))}
      </nav>
      {error && (
        <div className="creative-alert" role="alert">
          <p>{error}</p>
          <button
            disabled={!!busy}
            onClick={() => run("Reloading draft", () => loadDraft())}
          >
            Reload saved draft
          </button>
        </div>
      )}
      {notice && <p className="creative-notice" role="status">{notice}</p>}
      {busy && (
        <p className="creative-working" role="status">
          {busy}… Keep this tab open until the action is confirmed.
        </p>
      )}
      {!canCreate && (
        <p className="creative-notice">
          Your marketing role can review existing media. Ask an owner or admin
          for permission to create new media.
        </p>
      )}
      {panel === "photos" && (
        <div className="creative-two-column">
          {sourcePicker}
          <div className="creative-card">
            <h2>Bring out the best in every room</h2>
            <p>
              Preview the edit before adding it to the gallery. Every saved edit
              keeps its original and disclosure.
            </p>
            <div className="creative-preset-grid">
              {PRESETS.map((p) => (
                <button
                  key={p.id}
                  className={edit === p.id ? "selected" : ""}
                  onClick={() => setEdit(p.id)}
                >
                  <strong>{p.name}</strong>
                  <span>{p.hint}</span>
                </button>
              ))}
            </div>
            {edit === "stage" && (
              <label>
                Staging style<select
                  value={style}
                  onChange={(e) => setStyle(e.target.value)}
                >
                  {["modern", "rustic", "minimalist", "scandinavian"].map(
                    (s) => <option key={s}>{s}</option>,
                  )}
                </select>
              </label>
            )}
            {edit === "custom" && (
              <>
                <label>
                  Your edit<textarea
                    value={prompt}
                    maxLength={600}
                    onChange={(e) => setPrompt(e.target.value)}
                    placeholder="Brighten the room and remove the moving boxes."
                  />
                </label>
                <button
                  disabled={!!busy || !prompt.trim() || !canCreate}
                  onClick={() =>
                    run("Refining your edit", async () => {
                      const response = record(
                        await api("ai-copy/edit-prompt", {
                          rough: prompt.slice(0, 300),
                          room_hint: room,
                          listing_id: listingId,
                          space_type: listing.spaceType,
                        }, { idempotencyKey: crypto.randomUUID() }),
                      );
                      setPrompt(
                        requiredText(
                          response.prompt,
                          "an improved edit prompt",
                          600,
                        ),
                      );
                    })}
                >
                  Help me describe it
                </button>
              </>
            )}
            <div className="creative-actions">
              <button
                disabled={!source || !!busy || !canCreate}
                onClick={() =>
                  run("Finding suitable edits", async () => {
                    const response = record(
                      await api("ai-photo", {
                        image_b64: source!.base64,
                        mime: source!.mime,
                        edit: "suggest",
                        space_type: listing.spaceType,
                      }, {
                        idempotencyKey: crypto.randomUUID(),
                        timeoutMs: 180_000,
                      }),
                    );
                    setSuggestions(
                      rows(response.suggestions, 3).flatMap((raw) => {
                        const s = record(raw), id = text(s.edit, 30) as Edit;
                        return PRESETS.some((p) => p.id === id) &&
                            id !== "custom"
                          ? [{ edit: id, reason: text(s.reason, 400) }]
                          : [];
                      }),
                    );
                  })}
              >
                Suggest an edit
              </button>
              <button
                className="creative-primary"
                disabled={!source || !!busy || !canCreate}
                onClick={() => run("Creating your photo", generatePhoto)}
              >
                Generate preview
              </button>
            </div>
            <small>Uses the same photo allowance as your iPhone app.</small>
            {suggestions.map((s) => (
              <button
                className="creative-suggestion"
                key={s.edit}
                onClick={() => setEdit(s.edit)}
              >
                {PRESETS.find((p) => p.id === s.edit)?.name}
                <span>{s.reason}</span>
              </button>
            ))}
          </div>
          {photoResult && (
            <section className="creative-card creative-wide">
              <h2>Review your edit</h2>
              <div className="creative-comparison">
                <figure>
                  <img
                    src={source?.preview}
                    alt="Original photo before the edit"
                  />
                  <figcaption>Original</figcaption>
                </figure>
                <figure>
                  <img
                    src={photoResult.preview}
                    alt="AI edited photo preview"
                  />
                  <figcaption>AI edited preview</figcaption>
                </figure>
              </div>
              <p>{photoResult.disclosure}</p>
              <div className="creative-actions">
                <button
                  className="creative-primary"
                  disabled={!!busy || photoResult.saved ||
                    !photoResult.provenanceId}
                  onClick={() => run("Saving photo and original", savePhoto)}
                >
                  {photoResult.saved
                    ? "Saved to gallery"
                    : "Save to property gallery"}
                </button>
                <a href={photoResult.preview} download={photoResult.file.name}>
                  Download edited photo
                </a>
              </div>
            </section>
          )}
        </div>
      )}
      {panel === "copy" && (
        <div className="creative-two-column">
          <div className="creative-card">
            <h2>Tell the property's story</h2>
            <p>
              Your saved listing facts guide the writing. Review every detail
              before recording or publishing.
            </p>
            <div className="creative-form-row">
              <label>
                Tone<select
                  value={tone}
                  onChange={(e) => setTone(e.target.value)}
                >
                  {["warm", "punchy", "luxury"].map((t) => (
                    <option key={t}>{t}</option>
                  ))}
                </select>
              </label>
              <label>
                Length<select
                  value={targetSeconds}
                  onChange={(e) => setTargetSeconds(Number(e.target.value))}
                >
                  {[15, 20, 30, 45].map((n) => (
                    <option key={n} value={n}>{n} seconds</option>
                  ))}
                </select>
              </label>
            </div>
            {photoSelection}
            <div className="creative-actions">
              <button
                disabled={!!busy || !draftReady || !canCreate}
                onClick={() =>
                  run("Writing a script", () => generateCopy("script"))}
              >
                Write a script
              </button>
              <button
                className="creative-primary"
                disabled={!!busy || !draftReady || !chosenPhotos.length ||
                  !canCreate}
                onClick={() =>
                  run("Planning your shots", () => generateCopy("shotlist"))}
              >
                Plan my reel
              </button>
            </div>
          </div>
          <div className="creative-card">
            <h2>Your script</h2>
            <label className="creative-sr-only" htmlFor="creative-script">
              Property video script
            </label>
            <textarea
              id="creative-script"
              disabled={!draftReady}
              className="creative-script"
              value={draft.script}
              maxLength={4000}
              onChange={(e) =>
                updateDraft({ ...draft, script: e.target.value })}
              placeholder="Write your own script, or let Rendprop help you start."
            />
            <small>
              {draft.script.length} characters · voiceover limit 1,000
            </small>
            <div className="creative-actions">
              <button
                disabled={!!busy || !dirty || !draftReady}
                onClick={() => run("Saving script", () => saveDraft())}
              >
                Save script
              </button>
              <button
                disabled={!draft.script}
                onClick={() =>
                  downloadText("property-script.txt", draft.script)}
              >
                Download script
              </button>
              <button
                disabled={!draft.script}
                onClick={() => setPanel("voice")}
              >
                Add a voiceover →
              </button>
            </div>
          </div>
          {draft.shots.length > 0 && (
            <div className="creative-card creative-wide">
              <h2>Your reel, shot by shot</h2>
              <ol className="creative-shot-list">
                {draft.shots.map((shot) => (
                  <li key={shot.photoId}>
                    {photos.find((p) => p.id === shot.photoId) && (
                      <img
                        src={photos.find((p) => p.id === shot.photoId)!.url}
                        alt={shot.room || "Planned property photo"}
                      />
                    )}
                    <div>
                      <strong>
                        {shot.room || `Shot ${shot.order}`} · {shot.seconds}s
                      </strong>
                      <span>{shot.motion.replaceAll("_", " ")}</span>
                      <p>{shot.caption}</p>
                      <small>{shot.voiceLine}</small>
                    </div>
                  </li>
                ))}
              </ol>
              {onUseShotPlan && (
                <>
                  <p>
                    Bring these photos into the editor in the planned order,
                    with their durations and captions. You can adjust the
                    framing and add music before exporting.
                  </p>
                  {results.some((result) =>
                    result.kind === "voice" && result.state === "completed"
                  ) && (
                    <label>
                      Voiceover for this edit<select
                        value={planNarrationId}
                        onChange={(event) =>
                          setPlanNarrationId(event.target.value)}
                      >
                        <option value="">No voiceover yet</option>
                        {results.filter((result) =>
                          result.kind === "voice" &&
                          result.state === "completed"
                        ).map((result) => (
                          <option key={result.id} value={result.id}>
                            {result.voiceName || result.label ||
                              "Saved voiceover"}
                            {result.duration
                              ? ` · ${Math.round(result.duration)} seconds`
                              : ""}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                  <button
                    className="creative-primary"
                    disabled={!!busy || dirty || restoreConflict || !draftReady}
                    onClick={() =>
                      onUseShotPlan({
                        listingId,
                        shots: draft.shots.map((shot) => ({ ...shot })),
                        script: draft.script,
                        narrationResultId: planNarrationId || null,
                      })}
                  >
                    Use shot plan in editor
                  </button>
                  {dirty && (
                    <small>
                      Save your draft first so the editor uses the same plan as
                      your other devices.
                    </small>
                  )}
                </>
              )}
            </div>
          )}
          <details className="creative-card creative-wide">
            <summary>Plan an agent-on-camera reel</summary>
            <p>
              Use your real talking-head footage and a timed transcript.
              Rendprop plans when to show property photos while keeping your
              face at the opening and closing.
            </p>
            <label>
              Agent-on-camera video<select
                value={draft.agentAssetId || ""}
                disabled={!!busy || !draftReady}
                onChange={(event) => {
                  const asset = agentVideos.find((item) =>
                    item.id === event.target.value
                  );
                  updateDraft({
                    ...draft,
                    agentAssetId: asset?.id ?? null,
                    agentDuration: asset?.duration_s ?? null,
                    cutaways: [],
                  });
                }}
              >
                <option value="">Choose your saved spoken video</option>
                {agentVideos.map((asset) => (
                  <option key={asset.id} value={asset.id}>
                    Saved video ·{" "}
                    {new Date(asset.created_at).toLocaleString(undefined, {
                      month: "short",
                      day: "numeric",
                      hour: "numeric",
                      minute: "2-digit",
                    })}
                    {asset.duration_s != null
                      ? ` · ${Math.round(asset.duration_s)} seconds`
                      : ""}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Clip duration in seconds<input
                type="number"
                min={6}
                max={180}
                value={agentSeconds}
                disabled={!!busy || !draftReady ||
                  agentBase?.duration_s != null}
                onChange={(e) =>
                  updateDraft({
                    ...draft,
                    agentDuration: Number(e.target.value),
                    cutaways: [],
                  })}
              />
            </label>
            <label>
              Import subtitles (.srt or .vtt)<input
                type="file"
                accept=".srt,.vtt,text/vtt,application/x-subrip"
                disabled={!!busy || !draftReady || !agentBase}
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  event.target.value = "";
                  if (file) {
                    void run(
                      "Importing your timed subtitles",
                      () => importTranscript(file),
                    );
                  }
                }}
              />
            </label>
            <p>
              Import subtitles from your phone or video editor, then review the
              words below. You can also enter phrases with their actual start
              times. Studio uses these times to place the photos.
            </p>
            <label>
              Timed transcript<textarea
                value={draft.agentTranscript}
                disabled={!!busy || !draftReady}
                onChange={(e) =>
                  updateDraft({
                    ...draft,
                    agentTranscript: e.target.value,
                    cutaways: [],
                  })}
                maxLength={20000}
                placeholder={"0:00 Welcome to this property.\n0:04 The kitchen opens onto the patio.\n0:09 Upstairs are three bright bedrooms."}
              />
            </label>
            <button
              disabled={!!busy || !chosenPhotos.length || !canCreate ||
                !draftReady || !agentBase}
              onClick={() =>
                run("Planning your on-camera edit", generateAgentPlan)}
            >
              Create cutaway plan
            </button>
            {draft.cutaways.length > 0 && (
              <ol>
                {draft.cutaways.map((cutaway, index) => (
                  <li key={index}>
                    {cutaway.start.toFixed(1)}–{cutaway.end.toFixed(1)}s:{" "}
                    {photos.find((p) => p.id === cutaway.photoId)?.caption ||
                      "Property photo"}{" "}
                    {cutaway.caption && `· “${cutaway.caption}”`}
                  </li>
                ))}
              </ol>
            )}
            {draft.cutaways.length > 0 && onUseAgentPlan && (
              <>
                <p>
                  Your video and speaking audio continue underneath each photo.
                  Review the cutaway timing and captions in the editor.
                </p>
                <button
                  className="creative-primary"
                  disabled={!!busy || dirty || restoreConflict || !draftReady ||
                    !agentBase}
                  onClick={() =>
                    run("Opening your on-camera plan", async () => {
                      if (!agentBase) return;
                      onUseAgentPlan({
                        listingId,
                        assetId: agentBase.id,
                        cutaways: draft.cutaways.map((cutaway) => ({
                          ...cutaway,
                        })),
                        script: parseTranscript(
                          draft.agentTranscript,
                          agentSeconds,
                        ).map((phrase) => phrase.text).join(" "),
                      });
                    })}
                >
                  Use on-camera plan in editor
                </button>
                {!agentBase && (
                  <small>
                    Choose the original spoken video and create a new cutaway
                    plan before using this older saved plan.
                  </small>
                )}
              </>
            )}
          </details>
        </div>
      )}
      {panel === "voice" && (
        <div className="creative-two-column">
          <div className="creative-card">
            <h2>A voice for your property</h2>
            <p>
              Create narration from your reviewed script. The audio and timed
              captions are saved with this listing.
            </p>
            <label>
              Voice<select
                value={voiceId}
                onChange={(e) => setVoiceId(e.target.value)}
              >
                <option value="">
                  {voices.length ? "Choose a voice" : "Loading voices…"}
                </option>
                {voices.map((v) => (
                  <option key={v.id} value={v.id}>{v.name}</option>
                ))}
              </select>
            </label>
            {voices.find((v) => v.id === voiceId)?.description && (
              <p>{voices.find((v) => v.id === voiceId)!.description}</p>
            )}
            <label>
              Narration script<textarea
                className="creative-script"
                disabled={!draftReady}
                value={draft.script}
                maxLength={1000}
                onChange={(e) =>
                  updateDraft({ ...draft, script: e.target.value })}
              />
            </label>
            <small>{draft.script.length}/1,000 characters</small>
            <button
              className="creative-primary"
              disabled={!!busy || !voiceId || !draft.script.trim() ||
                draft.script.length > 1000 || !draftReady || !canCreate}
              onClick={() =>
                run("Creating and saving narration", generateVoice)}
            >
              Generate voiceover
            </button>
            <small>Uses the same narration allowance as your iPhone app.</small>
          </div>
          <div className="creative-card">
            <h2>Saved voiceovers</h2>
            {results.filter((r) => r.kind === "voice").length === 0
              ? (
                <p>
                  Your generated narration will appear here, ready to play or
                  download.
                </p>
              )
              : results.filter((r) => r.kind === "voice").map((result) => (
                <article className="creative-result" key={result.id}>
                  <h3>
                    {result.voiceName || result.label || "Property narration"}
                  </h3>
                  {result.url
                    ? (
                      <>
                        <audio controls src={result.url} preload="none" />
                        <div className="creative-actions">
                          <a href={result.url} target="_blank" rel="noreferrer">
                            Download audio
                          </a>
                          {result.words.length > 0 && (
                            <button
                              onClick={() =>
                                downloadText(
                                  "property-captions.srt",
                                  subtitleFile(result.words),
                                  "application/x-subrip",
                                )}
                            >
                              Download captions
                            </button>
                          )}
                        </div>
                      </>
                    )
                    : (
                      <p>
                        {result.message ||
                          "Your narration is still being confirmed."}
                      </p>
                    )}
                  <p className="creative-disclosure">{result.disclosure}</p>
                </article>
              ))}
          </div>
        </div>
      )}
      {panel === "video" && (
        <div className="creative-two-column">
          <div className="creative-card">
            <h2>Choose your video</h2>
            <label>
              What would you like to make?<select
                value={videoKind}
                onChange={(e) => setVideoKind(e.target.value)}
              >
                <option value="reel">Animate a property photo</option>
                <option value="aerial">Create an aerial-style intro</option>
                <option value="drone">Smooth and upscale drone footage</option>
                <option value="declutter">
                  Remove an object from a short clip
                </option>
              </select>
            </label>
            {videoKind === "reel" || videoKind === "aerial"
              ? sourcePicker
              : (
                <label>
                  Completed source video<select
                    value={videoAsset}
                    onChange={(e) => setVideoAsset(e.target.value)}
                  >
                    <option value="">Choose a cloud video</option>
                    {publicVideos.map((asset, i) => (
                      <option key={asset.id} value={asset.id}>
                        Video {i + 1}
                        {asset.duration_s ? ` · ${asset.duration_s}s` : ""}
                      </option>
                    ))}
                  </select>
                </label>
              )}
            {videoKind === "drone"
              ? (
                <label>
                  Output quality<select
                    value={tier}
                    onChange={(e) => setTier(e.target.value)}
                  >
                    <option value="1080p60">Smooth HD · 1080p at 60fps</option>
                    <option value="4k30">4K · 30fps</option>
                    <option value="4k60">Smooth 4K · 60fps</option>
                  </select>
                </label>
              )
              : videoKind === "reel"
              ? (
                <div className="creative-form-row">
                  <label>
                    Movement<select
                      value={motion}
                      onChange={(e) => setMotion(e.target.value)}
                    >
                      {[
                        "push_in",
                        "pull_back",
                        "orbit_left",
                        "orbit_right",
                        "tilt_up",
                        "tilt_down",
                        "static_parallax",
                        "rack_focus",
                      ].map((m) => (
                        <option key={m} value={m}>
                          {m.replaceAll("_", " ")}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Duration<select
                      value={seconds}
                      onChange={(e) => setSeconds(Number(e.target.value))}
                    >
                      {[3, 4, 5, 6, 8].map((n) => (
                        <option key={n} value={n}>{n} seconds</option>
                      ))}
                    </select>
                  </label>
                </div>
              )
              : null}
            {videoKind === "declutter" && (
              <p>
                Choose a clip shorter than five seconds. Review the result
                carefully before publishing.
              </p>
            )}
            <label>
              {videoKind === "declutter"
                ? "Object to remove"
                : "Direction (optional)"}
              <textarea
                maxLength={600}
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder={videoKind === "declutter"
                  ? "Remove the moving boxes beside the door."
                  : "Gentle, natural movement with the room unchanged."}
              />
            </label>
            <button
              className="creative-primary"
              disabled={!!busy || !canCreate}
              onClick={() => run("Starting your video", generateVideo)}
            >
              Generate video
            </button>
            <small>
              Uses this workspace's video allowance. Generated motion is
              reviewed before publishing.
            </small>
          </div>
          <div className="creative-card">
            <h2>Saved generations</h2>
            {results.filter((r) => r.kind === "video").length === 0
              ? (
                <p>
                  Your clips will appear here. Pending work stays with your
                  account when you move between devices.
                </p>
              )
              : results.filter((r) => r.kind === "video").map((result) => (
                <article className="creative-result" key={result.id}>
                  <div className="creative-result-title">
                    <h3>{result.label || "Property video"}</h3>
                    <span>{result.state.replaceAll("_", " ")}</span>
                  </div>
                  {result.url
                    ? (
                      <video
                        controls
                        playsInline
                        src={result.url}
                        preload="metadata"
                      />
                    )
                    : (
                      <p>
                        {result.message ||
                          "Generating your clip. Progress updates automatically while this tab is open."}
                      </p>
                    )}
                  <p className="creative-disclosure">{result.disclosure}</p>
                  <div className="creative-actions">
                    {result.url && (
                      <a href={result.url} target="_blank" rel="noreferrer">
                        Download clip
                      </a>
                    )}
                    {["processing", "importing"].includes(result.state) && (
                      <button
                        disabled={!!busy || pollBusy.current}
                        onClick={() =>
                          run("Checking video", async () => {
                            const raw = record(
                              await api("studio/video-status", {
                                result_id: result.id,
                              }, { timeoutMs: 180_000 }),
                            );
                            setResults((old) =>
                              old.map((r) =>
                                r.id === result.id
                                  ? decodeResult(raw.result)
                                  : r
                              )
                            );
                          })}
                      >
                        Check progress
                      </button>
                    )}
                    {result.url &&
                      ["reel", "aerial"].includes(result.videoKind ?? "") && (
                      <button
                        disabled={!!busy || result.qcPublishable}
                        onClick={() =>
                          run(
                            "Checking property accuracy",
                            () => reviewVideo(result),
                          )}
                      >
                        Review property accuracy
                      </button>
                    )}
                  </div>
                  {(quality[result.id] || result.qcRequired) && (
                    <p
                      className={result.qcPublishable
                        ? "creative-notice"
                        : "creative-alert"}
                    >
                      {result.qcMessage || quality[result.id]?.message}
                    </p>
                  )}
                  {result.assetId && (
                    <small>
                      Saved to this property's video library. Open the listing
                      to edit or publish it.
                    </small>
                  )}
                </article>
              ))}
          </div>
        </div>
      )}
      {panel === "chapters" && (
        <div className="creative-two-column">
          <div className="creative-card">
            <h2>Help buyers find each room</h2>
            <p>
              Review suggested room markers, then apply them to the matching
              tour.
            </p>
            <label>
              Walkthrough video<select
                value={chapterAsset}
                onChange={(e) => setChapterAsset(e.target.value)}
              >
                <option value="">Choose a completed walkthrough</option>
                {videos.map((asset, i) => (
                  <option value={asset.id} key={asset.id}>
                    Walkthrough {i + 1}
                    {asset.duration_s ? ` · ${asset.duration_s}s` : ""}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Maximum chapters<input
                type="number"
                min={1}
                max={24}
                value={maxChapters}
                onChange={(e) => setMaxChapters(Number(e.target.value))}
              />
            </label>
            <button
              className="creative-primary"
              disabled={!!busy || !chapterAsset || !canCreate || !draftReady}
              onClick={() =>
                run("Finding rooms in the walkthrough", generateChapters)}
            >
              Suggest room chapters
            </button>
          </div>
          <div className="creative-card">
            <h2>Review room markers</h2>
            {draft.chapters.length
              ? draft.chapters.map((chapter, index) => (
                <div className="creative-chapter" key={index}>
                  <label>
                    Start (seconds)<input
                      type="number"
                      min={0}
                      step={.1}
                      value={chapter.start_s}
                      onChange={(e) =>
                        updateDraft({
                          ...draft,
                          chapters: draft.chapters.map((c, i) =>
                            i === index
                              ? {
                                ...c,
                                start_s: Math.max(0, Number(e.target.value)),
                              }
                              : c
                          ),
                        })}
                    />
                  </label>
                  <label>
                    Room name<input
                      value={chapter.label}
                      maxLength={80}
                      onChange={(e) =>
                        updateDraft({
                          ...draft,
                          chapters: draft.chapters.map((c, i) =>
                            i === index ? { ...c, label: e.target.value } : c
                          ),
                        })}
                    />
                  </label>
                  <button
                    aria-label={`Remove ${chapter.label} chapter`}
                    onClick={() =>
                      updateDraft({
                        ...draft,
                        chapters: draft.chapters.filter((_, i) =>
                          i !== index
                        ),
                      })}
                  >
                    ×
                  </button>
                </div>
              ))
              : <p>Suggested chapters will appear here for your review.</p>}
            <button
              onClick={() =>
                updateDraft({
                  ...draft,
                  chapters: [...draft.chapters, {
                    start_s: 0,
                    label: "New room",
                    room_type: "other",
                    sort: draft.chapters.length,
                  }],
                })}
              disabled={draft.chapters.length >= 24}
            >
              Add room marker
            </button>
            {draft.chapters.length > 0 && (
              <>
                <label>
                  Apply to tour<select
                    value={chapterRender}
                    onChange={(e) => setChapterRender(e.target.value)}
                  >
                    <option value="">Choose the matching tour</option>
                    {matchingTours.map((render, i) => (
                      <option key={render.id} value={render.id}>
                        {render.slug || `Tour ${i + 1}`}
                      </option>
                    ))}
                  </select>
                </label>
                <button
                  className="creative-primary"
                  disabled={!!busy || !chapterRender || !canCreate}
                  onClick={() => run("Updating tour chapters", applyChapters)}
                >
                  Save chapters to tour
                </button>
              </>
            )}
          </div>
        </div>
      )}
      {panel === "coach" && (
        <div className="creative-card creative-coach">
          <h2>What would you like help with?</h2>
          <p>
            Get help with your property workflow or find your way around
            Rendprop.
          </p>
          <div className="creative-conversation" aria-live="polite">
            {conversation.map((item, index) => (
              <div key={index} className={`creative-message ${item.role}`}>
                <strong>{item.role === "user" ? "You" : "Rendprop"}</strong>
                <p>{item.content}</p>
              </div>
            ))}
          </div>
          <div className="creative-actions">
            {replies.map((reply) => (
              <button
                key={reply}
                disabled={!!busy}
                onClick={() => run("Asking Rendprop", () => askCoach(reply))}
              >
                {reply}
              </button>
            ))}
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void run("Asking Rendprop", () => askCoach());
            }}
          >
            <label>
              Your question<textarea
                value={question}
                maxLength={1200}
                onChange={(e) => setQuestion(e.target.value)}
                placeholder="What should I do next with this listing?"
              />
            </label>
            <button
              className="creative-primary"
              disabled={!!busy || !question.trim()}
            >
              Ask Rendprop
            </button>
          </form>
          <a
            href="https://rendprop.com/support"
            target="_blank"
            rel="noreferrer"
          >
            Contact support
          </a>
        </div>
      )}
    </>
  );
}
