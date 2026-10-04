// A deliberately narrow, bounded ISO-BMFF/AVC metadata verifier for paid
// Topaz admission. It reads headers and sample tables, never video payloads.
// The caller must authorize and pin an immutable source before using its URL.
// This verifies the supported container/codec contract, not decoded pictures.
import { HttpError } from "../_shared/http.ts";

export type MP4Video = {
  duration_s: number;
  billable_s: number;
  width: number;
  height: number;
  /** Maximum sample cadence, conservatively including any AVC VUI clock. */
  fps: number;
};
type Fetch = (url: string, init: RequestInit) => Promise<Response>;
type Box = { start: number; end: number; type: string };
type Span = { start: number; end: number };
const METADATA_BYTES = 2 * 1024 * 1024;
const TOP_BOXES = 64;
const DEADLINE_MS = 15_000;
const MESSAGE =
  "Video could not be verified. Upload the saved H.264 MP4 clip again.";
function need(condition: unknown): asserts condition {
  if (!condition) throw new HttpError(400, MESSAGE);
}
function unavailable(): never {
  throw new HttpError(409, MESSAGE);
}
function uint64(v: DataView, at: number): number {
  need(at + 8 <= v.byteLength);
  const n = v.getBigUint64(at);
  need(n <= BigInt(Number.MAX_SAFE_INTEGER));
  return Number(n);
}
function tag(v: DataView, at: number): string {
  need(at + 4 <= v.byteLength);
  return String.fromCharCode(...new Uint8Array(v.buffer, v.byteOffset + at, 4));
}
function header(
  v: DataView,
  at: number,
): { size: number; width: number; type: string } {
  need(at + 8 <= v.byteLength);
  const raw = v.getUint32(at), width = raw === 1 ? 16 : 8;
  const size = raw === 1 ? uint64(v, at + 8) : raw;
  need(size >= width);
  return { size, width, type: tag(v, at + 4) };
}
function children(v: DataView, start: number, end: number): Box[] {
  need(start >= 0 && end <= v.byteLength && start <= end);
  const out: Box[] = [];
  while (start < end) {
    need(out.length < 4096);
    const h = header(v, start);
    need(Number.isSafeInteger(start + h.size) && start + h.size <= end);
    out.push({ start: start + h.width, end: start + h.size, type: h.type });
    start += h.size;
  }
  return out;
}
function one(boxes: Box[], type: string): Box {
  const found = boxes.filter((b) => b.type === type);
  need(found.length === 1);
  return found[0];
}
function full(v: DataView, b: Box, versions = [0]): number {
  need(b.start + 4 <= b.end);
  const version = v.getUint8(b.start);
  need(versions.includes(version) && (v.getUint32(b.start) & 0xffffff) === 0);
  return version;
}
function clock(
  v: DataView,
  b: Box,
): { ticks: number; scale: number; seconds: number } {
  const version = full(v, b, [0, 1]), at = b.start + (version === 0 ? 12 : 20);
  need(at + (version === 0 ? 8 : 12) <= b.end);
  const scale = v.getUint32(at),
    ticks = version === 0 ? v.getUint32(at + 4) : uint64(v, at + 4);
  need(scale > 0 && ticks > 0 && (version !== 0 || ticks !== 0xffffffff));
  return { ticks, scale, seconds: ticks / scale };
}

