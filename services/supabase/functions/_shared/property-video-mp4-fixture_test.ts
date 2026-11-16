// Test-only AVC MP4 transport fixture; no decoded image/video quality claim.
function ok(v:unknown):asserts v{if(!v)throw new Error("fixture assertion");}
function equal(a:unknown,b:unknown){ok(JSON.stringify(a)===JSON.stringify(b));}
function concat(...items: Uint8Array[]) {
  const out = new Uint8Array(items.reduce((n, x) => n + x.length, 0));
  let at = 0;
  for (const item of items) {
    out.set(item, at);
    at += item.length;
  }
  return out;
}
function u32(...values: number[]) {
  const out = new Uint8Array(values.length * 4), v = new DataView(out.buffer);
  values.forEach((n, i) => v.setUint32(i * 4, n));
  return out;
}
function box(type: string, ...payload: Uint8Array[]) {
  const bytes = concat(...payload);
  return concat(u32(bytes.length + 8), new TextEncoder().encode(type), bytes);
}
function fromHex(hex: string) {
  return Uint8Array.from(hex.match(/../g)!.map((s) => parseInt(s, 16)));
}
class Writer {
  bits: number[] = [];
  put(n: number, width: number) {
    for (let i = width - 1; i >= 0; i--) {
      this.bits.push(Math.floor(n / 2 ** i) & 1);
    }
    return this;
  }
  ue(n: number) {
    const size = Math.floor(Math.log2(n + 1));
    this.put(0, size);
    this.put(n + 1, size + 1);
    return this;
  }
  se(n: number) {
    return this.ue(n <= 0 ? -n * 2 : n * 2 - 1);
  }
  finish(nal: number) {
    this.put(1, 1);
    while (this.bits.length % 8) this.put(0, 1);
    const raw = Uint8Array.from(
      { length: this.bits.length / 8 },
      (_, i) =>
        this.bits.slice(i * 8, i * 8 + 8).reduce((n, b) => n * 2 + b, 0),
    );
    const escaped: number[] = [nal];
    let zeros = 0;
    for (const n of raw) {
      if (zeros >= 2 && n <= 3) {
        escaped.push(3);
        zeros = 0;
      }
      escaped.push(n);
      zeros = n === 0 ? zeros + 1 : 0;
    }
    return new Uint8Array(escaped);
  }
}
function sequence(width: number, height: number) {
  const codedW = Math.ceil(width / 16) * 16,
    codedH = Math.ceil(height / 16) * 16;
  const b = new Writer().put(66, 8).put(0, 8).put(31, 8).ue(0).ue(0).ue(2).ue(1)
    .put(0, 1).ue(codedW / 16 - 1).ue(codedH / 16 - 1).put(1, 1).put(1, 1);
  const crop = codedW !== width || codedH !== height;
  b.put(Number(crop), 1);
  if (crop) b.ue(0).ue((codedW - width) / 2).ue(0).ue((codedH - height) / 2);
  return b.put(0, 1).finish(0x67);
}
const PPS = new Writer().ue(0).ue(0).put(0, 1).put(0, 1).ue(0).ue(0).ue(0).put(
  0,
  1,
).put(0, 2).se(0).se(0).se(0).put(1, 1).put(0, 1).put(0, 1).finish(0x68);
type Options = {
  width?: number;
  height?: number;
  fps?: number;
  seconds?: number;
  samples?: number;
  delta?: number;
  scale?: number;
  sps?: Uint8Array;
  profile?: number;
  compatibility?: number;
  level?: number;
  pps?: Uint8Array;
  mdatBytes?: number;
  tailMoov?: boolean;
  extendedMdat?: boolean;
  ctts?: boolean;
  timings?: [number, number][];
  fragment?: boolean;
  duplicateVideo?: boolean;
};
type Fixture = {
  total: number;
  segments: { start: number; bytes: Uint8Array }[];
  moov: Uint8Array;
  requests: { first: number; last: number; headers: Headers }[];
  fetch: (url: string, init: RequestInit) => Promise<Response>;
};
export function propertyMP4Fixture(o: Options = {}): Fixture {
  const width = o.width ?? 320,
    height = o.height ?? 240,
    fps = o.fps ?? 60,
    seconds = o.seconds ?? 1;
  const scale = o.scale ?? fps * 1000, delta = o.delta ?? 1000;
  const timing = o.timings ??
    [[o.samples ?? Math.round(seconds * scale / delta), delta]];
  const samples = timing.reduce((n, row) => n + row[0], 0),
    ticks = timing.reduce((n, row) => n + row[0] * row[1], 0);
  const seq = o.sps ?? sequence(width, height), pps = o.pps ?? PPS;
  const cfg = concat(
    new Uint8Array([
      1,
      o.profile ?? seq[1],
      o.compatibility ?? seq[2],
      o.level ?? seq[3],
      255,
      225,
    ]),
    new Uint8Array([seq.length >> 8, seq.length & 255]),
    seq,
    new Uint8Array([1, pps.length >> 8, pps.length & 255]),
    pps,
  );
  const visual = new Uint8Array(78), visualV = new DataView(visual.buffer);
  visualV.setUint16(6, 1);
  visualV.setUint16(24, width);
  visualV.setUint16(26, height);
  visualV.setUint16(40, 1);
  visualV.setUint16(74, 24);
  visualV.setInt16(76, -1);
  const tkhd = new Uint8Array(84), tk = new DataView(tkhd.buffer);
  tk.setUint32(0, 3);
  tk.setUint32(12, 1);
  tk.setUint32(20, seconds * 1000);
  tk.setInt32(40, 65536);
  tk.setInt32(56, 65536);
  tk.setInt32(72, 0x40000000);
  tk.setUint32(76, width * 65536);
  tk.setUint32(80, height * 65536);
  const mvhd = new Uint8Array(100), mv = new DataView(mvhd.buffer);
  mv.setUint32(12, 1000);
  mv.setUint32(16, seconds * 1000);
  const mdhd = new Uint8Array(24), md = new DataView(mdhd.buffer);
  md.setUint32(12, scale);
  md.setUint32(16, ticks);
  const hdlr = new Uint8Array(25);
  hdlr.set(new TextEncoder().encode("vide"), 8);
  const ftyp = box(
    "ftyp",
    new TextEncoder().encode("isom"),
    u32(0),
    new TextEncoder().encode("isomavc1"),
  );
  function movie(offset: number) {
    const track = box(
      "trak",
      box("tkhd", tkhd),
      box(
        "mdia",
        box("mdhd", mdhd),
        box("hdlr", hdlr),
        box(
          "minf",
          box("dinf", box("dref", u32(0, 1), box("url ", u32(1)))),
          box(
            "stbl",
            box("stsd", u32(0, 1), box("avc1", visual, box("avcC", cfg))),
            box("stts", u32(0, timing.length, ...timing.flat())),
            box("stsz", u32(0, 1, samples)),
            box("stsc", u32(0, 1, 1, samples, 1)),
            box("stco", u32(0, 1, offset)),
            ...(o.ctts ? [box("ctts", u32(0, 1, samples, delta * 2))] : []),
          ),
        ),
      ),
    );
    return box(
      "moov",
      box("mvhd", mvhd),
      track,
      ...(o.duplicateVideo ? [track] : []),
      ...(o.fragment ? [box("mvex")] : []),
    );
  }
  let moov = movie(0);
  const mdatBytes = o.mdatBytes ?? Math.max(samples, 16),
    mdatWidth = o.extendedMdat ? 16 : 8;
  const mdatStart = ftyp.length + (o.tailMoov ? 0 : moov.length),
    payloadStart = mdatStart + mdatWidth;
  moov = movie(payloadStart);
  const mh = o.extendedMdat
    ? concat(u32(1), new TextEncoder().encode("mdat"), new Uint8Array(8))
    : concat(u32(mdatBytes + 8), new TextEncoder().encode("mdat"));
  if (o.extendedMdat) {
    new DataView(mh.buffer).setBigUint64(8, BigInt(mdatBytes + 16));
  }
  const moovStart = o.tailMoov
    ? mdatStart + mdatWidth + mdatBytes
    : ftyp.length;
  const total = ftyp.length + moov.length + mdatWidth + mdatBytes;
  const segments = [{ start: 0, bytes: ftyp }, {
    start: moovStart,
    bytes: moov,
  }, { start: mdatStart, bytes: mh }];
  const requests: Fixture["requests"] = [];
  const f: Fixture = {
    total,
    segments,
    moov,
    requests,
    fetch: (_url, init) => {
      equal(init.redirect, "error");
      equal(init.method, "GET");
      const headers = new Headers(init.headers),
        match = /^bytes=(\d+)-(\d+)$/.exec(headers.get("range") ?? "");
      ok(match);
      const first = Number(match[1]), last = Number(match[2]);
      requests.push({ first, last, headers });
      const bytes = new Uint8Array(last - first + 1);
      for (const segment of segments) {
        const start = Math.max(first, segment.start),
          end = Math.min(last + 1, segment.start + segment.bytes.length);
        if (end > start) {
          bytes.set(
            segment.bytes.subarray(start - segment.start, end - segment.start),
            start - first,
          );
        }
      }
      return Promise.resolve(
        new Response(bytes, {
          status: 206,
          headers: {
            etag: '"fixture-version"',
            "content-range": `bytes ${first}-${last}/${f.total}`,
            "content-length": String(bytes.length),
          },
        }),
      );
    },
  };
  return f;
}
