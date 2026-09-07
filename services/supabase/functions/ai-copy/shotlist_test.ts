// ai-copy — shot-list tests.
//
//   deno test services/supabase/functions/ai-copy/shotlist_test.ts
//
// Pure — no env, no network, no Supabase. The route's whole claim is that the
// STRUCTURE of a reel is a decision the server makes and can defend, so these
// tests assert the decisions rather than the prose:
//
//   • THE ORDER IS DETERMINISTIC. The same photos always cut the same reel —
//     which is what makes it safe to plan before spending a token and to re-plan
//     unchanged when a compliance retry re-writes the words.
//   • NO TWO CONSECUTIVE SHOTS SHARE A CAMERA MOVE. Every clip moving
//     identically is the bug this route exists to fix.
//   • EVERY SHOT IS RENDERABLE. Integer seconds, at least 2 (the Seedance
//     duration enum is "2".."12"), summing to exactly the reel that was asked
//     for. A plan the provider would reject is not a plan.
//   • THE WORDS MATCH THE PICTURE. Shots are matched to the model's answer BY
//     photo_id and never by position, so a renumbered answer cannot slide the
//     narration one picture to the left.
//   • THE CAPTIONS ARE GATED TOO. The compliance surface carries the script AND
//     every on-screen caption, so a caption that trips fair housing costs the
//     attempt exactly as a script does.

