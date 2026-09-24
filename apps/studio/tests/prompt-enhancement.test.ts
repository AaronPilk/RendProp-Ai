import test from "node:test";
import assert from "node:assert/strict";
import { decodePromptEnhancement, enhancePromptLocally } from "../src/editor/prompt-enhancement";
import { applyConversationPlan, interpretLocalEdit } from "../src/editor/conversation";
import { newDraft, validateDraft, type EditClip, type EditDraft } from "../src/editor/model";

function photo(id: string, index: number): EditClip {
  return { id, source: { name: `${id}.png`, kind: "image", sha256: index.toString(16).padStart(64, "0"), size: 1000, width: 800, height: 450, lastModified: 0, duration: 0 }, start: 0, end: 3, caption: "", focusX: .5, focusY: .5 };
}
function draft(count = 3): EditDraft { return validateDraft({ ...newDraft(), id: "test-edit", revision: 9, clips: Array.from({ length: count }, (_, index) => photo(`clip-${index + 1}`, index + 1)) }); }
function renderIntent(message: string, source: EditDraft) {
  const parsed = interpretLocalEdit(message, source);
  assert.equal(parsed.kind, "plan"); if (parsed.kind !== "plan") throw new Error("Expected executable plan");
  return applyConversationPlan(source, parsed.plan).draft;
}

test("guided enhancement clarifies executable duration and transition wording without adding effects", () => {
  const source = draft(), before = structuredClone(source), original = "please make it 15 secs; use smooth transitions";
  const result = enhancePromptLocally(original, source);
  assert.equal(result.method, "guided"); assert.equal(result.original, original);
  assert.equal(result.enhanced, "Make it 15 seconds; Use dissolve transitions");
  assert.deepEqual(renderIntent(result.enhanced, source), renderIntent(original, source));
  assert.deepEqual(source, before); assert.equal(renderIntent(result.enhanced, source).clips[0].motion, undefined);
});

test("quoted captions and titles preserve exact spaces, punctuation, negation and newlines", () => {
  const source = draft(), original = 'please add caption “Open  house; don’t miss it” to clip 1; set title “Saturday\n2–4 PM”';
  const result = enhancePromptLocally(original, source), expected = renderIntent(original, source);
  assert.equal(result.method, "guided"); assert.notEqual(result.enhanced, original);
  assert.deepEqual(renderIntent(result.enhanced, source), expected);
  assert.equal(expected.clips[0].caption, "Open  house; don’t miss it"); assert.equal(expected.title, "Saturday\n2–4 PM");
  assert(result.notes.some(note => note.includes("preserved exactly")));
});

test("reordering and following caption references stay semantically identical", () => {
  const source = draft(), original = 'Put clip 1 last; add caption "New opening" to clip 1; put clip 3 first';
  const result = enhancePromptLocally(original, source);
  assert.notEqual(result.enhanced, original); assert.deepEqual(renderIntent(result.enhanced, source), renderIntent(original, source));
  assert(result.notes.some(note => note.includes("earlier ordering changes")));
});

test("supported shape, audio, motion and default highlight retain only their requested semantics", () => {
  const source = draft();
  for (const original of ["Make it landscape", "Keep original sound", "Mute the original audio", "Add slow zooms", "Create a listing highlight", "Make a vertical video", "Make it slower"]){
    const result = enhancePromptLocally(original, source);
    assert.deepEqual(renderIntent(result.enhanced, source), renderIntent(original, source), original);
    assert.equal(result.method, "guided");
  }
  assert.equal(enhancePromptLocally("Make it landscape", source).enhanced, "Set the ratio to 16:9");
});

test("unknown, negative and partly unsupported intent remains verbatim without invented facts or partial commands", () => {
  const source = draft();
  for (const original of ["  Give this a luxury feeling  ", "Don't make it shorter", "Put the kitchen first", "Generate a new drone view with music", "Make it shorter; clone my voice", 'Make the house look occupied. Keep “three bedrooms” in the script.']) {
    const result = enhancePromptLocally(original, source);
    assert.equal(result.original, original); assert.equal(result.enhanced, original); assert.equal(result.method, "guided");
    assert(result.notes.length > 0); assert(result.notes.length <= 4); assert(result.notes.every(note => note.length <= 300));
  }
});

test("missing media and timed narration yield useful notes without inventing a media catalog or dropping timing", () => {
  const original = "Make a 15-second reel", result = enhancePromptLocally(original);
  assert.equal(result.enhanced, original); assert(result.notes.some(note => note.includes("Add your photos or clips")));
  const source = { ...draft(), narration: { resultId: "10000000-0000-4000-8000-000000000001", label: "Voice", offset: 0, volume: 1, wordCaptions: false, words: [] } };
  const timed = enhancePromptLocally("Make it shorter", source);
  assert.equal(timed.enhanced, "Make it shorter"); assert(timed.notes.some(note => note.includes("timed narration or cutaways")));
});

test("overlong expanded clip moves keep the original executable request intact", () => {
  const source = draft(12), original = "Put clip 1 last; put clip 1 last";
  const result = enhancePromptLocally(original, source);
  assert.equal(result.enhanced, original); assert(result.notes.some(note => note.includes("could not be verified")));
  assert.deepEqual(renderIntent(result.enhanced, source), renderIntent(original, source));
});

test("proposal decoding binds exact original and validates provider method, size, notes and controls", () => {
  const original = "Make it shorter", response = { original, enhanced: "Make it 8 seconds", method: "ai", notes: ["Suggested a specific duration for review."] };
  assert.deepEqual(decodePromptEnhancement(response, original), response);
  for (const changed of ["make it shorter", "Make it shorter "])
    assert.throws(() => decodePromptEnhancement(response, changed), /prompt changed/);
  for (const patch of [{ method: "unknown" }, { enhanced: "" }, { enhanced: " " }, { enhanced: "x".repeat(2001) }, { enhanced: "bad\u0000text" }, { notes: new Array(5).fill("note") }, { notes: ["x".repeat(301)] }, { notes: ["bad\u007f"] }, { notes: [null] }, { notes: "note" }, { url: "https://example.invalid" }])
    assert.throws(() => decodePromptEnhancement({ ...response, ...patch }, original));
  const detached = decodePromptEnhancement(response, original); detached.notes.push("Local only"); assert.equal(response.notes.length, 1);
});

test("input length, control characters and malformed edit metadata fail before an enhancement is offered", () => {
  for (const value of ["", "  ", "x".repeat(2001), "Make\u0000it shorter", "Make\u007fit shorter", null])
    assert.throws(() => enhancePromptLocally(value as string));
  assert.throws(() => enhancePromptLocally("Make it shorter", { ...draft(), schema: 2 } as unknown as EditDraft), /Unsupported edit plan/);
});
