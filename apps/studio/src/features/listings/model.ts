import type { Listing } from "../../data/contracts";
import { uuid } from "../../data/contracts";
export type Asset = { id: string; listing_id: string; storage_key: string; kind: string; bucket: string; uploaded: boolean; duration_s: number | null; bytes?: number; created_at: string; qc_required?: boolean; qc_publishable?: boolean; qc_message?: string | null };
export type Job = { id: string; listing_id: string; capture_asset_id: string; status: string; progress: number; current_step: string | null; tier: string; error: string | null; created_at: string };
export type Published = { id: string; listing_id: string; job_id: string; slug: string; published_at: string | null; duration_s: number | null; staged: boolean; created_at: string };
export type Chapter = { label: string; t_ms: number; sort: number; asset_id?: string };
export type GalleryPhoto = { id: string; listing_id: string; original_key: string | null; enhanced_key: string | null; caption: string | null; is_staged: boolean; is_main: boolean; sort: number; created_at: string };
export type ListingState = { assets: Asset[]; jobs: Job[]; renders: Published[]; photos: GalleryPhoto[]; chapters: Chapter[]; nextOffset: number | null };
export const EMPTY_STATE: ListingState = { assets: [], jobs: [], renders: [], photos: [], chapters: [], nextOffset: null };
export function orderedGallery(photos: GalleryPhoto[]): GalleryPhoto[] { return [...photos].sort((a, b) => a.sort - b.sort || a.id.localeCompare(b.id)); }
export function canPublishAsset(asset: Asset): boolean { return asset.qc_required !== true || asset.qc_publishable === true; }
export function safeHTTPS(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 4096) return null;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password ? url.href : null; } catch { return null; }
}
export function decodeListingState(raw: unknown, orgId: string, listingId: string, offset = 0): ListingState {
  if (!raw || typeof raw !== "object") throw new Error("Property activity is temporarily unavailable.");
  const row = raw as Record<string, unknown>;
  if (row.org_id !== orgId || row.listing_id !== listingId) throw new Error("The property changed. Reopen it to continue.");
  const rows = <T,>(key: string): T[] => {
    if (!Array.isArray(row[key]) || row[key].length > 100) throw new Error("Property activity is incomplete. Refresh to try again.");
    return row[key].map((value: Record<string, unknown>) => {
      if (!value || value.listing_id !== listingId) throw new Error("The server returned activity from another property.");
      uuid(value.id);
      return value as T;
    });
  };
  const assets = rows<Asset>("assets");
  for (const asset of assets) {
    if (!["uploads", "renders"].includes(asset.bucket) || !["photo", "video"].includes(asset.kind) || typeof asset.storage_key !== "string" || !asset.storage_key.startsWith(`${asset.bucket}/${orgId}/${listingId}/`) || asset.storage_key.includes("..")) throw new Error("A media item could not be verified.");
    if (asset.qc_required !== undefined && typeof asset.qc_required !== "boolean" || asset.qc_publishable !== undefined && typeof asset.qc_publishable !== "boolean" || asset.qc_message != null && (typeof asset.qc_message !== "string" || asset.qc_message.length > 1000)) throw new Error("This video’s accuracy review could not be verified.");
  }
  const photos = row.photos === undefined ? [] : rows<GalleryPhoto>("photos");
  for (const photo of photos) {
    if (photo.caption !== null && (typeof photo.caption !== "string" || photo.caption.length > 4000) || typeof photo.is_staged !== "boolean" || typeof photo.is_main !== "boolean" || !Number.isInteger(photo.sort) || photo.sort < -32768 || photo.sort > 32767) throw new Error("Gallery details could not be verified.");
    for (const key of [photo.original_key, photo.enhanced_key]) if (key !== null && (typeof key !== "string" || !["uploads", "renders"].some(bucket => key.startsWith(`${bucket}/${orgId}/${listingId}/`)) || key.length > 1024 || key.includes("..") || /[?#\\]/.test(key))) throw new Error("A gallery photo could not be verified.");
  }
  const nextOffset = row.next_offset;
  if (nextOffset !== null && (!Number.isSafeInteger(nextOffset) || nextOffset !== offset + 100)) throw new Error("Property activity pagination changed. Refresh to try again.");
  const chapters: Chapter[] = Array.isArray(row.chapters) ? row.chapters.map((c: Record<string, unknown>) => {
    if (typeof c.label !== "string" || c.label.length > 80 || !Number.isInteger(c.t_ms) || Number(c.t_ms) < 0 || Number(c.t_ms) > 86_400_000) throw new Error("Saved chapters could not be read.");
    return { label: c.label, t_ms: Number(c.t_ms), sort: Number(c.sort) || 0, asset_id: typeof c.asset_id === "string" ? uuid(c.asset_id) : undefined };
  }) : [];
  return { assets, jobs: rows<Job>("jobs"), renders: rows<Published>("renders"), photos, chapters, nextOffset: nextOffset as number | null };
}
export function listingPayload(values: FormData, existing?: Listing): Record<string, unknown> {
  const text = (key: string, max = 500) => String(values.get(key) ?? "").trim().slice(0, max) || null;
  const number = (key: string, integer = false): number | null => {
    const value = text(key);
    if (value === null) return null;
    const n = Number(value);
    if (!Number.isFinite(n) || n < 0 || (integer && !Number.isInteger(n))) throw new Error(`Enter a valid ${key.replaceAll("_", " ")}.`);
    return n;
  };
  const address = text("address");
  if (!address) throw new Error("Give this property an address or name.");
  const price = number("price");
  const baths = number("baths");
  if (baths !== null && baths > 99) throw new Error("Bathrooms must be 99 or fewer.");
  return { address, tagline: text("tagline"), space_type: text("space_type"), beds: number("beds", true), baths, sqft: number("sqft", true), price_cents: price === null ? null : Math.round(price * 100), ...(existing ? {} : { status: "draft", source: "manual" }) };
}
export function parseChapterText(text: string, durationSeconds?: number | null): Chapter[] {
  const lines = text.split("\n").filter((line) => line.trim());
  if (lines.length > 60) throw new Error("A tour can have up to 60 room chapters.");
  const chapters = lines.map((line, sort) => {
    const match = /^\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\s+(.+?)\s*$/.exec(line);
    if (!match || Number(match[3]) > 59 || (match[1] && Number(match[2]) > 59)) throw new Error(`Use a time and room name, such as 0:12 Kitchen (line ${sort + 1}).`);
    const t_ms = (Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3])) * 1000;
    if (match[4].length > 80 || (durationSeconds && t_ms > durationSeconds * 1000)) throw new Error(`Chapter ${sort + 1} is too long or starts after the video ends.`);
    return { label: match[4], t_ms, sort };
  });
  if (chapters.some((chapter, index) => index > 0 && chapter.t_ms <= chapters[index - 1].t_ms)) throw new Error("Keep room chapters in time order with a different time for each room.");
  return chapters;
}
export function formatChapters(chapters: Chapter[]) {
  return [...chapters].sort((a, b) => a.t_ms - b.t_ms).map((c) => `${Math.floor(c.t_ms / 60_000)}:${String(Math.floor(c.t_ms / 1000) % 60).padStart(2, "0")} ${c.label}`).join("\n");
}
export function tourLinks(slug: string): { branded: string; unbranded: string } | null {
  if (!/^[a-zA-Z0-9_-]{1,160}$/.test(slug)) return null;
  return { branded: `https://rendprop.com/f/${encodeURIComponent(slug)}`, unbranded: `https://rendprop.com/u/${encodeURIComponent(slug)}` };
}
