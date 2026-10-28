// Inspect the encoded MP4, not just the canvas paint loop: MediaRecorder can
// silently drop requested frames while the media and audio clocks still agree.
// Only small ISO BMFF metadata boxes are read; the mdat video payload is skipped.
type Box = {type: string; start: number; body: number; end: number};
type VideoTrack = {id: number; timescale: number; defaultDuration?: number; flatFrames?: Frame[]};
type Frame = {start: number; end: number};
export type EncodedTransition = {startSeconds: number; durationSeconds: number};
const MAX_METADATA_BOX_BYTES = 2 * 1024 * 1024;
const MAX_TOP_LEVEL_BOXES = 2048;
const MAX_VIDEO_FRAMES = 7200; // 180 seconds at 40 fps, above the 30 fps target.
const MAX_ENCODED_GAP_SECONDS = .15;
const MAX_TRANSITION_GAP_SECONDS = .13;
const MIN_TRANSITION_FPS = 20;
const DENSITY_WINDOW_SECONDS = .5;
const MIN_FRAMES_PER_WINDOW = 11;

function unreadable(): never {
  throw new Error("The browser's MP4 frames could not be verified. No download was created. Retry the export.");
}
function readU64(view: DataView, offset: number): number {
  if (offset + 8 > view.byteLength) unreadable();
  const value = view.getBigUint64(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) unreadable();
  return Number(value);
}
function childBoxes(data: Uint8Array, from = 0, until = data.byteLength): Box[] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength), result: Box[] = [];
  let at = from;
  while (at < until) {
    if (at + 8 > until || result.length > MAX_TOP_LEVEL_BOXES) unreadable();
    let size = view.getUint32(at), header = 8;
    if (size === 1) {size = readU64(view, at + 8); header = 16;}
    if (size === 0) size = until - at;
    if (size < header || size > until - at) unreadable();
    result.push({type: String.fromCharCode(...data.subarray(at + 4, at + 8)),
      start: at, body: at + header, end: at + size});
    at += size;
  }
  return result;
}
function child(data: Uint8Array, parent: Box, type: string): Box {
  const match = childBoxes(data, parent.body, parent.end).find(box => box.type === type);
  if (!match) unreadable();
  return match;
}
function sampleTableFrames(data: Uint8Array, mdia: Box, timescale: number): Frame[] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const stbl = child(data, child(data, mdia, "minf"), "stbl");
  const stts = child(data, stbl, "stts"), stsz = child(data, stbl, "stsz");
  if (stts.body + 8 > stts.end || stsz.body + 12 > stsz.end) unreadable();
  const sampleCount = view.getUint32(stsz.body + 8);
  if (sampleCount > MAX_VIDEO_FRAMES) unreadable();
  const durations: number[] = [];
  const sttsCount = view.getUint32(stts.body + 4);
  if (sttsCount > MAX_VIDEO_FRAMES || stts.body + 8 + sttsCount * 8 > stts.end) unreadable();
  for (let at = stts.body + 8, index = 0; index < sttsCount; index++, at += 8) {
    const count = view.getUint32(at), duration = view.getUint32(at + 4);
    if (!count || durations.length + count > MAX_VIDEO_FRAMES) unreadable();
    for (let sample = 0; sample < count; sample++) durations.push(duration);
  }
  if (durations.length !== sampleCount) unreadable();
  const offsets: number[] = [];
  const ctts = childBoxes(data, stbl.body, stbl.end).find(box => box.type === "ctts");
  if (ctts) {
    if (ctts.body + 8 > ctts.end) unreadable();
    const version = view.getUint8(ctts.body), count = view.getUint32(ctts.body + 4);
    if (version > 1 || count > MAX_VIDEO_FRAMES || ctts.body + 8 + count * 8 > ctts.end) unreadable();
    for (let at = ctts.body + 8, index = 0; index < count; index++, at += 8) {
      const samples = view.getUint32(at), offset = version === 1 ? view.getInt32(at + 4) : view.getUint32(at + 4);
      if (!samples || offsets.length + samples > sampleCount) unreadable();
      for (let sample = 0; sample < samples; sample++) offsets.push(offset);
    }
    if (offsets.length !== sampleCount) unreadable();
  }
  const frames: Frame[] = [];
  let decodeTime = 0;
  for (let index = 0; index < sampleCount; index++) {
    const duration = durations[index], composition = offsets[index] ?? 0;
    if (duration) {
      const start = (decodeTime + composition) / timescale;
      const end = (decodeTime + composition + duration) / timescale;
      if (!Number.isFinite(start) || start < 0 || !Number.isFinite(end)) unreadable();
      frames.push({start, end});
    }
    decodeTime += duration;
  }
  return frames;
}
function videoTrack(data: Uint8Array): VideoTrack {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const moov = childBoxes(data).find(box => box.type === "moov");
  if (!moov) unreadable();
  for (const trak of childBoxes(data, moov.body, moov.end).filter(box => box.type === "trak")) {
    const tkhd = child(data, trak, "tkhd"), mdia = child(data, trak, "mdia");
    const hdlr = child(data, mdia, "hdlr"), mdhd = child(data, mdia, "mdhd");
    if (hdlr.body + 12 > hdlr.end) unreadable();
    if (String.fromCharCode(...data.subarray(hdlr.body + 8, hdlr.body + 12)) !== "vide") continue;
    const idOffset = tkhd.body + (view.getUint8(tkhd.body) === 1 ? 20 : 12);
    const scaleOffset = mdhd.body + (view.getUint8(mdhd.body) === 1 ? 20 : 12);
    if (idOffset + 4 > tkhd.end || scaleOffset + 4 > mdhd.end) unreadable();
    const id = view.getUint32(idOffset), timescale = view.getUint32(scaleOffset);
    if (!id || !timescale) unreadable();
    let defaultDuration: number | undefined;
    const mvex = childBoxes(data, moov.body, moov.end).find(box => box.type === "mvex");
    if (mvex) for (const trex of childBoxes(data, mvex.body, mvex.end).filter(box => box.type === "trex")) {
      if (trex.body + 16 > trex.end) unreadable();
      if (view.getUint32(trex.body + 4) === id) defaultDuration = view.getUint32(trex.body + 12);
    }
    // Safari may write a conventional, nonfragmented MP4. Its complete video
    // timing then lives in stbl/stts instead of Chromium's moof/trun records.
    return {id, timescale, defaultDuration,
      ...(!mvex ? {flatFrames: sampleTableFrames(data, mdia, timescale)} : {})};
  }
  unreadable();
}
function fragmentFrames(data: Uint8Array, track: VideoTrack): Frame[] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const moof = childBoxes(data).find(box => box.type === "moof");
  if (!moof) unreadable();
  const frames: Frame[] = [];
  for (const traf of childBoxes(data, moof.body, moof.end).filter(box => box.type === "traf")) {
    const tfhd = child(data, traf, "tfhd");
    if (tfhd.body + 8 > tfhd.end) unreadable();
    const flags = view.getUint32(tfhd.body) & 0xffffff;
    if (view.getUint32(tfhd.body + 4) !== track.id) continue;
    let cursor = tfhd.body + 8;
    if (flags & 1) cursor += 8; // base_data_offset
    if (flags & 2) cursor += 4; // sample_description_index
    const duration = flags & 8 ? view.getUint32(cursor) : track.defaultDuration;
    if (flags & 8) cursor += 4;
    if (flags & 16) cursor += 4;
    if (flags & 32) cursor += 4;
    if (cursor > tfhd.end) unreadable();
    const tfdt = child(data, traf, "tfdt");
    let decodeTime = view.getUint8(tfdt.body) === 1
      ? readU64(view, tfdt.body + 4) : view.getUint32(tfdt.body + 4);
    for (const trun of childBoxes(data, traf.body, traf.end).filter(box => box.type === "trun")) {
      if (trun.body + 8 > trun.end) unreadable();
      const runFlags = view.getUint32(trun.body) & 0xffffff;
      const version = view.getUint8(trun.body), count = view.getUint32(trun.body + 4);
      if (count > MAX_VIDEO_FRAMES || frames.length + count > MAX_VIDEO_FRAMES) unreadable();
      let offset = trun.body + 8;
      if (runFlags & 1) offset += 4; // data_offset
      if (runFlags & 4) offset += 4; // first_sample_flags
      for (let index = 0; index < count; index++) {
        const sampleDuration = runFlags & 0x100 ? view.getUint32(offset) : duration;
        if (runFlags & 0x100) offset += 4;
        if (runFlags & 0x200) offset += 4;
        if (runFlags & 0x400) offset += 4;
        const composition = runFlags & 0x800
          ? (version === 1 ? view.getInt32(offset) : view.getUint32(offset)) : 0;
        if (runFlags & 0x800) offset += 4;
        if (offset > trun.end || sampleDuration === undefined) unreadable();
        // Chromium can encode an extra sample with a zero duration at the same
        // timestamp as its successor. It is not a distinct displayed frame and
        // must not increase the measured cadence.
        if (sampleDuration === 0) continue;
        const start = (decodeTime + composition) / track.timescale;
        const end = (decodeTime + composition + sampleDuration) / track.timescale;
        if (!Number.isFinite(start) || start < 0 || !Number.isFinite(end)) unreadable();
        frames.push({start, end});
        decodeTime += sampleDuration;
      }
    }
  }
  return frames;
}
async function metadataBox(blob: Blob, offset: number): Promise<{type: string; end: number; data?: Uint8Array}> {
  const header = new DataView(await blob.slice(offset, offset + 16).arrayBuffer());
  if (header.byteLength < 8) unreadable();
  let size = header.getUint32(0);
  if (size === 1) size = readU64(header, 8);
  if (size === 0) size = blob.size - offset;
  const headerBytes = header.getUint32(0) === 1 ? 16 : 8;
  if (size < headerBytes || size > blob.size - offset) unreadable();
  const type = String.fromCharCode(...new Uint8Array(header.buffer, header.byteOffset + 4, 4));
  const end = offset + size;
  if (type !== "moov" && type !== "moof") return {type, end};
  if (size > MAX_METADATA_BOX_BYTES) unreadable();
  return {type, end, data: new Uint8Array(await blob.slice(offset, end).arrayBuffer())};
}
export async function verifyMp4FrameCadence(blob: Blob, transitions: EncodedTransition[], signal?: AbortSignal): Promise<void> {
  let track: VideoTrack | undefined, offset = 0, boxCount = 0;
  const frames: Frame[] = [];
  while (offset < blob.size) {
    if (signal?.aborted) throw signal.reason;
    if (++boxCount > MAX_TOP_LEVEL_BOXES) unreadable();
    const box = await metadataBox(blob, offset);
    if (box.type === "moov") track = videoTrack(box.data!);
    if (box.type === "moof") {
      if (!track) unreadable();
      frames.push(...fragmentFrames(box.data!, track));
      if (frames.length > MAX_VIDEO_FRAMES) unreadable();
    }
    offset = box.end;
  }
  if (!frames.length && track?.flatFrames) frames.push(...track.flatFrames);
  if (frames.length < 2) unreadable();
  frames.sort((a, b) => a.start - b.start);
  let windowStart = 0;
  for (let index = 0; index < frames.length; index++) {
    const frame = frames[index];
    if (frame.end - frame.start > MAX_ENCODED_GAP_SECONDS ||
        index && frame.start - frames[index - 1].start > MAX_ENCODED_GAP_SECONDS)
      throw new Error("Encoded video frames were skipped. No download was created. Close other busy tabs and retry.");
    while (frames[windowStart].start < frame.start - DENSITY_WINDOW_SECONDS) windowStart++;
    if (frame.start - frames[0].start >= DENSITY_WINDOW_SECONDS &&
        index - windowStart + 1 < MIN_FRAMES_PER_WINDOW)
      throw new Error("Encoded video frames were skipped. No download was created. Close other busy tabs and retry.");
  }
  for (const transition of transitions) {
    if (!Number.isFinite(transition.startSeconds) || !Number.isFinite(transition.durationSeconds) ||
        transition.startSeconds < 0 || transition.durationSeconds <= 0) unreadable();
    const from = transition.startSeconds, until = from + transition.durationSeconds;
    const inside = frames.filter(frame => frame.start >= from - .02 && frame.start < until + .02);
    if (inside.length < Math.ceil(transition.durationSeconds * MIN_TRANSITION_FPS))
      throw new Error("The encoded video skipped a transition. No download was created. Close other busy tabs and retry.");
    for (const frame of frames)
      if (frame.start < until && frame.end > from && frame.end - frame.start > MAX_TRANSITION_GAP_SECONDS)
        throw new Error("The encoded video skipped a transition. No download was created. Close other busy tabs and retry.");
  }
}
