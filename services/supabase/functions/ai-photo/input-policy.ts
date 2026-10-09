// A still-image admission policy, independent of provider token estimates.
// Originals remain untouched. Oversized photos must be resized by the caller;
// the server never silently crops, truncates or changes the source image.
import { HttpError } from "../_shared/http.ts";

export const PHOTO_INPUT_POLICY = Object.freeze({
  maxBase64Chars: 12_000_000,
  maxDecodedBytes: 9_000_000,
  maxPixels: 24_000_000,
  maxEdge: 8192,
  maxUserPromptChars: 600,
  // A 600-character request must not be cut in half by UTF-8 accents.
  maxUserPromptBytes: 2400,
  maxProviderPromptBytes: 8192,
});
export interface StillImage { mime: string; bytes: number; width: number; height: number }
const invalid = (): never => { throw new HttpError(400, "Use a complete still JPEG, PNG or WebP photo. Animated images and HEIC/HEIF must be exported as a still JPEG first.", "validation"); };
const large = (): never => { throw new HttpError(413, "Resize the photo before editing: at most 9 MB, 24 megapixels and 8192 pixels on either edge.", "payload_too_large"); };
const be16 = (b: Uint8Array, i: number) => b[i] * 256 + b[i + 1];
const be32 = (b: Uint8Array, i: number) => (b[i] * 0x1000000 + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3]) >>> 0;
const le32 = (b: Uint8Array, i: number) => (b[i] + (b[i + 1] << 8) + (b[i + 2] << 16) + b[i + 3] * 0x1000000) >>> 0;
const four = (b: Uint8Array, i: number) => String.fromCharCode(...b.subarray(i, i + 4));
function geometry(width: number, height: number) {
  if (!width || !height) invalid();
  if (width > PHOTO_INPUT_POLICY.maxEdge || height > PHOTO_INPUT_POLICY.maxEdge || width * height > PHOTO_INPUT_POLICY.maxPixels) large();
  return { width, height };
}
function jpeg(b: Uint8Array) {
  if (b.length < 4 || b[0] !== 255 || b[1] !== 216) invalid();
  let i = 2, dimensions: { width: number; height: number } | undefined, scan = false;
  while (i < b.length) {
    if (b[i++] !== 255) invalid();
    while (b[i] === 255) i++;
    const marker = b[i++];
    if (marker === 217) { if (!dimensions || !scan || i !== b.length) invalid(); return dimensions!; }
    if (marker === undefined || marker === 0 || marker === 216 || marker === 220 || (marker >= 208 && marker <= 215)) invalid();
    if (i + 2 > b.length) invalid();
    const length = be16(b, i), end = i + length;
    if (length < 2 || end > b.length) invalid();
    // Baseline, extended sequential and progressive JPEG. Other SOF encodings
    // are unsupported; there must be exactly one frame and fixed dimensions.
    if ([192, 193, 194].includes(marker)) {
      if (dimensions || length < 8 || b[i + 2] !== 8 || ![1, 3, 4].includes(b[i + 7]) || length !== 8 + 3 * b[i + 7]) invalid();
      dimensions = geometry(be16(b, i + 5), be16(b, i + 3));
    } else if (marker >= 192 && marker <= 207 && ![196, 200, 204].includes(marker)) invalid();
    i = end;
    if (marker === 218) {
      if (!dimensions || length < 6) invalid();
      scan = true;
      // Entropy data may contain stuffed FF00 and restart markers. A marker
      // begins the next segment; no balanced-prefix or trailing-image salvage.
      while (i < b.length) {
        if (b[i] !== 255) { i++; continue; }
        const start = i++;
        while (b[i] === 255) i++;
        if (b[i] === 0 || (b[i] >= 208 && b[i] <= 215)) { i++; continue; }
        i = start; break;
      }
    }
  }
  return invalid();
}
function crc32(b: Uint8Array, start: number, end: number) {
  let crc = 0xffffffff;
  for (let i = start; i < end; i++) {
    crc ^= b[i];
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function png(b: Uint8Array) {
  if (![137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => b[i] === v)) invalid();
  let i = 8, dimensions: { width: number; height: number } | undefined, image = false;
  while (i + 12 <= b.length) {
    const length = be32(b, i), kind = four(b, i + 4), end = i + 12 + length;
    if (end > b.length || !/^[A-Za-z]{4}$/.test(kind) || crc32(b, i + 4, end - 4) !== be32(b, end - 4)) invalid();
    if (!dimensions) {
      if (kind !== "IHDR" || length !== 13) invalid();
      dimensions = geometry(be32(b, i + 8), be32(b, i + 12));
      const allowedDepth: Record<number, number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
      if (!allowedDepth[b[i + 17]]?.includes(b[i + 16]) || b[i + 18] !== 0 || b[i + 19] !== 0 || b[i + 20] > 1) invalid();
    } else if (kind === "IHDR" || ["acTL", "fcTL", "fdAT"].includes(kind)) invalid();
    if (kind === "IDAT") { if (!length) invalid(); image = true; }
    if (kind === "IEND") { if (length || !image || end !== b.length) invalid(); return dimensions!; }
    if (kind[0] === kind[0].toUpperCase() && !["IHDR", "PLTE", "IDAT"].includes(kind)) invalid();
    i = end;
  }
  return invalid();
}
function webp(b: Uint8Array) {
  if (b.length < 20 || four(b, 0) !== "RIFF" || four(b, 8) !== "WEBP" || le32(b, 4) + 8 !== b.length) invalid();
  let i = 12, canvas: { width: number; height: number } | undefined, image: { width: number; height: number } | undefined;
  while (i + 8 <= b.length) {
    const kind = four(b, i), length = le32(b, i + 4), start = i + 8, end = start + length, next = end + (length & 1);
    if (next > b.length || (length & 1 && b[end] !== 0)) invalid();
    if (["ANIM", "ANMF"].includes(kind)) invalid();
    if (kind === "VP8X") {
      if (i !== 12 || length !== 10 || canvas || b[start] & 0xc3 || b[start + 1] || b[start + 2] || b[start + 3]) invalid();
      canvas = geometry(1 + b[start + 4] + (b[start + 5] << 8) + (b[start + 6] << 16), 1 + b[start + 7] + (b[start + 8] << 8) + (b[start + 9] << 16));
    } else if (kind === "VP8 ") {
      if (image || length < 10 || b[start] & 1 || b[start + 3] !== 157 || b[start + 4] !== 1 || b[start + 5] !== 42) invalid();
      image = geometry((b[start + 6] + (b[start + 7] << 8)) & 0x3fff, (b[start + 8] + (b[start + 9] << 8)) & 0x3fff);
    } else if (kind === "VP8L") {
      if (image || length < 5 || b[start] !== 47 || b[start + 4] & 0xe0) invalid();
      const bits = le32(b, start + 1);
      image = geometry(1 + (bits & 0x3fff), 1 + ((bits >>> 14) & 0x3fff));
    } else if (!["ALPH", "ICCP", "EXIF", "XMP "].includes(kind)) invalid();
    i = next;
  }
  if (i !== b.length || !image || (canvas && (canvas.width !== image.width || canvas.height !== image.height))) invalid();
  return image!;
}
export function validatePhotoInput(value: unknown, mime: string): StillImage {
  if (typeof value !== "string" || !value.length) return invalid();
  if (value.length > PHOTO_INPUT_POLICY.maxBase64Chars) large();
  // Canonical padded base64 only: no data-URL, whitespace or decoder salvage.
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  if (value.length % 4 || /[^A-Za-z0-9+/=]/.test(value) || value.slice(0, value.length - padding).includes("=")) invalid();
  let decoded: string; try { decoded = atob(value); } catch { return invalid(); }
  if (decoded.length > PHOTO_INPUT_POLICY.maxDecodedBytes) large();
  if (btoa(decoded) !== value) invalid();
  const bytes = Uint8Array.from(decoded, (char) => char.charCodeAt(0));
  const dimensions = mime === "image/jpeg" ? jpeg(bytes) : mime === "image/png" ? png(bytes) : mime === "image/webp" ? webp(bytes) : invalid();
  return { mime, bytes: bytes.length, ...dimensions };
}
export function validatePhotoInputs(image: unknown, mime: string, mask?: unknown, maskMime = "image/png") {
  const source = validatePhotoInput(image, mime);
  if (mask === undefined) return source;
  const overlay = validatePhotoInput(mask, maskMime);
  if (source.bytes + overlay.bytes > PHOTO_INPUT_POLICY.maxDecodedBytes) large();
  if (source.width !== overlay.width || source.height !== overlay.height) throw new HttpError(400, "The mask must have the same dimensions as the photo.", "validation");
  return source;
}
export function validatePhotoPrompt(prompt: string, user = false) {
  if (user && prompt.length > PHOTO_INPUT_POLICY.maxUserPromptChars) throw new HttpError(400,
    `Photo instructions are too long (maximum ${PHOTO_INPUT_POLICY.maxUserPromptChars} characters).`, "validation");
  const cap = user ? PHOTO_INPUT_POLICY.maxUserPromptBytes : PHOTO_INPUT_POLICY.maxProviderPromptBytes;
  if (new TextEncoder().encode(prompt).byteLength > cap) throw new HttpError(400, `Photo instructions are too long (maximum ${cap} UTF-8 bytes).`, "validation");
}
