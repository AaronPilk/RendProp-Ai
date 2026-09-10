// agentreel_test.ts — the rules that make an agent reel watchable, asserted.
//
// The point of this file is that the six rules in agentreel.ts's header are
// PROPERTIES OF THE PLANNER, not hopes about a prompt. Every one of them is
// checked here against a transcript, and the two guarantees that protect a user
// from a bad model answer — matching by window_id, and refusing a picture we
// never offered — are checked against deliberately hostile replies.

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { type ShotPhoto } from "./shotlist.ts";
import {
  FACE_LEAD_SECONDS,
  FACE_TAIL_SECONDS,
  MAX_BROLL_SECONDS,
  MAX_BROLL_SHARE,
  MAX_WINDOWS,
  MIN_BROLL_SECONDS,
  MIN_FACE_GAP_SECONDS,
  type Phrase,
  agentReelInstruction,
  buildAgentReelTurn,
  cleanTranscript,
  coveredSeconds,
  moveFor,
  parseAgentReel,
  planWindows,
  subjectOf,
  transcriptText,
} from "./agentreel.ts";

// A realistic sixty-second take: an agent walking a listing and talking.
const CLIP = 60;
const PHRASES: Phrase[] = [
  { t: 0.0, text: "Hey, I'm Aaron and I want to show you something." },
  { t: 3.2, text: "This one just came on the market this morning." },
  { t: 6.4, text: "The kitchen is the reason you're going to want this house." },
  { t: 10.1, text: "Quartz waterfall island, gas range, and it opens straight onto the deck." },
  { t: 14.8, text: "Which means you're cooking and still talking to everyone outside." },
  { t: 18.9, text: "Upstairs there are four bedrooms." },
  { t: 21.6, text: "The primary has a vaulted ceiling and its own balcony." },
  { t: 25.4, text: "The bathroom was redone last year, floor to ceiling." },
  { t: 29.7, text: "Out back you've got a fenced yard and a covered patio." },
  { t: 34.2, text: "It's a ten minute drive to the water." },
  { t: 37.5, text: "Priced at six ninety five." },
  { t: 40.1, text: "I think it goes this weekend." },
  { t: 43.0, text: "If you want to see it before it does, message me." },
  { t: 47.2, text: "I'll get you in tonight." },
  { t: 50.0, text: "That's it. Let's go look at it." },
];

const PHOTOS: ShotPhoto[] = [
  { id: "p_kitchen", room: "Kitchen", caption_hint: "waterfall island, gas range" },
  { id: "p_deck", room: "Backyard", caption_hint: "covered patio" },
  { id: "p_primary", room: "Primary Bedroom", caption_hint: "vaulted, balcony door" },
  { id: "p_bath", room: "Primary Bath", caption_hint: "redone 2025" },
  { id: "p_front", room: "Exterior Front", caption_hint: "" },
];

const WINDOWS = planWindows(PHRASES, CLIP, PHOTOS.length);

// ── The transcript ───────────────────────────────────────────────────────────

Deno.test("cleanTranscript drops non-advancing timestamps instead of sorting them", () => {
  const out = cleanTranscript(
    [
      { t: 0, text: "one" },
      { t: 5, text: "two" },
      { t: 2, text: "out of order" }, // a recogniser that lost the thread
      { t: 5, text: "duplicate" },
      { t: 9, text: "three" },
    ],
    30,
  );
  assertEquals(out.map((p) => p.text), ["one", "two", "three"]);
});

Deno.test("cleanTranscript refuses phrases past the end of the clip", () => {
  const out = cleanTranscript([{ t: 1, text: "in" }, { t: 99, text: "out" }], 30);
  assertEquals(out.length, 1);
});

Deno.test("transcriptText is the agent's own words, joined for the input gate", () => {
  assertStringIncludes(transcriptText(PHRASES), "Quartz waterfall island");
});

// ── The six rules ────────────────────────────────────────────────────────────

Deno.test("rule 1: nothing cuts away before the face lead", () => {
  assert(WINDOWS.length > 0, "the fixture should produce windows");
  for (const w of WINDOWS) assert(w.start >= FACE_LEAD_SECONDS, `${w.window_id} starts at ${w.start}`);
});

Deno.test("rule 2: nothing cuts away inside the face tail", () => {
  for (const w of WINDOWS) assert(w.end <= CLIP - FACE_TAIL_SECONDS, `${w.window_id} ends at ${w.end}`);
});

