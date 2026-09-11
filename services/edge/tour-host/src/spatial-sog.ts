/** Admit only the self-contained stored-ZIP SOG emitted by our pinned converter.
 * PlayCanvas otherwise inflates arbitrary members and fetches missing textures.
 * This bounds that input envelope, not total browser/GPU resident memory. */
export function inspectSpatialSog(input: Uint8Array, count: number): { textures: number; texturePixels: number } {
  const fail = (): never => { throw new Error("Room package is not a supported bounded SOG"); };
  if (input.byteLength < 22 || input.byteLength > 32 * 1024 * 1024 || !Number.isSafeInteger(count) || count < 1 || count > 500000) return fail();
  const data = new DataView(input.buffer, input.byteOffset, input.byteLength);
  const u16 = (o: number): number => data.getUint16(o, true);
  const u32 = (o: number): number => data.getUint32(o, true);
  const text = (start: number, length: number): string => new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(input.subarray(start, start + length));
  const end = input.byteLength - 22;
  if (u32(end) !== 0x06054b50 || u16(end + 4) !== 0 || u16(end + 6) !== 0 || u16(end + 20) !== 0) return fail();
  const entries = u16(end + 10), directory = u32(end + 16), size = u32(end + 12);
  if (entries < 6 || entries > 8 || u16(end + 8) !== entries || directory + size !== end) return fail();
  let offset = directory, texturePixels = 0;
  const files = new Map<string, Uint8Array>();
  for (let i = 0; i < entries; i++) {
    if (offset + 46 > end || u32(offset) !== 0x02014b50) return fail();
    const nameLength = u16(offset + 28), local = u32(offset + 42), bytes = u32(offset + 20);
    const name = text(offset + 46, nameLength);
    if (!/^(meta\.json|means_[lu]\.webp|quats\.webp|scales\.webp|sh0\.webp|shN_(centroids|labels)\.webp)$/.test(name) || files.has(name) ||
        u16(offset + 10) !== 0 || u32(offset + 24) !== bytes || (u16(offset + 8) & ~0x808) !== 0 ||
        local + 30 > directory || u32(local) !== 0x04034b50 || u16(local + 8) !== 0) return fail();
    const start = local + 30 + u16(local + 26) + u16(local + 28);
    if (start + bytes > directory || text(local + 30, u16(local + 26)) !== name) return fail();
    files.set(name, input.subarray(start, start + bytes));
    offset += 46 + nameLength + u16(offset + 30) + u16(offset + 32);
  }
  if (offset !== end) return fail();
  const metaFile = files.get("meta.json");
  if (!metaFile || metaFile.byteLength > 128 * 1024) return fail();
  const meta = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(metaFile));
  if (!meta || meta.version !== 2 || meta.count !== count) return fail();
  const referenced = new Set<string>();
  for (const key of ["means", "quats", "scales", "sh0", "shN"]) {
    if (key === "shN" && !meta.shN) continue;
    const list = meta[key]?.files;
    if (!Array.isArray(list) || list.length !== (key === "means" || key === "shN" ? 2 : 1)) return fail();
    for (const name of list) {
      if (typeof name !== "string" || !name.endsWith(".webp") || !files.has(name) || referenced.has(name)) return fail();
      referenced.add(name);
    }
  }
  if (referenced.size !== files.size - 1) return fail();
  for (const name of referenced) {
    const bytes = files.get(name)!;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    // libwebp lossless output is one VP8L chunk. No animation, external data,
    // canvas-size extension or second dimension-bearing chunk is admitted.
    if (bytes.byteLength < 25 || view.getUint32(0, true) !== 0x46464952 || view.getUint32(8, true) !== 0x50424557 ||
        view.getUint32(12, true) !== 0x4c385056 || view.getUint32(4, true) + 8 !== bytes.byteLength || bytes[20] !== 0x2f) return fail();
    const compressed = view.getUint32(16, true), dimensions = view.getUint32(21, true);
    if (20 + compressed + (compressed % 2) !== bytes.byteLength || dimensions >>> 29 !== 0) return fail();
    const width = (dimensions & 0x3fff) + 1, height = ((dimensions >>> 14) & 0x3fff) + 1;
    if (width > 2048 || height > 2048) return fail();
    texturePixels += width * height;
    if (texturePixels > 8 * 1024 * 1024) return fail();
  }
  return { textures: referenced.size, texturePixels };
}