// Exp-Golomb reads are bounded both in length and value; a malformed SPS must
// not produce an unbounded loop or overflow dimensions/crop arithmetic.
class Bits {
  at = 0;
  constructor(readonly bytes: Uint8Array) {}
  read(n: number): number {
    need(n >= 0 && n <= 32 && this.at + n <= this.bytes.length * 8);
    let value = 0;
    for (let i = 0; i < n; i++, this.at++) {
      value = value * 2 +
        ((this.bytes[this.at >> 3] >> (7 - (this.at & 7))) & 1);
    }
    return value;
  }
  ue(max = 1_000_000): number {
    let zeros = 0;
    while (this.read(1) === 0) need(++zeros <= 30);
    const n = 2 ** zeros - 1 + this.read(zeros);
    need(n <= max);
    return n;
  }
  se(max = 1_000_000): number {
    const n = this.ue(max * 2);
    return n & 1 ? (n + 1) / 2 : -n / 2;
  }
  finish() {
    need(this.read(1) === 1);
    while (this.at < this.bytes.length * 8) need(this.read(1) === 0);
  }
  more(): boolean {
    if (this.at >= this.bytes.length * 8) return false;
    for (let bit = this.at; bit < this.bytes.length * 8; bit++) {
      const value = (this.bytes[bit >> 3] >> (7 - (bit & 7))) & 1;
      if (value !== (bit === this.at ? 1 : 0)) return true;
    }
    return false;
  }
}
function rbsp(nal: Uint8Array, type: number): Uint8Array {
  need(
    nal.length >= 2 && nal.length <= 4096 && (nal[0] & 0x80) === 0 &&
      (nal[0] & 0x60) !== 0 && (nal[0] & 31) === type,
  );
  const out: number[] = [];
  let zeros = 0;
  for (let i = 1; i < nal.length; i++) {
    const n = nal[i];
    if (zeros >= 2 && n === 3) {
      need(i + 1 < nal.length && nal[i + 1] <= 3);
      zeros = 0;
      continue;
    }
    need(!(zeros >= 2 && n <= 2));
    out.push(n);
    zeros = n === 0 ? zeros + 1 : 0;
  }
  return new Uint8Array(out);
}
function hrd(b: Bits) {
  const count = b.ue(31) + 1;
  b.read(4);
  b.read(4);
  for (let i = 0; i < count; i++) {
    b.ue();
    b.ue();
    b.read(1);
  }
  b.read(5);
  b.read(5);
  b.read(5);
  b.read(5);
}
function vui(b: Bits): number | null {
  if (b.read(1)) {
    const aspect = b.read(8);
    if (aspect === 255) {
      const x = b.read(16), y = b.read(16);
      need(x > 0 && x === y);
    } else need(aspect === 1);
  }
  if (b.read(1)) b.read(1);
  if (b.read(1)) {
    b.read(3);
    b.read(1);
    if (b.read(1)) {
      b.read(8);
      b.read(8);
      b.read(8);
    }
  }
  if (b.read(1)) {
    b.ue(5);
    b.ue(5);
  }
  let fps: number | null = null;
  if (b.read(1)) {
    const units = b.read(32), scale = b.read(32);
    b.read(1);
    need(units > 0 && scale > 0);
    fps = scale / (2 * units);
    need(fps > 0 && fps <= 240);
  }
  const nalHrd = b.read(1);
  if (nalHrd) hrd(b);
  const vclHrd = b.read(1);
  if (vclHrd) hrd(b);
  if (nalHrd || vclHrd) b.read(1);
  need(b.read(1) === 0); // pic_struct_present can signal field/repeated pictures.
  if (b.read(1)) {
    b.read(1);
    b.ue(16);
    b.ue(16);
    b.ue(16);
    b.ue(16);
    b.ue(16);
    b.ue(16);
  }
  return fps;
}
type SPS = {
  id: number;
  profile: number;
  compatibility: number;
  level: number;
  width: number;
  height: number;
  fps: number | null;
};
function sps(nal: Uint8Array): SPS {
  const b = new Bits(rbsp(nal, 7));
  const profile = b.read(8),
    compatibility = b.read(8),
    level = b.read(8),
    id = b.ue(31);
  need(
    [66, 77, 100].includes(profile) && (compatibility & 3) === 0 && level > 0 &&
      level <= 62,
  );
  if (profile === 100) {
    need(b.ue(3) === 1); // Only 8-bit, 4:2:0 progressive AVC.
    need(b.ue(6) === 0 && b.ue(6) === 0);
    b.read(1);
    if (b.read(1)) {
      for (let list = 0; list < 8; list++) {
        if (!b.read(1)) continue;
        let last = 8, next = 8;
        for (let j = 0; j < (list < 6 ? 16 : 64); j++) {
          if (next) next = (last + b.se(128) + 256) % 256;
          last = next || last;
        }
      }
    }
  }
  b.ue(12);
  const order = b.ue(2);
  if (order === 0) b.ue(12);
  if (order === 1) {
    b.read(1);
    b.se();
    b.se();
    const cycle = b.ue(255);
    for (let i = 0; i < cycle; i++) b.se();
  }
  b.ue(16);
  b.read(1);
  const width = (b.ue(1023) + 1) * 16, height = (b.ue(1023) + 1) * 16;
  need(b.read(1) === 1); // Interlacing changes the frame/field clock.
  b.read(1);
  let left = 0, right = 0, top = 0, bottom = 0;
  if (b.read(1)) {
    left = b.ue(8192);
    right = b.ue(8192);
    top = b.ue(8192);
    bottom = b.ue(8192);
  }
  const displayWidth = width - (left + right) * 2,
    displayHeight = height - (top + bottom) * 2;
  need(displayWidth > 0 && displayHeight > 0);
  const fps = b.read(1) ? vui(b) : null;
  b.finish();
  return {
    id,
    profile,
    compatibility,
    level,
    width: displayWidth,
    height: displayHeight,
    fps,
  };
}
function avcc(v: DataView, b: Box): SPS {
  need(b.end - b.start >= 11 && v.getUint8(b.start) === 1);
  need(v.getUint8(b.start + 4) === 255 && v.getUint8(b.start + 5) === 225);
  let at = b.start + 6;
  function nal(): Uint8Array {
    need(at + 2 <= b.end);
    const n = v.getUint16(at);
    at += 2;
    need(n > 0 && n <= 4096 && at + n <= b.end);
    const bytes = new Uint8Array(v.buffer, v.byteOffset + at, n);
    at += n;
    return bytes;
  }
  const info = sps(nal());
  need(
    info.profile === v.getUint8(b.start + 1) &&
      info.compatibility === v.getUint8(b.start + 2) &&
      info.level === v.getUint8(b.start + 3),
  );
  need(at < b.end && v.getUint8(at++) === 1);
  const pps = new Bits(rbsp(nal(), 8));
  pps.ue(255);
  need(pps.ue(31) === info.id);
  pps.read(1);
  pps.read(1);
  need(pps.ue(7) === 0); // No flexible slice groups.
  pps.ue(31);
  pps.ue(31);
  pps.read(1);
  need(pps.read(2) <= 2);
  const qp = pps.se(51), qs = pps.se(51), chromaQp = pps.se(12);
  need(
    qp >= -26 && qp <= 25 && qs >= -26 && qs <= 25 && Math.abs(chromaQp) <= 12,
  );
  pps.read(1);
  pps.read(1);
  need(pps.read(1) === 0);
  if (pps.more()) {
    const transform = pps.read(1);
    if (pps.read(1)) {
      for (let list = 0; list < 6 + transform * 2; list++) {
        if (!pps.read(1)) continue;
        let last = 8, next = 8;
        for (let j = 0; j < (list < 6 ? 16 : 64); j++) {
          if (next) next = (last + pps.se(128) + 256) % 256;
          last = next || last;
        }
      }
    }
    pps.se(12);
  }
  pps.finish();
  // High-profile extension bytes, when present, must agree with the SPS.
  if (at < b.end) {
    need(
      info.profile === 100 && at + 4 === b.end && v.getUint8(at) === 253 &&
        v.getUint8(at + 1) === 248 && v.getUint8(at + 2) === 248 &&
        v.getUint8(at + 3) === 0,
    );
    at += 4;
  }
  need(at === b.end);
  return info;
}

