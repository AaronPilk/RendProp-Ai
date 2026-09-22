import { canonical, check } from "./common.ts";
import { compileStyle, validateEDL } from "./compile.ts";
import { catalogRefs } from "./policy.ts";
import {
  agentFixture,
  equal,
  photoFixture,
  rejects,
  throws,
} from "./test_helpers.ts";
import {
  REEL_MOTIONS,
  ROOMS,
} from "../../services/supabase/functions/ai-video/motion.ts";

Deno.test("compiler preserves actual upstream agent EDL exactly for all policies", async () => {
  const edl = agentFixture(), before = canonical(edl);
  for (const ref of [null, ...await catalogRefs()]) {
    const result = await compileStyle(ref, edl);
    equal(result.edl, edl);
    equal(result.source_edl_sha256, result.output_edl_sha256);
    check(
      Object.isFrozen(result.edl) && Object.isFrozen(result.edl.cutaways),
      "EDL not frozen",
    );
    equal(result.room_safety, "unverified");
    equal(result.publication_ready, false);
    equal(result.live_api_applied, false);
    equal(result.rendered, false);
    equal(result.applied_effects, []);
    equal(result.unapplied_effects, [
      "timing",
      "motion",
      "music",
      "grade",
      "transition",
      "caption-treatment",
    ]);
  }
  equal(canonical(edl), before);
});
Deno.test("photo motion vocabulary is not falsely promoted to room safety", async () => {
  const edl = photoFixture(); // Bathroom orbit deliberately remains unapproved/unapplied.
  const result = await compileStyle((await catalogRefs())[0], edl);
  equal(result.edl, edl);
  equal(result.room_safety, "unverified");
  equal(result.publication_ready, false);
});
Deno.test("empty-photo windows preserve face and clear caption", () => {
  const e = agentFixture();
  e.cutaways[0].photo_id = "";
  e.cutaways[0].room = "";
  e.cutaways[0].on_screen_text = "";
  equal(validateEDL(e), e);
});
Deno.test("zero-cutaway honest no-op EDL is valid but never publication-ready", async () => {
  const e = agentFixture();
  e.cutaways = [];
  equal((await compileStyle(null, e)).publication_ready, false);
});
const corruptions: Record<
  string,
  (e: ReturnType<typeof agentFixture>) => void
> = {
  "clip below minimum": (e) => e.clip_seconds = 5.9,
  "clip above maximum": (e) => e.clip_seconds = 180.1,
  "nonfinite clip": (e) => e.clip_seconds = NaN,
  "invalid audio hash": (e) => e.original_audio_sha256 = "not-a-hash",
  "boundary duplicates": (e) => e.phrase_boundaries[1] = e.phrase_boundaries[0],
  "rounded boundary collision": (e) => e.phrase_boundaries[1] = 0.01,
  "unknown photo": (e) => e.cutaways[0].photo_id = "missing",
  "room mismatch": (e) => e.cutaways[0].room = "another room",
  "caption over blank": (e) => {
    e.cutaways[0].photo_id = "";
    e.cutaways[0].room = "";
    e.cutaways[0].on_screen_text = "Wrong overlay";
  },
  "face lead": (e) => e.cutaways[0].start = 1.9,
  "face tail": (e) => e.cutaways[e.cutaways.length - 1].end = 60,
  "window length": (e) => e.cutaways[0].end = e.cutaways[0].start + 3.6,
  "gap": (e) => e.cutaways[1].start = e.cutaways[0].end + 1.1,
  "off-boundary": (e) => e.cutaways[0].start = 3.3,
  "duplicate window": (e) => e.cutaways[1].window_id = e.cutaways[0].window_id,
  "unordered windows": (e) => e.cutaways.reverse(),
  "adjacent photo": (e) => {
    e.cutaways[1].photo_id = e.cutaways[0].photo_id;
    e.cutaways[1].room = e.cutaways[0].room;
  },
  "caption length": (e) => e.cutaways[0].on_screen_text = "x".repeat(29),
  "caption word count": (e) => e.cutaways[0].on_screen_text = "a b c d e f",
  "extra field": (e) => Object.assign(e, { speed: 2 }),
};
for (const [name, change] of Object.entries(corruptions)) {
  Deno.test(`EDL rejects ${name}`, () => {
    const e = agentFixture();
    change(e);
    throws(() => validateEDL(e));
  });
}
Deno.test("compiler revalidates style reference instead of trusting a forged decision", async () =>
  await rejects(() =>
    compileStyle({ kind: "selected", policy: {} }, agentFixture())
  ));
for (const seconds of [1, 13, 2.5, NaN, Infinity]) {
  Deno.test(`photo duration rejects ${String(seconds)}`, () => {
    const e = photoFixture();
    e.shots[0].seconds = seconds;
    throws(() => validateEDL(e));
  });
}
Deno.test("all 408 room-motion-style combinations preserve input and withhold safety", async () => {
  let cases = 0;
  for (const ref of await catalogRefs()) {
    for (const room of ["", ...ROOMS]) {
      for (const motion of REEL_MOTIONS) {
        const e = photoFixture();
        e.shots[0].room = room;
        e.shots[0].motion = motion;
        const output = await compileStyle(ref, e);
        equal(output.edl, e);
        equal(output.room_safety, "unverified");
        equal(output.publication_ready, false);
        cases++;
      }
    }
  }
  equal(cases, 408);
});
Deno.test("B-roll share rejects an otherwise valid five-window timeline", () => {
  const e = agentFixture();
  e.clip_seconds = 29;
  e.cutaways.forEach((w, i) => {
    w.start = Number((2 + i * 4.7).toFixed(1));
    w.end = Number((w.start + 3.5).toFixed(1));
  });
  e.phrase_boundaries = [0, ...e.cutaways.flatMap((w) => [w.start, w.end])];
  throws(() => validateEDL(e));
  e.clip_seconds = 32;
  equal(validateEDL(e), e);
});
Deno.test("oversized windows, phrases and duplicate registry fail", () => {
  const a = agentFixture();
  a.cutaways = Array(13).fill(a.cutaways[0]);
  throws(() => validateEDL(a));
  const b = agentFixture();
  b.phrase_boundaries = Array(201).fill(0);
  throws(() => validateEDL(b));
  const c = agentFixture();
  c.photos.push(c.photos[0]);
  throws(() => validateEDL(c));
});
Deno.test("photo shot count, motion and duplicate identity fail", () => {
  const a = photoFixture();
  a.shots = Array(21).fill(a.shots[0]);
  throws(() => validateEDL(a));
  const b = photoFixture();
  b.shots[0].motion = "whip-pan";
  throws(() => validateEDL(b));
  const c = photoFixture();
  c.shots.push(c.shots[0]);
  throws(() => validateEDL(c));
});