Deno.test("rule 3: every boundary is a phrase boundary or the clip's end", () => {
  const starts = new Set(PHRASES.map((p) => p.t));
  const ends = new Set<number>([...PHRASES.map((p) => p.t), CLIP]);
  for (const w of WINDOWS) {
    assert(starts.has(w.start), `${w.window_id} starts mid-phrase at ${w.start}`);
    assert(ends.has(w.end), `${w.window_id} ends mid-phrase at ${w.end}`);
  }
});

Deno.test("rule 4: the agent is seen between any two cutaways", () => {
  for (let i = 1; i < WINDOWS.length; i++) {
    const gap = WINDOWS[i].start - WINDOWS[i - 1].end;
    assert(gap >= MIN_FACE_GAP_SECONDS, `only ${gap}s of face between ${i - 1} and ${i}`);
  }
});

Deno.test("rule 5: b-roll never exceeds its share of the clip", () => {
  assert(coveredSeconds(WINDOWS) <= CLIP * MAX_BROLL_SHARE);
});

Deno.test("every window is a real shot length", () => {
  for (const w of WINDOWS) {
    const len = w.end - w.start;
    assert(len >= MIN_BROLL_SECONDS && len <= MAX_BROLL_SECONDS, `${w.window_id} is ${len}s`);
  }
});

Deno.test("a window carries the words spoken underneath it", () => {
  // This is what lets the model match a picture to a sentence rather than to a
  // position, so it must never be empty.
  for (const w of WINDOWS) assert(w.says.length > 0, `${w.window_id} has no words`);
});

Deno.test("windows are capped by the number of photographs on offer", () => {
  assertEquals(planWindows(PHRASES, CLIP, 2).length, 2);
  assertEquals(planWindows(PHRASES, CLIP, 0).length, 0);
});

Deno.test("a clip with no transcript gets no cutaways rather than blind ones", () => {
  assertEquals(planWindows([], CLIP, PHOTOS.length).length, 0);
});

Deno.test("MAX_WINDOWS is a real ceiling on a long take", () => {
  const many: Phrase[] = [];
  for (let i = 0; i < 120; i++) many.push({ t: i * 2, text: `phrase ${i}` });
  assert(planWindows(many, 240, 60).length <= MAX_WINDOWS);
});

Deno.test("planning is deterministic — the same take edits the same way twice", () => {
  assertEquals(
    JSON.stringify(planWindows(PHRASES, CLIP, PHOTOS.length)),
    JSON.stringify(planWindows(PHRASES, CLIP, PHOTOS.length)),
  );
});

// ── Motion ───────────────────────────────────────────────────────────────────

Deno.test("a tight room never orbits", () => {
  // ai-video/motion.ts argues this at length: an orbit invents the most geometry
  // of any move, and a bathroom has none to spare.
  assert(!moveFor("Primary Bath", null).startsWith("orbit"));
});

Deno.test("two adjacent cutaways never move the same way", () => {
  const first = moveFor("Kitchen", null);
  assert(moveFor("Kitchen", first) !== first);
});

// ── The answer, against hostile replies ──────────────────────────────────────

const good = JSON.stringify({
  windows: WINDOWS.map((w, i) => ({
    window_id: w.window_id,
    photo_id: PHOTOS[i % PHOTOS.length].id,
    on_screen_text: "QUARTZ WATERFALL ISLAND",
  })),
});

Deno.test("a clean answer fills every window", () => {
  const a = parseAgentReel(good, WINDOWS, PHOTOS);
  assert(a);
  assertEquals(a.cutaways.length, WINDOWS.length);
  assert(a.cutaways.every((c) => c.photo_id));
});

Deno.test("cutaways are matched by window_id, never by position", () => {
  // The model answers in reverse. Position matching would put every picture on
  // the wrong sentence; id matching cannot.
  const reversed = JSON.stringify({
    windows: [...WINDOWS].reverse().map((w, i) => ({
      window_id: w.window_id,
      photo_id: PHOTOS[(WINDOWS.length - 1 - i) % PHOTOS.length].id,
      on_screen_text: "",
    })),
  });
  const forward = parseAgentReel(good, WINDOWS, PHOTOS);
  const back = parseAgentReel(reversed, WINDOWS, PHOTOS);
  assert(forward && back);
  assertEquals(
    forward.cutaways.map((c) => [c.window_id, c.photo_id]),
    back.cutaways.map((c) => [c.window_id, c.photo_id]),
  );
});

