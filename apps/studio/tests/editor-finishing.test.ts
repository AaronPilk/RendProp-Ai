import assert from "node:assert/strict";
import test from "node:test";
import {newDraft, validateDraft, reviseDraft, type EditClip, type EditDraft} from "../src/editor/model";
import {musicGainAt, parseSubtitleFile, proposeBeatCuts, speechCaption, validateMusic, validateSpeech} from "../src/editor/finishing";
import {detectBeatGrid} from "../src/editor/music";
import {createHistory, editHistory, undoHistory, redoHistory} from "../src/editor/history";
const source = {name: "room.mp4", size: 4000, lastModified: 0, sha256: "a".repeat(64), kind: "video" as const, width: 640, height: 360, duration: 12};
const clip: EditClip = {id: "clip-1", source, start: 2, end: 8, caption: "", focusX: .5, focusY: .5};
const music = {source: {name: "licensed.wav", size: 1200, lastModified: 0, sha256: "b".repeat(64), duration: 10, mime: "audio/wav"}, start: 0, end: 10, offset: 0, volume: .5, fadeIn: 1, fadeOut: 1, ducking: "speech" as const, licensed: true as const};
const speech = [{sourceSha256: source.sha256, sourceDuration: 12, reviewed: true as const, words: [{text: "Welcome", start: 3, end: 3.5}, {text: "home", start: 3.5, end: 4}, {text: "outside", start: 9, end: 10}]}];
const draft = (): EditDraft => validateDraft({...newDraft(), clips: [clip], music, speech});
test("music and reviewed source-bound captions survive serialized validation and undo/redo", () => {
  const original = draft(); assert.deepEqual(validateDraft(JSON.parse(JSON.stringify(original))), original);
  let history = editHistory(createHistory(original), {music: undefined, speech: undefined}, "remove finish");
  history = undoHistory(history); assert.deepEqual(history.present.music, original.music); assert.deepEqual(history.present.speech, original.speech);
  history = redoHistory(history); assert.equal(history.present.music, undefined); assert.equal(history.present.speech, undefined);
  assert.deepEqual(reviseDraft(original, {clips: []}).speech, [], "Removed footage must not leave private transcript text in a shared draft");
  assert.throws(() => validateMusic({...music, licensed: false}), /permission/);
  assert.throws(() => validateMusic({...music, source: {...music.source, size: 17 * 1024 * 1024}}), /bytes/);
  assert.throws(() => validateSpeech([{...speech[0], reviewed: false}]), /Review/);
  assert.throws(() => validateSpeech([{...speech[0], words: [{text: "bad", start: 2, end: 1}]}]), /speech end/);
});
test("captions follow original trim, speed and fingerprint rather than timeline position", () => {
  const edit = draft(); assert.equal(speechCaption(edit, clip, 1.1), "Welcome"); assert.equal(speechCaption(edit, {...clip, speed: 2}, .6), "Welcome");
  assert.equal(speechCaption(edit, {...clip, source: {...source, sha256: "c".repeat(64)}}, 1.1), "");
  assert.equal(speechCaption(edit, {...clip, start: 4.1}, 0), "");
  assert.equal(speechCaption(edit, clip, 7.1), "");
});
test("music fades at the edit end and ducks only the chosen audio intervals", () => {
  const edit = draft(); assert.equal(musicGainAt(edit, clip, 0, 0), 0);
  assert.equal(musicGainAt(edit, clip, .5, .5), .25);
  assert.equal(musicGainAt(edit, clip, 1.2, 1.2), .11);
  assert.equal(musicGainAt(edit, clip, 4, 4), .5);
  assert.equal(musicGainAt(edit, clip, 5.5, 5.5), .25); assert.equal(musicGainAt(edit, clip, 6, 6), 0);
  const muted = {...edit, audio: "muted" as const}; assert.equal(musicGainAt(muted, clip, 1.2, 1.2), .5);
  const voice = {...edit, narration: {resultId: "00000000-0000-0000-0000-000000000001", label: "voice", offset: 3, volume: 1, wordCaptions: false, words: []}};
  assert.equal(musicGainAt(voice, clip, 3.5, 3.5, 1), .11); assert.equal(musicGainAt(voice, clip, 4.5, 4.5, 1), .5);
});
test("beat proposal changes nothing until applied, preserves media and never extends selected video", () => {
  const edit = validateDraft({...newDraft(), clips: [{...clip, start: 0, end: 2.8}, {...clip, id: "two", start: 3, end: 6.1}]});
  const before = JSON.stringify(edit), proposal = proposeBeatCuts(edit, 120, 0);
  assert.equal(JSON.stringify(edit), before); assert.equal(proposal.clips[0].end, 2.5); assert.equal(proposal.clips[1].end, 6.1);
  assert.equal(proposal.clips[0].source.sha256, source.sha256); assert.equal(proposal.revision, edit.revision);
  const applied = reviseDraft(edit, {clips: proposal.clips}); assert.equal(applied.revision, edit.revision + 1);
  assert.throws(() => proposeBeatCuts({...edit, overlays: [{id: "anything"} as never]}, 120, 0), /timed/);
});
test("SRT and VTT preserve supplied cue timing; malformed or overlong data fail", () => {
  const words = parseSubtitleFile("1\n00:00:01,000 --> 00:00:02,500\nWelcome home\n\n2\n00:00:03,000 --> 00:00:04,000\nKitchen", 5);
  assert.deepEqual(words, [{text: "Welcome home", start: 1, end: 2.5}, {text: "Kitchen", start: 3, end: 4}]);
  assert.equal(parseSubtitleFile("WEBVTT\n\n00:01.000 --> 00:02.000\nHello", 3)[0].start, 1);
  assert.throws(() => parseSubtitleFile("1\n00:00:03,000 --> 00:00:02,000\nBad", 5), /speech end/);
  assert.throws(() => parseSubtitleFile("x".repeat(140000), 5), /128 KiB/);
  assert.throws(() => parseSubtitleFile("1\n00:00:01,000 --> 00:00:02,000\nValid\n\nuntimed missing words", 5), /Every subtitle/);
  assert.throws(() => parseSubtitleFile("1\n00:00:80,000 --> 00:01:30,000\nBad clock", 100), /timestamp/);
});
test("beat analysis finds synthetic 120 BPM pulses and rejects silence", () => {
  const rate = 8000, samples = new Float32Array(rate * 8);
  for (let beat = 0; beat < 16; beat++) for (let i = 0; i < 160; i++) samples[Math.round((beat * .5 + .1) * rate) + i] = Math.sin(i * .8) * (1 - i / 160);
  const found = detectBeatGrid(samples, rate); assert(Math.abs(found.bpm - 120) < 3); assert(Math.abs(found.firstBeat - .1) < .05);
  assert.throws(() => detectBeatGrid(new Float32Array(rate * 4), rate), /No clear beat/);
});

