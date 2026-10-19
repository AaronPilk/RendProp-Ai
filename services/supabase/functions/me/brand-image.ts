import jpeg from "npm:jpeg-js@0.4.4";
import { HttpError } from "../_shared/http.ts";

export const MAX_LOGO_BYTES = 512 * 1024;
const MAX_DIMENSION = 1024;
const pngSignature = new Uint8Array([137,80,78,71,13,10,26,10]);
function invalid(): never { throw new HttpError(400, "Choose a valid JPEG or PNG logo up to 512 KiB and 1024 pixels per side.", "validation"); }
function crc(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  }
  return (value ^ 0xffffffff) >>> 0;
}
function join(parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
  let cursor = 0;
  for (const part of parts) { out.set(part, cursor); cursor += part.length; }
  return out;
}
async function cleanPNG(bytes: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
  if (!pngSignature.every((byte, i) => bytes[i] === byte)) invalid();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const kept: Uint8Array[] = [pngSignature], compressed: Uint8Array[] = [];
  let cursor = 8, width = 0, height = 0, channels = 0, ended = false, dataEnded = false;
  while (cursor < bytes.length) {
    if (cursor + 12 > bytes.length) invalid();
    const length = view.getUint32(cursor), end = cursor + length + 12;
    if (end > bytes.length) invalid();
    const type = String.fromCharCode(...bytes.subarray(cursor + 4, cursor + 8));
    if (!/^[A-Za-z]{4}$/.test(type) || crc(bytes.subarray(cursor + 4, end - 4)) !== view.getUint32(end - 4)) invalid();
    const data = bytes.subarray(cursor + 8, end - 4);
    if (cursor === 8 && type !== "IHDR") invalid();
    if (type === "IHDR") {
      if (width || length !== 13) invalid();
      width = view.getUint32(cursor + 8); height = view.getUint32(cursor + 12);
      if (width < 1 || height < 1 || width > MAX_DIMENSION || height > MAX_DIMENSION || data[8] !== 8 || ![2,6].includes(data[9]) || data[10] !== 0 || data[11] !== 0 || data[12] !== 0) invalid();
      channels = data[9] === 6 ? 4 : 3;
      kept.push(bytes.subarray(cursor, end));
    } else if (type === "IDAT") {
      if (!width || dataEnded) invalid();
      compressed.push(data); kept.push(bytes.subarray(cursor, end));
    } else if (type === "IEND") {
      if (length !== 0 || !compressed.length || end !== bytes.length) invalid();
      kept.push(bytes.subarray(cursor, end)); ended = true;
    } else {
      if (compressed.length) dataEnded = true;
      // Only optional metadata is discarded; animation/unknown critical chunks
      // are refused. No EXIF, text, ICC payload or location survives publication.
      if (type === "acTL" || type === "fcTL" || type === "fdAT" || type[0] === type[0].toUpperCase()) invalid();
    }
    cursor = end;
  }
  if (!ended) invalid();
  const stride = width * channels + 1, expected = height * stride;
  const raw = new Uint8Array(expected);
  const reader = new Blob([join(compressed)]).stream().pipeThrough(new DecompressionStream("deflate")).getReader();
  let received = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.length > expected - received) { await reader.cancel(); invalid(); }
      raw.set(value, received); received += value.length;
    }
  } catch { invalid(); }
  if (received !== expected) invalid();
  for (let row = 0; row < height; row++) if (raw[row * stride] > 4) invalid();
  return join(kept);
}

/** Fully decode bounded JPEG pixels and re-encode without caller metadata;
 * validate PNG CRCs, dimensions, exact inflated scanlines, then strip metadata.
 * The resulting immutable object is always raster, never SVG/HTML by extension. */
export async function brandImage(raw: unknown, type: unknown): Promise<{ bytes: Uint8Array<ArrayBuffer>; type: "image/jpeg" | "image/png"; sha256: string }> {
  if ((type !== "image/jpeg" && type !== "image/png") || typeof raw !== "string" || raw.length < 4 || raw.length > Math.ceil(MAX_LOGO_BYTES / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(raw)) invalid();
  const padding = raw.endsWith("==") ? 2 : raw.endsWith("=") ? 1 : 0;
  if (padding && "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".indexOf(raw[raw.length - padding - 1]) % (padding === 2 ? 16 : 4) !== 0) invalid();
  let input: Uint8Array;
  try { input = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0)); } catch { invalid(); }
  if (input.length < 1 || input.length > MAX_LOGO_BYTES) invalid();
  let bytes: Uint8Array<ArrayBuffer>;
  if (type === "image/png") bytes = await cleanPNG(input);
  else {
    try {
      if (input[0] !== 255 || input[1] !== 216 || input[input.length - 2] !== 255 || input[input.length - 1] !== 217) invalid();
      const decoded = jpeg.decode(input, { useTArray: true, tolerantDecoding: false, maxResolutionInMP: 1.05, maxMemoryUsageInMB: 32 });
      if (decoded.width < 1 || decoded.height < 1 || decoded.width > MAX_DIMENSION || decoded.height > MAX_DIMENSION) invalid();
      bytes = new Uint8Array(jpeg.encode({ width: decoded.width, height: decoded.height, data: decoded.data }, 85).data);
    } catch { invalid(); }
  }
  if (bytes.length > MAX_LOGO_BYTES) invalid();
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return { bytes, type, sha256: Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("") };
}
