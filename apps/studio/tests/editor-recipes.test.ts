import test from "node:test";
import assert from "node:assert/strict";
import { buildRecipeDraft } from "../src/editor/recipes";
import { splitVideoAtTime } from "../src/editor/edit-actions";
import { createHistory, editHistory, undoHistory, redoHistory } from "../src/editor/history";
import { clipDuration, draftMedia, newDraft, parseDraft, serializeDraft, timelineDuration, validateDraft, validateFileBatch, type EditClip, type EditDraft } from "../src/editor/model";

function photo(id: string, index = 1): EditClip {
  return { id, source: { name: `${id}.jpg`, kind: "image", sha256: index.toString(16).repeat(64), size: 1000, width: 1200, height: 800, lastModified: 0, duration: 0 }, start: 0, end: 3, caption: "", focusX: .4, focusY: .6 };
}
function recording(id = "presenter"): EditClip {
  return { ...photo(id, 0), source: { ...photo(id, 0).source, name: "agent.mp4", kind: "video", duration: 60 }, start: 5, end: 50, caption: "Agent supplied title" };
}
function draft(clips: EditClip[] = [recording(), photo("kitchen", 1), photo("exterior", 2)]): EditDraft {
  return validateDraft({ ...newDraft(), id: "property-edit", revision: 7, title: "User supplied property", clips });
}
const narration = { resultId: "10000000-0000-4000-8000-000000000001", label: "Saved voice", offset: 0, volume: 1, wordCaptions: true, words: [{ text: "Welcome", start: 0, end: 1 }] };

test("listing highlight retains exact identity, trims, order and supplied text without mutating input", () => {
  const source = draft(), before = structuredClone(source);
  const result = buildRecipeDraft(source, "listing-highlight");
  assert.deepEqual(source, before);
  assert.equal(result.draft.id, source.id); assert.equal(result.draft.revision, source.revision);
  assert.deepEqual(result.draft.clips.map(clip => clip.id), source.clips.map(clip => clip.id));
  result.draft.clips.forEach((clip, index) => { assert.deepEqual(clip.source, source.clips[index].source); assert.equal(clip.caption, source.clips[index].caption); });
  assert.equal(result.draft.clips[0].start, 5); assert.equal(result.draft.clips[0].end, 9);
  assert.equal(result.draft.clips[1].motion, "push_in"); assert.equal(result.draft.clips[1].end, 4);
  assert.equal(result.draft.title, source.title); assert.deepEqual(result.omittedSourceIds, []);
  assert.equal(result.draft.clips[1].caption, "");
});

test("highlight timing respects existing speed and short selected source spans", () => {
  const fast = { ...recording(), speed: 2, start: 6, end: 12 }, short = { ...recording("short"), start: 0, end: 1 };
  const result = buildRecipeDraft(draft([fast, short]), "listing-highlight", { shotSeconds: 2 });
  assert.equal(result.draft.clips[0].end, 10); assert.equal(clipDuration(result.draft.clips[0]), 2);
  assert.equal(result.draft.clips[1].end, 1);
});

test("production targets pace highlights without extending source spans or truncating speech", () => {
  const photos = draft(Array.from({length:6}, (_,index) => photo(`photo-${index}`, index+1)));
  assert.equal(timelineDuration(buildRecipeDraft(photos, "listing-highlight", {targetSeconds:30}).draft.clips),30);
  const short = buildRecipeDraft(draft([{...recording(),start:0,end:2},photo("kitchen")]),"listing-highlight",{targetSeconds:60});
  assert.equal(timelineDuration(short.draft.clips),10); assert(short.reviewNotes.some(note=>note.includes("this draft is 10 seconds")));
  const speech = buildRecipeDraft(draft(),"agent-tour",{primaryClipId:"presenter",targetSeconds:30});
  assert.equal(timelineDuration(speech.draft.clips),45); assert(speech.reviewNotes.some(note=>note.includes("recording range is retained")));
  assert.throws(()=>buildRecipeDraft(photos,"listing-highlight",{targetSeconds:0 as never}),/target/);
});

