import assert from "node:assert/strict";
import {test} from "node:test";
import {OFFLINE_PCM_CAP, originalDuckTiming, pcmWindowMode,
  windowTrackSlice} from "../src/editor/export-audio-route";
import {planExport} from "../src/editor/export-plan";
import type {EditDraft} from "../src/editor/model";

const source = (kind: "image" | "video", duration: number) => ({
  name: `${kind}.local`, size: 1, lastModified: 0, sha256: "a".repeat(64),
  kind, width: 1280, height: 720, duration,
});
function draft(): EditDraft {
  return {schema: 1, id: "hybrid", revision: 0, ratio: "16:9", title: "",
    audio: "original", clips: [
      {id: "photo-1", source: source("image", 0), start: 0, end: .5,
        caption: "", focusX: .5, focusY: .5},
      {id: "speed-2", source: source("video", 4), start: 0, end: 4,
        speed: 2, caption: "", focusX: .5, focusY: .5},
      {id: "photo-2", source: source("image", 0), start: 0, end: .5,
        caption: "", focusX: .5, focusY: .5},
      {id: "normal", source: source("video", 3), start: .5, end: 2,
        speed: 1, caption: "", focusX: .5, focusY: .5},
    ]};
}

test("hybrid route keeps photos offline and live capture only for pitch-preserved source", () => {
  const edit = draft(), windows = planExport(edit, true).windows;
  assert.deepEqual(windows.map(window => window.startFrame),
    [0, 24000, 120000, 144000]);
  assert.deepEqual(edit.clips.map((clip, index) => pcmWindowMode(edit, clip,
    windows[index]!, index === 3, true)),
  ["offline", "live", "offline", "offline"]);
  assert.equal(pcmWindowMode(edit, edit.clips[3]!, windows[3]!, false, true), "live");
});

test("hybrid route fails over to finite realtime capture only when offline is unavailable or too large", () => {
  const edit = draft(), window = planExport(edit, true).windows[0]!;
  assert.equal(pcmWindowMode(edit, edit.clips[0]!, window, false, false), "live");
  assert.equal(pcmWindowMode(edit, edit.clips[0]!, {...window,
    frameCount: Math.floor(OFFLINE_PCM_CAP / 8) + 1}, false, true), "live");
  edit.audio = "muted";
  const normal = planExport(edit, true).windows[3]!;
  assert.equal(pcmWindowMode(edit, edit.clips[3]!, normal, false, true), "offline");
});

test("split windows retain narration marker, music trim and original duck on the global PCM timeline", () => {
  const edit = draft(), windows = planExport(edit, true).windows;
  const voiceFirst = windowTrackSlice(windows[0]!.startFrame / 48000,
    windows[0]!.frameCount / 48000, .15, 0, 4);
  const voiceLive = windowTrackSlice(windows[1]!.startFrame / 48000,
    windows[1]!.frameCount / 48000, .15, 0, 4);
  const voiceLast = windowTrackSlice(windows[3]!.startFrame / 48000,
    windows[3]!.frameCount / 48000, .15, 0, 4);
  assert(voiceFirst && voiceLive && voiceLast);
  assert(Math.abs(voiceFirst.delay - .15) < 1e-12);
  assert.equal(voiceFirst.sourceOffset, 0);
  assert(Math.abs(voiceLive.sourceOffset - .35) < 1e-12);
  // A nonstationary 1320 Hz source marker at 1.25 s still lands at 1.40 s,
  // even though the source was restarted after the first offline photo.
  assert(Math.abs(windows[1]!.startFrame / 48000 +
    (1.25 - voiceLive.sourceOffset) - 1.4) < 1 / 48000);
  assert(Math.abs(voiceLast.sourceOffset - 2.85) < 1e-12);
  const music = windowTrackSlice(windows[3]!.startFrame / 48000,
    windows[3]!.frameCount / 48000, .1, .2, 5.4);
  assert(music);
  assert(Math.abs(music.sourceOffset - 3.1) < 1e-12);
  const duck = originalDuckTiming(windows[3]!.startFrame / 48000,
    windows[3]!.frameCount / 48000, .15, 4);
  assert.equal(duck.initial, .22);
  assert.equal(duck.duckAt, undefined);
  assert(Math.abs(duck.recoverAt! - 1.15) < 1e-12);
  const fractional = 24001 / 48000;
  const afterRoundedBoundary = windowTrackSlice(fractional, .5, .15, 0, 4);
  assert(afterRoundedBoundary);
  assert(Math.abs(fractional + (1.25 - afterRoundedBoundary.sourceOffset) - 1.4) < 1 / 48000);
});
