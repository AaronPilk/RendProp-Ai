// ai-chapters — post-processing tests.
//
//   deno test services/supabase/functions/ai-chapters/postprocess_test.ts
//
// These cover the rules that decide what an agent actually sees in the tagger:
// the fair-housing drop, the 3-second merge, the clamp, the cap and the sort.
// Everything here is pure — no env, no network, no Supabase.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  MIN_CHAPTER_SECONDS,
  isSafeRoomLabel,
  passesFairHousing,
  postprocessChapters,
  snapLabel,
  toSeconds,
} from "./postprocess.ts";

const REAL_ESTATE = [
  "Exterior", "Entry", "Living Room", "Kitchen", "Dining", "Primary",
  "Bedroom", "Bath", "Office", "Garage", "Backyard", "Other",
];

function run(chapters: unknown, videoSeconds = 90, maxChapters = 12) {
  return postprocessChapters(chapters, {
    videoSeconds,
    maxChapters,
    allowedLabels: REAL_ESTATE,
  });
}

// ── Fair housing ─────────────────────────────────────────────────────────────

Deno.test("fair housing: an occupant-framing description is dropped, the chapter is kept", () => {
  const { chapters, warnings } = run([
    { label: "Living Room", start_s: 0, end_s: 30, description: "Bright open room with oak floors." },
    { label: "Bedroom", start_s: 30, end_s: 60, description: "A great room for a growing family." },
    { label: "Kitchen", start_s: 60, end_s: 90, description: "Quartz counters and a gas range." },
  ]);

  assertEquals(chapters.length, 3, "every room survives — only the sentence is dropped");
  assertEquals(chapters[1].label, "Bedroom");
  assertEquals(chapters[1].description, null, "the familial-status sentence must not reach the app");
  assertEquals(chapters[0].description, "Bright open room with oak floors.");
  assertEquals(chapters[2].description, "Quartz counters and a gas range.");
  assert(warnings.some((w) => w.includes("fair-housing")), "the drop is disclosed to the app");
});

Deno.test("fair housing: neighborhood, schools and religious objects are all refused", () => {
  const bad = [
    "Steps from the best schools in the neighborhood.",
    "A crucifix hangs over the bed.",
    "Perfect for a young couple starting out.",
    "A safe area with the right crowd.",
  ];
  for (const text of bad) assertEquals(passesFairHousing(text), false, text);

  const good = [
    "South-facing windows and a vaulted ceiling.",
    "Tiled entry with a coat closet and a view down the hall.",
    "Stainless appliances, quartz counters, and a walk-in pantry.",
  ];
  for (const text of good) assertEquals(passesFairHousing(text), true, text);
});

Deno.test("fair housing: a room LABEL that names the occupant becomes Other", () => {
  // The shared denylist never had to catch these — nobody types "Prayer room"
  // as a photo prompt. A room LABELLER can, so ai-chapters adds its own tier.
  for (
    const label of [
      "Prayer room",
      "Meditation and prayer room",
      "Home chapel",
      "Shrine room",
      "Kids' room",
      "Children's bedroom",
      "Nursery",
      "Playroom",
      "Nanny's room",
      "Grandma's suite",
      "Maid's quarters",
      "Kids' playroom for a growing family",
    ]
  ) {
    assertEquals(snapLabel(label, REAL_ESTATE).label, "Other", label);
    assertEquals(isSafeRoomLabel(label), false, label);
  }
});

Deno.test("fair housing: real room names — including accessibility — are NOT refused", () => {
  // HUD wants accessible features disclosed, not hidden. Refusing them would be
  // the opposite of the rule this gate exists to serve.
  for (
    const label of [
      "Loft", "Basement", "Mudroom", "Sunroom", "Pantry", "Laundry",
      "Accessible bathroom", "Wheelchair ramp", "Roll-in shower",
      "Wine cellar", "Bonus room", "Media room", "Craft room",
    ]
  ) {
    assertEquals(isSafeRoomLabel(label), true, label);
  }
  // …and a plain off-vocabulary room name survives, flagged for review.
  const loft = snapLabel("Loft", REAL_ESTATE);
  assertEquals(loft.label, "Loft");
  assertEquals(loft.offVocabulary, true);
});

