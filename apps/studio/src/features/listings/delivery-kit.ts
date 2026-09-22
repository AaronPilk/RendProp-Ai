import { mediaURL, uuid } from "../../data/contracts";
import type { Listing, ListingMedia, Workspace } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { decodeDocument } from "../../data/documents";
import { decodeDraft, decodeResult } from "../creative/model";
import { decodeListingState, EMPTY_STATE, orderedGallery, tourLinks } from "./model";
import type { ListingState, Published } from "./model";
import { createTourQR } from "./qr";
import { createStoredZip, filenamePart, KIT_MAX_BYTES, KIT_MAX_FILE_BYTES } from "./kit-archive";
import type { ZipEntry } from "./kit-archive";

export const KIT_MAX_SELECTED = 40;
export type KitItem = { id: string; kind: "photo" | "video"; label: string; caption: string; disclosure: string; url: string; expiresAt: string; originalUrl: string | null; originalLabel: "Paired original" | "Source photo" | null };
export type KitSnapshot = { listing: Listing; items: KitItem[]; excluded: string[]; script: string; published: Published | null; checkedAt: string; identityVersion: number };
export type KitProgress = { done: number; total: number; bytes: number; label: string };
const encoder = new TextEncoder();
const record = (raw: unknown) => {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("The saved property materials could not be read.");
  return raw as Record<string, unknown>;
};
export function assertKitIdentity(services: StudioServices, workspace: Workspace, version: number, signal: AbortSignal) {
  signal.throwIfAborted(); const current = services.getSnapshot();
  if (current.status !== "signed-in" || current.identity?.userId !== workspace.user.id || current.identity.isAnonymous || current.identityVersion !== version || !workspace.memberships.some(row => row.orgId === workspace.org.id)) throw new Error("Your account changed. Reopen this property before downloading.");
}
/** Only saved server state is read; local drafts and upload journals stay untouched. */
export async function loadKit(services: StudioServices, workspace: Workspace, listingId: string, signal: AbortSignal): Promise<KitSnapshot> {
  uuid(listingId); const orgId = uuid(workspace.org.id), version = services.getSnapshot().identityVersion;
  const check = () => assertKitIdentity(services, workspace, version, signal); check();
  const listingPromise = services.listListings(orgId, signal).then(rows => {
    const listing = rows.find(row => row.id === listingId && row.orgId === orgId);
    if (!listing) throw new Error("This property is no longer available in your workspace."); return listing;
  });
  const statePromise = (async () => {
    const all: ListingState = { ...EMPTY_STATE, assets: [], photos: [], jobs: [], renders: [], chapters: [] }; let offset = 0;
    for (;;) {
      const page = decodeListingState(await services.api(`/functions/v1/studio/listing-state?listing_id=${listingId}&offset=${offset}`, { orgId, signal }), orgId, listingId, offset); check();
      all.assets.push(...page.assets); all.photos.push(...page.photos); all.renders.push(...page.renders);
      if (all.assets.length + all.photos.length + all.renders.length > 2000) throw new Error("This property has too many saved materials for one kit. Download individual files from Media.");
      if (page.nextOffset === null) return all; offset = page.nextOffset;
    }
  })();
  const mediaPromise = (async () => {
    const all: ListingMedia = { orgId, listingId, photos: [], videos: [], nextOffset: null, unavailableCount: 0 }; let offset = 0;
    for (;;) {
      const page = await services.listMedia(orgId, listingId, signal, offset); check();
      if (page.orgId !== orgId || page.listingId !== listingId) throw new Error("The media belongs to another property.");
      all.photos = [...all.photos, ...page.photos]; all.videos = [...all.videos, ...page.videos]; all.unavailableCount += page.unavailableCount;
      if (all.photos.length + all.videos.length > 1000) throw new Error("This property's media is too large for one kit. Download individual files from Media.");
      if (page.nextOffset === null) return all;
      if (page.nextOffset !== offset + 50) throw new Error("The property media could not be loaded completely."); offset = page.nextOffset;
    }
  })();
  const creativePromise = (async () => {
    const all: ReturnType<typeof decodeResult>[] = []; let offset = 0;
    for (;;) {
      const page = record(await services.api(`/functions/v1/studio/creative-results?listing_id=${listingId}&offset=${offset}`, { orgId, signal })); check();
      if (!Array.isArray(page.results) || page.results.length > 100) throw new Error("Saved video results could not be checked.");
      for (const raw of page.results) { if (record(raw).listing_id !== listingId) throw new Error("A video result belongs to another property."); all.push(decodeResult(raw)); }
      if (all.length > 1000) throw new Error("This property has too many saved results for one kit.");
      if (page.next_offset === null) return all;
      if (page.next_offset !== offset + 100) throw new Error("Saved video results could not be loaded completely."); offset = page.next_offset as number;
    }
  })();
  const scriptPromise = (async () => {
    const key = `creative:${listingId}`, doc = decodeDocument(await services.api(`/functions/v1/studio/documents?key=${key}`, { orgId, signal }), key);
    if (doc && (doc.kind !== "creative" || doc.listing_id !== listingId)) throw new Error("The saved script belongs to another property.");
    return doc ? decodeDraft(doc.payload).script : "";
  })();
  const [listing, state, media, creative, script] = await Promise.all([listingPromise, statePromise, mediaPromise, creativePromise, scriptPromise]); check();
  const items: KitItem[] = [], excluded: string[] = [], seen = new Set<string>();
  const scoped = (url: string, expires: string) => mediaURL(url, orgId, listingId, expires, Date.now());
  const storageKey = (url: string) => new URL(url).pathname.split("/").slice(2).map(decodeURIComponent).join("/");
  for (const [index, gallery] of orderedGallery(state.photos).entries()) {
    const photo = media.photos.find(row => row.id === gallery.id);
    const label = `Photo ${index + 1}`;
    if (!photo || photo.listingId !== listingId) { excluded.push(`${label}: its saved file is unavailable.`); continue; }
    const altered = photo.isAltered === true || photo.isStaged || gallery.is_staged || Boolean(gallery.enhanced_key && gallery.enhanced_key !== gallery.original_key);
    if (altered && (!photo.originalUrl || photo.originalUrl === photo.url || !photo.caption?.trim())) { excluded.push(`${label}: the altered photo needs its paired original and saved disclosure.`); continue; }
    scoped(photo.url, photo.expiresAt);
    if (storageKey(photo.url) !== (gallery.enhanced_key || gallery.original_key) || altered && storageKey(scoped(photo.originalUrl!, photo.expiresAt)) !== gallery.original_key) throw new Error("A gallery photo no longer matches its saved original pairing. Refresh the materials.");
    if (seen.has(photo.id)) throw new Error("The gallery returned duplicate photos."); seen.add(photo.id);
    items.push({ id: `photo:${uuid(photo.id)}`, kind: "photo", label, caption: photo.caption ?? "", disclosure: altered ? `${photo.isStaged || gallery.is_staged ? "Virtually staged / AI-altered photo." : "Altered photo."} Saved caption and disclosure: ${photo.caption}` : "Saved gallery photo. No alteration flag is recorded for this photo.", url: scoped(photo.url, photo.expiresAt), expiresAt: photo.expiresAt, originalUrl: altered ? scoped(photo.originalUrl!, photo.expiresAt) : null, originalLabel: altered ? "Paired original" : null });
  }
  for (const result of creative.filter(row => row.kind === "video")) {
    const label = result.label || "Saved video";
    if (result.state !== "completed" || !result.url || !result.expiresAt || !result.assetId || !result.provenanceId || !result.disclosure.trim() || !result.qcPublishable) {
      excluded.push(`${label}: completion, disclosure or property-accuracy review is not confirmed.`); continue;
    }
    const asset = state.assets.find(row => row.id === result.assetId && row.uploaded && row.kind === "video");
    if (!asset) { excluded.push(`${label}: its saved video asset is unavailable.`); continue; }
    const identity = `video:${uuid(result.assetId)}`; if (seen.has(identity)) continue; seen.add(identity);
    const url = scoped(result.url, result.expiresAt);
    if (storageKey(url) !== asset.storage_key) throw new Error("A finished video no longer matches its saved asset. Refresh the materials.");
    // Generated clips have a single source photo; edited reels may combine many
    // sources and must never invent a single "unaltered original" video.
    const originalUrl = result.sourceUrl ? scoped(result.sourceUrl, result.expiresAt) : null;
    items.push({ id: identity, kind: "video", label, caption: "", disclosure: result.disclosure, url, expiresAt: result.expiresAt, originalUrl, originalLabel: originalUrl ? "Source photo" : null });
  }
  const published = state.renders.filter(row => row.listing_id === listingId && row.published_at && Number.isFinite(Date.parse(row.published_at)) && tourLinks(row.slug)).sort((a, b) => Date.parse(b.published_at!) - Date.parse(a.published_at!))[0] ?? null;
  return { listing, items, excluded, script, published, checkedAt: new Date().toISOString(), identityVersion: version };
}

