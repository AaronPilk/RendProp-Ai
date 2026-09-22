export type ZipEntry = { path: string; bytes: Uint8Array };
export const KIT_MAX_BYTES = 256 * 1024 * 1024;
export const KIT_MAX_FILE_BYTES = 128 * 1024 * 1024;
export const KIT_MAX_ENTRIES = 128;
const encoder = new TextEncoder();
const crcTable = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let bit = 0; bit < 8; bit++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function stopped(signal?: AbortSignal) { signal?.throwIfAborted(); }
export function archivePath(path: string): string {
  if (!path || path.length > 240 || path.startsWith("/") || /[\\:<>"|?*\u0000-\u001f\u007f]/.test(path) ||
    path.split("/").some(part => !part || part === "." || part === ".." || /[. ]$/.test(part) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))) {
    throw new Error("A download filename could not be made safe.");
  }
  return path;
}
export function filenamePart(value: string): string {
  return value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-zA-Z0-9 -]/g, "-")
    .replace(/[ -]+/g, "-").replace(/^-|-$/g, "").slice(0, 70) || "property";
}
async function crc32(bytes: Uint8Array, signal?: AbortSignal) {
  let crc = 0xffffffff;
  for (let start = 0; start < bytes.length; start += 1024 * 1024) {
    stopped(signal);
    for (let i = start; i < Math.min(bytes.length, start + 1024 * 1024); i++) crc = crcTable[(crc ^ bytes[i]) & 255] ^ (crc >>> 8);
    if (bytes.length > 1024 * 1024) await new Promise<void>(resolve => setTimeout(resolve, 0));
  }
  stopped(signal); return (crc ^ 0xffffffff) >>> 0;
}
/** ZIP method 0: retain already-compressed photos/video without lossy conversion. */
export async function createStoredZip(entries: ZipEntry[], signal?: AbortSignal): Promise<Blob> {
  stopped(signal);
  if (!entries.length || entries.length > KIT_MAX_ENTRIES) throw new Error("Choose fewer files for this download.");
  const names = new Set<string>(); let total = 0;
  for (const entry of entries) {
    const name = archivePath(entry.path).normalize("NFC").toLowerCase();
    if (names.has(name)) throw new Error("Two download files have the same name.");
    names.add(name); total += entry.bytes.byteLength;
    if (entry.bytes.byteLength > KIT_MAX_FILE_BYTES || total > KIT_MAX_BYTES) throw new Error("Choose fewer files. A kit can contain up to 256 MB, with 128 MB per file.");
  }
  const chunks: BlobPart[] = [], directory: Uint8Array<ArrayBuffer>[] = []; let offset = 0;
  for (const entry of entries) {
    const name = encoder.encode(entry.path), crc = await crc32(entry.bytes, signal);
    const local = new Uint8Array(30 + name.length), l = new DataView(local.buffer);
    l.setUint32(0, 0x04034b50, true); l.setUint16(4, 20, true); l.setUint16(6, 0x800, true);
    l.setUint16(12, 33, true); // 1980-01-01, reproducible and valid DOS date.
    l.setUint32(14, crc, true); l.setUint32(18, entry.bytes.length, true); l.setUint32(22, entry.bytes.length, true); l.setUint16(26, name.length, true); local.set(name, 30);
    const central = new Uint8Array(46 + name.length), c = new DataView(central.buffer);
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x800, true); c.setUint16(14, 33, true);
    c.setUint32(16, crc, true); c.setUint32(20, entry.bytes.length, true); c.setUint32(24, entry.bytes.length, true); c.setUint16(28, name.length, true); c.setUint32(42, offset, true); central.set(name, 46);
    chunks.push(local, entry.bytes as Uint8Array<ArrayBuffer>); directory.push(central); offset += local.length + entry.bytes.length;
  }
  const end = new Uint8Array(22), e = new DataView(end.buffer), directorySize = directory.reduce((sum, item) => sum + item.length, 0);
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, entries.length, true); e.setUint16(10, entries.length, true); e.setUint32(12, directorySize, true); e.setUint32(16, offset, true);
  stopped(signal); return new Blob([...chunks, ...directory, end], { type: "application/zip" });
}
