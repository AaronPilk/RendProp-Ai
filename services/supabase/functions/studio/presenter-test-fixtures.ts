// Synthetic MP4 timing metadata, not a playable video or a quality fixture.
function box(kind: string, data: Uint8Array) { const b = new Uint8Array(data.length + 8); new DataView(b.buffer).setUint32(0, b.length); b.set(new TextEncoder().encode(kind), 4); b.set(data, 8); return b; }
function concat(...parts: Uint8Array[]) { const b = new Uint8Array(parts.reduce((n, a) => n + a.length, 0)); let at = 0; for (const p of parts) { b.set(p, at); at += p.length; } return b; }
export function syntheticPresenterMP4(seconds = 5): Uint8Array<ArrayBuffer> {
  const b = new Uint8Array(24), v = new DataView(b.buffer); v.setUint32(12, 1000); v.setUint32(16, seconds * 1000);
  const tk = new Uint8Array(24); new DataView(tk.buffer).setUint32(20, seconds * 1000);
  const h = new Uint8Array(12); h.set(new TextEncoder().encode("vide"), 8);
  const times = new Uint8Array(16), t = new DataView(times.buffer); t.setUint32(4, 1); t.setUint32(8, 1); t.setUint32(12, seconds * 1000);
  const sizes = new Uint8Array(12), z = new DataView(sizes.buffer); z.setUint32(4, 8); z.setUint32(8, 1);
  const stbl = box("stbl", concat(box("stts", times), box("stsz", sizes)));
  const mdia = box("mdia", concat(box("mdhd", b), box("hdlr", h), box("minf", stbl)));
  return box("moov", concat(box("mvhd", b), box("trak", concat(box("tkhd", tk), mdia))));
}
