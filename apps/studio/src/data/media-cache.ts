import type { ListingMedia } from "./contracts";

/** Private media links live ten minutes. A link with at least this much life
 * left is kept when the same saved object is read again, so the browser does
 * not download a photo it is already showing. */
export const LINK_KEEP_MS = 4 * 60_000;
/** Read fresh links before the oldest one shown gets this close to expiry. */
export const LINK_RENEW_MS = 3 * 60_000;
const MAX_REMEMBERED = 24;

/** The stored object behind a signed link, without its signature or expiry.
 * An unreadable link has no identity and is never reused. */
export function mediaObject(url: string): string {
  try {
    const parsed = new URL(url);
    const match = /^\/private-media\/([A-Za-z0-9_-]+)\.[a-f0-9]{64}$/.exec(parsed.pathname);
    if (!match) return parsed.origin + parsed.pathname;
    const bytes = Uint8Array.from(atob(match[1].replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
    const capability = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as { bucket?: unknown; key?: unknown };
    return typeof capability?.bucket === "string" && typeof capability.key === "string" && capability.key
      ? `${capability.bucket}/${capability.key}` : "";
  } catch { return ""; }
}
function sameObject(a: string, b: string): boolean {
  const identity = mediaObject(a);
  return identity !== "" && identity === mediaObject(b);
}

/** Earliest link expiry in a media set; Infinity when it holds no links. */
export function earliestExpiry(media: ListingMedia): number {
  let earliest = Infinity;
  for (const item of [...media.photos, ...media.videos]) earliest = Math.min(earliest, Date.parse(item.expiresAt));
  return Number.isFinite(earliest) || earliest === Infinity ? earliest : 0;
}

/** The server's new answer decides WHAT is shown. For an item it still lists,
 * pointing at the same saved object, keep the link already on screen while that
 * link has comfortable life left. Anything new, changed or aging takes the new link. */
export function retainFreshLinks(previous: ListingMedia | null, next: ListingMedia, now = Date.now()): ListingMedia {
  if (!previous || previous.orgId !== next.orgId || previous.listingId !== next.listingId) return next;
  const fresh = (expiresAt: string) => Date.parse(expiresAt) - now >= LINK_KEEP_MS;
  const oldPhotos = new Map(previous.photos.map((photo) => [photo.id, photo]));
  const oldVideos = new Map(previous.videos.map((video) => [video.id, video]));
  return {
    ...next,
    photos: next.photos.map((photo) => {
      const old = oldPhotos.get(photo.id);
      if (!old || !fresh(old.expiresAt) || !sameObject(old.url, photo.url)) return photo;
      if (typeof photo.originalUrl === "string") {
        // Both links of one photo were issued together and share one expiry.
        if (typeof old.originalUrl !== "string" || !sameObject(old.originalUrl, photo.originalUrl)) return photo;
        return { ...photo, url: old.url, originalUrl: old.originalUrl, expiresAt: old.expiresAt };
      }
      return { ...photo, url: old.url, expiresAt: old.expiresAt };
    }),
    videos: next.videos.map((video) => {
      const old = oldVideos.get(video.id);
      return old && fresh(old.expiresAt) && sameObject(old.url, video.url)
        ? { ...video, url: old.url, expiresAt: old.expiresAt } : video;
    }),
  };
}

export type MediaCacheScope = { identityVersion: number; user: string; library: string; org: string; listing: string };
const scopeKey = (kind: "full" | "preview", scope: MediaCacheScope) =>
  `${kind}:${scope.identityVersion}:${scope.user}:${scope.library}:${scope.org}:${scope.listing}`;
// Memory only, per signed-in service instance. Never written to browser storage:
// these are short-lived private links for the account that loaded them.
const remembered = new WeakMap<object, Map<string, ListingMedia>>();

/** `full` is a complete property read; `preview` is only its first page. */
export function rememberMedia(owner: object, kind: "full" | "preview", scope: MediaCacheScope, media: ListingMedia): void {
  let entries = remembered.get(owner);
  if (!entries) { entries = new Map(); remembered.set(owner, entries); }
  const key = scopeKey(kind, scope);
  entries.delete(key);
  entries.set(key, media);
  while (entries.size > MAX_REMEMBERED) entries.delete(entries.keys().next().value as string);
}
/** A remembered read whose every link is still usable for at least a minute. */
export function recallMedia(owner: object, kind: "full" | "preview", scope: MediaCacheScope, now = Date.now()): ListingMedia | null {
  const entries = remembered.get(owner), key = scopeKey(kind, scope), media = entries?.get(key);
  if (!media) return null;
  if (media.orgId !== scope.org || media.listingId !== scope.listing || earliestExpiry(media) - now < 60_000) {
    entries!.delete(key);
    return null;
  }
  return media;
}