test("agent tour preserves the complete selected speech range and moves exact photo identities into cutaways", () => {
  const source = draft(), result = buildRecipeDraft(source, "agent-tour", { primaryClipId: "presenter" });
  assert.equal(result.draft.audio, "original"); assert.equal(result.draft.clips.length, 1);
  assert.equal(result.draft.clips[0].start, 5); assert.equal(result.draft.clips[0].end, 50);
  assert.equal(result.draft.clips[0].speed, 1); assert.equal(timelineDuration(result.draft.clips), 45);
  assert.deepEqual(result.draft.overlays!.map(item => item.id), ["kitchen", "exterior"]);
  assert.deepEqual(result.draft.overlays![0].source, source.clips[1].source);
  assert(result.draft.overlays![0].start >= 2); assert(result.draft.overlays!.at(-1)!.end <= 43);
  for (let index = 1; index < result.draft.overlays!.length; index++) assert(result.draft.overlays![index].start - result.draft.overlays![index - 1].end >= 1);
  assert(result.reviewNotes.some(note => note.includes("no transcript matching")));
});

test("agent tour never guesses a presenter, source range or missing footage", () => {
  assert.throws(() => buildRecipeDraft(draft(), "agent-tour"), /Choose the recording/);
  assert.throws(() => buildRecipeDraft(draft(), "agent-tour", { primaryClipId: "kitchen" }), /Choose the recording/);
  assert.throws(() => buildRecipeDraft(draft(), "agent-tour", { primaryClipId: "presenter", primaryRange: { start: 4, end: 61 } }), /source range/);
  const short = buildRecipeDraft(draft([{ ...recording(), end: 7 }, photo("kitchen")]), "agent-tour", { primaryClipId: "presenter" });
  assert.equal(short.draft.clips[0].end, 7); assert.equal(short.draft.overlays!.length, 0);
  assert.deepEqual(short.omittedSourceIds, ["kitchen"]); assert(short.reviewNotes.some(note => note.includes("under 15 seconds")));
});

test("explicit full recording selection is bounded and normal-speed speech is enforced", () => {
  const source = draft([{ ...recording(), speed: 2 }]);
  const result = buildRecipeDraft(source, "agent-tour", { primaryClipId: "presenter", primaryRange: { start: 0, end: 60 } });
  assert.equal(timelineDuration(result.draft.clips), 60); assert.equal(result.draft.clips[0].speed, 1);
  const long = draft([{ ...recording(), source: { ...recording().source, duration: 300 } }]);
  assert.throws(() => buildRecipeDraft(long, "agent-tour", { primaryClipId: "presenter", primaryRange: { start: 0, end: 181 } }), /3 minutes/);
});

test("market update limits supporting images, names omitted items and never invents statistics", () => {
  const source = draft([recording(), ...Array.from({ length: 5 }, (_, index) => ({ ...photo(`chart-${index}`, index + 1), caption: index === 0 ? "User reviewed data: period September" : "" }))]);
  const result = buildRecipeDraft(source, "market-update", { primaryClipId: "presenter" });
  assert.equal(result.draft.overlays!.length, 3); assert.equal(result.draft.overlays![0].caption, source.clips[1].caption);
  assert.equal(result.draft.overlays![1].caption, ""); assert(result.draft.overlays!.every(item => item.motion === "still"));
  assert.deepEqual(result.omittedSourceIds, ["chart-3", "chart-4"]);
  assert(result.reviewNotes.some(note => note.includes("No statistics")));
});

test("recipes disclose removal of narration and keep highlight narration without regeneration", () => {
  const source = { ...draft(), narration };
  const tour = buildRecipeDraft(source, "agent-tour", { primaryClipId: "presenter" });
  assert.equal(tour.draft.narration, undefined); assert(tour.reviewNotes.some(note => note.includes("Saved narration is removed")));
  const highlight = buildRecipeDraft(source, "listing-highlight"); assert.deepEqual(highlight.draft.narration, narration);
  assert(highlight.reviewNotes.some(note => note.includes("shorter picture sequence")));
});

test("recipe application is a single reversible revision with ordinary schema-1 persistence", () => {
  const source = { ...draft(), narration }, planned = buildRecipeDraft(source, "agent-tour", { primaryClipId: "presenter" });
  let history = editHistory(createHistory(source), planned.draft, "guided draft");
  assert.equal(history.past.length, 1); assert.equal(history.present.revision, 8);
  assert.deepEqual(parseDraft(serializeDraft(history.present)), history.present);
  history = undoHistory(history); assert.deepEqual(history.present.clips, source.clips); assert.deepEqual(history.present.narration, narration);
  history = redoHistory(history); assert.deepEqual(history.present.overlays, planned.draft.overlays); assert.equal(history.present.revision, 10);
});

