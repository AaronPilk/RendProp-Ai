import test from "node:test";
import assert from "node:assert/strict";
import {
  HISTORY_LIMITS, closeHistoryGroup, createHistory, editHistory, historyBytes,
  redoHistory, releasedMediaIds, undoHistory,
} from "../src/editor/history.ts";
import { assertCurrentRevision, assertSourceMatch, moveClip, serializeDraft, type EditDraft } from "../src/editor/model.ts";

const initial = (): EditDraft => ({
  schema: 1, id: "history-plan", revision: 2, ratio: "9:16", title: "Original", audio: "original",
  clips: ["first", "second"].map((id, index) => ({
    id, source: { name: `${id}.mp4`, size: 1234, lastModified: 100,
      sha256: (index ? "b" : "a").repeat(64), kind: "video", width: 640, height: 360, duration: 8 },
    start: 1, end: 4, caption: "Original caption", focusX: 0.5, focusY: 0.5,
  })),
});

test("history reverses timing, captions, order, ratio, and removal as fresh revisions", () => {
  let history = createHistory(initial());
  const states = [history.present];
  const patches = [
    { clips: history.present.clips.map((clip, index) => index === 0 ? { ...clip, start: 2, end: 6 } : clip) },
    { ratio: "1:1" as const },
    { title: "New story", audio: "muted" as const },
  ];
  for (const patch of patches) {
    history = editHistory(history, patch, "edit");
    states.push(history.present);
  }
  history = editHistory(history, { clips: history.present.clips.map((clip) => ({ ...clip, caption: "New caption", focusX: 0.8 })) }, "caption");
  states.push(history.present);
  history = editHistory(history, { clips: moveClip(history.present.clips, 0, 1) }, "order");
  states.push(history.present);
  history = editHistory(history, { clips: history.present.clips.slice(1) }, "remove");
  states.push(history.present);
  let revision = history.present.revision;
  for (let index = states.length - 2; index >= 0; index--) {
    const before = history.present;
    history = undoHistory(history);
    assert.deepEqual(history.present, { ...states[index], revision: ++revision });
    assert.throws(() => assertCurrentRevision(before, history.present, new AbortController().signal), { name: "AbortError" });
  }
  assert.equal(undoHistory(history), history);
  for (const state of states.slice(1)) {
    history = redoHistory(history);
    assert.deepEqual(history.present, { ...state, revision: ++revision });
  }
  assert.equal(redoHistory(history), history);
  assert.equal(initial().clips[0]!.start, 1);
  assert.equal(states[0]!.clips[0]!.caption, "Original caption");
});

test("a focused field coalesces changes; leaving the field starts a new undo step", () => {
  let history = createHistory(initial());
  history = editHistory(history, { title: "N" }, "title", "title");
  history = editHistory(history, { title: "New" }, "title", "title");
  assert.equal(history.past.length, 1);
  assert.equal(undoHistory(history).present.title, "Original");
  history = closeHistoryGroup(history);
  history = editHistory(history, { title: "New story" }, "title", "title");
  assert.equal(history.past.length, 2);
  assert.equal(undoHistory(history).present.title, "New");
});

test("no-op edits preserve redo and revision; a real divergent edit clears redo", () => {
  let history = editHistory(createHistory(initial()), { title: "Changed" }, "title");
  history = undoHistory(history);
  assert.equal(history.future.length, 1);
  assert.equal(editHistory(history, { title: "Original" }, "title"), history);
  history = editHistory(history, { title: "Branch" }, "title");
  assert.equal(history.future.length, 0);
  assert.equal(redoHistory(history), history);
  assert.equal(createHistory(history.present).past.length, 0);
  assert.equal(createHistory(history.present).future.length, 0);
});

