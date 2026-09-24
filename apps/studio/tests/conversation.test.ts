import test from "node:test";
import assert from "node:assert/strict";
import { applyConversationPlan, interpretLocalEdit, type ConversationOperation } from "../src/editor/conversation";
import { newDraft, validateDraft, timelineDuration, type EditClip, type EditDraft } from "../src/editor/model";
import { createHistory, editHistory, undoHistory } from "../src/editor/history";

function photo(id: string, index = 1): EditClip {
  return { id, source: { name: `${id}.jpg`, kind: "image", sha256: index.toString(16).repeat(64), size: 1000, width: 1200, height: 800, lastModified: 0, duration: 0 }, start: 0, end: 3, caption: "", focusX: .4, focusY: .6 };
}
function video(): EditClip {
  return { ...photo("recording", 0), source: { ...photo("recording", 0).source, name: "agent.mp4", kind: "video", duration: 60 }, start: 4, end: 16, speed: 2, caption: "Original text" };
}
function draft(clips: EditClip[] = [photo("one"), photo("two", 2), photo("three", 3)]): EditDraft {
  return validateDraft({ ...newDraft(), id: "edit", revision: 7, title: "Supplied title", clips });
}
function apply(source: EditDraft, operations: ConversationOperation[]) {
  return applyConversationPlan(source, { draftId: source.id, expectedRevision: source.revision, operations });
}
const narration = { resultId: "10000000-0000-4000-8000-000000000001", label: "Saved voice", offset: 0, volume: 1, wordCaptions: true, words: [{ text: "Welcome", start: 0, end: 1 }] };

test("create a 15-second reel produces an actual schema-1 media sequence without touching sources", () => {
  const source = draft(), before = structuredClone(source), interpreted = interpretLocalEdit("Make a 15-second reel", source);
  assert.equal(interpreted.kind, "plan"); if (interpreted.kind !== "plan") return;
  const result = applyConversationPlan(source, interpreted.plan);
  assert.equal(timelineDuration(result.draft.clips), 15); assert.equal(result.draft.ratio, "9:16");
  assert.deepEqual(result.draft.clips.map(clip => clip.source), source.clips.map(clip => clip.source));
  assert.deepEqual(result.draft.clips.map(clip => clip.id), ["one", "two", "three"]);
  assert.equal(result.draft.clips[0].transition, "cut"); assert.equal(result.draft.clips[1].transition, "dissolve");
  assert(result.draft.clips.every(clip => clip.motion === "push_in")); assert.deepEqual(source, before);
  result.draft.clips[0].source.name = "changed.jpg"; assert.equal(source.clips[0].source.name, "one.jpg");
});

test("mixed duration allocation clamps video at chosen source spans and only extends photos", () => {
  const source = draft([video(), photo("two", 2)]), result = apply(source, [{ type: "duration", seconds: 15 }]);
  assert(Math.abs(timelineDuration(result.draft.clips) - 15) < 1e-8);
  assert.equal(result.draft.clips[0].start, 4); assert.equal(result.draft.clips[0].end, 16); assert.equal(result.draft.clips[0].speed, 2);
  assert.equal(result.draft.clips[1].end, 9); assert.equal(result.draft.audio, source.audio);
  assert.throws(() => apply(draft([video()]), [{ type: "duration", seconds: 15 }]), /without dropping shots or extending video/);
});

test("shorter trims source endings without changing playback speed and discloses speech review", () => {
  const source = draft([video(), photo("two", 2)]), result = apply(source, [{ type: "pace", value: "faster" }]);
  assert(Math.abs(timelineDuration(result.draft.clips) - 7.2) < 1e-8); assert.equal(result.draft.clips[0].speed, 2);
  assert.equal(result.draft.clips[0].start, 4); assert(result.draft.clips[0].end < 16);
  assert.match(result.summary, /Video endings were shortened/); assert.equal(source.clips[0].end, 16);
});

test("duration rejects invalid and impossible values; proportional allocation handles saturated short footage", () => {
  const source = draft([ { ...video(), end: 4.5 }, photo("two", 2), photo("three", 3)]);
  for (const seconds of [NaN, Infinity, -.5, 0, 181]) assert.throws(() => apply(source, [{ type: "duration", seconds }]), /duration/);
  assert.throws(() => apply(source, [{ type: "duration", seconds: .5 }]), /without dropping shots/);
  const result = apply(source, [{ type: "duration", seconds: 20.37 }]);
  assert(Math.abs(timelineDuration(result.draft.clips) - 20.37) < 1e-8); assert.equal(result.draft.clips[0].end, 4.5);
  assert.throws(() => apply(draft([photo("one")]), [{ type: "duration", seconds: 31 }]), /without dropping shots/);
});

test("timed narration and cutaways keep exact timing or reject the entire request", () => {
  const narrated = { ...draft(), narration };
  const cutaway = { ...draft([video()]), overlays: [{ ...photo("cutaway", 2), start: 1, end: 3 }] };
  for (const source of [narrated, cutaway]) {
    for (const operation of [{ type: "duration", seconds: 5 }, { type: "pace", value: "faster" }, { type: "highlight", targetSeconds: 5 }, { type: "reorder", clipIds: source.clips.map(clip => clip.id).reverse() }] as ConversationOperation[])
      assert.throws(() => apply(source, [operation]), /timed narration or cutaways/);
    const result = apply(source, [{ type: "title", text: "Welcome home" }, { type: "transition", value: "cut" }, { type: "audio", value: "muted" }]);
    assert.deepEqual(result.draft.narration, source.narration); assert.deepEqual(result.draft.overlays, "overlays" in source ? source.overlays : undefined);
    assert.equal(timelineDuration(result.draft.clips), timelineDuration(source.clips));
  }
});

