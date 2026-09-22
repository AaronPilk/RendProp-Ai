import type { StudioServices } from "../../data/services";
import { uuid } from "../../data/contracts";

export type UploadRole = "capture" | "render" | "original" | "gallery";
export type UploadJournal = {
  version: 1; userId: string; orgId: string; listingId: string; filename: string;
  bytes: number; contentType: string; role: UploadRole; fingerprint: string;
  operationId: string; assetId?: string; storageKey?: string;
  purpose?: "media" | "master" | "floorplan";
  parts: { number: number; etag: string }[]; updatedAt: string;
};
export type UploadedAsset = { assetId: string; storageKey: string; contentType: string; kind: "photo" | "video"; durationSeconds: number | null };
type Ticket = { assetId: string; storageKey: string; mode: "single" | "multipart"; uploaded: boolean; putURL?: string; partSize?: number; partCount?: number; confirmed: { number: number; etag: string }[] };
export type UploadOptions = {
  orgId: string; listingId: string; file: File; role?: UploadRole; signal?: AbortSignal;
  onProgress?: (loaded: number, total: number) => void;
  metadata?: { duration_s?: number; width?: number; height?: number };
  resume?: UploadJournal; onJournal?: (journal: UploadJournal) => void;
};
const VIDEO = new Map([["mp4", "video/mp4"], ["mov", "video/quicktime"], ["m4v", "video/x-m4v"]]);
const PHOTO = new Map([["jpg", "image/jpeg"], ["jpeg", "image/jpeg"], ["png", "image/png"], ["webp", "image/webp"], ["heic", "image/heic"], ["heif", "image/heif"]]);
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("The upload server returned an incomplete receipt. Resume this upload to check its status.");
  return value as Record<string, unknown>;
}
function stopped(signal?: AbortSignal) { if (signal?.aborted) throw new DOMException("Upload paused", "AbortError"); }
export function validateUpload(file: Pick<File, "name" | "size" | "type">, role: UploadRole = "capture") {
  const ext = file.name.split(".").at(-1)?.toLowerCase() ?? "";
  const contentType = VIDEO.get(ext) ?? PHOTO.get(ext);
  if (!contentType) throw new Error("Choose a JPG, PNG, WebP, HEIC, MP4, MOV, or M4V file.");
  const kind = VIDEO.has(ext) ? "video" as const : "photo" as const;
  if (kind === "video" && ["original", "gallery"].includes(role)) throw new Error("Choose a photo for this action.");
  if (kind === "photo" && role !== "capture" && ["image/heic", "image/heif"].includes(contentType)) throw new Error("Export this photo as JPG, PNG, or WebP before publishing it.");
  const maximum = kind === "video" ? 2 * 1024 ** 3 : role === "render" || role === "gallery" ? 10 * 1024 ** 2 : 50 * 1024 ** 2;
  if (!Number.isSafeInteger(file.size) || file.size < 1 || file.size > maximum) throw new Error(`Choose a file smaller than ${kind === "video" ? "2 GB" : maximum === 10 * 1024 ** 2 ? "10 MB" : "50 MB"}.`);
  if (file.type && file.type !== contentType && !(contentType === "video/x-m4v" && file.type === "video/mp4")) throw new Error("The filename and media type disagree. Export the file again before uploading.");
  return { kind, contentType };
}