// ── Merge (< 3 s) ────────────────────────────────────────────────────────────

Deno.test("merge: a sub-3s chapter is absorbed by the PREVIOUS room", () => {
  const { chapters } = run([
    { label: "Entry", start_s: 0, end_s: 10 },
    { label: "Bath", start_s: 10, end_s: 11.5 },   // 1.5 s — a doorway glance
    { label: "Kitchen", start_s: 11.5, end_s: 40 },
  ]);
  assertEquals(chapters.map((c) => c.label), ["Entry", "Kitchen"]);
  assertEquals(chapters[0].start_s, 0);
  assertEquals(chapters[0].end_s, 11.5, "the previous room simply runs longer");
  assertEquals(chapters[1].start_s, 11.5);
});

Deno.test("merge: a sub-3s FIRST chapter is absorbed by the next, which starts earlier", () => {
  const { chapters } = run([
    { label: "Exterior", start_s: 0, end_s: 2 },   // 2 s — no previous to absorb it
    { label: "Entry", start_s: 2, end_s: 20 },
    { label: "Living Room", start_s: 20, end_s: 60 },
  ]);
  assertEquals(chapters.map((c) => c.label), ["Entry", "Living Room"]);
  assertEquals(chapters[0].start_s, 0, "the entry point is inherited, never lost");
});

Deno.test("merge: cascading shorts collapse in one call", () => {
  const { chapters } = run([
    { label: "Entry", start_s: 0, end_s: 12 },
    { label: "Bath", start_s: 12, end_s: 13 },
    { label: "Office", start_s: 13, end_s: 14 },
    { label: "Garage", start_s: 14, end_s: 15 },
    { label: "Kitchen", start_s: 15, end_s: 50 },
  ]);
  assertEquals(chapters.map((c) => c.label), ["Entry", "Kitchen"]);
  assertEquals(chapters[0].end_s, 15);
});

Deno.test("merge: adjacent same-label chapters become one", () => {
  const { chapters } = run([
    { label: "Kitchen", start_s: 0, end_s: 20 },
    { label: "kitchen", start_s: 20, end_s: 45 },   // same room, different casing
    { label: "Dining", start_s: 45, end_s: 80 },
  ]);
  assertEquals(chapters.map((c) => c.label), ["Kitchen", "Dining"]);
  assertEquals(chapters[0].end_s, 45);
});

Deno.test("merge: exactly MIN_CHAPTER_SECONDS is kept, a hair under is not", () => {
  const keep = run([
    { label: "Entry", start_s: 0, end_s: 20 },
    { label: "Bath", start_s: 20, end_s: 20 + MIN_CHAPTER_SECONDS },
    { label: "Kitchen", start_s: 20 + MIN_CHAPTER_SECONDS, end_s: 60 },
  ]);
  assertEquals(keep.chapters.length, 3);

  const drop = run([
    { label: "Entry", start_s: 0, end_s: 20 },
    { label: "Bath", start_s: 20, end_s: 20 + MIN_CHAPTER_SECONDS - 0.1 },
    { label: "Kitchen", start_s: 20 + MIN_CHAPTER_SECONDS - 0.1, end_s: 60 },
  ]);
  assertEquals(drop.chapters.length, 2);
});

// ── Clamp ────────────────────────────────────────────────────────────────────

Deno.test("clamp: ends are pulled back to the video duration", () => {
  const { chapters } = run([
    { label: "Entry", start_s: 0, end_s: 40 },
    { label: "Kitchen", start_s: 40, end_s: 500 },   // past the end of a 90 s clip
  ], 90);
  assertEquals(chapters[1].end_s, 90);
});

Deno.test("clamp: a negative start becomes 0", () => {
  const { chapters } = run([
    { label: "Entry", start_s: -8, end_s: 30 },
    { label: "Kitchen", start_s: 30, end_s: 90 },
  ], 90);
  assertEquals(chapters[0].start_s, 0);
});