Deno.test("a photo id we never offered is dropped, not trusted", () => {
  const hostile = JSON.stringify({
    windows: [{ window_id: WINDOWS[0].window_id, photo_id: "p_not_ours", on_screen_text: "HI" }],
  });
  const a = parseAgentReel(hostile, WINDOWS, PHOTOS);
  assertEquals(a, null); // nothing was filled, so there is no edit to sell
});

Deno.test("rule 3 is enforced, not requested: no photo plays twice in a row", () => {
  const repeated = JSON.stringify({
    windows: WINDOWS.map((w) => ({
      window_id: w.window_id,
      photo_id: "p_kitchen",
      on_screen_text: "",
    })),
  });
  const a = parseAgentReel(repeated, WINDOWS, PHOTOS);
  assert(a);
  const used = a.cutaways.map((c) => c.photo_id);
  for (let i = 1; i < used.length; i++) {
    if (used[i]) assert(used[i] !== used[i - 1], `photo repeated at ${i}`);
  }
});

Deno.test("a caption never burns over the agent's own face", () => {
  const captionOnly = JSON.stringify({
    windows: WINDOWS.map((w, i) => ({
      window_id: w.window_id,
      photo_id: i === 0 ? PHOTOS[0].id : "", // the model honestly had no match
      on_screen_text: "SIX NINETY FIVE",
    })),
  });
  const a = parseAgentReel(captionOnly, WINDOWS, PHOTOS);
  assert(a);
  for (const c of a.cutaways) {
    if (!c.photo_id) assertEquals(c.on_screen_text, "", "text over a face-only window");
  }
});

Deno.test("an empty photo_id is a legitimate answer, not a failure", () => {
  const partial = JSON.stringify({
    windows: WINDOWS.map((w, i) => ({
      window_id: w.window_id,
      photo_id: i === 0 ? PHOTOS[0].id : "",
      on_screen_text: "",
    })),
  });
  const a = parseAgentReel(partial, WINDOWS, PHOTOS);
  assert(a, "one honest match is still an edit");
  assertEquals(a.cutaways.filter((c) => c.photo_id).length, 1);
});

Deno.test("an answer with no pictures at all is unusable", () => {
  assertEquals(parseAgentReel('{"windows":[]}', WINDOWS, PHOTOS), null);
  assertEquals(parseAgentReel("not json", WINDOWS, PHOTOS), null);
});

Deno.test("covered_seconds counts only windows that actually got a picture", () => {
  const one = JSON.stringify({
    windows: [{ window_id: WINDOWS[0].window_id, photo_id: PHOTOS[0].id, on_screen_text: "" }],
  });
  const a = parseAgentReel(one, WINDOWS, PHOTOS);
  assert(a);
  assertEquals(a.covered_seconds, Math.round((WINDOWS[0].end - WINDOWS[0].start) * 10) / 10);
});

Deno.test("the compliance surface carries every caption", () => {
  const a = parseAgentReel(good, WINDOWS, PHOTOS);
  assert(a);
  assertStringIncludes(a.surface, "QUARTZ");
});

// ── The prompt ───────────────────────────────────────────────────────────────

const REQ = {
  space: "real_estate" as const,
  tone: "punchy" as const,
  subject: "listing" as const,
  facts: { tagline: "", region: "", details: {} as Record<string, string> },
  photos: PHOTOS,
  windows: WINDOWS,
  clipSeconds: CLIP,
};

Deno.test("the instruction tells the model it is not writing the script", () => {
  assertStringIncludes(agentReelInstruction(REQ), "NOT writing the script");
});

Deno.test("the instruction offers an honest way out of a bad match", () => {
  assertStringIncludes(agentReelInstruction(REQ), "empty photo_id");
});

Deno.test("the subject changes what the reel is about", () => {
  assertStringIncludes(agentReelInstruction({ ...REQ, subject: "agent" }), "THEMSELVES");
  assertStringIncludes(agentReelInstruction(REQ), "ONE PROPERTY");
});

Deno.test("the turn shows the words under each window", () => {
  const turn = buildAgentReelTurn(REQ);
  assertStringIncludes(turn, "they are saying:");
  assertStringIncludes(turn, WINDOWS[0].window_id);
});

Deno.test("the turn never leaks the whole transcript — only the covered words", () => {
  const turn = buildAgentReelTurn(REQ);
  // The opening line is inside the face lead, so no window covers it.
  assert(!turn.includes("Hey, I'm Aaron"));
});

Deno.test("subjectOf defaults to the listing", () => {
  assertEquals(subjectOf("agent"), "agent");
  assertEquals(subjectOf("nonsense"), "listing");
  assertEquals(subjectOf(undefined), "listing");
});
