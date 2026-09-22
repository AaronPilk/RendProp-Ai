// Bounded ISO-BMFF duration read. Source URLs come only from an authorized R2
// asset. Jump over mdat instead of downloading a full walkthrough into an edge
// function. Refuse malformed/unreadable media before any paid reservation.
import { assert } from "../_shared/http.ts";
type Fetch = (url: string, init: RequestInit) => Promise<Response>;
const LIMIT = 2 * 1024 * 1024;
function header(
  v: DataView,
  offset: number,
): { size: number; type: string; header: number } {
  assert(offset + 8 <= v.byteLength, 400, "Invalid MP4 box");
  let size = v.getUint32(offset);
  let width = 8;
  if (size === 1) {
    assert(offset + 16 <= v.byteLength, 400, "Invalid extended MP4 box");
    const n = v.getBigUint64(offset + 8);
    assert(n <= BigInt(Number.MAX_SAFE_INTEGER), 400, "MP4 box is too large");
    size = Number(n);
    width = 16;
  }
  const type = String.fromCharCode(
    ...new Uint8Array(v.buffer, v.byteOffset + offset + 4, 4),
  );
  assert(size >= width, 400, "Unbounded MP4 boxes are not supported");
  return { size, type, header: width };
}
type Box = { start: number; end: number; type: string };
function children(v: DataView, start: number, end: number): Box[] {
  const boxes: Box[] = [];
  while (start < end) {
    const h = header(v, start);
    assert(start + h.size <= end, 400, "Incomplete MP4 box");
    boxes.push({ start: start + h.header, end: start + h.size, type: h.type });
    start += h.size;
  }
  return boxes;
}
function one(boxes: Box[], type: string): Box {
  const hits = boxes.filter((b) => b.type === type);
  assert(hits.length === 1, 400, "Missing or duplicate MP4 " + type);
  return hits[0];
}
function clock(
  v: DataView,
  b: Box,
): { seconds: number; ticks: number; scale: number } {
  assert(b.end - b.start >= 4, 400, "Invalid MP4 timeline");
  const version = v.getUint8(b.start),
    base = b.start + (version === 0 ? 12 : 20);
  assert(
    (version === 0 || version === 1) &&
      base + (version === 0 ? 8 : 12) <= b.end,
    400,
    "Invalid MP4 timeline",
  );
  const scale = v.getUint32(base),
    ticks = version === 0
      ? v.getUint32(base + 4)
      : Number(v.getBigUint64(base + 4));
  assert(
    scale > 0 && Number.isSafeInteger(ticks) && ticks > 0,
    400,
    "MP4 duration must be positive and finite",
  );
  return { seconds: ticks / scale, ticks, scale };
}
export function movieTiming(
  bytes: Uint8Array,
): { duration_s: number; billable_s: number } {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    root = header(v, 0);
  assert(
    root.type === "moov" && root.size === bytes.length,
    400,
    "Invalid MP4 movie header",
  );
  const boxes = children(v, root.header, bytes.length);
  assert(
    !boxes.some((b) => b.type === "mvex"),
    400,
    "A complete, non-fragmented MP4 video is required",
  );
  const movie = clock(v, one(boxes, "mvhd"));
  let videos = 0;
  let billable = movie.seconds;
  const tracks = boxes.filter((b) => b.type === "trak");
  assert(tracks.length > 0 && tracks.length <= 8, 400, "Invalid MP4 tracks");
  for (const track of tracks) {
    const trackBoxes = children(v, track.start, track.end),
      mdia = one(trackBoxes, "mdia"),
      media = children(v, mdia.start, mdia.end),
      hdlr = one(media, "hdlr");
    assert(hdlr.end - hdlr.start >= 12, 400, "Invalid MP4 handler");
    const type = String.fromCharCode(
      ...new Uint8Array(v.buffer, v.byteOffset + hdlr.start + 8, 4),
    );
    if (type !== "vide" && type !== "soun") continue;
    if (type === "vide") videos++;
    const timeline = clock(v, one(media, "mdhd")),
      minf = one(media, "minf"),
      stbl = one(children(v, minf.start, minf.end), "stbl"),
      samples = children(v, stbl.start, stbl.end),
      stts = one(samples, "stts");
    assert(stts.end - stts.start >= 8, 400, "Invalid MP4 sample times");
    const entries = v.getUint32(stts.start + 4);
    assert(
      entries > 0 && entries <= 65536 &&
        stts.start + 8 + entries * 8 === stts.end,
      400,
      "Invalid MP4 sample timing table",
    );
    let ticks = 0, count = 0;
    for (let i = 0; i < entries; i++) {
      const p = stts.start + 8 + i * 8,
        n = v.getUint32(p),
        delta = v.getUint32(p + 4);
      assert(n > 0 && delta > 0, 400, "Invalid MP4 sample duration");
      count += n;
      ticks += n * delta;
    }
    assert(
      Number.isSafeInteger(ticks) && ticks === timeline.ticks,
      400,
      "MP4 media and sample timelines disagree",
    );
    if (type === "vide") billable = Math.max(billable, timeline.seconds);
    const stsz = one(samples, "stsz");
    assert(stsz.end - stsz.start >= 12, 400, "Invalid MP4 sample sizes");
    const constant = v.getUint32(stsz.start + 4),
      sizeCount = v.getUint32(stsz.start + 8);
    assert(
      sizeCount === count &&
        stsz.start + 12 + (constant ? 0 : count * 4) === stsz.end,
      400,
      "MP4 sample counts disagree",
    );
    const tkhd = one(trackBoxes, "tkhd"),
      version = v.getUint8(tkhd.start),
      durationOffset = tkhd.start + (version === 0 ? 20 : 28);
    assert(
      (version === 0 || version === 1) &&
        durationOffset + (version === 0 ? 4 : 8) <= tkhd.end,
      400,
      "Invalid MP4 track duration",
    );
    const trackTicks = version === 0
        ? v.getUint32(durationOffset)
        : Number(v.getBigUint64(durationOffset)),
      trackSeconds = trackTicks / movie.scale;
    // Encoder priming/edit lists may differ by a few frames, never seconds.
    assert(
      Number.isSafeInteger(trackTicks) && trackTicks > 0 &&
        Math.abs(trackSeconds - movie.seconds) <= 0.15 &&
        Math.abs(timeline.seconds - movie.seconds) <= 0.15,
      400,
      "MP4 movie, track and sample timelines disagree",
    );
  }
  assert(videos === 1, 400, "One complete MP4 video track is required");
  return { duration_s: movie.seconds, billable_s: billable };
}
export function movieDuration(bytes: Uint8Array): number {
  return movieTiming(bytes).duration_s;
}
export async function probeMP4Timing(
  url: string,
  fetcher: Fetch,
): Promise<{ duration_s: number; billable_s: number }> {
  const deadline = Date.now() + 15000;
  async function range(
    first: number,
    last: number,
  ): Promise<{ bytes: Uint8Array; total: number }> {
    assert(Date.now() < deadline, 409, "Video duration verification timed out");
    const res = await fetcher(url, {
      method: "GET",
      headers: { Range: `bytes=${first}-${last}` },
      redirect: "error",
      signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
    });
    const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(
      res.headers.get("content-range") ?? "",
    );
    if (
      res.status !== 206 || !match || Number(match[1]) !== first ||
      Number(match[2]) !== last
    ) {
      await res.body?.cancel();
      assert(
        false,
        409,
        "Video duration could not be verified; upload the saved clip again",
      );
    }
    const total = Number(match[3]);
    assert(
      Number.isSafeInteger(total) && total > last,
      400,
      "Invalid MP4 length",
    );
    const length = last - first + 1;
    assert(length <= LIMIT, 400, "MP4 metadata is too large");
    const reader = res.body?.getReader();
    assert(reader, 409, "Video duration could not be read");
    const bytes = new Uint8Array(length);
    let used = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        assert(
          used + chunk.value.length <= length,
          400,
          "Unexpected video range length",
        );
        bytes.set(chunk.value, used);
        used += chunk.value.length;
      }
    } finally {
      await reader.cancel();
    }
    assert(used === length, 409, "Incomplete video metadata");
    return { bytes, total };
  }
  let offset = 0, total = Number.MAX_SAFE_INTEGER;
  for (let count = 0; count < 64 && offset + 16 <= total; count++) {
    const result = await range(offset, offset + 15);
    total = result.total;
    const box = header(new DataView(result.bytes.buffer), 0);
    assert(offset + box.size <= total, 400, "MP4 box exceeds video length");
    if (box.type === "moov") {
      assert(box.size <= LIMIT, 400, "MP4 metadata is too large");
      return movieTiming((await range(offset, offset + box.size - 1)).bytes);
    }
    offset += box.size;
  }
  assert(false, 400, "MP4 movie duration was not found");
}

export async function probeMP4Duration(
  url: string,
  fetcher: Fetch,
): Promise<number> {
  return (await probeMP4Timing(url, fetcher)).duration_s;
}