Deno.test("clamp: a start beyond the video is dropped, not squashed onto the last frame", () => {
  const { chapters, warnings } = run([
    { label: "Entry", start_s: 0, end_s: 45 },
    { label: "Kitchen", start_s: 45, end_s: 90 },
    { label: "Backyard", start_s: 220, end_s: 260 },   // hallucinated
  ], 90);
  assertEquals(chapters.map((c) => c.label), ["Entry", "Kitchen"]);
  assert(warnings.some((w) => w.includes("no usable timestamp")));
});

Deno.test("clamp: a missing end_s is closed against the next chapter, and the last against the video", () => {
  const { chapters } = run([
    { label: "Entry", start_s: 0 },
    { label: "Kitchen", start_s: 30 },
    { label: "Backyard", start_s: 65 },
  ], 90);
  assertEquals(chapters.map((c) => [c.start_s, c.end_s]), [[0, 30], [30, 65], [65, 90]]);
});

Deno.test("clamp: a zero-length video yields nothing rather than a divide-by-nothing", () => {
  const { chapters, warnings } = run([{ label: "Entry", start_s: 0, end_s: 10 }], 0);
  assertEquals(chapters, []);
  assertEquals(warnings.length, 1);
});

// ── Cap ──────────────────────────────────────────────────────────────────────

Deno.test("cap: the longest rooms survive and the result stays in time order", () => {
  const raw = [
    { label: "Entry", start_s: 0, end_s: 5 },
    { label: "Living Room", start_s: 5, end_s: 30 },   // 25 s
    { label: "Kitchen", start_s: 30, end_s: 55 },      // 25 s
    { label: "Bath", start_s: 55, end_s: 60 },         // 5 s
    { label: "Bedroom", start_s: 60, end_s: 66 },      // 6 s
    { label: "Backyard", start_s: 66, end_s: 90 },     // 24 s
  ];
  const { chapters, warnings } = run(raw, 90, 3);
  assertEquals(chapters.length, 3);
  assertEquals(chapters.map((c) => c.label), ["Living Room", "Kitchen", "Backyard"]);
  const starts = chapters.map((c) => c.start_s);
  assertEquals([...starts].sort((a, b) => a - b), starts, "still sorted by start_s");
  assert(warnings.some((w) => w.includes("trimmed")));
});

Deno.test("cap: max_chapters is bounded to 1…24 whatever the caller asks", () => {
  const many = Array.from({ length: 30 }, (_, i) => ({
    label: `Room ${i}`,
    start_s: i * 10,
    end_s: i * 10 + 10,
  }));
  assertEquals(postprocessChapters(many, { videoSeconds: 300, maxChapters: 999, allowedLabels: REAL_ESTATE }).chapters.length, 24);
  assertEquals(postprocessChapters(many, { videoSeconds: 300, maxChapters: 0, allowedLabels: REAL_ESTATE }).chapters.length, 12);
  assertEquals(postprocessChapters(many, { videoSeconds: 300, maxChapters: -4, allowedLabels: REAL_ESTATE }).chapters.length, 12);
});

// ── Sort ─────────────────────────────────────────────────────────────────────

Deno.test("sort: out-of-order suggestions come back in time order", () => {
  const { chapters } = run([
    { label: "Backyard", start_s: 60, end_s: 90 },
    { label: "Entry", start_s: 0, end_s: 20 },
    { label: "Kitchen", start_s: 20, end_s: 60 },
  ]);
  assertEquals(chapters.map((c) => c.label), ["Entry", "Kitchen", "Backyard"]);
});

// ── Parsing ──────────────────────────────────────────────────────────────────

Deno.test("parse: MM:SS, numeric strings and '12s' are all accepted", () => {
  assertEquals(toSeconds(12), 12);
  assertEquals(toSeconds("12"), 12);
  assertEquals(toSeconds("12s"), 12);
  assertEquals(toSeconds("01:15"), 75);
  assertEquals(toSeconds("1:02:03"), 3723);
  assertEquals(toSeconds("later"), null);
  assertEquals(toSeconds(null), null);
  assertEquals(toSeconds(Number.NaN), null);
});

