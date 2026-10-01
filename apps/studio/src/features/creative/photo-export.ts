import { createStoredZip, filenamePart, type ZipEntry } from "../listings/kit-archive";
import { kitText } from "../listings/delivery-kit";
import type { PhotoDelivery } from "./photo-lineage";

export type PhotoDestination = "mls" | "web" | "social";
export type PhotoRatio = "original" | "4:3" | "16:9" | "3:2" | "1:1" | "4:5" | "9:16";
export type PhotoExportOptions = { destination: PhotoDestination; ratio: PhotoRatio };
export function photoFrame(width: number, height: number, ratio: PhotoRatio) {
  if (![width, height].every(n => Number.isSafeInteger(n) && n > 0) || width * height > 100_000_000) throw new Error("This image is too large or unreadable.");
  const ratios = { "4:3": 4 / 3, "16:9": 16 / 9, "3:2": 3 / 2, "1:1": 1, "4:5": 4 / 5, "9:16": 9 / 16 };
  if (ratio !== "original" && !(ratio in ratios)) throw new Error("Choose a supported photo shape.");
  const target = ratio === "original" ? width / height : ratios[ratio];
  const cropWidth = Math.floor(Math.min(width, height * target)), cropHeight = Math.floor(Math.min(height, width / target));
  if (!cropWidth || !cropHeight) throw new Error("This photo is too small for the selected crop.");
  return { x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, cropWidth, cropHeight,
    width: cropWidth, height: cropHeight };
}
export function photoCaption(photo: PhotoDelivery) {
  const history = photo.originalVerified ? "Original included separately." : "Earlier source history is unverified. No unedited-original claim is made.";
  return kitText([...new Set(photo.disclosures.length ? photo.disclosures : [photoLabel(photo)])].join("\n") + "\n" + history);
}
export function photoLabel(photo: PhotoDelivery) {
  return kitText([...new Set(["Digitally altered", ...photo.edits])].join(" · "));
}
/** Preview and downloaded JPEG use this same rendering path. Originals are never rendered. */
export async function renderPhoto(photo: PhotoDelivery, options: PhotoExportOptions, signal: AbortSignal) {
  signal.throwIfAborted();
  if (!["mls", "web", "social"].includes(options.destination)) throw new Error("Choose a download destination.");
  const image = await createImageBitmap(photo.file);
  try {
    signal.throwIfAborted();
    const frame = photoFrame(image.width, image.height, options.ratio);
    const canvas = document.createElement("canvas"); canvas.width = frame.width; canvas.height = frame.height;
    const ctx = canvas.getContext("2d", { colorSpace: "srgb" });
    if (!ctx) throw new Error("Your browser could not prepare this photo.");
    ctx.fillStyle = "white"; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, frame.x, frame.y, frame.cropWidth, frame.cropHeight, 0, 0, canvas.width, canvas.height);
    if (options.destination !== "mls") {
      const font = Math.max(8, Math.round(Math.min(canvas.width, canvas.height) / 42)), padding = Math.max(4, font * .7);
      ctx.font = `600 ${font}px sans-serif`;
      const lines: string[] = []; let line = "";
      for (const word of photoLabel(photo).split(/\s+/)) {
        if (line && ctx.measureText(`${line} ${word}`).width > canvas.width - padding * 2) { lines.push(line); line = word; }
        else line += `${line ? " " : ""}${word}`;
      }
      if (line) lines.push(line);
      if ((lines.length + 1) * font * 1.3 > canvas.height / 2) throw new Error("This image is too small for a readable disclosure. Choose MLS for a clean image with a separate caption.");
      const band = lines.length * font * 1.3 + padding * 2;
      ctx.fillStyle = "rgba(0,0,0,.85)"; ctx.fillRect(0, canvas.height - band, canvas.width, band);
      ctx.fillStyle = "white"; ctx.textBaseline = "top";
      lines.forEach((text, index) => ctx.fillText(text, padding, canvas.height - band + padding + index * font * 1.3));
    }
    const blob = await new Promise<Blob>((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new Error("The JPEG could not be prepared.")), "image/jpeg", .94));
    signal.throwIfAborted();
    return { blob, ...frame };
  } finally { image.close(); }
}
async function digest(bytes: Uint8Array) {
  const hash = await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>);
  return [...new Uint8Array(hash)].map(n => n.toString(16).padStart(2, "0")).join("");
}
function originalExtension(bytes: Uint8Array) {
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "jpg";
  if ([137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) => bytes[index] === byte)) return "png";
  if (new TextDecoder().decode(bytes.slice(0, 4)) === "RIFF" && new TextDecoder().decode(bytes.slice(8, 12)) === "WEBP") return "webp";
  throw new Error("The original photo format could not be verified.");
}
export async function buildPhotoDownload(photos: readonly PhotoDelivery[], options: PhotoExportOptions,
  signal: AbortSignal, assertScope: () => void, renderer = renderPhoto) {
  const check = () => { signal.throwIfAborted(); assertScope(); };
  check(); if (!photos.length || photos.length > 6) throw new Error("Choose one to six completed photos.");
  const entries: ZipEntry[] = [], records: unknown[] = [], captions: string[] = [];
  for (const [index, photo] of photos.entries()) {
    check();
    const number = String(index + 1).padStart(2, "0"), stem = `${number}-${filenamePart(photo.file.name.replace(/\.[^.]+$/, ""))}`;
    const rendered = await renderer(photo, options, signal); check();
    const bytes = new Uint8Array(await rendered.blob.arrayBuffer()); check();
    const editedPath = `photos/${stem}-02-edited.jpg`;
    entries.push({ path: editedPath, bytes });
    let original: { path: string; sha256: string } | null = null;
    if (photo.originalVerified) {
      if (!photo.original) throw new Error("This photo has no verified original to include.");
      const originalBytes = new Uint8Array(await photo.original.arrayBuffer()); check();
      // Source preparation decoded this file; the ZIP retains its exact bytes.
      const path = `photos/${stem}-01-original.${originalExtension(originalBytes)}`;
      original = { path, sha256: await digest(originalBytes) }; check();
      entries.push({ path, bytes: originalBytes });
    }
    captions.push(`${editedPath}\n${photoCaption(photo)}\n`);
    records.push({ editedPath, editedSHA256: await digest(bytes), original,
      originalStatus: original ? "provided-or-user-reviewed-original" : "history-unverified",
      disclosure: photoCaption(photo), visibleLabel: options.destination === "mls" ? null : photoLabel(photo),
      provenanceId: photo.provenanceId, width: rendered.width, height: rendered.height,
      crop: { x: rendered.x, y: rendered.y, width: rendered.cropWidth, height: rendered.cropHeight } });
    check();
  }
  const encode = (path: string, text: string) => entries.push({ path, bytes: new TextEncoder().encode(text) });
  encode("captions.txt", captions.join("\n"));
  encode("provenance.json", JSON.stringify({ schema: 1, destination: options.destination, ratio: options.ratio,
    publicOriginalURL: null, files: records }, null, 2));
  encode("READ-ME.txt", "Review the edited photo against the real property before advertising. Labels do not permit hiding defects or changing permanent property features.\n\n" +
    "MLS: upload each included original immediately beside its edited version and copy the exact captions into the listing's photo descriptions. Your MLS may require other fields or forbid particular edits. These clean photos have no branding or text overlay.\n\n" +
    "Zillow / web and Social: the edited JPEG has a visible alteration label. Keep the full caption and original comparison with it.\n\n" +
    "No public-original URL is supplied by this download. California advertising can require a conspicuous disclosure and publicly accessible original link/URL/QR; this package alone does not certify those requirements.\n\n" +
    "Originals, when included, are copied without resizing or re-encoding. Earlier source history can require your verification. Crop affects only the exported edited JPEG; no images are stretched or upscaled.\n");
  const blob = await createStoredZip(entries, signal); check();
  return { blob, filename: `rendprop-${options.destination}-photos.zip` };
}