import {
  assert,
  assertEquals,
  assertNotEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { guardedCopy, MAX_COPY_ATTEMPTS } from "./guard.ts";
import { ADDRESS_PLACEHOLDER, cleanFacts, estimatedSecondsFor, userFreeText } from "./prompt.ts";
import {
  MAX_OVERLAY_CHARS,
  MAX_OVERLAY_WORDS,
  MAX_SHOT_SECONDS,
  MAX_SHOTS,
  MIN_SHOT_SECONDS,
  MOTIONS,
  type PlannedShot,
  SURFACE_SEPARATOR,
  apportion,
  classifyRoom,
  cleanOverlayText,
  captionFrom,
  cleanPhotos,
  cleanShotlistTarget,
  defaultTargetSeconds,
  overlayWordCount,
  parseShotlist,
  photoWords,
  planCharBudget,
  planSeconds,
  planShots,
  shotlistInstruction,
  buildShotlistTurn,
} from "./shotlist.ts";

// A nine-photo reel, tapped in the order a hurried agent actually taps: the
// kitchen first because it is the photo they like, the exterior buried in the
// middle, the pool last only by accident.
const NINE = cleanPhotos([
  { id: "p1", room: "Kitchen" },
  { id: "p2", room: "Great Room" },
  { id: "p3", room: "Front Exterior", caption_hint: "twilight, lights on" },
  { id: "p4", room: "Primary Bath" },
  { id: "p5", room: "Backyard Pool" },
  { id: "p6", room: "Primary Suite" },
  { id: "p7", room: "Home Office" },
  { id: "p8", room: "Guest Bedroom" },
  { id: "p9", room: "Entry Foyer" },
]);

const FACTS = cleanFacts({
  beds: 4,
  baths: 3,
  sqft: 2400,
  price_label: "$1,500,000",
  tagline: "Water on three sides",
  region: "Sausalito, CA",
});

function req(plan: PlannedShot[]) {
  return {
    space: "real_estate" as const,
    tone: "warm" as const,
    facts: FACTS,
    plan,
    charBudget: planCharBudget(plan),
    targetSeconds: planSeconds(plan),
  };
}

/** A model answer that writes one caption and one line per planned shot. */
function answerFor(plan: PlannedShot[], line = (s: PlannedShot) => `Shot ${s.order} is the ${s.room || "space"}.`) {
  return JSON.stringify({
    shots: plan.map((s) => ({
      photo_id: s.photo_id,
      on_screen_text: s.room ? s.room.toUpperCase() : "",
      voice_line: line(s),
    })),
  });
}

// ── The order is a decision ──────────────────────────────────────────────────

Deno.test("planShots: the same photos always cut the same reel", () => {
  const a = planShots(NINE, 45);
  const b = planShots(NINE, 45);
  assertEquals(a, b);
  // …and it is stable across a fresh clean of the same body, not just across two
  // calls with one array.
  assertEquals(planShots(cleanPhotos(NINE.map((p) => ({ ...p }))), 45), a);
});

Deno.test("planShots: the reel OPENS on the exterior and CLOSES on the CTA frame", () => {
  const plan = planShots(NINE, 45);
  assertEquals(plan[0].photo_id, "p3", "the establishing shot opens, not the first tap");
  assertEquals(plan[plan.length - 1].photo_id, "p5", "the pool is the frame the end card sits over");
  // The walk between them is public → private, so the great room takes position
  // two of the interior and the kitchen follows it — they cannot both be second.
  const ids = plan.map((s) => s.photo_id);
  assert(ids.indexOf("p2") < ids.indexOf("p1"), "the great room precedes the kitchen");
  assert(ids.indexOf("p1") < ids.indexOf("p4"), "the kitchen precedes the bathroom");
  assert(ids.indexOf("p6") < ids.indexOf("p8"), "the primary suite precedes a guest bedroom");
});

Deno.test("planShots: with no exterior, the great room opens and the primary closes", () => {
  const plan = planShots(
    cleanPhotos([
      { id: "a", room: "Guest Bath" },
      { id: "b", room: "Kitchen" },
      { id: "c", room: "Great Room" },
      { id: "d", room: "Primary Suite" },
    ]),
    20,
  );
  assertEquals(plan[0].photo_id, "c");
  assertEquals(plan[plan.length - 1].photo_id, "d");
});

Deno.test("planShots: unlabelled photos keep the user's own tap order", () => {
  // With nothing to reason about, the user's sequence wins — the plan must not
  // shuffle a reel it has no opinion about.
  const plan = planShots(cleanPhotos([{ id: "a" }, { id: "b" }, { id: "c" }, { id: "d" }]), 20);
  assertEquals(plan.map((s) => s.photo_id), ["a", "b", "c", "d"]);
});

Deno.test("classifyRoom: a PRIMARY BATH is a bathroom, not the primary suite", () => {
  assertEquals(classifyRoom("Primary Bath"), "bath");
  assertEquals(classifyRoom("Master Bathroom"), "bath");
  assertEquals(classifyRoom("Primary Suite"), "primary");
  assertEquals(classifyRoom("Guest Suite"), "bed");
  assertEquals(classifyRoom("Back Yard"), "exterior_rear");
  assertEquals(classifyRoom("Front Elevation"), "exterior_front");
  assertEquals(classifyRoom("Great Room"), "hero_living");
  assertEquals(classifyRoom("Breakfast Nook"), "kitchen");
  // Unknown and unlabelled are honest about it: we do not know what is in the
  // frame, so it is a detail cut rather than a hero's six seconds.
  assertEquals(classifyRoom("Zamboni Bay"), "detail");
  assertEquals(classifyRoom(""), "detail");
});

// ── The motion belongs to the shot ───────────────────────────────────────────

Deno.test("planShots: no two consecutive shots ever share a camera move", () => {
  const shapes: string[][] = [
    NINE.map((p) => p.room),
    ["Kitchen", "Kitchen", "Kitchen", "Kitchen", "Kitchen", "Kitchen", "Kitchen", "Kitchen", "Kitchen"],
    ["", "", "", "", ""],
    ["Backyard", "Pool", "Patio", "Deck"],
    ["Front Exterior", "Front Exterior"],
    ["Primary Bath", "Guest Bath", "Powder Room"],
  ];
  for (const rooms of shapes) {
    const plan = planShots(cleanPhotos(rooms.map((room, i) => ({ id: `x${i}`, room }))), rooms.length * 5);
    for (let i = 1; i < plan.length; i++) {
      assertNotEquals(
        plan[i].motion,
        plan[i - 1].motion,
        `shots ${i} and ${i + 1} repeat ${plan[i].motion} for [${rooms.join(", ")}]`,
      );
      // …and the stronger property the move actually needs: two arcs in
      // opposite directions are still two arcs, and read as monotonous as two
      // push-ins do.
      assert(
        !familyMates(plan[i - 1].motion).includes(plan[i].motion),
        `shots ${i} and ${i + 1} are both ${familyMates(plan[i].motion).join("/")} for [${rooms.join(", ")}]`,
      );
    }
  }
});

Deno.test("an UNLABELLED reel still varies — the common case is not a slideshow", () => {
  // No room labels at all is what the app sends when nobody tagged anything, so
  // it is the case that has to look good. Two moves alternating satisfies "never
  // repeats" and is still a slideshow with a longer period, so the detail
  // rotation has to reach every family.
  const plan = planShots(cleanPhotos(Array.from({ length: 8 }, (_, i) => ({ id: `u${i}` }))), 40);
  const families = new Set(plan.map((s) => familyMates(s.motion).join("+")));
  assertEquals(families.size, 4, `only ${[...families].join(", ")} — an unlabelled reel ping-pongs`);
  // The hook still opens on a move toward the viewer, not a focus rack.
  assertEquals(plan[0].motion, "push_in");
  assertEquals(plan[plan.length - 1].motion, "pull_back");
  // …and a labelled reel is not disturbed by any of it.
  assertEquals(planShots(NINE, 45)[0].motion, "push_in");
});

Deno.test("planShots: every move is in the closed set ai-video can render", () => {
  for (const s of planShots(NINE, 45)) {
    assert((MOTIONS as readonly string[]).includes(s.motion), `${s.motion} is not a known move`);
  }
});

// ⚠ THE TWO LISTS MUST AGREE — ai-video/motion.ts owns the render contract.
//
// A motion this route returns is handed to POST /ai-video/reel-clip and becomes
// the clause that drives the clip, so a move ai-video does not know is a clip
// that falls back to the fixed push-in: the exact bug this route exists to fix.
// motion.ts is owned by another agent and was written in parallel with this
// file, so the specifier is built at RUNTIME (deno check must not resolve a file
// that may not be on a given branch) and the test skips when it is absent — but
// it is not optional when the file is there, and it names what disagrees.
const MOTION_MODULE = new URL("../ai-video/motion.ts", import.meta.url);
let motionModuleExists = false;
try {
  motionModuleExists = Deno.statSync(MOTION_MODULE).isFile;
} catch {
  motionModuleExists = false;
}

function setOf(v: unknown): Set<string> | null {
  return Array.isArray(v) && v.every((x) => typeof x === "string") ? new Set(v as string[]) : null;
}

Deno.test({
  name: "MOTIONS is exactly ai-video/motion.ts REEL_MOTIONS",
  ignore: !motionModuleExists,
  fn: async () => {
    const mod = await import(MOTION_MODULE.href) as Record<string, unknown>;
    const theirs = setOf(mod.REEL_MOTIONS);
    assert(
      theirs,
      "ai-video/motion.ts no longer exports REEL_MOTIONS as a string array — the reel's move " +
        "vocabulary moved, so ai-copy/shotlist.ts MOTIONS has to follow it.",
    );
    const ours = new Set<string>(MOTIONS);
    const missing = [...theirs].filter((m) => !ours.has(m));
    const extra = [...ours].filter((m) => !theirs.has(m));
    assertEquals(
      { missing, extra },
      { missing: [], extra: [] },
      "ai-video owns the render contract: `missing` are moves it can render that the shot list " +
        "never picks, `extra` are moves this route would return that no clip can be made from.",
    );
  },
});

Deno.test({
  name: "the move FAMILIES agree too — variation means the same thing on both sides",
  ignore: !motionModuleExists,
  fn: async () => {
    const mod = await import(MOTION_MODULE.href) as Record<string, unknown>;
    const theirs = mod.REEL_MOTION_FAMILY as Record<string, string> | undefined;
    assert(theirs && typeof theirs === "object", "ai-video/motion.ts no longer exports REEL_MOTION_FAMILY");
    // Two moves are "the same kind of shot" here iff they are there. Compared as
    // a PARTITION rather than by label, so renaming a family is not a failure.
    const partition = (fam: Record<string, string>) => {
      const groups = new Map<string, string[]>();
      for (const m of MOTIONS) {
        const key = fam[m] ?? "?";
        groups.set(key, [...(groups.get(key) ?? []), m]);
      }
      return [...groups.values()].map((g) => g.sort().join("+")).sort();
    };
    const mine: Record<string, string> = {};
    for (const m of MOTIONS) {
      // Read our own grouping back out of the planner: two moves share a family
      // iff neither may follow the other.
      mine[m] = MOTIONS.filter((o) => familyMates(m).includes(o)).sort().join("+");
    }
    assertEquals(partition(mine), partition(theirs));
  },
});

/** Our family grouping, observed through the planner rather than exported: the
 *  moves that may never sit next to `m` are exactly its family. */
function familyMates(m: string): string[] {
  const NEIGHBOURS: Record<string, string[]> = {
    push_in: ["push_in", "pull_back"],
    pull_back: ["push_in", "pull_back"],
    tilt_up: ["tilt_up", "tilt_down"],
    tilt_down: ["tilt_up", "tilt_down"],
    orbit_left: ["orbit_left", "orbit_right"],
    orbit_right: ["orbit_left", "orbit_right"],
    rack_focus: ["rack_focus", "static_parallax"],
    static_parallax: ["rack_focus", "static_parallax"],
  };
  return NEIGHBOURS[m] ?? [m];
}

// ── Pacing: every shot has to be renderable ──────────────────────────────────

Deno.test("planShots: seconds are INTEGERS >= 2 that sum to the reel's length", () => {
  for (const n of [1, 2, 3, 5, 9, 12, MAX_SHOTS]) {
    const photos = cleanPhotos(Array.from({ length: n }, (_, i) => ({ id: `p${i}`, room: i % 3 === 0 ? "Kitchen" : "" })));
    for (const asked of [undefined, 5, 10, 30, 45, 60, 90, 1000, -4, "nonsense"]) {
      const target = cleanShotlistTarget(asked, n);
      const plan = planShots(photos, target);
      assertEquals(plan.length, n);
      for (const s of plan) {
        assertEquals(s.seconds, Math.round(s.seconds), "a fractional duration cannot be ordered");
        assert(s.seconds >= MIN_SHOT_SECONDS, `${s.seconds}s reads as a glitch`);
        assert(s.seconds <= MAX_SHOT_SECONDS, `${s.seconds}s is past the provider's enum`);
      }
      assertEquals(planSeconds(plan), target, `n=${n} asked=${asked}`);
    }
  }
});

Deno.test("cleanShotlistTarget: clamped to what n whole clips can actually render", () => {
  // 5 s per photo is the reel the app makes today.
  assertEquals(defaultTargetSeconds(9), 45);
  assertEquals(cleanShotlistTarget(undefined, 9), 45);
  assertEquals(cleanShotlistTarget(45, 9), 45);
  // Three photos cannot make a 60-second reel out of 2..12 s clips: 36 is the
  // longest that exists, so the answer is 36 rather than a 400 nobody can act on.
  assertEquals(cleanShotlistTarget(60, 3), 36);
  // …and cannot make a 3-second one either: 6 is the shortest.
  assertEquals(cleanShotlistTarget(3, 3), 6);
  assertEquals(cleanShotlistTarget(0, 1), 5);
  assertEquals(cleanShotlistTarget("nope", 4), 20);
});

Deno.test("planShots: a hero holds longer than a detail — the pace is not uniform", () => {
  const plan = planShots(NINE, 45);
  const byId = new Map(plan.map((s) => [s.photo_id, s]));
  assert(
    byId.get("p2")!.seconds > byId.get("p7")!.seconds,
    "the great room must hold longer than the home office",
  );
  assert(byId.get("p5")!.seconds >= byId.get("p4")!.seconds, "the closing frame is not a quick cut");
  // …and the words are budgeted in the same proportion, so the narration cannot
  // drift away from the picture it belongs to.
  assert(byId.get("p2")!.voiceBudget > byId.get("p7")!.voiceBudget);
});

Deno.test("apportion: exact, bounded and stable", () => {
  assertEquals(apportion(10, [1, 1], 2, 12), [5, 5]);
  assertEquals(apportion(6, [3, 1, 1], 2, 12), [2, 2, 2], "the floor wins over the weights");
  assertEquals(apportion(45, [1.15, 0.8, 1.35], 2, 12), apportion(45, [1.15, 0.8, 1.35], 2, 12));
  // Ties go to the earlier shot, so the answer never depends on sort order.
  assertEquals(apportion(7, [1, 1, 1], 2, 12), [3, 2, 2]);
  assertEquals(apportion(0, [1, 1], 0, 10), [0, 0]);
  assertEquals(apportion(5, [], 2, 12), []);
  // Feasible totals land exactly (5 shots can carry 10..60 seconds).
  for (const total of [10, 24, 25, 37, 60]) {
    const out = apportion(total, [1.15, 1.15, 0.8, 0.8, 1.35], 2, 12);
    assertEquals(out.reduce((a, b) => a + b, 0), total, `total ${total}`);
  }
  // An INFEASIBLE total returns the closest bounded answer rather than looping.
  // Nothing reaches it — cleanShotlistTarget() is what makes the total feasible
  // — but a clamp is the right failure for arithmetic that cannot be satisfied.
  assertEquals(apportion(90, [1, 1, 1, 1, 1], 2, 12), [12, 12, 12, 12, 12]);
  assertEquals(apportion(1, [1, 1, 1], 2, 12), [2, 2, 2]);
});

// ── On-screen text: the realtor-reel idiom ───────────────────────────────────

Deno.test("cleanOverlayText: the idiom survives, a sentence does not", () => {
  assertEquals(cleanOverlayText("5 bed · 3.5 bath"), "5 BED · 3.5 BATH");
  assertEquals(cleanOverlayText("**Chef's Kitchen**"), "CHEF'S KITCHEN");
  assertEquals(cleanOverlayText("$1.5M"), "$1.5M");
  assertEquals(cleanOverlayText("2,400 sq ft"), "2,400 SQ FT");
  // A caption is never a sentence: no terminal punctuation, no emoji, no
  // markdown, and nothing to render as a stray glyph over somebody's kitchen.
  assertEquals(cleanOverlayText("Sunlit and open."), "SUNLIT AND OPEN");
  assertEquals(cleanOverlayText("🔥 POOL 🔥"), "POOL");
  assertEquals(cleanOverlayText("   "), "");
  assertEquals(cleanOverlayText(undefined), "");
  assertEquals(cleanOverlayText(42), "42");
});

Deno.test("cleanOverlayText: always inside the word AND character budget", () => {
  const inputs = [
    "a very long caption about the beautiful sunlit primary bedroom suite upstairs",
    "ONE TWO THREE FOUR FIVE SIX SEVEN",
    "5 bed · 3.5 bath · 2,400 sq ft · $1.5M",
    "supercalifragilistic expialidocious extravaganza",
    "· · · ·",
  ];
  for (const raw of inputs) {
    const out = cleanOverlayText(raw);
    assert(overlayWordCount(out) <= MAX_OVERLAY_WORDS, `"${out}" is over the word budget`);
    assert(out.length <= MAX_OVERLAY_CHARS, `"${out}" is over the character budget`);
    assertEquals(out, out.toUpperCase(), "captions are upper case");
    assert(!/[.!?]$/.test(out), `"${out}" ends like a sentence`);
    assert(out === out.trim());
  }
  // The separators are punctuation, not words: the canonical caption is FOUR
  // words and fits comfortably.
  assertEquals(overlayWordCount("5 BED · 3.5 BATH"), 4);
  assertEquals(overlayWordCount(""), 0);
});

// ── Reading the model's answer ───────────────────────────────────────────────

Deno.test("parseShotlist: lines are matched BY photo_id, never by position", () => {
  const plan = planShots(NINE, 45);
  // The model answers in a DIFFERENT order from the plan. Position matching
  // would slide every line onto the wrong picture; id matching cannot.
  const shuffled = [...plan].reverse();
  const out = parseShotlist(
    JSON.stringify({
      shots: shuffled.map((s) => ({
        photo_id: s.photo_id,
        on_screen_text: "",
        voice_line: `This is ${s.photo_id}.`,
      })),
    }),
    plan,
  )!;
  assertEquals(out.shots.map((s) => s.order), plan.map((s) => s.order));
  for (const s of out.shots) assertEquals(s.voice_line, `This is ${s.photo_id}.`);
});

Deno.test("parseShotlist: an id we never sent is dropped; a shot never mentioned plays silent", () => {
  const plan = planShots(NINE, 45);
  const out = parseShotlist(
    JSON.stringify({
      shots: [
        { photo_id: plan[0].photo_id, on_screen_text: "TWILIGHT EXTERIOR", voice_line: "Water on three sides." },
        { photo_id: "not-a-photo-we-sent", on_screen_text: "GHOST", voice_line: "Invented." },
      ],
    }),
    plan,
  )!;
  assertEquals(out.shots.length, plan.length, "the reel keeps every planned picture");
  assertEquals(out.shots[0].voice_line, "Water on three sides.");
  assertEquals(out.shots[1].voice_line, "", "an unmentioned shot is silent, never given someone else's line");
  assert(!out.surface.includes("Invented."), "an invented photo_id contributes nothing");
  assert(!out.surface.includes("GHOST"));
});

Deno.test("parseShotlist: the {address} placeholder survives into the voice line", () => {
  const plan = planShots(cleanPhotos([{ id: "solo", room: "Great Room" }]), 5);
  const out = parseShotlist(
    JSON.stringify({ shots: [{ photo_id: "solo", on_screen_text: "", voice_line: "This is {{address}}." }] }),
    plan,
  )!;
  assertStringIncludes(out.shots[0].voice_line, ADDRESS_PLACEHOLDER);
  assertStringIncludes(out.script, ADDRESS_PLACEHOLDER);
  assertStringIncludes(out.surface, ADDRESS_PLACEHOLDER);

  // …and an INVENTED street address never does: the request contains nothing to
  // copy one from, so any address in the answer was made up.
  const invented = parseShotlist(
    JSON.stringify({ shots: [{ photo_id: "solo", on_screen_text: "", voice_line: "Set on 12 Bakery Lane." }] }),
    plan,
  )!;
  assertStringIncludes(invented.shots[0].voice_line, ADDRESS_PLACEHOLDER);
  assert(!invented.shots[0].voice_line.includes("Bakery"));
});

Deno.test("a caption never carries an address — it is DROPPED, not mangled", () => {
  const plan = planShots(cleanPhotos([{ id: "solo", room: "Front Exterior" }]), 5);
  const caption = (text: string) =>
    parseShotlist(
      JSON.stringify({ shots: [{ photo_id: "solo", on_screen_text: text, voice_line: "Book a showing." }] }),
      plan,
    )!.shots[0].on_screen_text;

  // An invented street address on screen is legible and held for the whole shot.
  assertEquals(caption("1247 HILLCREST DRIVE"), "");
  // …and so is a placeholder the caption pipeline would flatten to "ADDRESS",
  // because braces are not in the caption character set.
  assertEquals(caption("{address}"), "");
  assertEquals(caption("WELCOME TO {{ADDRESS}}"), "");
  assertEquals(captionFrom("[address]"), "");
  // An ordinary number is not an address and survives untouched.
  assertEquals(caption("2,400 SQ FT"), "2,400 SQ FT");
  assertEquals(caption("5 BED · 3.5 BATH"), "5 BED · 3.5 BATH");
  // The instruction states the rule, so the model is not left to discover it by
  // having its caption silently dropped.
  assertStringIncludes(
    shotlistInstruction(req(plan)),
    `A caption NEVER names the address and never contains ${ADDRESS_PLACEHOLDER}`,
  );
});

Deno.test("parseShotlist: unusable answers are null, never half a reel", () => {
  const plan = planShots(NINE, 45);
  assertEquals(parseShotlist("", plan), null);
  assertEquals(parseShotlist("just prose, no JSON at all", plan), null);
  assertEquals(parseShotlist('{"script":"wrong shape"}', plan), null);
  assertEquals(parseShotlist('{"shots":[]}', plan), null);
  // Captions but no narration is not this route's deliverable.
  assertEquals(
    parseShotlist(JSON.stringify({ shots: plan.map((s) => ({ photo_id: s.photo_id, on_screen_text: "POOL", voice_line: "" })) }), plan),
    null,
  );
  assertEquals(parseShotlist(answerFor(plan), []), null);
});

Deno.test("parseShotlist: the compliance surface carries the script AND every caption", () => {
  const plan = planShots(NINE, 45);
  const out = parseShotlist(answerFor(plan), plan)!;
  for (const shot of out.shots) {
    if (shot.voice_line) assertStringIncludes(out.surface, shot.voice_line);
    if (shot.on_screen_text) assertStringIncludes(out.surface, shot.on_screen_text);
  }
  assertStringIncludes(out.surface, SURFACE_SEPARATOR);
  // The separator is not whitespace, so a rule joining its words with \s+ cannot
  // build a phrase across the seam that exists in neither half.
  assert(!/\s/.test(SURFACE_SEPARATOR.trim()));
  assert(SURFACE_SEPARATOR.trim().length > 0);
});

Deno.test("parseShotlist: the joined script always fits the reel's own budget", () => {
  for (const n of [1, 2, 5, 9, MAX_SHOTS]) {
    const photos = cleanPhotos(Array.from({ length: n }, (_, i) => ({ id: `p${i}`, room: "Kitchen" })));
    const plan = planShots(photos, cleanShotlistTarget(undefined, n));
    // Every line arrives far too long; each is trimmed to its own shot's budget.
    const fat = JSON.stringify({
      shots: plan.map((s) => ({
        photo_id: s.photo_id,
        on_screen_text: "CHEF'S KITCHEN",
        voice_line: "Quartz counters and a six-burner range under a wall of glass. ".repeat(12),
      })),
    });
    const out = parseShotlist(fat, plan)!;
    assert(
      out.script.length <= planCharBudget(plan),
      `n=${n}: ${out.script.length} characters over a ${planCharBudget(plan)} budget freezes the last frame`,
    );
    for (let i = 0; i < plan.length; i++) {
      assert(out.shots[i].voice_line.length <= plan[i].voiceBudget, `shot ${i + 1} overruns its own hold`);
    }
    assert(estimatedSecondsFor(out.script.length) <= planSeconds(plan) + 1);
  }
});

// ── The instruction ──────────────────────────────────────────────────────────

Deno.test("shotlistInstruction: the shot list is FIXED and the words follow the picture", () => {
  const plan = planShots(NINE, 45);
  const s = shotlistInstruction(req(plan));
  assertStringIncludes(s, "ALREADY CUT");
  assertStringIncludes(s, "Do not ");
  assertStringIncludes(s, "MUST MATCH THE PICTURE");
  assertStringIncludes(s, "HOOK FIRST");
  assertStringIncludes(s, '"Welcome to"');
  assertStringIncludes(s, "Book a showing"); // the tour's own CTA, on the last shot
  assertStringIncludes(s, `Shot ${plan.length} is the last shot`);
  assertStringIncludes(s, "FREEZES");
  assertStringIncludes(s, ADDRESS_PLACEHOLDER);
  assertStringIncludes(s, "AT MOST ONCE");
  assertStringIncludes(s, `AT MOST ${MAX_OVERLAY_WORDS} WORDS, UPPER CASE`);
  assertStringIncludes(s, "5 BED · 3.5 BATH");
  assertStringIncludes(s, '{"shots":[{"photo_id"');
  // The fair-housing rule is stated for BOTH kinds of copy, because both are
  // published and both are checked.
  assertStringIncludes(s, "OR in an on-screen caption");
});

Deno.test("shotlistInstruction: each industry gets its own words", () => {
  const plan = planShots(cleanPhotos([{ id: "a", room: "Main Hall" }, { id: "b", room: "Terrace" }]), 10);
  const venue = shotlistInstruction({ ...req(plan), space: "venue" });
  assertStringIncludes(venue, "planners");
  assertStringIncludes(venue, "Plan your event");
  assert(!venue.includes("buyers"), "a venue never has buyers");
});

Deno.test("buildShotlistTurn: every shot arrives with its move, its hold and its budget", () => {
  const plan = planShots(NINE, 45);
  const turn = buildShotlistTurn(req(plan));
  for (const s of plan) {
    assertStringIncludes(turn, `${s.order}. photo_id=${s.photo_id}`);
    assertStringIncludes(turn, `camera: ${s.motion}`);
    assertStringIncludes(turn, `holds ${s.seconds}s`);
    assertStringIncludes(turn, `at most ${s.voiceBudget} characters`);
  }
  // The facts are stated in the same words /ai-copy/script states them in.
  assertStringIncludes(turn, "Beds: 4");
  assertStringIncludes(turn, "Price: $1,500,000");
  assertStringIncludes(turn, "Area (city/state only): Sausalito, CA");
  // The photographer's note reaches the model — it is the only thing anyone
  // knows about what is actually in the frame.
  assertStringIncludes(turn, "twilight, lights on");
  // The photos themselves never do.
  assert(!turn.includes("base64") && !turn.includes("http"));
});

// ── The photos the client sends ──────────────────────────────────────────────

Deno.test("cleanPhotos: keeps tap order, drops what cannot be matched", () => {
  const out = cleanPhotos([
    { id: " a ", room: "  Kitchen  " },
    { id: "", room: "Nowhere" },
    { id: "a", room: "Duplicate" },
    { id: "b", room: "Great Room", caption_hint: "wide, morning light" },
    "not an object",
  ]);
  assertEquals(out.map((p) => p.id), ["a", "b"]);
  assertEquals(out[0].room, "Kitchen");
  assertEquals(out[1].caption_hint, "wide, morning light");
  assertEquals(cleanPhotos(undefined), []);
  assertEquals(cleanPhotos("nope"), []);
  assertEquals(cleanPhotos(Array.from({ length: 200 }, (_, i) => ({ id: `p${i}` }))).length, MAX_SHOTS);
});

Deno.test("photoWords: the gate reads the labels the user wrote, never the ids", () => {
  const words = photoWords(cleanPhotos([{ id: "uuid-1234", room: "Kitchen", caption_hint: "morning light" }]));
  assertEquals(words, ["Kitchen", "morning light"]);
  const brief = userFreeText(FACTS, words);
  assertStringIncludes(brief, "Kitchen");
  assertStringIncludes(brief, "Water on three sides");
  assert(!brief.includes("uuid-1234"), "an asset id cannot trip a fair-housing rule");
});

// ── The gates, driven exactly as index.ts drives them ────────────────────────

/** The compliance loop as the route wires it: parseShotlist is the `clean`, and
 *  its surface — script plus every caption — is what the output gate reads. */
function runRoute(plan: PlannedShot[], brief: string, answers: string[]) {
  const calls: boolean[] = [];
  const parsed: ReturnType<typeof parseShotlist>[] = [];
  const run = guardedCopy({
    gate: "marketing",
    input: brief,
    inputWhat: "This reel brief",
    outputWhat: "This reel",
    spaceType: null,
    clean: (raw) => {
      const answer = parseShotlist(raw, plan);
      if (!answer) return "";
      parsed.push(answer);
      return answer.surface;
    },
    refusal: "We couldn't write this reel in a way that clears the fair-housing rules.",
    attempt: (isRetry: boolean) => {
      calls.push(isRetry);
      return Promise.resolve(answers[Math.min(calls.length - 1, answers.length - 1)]);
    },
  });
  return { run, calls, parsed };
}

Deno.test("input gate: a brief that trips fair housing spends NOTHING", async () => {
  const plan = planShots(NINE, 45);
  // The offending phrase is in a ROOM LABEL, not in the facts — the labels are
  // the caller's own words too, and they go straight into the prompt.
  const brief = userFreeText(FACTS, photoWords(cleanPhotos([{ id: "p1", room: "Great for families den" }])));
  const { run, calls } = runRoute(plan, brief, [answerFor(plan)]);
  const err = await assertRejects(() => run, HttpError);
  assertEquals(err.status, 400);
  assertEquals(err.code, "unsupported_edit");
  assertEquals(calls.length, 0, "the model was never called, so nothing was billed");
  assertStringIncludes(err.message, "Great for families");
});

Deno.test("output gate: a CAPTION that trips is retried, then refused", async () => {
  const plan = planShots(NINE, 45);
  // A clean script with one poisoned burned-in caption. The caption is
  // model-authored copy that gets published over the video, so it is gated
  // exactly as the narration is — and the user is never blamed for it.
  const poisoned = JSON.stringify({
    shots: plan.map((s, i) => ({
      photo_id: s.photo_id,
      on_screen_text: i === 2 ? "GREAT FOR FAMILIES" : "SUNLIT AND OPEN",
      voice_line: `Shot ${s.order} looks out over the water.`,
    })),
  });
  const clean = answerFor(plan);

  // Retried once, and the retry is used.
  const ok = runRoute(plan, "Water on three sides.", [poisoned, clean]);
  const saved = await ok.run;
  assertEquals(ok.calls, [false, true]);
  assertEquals(saved.attempts, 2);
  assertEquals(saved.retried, true);
  assert(!saved.text.includes("GREAT FOR FAMILIES"));

  // Twice bad is refused — 502, ours, not a 400 blaming the user for words a
  // model wrote, and never a quotation of the offending caption.
  const bad = runRoute(plan, "Water on three sides.", [poisoned, poisoned]);
  const err = await assertRejects(() => bad.run, HttpError);
  assertEquals(err.status, 502);
  assertEquals(err.code, "upstream");
  assert(!err.message.includes("GREAT FOR FAMILIES"));
  assertEquals(bad.calls.length, MAX_COPY_ATTEMPTS);
});

Deno.test("output gate: a poisoned VOICE LINE is refused the same way", async () => {
  const plan = planShots(NINE, 45);
  const poisoned = JSON.stringify({
    shots: plan.map((s) => ({
      photo_id: s.photo_id,
      on_screen_text: "",
      voice_line: s.order === 1 ? "A safe neighborhood, perfect for families." : "Light on three sides.",
    })),
  });
  const bad = runRoute(plan, "Water on three sides.", [poisoned, poisoned]);
  const err = await assertRejects(() => bad.run, HttpError);
  assertEquals(err.status, 502);
  assertEquals(bad.calls.length, MAX_COPY_ATTEMPTS);
});

// ── End to end: one photo, and nine ──────────────────────────────────────────

Deno.test("a ONE-photo reel is a whole reel: one shot, a hook and a CTA", async () => {
  const photos = cleanPhotos([{ id: "only", room: "Great Room" }]);
  const plan = planShots(photos, cleanShotlistTarget(undefined, photos.length));
  assertEquals(plan.length, 1);
  assertEquals(plan[0].order, 1);
  assertEquals(plan[0].seconds, 5);
  assertEquals(planSeconds(plan), 5);

  const answer = JSON.stringify({
    shots: [{ photo_id: "only", on_screen_text: "light-filled great room", voice_line: "Water on three sides. Book a showing." }],
  });
  const { run, parsed } = runRoute(plan, "Water on three sides.", [answer]);
  const written = await run;
  const out = parsed.find((a) => a!.surface === written.text)!;
  assertEquals(out.shots.length, 1);
  assertEquals(out.shots[0].on_screen_text, "LIGHT-FILLED GREAT ROOM");
  assertEquals(out.script, "Water on three sides. Book a showing.");
  assert(out.script.length <= planCharBudget(plan));
});

Deno.test("a NINE-photo reel: nine shots, every contract field, a renderable plan", async () => {
  const plan = planShots(NINE, cleanShotlistTarget(undefined, NINE.length));
  assertEquals(plan.length, 9);
  assertEquals(planSeconds(plan), 45);

  const { run, parsed } = runRoute(plan, userFreeText(FACTS, photoWords(NINE)), [answerFor(plan)]);
  const written = await run;
  const out = parsed.find((a) => a!.surface === written.text)!;

  assertEquals(out.shots.length, 9);
  assertEquals(out.shots.map((s) => s.order), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assertEquals(new Set(out.shots.map((s) => s.photo_id)).size, 9, "every photo the user picked is in the reel");
  for (const s of out.shots) {
    // The response shape, field for field.
    assertEquals(Object.keys(s), [
      "photo_id",
      "order",
      "motion",
      "room",
      "on_screen_text",
      "seconds",
      "voice_line",
    ]);
    assert((MOTIONS as readonly string[]).includes(s.motion));
    assert(s.seconds >= MIN_SHOT_SECONDS && Number.isInteger(s.seconds));
    assert(overlayWordCount(s.on_screen_text) <= MAX_OVERLAY_WORDS);
  }
  assertEquals(out.shots.reduce((a, s) => a + s.seconds, 0), 45);
  assert(out.script.length <= planCharBudget(plan));
  assertEquals(out.script, out.shots.map((s) => s.voice_line).filter((t) => t).join(" "));
});
