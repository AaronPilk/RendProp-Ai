import type { StudioPhoto } from "../../data/contracts";
import type { StudioServices } from "../../data/services";
import { createStoredZip, filenamePart, KIT_MAX_BYTES, KIT_MAX_ENTRIES, type ZipEntry } from "../listings/kit-archive";
import { kitText } from "../listings/delivery-kit";
import { renderPhoto } from "./photo-export";
import type { PhotoDelivery } from "./photo-lineage";

const IMAGE_BYTES = 32 * 1024 * 1024, META_RESERVE = 1024 * 1024;
const targets = [["MLS", "4:3"], ["Zillow", "4:3"], ["Instagram/Feed4x5", "4:5"], ["Instagram/Stories9x16", "9:16"]] as const;
export type CoordinatorPart = { blob: Blob; filename: string; part: number; files: number; from: number; through: number; total: number; more: boolean; notes: string[] };
export type CoordinatorLoaded = { delivery: PhotoDelivery; category: "Originals" | "Decluttered" | "Staged" | "Edited"; earlierSource?: File | null };
export function coordinatorCategory(photo: StudioPhoto): CoordinatorLoaded["category"] {
  if (photo.editKind === "stage") return "Staged";
  if (photo.editKind === "declutter") return "Decluttered";
  return photo.isAltered || photo.isStaged ? "Edited" : "Originals";
}
export async function loadCoordinatorPhotos(services: Pick<StudioServices, "listMedia">, org: string, listing: string,
  signal: AbortSignal, assertScope: () => void): Promise<StudioPhoto[]> {
  const result: StudioPhoto[] = [], seen = new Set<string>(); let offset = 0;
  for (;;) {
    signal.throwIfAborted(); assertScope();
    const page = await services.listMedia(org, listing, signal, offset); signal.throwIfAborted(); assertScope();
    if (page.orgId !== org || page.listingId !== listing || page.photos.some(photo => photo.listingId !== listing)) throw new Error("The saved photos belong to another property.");
    if (page.unavailableCount) throw new Error("Some saved media is unavailable. Refresh this property before preparing its complete photo package.");
    for (const photo of page.photos) {
      if (seen.has(photo.id)) throw new Error("The saved photo list changed while loading. Refresh and try again.");
      seen.add(photo.id); result.push({ ...photo });
    }
    if (page.nextOffset === null) break;
    if (page.nextOffset !== offset + 50) throw new Error("The complete photo list could not be loaded.");
    offset = page.nextOffset;
  }
  if (!result.length) throw new Error("This property has no uploaded photos to download.");
  return result;
}
function imageExtension(bytes: Uint8Array): string {
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "jpg";
  if ([137,80,78,71,13,10,26,10].every((byte,index) => bytes[index] === byte)) return "png";
  if (new TextDecoder().decode(bytes.slice(0,4)) === "RIFF" && new TextDecoder().decode(bytes.slice(8,12)) === "WEBP") return "webp";
  if (new TextDecoder().decode(bytes.slice(4,8)) === "ftyp") {
    const brands = new TextDecoder().decode(bytes.slice(8,Math.min(bytes.length,80)));
    if (/heic|heix|hevc|hevx/.test(brands)) return "heic";
    if (!/avif|avis/.test(brands) && /mif1|msf1|heif/.test(brands)) return "heif";
  }
  throw new Error("A saved photo format could not be verified. No replacement image was used.");
}
async function digest(bytes: Uint8Array) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>))].map(n => n.toString(16).padStart(2,"0")).join("");
}
async function readImage(url: string, expiresAt: string, signal: AbortSignal, assertScope: () => void): Promise<File> {
  signal.throwIfAborted(); assertScope();
  if (Date.parse(expiresAt) <= Date.now()) throw new Error("A photo link expired. Refresh this property and prepare the package again.");
  const response = await fetch(url, { credentials: "omit", redirect: "error", signal: AbortSignal.any([signal, AbortSignal.timeout(90_000)]) });
  signal.throwIfAborted(); assertScope();
  if (!response.ok || !response.body) throw new Error("A saved photo could not download. Refresh and try again; no substitute was used.");
  const length = response.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > IMAGE_BYTES)) { void response.body.cancel(); throw new Error("A photo exceeds the browser's 32 MB decode limit. Its saved master is unchanged."); }
  const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) {
      const next = await reader.read(); signal.throwIfAborted(); assertScope(); if (next.done) break;
      size += next.value.byteLength; if (size > IMAGE_BYTES) throw new Error("A photo exceeds the browser's 32 MB decode limit. Its saved master is unchanged.");
      chunks.push(next.value);
    }
  } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
  const ext = imageExtension(bytes), mime = ext === "jpg" ? "image/jpeg" : ext === "png" ? "image/png" : ext === "webp" ? "image/webp" : `image/${ext}`;
  return new File([bytes], `saved-photo.${ext}`, { type: mime });
}
export async function loadCoordinatorPhoto(photo: StudioPhoto, signal: AbortSignal, assertScope: () => void): Promise<CoordinatorLoaded> {
  const file = await readImage(photo.url,photo.expiresAt,signal,assertScope), category = coordinatorCategory(photo);
  const paired = category !== "Originals" && photo.originalUrl && photo.originalUrl !== photo.url
    ? await readImage(photo.originalUrl,photo.expiresAt,signal,assertScope) : null;
  const original = category === "Originals" ? file : photo.originalVerified ? paired : null;
  signal.throwIfAborted(); assertScope();
  return { category, earlierSource: photo.originalVerified ? null : paired, delivery: { file, original, originalPreview: null, originalVerified: !!original,
    disclosures: category === "Originals" ? [] : [photo.caption?.trim() || "Saved altered photo; edit history is incomplete. Verify it against the property before advertising."],
    edits: photo.editKind ? [photo.editKind] : category === "Originals" ? [] : ["Earlier AI edits"], provenanceId: null } };
}
const encoder = new TextEncoder();
const readme = (part: number, from: number, through: number, total: number, more: boolean) =>
  `RENDPROP COORDINATOR PHOTO PACKAGE — PART ${part}\nPhotos ${from}–${through} of ${total}. ${more ? "More numbered parts follow; download every part." : "This is the final part."}\n\n` +
  "Extract ALL numbered ZIP parts into the same folder, preserving the folder tree. Unique photo IDs in filenames prevent parts or saved versions from overwriting one another. Each part has its own manifest and matching disclosure notes.\n\n" +
  "Originals, Decluttered, Staged and Edited contain exact saved file bytes, original format and available dimensions. Unknown edit kinds stay in Edited; captions never determine the folder. Only uploaded media accessible to this account is included; files stored only on a phone are not fetched. A paired original is included only when server history verifies it. Other available paired sources go in EarlierSources with unverified history. No missing source is replaced or called an original. HEIC/HEIF masters and paired sources retain their real format. If this browser cannot decode a HEIC/HEIF master, it is retained without substituted delivery copies; the manifest and part notes identify that limitation.\n\n" +
  "MLS and Zillow use landscape 4:3 delivery presets; Instagram/Feed4x5 uses 4:5 and Instagram/Stories9x16 uses 9:16. These are presets, not universal platform requirements. Copies are clean JPEGs at quality 0.97, center-cropped at the available resolution, never enlarged, stretched, blurred or watermarked. Originals and saved masters are untouched. Review crops: they remove edges. Limited source resolution remains limited; no 4K detail is invented.\n\n" +
  "All saved versions are retained separately. Downloading does not approve an edit, select it for a listing or publish anything. Check fixed features and required review in the app before advertising. Every altered copy has a matching disclosure text file; add that disclosure and any required original link using your MLS/advertising platform's rules. This package does not certify legal or platform compliance.\n";