/** Hash every byte in bounded chunks. A resume must match the complete file, including its middle. */
export async function fingerprintFile(file: Blob, signal?: AbortSignal): Promise<string> {
  const hashes: number[] = [];
  for (let start = 0; start < file.size; start += 8 * 1024 ** 2) {
    stopped(signal);
    const chunk = await file.slice(start, start + 8 * 1024 ** 2).arrayBuffer();
    hashes.push(...new Uint8Array(await crypto.subtle.digest("SHA-256", chunk)));
  }
  stopped(signal);
  const final = await crypto.subtle.digest("SHA-256", new Uint8Array(hashes));
  return [...new Uint8Array(final)].map((v) => v.toString(16).padStart(2, "0")).join("");
}
function receiptParts(value: unknown, count: number) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error("The server could not verify uploaded parts.");
  const parts = value.map((raw) => {
    const p = object(raw);
    if (!Number.isInteger(p.number) || Number(p.number) < 1 || Number(p.number) > count || typeof p.etag !== "string" || !p.etag || p.etag.length > 256) throw new Error("The server could not verify uploaded parts.");
    return { number: Number(p.number), etag: p.etag };
  });
  if (new Set(parts.map((p) => p.number)).size !== parts.length) throw new Error("The server returned duplicate upload receipts.");
  return parts;
}
function ticket(raw: unknown, options: UploadOptions): Ticket {
  const row = object(raw);
  const assetId = uuid(row.asset_id);
  const storageKey = String(row.storage_key ?? "");
  const bucket = (options.role ?? "capture") === "capture" ? "uploads" : "renders";
  if (!storageKey.startsWith(`${bucket}/${options.orgId}/${options.listingId}/`) || storageKey.includes("..") || storageKey.length > 1024) throw new Error("The upload does not belong to this property.");
  if (!["single", "multipart"].includes(String(row.mode))) throw new Error("The server returned an unsupported upload mode.");
  const count = Number(row.part_count), size = Number(row.part_size);
  if (row.mode === "multipart" && (!Number.isInteger(count) || count < 1 || count > 384 || !Number.isSafeInteger(size) || size < 5 * 1024 ** 2 || size > 64 * 1024 ** 2 || Math.ceil(options.file.size / size) !== count)) throw new Error("The server returned an invalid upload layout.");
  if (row.uploaded !== true && row.mode === "single" && typeof row.put_url !== "string") throw new Error("The upload link is unavailable. Resume to request a fresh link.");
  return { assetId, storageKey, mode: row.mode as Ticket["mode"], uploaded: row.uploaded === true, putURL: typeof row.put_url === "string" ? row.put_url : undefined, partSize: size, partCount: count, confirmed: receiptParts(row.confirmed_parts, count) };
}

