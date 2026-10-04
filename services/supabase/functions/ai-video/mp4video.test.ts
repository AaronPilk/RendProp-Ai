import { HttpError } from "../_shared/http.ts";
import { probeMP4Video } from "./mp4video.ts";

function ok(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(a: unknown, b: unknown) {
  ok(
    JSON.stringify(a) === JSON.stringify(b),
    `${JSON.stringify(a)} != ${JSON.stringify(b)}`,
  );
}
async function rejects(run: () => Promise<unknown>, status?: number) {
  try {
    await run();
  } catch (e) {
    ok(e instanceof HttpError);
    if (status) equal(e.status, status);
    ok(e.message.includes("Upload the saved H.264 MP4 clip again"));
    ok(!e.message.includes("fixture.invalid"));
    return;
  }
  throw new Error("unsupported media was accepted");
}
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
function fixture(o: Options = {}): Fixture {
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
const URL = "https://fixture.invalid/saved.mp4";
function locate(bytes: Uint8Array, type: string) {
  const needle = new TextEncoder().encode(type);
  for (let i = 4; i + 4 <= bytes.length; i++) {
    if (needle.every((n, j) => bytes[i + j] === n)) return i + 4;
  }
  throw new Error(`missing fixture ${type}`);
}
function mutate(
  f: Fixture,
  type: string,
  at: number,
  value: number,
  width = 4,
) {
  const offset = locate(f.moov, type) + at, v = new DataView(f.moov.buffer);
  if (width === 2) v.setUint16(offset, value);
  else v.setUint32(offset, value);
}

Deno.test("authoritative AVC geometry/duration/cadence comes from bytes, with no client metadata", async () => {
  const f = fixture({ width: 3840, height: 2160, seconds: 300 });
  equal(await probeMP4Video(URL, f.fetch), {
    duration_s: 300,
    billable_s: 300,
    width: 3840,
    height: 2160,
    fps: 60,
  });
  ok(f.requests.length <= 5);
  ok(f.requests.reduce((n, r) => n + r.last - r.first + 1, 0) < 2048);
  equal(f.requests[0].headers.get("if-match"), null);
  ok(
    f.requests.slice(1).every((r) =>
      r.headers.get("if-match") === '"fixture-version"'
    ),
  );
});
Deno.test("deterministic SPS crop permits genuine 1080 display frames and quarter-turn orientation", async () => {
  const f = fixture({ width: 1920, height: 1080, fps: 30 });
  equal((await probeMP4Video(URL, f.fetch)).height, 1080);
  mutate(f, "tkhd", 40, 0);
  mutate(f, "tkhd", 44, 65536);
  mutate(f, "tkhd", 52, 0xffff0000);
  mutate(f, "tkhd", 56, 0);
  const result = await probeMP4Video(URL, f.fetch);
  equal([result.width, result.height], [1080, 1920]);
});
Deno.test("59.94 cadence and conservative variable sample cadence never use average fps", async () => {
  const f = fixture({
    fps: 60,
    scale: 60000,
    delta: 1001,
    samples: 60,
    seconds: 1.001,
  });
  const result = await probeMP4Video(URL, f.fetch);
  equal(result.fps, 60000 / 1001);
  equal(result.billable_s, 1.001);
  const slow = fixture({ fps: 30 });
  equal((await probeMP4Video(URL, slow.fetch)).fps, 30);
  const variable = fixture({ timings: [[30, 1000], [15, 2000]] });
  equal((await probeMP4Video(URL, variable.fetch)).fps, 60); // Average is45.
});
Deno.test("observed x264 baseline AVC SPS/PPS and VUI clock are parsed, not guessed", async () => {
  // Locally generated with ffmpeg color320x240/r60, libx264 baseline/bf0,
  // faststart; ffprobe independently reported h264,320x240,60/1,1s,60frames.
  const f = fixture({
    sps: fromHex("6742c015d90141fb0110000003001000000788f162e480"),
    pps: fromHex("68cb83cb20"),
  });
  equal(await probeMP4Video(URL, f.fetch), {
    duration_s: 1,
    billable_s: 1,
    width: 320,
    height: 240,
    fps: 60,
  });
});
Deno.test("real AVAssetWriter High/all-intra/no-reordering metadata remains supported", async () => {
  // 12 owned grey frames encoded locally with the exact RenderEngine color/
  // compression settings, network optimization and H264HighAutoLevel.
  // Independent ffprobe: High,320x240,60/1,0.2s,12frames. Host AVFoundation
  // evidence only; this is not a physical iOS or arbitrary-media guarantee.
  const native = Uint8Array.from(
    atob(
      "AAAC921vb3YAAABsbXZoZAAAAADm6BrR5uga0QAAAlgAAAB4AAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAKDdHJhawAAAFx0a2hkAAAAAeboGtHm6BrRAAAAAQAAAAAAAAB4AAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAFAAAAA8AAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAeAAAAAAAAQAAAAAB+21kaWEAAAAgbWRoZAAAAADm6BrR5uga0QAAAlgAAAB4VcQAAAAAADFoZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAQ29yZSBNZWRpYSBWaWRlbwAAAAGibWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABYnN0YmwAAAC2c3RzZAAAAAAAAAABAAAApmF2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAABQADwAEgAAABIAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAAApYXZjQwFkACD/4QAOJ2QAIKxXBQfpqAgICBABAAQo7jyw/fj4AAAAABNjb2xybmNseAABAAEAAQAAAAAKZmllbAEAAAAACmNocm0AAAAAABhzdHRzAAAAAAAAAAEAAAAMAAAACgAAABhzZHRwAAAAACAgICAgICAgICAgIAAAABxzdHNjAAAAAAAAAAEAAAABAAAADAAAAAEAAABEc3RzegAAAAAAAAAAAAAADAAAAIIAAABhAAAAXwAAAF4AAABcAAAAWwAAAFcAAABWAAAAVgAAAFYAAABWAAAAVgAAABRzdGNvAAAAAAAAAAEAAAMj",
    ),
    (c) => c.charCodeAt(0),
  );
  const f = fixture(),
    ftyp = box(
      "ftyp",
      new TextEncoder().encode("mp42"),
      u32(0),
      new TextEncoder().encode("mp42isomavc1"),
    );
  const mdat = concat(
    u32(1),
    new TextEncoder().encode("mdat"),
    new Uint8Array(8),
  );
  new DataView(mdat.buffer).setBigUint64(8, 1132n);
  f.moov = native;
  f.total = 1919;
  f.segments.splice(0, 3, { start: 0, bytes: ftyp }, {
    start: 28,
    bytes: native,
  }, { start: 787, bytes: mdat });
  equal(await probeMP4Video(URL, f.fetch), {
    duration_s: 0.2,
    billable_s: 0.2,
    width: 320,
    height: 240,
    fps: 60,
  });
  equal(f.requests.reduce((n, r) => n + r.last - r.first + 1, 0), 807);
  const fields = locate(f.moov, "fiel");
  f.moov[fields] = 2;
  await rejects(() => probeMP4Video(URL, f.fetch), 400); // Field-based metadata is ambiguous.
});
Deno.test("large trailing moov is reached by jumping over multi-gigabyte extended mdat", async () => {
  const f = fixture({
    width: 3840,
    height: 2160,
    seconds: 300,
    mdatBytes: 5 * 1024 ** 3,
    tailMoov: true,
    extendedMdat: true,
  });
  equal((await probeMP4Video(URL, f.fetch)).duration_s, 300);
  ok(f.requests.some((r) => r.first > 5 * 1024 ** 3));
  ok(f.requests.reduce((n, r) => n + r.last - r.first + 1, 0) < 2048);
});
Deno.test("forged container dimensions cannot override coded SPS geometry", async () => {
  for (const type of ["avc1", "tkhd"]) {
    const f = fixture({ width: 3840, height: 2160 });
    mutate(
      f,
      type,
      type === "avc1" ? 24 : 76,
      type === "avc1" ? 1920 : 1920 * 65536,
      type === "avc1" ? 2 : 4,
    );
    await rejects(() => probeMP4Video(URL, f.fetch), 400);
  }
  const f = fixture({ width: 1920, height: 1080, sps: sequence(3840, 2160) });
  await rejects(() => probeMP4Video(URL, f.fetch), 400);
});
Deno.test("SPS/PPS truncation, parameter mismatch, alternate codec and multiple descriptions reject", async () => {
  for (
    const options of [{ sps: new Uint8Array([0x67, 0x42]) }, {
      pps: new Uint8Array([0x68, 0xc0]),
    }, { level: 40 }]
  ) await rejects(() => probeMP4Video(URL, fixture(options).fetch), 400);
  for (const name of ["avc3", "hvc1", "encv"]) {
    const f = fixture();
    f.moov.set(new TextEncoder().encode(name), locate(f.moov, "avc1") - 4);
    await rejects(() => probeMP4Video(URL, f.fetch), 400);
  }
  const f = fixture();
  mutate(f, "stsd", 4, 2);
  await rejects(() => probeMP4Video(URL, f.fetch), 400);
});
Deno.test("invalid clock/sample sizes/chunk extents/crop matrix fail before any billable work", async () => {
  for (
    const [type, offset, value] of [
      ["mdhd", 16, 100],
      ["stts", 12, 0],
      ["stsz", 8, 61],
      ["stsc", 16, 2],
      ["stco", 8, 1],
      ["tkhd", 40, 2 * 65536],
      ["tkhd", 76, 1],
    ]
  ) {
    const f = fixture();
    mutate(f, type as string, offset as number, value as number);
    await rejects(() => probeMP4Video(URL, f.fetch), 400);
  }
});
Deno.test("composition offsets remain bounded and cannot hide extra duration", async () => {
  equal(
    (await probeMP4Video(URL, fixture({ ctts: true }).fetch)).duration_s,
    1,
  );
  const f = fixture({ ctts: true });
  mutate(f, "ctts", 12, 60000);
  await rejects(() => probeMP4Video(URL, f.fetch), 400);
});
Deno.test("unsupported metadata boxes/fragmentation and unbounded root sizes reject", async () => {
  for (const options of [{ fragment: true }, { duplicateVideo: true }]) {
    await rejects(() => probeMP4Video(URL, fixture(options).fetch), 400);
  }
  for (const name of ["moof", "sidx", "mvex"]) {
    const f = fixture();
    const segment = f.segments[0];
    segment.bytes.set(new TextEncoder().encode(name), 4);
    await rejects(() => probeMP4Video(URL, f.fetch), 400);
  }
  const f = fixture();
  new DataView(f.segments[0].bytes.buffer).setUint32(0, 0);
  await rejects(() => probeMP4Video(URL, f.fetch), 400);
});
Deno.test("range admission rejects full responses, redirects, wrong ranges, weak/missing ETags and encoding", async () => {
  for (
    const [status, headers] of [
      [200, {}],
      [302, { location: "https://untrusted.invalid/a" }],
      [206, { "content-range": "bytes 1-16/1000" }],
      [206, { etag: 'W/"fixture-version"' }],
      [206, { etag: "" }],
      [206, { "content-encoding": "gzip" }],
      [206, { "content-length": "1" }],
    ] as [number, Record<string, string>][]
  ) {
    const f = fixture();
    await rejects(() =>
      probeMP4Video(URL, async (u, i) => {
        const r = await f.fetch(u, i);
        const h = new Headers(r.headers);
        Object.entries(headers).forEach(([k, v]) => h.set(k, v));
        return new Response(r.body, { status, headers: h });
      }), 409);
  }
});
Deno.test("stable response identity rejects changes in ETag or total even when dimensions look valid", async () => {
  for (const field of ["etag", "content-range"]) {
    const f = fixture();
    let calls = 0;
    await rejects(() =>
      probeMP4Video(URL, async (u, i) => {
        const r = await f.fetch(u, i);
        calls++;
        const h = new Headers(r.headers);
        if (calls === 2) {
          h.set(
            field,
            field === "etag"
              ? '"replacement"'
              : h.get(field)!.replace(/\/\d+$/, `/${f.total + 100}`),
          );
        }
        return new Response(r.body, { status: 206, headers: h });
      }), 409);
  }
});
Deno.test("truncated and excessive range streams are bounded and rejected", async () => {
  for (const extra of [-1, 1]) {
    const f = fixture();
    await rejects(() =>
      probeMP4Video(URL, async (u, i) => {
        const r = await f.fetch(u, i),
          bytes = new Uint8Array(await r.arrayBuffer()),
          h = new Headers(r.headers);
        const output = extra < 0
          ? bytes.slice(0, -1)
          : concat(bytes, new Uint8Array(1));
        return new Response(output, { status: 206, headers: h });
      }), extra < 0 ? 409 : 400);
  }
});
Deno.test("invalid URLs and transport exceptions expose no URL, body or internal failure", async () => {
  for (
    const url of [
      "http://fixture.invalid/a",
      "https://user:secret@fixture.invalid/a",
      "https://fixture.invalid/a#other",
      "file:///private/a",
    ]
  ) await rejects(() => probeMP4Video(url, fixture().fetch), 400);
  await rejects(
    () =>
      probeMP4Video(URL, () =>
        Promise.reject(
          new Error("private response body https://fixture.invalid secret"),
        )),
    409,
  );
});
Deno.test("metadata/box count bounds prevent unlimited header walks and oversized moov reads", async () => {
  const f = fixture();
  new DataView(f.moov.buffer).setUint32(0, 2 * 1024 * 1024 + 1);
  f.total = 3 * 1024 * 1024;
  await rejects(() => probeMP4Video(URL, f.fetch), 400);
  equal(f.requests.length, 2);
  let calls = 0;
  await rejects(() =>
    probeMP4Video(URL, (_u, init) => {
      calls++;
      const h = new Headers(init.headers),
        m = /bytes=(\d+)-(\d+)/.exec(h.get("range")!)!;
      return Promise.resolve(
        new Response(concat(box("free"), box("free")), {
          status: 206,
          headers: {
            etag: '"same"',
            "content-range": `bytes ${m[1]}-${m[2]}/1000000`,
          },
        }),
      );
    }), 400);
  equal(calls, 64);
});

Deno.test("a stalled metadata body expires at the real deadline and cancels its reader", async () => {
  let cancelled = false, signal: AbortSignal | null = null;
  const start = Date.now();
  await rejects(() =>
    probeMP4Video(URL, (_u, init) => {
      signal = init.signal as AbortSignal;
      return Promise.resolve(
        new Response(
          new ReadableStream<Uint8Array>({
            cancel() {
              cancelled = true;
            },
          }),
          {
            status: 206,
            headers: {
              etag: '"fixture"',
              "content-range": "bytes 0-15/100000",
              "content-length": "16",
            },
          },
        ),
      );
    }), 409);
  ok(Date.now() - start >= 14000 && Date.now() - start < 18000);
  ok(cancelled && (signal as AbortSignal | null)?.aborted);
});