test("chat music instructions are explicit, atomic and preserve original speech/media", async () => {
  const {interpretLocalEdit, applyConversationPlan} = await import("../src/editor/conversation");
  const {enhancePromptLocally} = await import("../src/editor/prompt-enhancement");
  const edit = draft(), instruction = "Make music quieter; lower music under speech; fade music in and out over 0.5 seconds";
  const interpreted = interpretLocalEdit(instruction, edit); assert.equal(interpreted.kind, "plan");
  if (interpreted.kind !== "plan") return;
  const result = applyConversationPlan(edit, interpreted.plan).draft;
  assert.equal(result.music?.volume, .25); assert.equal(result.music?.fadeIn, .5); assert.deepEqual(result.speech, edit.speech); assert.deepEqual(result.clips, edit.clips);
  const enhanced = enhancePromptLocally(instruction, edit); assert.match(enhanced.enhanced, /25 percent/);
  assert.equal(interpretLocalEdit("Make music quieter; invent a dragon", edit).kind, "unsupported");
  assert.equal(interpretLocalEdit("Set music volume to 120 percent", edit).kind, "clarification");
});

test("speaking selections require exact transcript-backed spans and preserve sources", async () => {
  const {decodeSpeechPassages, useSpeechPassage} = await import("../src/editor/finishing");
  const words = [{text:"Welcome",start:2,end:2.5},{text:"home",start:2.5,end:4}], raw={segments:[{id:"one",start:2,end:4,text:"Welcome home"}],highlights:[{segmentIds:["one"],start:2,end:4,reason:"speaking"}]};
  const passages=decodeSpeechPassages(raw,words,12);assert.deepEqual(passages,[{start:2,end:4,text:"Welcome home"}]);
  const changed=useSpeechPassage(draft(),clip.id,passages[0]);assert.equal(changed[0].start,2);assert.equal(changed[0].end,4);assert.deepEqual(changed[0].source,source);
  assert.throws(()=>decodeSpeechPassages({...raw,segments:[{...raw.segments[0],text:"Invented sales claim"}]},words,12),/not backed/);
  assert.throws(()=>decodeSpeechPassages({...raw,highlights:[{...raw.highlights[0],end:5}]},words,12),/timing changed/);
  assert.throws(()=>useSpeechPassage({...draft(),overlays:[{} as never]},clip.id,passages[0]),/timed/);
});