export async function uploadListingAsset(services: StudioServices, options: UploadOptions): Promise<UploadedAsset> {
  const { file, orgId, listingId, signal, onProgress } = options;
  uuid(orgId); uuid(listingId);
  const actor = services.getSnapshot();
  const userId = actor.identity?.userId;
  if (!userId || actor.status !== "signed-in" || actor.identity?.isAnonymous) throw new Error("Sign in to upload to your workspace.");
  const assertActor = () => { stopped(signal); if (services.getSnapshot().identityVersion !== actor.identityVersion) throw new Error("Your account changed. Reopen this property before uploading."); };
  const role = options.role ?? "capture";
  const { kind, contentType } = validateUpload(file, role);
  const fingerprint = await fingerprintFile(file, signal);
  assertActor();
  let journal: UploadJournal = options.resume ?? { version: 1, userId, orgId, listingId, filename: file.name, bytes: file.size, contentType, role, fingerprint, operationId: crypto.randomUUID(), parts: [], updatedAt: new Date().toISOString() };
  if (journal.version !== 1 || journal.userId !== userId || journal.orgId !== orgId || journal.listingId !== listingId || journal.bytes !== file.size || journal.contentType !== contentType || journal.role !== role || journal.fingerprint !== fingerprint) throw new Error("This file does not match the paused upload. Select the original file to resume.");
  const persist = () => { assertActor(); journal = { ...journal, updatedAt: new Date().toISOString(), parts: [...journal.parts] }; options.onJournal?.(journal); };
  persist();
  const api = (path: string, body: unknown, idempotencyKey?: string) => services.api(`/functions/v1/uploads${path}`, { method: "POST", orgId, body, signal, idempotencyKey, timeoutMs: 120_000 });
  const raw = journal.assetId
    ? await api(`/${uuid(journal.assetId)}/renew`, {})
    : await api("", { listing_id: listingId, filename: file.name, bytes: file.size, kind, role, content_type: contentType }, `studio-upload:${journal.operationId}`);
  assertActor();
  const current = ticket(raw, options);
  let completedStorageKey = current.storageKey;
  if (journal.assetId && journal.assetId !== current.assetId) throw new Error("The resumed upload returned a different file. Reopen this property.");
  journal = { ...journal, assetId: current.assetId, storageKey: current.storageKey };
  persist();
  if (!current.uploaded) {
    if (current.mode === "single") {
      await services.upload(current.putURL!, file, { orgId, signal, contentType, onProgress });
      assertActor();
    } else {
      // Renewal uses the server's journal, including parts whose browser response was lost.
      const confirmed = new Map(current.confirmed.map((p) => [p.number, p.etag]));
      journal.parts = current.confirmed;
      persist();
      let loaded = [...confirmed.keys()].reduce((total, number) => total + Math.min(current.partSize!, file.size - (number - 1) * current.partSize!), 0);
      onProgress?.(loaded, file.size);
      for (let number = 1; number <= current.partCount!; number += 1) {
        assertActor();
        if (confirmed.has(number)) continue;
        const response = object(await api(`/${current.assetId}/part-urls`, { numbers: [number] }));
        const urls = Array.isArray(response.urls) ? response.urls : [];
        const part = urls.length === 1 ? object(urls[0]) : {};
        if (part.number !== number || typeof part.url !== "string") throw new Error("The server could not prepare the next part. Resume this upload.");
        const bytes = file.slice((number - 1) * current.partSize!, Math.min(number * current.partSize!, file.size), contentType);
        const uploaded = await services.upload(part.url, bytes, { orgId, signal, contentType, onProgress: (n) => onProgress?.(loaded + n, file.size) });
        assertActor();
        if (!uploaded.etag) throw new Error("The server stored a part but its receipt was unavailable. Resume to recover it.");
        journal.parts = [...journal.parts, { number, etag: uploaded.etag }].sort((a, b) => a.number - b.number);
        persist();
        loaded += bytes.size;
        onProgress?.(loaded, file.size);
      }
    }
    const completed = object(await api(`/${current.assetId}/complete`, { ...(current.mode === "multipart" ? { parts: journal.parts } : {}), bytes: file.size, ...options.metadata }, `complete:${current.assetId}`));
    assertActor();
    // Single-part completion promotes the object to an immutable operation key.
    // Trust the confirmed same-asset receipt, not the reservation's earlier key.
    const storageKey = String(completed.storage_key ?? "");
    const bucket = role === "capture" ? "uploads" : "renders";
    if (completed.id !== current.assetId || completed.uploaded !== true || completed.listing_id !== listingId ||
      !storageKey.startsWith(`${bucket}/${orgId}/${listingId}/`) || storageKey.includes("..") || storageKey.length > 1024 || /[\\?#\u0000-\u001f]/.test(storageKey)) throw new Error("Upload confirmation is still pending. Resume to check its status before publishing.");
    completedStorageKey = storageKey;
    journal = {...journal,storageKey};persist();
  }
  assertActor();
  onProgress?.(file.size, file.size);
  return { assetId: current.assetId, storageKey: completedStorageKey, contentType, kind, durationSeconds: options.metadata?.duration_s ?? null };
}

export async function cancelListingUpload(services: StudioServices, journal: UploadJournal, signal?: AbortSignal): Promise<void> {
  if (!journal.assetId) return;
  if (services.getSnapshot().identity?.userId !== journal.userId) throw new Error("Sign in to the account that started this upload.");
  const result = object(await services.api(`/functions/v1/uploads/${uuid(journal.assetId)}/abort`, { method: "POST", orgId: journal.orgId, body: {}, signal }));
  if (result.ok !== true || result.upload_aborted !== true) throw new Error("Cancellation could not be confirmed. Keep this upload and retry.");
}