test("history bounds combined past/future step count and UTF-8 metadata bytes", () => {
  let history = createHistory(initial());
  for (let index = 0; index < 80; index++) history = editHistory(history, { title: String(index) }, "title");
  assert.equal(history.past.length, HISTORY_LIMITS.steps);
  for (let index = 0; index < 80; index++) {
    history = undoHistory(history);
    assert.ok(history.past.length + history.future.length <= HISTORY_LIMITS.steps);
    assert.ok(historyBytes(history) <= HISTORY_LIMITS.bytes);
  }
  assert.equal(history.present.title, "59");
  const large = initial();
  large.clips = Array.from({ length: 12 }, (_, index) => ({ ...large.clips[0]!, id: String(index), caption: "🌟".repeat(60), source: { ...large.clips[0]!.source, name: "🌟".repeat(120) + ".mp4" } }));
  history = createHistory(large);
  for (let index = 0; index < 80; index++) history = editHistory(history, { title: String(index) }, "title");
  assert.ok(history.past.length > 0 && history.past.length < HISTORY_LIMITS.steps);
  assert.ok(historyBytes(history) <= HISTORY_LIMITS.bytes);
  for (let index = 0; index < 80; index++) {
    history = index % 2 ? redoHistory(history) : undoHistory(history);
    assert.ok(historyBytes(history) <= HISTORY_LIMITS.bytes);
  }
});

test("removed sources are released, and undo restores exact identity without retaining media", () => {
  let history = createHistory(initial());
  const source = history.present.clips[0]!.source;
  const sources = new Map(history.present.clips.map((clip) => [clip.id, clip.source]));
  history = editHistory(history, { clips: history.present.clips.slice(1) }, "remove");
  assert.deepEqual(releasedMediaIds(history.present, sources), ["first"]);
  sources.delete("first");
  history = undoHistory(history);
  assert.equal(sources.has("first"), false);
  assert.deepEqual(history.present.clips[0]!.source, source);
  assert.doesNotThrow(() => assertSourceMatch(history.present.clips[0]!.source, source));
  assert.throws(() => assertSourceMatch(source, { ...source, sha256: "c".repeat(64) }), /different file/);
  const wrong = new Map([["first", { ...source, sha256: "c".repeat(64) }]]);
  assert.deepEqual(releasedMediaIds(history.present, wrong), ["first"]);
  assert.deepEqual(releasedMediaIds(history.present, sources), []);
  const reopened = createHistory({ ...initial(), blobURL: "blob:untrusted", clips: initial().clips.map((clip) => ({ ...clip, file: "not retained", source: { ...clip.source, url: "blob:untrusted" } })) } as EditDraft);
  const saved = JSON.stringify(editHistory(reopened, { title: "Safe" }, "title"));
  assert.equal(saved.includes("blob:"), false);
  assert.equal(saved.includes("not retained"), false);
  assert.equal(serializeDraft(history.present).includes("past"), false);
});

test("invalid edits, poisoned history, identity crossover, and revision overflow fail without mutation", () => {
  const history = createHistory(initial());
  const before = JSON.stringify(history);
  assert.throws(() => editHistory(history, { clips: [{ ...history.present.clips[0]!, end: 0 }] }, "trim"), /trim end/);
  assert.throws(() => editHistory(history, { title: "x".repeat(81) }, "title"), /title/);
  assert.throws(() => editHistory(history, { title: "x" }, "title", "x".repeat(129)), /history group/);
  assert.throws(() => editHistory(history, { title: "x" }, ""), /history label/);
  assert.equal(JSON.stringify(history), before);
  assert.throws(() => undoHistory({ ...history, past: [{ label: "bad", json: "{" }] }), SyntaxError);
  assert.throws(() => undoHistory({ ...history, past: [{ label: "bad", json: JSON.stringify({ ...initial(), id: "other-plan" }) }] }), /another plan/);
  const exhausted = { ...history, present: { ...history.present, revision: Number.MAX_SAFE_INTEGER - 1 }, past: [{ label: "edit", json: JSON.stringify(initial()) }] };
  assert.throws(() => undoHistory(exhausted), /revision/);
  assert.throws(() => redoHistory({ ...exhausted, future: exhausted.past }), /revision/);
});
