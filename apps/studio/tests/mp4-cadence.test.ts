import assert from "node:assert/strict";
import {test} from "node:test";
import {verifyMp4FrameCadence} from "../src/editor/mp4-cadence";

const u32 = (value: number) => {const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes;};
const box = (type: string, ...parts: Buffer[]) => {
  const body = Buffer.concat(parts);
  return Buffer.concat([u32(body.length + 8), Buffer.from(type), body]);
};
const full = (version: number, flags: number, ...parts: Buffer[]) =>
  Buffer.concat([Buffer.from([version, flags >> 16 & 255, flags >> 8 & 255, flags & 255]), ...parts]);
function fixture(durations: number[]): Blob {
  const tkhd = box("tkhd", full(0, 3, Buffer.alloc(8), u32(1), Buffer.alloc(8)));
  const mdhd = box("mdhd", full(0, 0, Buffer.alloc(8), u32(30_000), u32(0)));
  const hdlr = box("hdlr", full(0, 0, u32(0), Buffer.from("vide"), Buffer.alloc(12)));
  const trak = box("trak", tkhd, box("mdia", mdhd, hdlr));
  const trex = box("trex", full(0, 0, u32(1), u32(1), u32(0), u32(0), u32(0)));
  const moov = box("moov", trak, box("mvex", trex));
  const tfhd = box("tfhd", full(0, 0, u32(1)));
  const tfdt = box("tfdt", full(1, 0, Buffer.alloc(8)));
  const trun = box("trun", full(1, 0x305, u32(durations.length), u32(0), u32(0),
    ...durations.flatMap(duration => [u32(duration), u32(1)])));
  return new Blob([box("ftyp", Buffer.from("isom")), moov,
    box("moof", box("traf", tfhd, tfdt, trun)), box("mdat", Buffer.from([0]))], {type: "video/mp4"});
}
function flatFixture(durations: number[], compositionOffsets?: number[]): Blob {
  const tkhd = box("tkhd", full(0, 3, Buffer.alloc(8), u32(1), Buffer.alloc(8)));
  const mdhd = box("mdhd", full(0, 0, Buffer.alloc(8), u32(30_000), u32(0)));
  const hdlr = box("hdlr", full(0, 0, u32(0), Buffer.from("vide"), Buffer.alloc(12)));
  const stts = box("stts", full(0, 0, u32(durations.length),
    ...durations.flatMap(duration => [u32(1), u32(duration)])));
  const stsz = box("stsz", full(0, 0, u32(1), u32(durations.length)));
  const ctts = compositionOffsets && box("ctts", full(0, 0, u32(compositionOffsets.length),
    ...compositionOffsets.flatMap(offset => [u32(1), u32(offset)])));
  const stbl = box("stbl", stts, stsz, ...(ctts ? [ctts] : []));
  const trak = box("trak", tkhd, box("mdia", mdhd, hdlr, box("minf", stbl)));
  return new Blob([box("ftyp", Buffer.from("isom")), box("mdat", Buffer.from([0])),
    box("moov", trak)], {type: "video/mp4"});
}

test("encoded 30 fps MP4 retains enough real video samples across a dissolve", async () => {
  await verifyMp4FrameCadence(fixture(Array.from({length: 90}, () => 1000)),
    [{startSeconds: .5, durationSeconds: .28}]);
});
test("zero-duration duplicate sample does not invalidate healthy Chromium MP4", async () => {
  const durations = Array.from({length: 90}, () => 1000);
  durations.splice(13, 0, 0);
  await verifyMp4FrameCadence(fixture(durations),
    [{startSeconds: .5, durationSeconds: .28}]);
});
test("nonfragmented Safari-style sample table verifies healthy frame cadence", async () => {
  await verifyMp4FrameCadence(flatFixture(Array.from({length: 90}, () => 1000)),
    [{startSeconds: .5, durationSeconds: .28}]);
  await verifyMp4FrameCadence(flatFixture(Array.from({length: 90}, () => 1000),
    Array.from({length: 90}, () => 0)), [{startSeconds: .5, durationSeconds: .28}]);
});
test("nonfragmented sample table rejects a 552 ms encoded gap", async () => {
  const durations = [...Array.from({length: 15}, () => 1000), 16_575,
    ...Array.from({length: 58}, () => 1000)];
  await assert.rejects(verifyMp4FrameCadence(flatFixture(durations),
    [{startSeconds: .5, durationSeconds: .28}]), /Encoded video frames were skipped.*No download/);
});
test("encoded MP4 with a 552 ms video gap cannot be downloaded despite requested paints", async () => {
  const durations = [...Array.from({length: 15}, () => 1000), 16_575,
    ...Array.from({length: 58}, () => 1000)];
  await assert.rejects(verifyMp4FrameCadence(fixture(durations),
    [{startSeconds: .5, durationSeconds: .28}]), /Encoded video frames were skipped.*No download/);
});
test("encoded 14 fps MP4 is refused even when individual gaps stay under 150 ms", async () => {
  await assert.rejects(verifyMp4FrameCadence(fixture(Array.from({length: 43}, () => 2100)),
    [{startSeconds: .5, durationSeconds: .28}]), /Encoded video frames were skipped.*No download/);
});
test("unreadable MP4 metadata fails closed and abort remains cancellable", async () => {
  await assert.rejects(verifyMp4FrameCadence(new Blob([Buffer.from("broken")]), []), /could not be verified/);
  const abort = new AbortController(); abort.abort(new Error("Cancelled"));
  await assert.rejects(verifyMp4FrameCadence(fixture([1000,1000]), [], abort.signal), /Cancelled/);
});
