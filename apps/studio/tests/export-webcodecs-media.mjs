/* Authoring only until the root-owned harness invokes generateExportMedia. */
import assert from "node:assert/strict";
import {execFileSync, spawnSync} from "node:child_process";
import {createHash} from "node:crypto";
import {readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";
import {deflateSync} from "node:zlib";
import {inspectSeekSource} from "./export-webcodecs-oracles.mjs";

const command = (binary, args, options = {}) => execFileSync(binary, args,
  {timeout: 45_000, maxBuffer: 64 * 1024 * 1024, ...options});
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
// FFmpeg propagates frame properties to the encoder. Set them after the actual
// matrix conversion so unspecified lavfi primaries/transfer cannot replace the
// matching output options in either H.264 VUI or the MP4 nclx record.
const convert709 = "scale=in_color_matrix=bt601:out_color_matrix=bt709:in_range=tv:out_range=tv,format=yuv420p," +
  "setparams=range=limited:color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709";
const tags709 = ["-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
  "-colorspace", "bt709", "-color_range", "tv", "-movflags", "+write_colr"];

function png(rgb, stripe = false) {
  const width = 800, height = 450, raw = Buffer.alloc(height * (width * 3 + 1));
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const at = y * (width * 3 + 1) + 1 + x * 3;
    const value = stripe && x >= 390 && x < 410 ? [255, 255, 255] : rgb;
    value.forEach((channel, index) => {raw[at + index] = channel;});
  }
  const crc = bytes => {
    let value = 0xffffffff;
    for (const byte of bytes) {
      value ^= byte;
      for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
    }
    return (value ^ 0xffffffff) >>> 0;
  };
  const chunk = (kind, bytes) => {
    const type = Buffer.from(kind), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length); checksum.writeUInt32BE(crc(Buffer.concat([type, bytes])));
    return Buffer.concat([length, type, bytes, checksum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

function colrTags(bytes) {
  const found = [];
  const boxes = (start, end) => {
    let at = start;
    while (at < end) {
      assert(at + 8 <= end, "Truncated source MP4 box");
      const size = bytes.readUInt32BE(at), type = bytes.toString("ascii", at + 4, at + 8);
      assert(size >= 8 && at + size <= end, "Invalid bounded source MP4 box");
      if (["moov", "trak", "mdia", "minf", "stbl"].includes(type)) boxes(at + 8, at + size);
      else if (type === "stsd") boxes(at + 16, at + size);
      else if (type === "avc1") boxes(at + 86, at + size);
      else if (type === "colr") {
        assert.equal(bytes.toString("ascii", at + 8, at + 12), "nclx");
        assert(size >= 19);
        found.push({primaries: bytes.readUInt16BE(at + 12),
          transfer: bytes.readUInt16BE(at + 14), matrix: bytes.readUInt16BE(at + 16),
          fullRange: (bytes[at + 18] & 128) !== 0});
      }
      at += size;
    }
  };
  boxes(0, bytes.length); return found;
}

async function verifySource(file, expected, probeTime = 1.1) {
  const bytes = await readFile(file);
  const metadata = JSON.parse(command("ffprobe",
    ["-v", "error", "-show_streams", "-show_format", "-of", "json", file], {encoding: "utf8"}));
  const video = metadata.streams.find(row => row.codec_type === "video");
  const evidence = {file, sha256: hash(bytes), bytes: bytes.length, metadata};
  await writeFile(file + ".source-probe.json", JSON.stringify(evidence, null, 2));
  assert.equal(video.color_space, "bt709"); assert.equal(video.color_primaries, "bt709");
  assert.equal(video.color_transfer, "iec61966-2-1"); assert.equal(video.color_range, "tv");
  const container = colrTags(bytes);
  assert.deepEqual(container, [{primaries: 1, transfer: 13, matrix: 1, fullRange: false}]);
  const vui = spawnSync("ffmpeg", ["-v", "verbose", "-i", file, "-map", "0:v:0",
    "-c:v", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
  {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 45_000, maxBuffer: 64 * 1024 * 1024});
  const vuiPath = file + ".h264-vui.log";
  await writeFile(vuiPath, vui.stderr ?? "");
  assert.equal(vui.status, 0, "Source H.264 VUI inspection failed");
  for (const [field, value] of [["colour_primaries", 1], ["transfer_characteristics", 13],
    ["matrix_coefficients", 1], ["video_full_range_flag", 0]])
    assert(new RegExp("\\b" + field + "\\s+\\S+\\s*=\\s*" + value + "\\b").test(vui.stderr),
      "Source H.264 VUI disagrees with its converted pixels: " + field);
  const pixel = [...command("ffmpeg", ["-v", "error", "-ss", String(probeTime), "-i", file,
    "-frames:v", "1", "-vf", "format=rgb24,crop=1:1:700:200", "-f", "rawvideo", "pipe:1"])];
  await writeFile(file + ".source-probe.json", JSON.stringify({...evidence,
    containerColor: container, decodedRGB: pixel, vuiLog: vuiPath}, null, 2));
  if (expected === "blue") assert(pixel[0] < 10 && pixel[1] < 10 && pixel[2] > 240,
    "Generated source blue already violates the unchanged strict RGB oracle");
  else assert(pixel[0] > 205 && pixel[1] < 35 && pixel[2] < 35,
    "Generated source red already violates the unchanged strict RGB oracle");
  return {file, sha256: hash(bytes), bytes: bytes.length, metadata,
    authoring: {pixelConversion: convert709, matchingEncoderTags: tags709},
    containerColor: container, h264VUI: {log: vuiPath, sha256: hash(Buffer.from(vui.stderr))},
    decodedRGB: pixel};
}

export async function generateExportMedia(artifacts, {seekOnly = false, hybridReuseOnly = false} = {}) {
  if (seekOnly) {
    const file = join(artifacts, "source-exact-seek-120fps.mp4");
    command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=800x450:r=120:d=1",
      "-f", "lavfi", "-i", "color=c=white:s=32x450:r=120:d=1", "-filter_complex",
      "[0:v][1:v]overlay=x='round(40+720*t)':y=0:eval=frame," + convert709 + "[v]",
      "-map", "[v]", "-an", "-c:v", "libx264", "-g", "1", "-bf", "0", "-pix_fmt", "yuv420p",
      ...tags709, file]);
    const source = {...await verifySource(file, "red", .2), seekProbe: inspectSeekSource(file)};
    await writeFile(file + ".seek-probe.json", JSON.stringify(source, null, 2));
    return {assets: {sourceSeek: file}, sources: {sourceSeek: source}};
  }
  const one = join(artifacts, "source-blue-2x.mp4"), two = join(artifacts, "source-moving-normal.mp4");
  command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=800x450:r=30:d=4",
    "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,0.3)\\,0.25*sin(2*PI*990*t)\\,0.25*sin(2*PI*880*t)):s=48000:d=4",
    "-vf", convert709, "-c:v", "libx264", "-pix_fmt", "yuv420p", ...tags709,
    "-c:a", "aac", "-shortest", one]);
  command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=800x450:r=30:d=3",
    "-f", "lavfi", "-i", "color=c=white:s=40x450:r=30:d=3", "-f", "lavfi", "-i",
    "aevalsrc=if(lt(t\\,0.5)\\,0\\,if(lt(t\\,0.65)\\,0.25*sin(2*PI*770*t)\\,0.25*sin(2*PI*1100*t))):s=48000:d=3",
    "-filter_complex", "[0:v][1:v]overlay=x='220*t-90':y=0:eval=frame," + convert709 + "[v]",
    "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-pix_fmt", "yuv420p",
    ...tags709, "-c:a", "aac", "-shortest", two]);
  const narration = join(artifacts, "narration.wav"), music = join(artifacts, "music.wav");
  command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i",
    hybridReuseOnly ? "aevalsrc=0.2*sin(2*PI*660*t):s=48000:d=1.2" :
      "aevalsrc=if(between(t\\,1.25\\,1.5)\\,0.2*sin(2*PI*1320*t)\\,0.2*sin(2*PI*660*t)):s=48000:d=4",
    "-c:a", "pcm_s16le", narration]);
  command("ffmpeg", ["-v", "error", "-f", "lavfi", "-i",
    "aevalsrc=0.2*sin(2*PI*220*t):s=48000:d=5.4", "-c:a", "pcm_s16le", music]);
  const assets = {sourceOne: one, sourceTwo: two, narration, music};
  for (const [name, color] of Object.entries({opening: [117, 83, 153], middle: [255, 0, 0],
    closing: [255, 0, 0], cutaway: [0, 255, 0], motion: [117, 83, 153]})) {
    const path = join(artifacts, name + ".png");
    await writeFile(path, png(color, name === "motion")); assets[name] = path;
  }
  const sources = {sourceOne: await verifySource(one, "blue"), sourceTwo: await verifySource(two, "red")};
  for (const [name, path] of Object.entries(assets)) if (!sources[name]) {
    const bytes = await readFile(path); sources[name] = {file: path, sha256: hash(bytes), bytes: bytes.length};
  }
  return {assets, sources};
}