test("existing cutaway photos can return to an editable sequence with the same identities", () => {
  const tour = buildRecipeDraft(draft(), "agent-tour", { primaryClipId: "presenter" }).draft;
  const highlight = buildRecipeDraft(tour, "listing-highlight").draft;
  assert.deepEqual(draftMedia(highlight).map(item => item.id), ["presenter", "kitchen", "exterior"]);
  assert.equal(highlight.overlays!.length, 0); assert(highlight.clips.slice(1).every(clip => clip.start === 0));
});

test("recipe options and inherited source identities use the editor's validator", () => {
  assert.throws(() => buildRecipeDraft(draft(), "listing-highlight", { shotSeconds: NaN }), /shot length/);
  assert.throws(() => buildRecipeDraft(draft(), "listing-highlight", { shotSeconds: 40 }), /shot length/);
  assert.throws(() => buildRecipeDraft(draft(), "listing-highlight", { captionStyle: "unsupported" as never }), /caption style/);
  assert.throws(() => buildRecipeDraft({ ...draft(), clips: [] }, "listing-highlight"), /Add your property/);
  assert.throws(() => buildRecipeDraft(draft(), "unknown" as never), /supported guided draft/);
  const result = buildRecipeDraft({ ...draft(), storage_url: "https://not-persisted.invalid" } as EditDraft, "listing-highlight");
  assert(!serializeDraft(result.draft).includes("not-persisted"));
});

test("split converts timeline position to source seconds and preserves speed, audio and cutaways", () => {
  const source = { ...draft([{ ...recording(), start: 4, end: 24, speed: 2 }]), narration };
  const result = splitVideoAtTime(source, 3, "right");
  assert.equal(result.clips[0].end, 10); assert.equal(result.clips[1].start, 10); assert.equal(result.clips[1].end, 24);
  assert.equal(result.clips[0].id, "presenter"); assert.equal(result.clips[1].id, "right");
  assert.equal(result.clips[1].transition, "cut"); assert.equal(result.clips[1].speed, 2);
  assert.equal(timelineDuration(result.clips), timelineDuration(source.clips));
  assert.deepEqual(result.narration, narration); assert.equal(source.clips.length, 1);
});

test("split uses the playhead's actual clip and rejects endpoints, photos, duplicate IDs and limits", () => {
  const source = draft([photo("opening"), recording()]);
  const result = splitVideoAtTime(source, 6, "right"); assert.equal(result.clips[1].end, 8);
  assert.throws(() => splitVideoAtTime(source, 1, "right"), /inside a video/);
  assert.throws(() => splitVideoAtTime(source, 3, "right"), /half a second/);
  assert.throws(() => splitVideoAtTime(source, 500, "right"), /half a second/);
  assert.throws(() => splitVideoAtTime(source, NaN, "right"), /playhead/);
  assert.throws(() => splitVideoAtTime(source, 6, "presenter"), /Duplicate/);
  const full = draft(Array.from({ length: 12 }, (_, index) => ({ ...recording(`clip-${index}`), start: 0, end: 2 })));
  assert.throws(() => splitVideoAtTime(full, 1, "right"), /12 clips/);
});

test("split counts a shared source once and rejects conflicting metadata for a shared hash", () => {
  const big = { ...recording(), source: { ...recording().source, size: 128 * 1024 ** 2 } };
  let source = draft([big]);
  for (let index = 0; index < 4; index++) source = splitVideoAtTime(source, 2 + index * 2, `split-${index}`);
  assert.equal(source.clips.length, 5); assert.equal(timelineDuration(source.clips), 45);
  assert.doesNotThrow(() => validateFileBatch([{name:"extra.jpg",type:"image/jpeg",size:1000}],source.clips));
  const renamed = source.clips.map((clip,index) => index ? clip : {...clip,source:{...clip.source,name:"same-bytes.mp4",lastModified:1234}});
  assert.doesNotThrow(()=>validateDraft({...source,clips:renamed}));
  const bad = source.clips.map((clip, index) => index ? clip : { ...clip, source: { ...clip.source, width: 800 } });
  assert.throws(() => validateDraft({ ...source, clips: bad }), /different file/);
  const durationMismatch = source.clips.map((clip,index) => index ? clip : {...clip,source:{...clip.source,duration:61}});
  assert.throws(()=>validateDraft({...source,clips:durationMismatch}),/different file/);
});