export function kitText(value: string): string {
  return value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "").replace(/https?:\/\/[^\s<>"']+/gi, raw => {
    try { const url = new URL(raw); return url.hostname === "uploads.rendprop.com" || /\.r2\.cloudflarestorage\.com$/.test(url.hostname) || [...url.searchParams.keys()].some(key => /^(x-amz-|token$|access_token$|refresh_token$|apikey$|signature$|sig$)/i.test(key)) ? "[private link omitted]" : raw; } catch { return raw; }
  });
}
const escapeHTML = (value: string) => kitText(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
function mediaExtension(bytes: Uint8Array, type: string, kind: "photo" | "video") {
  const ascii = (start: number, end: number) => String.fromCharCode(...bytes.slice(start, end));
  if (kind === "photo") {
    if (type === "image/png" && bytes[0] === 137 && ascii(1, 4) === "PNG") return "png";
    if (type === "image/jpeg" && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "jpg";
    if (type === "image/webp" && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "webp";
    if (["image/heic", "image/heif"].includes(type) && ascii(4, 8) === "ftyp") return type === "image/heic" ? "heic" : "heif";
  } else if (["video/mp4", "video/quicktime", "video/x-m4v"].includes(type) && ascii(4, 8) === "ftyp") return type === "video/quicktime" ? "mov" : "mp4";
  throw new Error("A saved file has an unsupported or mismatched format. No incomplete kit was downloaded.");
}
export async function buildKit(snapshot: KitSnapshot, selectedIds: string[], options: { services: StudioServices; workspace: Workspace; signal: AbortSignal; progress: (value: KitProgress) => void; fetcher?: typeof fetch }) {
  const { signal, services, workspace } = options, check = () => assertKitIdentity(services, workspace, snapshot.identityVersion, signal);
  check(); if (snapshot.listing.orgId !== workspace.org.id) throw new Error("This kit belongs to another workspace.");
  if (selectedIds.length > KIT_MAX_SELECTED || new Set(selectedIds).size !== selectedIds.length) throw new Error("Choose up to 40 photos or videos for one kit.");
  const selected = selectedIds.map(id => { const item = snapshot.items.find(row => row.id === id); if (!item) throw new Error("Your selection changed. Refresh the kit materials."); return item; });
  const entries: ZipEntry[] = [], files: Record<string, unknown>[] = []; let bytesRead = 0, done = 0;
  const total = selected.reduce((sum, item) => sum + (item.originalUrl ? 2 : 1), 0);
  const read = async (url: string, expiresAt: string, label: string, kind: "photo" | "video") => {
    check(); const verified = mediaURL(url, workspace.org.id, snapshot.listing.id, expiresAt, Date.now());
    const response = await (options.fetcher ?? fetch)(verified, { credentials: "omit", referrerPolicy: "no-referrer", redirect: "error", signal: AbortSignal.any([signal, AbortSignal.timeout(90_000)]) }); check();
    if (!response.ok || !response.body) throw new Error(`${label} could not download. Refresh the kit and try again. No incomplete kit was downloaded.`);
    const available = Math.min(KIT_MAX_FILE_BYTES, KIT_MAX_BYTES - 1024 * 1024 - bytesRead), length = response.headers.get("content-length");
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > available)) { void response.body.cancel(); throw new Error("This kit exceeds its download size. Choose fewer files, or download a large video separately."); }
    const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
    try { for (;;) { const next = await reader.read(); check(); if (next.done) break; size += next.value.length; if (size > available) throw new Error("This kit exceeds its download size. Choose fewer files."); chunks.push(next.value); options.progress({ done, total, bytes: bytesRead + size, label }); } }
    finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
    const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const extension = mediaExtension(bytes, (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase(), kind);
    bytesRead += size; done++; options.progress({ done, total, bytes: bytesRead, label }); return { bytes, extension };
  };
  for (const [index, item] of selected.entries()) {
    const stem = `${String(index + 1).padStart(2, "0")}-${filenamePart(item.label)}`, file = await read(item.url, item.expiresAt, item.label, item.kind);
    const path = `${item.kind === "photo" ? "photos" : "videos"}/${stem}.${file.extension}`; entries.push({ path, bytes: file.bytes });
    let originalPath: string | null = null;
    if (item.originalUrl) { const original = await read(item.originalUrl, item.expiresAt, `${item.label} — ${item.originalLabel}`, "photo"); originalPath = `originals/${stem}-${item.originalLabel === "Source photo" ? "source" : "original"}.${original.extension}`; entries.push({ path: originalPath, bytes: original.bytes }); }
    files.push({ path, caption: kitText(item.caption), disclosure: kitText(item.disclosure), originalPath, originalRelationship: item.originalLabel, ...(item.kind === "video" && !originalPath ? { sourceNote: "This edit may combine multiple inputs. No single unaltered original is claimed or included." } : {}) });
  }
  const listing = snapshot.listing, links = snapshot.published ? tourLinks(snapshot.published.slug) : null;
  const facts = { address: kitText(listing.address ?? "Untitled property"), headline: kitText(listing.tagline ?? ""), beds: listing.beds, baths: listing.baths, squareFeet: listing.sqft, askingPriceUSD: listing.priceCents === null ? null : listing.priceCents / 100, status: listing.soldAt ? "Sold" : listing.status };
  const text = (path: string, value: string) => entries.push({ path, bytes: encoder.encode(value) });
  const factsText = [`${facts.address}`, facts.headline, `Bedrooms: ${facts.beds ?? "Not saved"}`, `Bathrooms: ${facts.baths ?? "Not saved"}`, `Square feet: ${facts.squareFeet ?? "Not saved"}`, `Asking price (USD): ${facts.askingPriceUSD ?? "Not saved"}`, `Status: ${facts.status}`].join("\n");
  text("property-details.txt", `${factsText}\n\nSaved snapshot: ${snapshot.checkedAt}\nReview the saved facts before advertising. Unsaved field edits are not included.\n`);
  if (snapshot.script.trim()) text("saved-script.txt", `${kitText(snapshot.script)}\n\nSaved script only. Review claims, pricing and wording before use.\n`);
  if (links && snapshot.published) {
    text("sharing-links.txt", `Published marketing tour: ${links.branded}\nPublished unbranded tour: ${links.unbranded}\nPublished at: ${snapshot.published.published_at}\nThese links open the existing published tour. Downloading a kit does not publish new work. Check your destination's rules before sharing.\n`);
    text("sharing/marketing-qr.svg", await createTourQR(snapshot.published.slug)); check();
    text("sharing/unbranded-qr.svg", await createTourQR(snapshot.published.slug, "unbranded")); check();
  }
  const manifest = { format: "rendprop-listing-kit", version: 1, savedSnapshotAt: snapshot.checkedAt, facts, files, publishedLinks: links, selectedMediaCount: selected.length, availableMediaCount: snapshot.items.length, excluded: snapshot.excluded.map(kitText), review: "The person downloading confirmed they reviewed the selected materials. This is not an approval record, a new publication or an MLS compliance certification." };
  text("manifest.json", JSON.stringify(manifest, null, 2) + "\n");
  text("disclosures.txt", files.map(file => `${file.path}\n${file.disclosure}\n${file.originalPath ? `${file.originalRelationship}: ${file.originalPath}` : ""}${file.sourceNote ? `\n${file.sourceNote}` : ""}`).join("\n\n") + "\n\nKeep each altered image with its paired original and disclosure when sharing. This kit is not an MLS compliance certification.\n");
  text("START-HERE.html", `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:"><title>${escapeHTML(facts.address)} — Rendprop listing kit</title><style>body{font:16px/1.6 system-ui,sans-serif;background:#f8f7fb;color:#211c2b;max-width:900px;padding:32px;margin:auto}h1{line-height:1.2}header{border-bottom:3px solid #7351b5;padding-bottom:20px}small{color:#615769}a{color:#63419f}article{background:white;border:1px solid #e3dfeb;border-radius:12px;padding:20px;margin:18px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}img{max-width:180px}li{margin:8px 0}</style><header><strong>RENDPROP</strong><h1>${escapeHTML(facts.address)}</h1><p>Your selected listing materials, together.</p><small>Saved snapshot: ${escapeHTML(snapshot.checkedAt)}</small></header><article><h2>Property details</h2><pre>${escapeHTML(factsText)}</pre><a href="property-details.txt">Open saved property details</a>${snapshot.script.trim() ? ' · <a href="saved-script.txt">Open saved script</a>' : ""}<p>Only saved details are included. Review the facts and keep disclosures with altered media before sharing.</p></article><article><h2>Selected media (${selected.length})</h2><ul>${files.map(file => `<li><a href="${file.path}">${escapeHTML(String(file.path))}</a>${file.originalPath ? ` · <a href="${file.originalPath}">${file.originalRelationship}</a>` : ""}<br>${escapeHTML(String(file.disclosure))}${file.sourceNote ? `<br>${escapeHTML(String(file.sourceNote))}` : ""}</li>`).join("")}</ul><a href="disclosures.txt">Open disclosures and original pairings</a></article><article><h2>Published sharing links</h2>${links ? `<p><a href="${links.branded}" rel="noreferrer">Open marketing tour</a> · <a href="${links.unbranded}" rel="noreferrer">Open unbranded tour</a></p><p><a href="sharing/marketing-qr.svg">Marketing QR</a> · <a href="sharing/unbranded-qr.svg">Unbranded QR</a></p><p>These open the existing published version. New work was not published by this download.</p>` : "<p>No published tour was available when this kit was prepared. No tour links or QR codes are included.</p>"}</article>${snapshot.excluded.length ? `<article><h2>Unavailable materials</h2><ul>${snapshot.excluded.map(reason => `<li>${escapeHTML(reason)}</li>`).join("")}</ul></article>` : ""}<p>${selected.length} selected media item(s) included from ${snapshot.items.length} available. <a href="manifest.json">File inventory</a>. This download does not certify advertising or MLS compliance.</p></html>`);
  check(); options.progress({ done, total, bytes: bytesRead, label: "Packing your listing kit…" });
  const blob = await createStoredZip(entries, signal); check();
  return { blob, filename: `${filenamePart(listing.address ?? "property")}-listing-kit.zip`, mediaCount: selected.length };
}