/** Serial decode/render and numbered bounded ZIPs retain quality without loading an entire 4K library into memory. */
export async function* coordinatorPhotoParts(photos: readonly StudioPhoto[], signal: AbortSignal, assertScope: () => void,
  options: { title?: string; load?: typeof loadCoordinatorPhoto; render?: typeof renderPhoto; maxBytes?: number; maxEntries?: number; progress?: (done: number,total: number) => void } = {}): AsyncGenerator<CoordinatorPart> {
  const check = () => { signal.throwIfAborted(); assertScope(); }; check();
  if (!photos.length) throw new Error("Choose uploaded photos for this package.");
  const maxBytes = Math.min(options.maxBytes ?? KIT_MAX_BYTES,KIT_MAX_BYTES), maxEntries = Math.min(options.maxEntries ?? KIT_MAX_ENTRIES,KIT_MAX_ENTRIES);
  if (maxBytes <= META_RESERVE || maxEntries < 14) throw new Error("The photo package bounds are invalid.");
  const ids = new Set<string>(); for (const photo of photos) { if (ids.has(photo.id)) throw new Error("A saved photo identity is duplicated."); ids.add(photo.id); }
  let entries: ZipEntry[] = [], records: unknown[] = [], bytes = 0, part = 1, from = 1;
  async function pack(through: number,more: boolean): Promise<CoordinatorPart> {
    check();
    const notes = (records as Record<string,unknown>[]).filter(row => row.deliveryCopiesUnavailable).map(row => `${row.photoId}: ${row.deliveryCopiesUnavailable}`);
    const metadata = [
      { path: `READ-ME-part-${String(part).padStart(2,"0")}.txt`, bytes: encoder.encode(readme(part,from,through,photos.length,more) + (notes.length ? `\nPART NOTES\n${notes.join("\n")}\n` : "")) },
      { path: `manifest-part-${String(part).padStart(2,"0")}.json`, bytes: encoder.encode(JSON.stringify({ schema:1,part,from,through,totalPhotos:photos.length,moreParts:more,files:records,notes },null,2)) },
    ];
    const blob = await createStoredZip([...entries,...metadata],signal); check();
    return { blob, filename:`${filenamePart(options.title || "rendprop")}-coordinator-part-${String(part).padStart(2,"0")}.zip`, part, files:entries.length+metadata.length, from,through,total:photos.length,more,notes };
  }
  for (const [index,photo] of photos.entries()) {
    check(); options.progress?.(index,photos.length); const loaded = await (options.load ?? loadCoordinatorPhoto)(photo,signal,assertScope); check();
    const master = new Uint8Array(await loaded.delivery.file.arrayBuffer()); check();
    const category = loaded.category, stem = `${String(index+1).padStart(3,"0")}-${filenamePart(photo.id)}`;
    const photoEntries: ZipEntry[] = [], proof: Record<string,unknown> = { photoId:photo.id,category,sourceStatus:category === "Originals" ? "saved-original" : loaded.delivery.originalVerified ? "verified-paired-original" : "history-unverified",copies:[] };
    const caption = kitText(loaded.delivery.disclosures.join("\n") || (category === "Originals" ? "Saved source photo. Imported files may already contain edits made elsewhere." : "Saved altered photo; verify edit history before advertising."));
    const extension = imageExtension(master), masterPath = `${category}/${stem}.${extension}`;
    photoEntries.push({path:masterPath,bytes:master},{path:`${category}/${stem}-disclosure.txt`,bytes:encoder.encode(caption)});
    Object.assign(proof,{masterPath,masterSHA256:await digest(master),disclosure:caption}); check();
    if (category !== "Originals" && loaded.delivery.originalVerified && loaded.delivery.original) {
      const original = new Uint8Array(await loaded.delivery.original.arrayBuffer()); check();
      const path = `Originals/${stem}-paired-original.${imageExtension(original)}`;
      photoEntries.push({path,bytes:original}); Object.assign(proof,{originalPath:path,originalSHA256:await digest(original)}); check();
    }
    if (loaded.earlierSource) {
      const earlier = new Uint8Array(await loaded.earlierSource.arrayBuffer()); check();
      const path = `EarlierSources/${stem}-unverified-source.${imageExtension(earlier)}`;
      photoEntries.push({path,bytes:earlier}); Object.assign(proof,{earlierSourcePath:path,earlierSourceSHA256:await digest(earlier)}); check();
    }
    const copyStart = photoEntries.length;
    for (const [folder,ratio] of targets) {
      let rendered: Awaited<ReturnType<typeof renderPhoto>>;
      try { rendered = await (options.render ?? renderPhoto)(loaded.delivery,{destination:"mls",ratio},signal); }
      catch (error) {
        check();
        if (extension !== "heic" && extension !== "heif") throw error;
        photoEntries.length = copyStart; proof.copies = [];
        proof.deliveryCopiesUnavailable = "This browser could not create delivery copies from the saved HEIC/HEIF master. The exact master is included; no smaller replacement or delivery copies were created. Convert the retained master with a compatible photo application if needed.";
        break;
      }
      check();
      const copy = new Uint8Array(await rendered.blob.arrayBuffer()); check();
      const path = `${folder}/${category}/${stem}.jpg`;
      photoEntries.push({path,bytes:copy},{path:`${folder}/${category}/${stem}-disclosure.txt`,bytes:encoder.encode(caption)});
      (proof.copies as unknown[]).push({path,sha256:await digest(copy),width:rendered.width,height:rendered.height,crop:{x:rendered.x,y:rendered.y,width:rendered.cropWidth,height:rendered.cropHeight},limitedResolution:Math.min(rendered.width,rendered.height)<1080}); check();
    }
    const photoBytes = photoEntries.reduce((n,row) => n+row.bytes.byteLength,0);
    if (photoBytes > maxBytes-META_RESERVE || photoEntries.length > maxEntries-2) throw new Error("One full-resolution photo family exceeds the browser package limit. Download its master separately; no smaller substitute was created.");
    if (entries.length && (bytes+photoBytes > maxBytes-META_RESERVE || entries.length+photoEntries.length > maxEntries-2)) {
      yield await pack(index,true); check(); entries=[];records=[];bytes=0;part++;from=index+1;
    }
    entries.push(...photoEntries); records.push(proof); bytes+=photoBytes; options.progress?.(index+1,photos.length);
  }
  if (entries.length) yield await pack(photos.length,false);
}
