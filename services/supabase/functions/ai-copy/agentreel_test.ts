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
  agentReelInstruction,
  buildAgentReelTurn,
  cleanTranscript,
  coveredSeconds,
  FACE_LEAD_SECONDS,
  FACE_TAIL_SECONDS,
  MAX_AGENT_REEL_CAPTION_BYTES,
  MAX_AGENT_REEL_RESPONSE_BYTES,
  MAX_AGENT_REEL_TOKENS,
  MAX_BROLL_SECONDS,
  MAX_BROLL_SHARE,
  MAX_WINDOWS,
  MIN_BROLL_SECONDS,
  MIN_FACE_GAP_SECONDS,
  moveFor,
  parseAgentReel,
  type Phrase,
  planWindows,
  subjectOf,
  transcriptText,
} from "./agentreel.ts";

// A realistic sixty-second take: an agent walking a listing and talking.
const CLIP = 60;
const PHRASES: Phrase[] = [
  { t: 0.0, text: "Hey, I'm Aaron and I want to show you something." },
  { t: 3.2, text: "This one just came on the market this morning." },
  {
    t: 6.4,
    text: "The kitchen is the reason you're going to want this house.",
  },
  {
    t: 10.1,
    text:
      "Quartz waterfall island, gas range, and it opens straight onto the deck.",
  },
  {
    t: 14.8,
    text: "Which means you're cooking and still talking to everyone outside.",
  },
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
  {
    id: "p_kitchen",
    room: "Kitchen",
    caption_hint: "waterfall island, gas range",
  },
  { id: "p_deck", room: "Backyard", caption_hint: "covered patio" },
  {
    id: "p_primary",
    room: "Primary Bedroom",
    caption_hint: "vaulted, balcony door",
  },
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
  const out = cleanTranscript(
    [{ t: 1, text: "in" }, { t: 99, text: "out" }],
    30,
  );
  assertEquals(out.length, 1);
});

Deno.test("transcriptText is the agent's own words, joined for the input gate", () => {
  assertStringIncludes(transcriptText(PHRASES), "Quartz waterfall island");
});

// ── The six rules ────────────────────────────────────────────────────────────

Deno.test("rule 1: nothing cuts away before the face lead", () => {
  assert(WINDOWS.length > 0, "the fixture should produce windows");
  for (const w of WINDOWS) {
    assert(w.start >= FACE_LEAD_SECONDS, `${w.window_id} starts at ${w.start}`);
  }
});

Deno.test("rule 2: nothing cuts away inside the face tail", () => {
  for (const w of WINDOWS) {
    assert(
      w.end <= CLIP - FACE_TAIL_SECONDS,
      `${w.window_id} ends at ${w.end}`,
    );
  }
});

Deno.test("rule 3: every boundary is a phrase boundary or the clip's end", () => {
  const starts = new Set(PHRASES.map((p) => p.t));
  const ends = new Set<number>([...PHRASES.map((p) => p.t), CLIP]);
  for (const w of WINDOWS) {
    assert(
      starts.has(w.start),
      `${w.window_id} starts mid-phrase at ${w.start}`,
    );
    assert(ends.has(w.end), `${w.window_id} ends mid-phrase at ${w.end}`);
  }
});

Deno.test("rule 4: the agent is seen between any two cutaways", () => {
  for (let i = 1; i < WINDOWS.length; i++) {
    const gap = WINDOWS[i].start - WINDOWS[i - 1].end;
    assert(
      gap >= MIN_FACE_GAP_SECONDS,
      `only ${gap}s of face between ${i - 1} and ${i}`,
    );
  }
});

Deno.test("rule 5: b-roll never exceeds its share of the clip", () => {
  assert(coveredSeconds(WINDOWS) <= CLIP * MAX_BROLL_SHARE);
});

Deno.test("every window is a real shot length", () => {
  for (const w of WINDOWS) {
    const len = w.end - w.start;
    assert(
      len >= MIN_BROLL_SECONDS && len <= MAX_BROLL_SECONDS,
      `${w.window_id} is ${len}s`,
    );
  }
});

