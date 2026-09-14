import { useEffect, useRef, useState } from "react";
import type { Listing, StudioPhoto, StudioVideo, Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import type { VideoEditorProps } from "../../editor/VideoEditor";
import { EDIT_LIMITS } from "../../editor/model";

export type ReelMedia = { id: string; listingId: string; kind: "photo" | "video"; url: string; label: string; altered: boolean; seconds?: number | null };
export function validateReelMediaPage(offset: number, nextOffset: number | null) {
  if (offset < 0 || offset % 50 !== 0 || offset > 10000 || nextOffset !== null && (nextOffset !== offset + 50 || nextOffset > 10000)) throw new Error("The property media could not be read completely. Refresh and try again.");
}
export function reelMediaItems(photos: readonly StudioPhoto[], videos: readonly StudioVideo[], listingId: string): ReelMedia[] {
  if ([...photos, ...videos].some(item => item.listingId !== listingId)) throw new Error("These files belong to another property. Refresh the photos.");
  return [
    ...photos.map((photo, index) => ({ id: photo.id, listingId, kind: "photo" as const, url: photo.url, label: photo.caption || `Photo ${index + 1}`, altered: !!(photo.isAltered || photo.isStaged) })),
    ...videos.map((video, index) => ({ id: video.id, listingId, kind: "video" as const, url: video.url, label: `Video ${index + 1}`, seconds: video.durationSeconds, altered: false })),
  ];
}
/** Download the actual selected bytes. Never re-encode a thumbnail or forward
 * account credentials to a signed storage URL. The editor verifies their full
 * fingerprint and media limits again before adding anything to its sequence. */
export async function downloadReelMedia(item: ReelMedia, remainingBytes: number, signal: AbortSignal, fetcher: typeof fetch = fetch): Promise<File> {
  signal.throwIfAborted();
  if (!Number.isSafeInteger(remainingBytes) || remainingBytes < 0 || remainingBytes > EDIT_LIMITS.totalBytes) throw new Error("The edit’s remaining media limit could not be checked. Reopen the media picker.");
  const limit = Math.min(EDIT_LIMITS.fileBytes, remainingBytes);
  if (limit <= 0) throw new Error("This edit has reached its 512 MiB media limit. Remove a clip before adding more.");
  const response = await fetcher(item.url, { signal, credentials: "omit", redirect: "error", cache: "no-store", referrerPolicy: "no-referrer" });
  if (!response.ok || !response.body) throw new Error("This media link expired. Refresh the property photos and try again.");
  const mime = response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() || "";
  const extension = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v" } as Record<string, string>)[mime];
  const declared = Number(response.headers.get("content-length"));
  if (!extension || !mime.startsWith(item.kind === "photo" ? "image/" : "video/") || declared > limit) {
    void response.body.cancel().catch(() => {});
    throw new Error(!extension || !mime.startsWith(item.kind === "photo" ? "image/" : "video/") ? "Use a JPG, PNG, WebP, MP4 or MOV copy of this file for the reel." : "This file exceeds the edit’s remaining media limit (128 MiB per file; 512 MiB total).");
  }
  const chunks: Uint8Array<ArrayBuffer>[] = [], reader = response.body.getReader(); let bytes = 0;
  try {
    for (;;) {
      signal.throwIfAborted();
      const { done, value } = await reader.read(); signal.throwIfAborted(); if (done) break;
      bytes += value.byteLength;
      if (bytes > limit) throw new Error("This file exceeds the edit’s remaining media limit (128 MiB per file; 512 MiB total).");
      chunks.push(new Uint8Array(value));
    }
  } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
  if (!bytes || declared > 0 && bytes !== declared) throw new Error("The file download was incomplete. Refresh and select it again.");
  const name = item.label.replace(/[\\/\u0000-\u001f]/g, "-").replace(/\.[^.]+$/, "").slice(0, 100) || "property-media";
  return new File(chunks, `${name}.${extension}`, { type: mime, lastModified: 0 });
}
export async function downloadReelSelection(items: readonly ReelMedia[], listingId: string, remainingBytes: number, signal: AbortSignal, assertScope: () => void, progress: (index: number) => void, download = downloadReelMedia): Promise<NonNullable<VideoEditorProps["importRequest"]>> {
  if (!items.length || items.length > EDIT_LIMITS.clips || new Set(items.map(item => item.id)).size !== items.length || items.some(item => item.listingId !== listingId)) throw new Error("Choose up to 12 different files from this property.");
  const files: File[] = [];
  for (const [index, item] of items.entries()) {
    signal.throwIfAborted(); assertScope(); progress(index + 1);
    const file = await download(item, remainingBytes, AbortSignal.any([signal, AbortSignal.timeout(120_000)]));
    signal.throwIfAborted(); assertScope(); files.push(file); remainingBytes -= file.size;
  }
  assertScope();
  return { id: crypto.randomUUID(), listingId, files, sourceMedia: items.map(item => ({ id: item.id, kind: item.kind })) };
}

type Props = {
  services: StudioServices; workspace: Workspace; listing: Listing;
  availableSlots: number; remainingBytes: number; disabled?: boolean;
  onImport: (request: NonNullable<VideoEditorProps["importRequest"]>) => void | Promise<void>;
  onClose: () => void;
};
export default function ReelMediaPicker(props: Props) {
  return <ReelMediaPickerContent key={`${props.workspace.user.id}:${props.workspace.org.id}:${props.listing.id}`} {...props} />;
}
function ReelMediaPickerContent({ services, workspace, listing, availableSlots, remainingBytes, disabled, onImport, onClose }: Props) {
  const [items, setItems] = useState<ReelMedia[]>([]), [selected, setSelected] = useState<string[]>([]), [offset, setOffset] = useState<number | null>(null);
  const [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null), [progress, setProgress] = useState(0), [downloading, setDownloading] = useState(false);
  const alive = useRef(true), controller = useRef(new AbortController()), downloadController = useRef<AbortController | null>(null), loadingRef = useRef(false), downloadRef = useRef(false);
  const identityVersion = useRef(services.getSnapshot().identityVersion).current;
  function assertScope() {
    const actor = services.getSnapshot();
    if (!alive.current || actor.identityVersion !== identityVersion || actor.status !== "signed-in" || actor.identity?.userId !== workspace.user.id || listing.orgId !== workspace.org.id) throw new Error("Your account changed. Reopen the property to choose its media.");
  }
  async function load(nextOffset = 0) {
    if (loadingRef.current || downloadRef.current) return;
    loadingRef.current = true; setLoading(true); setError(null);
    try {
      assertScope();
      const media = await services.listMedia(workspace.org.id, listing.id, controller.current.signal, nextOffset);
      assertScope();
      if (media.orgId !== workspace.org.id || media.listingId !== listing.id) throw new Error("These files belong to another property. Refresh the photos.");
      validateReelMediaPage(nextOffset, media.nextOffset);
      const page = reelMediaItems(media.photos, media.videos, listing.id);
      setItems(old => nextOffset ? [...old, ...page.filter(item => !old.some(previous => previous.id === item.id))] : page);
      setOffset(media.nextOffset);
      if (!nextOffset) setSelected([]);
    } catch (reason) { if (alive.current && !controller.current.signal.aborted) setError(reason instanceof Error ? reason.message : "Property media could not be opened."); }
    finally { loadingRef.current = false; if (alive.current) setLoading(false); }
  }
  useEffect(() => {
    alive.current = true; controller.current = new AbortController(); void load();
    const unsubscribe = services.subscribe(snapshot => {
      if (snapshot.identityVersion !== identityVersion) {
        controller.current.abort(); downloadController.current?.abort();
        if (alive.current) { setItems([]); setSelected([]); setError("Your account changed. Reopen the property to choose its media."); }
      }
    });
    return () => { alive.current = false; controller.current.abort(); downloadController.current?.abort(); unsubscribe(); };
  }, [services, workspace.user.id, workspace.org.id, listing.id]);
  async function add() {
    if (downloadRef.current || loadingRef.current || disabled || !selected.length || selected.length > availableSlots) return;
    downloadRef.current = true; const abort = new AbortController(); downloadController.current = abort;
    setDownloading(true); setError(null);
    try {
      const chosen = selected.map(id => items.find(item => item.id === id)).filter((item): item is ReelMedia => !!item);
      if (chosen.length !== selected.length) throw new Error("A selected file changed. Refresh the property media.");
      const request = await downloadReelSelection(chosen, listing.id, remainingBytes, AbortSignal.any([controller.current.signal, abort.signal]), assertScope, setProgress);
      assertScope(); await onImport(request); assertScope();
    } catch (reason) { if (alive.current) setError(abort.signal.aborted ? "Import cancelled. The current edit is unchanged." : reason instanceof Error ? reason.message : "The selected media could not be opened."); }
    finally { downloadRef.current = false; downloadController.current = null; if (alive.current) setDownloading(false); }
  }
  return <section className="panel reel-media-picker" aria-label="Choose property photos and video">
    <header className="reel-media-picker-heading"><div><h3>Choose photos & video</h3><p><strong>{listing.address || listing.tagline || "Your property"}</strong> · Uploaded from your phone or saved in Studio.</p></div><button onClick={() => { downloadController.current?.abort(); onClose(); }}>Close media picker</button></header>
    <p>Tap files in the order you want them. {Math.max(0, availableSlots)} of 12 clip spaces available. Adding files keeps your current sequence.</p>
    {error && <p role="alert" className="creative-alert">{error}</p>}
    {!items.length && !loading && <p>Open this property on your iPhone, capture photos or a walkthrough, and finish the upload. Then refresh here. You can also use “Add photos or videos” in the editor to choose computer files.</p>}
    <div className="reel-media-grid">{items.map(item => <label className="reel-media-choice" key={item.id}><input type="checkbox" checked={selected.includes(item.id)} disabled={downloading || loading || !!disabled || !selected.includes(item.id) && selected.length >= availableSlots} onChange={event => setSelected(ids => event.target.checked ? [...ids, item.id] : ids.filter(id => id !== item.id))} />{item.kind === "photo" ? <img src={item.url} alt="" loading="lazy" referrerPolicy="no-referrer" /> : <video src={item.url} preload="metadata" muted playsInline />}<span>{selected.includes(item.id) ? `${selected.indexOf(item.id) + 1}. ` : ""}{item.label}{item.seconds ? ` · ${Math.round(item.seconds)} sec` : ""}</span>{item.altered && <small>AI edited</small>}</label>)}</div>
    <div className="reel-media-picker-actions"><button disabled={loading || downloading || !!disabled} onClick={() => void load()}>Refresh property media</button>{offset !== null && <button disabled={loading || downloading || !!disabled} onClick={() => void load(offset)}>Load more files</button>}{downloading ? <><p role="status">Opening file {progress} of {selected.length}…</p><button onClick={() => downloadController.current?.abort()}>Cancel media import</button></> : <button className="primary" disabled={loading || !!disabled || !selected.length || selected.length > availableSlots} onClick={() => void add()}>Add {selected.length || "selected"} {selected.length === 1 ? "file" : "files"} to reel</button>}</div>
    {loading && <p role="status">Loading property media…</p>}
    <small>Uses your existing media. Choosing these files does not run AI generation. Source files must fit the editor’s 128 MiB per-file and 512 MiB total limits.</small>
  </section>;
}