test("atomic failures never mutate prior captions or partially apply a message", () => {
  const source = draft(), before = structuredClone(source);
  assert.throws(() => apply(source, [{ type: "title", text: "Changed" }, { type: "caption", clipId: "missing", text: "Hello" }]), /current clip/);
  assert.throws(() => apply(source, [{ type: "title", text: "Changed" }, { type: "duration", seconds: 150 }]), /without dropping shots/);
  assert.deepEqual(source, before);
});

test("stale revisions, unknown fields, invalid enums and malformed operation IDs cannot change the edit", () => {
  const source = draft(), plan = { draftId: source.id, expectedRevision: source.revision, operations: [{ type: "title", text: "Changed" }] };
  for (const bad of [{ ...plan, draftId: "other" }, { ...plan, expectedRevision: 6 }]) assert.throws(() => applyConversationPlan(source, bad), /edit changed/);
  for (const operations of [[], new Array(13).fill(plan.operations[0]), [{ type: "publish" }], [{ type: "audio", value: "clone" }], [{ type: "title", text: "Title", source: "injected" }], [{ type: "caption", clipId: {}, text: "bad" }]])
    assert.throws(() => applyConversationPlan(source, { ...plan, operations }));
  assert.throws(() => applyConversationPlan(source, { ...plan, url: "https://example.invalid" }), /Unsupported/);
  assert.throws(() => applyConversationPlan(source, Object.assign(Object.create({ bypass: true }), plan)), /Unsupported/);
});

test("reordering is exact, keeps sources and all trims, and one message is one undoable revision", () => {
  const source = draft([video(), photo("two", 2), photo("three", 3)]);
  for (const clipIds of [["two"], ["two", "two", "recording"], ["two", "three", "missing"]]) assert.throws(() => apply(source, [{ type: "reorder", clipIds }]), /exactly once/);
  const result = apply(source, [{ type: "reorder", clipIds: ["three", "recording", "two"] }, { type: "caption", clipId: "three", text: "Open house Saturday" }, { type: "ratio", value: "1:1" }]);
  assert.deepEqual(result.draft.clips[1], source.clips[0]); assert.equal(result.draft.revision, source.revision);
  const history = editHistory(createHistory(source), result.draft, "conversation edit");
  assert.equal(history.past.length, 1); assert.equal(history.present.revision, 8);
  const undone = undoHistory(history); assert.deepEqual(undone.present.clips, source.clips); assert.equal(undone.present.ratio, source.ratio); assert.equal(undone.present.revision, 9);
});

test("captions preserve supplied whitespace and semicolons, enforce limits, and never invent text", () => {
  const source = draft(), result = interpretLocalEdit('Add caption "Open  house; don’t miss it" to clip 1', source);
  assert.equal(result.kind, "plan"); if (result.kind !== "plan") return;
  assert.equal(applyConversationPlan(source, result.plan).draft.clips[0].caption, "Open  house; don’t miss it");
  assert.throws(() => apply(source, [{ type: "caption", clipId: "one", text: "x".repeat(121) }]), /120 characters/);
  assert.throws(() => apply(source, [{ type: "title", text: "x".repeat(81) }]), /80 characters/);
  assert.throws(() => apply(source, [{ type: "title", text: "a\nb\nc\nd\ne" }]), /four lines/);
});

test("local commands match complete requests and reject negation, vague room inference and generation", () => {
  const source = draft();
  for (const message of ["Make it shorter", "Add slow zooms", "Use smooth transitions", "Create a listing highlight", "Make a vertical video", "Make a 15-second reel. Use slow zooms and smooth transitions.", "Make it landscape", "Mute it", "Keep original sound", "Put clip 3 first"])
    assert.equal(interpretLocalEdit(message, source).kind, "plan", message);
  for (const message of ["Don't make it shorter", "Make it shorter but don't change the audio", "I might make it shorter tomorrow", "Put the kitchen first", "Generate a drone camera angle", "Add music", "Make it shorter; add a dragon", "Unmute it"])
    assert.notEqual(interpretLocalEdit(message, source).kind, "plan", message);
  assert.equal(interpretLocalEdit('Add caption "Hello', source).kind, "clarification");
  assert.equal(interpretLocalEdit("Make a 15-second reel", draft([])).kind, "clarification");
});

test("compound local edits use the current order and fail as a whole if any clause is unsupported", () => {
  const source = draft(), interpreted = interpretLocalEdit('Put clip 3 first; add caption "Opening" to clip 1; put clip 2 last', source);
  assert.equal(interpreted.kind, "plan"); if (interpreted.kind !== "plan") return;
  const result = applyConversationPlan(source, interpreted.plan).draft;
  assert.deepEqual(result.clips.map(clip => clip.id), ["three", "two", "one"]); assert.equal(result.clips[0].caption, "Opening");
  assert.notEqual(interpretLocalEdit("Make it shorter; generate new rooms", source).kind, "plan");
  assert.equal(interpretLocalEdit(new Array(13).fill("Use hard cuts").join("; "), source).kind, "clarification");
});