function geometry(v: DataView, b: Box): SPS {
  full(v, b);
  need(b.start + 8 <= b.end && v.getUint32(b.start + 4) === 1);
  const entry = one(children(v, b.start + 8, b.end), "avc1");
  need(
    entry.end - entry.start >= 78 && v.getUint16(entry.start + 6) === 1 &&
      v.getUint16(entry.start + 40) === 1,
  );
  const extensions = children(v, entry.start + 78, entry.end);
  need(
    extensions.every((e) =>
      ["avcC", "pasp", "colr", "btrt", "fiel", "chrm"].includes(e.type)
    ),
  );
  // AVAssetWriter emits these QuickTime extensions even for progressive AVC.
  // Admit only the observed unambiguous progressive/unspecified forms.
  for (
    const e of extensions.filter((e) => e.type === "fiel" || e.type === "chrm")
  ) {
    need(
      e.end - e.start === 2 && v.getUint8(e.start + 1) === 0 &&
        v.getUint8(e.start) === (e.type === "fiel" ? 1 : 0),
    );
  }
  const info = avcc(v, one(extensions, "avcC"));
  need(
    v.getUint16(entry.start + 24) === info.width &&
      v.getUint16(entry.start + 26) === info.height,
  );
  const aspect = extensions.filter((e) => e.type === "pasp");
  need(aspect.length <= 1);
  if (aspect.length) {
    need(
      aspect[0].end - aspect[0].start === 8 &&
        v.getUint32(aspect[0].start) > 0 &&
        v.getUint32(aspect[0].start) === v.getUint32(aspect[0].start + 4),
    );
  }
  return info;
}
function trackHeader(
  v: DataView,
  b: Box,
  movieScale: number,
): { seconds: number; width: number; height: number; rotated: boolean } {
  need(b.start + 4 <= b.end);
  const version = v.getUint8(b.start), flags = v.getUint32(b.start) & 0xffffff;
  // AVAssetWriter's playable single-video output uses zero track flags.
  // Inspect all tracks regardless of flags; flags cannot hide a second video.
  need([0, 1].includes(version) && (flags & ~7) === 0);
  const durationAt = b.start + (version === 0 ? 20 : 28),
    matrixAt = b.start + (version === 0 ? 40 : 52);
  need(matrixAt + 44 === b.end);
  const ticks = version === 0 ? v.getUint32(durationAt) : uint64(v, durationAt);
  need(ticks > 0);
  const matrix = Array.from(
    { length: 9 },
    (_, i) => v.getInt32(matrixAt + i * 4),
  );
  need(matrix[2] === 0 && matrix[5] === 0 && matrix[8] === 0x40000000);
  const [a, b1, , c, d] = matrix;
  const identity = a === 65536 && b1 === 0 && c === 0 && d === 65536;
  const half = a === -65536 && b1 === 0 && c === 0 && d === -65536;
  const quarter = a === 0 && d === 0 &&
    ((b1 === 65536 && c === -65536) || (b1 === -65536 && c === 65536));
  need(identity || half || quarter);
  // Translation may position a rotated portrait, but cannot scale/crop it.
  need(
    Math.abs(matrix[6]) <= 16384 * 65536 &&
      Math.abs(matrix[7]) <= 16384 * 65536,
  );
  const w = v.getUint32(matrixAt + 36), h = v.getUint32(matrixAt + 40);
  need(w > 0 && h > 0 && w % 65536 === 0 && h % 65536 === 0);
  return {
    seconds: ticks / movieScale,
    width: w / 65536,
    height: h / 65536,
    rotated: quarter,
  };
}
function editList(
  v: DataView,
  boxes: Box[],
  movieScale: number,
  trackSeconds: number,
  mediaTicks: number,
) {
  const edits = boxes.filter((b) => b.type === "edts");
  need(edits.length <= 1);
  if (!edits.length) return;
  const entries = children(v, edits[0].start, edits[0].end),
    e = one(entries, "elst");
  need(entries.length === 1);
  const version = full(v, e, [0, 1]);
  need(
    e.start + 8 + (version === 0 ? 12 : 20) === e.end &&
      v.getUint32(e.start + 4) === 1,
  );
  const at = e.start + 8,
    segment = version === 0 ? v.getUint32(at) : uint64(v, at);
  const mediaTime = version === 0
    ? v.getInt32(at + 4)
    : Number(v.getBigInt64(at + 8));
  const rateAt = at + (version === 0 ? 8 : 16);
  need(
    Number.isSafeInteger(mediaTime) && mediaTime >= 0 &&
      mediaTime < mediaTicks && segment > 0 &&
      Math.abs(segment / movieScale - trackSeconds) <= 0.001 &&
      v.getInt16(rateAt) === 1 && v.getInt16(rateAt + 2) === 0,
  );
}
function table(v: DataView, b: Box, width: number, max = 65536): number {
  full(v, b);
  need(b.start + 8 <= b.end);
  const n = v.getUint32(b.start + 4);
  need(n > 0 && n <= max && b.start + 8 + n * width === b.end);
  return n;
}
function sampleTimes(
  v: DataView,
  samples: Box[],
  scale: number,
  mediaTicks: number,
): { count: number; fps: number } {
  const b = one(samples, "stts"), entries = table(v, b, 8);
  let count = 0, ticks = 0, fps = 0;
  for (let i = 0; i < entries; i++) {
    const at = b.start + 8 + i * 8,
      n = v.getUint32(at),
      delta = v.getUint32(at + 4);
    need(n > 0 && delta > 0);
    count += n;
    ticks += n * delta;
    fps = Math.max(fps, scale / delta);
    need(Number.isSafeInteger(ticks) && count <= 720_000);
  }
  need(ticks === mediaTicks && fps > 0 && fps <= 240);
  // Composition offsets may reorder pictures, not introduce unpriced seconds.
  const ctts = samples.filter((s) => s.type === "ctts");
  need(ctts.length <= 1);
  if (ctts.length) {
    const c = ctts[0], version = full(v, c, [0, 1]);
    need(c.start + 8 <= c.end);
    const entries = v.getUint32(c.start + 4);
    need(
      entries > 0 && entries <= 65536 && c.start + 8 + entries * 8 === c.end,
    );
    let total = 0;
    for (let i = 0; i < entries; i++) {
      const at = c.start + 8 + i * 8,
        n = v.getUint32(at),
        offset = version ? v.getInt32(at + 4) : v.getUint32(at + 4);
      need(n > 0 && Math.abs(offset / scale) <= 0.15);
      total += n;
    }
    need(total === count);
  }
  return { count, fps };
}
function sampleExtents(
  v: DataView,
  samples: Box[],
  count: number,
  mdats: Span[],
) {
  const sizes = one(samples, "stsz");
  full(v, sizes);
  need(sizes.start + 12 <= sizes.end);
  const fixed = v.getUint32(sizes.start + 4), n = v.getUint32(sizes.start + 8);
  need(n === count && sizes.start + 12 + (fixed ? 0 : count * 4) === sizes.end);
  const offsets = samples.filter((s) => s.type === "stco" || s.type === "co64");
  need(offsets.length === 1);
  const offsetsBox = offsets[0],
    width = offsetsBox.type === "stco" ? 4 : 8,
    chunks = table(v, offsetsBox, width);
  const sc = one(samples, "stsc"), entries = table(v, sc, 12);
  const mappings: { first: number; per: number }[] = [];
  for (let i = 0; i < entries; i++) {
    const at = sc.start + 8 + i * 12,
      first = v.getUint32(at),
      per = v.getUint32(at + 4);
    need(
      first >= 1 && first <= chunks && per > 0 && per <= count &&
        v.getUint32(at + 8) === 1 &&
        (i === 0 ? first === 1 : first > mappings[i - 1].first),
    );
    mappings.push({ first, per });
  }
  let sample = 0, map = 0;
  const spans: Span[] = [];
  for (let chunk = 1; chunk <= chunks; chunk++) {
    if (map + 1 < entries && mappings[map + 1].first === chunk) map++;
    const at = offsetsBox.start + 8 + (chunk - 1) * width;
    const start = width === 4 ? v.getUint32(at) : uint64(v, at);
    let bytes = 0;
    for (let i = 0; i < mappings[map].per; i++) {
      need(sample < count);
      const size = fixed || v.getUint32(sizes.start + 12 + sample * 4);
      need(size > 0);
      bytes += size;
      sample++;
      need(Number.isSafeInteger(bytes));
    }
    need(
      Number.isSafeInteger(start + bytes) &&
        mdats.some((m) => start >= m.start && start + bytes <= m.end),
    );
    spans.push({ start, end: start + bytes });
  }
  need(sample === count);
  spans.sort((a, b) => a.start - b.start);
  for (let i = 1; i < spans.length; i++) {
    need(spans[i].start >= spans[i - 1].end);
  }
}
function movie(bytes: Uint8Array, mdats: Span[]): MP4Video {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    root = header(v, 0);
  need(root.type === "moov" && root.size === bytes.length);
  const boxes = children(v, root.width, bytes.length);
  need(!boxes.some((b) => ["mvex", "cmov"].includes(b.type)));
  const timeline = clock(v, one(boxes, "mvhd")),
    tracks = boxes.filter((b) => b.type === "trak");
  need(tracks.length > 0 && tracks.length <= 8);
  let result: MP4Video | null = null;
  for (const track of tracks) {
    const trackBoxes = children(v, track.start, track.end);
    need(!trackBoxes.some((b) => ["tapt", "tref"].includes(b.type)));
    const mdia = one(trackBoxes, "mdia"),
      media = children(v, mdia.start, mdia.end),
      handler = one(media, "hdlr");
    full(v, handler);
    need(handler.start + 12 <= handler.end);
    const type = tag(v, handler.start + 8);
    need(type === "vide" || type === "soun");
    const mediaClock = clock(v, one(media, "mdhd"));
    need(Math.abs(mediaClock.seconds - timeline.seconds) <= 0.15);
    const minf = one(media, "minf"),
      stbl = one(children(v, minf.start, minf.end), "stbl"),
      samples = children(v, stbl.start, stbl.end);
    need(
      !samples.some((b) => ["stz2", "senc", "saiz", "saio"].includes(b.type)),
    );
    if (type === "vide") {
      need(!samples.some((b) => ["sgpd", "sbgp"].includes(b.type)));
    }
    const times = sampleTimes(v, samples, mediaClock.scale, mediaClock.ticks);
    sampleExtents(v, samples, times.count, mdats);
    // Data references must name this file, never an external video URL.
    const dinf = one(children(v, minf.start, minf.end), "dinf"),
      dref = one(children(v, dinf.start, dinf.end), "dref");
    full(v, dref);
    need(dref.start + 8 <= dref.end && v.getUint32(dref.start + 4) === 1);
    const refs = children(v, dref.start + 8, dref.end),
      local = one(refs, "url ");
    need(
      refs.length === 1 && local.end - local.start === 4 &&
        v.getUint32(local.start) === 1,
    );
    if (type === "soun") continue;
    need(result === null);
    const info = geometry(v, one(samples, "stsd")),
      tkhd = trackHeader(v, one(trackBoxes, "tkhd"), timeline.scale);
    need(
      info.width === tkhd.width && info.height === tkhd.height &&
        Math.abs(tkhd.seconds - timeline.seconds) <= 0.15,
    );
    editList(v, trackBoxes, timeline.scale, tkhd.seconds, mediaClock.ticks);
    result = {
      duration_s: timeline.seconds,
      billable_s: Math.max(timeline.seconds, mediaClock.seconds, tkhd.seconds),
      width: tkhd.rotated ? info.height : info.width,
      height: tkhd.rotated ? info.width : info.height,
      fps: Math.max(times.fps, info.fps ?? 0),
    };
  }
  need(result);
  return result;
}