Deno.test("a window carries the words spoken underneath it", () => {
  // This is what lets the model match a picture to a sentence rather than to a
  // position, so it must never be empty.
  for (const w of WINDOWS) {
    assert(w.says.length > 0, `${w.window_id} has no words`);
  }
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

function wire(rows: [string, string, string][]): string {
  return JSON.stringify({ w: rows });
}
function rows(
  choose: (i: number) => [string, string] = (i) => [`p${i + 1}`, ""],
): [string, string, string][] {
  return WINDOWS.map((w, i) => [w.window_id, ...choose(i)]);
}
const good = wire(rows((i) => [`p${i + 1}`, "QUARTZ WATERFALL ISLAND"]));

Deno.test("a clean compact answer fills every window with the exact offered photo ID", () => {
  const a = parseAgentReel(good, WINDOWS, PHOTOS);
  assert(a);
  assertEquals(a.cutaways.length, WINDOWS.length);
  assertEquals(
    a.cutaways.map((c) => c.photo_id),
    PHOTOS.slice(0, WINDOWS.length).map((p) => p.id),
  );
  assertEquals(
    a.cutaways.map((c) => [c.start, c.end]),
    WINDOWS.map((w) => [w.start, w.end]),
  );
});

Deno.test("reversed compact rows still match explicit window IDs, never positions", () => {
  const forward = parseAgentReel(good, WINDOWS, PHOTOS);
  const back = parseAgentReel(
    wire(rows((i) => [`p${i + 1}`, "QUARTZ WATERFALL ISLAND"]).reverse()),
    WINDOWS,
    PHOTOS,
  );
  assert(forward && back);
  assertEquals(back, forward);
});

Deno.test("unknown or noncanonical photo aliases reject the complete answer", () => {
  for (
    const alias of [
      "p_not_ours",
      "p0",
      "p01",
      "p21",
      PHOTOS[0].id,
      " p1",
      "p1 ",
    ]
  ) {
    assertEquals(
      parseAgentReel(
        wire(rows((i) => [i === 0 ? alias : `p${i + 1}`, ""])),
        WINDOWS,
        PHOTOS,
      ),
      null,
      alias,
    );
  }
});

Deno.test("unknown, duplicate and missing windows cannot salvage a partial edit", () => {
  const original = rows();
  for (
    const bad of [
      original.slice(0, -1),
      [...original, original[0]],
      original.map((r, i) =>
        i === 0 ? ["w0", r[1], r[2]] as [string, string, string] : r
      ),
      original.map((r, i) =>
        i === 0 ? ["w01", r[1], r[2]] as [string, string, string] : r
      ),
      original.map((r, i) =>
        i === 0 ? [original[1][0], r[1], r[2]] as [string, string, string] : r
      ),
    ]
  ) assertEquals(parseAgentReel(wire(bad), WINDOWS, PHOTOS), null);
});

Deno.test("exact compact root and tuple schema is required", () => {
  for (
    const bad of [
      { w: rows(), extra: true },
      { windows: rows() },
      rows(),
      null,
      { w: rows().map((r, i) => i === 0 ? [...r, "extra"] : r) },
      { w: rows().map((r, i) => i === 0 ? r.slice(0, 2) : r) },
      { w: rows().map((r, i) => i === 0 ? [r[0], 1, ""] : r) },
      {
        w: rows().map((r, i) =>
          i === 0 ? { window_id: r[0], photo_id: r[1] } : r
        ),
      },
    ]
  ) assertEquals(parseAgentReel(JSON.stringify(bad), WINDOWS, PHOTOS), null);
});

Deno.test("truncated, fenced and balanced-prefix answers are refused without salvage", () => {
  for (
    const bad of [
      good.slice(0, -1),
      "prefix " + good,
      good + " trailing",
      "```json\n" + good + "\n```",
      '{"w":[]}',
      "not json",
    ]
  ) {
    assertEquals(parseAgentReel(bad, WINDOWS, PHOTOS), null);
  }
});

Deno.test("rule 3 remains enforced after UUID reconstruction: no adjacent repeated photo", () => {
  const a = parseAgentReel(wire(rows(() => ["p1", ""])), WINDOWS, PHOTOS);
  assert(a);
  const used = a.cutaways.map((c) => c.photo_id);
  for (let i = 1; i < used.length; i++) {
    if (used[i]) assert(used[i] !== used[i - 1]);
  }
});

Deno.test("a caption never burns over the agent's face-only window", () => {
  const a = parseAgentReel(
    wire(rows((i) => [i === 0 ? "p1" : "", "SIX NINETY FIVE"])),
    WINDOWS,
    PHOTOS,
  );
  assert(a);
  for (const c of a.cutaways) {
    if (!c.photo_id) assertEquals(c.on_screen_text, "");
  }
});

Deno.test("empty photo aliases are honest face-only windows, with one match still usable", () => {
  const a = parseAgentReel(
    wire(rows((i) => [i === 0 ? "p1" : "", ""])),
    WINDOWS,
    PHOTOS,
  );
  assert(a);
  assertEquals(a.cutaways.filter((c) => c.photo_id).length, 1);
  assertEquals(
    a.covered_seconds,
    Math.round((WINDOWS[0].end - WINDOWS[0].start) * 10) / 10,
  );
  assertEquals(
    parseAgentReel(wire(rows(() => ["", ""])), WINDOWS, PHOTOS),
    null,
  );
});

Deno.test("the compliance surface still carries every published caption", () => {
  const a = parseAgentReel(good, WINDOWS, PHOTOS);
  assert(a);
  assertEquals(a.surface.split("QUARTZ").length - 1, WINDOWS.length);
});

const LONG_PHOTOS: ShotPhoto[] = Array.from({ length: 20 }, (_, i) => ({
  id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
  room: i % 2 ? "Kitchen" : "Backyard",
  caption_hint: "",
}));
const TWELVE_WINDOWS = planWindows(
  Array.from({ length: 60 }, (_, i) => ({ t: i * 3, text: `room ${i}` })),
  180,
  LONG_PHOTOS.length,
);
const twelve = (caption = "") =>
  wire(TWELVE_WINDOWS.map((w, i) => [w.window_id, `p${i + 1}`, caption]));
const byteLength = (s: string) => new TextEncoder().encode(s).byteLength;

Deno.test("all12 windows and20 full UUID photos fit with the entire240-byte caption budget", () => {
  assertEquals(TWELVE_WINDOWS.length, 12);
  const raw = twelve("A".repeat(20));
  assertEquals(20 * TWELVE_WINDOWS.length, MAX_AGENT_REEL_CAPTION_BYTES);
  assert(byteLength(raw) <= MAX_AGENT_REEL_RESPONSE_BYTES);
  const answer = parseAgentReel(raw, TWELVE_WINDOWS, LONG_PHOTOS);
  assert(answer);
  assertEquals(answer.cutaways.length, 12);
  assertEquals(
    answer.cutaways.map((c) => c.photo_id),
    LONG_PHOTOS.slice(0, 12).map((p) => p.id),
  );
  assertEquals(
    answer.cutaways.map((c) => c.motion),
    TWELVE_WINDOWS.map((_, i) =>
      moveFor(
        LONG_PHOTOS[i].room,
        i ? moveFor(LONG_PHOTOS[i - 1].room, null) : null,
      )
    ),
  );
});

Deno.test("whole-answer500/501 UTF8-byte boundary includes whitespace before parsing", () => {
  assertEquals(MAX_AGENT_REEL_TOKENS, 500);
  const base = twelve("海景");
  const exact = base + " ".repeat(500 - byteLength(base));
  assertEquals(byteLength(exact), 500);
  assert(parseAgentReel(exact, TWELVE_WINDOWS, LONG_PHOTOS));
  const oversized = exact + " ";
  assert(
    oversized.length < 500,
    "multibyte fixture must defeat a JS length-only check",
  );
  assertEquals(byteLength(oversized), 501);
  assertEquals(parseAgentReel(oversized, TWELVE_WINDOWS, LONG_PHOTOS), null);
});

Deno.test("aggregate caption bytes are measured before cleaning or dropping face-only text", () => {
  for (const caption of [" ".repeat(21), "海".repeat(7)]) {
    const raw = twelve(caption);
    assert(
      byteLength(raw) < 500,
      "whole-body check must not hide the caption guard",
    );
    assertEquals(byteLength(caption) * 12, 252);
    assertEquals(parseAgentReel(raw, TWELVE_WINDOWS, LONG_PHOTOS), null);
  }
  const faceOnly = wire(
    TWELVE_WINDOWS.map((w, i) => [w.window_id, i ? "" : "p1", " ".repeat(21)]),
  );
  assertEquals(parseAgentReel(faceOnly, TWELVE_WINDOWS, LONG_PHOTOS), null);
});

Deno.test("per-caption length and JSON-escaped whole-answer expansion cannot exceed the contract", () => {
  assertEquals(
    parseAgentReel(
      wire(rows((i) => [`p${i + 1}`, i === 0 ? "A".repeat(29) : ""])),
      WINDOWS,
      PHOTOS,
    ),
    null,
  );
  const escaped = twelve('"'.repeat(20));
  assert(byteLength(escaped) > 500);
  assertEquals(parseAgentReel(escaped, TWELVE_WINDOWS, LONG_PHOTOS), null);
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
  assertStringIncludes(agentReelInstruction(REQ), "empty photo alias");
});

Deno.test("the subject changes what the reel is about", () => {
  assertStringIncludes(
    agentReelInstruction({ ...REQ, subject: "agent" }),
    "THEMSELVES",
  );
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

Deno.test("prompt offers aliases only and names both bounded answer budgets", () => {
  const instruction = agentReelInstruction(REQ);
  assertStringIncludes(instruction, "500 UTF-8 bytes");
  assertStringIncludes(instruction, "240 UTF-8 bytes");
  assertStringIncludes(instruction, '["w1","p1","caption"]');
  const turn = buildAgentReelTurn({
    ...REQ,
    photos: LONG_PHOTOS,
    windows: TWELVE_WINDOWS,
  });
  assertStringIncludes(turn, "- p20");
  for (const p of LONG_PHOTOS) assert(!turn.includes(p.id));
});
