import assert from "node:assert/strict";
import test from "node:test";
import {createHash} from "node:crypto";
import {timelineDuration, validateDraft, type SourceRef} from "../src/editor/model";
import {makeExportFixtureDraft, type ExportFixtureScenario, type ExportFixtureSources} from "./export-webcodecs-draft";

const names = ["opening", "sourceOne", "middle", "sourceTwo", "closing", "cutaway", "motion", "sourceSeek"] as const;
const sources = Object.fromEntries(names.map(name => [name, {
  name: `${name}.${name.startsWith("source") ? "mp4" : "png"}`,
  size: 1024, lastModified: 0,
  sha256: createHash("sha256").update(name).digest("hex"),
  kind: name.startsWith("source") ? "video" : "image",
  width: 800, height: 450,
  duration: name === "sourceOne" ? 4 : name === "sourceTwo" ? 3 : name === "sourceSeek" ? 1 : 0,
} satisfies SourceRef])) as ExportFixtureSources;
const music = {name: "music.wav", size: 576000, lastModified: 0,
  sha256: "b".repeat(64), duration: 5.4, mime: "audio/wav"};

test("all browser scenarios use valid actual shipping metadata", () => {
  for (const scenario of ["combined", "fractional", "muted-music", "silent", "long", "seek", "hybrid-reuse"] as ExportFixtureScenario[]) {
    const draft = makeExportFixtureDraft(sources, music, scenario);
    assert.deepEqual(validateDraft(draft), draft, scenario);
  }
  const combined = makeExportFixtureDraft(sources, music, "combined");
  assert.equal(timelineDuration(combined.clips), 5.5);
  assert.throws(() => validateDraft({...combined,
    narration: {...combined.narration, resultId: "synthetic-660"}}), /Choose a saved narration result/);
  const fractional = makeExportFixtureDraft(sources, music, "fractional");
  const seconds = timelineDuration(fractional.clips);
  assert(Math.abs(seconds - (.517 + (1.789 - .431) / 1.3 + .683)) < 1e-12);
  assert(Math.abs(seconds * 30 - Math.round(seconds * 30)) > .1);
  assert.equal(fractional.clips[0].motion, "pan_left");
  assert.equal(fractional.speech?.[0].reviewed, true);
  assert.equal(fractional.overlays?.length, 1);
  const muted = makeExportFixtureDraft(sources, music, "muted-music");
  assert.equal(muted.audio, "muted");
  assert.equal(muted.music?.ducking, "none");
  const silent = makeExportFixtureDraft(sources, music, "silent");
  assert.equal(silent.audio, "muted"); assert.equal(silent.music, undefined);
  const long = makeExportFixtureDraft(sources, music, "long");
  assert.equal(long.clips.length, 12); assert.equal(timelineDuration(long.clips), 180);
  const seek = makeExportFixtureDraft({sourceSeek: sources.sourceSeek}, undefined, "seek");
  assert.equal(seek.audio, "muted"); assert.equal(seek.music, undefined);
  assert.equal(seek.clips[0].start, .2521); assert.equal(seek.clips[0].end, .7521);
  assert.equal(seek.clips[0].speed, .25); assert.equal(timelineDuration(seek.clips), 2);
  assert(Math.abs(seek.clips[0].start * 120 - 30.252) < 1e-12,
    "Seek source time must retain its interior-frame phase");
  const reuse = makeExportFixtureDraft(sources, undefined, "hybrid-reuse");
  assert.equal(timelineDuration(reuse.clips), 1.5);
  assert.deepEqual(reuse.clips.map(value => value.speed ?? 1), [2, 1, 2]);
  assert.equal(new Set(reuse.clips.map(value => value.id)).size, 3);
  assert.equal(reuse.narration?.offset, .15); assert.equal(reuse.music, undefined);
});