Deno.test("parse: junk in, empty out — never a throw", () => {
  assertEquals(run(null).chapters, []);
  assertEquals(run("not an array").chapters, []);
  assertEquals(run([null, 7, "x", {}]).chapters, []);
});

Deno.test("parse: confidence is clamped to 0…1 and survives as null when absent", () => {
  const { chapters } = run([
    { label: "Entry", start_s: 0, end_s: 40, confidence: 1.7 },
    { label: "Kitchen", start_s: 40, end_s: 90 },
  ]);
  assertEquals(chapters[0].confidence, 1);
  assertEquals(chapters[1].confidence, null);
});

// ── Vocabulary ───────────────────────────────────────────────────────────────

Deno.test("labels: synonyms snap onto the app's own quick tags", () => {
  assertEquals(snapLabel("master bedroom", REAL_ESTATE).label, "Primary");
  assertEquals(snapLabel("Family Room", REAL_ESTATE).label, "Living Room");
  assertEquals(snapLabel("powder room", REAL_ESTATE).label, "Bath");
  assertEquals(snapLabel("Back yard", REAL_ESTATE).label, "Backyard");
  assertEquals(snapLabel("living room", REAL_ESTATE).label, "Living Room", "canonical spelling wins");
});

Deno.test("labels: a synonym whose target is not in THIS space type's list is not forced", () => {
  const gym = ["Entrance", "Reception", "Main Floor", "Weights", "Studio", "Cardio", "Locker Room", "Showers", "Other"];
  // "master bedroom" maps to Primary, which a gym does not have → kept as free
  // text (it clears the gate) rather than snapped to a label that isn't offered.
  assertEquals(snapLabel("master bedroom", gym).label, "master bedroom");
  assertEquals(snapLabel("changing room", gym).label, "Locker Room");
});

Deno.test("labels: an empty or absurdly long label becomes Other", () => {
  assertEquals(snapLabel("", REAL_ESTATE).label, "Other");
  assertEquals(snapLabel("   ", REAL_ESTATE).label, "Other");
  assertEquals(snapLabel("x".repeat(200), REAL_ESTATE).label, "Other");
  assertEquals(snapLabel(undefined, REAL_ESTATE).label, "Other");
});

// ── End to end ───────────────────────────────────────────────────────────────

Deno.test("end to end: a realistic messy model response becomes a clean tagger pre-fill", () => {
  const { chapters, warnings } = run([
    { label: "Front yard", start_s: "00:00", end_s: "00:06", confidence: 0.8, description: "Brick facade with a covered porch." },
    { label: "Foyer", start_s: 6, end_s: 7.4, confidence: 0.5 },
    { label: "living room", start_s: 7.4, end_s: 26, confidence: 0.93, description: "Perfect for a growing family." },
    { label: "Living Room", start_s: 26, end_s: 31, confidence: 0.7 },
    { label: "kitchen", start_s: 31, end_s: 58, confidence: 0.95, description: "Quartz counters, gas range, walk-in pantry." },
    { label: "master bedroom", start_s: 58, end_s: 74, confidence: 0.88 },
    { label: "Back yard", start_s: 74, end_s: 400, confidence: 0.6 },
  ], 90, 12);

  assertEquals(chapters.map((c) => c.label), ["Exterior", "Living Room", "Kitchen", "Primary", "Backyard"]);
  assertEquals(chapters[0].start_s, 0);
  assertEquals(chapters[chapters.length - 1].end_s, 90, "clamped to the video");
  assertEquals(chapters[1].description, null, "the familial-status sentence was dropped");
  assertEquals(chapters[2].description, "Quartz counters, gas range, walk-in pantry.");
  assert(warnings.length >= 2, "merges and the fair-housing drop are both reported");

  // Monotonic and inside the clip — the two properties the tagger relies on.
  for (let i = 0; i < chapters.length; i++) {
    assert(chapters[i].start_s >= 0 && chapters[i].end_s <= 90);
    assert(chapters[i].end_s >= chapters[i].start_s);
    if (i > 0) assert(chapters[i].start_s >= chapters[i - 1].start_s);
  }
});