/** Source URL is server-selected. Byte/version checks do not replace that
 * authorization or immutable publication fence for the provider's later GET. */
export async function probeMP4Video(
  url: string,
  fetcher: Fetch,
): Promise<MP4Video> {
  try {
    const parsed = new URL(url);
    need(
      parsed.protocol === "https:" && !parsed.username && !parsed.password &&
        !parsed.hash,
    );
  } catch {
    throw new HttpError(400, MESSAGE);
  }
  const abort = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    abort.abort();
  }, DEADLINE_MS);
  let total: number | null = null, etag: string | null = null, usedBytes = 0;
  const deadline = new Promise<never>((_, reject) =>
    abort.signal.addEventListener(
      "abort",
      () => reject(new HttpError(409, MESSAGE)),
      { once: true },
    )
  );
  // A synchronously throwing injected transport may leave no race attached.
  // Keep final cancellation handled even in that pre-await failure path.
  void deadline.catch(() => {});
  // Each await is also deadline-bound for injected/noncompliant transports.
  function bounded<T>(work: Promise<T>): Promise<T> {
    return Promise.race([work, deadline]);
  }
  async function range(first: number, last: number): Promise<Uint8Array> {
    need(
      Number.isSafeInteger(first) && Number.isSafeInteger(last) && first >= 0 &&
        last >= first && last - first + 1 <= METADATA_BYTES,
    );
    if (timedOut) unavailable();
    const res = await bounded(fetcher(url, {
      method: "GET",
      headers: {
        Range: `bytes=${first}-${last}`,
        "Accept-Encoding": "identity",
        ...(etag ? { "If-Match": etag } : {}),
      },
      redirect: "error",
      signal: abort.signal,
      cache: "no-store",
    }));
    const match = /^bytes (\d{1,16})-(\d{1,16})\/(\d{1,16})$/.exec(
      res.headers.get("content-range") ?? "",
    );
    const currentTag = res.headers.get("etag"), length = last - first + 1;
    if (
      res.status !== 206 || !match || Number(match[1]) !== first ||
      Number(match[2]) !== last || !currentTag ||
      !/^"[\x21\x23-\x7e]{1,254}"$/.test(currentTag) ||
      (etag !== null && etag !== currentTag) ||
      ![null, "identity"].includes(res.headers.get("content-encoding"))
    ) {
      void res.body?.cancel().catch(() => {});
      unavailable();
    }
    const observedTotal = Number(match[3]);
    if (!Number.isSafeInteger(observedTotal) || observedTotal <= last) {
      void res.body?.cancel().catch(() => {});
      need(false);
    }
    if (total !== null && observedTotal !== total) {
      void res.body?.cancel().catch(() => {});
      unavailable();
    }
    const declaredLength = res.headers.get("content-length");
    if (
      declaredLength !== null &&
      (!/^\d+$/.test(declaredLength) || Number(declaredLength) !== length)
    ) {
      void res.body?.cancel().catch(() => {});
      unavailable();
    }
    total = observedTotal;
    etag = currentTag;
    const reader = res.body?.getReader();
    if (!reader) unavailable();
    const bytes = new Uint8Array(length);
    let used = 0;
    try {
      while (true) {
        const chunk = await bounded(reader.read());
        if (chunk.done) break;
        need(used + chunk.value.length <= length);
        usedBytes += chunk.value.length;
        need(usedBytes <= METADATA_BYTES + TOP_BOXES * 16);
        bytes.set(chunk.value, used);
        used += chunk.value.length;
      }
    } finally {
      void reader.cancel().catch(() => {});
    }
    if (used !== length) unavailable();
    return bytes;
  }
  try {
    let offset = 0, moov: Uint8Array | null = null;
    const mdats: Span[] = [];
    for (let count = 0; count < TOP_BOXES; count++) {
      if (total !== null && offset === total) break;
      if (total !== null) need(offset + 8 <= total);
      const bytes = await range(
        offset,
        total === null ? offset + 15 : Math.min(offset + 15, total - 1),
      );
      const h = header(new DataView(bytes.buffer), 0);
      need(
        total !== null && Number.isSafeInteger(offset + h.size) &&
          offset + h.size <= total,
      );
      need(!["moof", "mfra", "sidx"].includes(h.type));
      if (h.type === "moov") {
        need(moov === null && h.size <= METADATA_BYTES);
        moov = await range(offset, offset + h.size - 1);
      } else if (h.type === "mdat") {
        mdats.push({ start: offset + h.width, end: offset + h.size });
      } else need(["ftyp", "free", "skip", "wide"].includes(h.type));
      offset += h.size;
    }
    need(offset === total && moov !== null && mdats.length > 0);
    return movie(moov, mdats);
  } catch (error) {
    if (error instanceof HttpError) throw error;
    unavailable();
  } finally {
    clearTimeout(timer);
    abort.abort();
  }
}
