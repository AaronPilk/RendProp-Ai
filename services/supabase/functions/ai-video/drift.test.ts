// drift.test.ts — the quality gate that decides whether a generated clip is
// still of the customer's own house.
//
//   deno test --allow-read services/supabase/functions/ai-video/drift.test.ts
//
// (`--allow-read` only for the WIRING and SEED sections at the bottom, which
// grep index.ts and migration 0018 the way dronecost.test.ts and motion_test.ts
// grep index.ts. Nothing here touches the network, the environment or a
// Supabase client: _shared/drift.ts is pure.)
//
// THE BUG THESE EXIST TO KEEP FIXED. 2026-09-07: a generated aerial came back
// with the roof tiles smeared into a warped painterly mess over invented
// geometry. "the photo to reel generator is changing how the house looks and
// that's false advertising — it has AI slop left over." It was not his house,
// and on a real estate listing that is a CA AB 723 / MLS / HUD problem rather
// than an aesthetic one.
//
// The module lives in _shared/ (it is the same judge ai-photo will want) and
// its tests live here, next to the route that is its only caller today.
//
// The five properties that make this safe to ship are all asserted below:
//   1. a broken judge NEVER reads as a pass — malformed, partial, or absent;
//   2. a clean verdict passes and every failure category trips on its own;
//   3. the retry happens EXACTLY once, and the second failure refuses;
//   4. nothing but a real pass is ever `publishable`;
//   5. GET /ai-video/status keeps every field it had — the block is additive.

import {
  assert,
  assertEquals,
  assertNotEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  DRIFT_CATEGORIES,
  DRIFT_FALLBACK_CENTS,
  DRIFT_FRAME_POSITIONS,
  DRIFT_MAX_FRAMES,
  DRIFT_PASS_SCORES,
  DRIFT_TASK,
  type DriftScores,
  type DriftVerdict,
  decideDriftAction,
  driftBlock,
  driftLineageKey,
  driftPasses,
  driftRubric,
  ESCALATE_BELOW_CONFIDENCE,
  failedCategories,
  parseDriftVerdict,
  SAFEST_MOTION,
  sanitizeJudgeSentence,
  unavailableVerdict,
  uncheckedDriftBlock,
} from "../_shared/drift.ts";
import { APP_AI_UNIT_CENTS } from "../_shared/ledger.ts";
import {
  AERIAL_INVENTS_SURFACE,
  AERIAL_MOTIONS,
  type AerialMotion,
  groundedAerialMotion,
  REEL_MOTIONS,
} from "./motion.ts";

// ── Helpers ──────────────────────────────────────────────────────────────────

/** A model reply that clears every bar — the ordinary, good clip. */
function goodReply(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    architecture: 98,
    contents: 95,
    additions: 100,
    artifacts: 90,
    same_room: 99,
    confidence: 0.93,
    verdict: "pass",
    reason: "The house, roofline and furniture are unchanged; only the camera moves.",
    ...over,
  });
}

/** A verdict object built directly, for the decision tests. */
function verdict(
  over: Omit<Partial<DriftVerdict>, "scores"> & { scores?: Partial<DriftScores> } = {},
): DriftVerdict {
  const scores: DriftScores = {
    architecture: 98,
    contents: 95,
    additions: 100,
    artifacts: 90,
    same_room: 99,
    ...(over.scores ?? {}),
  };
  const { scores: _ignored, ...rest } = over;
  return {
    judgement: "pass",
    score: scores.architecture,
    confidence: 0.9,
    reason: "Unchanged.",
    clean: true,
    unavailable: false,
    ...rest,
    scores,
  };
}

// ── 1. The parser never lets a broken judge read as a pass ───────────────────

Deno.test("parser: a clean reply parses into the verdict it says", () => {
  const v = parseDriftVerdict(goodReply());
  assertEquals(v.judgement, "pass");
  assertEquals(v.scores.architecture, 98);
  assertEquals(v.scores.artifacts, 90);
  assertEquals(v.score, 98, "the headline score is the architecture axis — the legal one");
  assertEquals(v.confidence, 0.93);
  assertEquals(v.clean, true);
  assertEquals(v.unavailable, false);
  assert(driftPasses(v));
});

Deno.test("parser: a fenced reply is still read (models love ```json)", () => {
  const v = parseDriftVerdict("```json\n" + goodReply() + "\n```");
  assertEquals(v.judgement, "pass");
  assert(driftPasses(v));
});

Deno.test("parser: prose either side of the object is survived", () => {
  const v = parseDriftVerdict(`Sure! Here is my assessment:\n${goodReply()}\nLet me know if you need more.`);
  assertEquals(v.judgement, "pass");
  assert(driftPasses(v));
});

Deno.test("parser: a MALFORMED reply is 'unknown' and can never pass", () => {
  for (
    const raw of [
      "",
      "   ",
      "I'm sorry, I can't help with that.",
      "{not json at all",
      "{",
      "}{",
      "[1,2,3]",
      '"just a string"',
      "null",
    ]
  ) {
    const v = parseDriftVerdict(raw);
    assertEquals(v.judgement, "unknown", `"${raw.slice(0, 20)}" must not parse to a judgement`);
    assertEquals(v.clean, false);
    assertEquals(driftPasses(v), false);
    // And it must route to HOLD, never to a paid retry — our parser failing is
    // not evidence that the customer's clip is bad.
    const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
    assertEquals(d.action, "hold");
    assertEquals(d.publishable, false);
  }
});

Deno.test("parser: an ARRAY of the right shape is not an object and is refused", () => {
  const v = parseDriftVerdict(`[${goodReply()}]`);
  // The array's inner object is found by the brace scan, which is fine — what
  // must never happen is a pass out of something that was not a verdict object.
  assert(v.judgement === "pass" ? driftPasses(v) : true);
  // The genuinely hostile shape: a top-level array with no object at all.
  const empty = parseDriftVerdict("[1, 2, 3]");
  assertEquals(empty.judgement, "unknown");
  assertEquals(driftPasses(empty), false);
});

Deno.test("parser: string and float scores coerce, exactly as the python gate does", () => {
  // services/pipeline/providers/anthropic_qc.py _Coerce, audit F-G-19: a judge
  // that answers "92" or 95.0 used to kill the whole enhancement pass.
  const v = parseDriftVerdict(
    JSON.stringify({
      architecture: "92",
      contents: 95.4,
      additions: 100,
      artifacts: "88.6",
      same_room: 97,
      confidence: "0.81",
      verdict: "pass",
      reason: "fine",
    }),
  );
  assertEquals(v.clean, true, "coercible values are clean, not degraded");
  assertEquals(v.scores.architecture, 92);
  assertEquals(v.scores.contents, 95);
  assertEquals(v.scores.artifacts, 89);
  assertEquals(v.confidence, 0.81);
  assert(driftPasses(v));
});

Deno.test("parser: out-of-range numbers are clamped, not trusted", () => {
  const v = parseDriftVerdict(
    goodReply({ architecture: 40000, artifacts: -12, confidence: 7 }),
  );
  assertEquals(v.scores.architecture, 100);
  assertEquals(v.scores.artifacts, 0);
  assertEquals(v.confidence, 1);
});

Deno.test("parser: a PASS with an unreadable field is downgraded and held", () => {
  // The dangerous case: everything looks like a pass except one field that did
  // not parse. The python gate turns this into a regen; here it becomes a HOLD,
  // because regenerating costs 24c and the clip may be perfectly good.
  for (
    const broken of [
      { architecture: "n/a" },
      { same_room: null },
      { confidence: "high" },
      { verdict: "looks good to me" },
      { reason: "" },
    ]
  ) {
    const v = parseDriftVerdict(goodReply(broken));
    assertEquals(v.clean, false, `${JSON.stringify(broken)} must mark the verdict unclean`);
    assertEquals(driftPasses(v), false, `${JSON.stringify(broken)} must not pass`);
    const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
    assertEquals(d.publishable, false);
  }
});

Deno.test("parser: an unreadable field on a FAIL leaves the failure standing", () => {
  // Downgrading only ever applies to a pass. A judge that clearly says the
  // building changed is believed, even if its confidence field was garbage.
  const v = parseDriftVerdict(
    goodReply({ verdict: "fail", architecture: 20, confidence: "very sure" }),
  );
  assertEquals(v.judgement, "fail");
  assertEquals(v.clean, false);
  assertEquals(driftPasses(v), false);
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  assertEquals(d.action, "retry", "a real failure still earns its one retry");
});

Deno.test("parser: a boolean is not a score", () => {
  const v = parseDriftVerdict(goodReply({ architecture: true }));
  assertEquals(v.clean, false);
  assertEquals(driftPasses(v), false);
});

Deno.test("parser: the judge's sentence is bounded and stripped", () => {
  const nasty = "line one\nline two [31m" + "x".repeat(400);
  const v = parseDriftVerdict(goodReply({ reason: nasty, verdict: "fail" }));
  assert(v.reason.length <= 200);
  assert(!v.reason.includes("\n"));
  assert(!v.reason.includes(" "));
  assertEquals(sanitizeJudgeSentence("ab\r\nc  d"), "a b c d");
  assertEquals(sanitizeJudgeSentence(null), "");
  assertEquals(sanitizeJudgeSentence("y".repeat(500)).length, 200);
});

// ── 2. A clean verdict passes; each failure category trips on its own ────────

Deno.test("gate: the good clip passes and is the only thing that is publishable", () => {
  const v = parseDriftVerdict(goodReply());
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  assertEquals(d.action, "accept");
  assertEquals(d.status, "pass");
  assertEquals(d.publishable, true);
  assertEquals(failedCategories(v).length, 0);
});

Deno.test("gate: EVERY category can fail the clip on its own", () => {
  for (const category of DRIFT_CATEGORIES) {
    const below = DRIFT_PASS_SCORES[category] - 1;
    const v = parseDriftVerdict(goodReply({ [category]: below }));
    assertEquals(
      driftPasses(v),
      false,
      `${category} at ${below} (bar ${DRIFT_PASS_SCORES[category]}) must fail the clip`,
    );
    assertEquals(failedCategories(v), [category]);
    const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
    assertEquals(d.action, "retry");
    assertEquals(d.publishable, false);
    // Exactly at the bar is a pass — the thresholds are >=, and an off-by-one
    // here would reject a clip and spend 24c retrying it for nothing.
    const atBar = parseDriftVerdict(goodReply({ [category]: DRIFT_PASS_SCORES[category] }));
    assertEquals(driftPasses(atBar), true, `${category} exactly at its bar must pass`);
  }
});

Deno.test("gate: the axes are ANDed, never averaged", () => {
  // The screenshot's clip: perfect on everything except the roof it invented.
  // An average would be 84 and would sail through a single-number threshold.
  const v = parseDriftVerdict(
    goodReply({ architecture: 25, contents: 100, additions: 100, artifacts: 30, same_room: 100 }),
  );
  assertEquals(driftPasses(v), false);
  assertEquals(failedCategories(v), ["architecture", "artifacts"]);
});

Deno.test("gate: the model's own verdict is necessary as well as the scores", () => {
  // Scores that clear every bar but a judge that still says fail: believed.
  // A model that has seen something the rubric did not enumerate must be able
  // to stop the clip without having to express it as a number.
  const v = parseDriftVerdict(goodReply({ verdict: "fail" }));
  assertEquals(driftPasses(v), false);
  const r = parseDriftVerdict(goodReply({ verdict: "regen" }));
  assertEquals(driftPasses(r), false);
});

Deno.test("gate: the strictest bars are the ones the law cares about", () => {
  // Not a style assertion: if these ever invert, the gate is protecting the
  // wrong thing. `additions` (invented people — fair housing) and `same_room`
  // (it is not his house) are the two that must never be the loosest, and
  // `architecture` is the AB 723 axis, so it outranks pure aesthetics.
  assert(DRIFT_PASS_SCORES.additions >= DRIFT_PASS_SCORES.architecture);
  assert(DRIFT_PASS_SCORES.same_room >= DRIFT_PASS_SCORES.architecture);
  assert(DRIFT_PASS_SCORES.architecture > DRIFT_PASS_SCORES.artifacts);
  // And the photo pipeline's own bar, which this one deliberately copies so the
  // two gates cannot disagree about what "unchanged architecture" means.
  assertEquals(DRIFT_PASS_SCORES.architecture, 85, "services/pipeline/config.py qc_pass_score");
});

// ── 3. The retry happens exactly once ────────────────────────────────────────

Deno.test("retry: the FIRST failure retries once, with the safest possible move", () => {
  const v = parseDriftVerdict(goodReply({ verdict: "fail", architecture: 20 }));
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  assertEquals(d.action, "retry");
  assertEquals(d.retryMotion, SAFEST_MOTION);
  assertEquals(d.publishable, false);
  assertStringIncludes(d.message, "push in");
  assertStringIncludes(d.message, "doesn't use another clip from your plan");
});

Deno.test("retry: the SECOND failure REFUSES rather than publishing", () => {
  const v = parseDriftVerdict(goodReply({ verdict: "fail", architecture: 20 }));
  const d = decideDriftAction({ verdict: v, attempt: 1, retryGranted: false });
  assertEquals(d.action, "refuse");
  assertEquals(d.publishable, false);
  assertEquals(d.retryMotion, undefined, "a refusal must not hand back a move to try");
  assertStringIncludes(d.message, "still photo");
});

Deno.test("retry: EXACTLY once — a spent grant refuses even on a first-attempt claim", () => {
  // This is the case a lying or confused client produces: it claims attempt 0
  // forever. The durable grant is what actually decides, and once it is spent
  // the answer is refuse. Without this, "retry once" would be "retry always".
  const v = parseDriftVerdict(goodReply({ verdict: "fail", architecture: 20 }));
  assertEquals(decideDriftAction({ verdict: v, attempt: 0, retryGranted: false }).action, "refuse");
  assertEquals(decideDriftAction({ verdict: v, attempt: 5, retryGranted: true }).action, "refuse");
  // The only combination that retries:
  assertEquals(decideDriftAction({ verdict: v, attempt: 0, retryGranted: true }).action, "retry");
});

Deno.test("retry: a whole lineage runs retry-then-refuse and never publishes", () => {
  // The full sequence a failing photograph produces, with the durable grant
  // modelled as the one-shot it is.
  const failed = parseDriftVerdict(goodReply({ verdict: "fail", artifacts: 15 }));
  let grant = true;
  const spend = () => {
    const had = grant;
    grant = false;
    return had;
  };
  const first = decideDriftAction({ verdict: failed, attempt: 0, retryGranted: spend() });
  const second = decideDriftAction({ verdict: failed, attempt: 0, retryGranted: spend() });
  const third = decideDriftAction({ verdict: failed, attempt: 0, retryGranted: spend() });
  assertEquals([first.action, second.action, third.action], ["retry", "refuse", "refuse"]);
  assertEquals([first.publishable, second.publishable, third.publishable], [false, false, false]);
});

Deno.test("retry: a clip that PASSES on the retry is accepted, grant or no grant", () => {
  const ok = parseDriftVerdict(goodReply());
  assertEquals(decideDriftAction({ verdict: ok, attempt: 1, retryGranted: false }).action, "accept");
  assertEquals(decideDriftAction({ verdict: ok, attempt: 1, retryGranted: false }).publishable, true);
});

// ── 4. Fail closed: nothing but a real pass is publishable ───────────────────

Deno.test("fail closed: an unreachable judge HOLDS — never passes, never retries", () => {
  const v = unavailableVerdict("every provider is down");
  assertEquals(v.unavailable, true);
  assertEquals(driftPasses(v), false);
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  assertEquals(d.action, "hold");
  assertEquals(d.status, "unavailable");
  assertEquals(d.publishable, false);
  assertStringIncludes(d.message, "hasn't been approved");
});

Deno.test("fail closed: an unchecked clip is reported as unchecked, not as fine", () => {
  const block = uncheckedDriftBlock();
  assertEquals(block.status, "unchecked");
  assertEquals(block.publishable, false);
  assertEquals(block.action, "check");
  // It tells the client HOW to check, so "not checked" is actionable rather
  // than a dead end the client learns to ignore.
  const check = block.check as Record<string, unknown>;
  assertEquals(check.path, "/ai-video/drift");
  assertEquals(check.frames, DRIFT_FRAME_POSITIONS);
});

Deno.test("fail closed: `publishable` is true in exactly one situation", () => {
  const cases: DriftVerdict[] = [
    verdict(),                                                   // pass
    verdict({ judgement: "fail" }),
    verdict({ judgement: "regen" }),
    verdict({ judgement: "unknown" }),
    verdict({ clean: false }),
    unavailableVerdict("down"),
    verdict({ scores: { architecture: 10 } }),
  ];
  const publishable = cases.map((v) =>
    [0, 1].some((attempt) =>
      [true, false].some((g) => decideDriftAction({ verdict: v, attempt, retryGranted: g }).publishable)
    )
  );
  assertEquals(publishable, [true, false, false, false, false, false, false]);
});

Deno.test("fail closed: every decision carries a message a human can act on", () => {
  for (const v of [verdict(), verdict({ judgement: "fail" }), unavailableVerdict("down")]) {
    for (const attempt of [0, 1]) {
      const d = decideDriftAction({ verdict: v, attempt, retryGranted: attempt === 0 });
      assert(d.message.length > 30, "a verdict with no explanation teaches the user nothing");
      assert(!d.message.includes("undefined"));
    }
  }
});

Deno.test("fail closed: the judge's own sentence is what the user is told", () => {
  const v = parseDriftVerdict(
    goodReply({ verdict: "fail", architecture: 20, reason: "The roof tiles smear into a painted mass in the last second" }),
  );
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  assertStringIncludes(d.message, "roof tiles smear");
});

// ── 5. The block the API returns ─────────────────────────────────────────────

Deno.test("block: a judged clip reports its scores, its bars and what failed", () => {
  const v = parseDriftVerdict(goodReply({ verdict: "fail", architecture: 31, artifacts: 22 }));
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  const block = driftBlock({
    decision: d,
    verdict: v,
    provider: "anthropic",
    model: "claude-haiku-4-5",
    escalated: false,
    framesJudged: 3,
    attempt: 0,
  });
  assertEquals(block.status, "fail");
  assertEquals(block.publishable, false);
  assertEquals(block.action, "retry");
  assertEquals(block.score, 31);
  assertEquals(block.failed, ["architecture", "artifacts"]);
  assertEquals(block.thresholds, DRIFT_PASS_SCORES);
  assertEquals(block.frames_judged, 3);
  assertEquals((block.retry as Record<string, unknown>).motion, SAFEST_MOTION);
  // Machine-readable, so the client re-checks the retry as attempt 1 and gets a
  // refusal rather than a third go.
  assertEquals((block.retry as Record<string, unknown>).next_attempt, 1);
  // The model that judged it, so a verdict can be traced to a provider later.
  assertEquals(block.model, "claude-haiku-4-5");
});

Deno.test("block: a passing clip carries no retry instruction", () => {
  const v = parseDriftVerdict(goodReply());
  const d = decideDriftAction({ verdict: v, attempt: 0, retryGranted: true });
  const block = driftBlock({
    decision: d,
    verdict: v,
    provider: "anthropic",
    model: "claude-haiku-4-5",
    escalated: false,
    framesJudged: 3,
    attempt: 0,
  });
  assertEquals(block.publishable, true);
  assertEquals(block.retry, undefined);
});

// ── 6. The rubric judges a PROPERTY, not an image ────────────────────────────

Deno.test("rubric: it names every thing the brief said must be judged", () => {
  const r = driftRubric({ kind: "reel", sceneNoun: "home", motionText: "one slow push-in" });
  for (
    const needle of [
      "roof", "windows", "doors", "walls",             // architecture
      "furniture",                                      // contents
      "people", "animal", "watermark", "logo",          // additions
      "melt", "smear", "warp", "flicker",               // artifacts
      "same room",                                      // same_room
    ]
  ) {
    assertStringIncludes(r.toLowerCase(), needle);
  }
  // The framing that makes it a compliance check rather than a taste check.
  assertStringIncludes(r, "SOURCE PHOTOGRAPH IS THE TRUTH");
  assertStringIncludes(r, "AB 723");
  assertStringIncludes(r, "false advertising");
  // The structured answer the parser depends on.
  assertStringIncludes(r, '"verdict": "pass|regen|fail"');
  for (const c of DRIFT_CATEGORIES) assertStringIncludes(r, c);
});

Deno.test("rubric: it says what is NOT a failure, so the gate is not a wall", () => {
  // A judge that fails everything costs a retry every time and gets switched
  // off, which is worse than no gate at all.
  const r = driftRubric({ kind: "reel", sceneNoun: "home", motionText: "one slow push-in" });
  assertStringIncludes(r, "WHAT IS NOT A FAILURE");
  assertStringIncludes(r, "parallax");
  assertStringIncludes(r, "motion blur");
  // And it tells the judge which move was asked for, so legitimate motion is
  // recognisable as legitimate.
  assertStringIncludes(r, "one slow push-in");
});

Deno.test("rubric: the aerial and the reel are described as what they are", () => {
  const aerial = driftRubric({ kind: "aerial", sceneNoun: "home", motionText: null });
  const reel = driftRubric({ kind: "reel", sceneNoun: "restaurant", motionText: null });
  assertStringIncludes(aerial, "aerial establishing shot");
  assertStringIncludes(reel, "animated from one real photograph of a restaurant");
  // No dangling clause when no move was named.
  assert(!aerial.includes("The move this clip was asked for was: null"));
});

// ── 7. Lineage: "once" is a fact about the PHOTOGRAPH ────────────────────────

Deno.test("lineage: the same source hashes the same, a different one does not", async () => {
  const a = await driftLineageKey("aGVsbG8gd29ybGQ=");
  const b = await driftLineageKey("aGVsbG8gd29ybGQ=");
  const c = await driftLineageKey("aGVsbG8gd29ybGQh");
  assertEquals(a, b, "a retry of the same photo must land on the same counter");
  assertNotEquals(a, c);
  assertEquals(a.length, 32);
  assert(/^[0-9a-f]{32}$/.test(a));
  // Empty input still answers something stable rather than throwing.
  assertEquals((await driftLineageKey("")).length, 32);
});

// ── 8. The move a rejected clip is retried with ──────────────────────────────

Deno.test("motion: the safest move exists in BOTH vocabularies", () => {
  // One constant serves reel retries and aerial retries. If a future edit drops
  // push_in from either enum, this fails here rather than at a customer's retry.
  assert((REEL_MOTIONS as readonly string[]).includes(SAFEST_MOTION));
  assert((AERIAL_MOTIONS as readonly string[]).includes(SAFEST_MOTION));
  assertEquals(AERIAL_INVENTS_SURFACE[SAFEST_MOTION as AerialMotion], false);
});

Deno.test("motion: a GROUNDED rise_reveal — the screenshot — is substituted", () => {
  const g = groundedAerialMotion("rise_reveal", true);
  assertEquals(g.motion, "push_in");
  assertEquals(g.requested, "rise_reveal");
  assertEquals(g.substituted, true);
  assert(g.reason && g.reason.includes("roof"), "the user is told why, in their own terms");
});

Deno.test("motion: the UNGROUNDED aerial is untouched, every move, every time", () => {
  // Veo invents a generic building by design and there is no real property to
  // contradict — so text-to-video aerials must be byte-identical to what they
  // were, including the shipped default.
  for (const m of AERIAL_MOTIONS) {
    const g = groundedAerialMotion(m, false);
    assertEquals(g.motion, m);
    assertEquals(g.substituted, false);
    assertEquals(g.reason, null);
  }
});

Deno.test("motion: grounded aerials keep every move that is not rise_reveal", () => {
  for (const m of AERIAL_MOTIONS) {
    const g = groundedAerialMotion(m, true);
    if (m === "rise_reveal") {
      assertEquals(g.substituted, true);
    } else {
      assertEquals(g.motion, m, `${m} must not be substituted — it is handled by the prompt clause`);
      assertEquals(g.substituted, false);
    }
  }
  // Exactly one move is on the list, and it is the one from the screenshot.
  const inventing = AERIAL_MOTIONS.filter((m) => AERIAL_INVENTS_SURFACE[m]);
  assertEquals(inventing, ["rise_reveal"]);
});

// ── 9. Cost: the arithmetic in the comments is the arithmetic in the code ────

Deno.test("cost: the fallback chain's prices are 0018's judge.qc_drift prices", () => {
  const seed = Deno.readTextFileSync(
    new URL("../../migrations/0018_ai_routes.sql", import.meta.url),
  );
  const rows = seed.slice(seed.indexOf("judge.qc_drift"));
  assertStringIncludes(rows, "('judge.qc_drift', 1, 'anthropic', 'claude-haiku-4-5', 'call', 0.66");
  assertStringIncludes(rows, "('judge.qc_drift', 2, 'anthropic', 'claude-sonnet-5', 'call', 1.3");
  assertEquals(DRIFT_FALLBACK_CENTS.primary, 0.66);
  assertEquals(DRIFT_FALLBACK_CENTS.escalation, 1.3);
  assertEquals(DRIFT_TASK, "judge.qc_drift");
});

Deno.test("cost: the check is a small percentage of the clip it protects", () => {
  // The claim made in _shared/drift.ts, asserted against the ledger's own
  // committed prices so it cannot quietly stop being true.
  const reel5s = APP_AI_UNIT_CENTS.seedance_per_s * 5;     // 24.0c
  const aerial8s = APP_AI_UNIT_CENTS.seedance_per_s * 8;   // 38.4c
  const veo = APP_AI_UNIT_CENTS.veo_aerial_clip;           // 80.0c
  assertEquals(reel5s, 24);
  const share = DRIFT_FALLBACK_CENTS.primary / reel5s;
  assert(share < 0.03, `the check is ${(share * 100).toFixed(2)}% of a reel clip`);
  assert(DRIFT_FALLBACK_CENTS.primary / aerial8s < 0.02);
  assert(DRIFT_FALLBACK_CENTS.primary / veo < 0.01);
  // And the escalation is worth buying rather than treating low confidence as a
  // failure: 1.3c against a 24.66c retry (the clip plus its own check).
  assert(DRIFT_FALLBACK_CENTS.escalation < reel5s + DRIFT_FALLBACK_CENTS.primary);
});

Deno.test("cost: the frame budget is the 4-image call 0018 priced", () => {
  assertEquals(DRIFT_MAX_FRAMES, 3, "plus the source still = 4 images");
  assertEquals(DRIFT_FRAME_POSITIONS, ["first", "middle", "last"] as const);
  assertEquals(ESCALATE_BELOW_CONFIDENCE, 0.75, "services/pipeline/config.py qc_confidence_escalate");
});

// ── 10. Wiring ───────────────────────────────────────────────────────────────
//
// index.ts calls Deno.serve at module load, so the route cannot be exercised
// in-process. Grep its source instead — the approach dronecost.test.ts and
// motion_test.ts already use. What matters here is the ORDER of operations and
// that the additive contract with the shipped app is kept.

const INDEX_SRC = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
const DRIFT_ROUTE = INDEX_SRC.slice(
  INDEX_SRC.indexOf('seg[0] === "drift"'),
  INDEX_SRC.indexOf('// ---- GET /ai-video/status ----'),
);

Deno.test("wiring: the drift route exists and judges through the routed task", () => {
  assert(DRIFT_ROUTE.length > 500, "failed to slice the drift route out of index.ts");
  assertStringIncludes(DRIFT_ROUTE, "judgeDrift({");
  assertStringIncludes(DRIFT_ROUTE, "decideDriftAction({ verdict, attempt, retryGranted })");
  assertStringIncludes(INDEX_SRC, "resolveRoute(DRIFT_TASK");
  assertStringIncludes(INDEX_SRC, 'needs: ["classifier", "vision", "multi_image"]');
  assertStringIncludes(INDEX_SRC, "carries_customer_media: true");
});

Deno.test("wiring: the body is validated BEFORE the burst limiter is touched", () => {
  // Audit round 4's rule, which every other route here follows: a request that
  // was never going to work must not consume anything on its way to a 400.
  const validate = DRIFT_ROUTE.indexOf("cleanDriftFrames(body.frames)");
  const guard = DRIFT_ROUTE.indexOf("await guardDriftCheck(");
  const judge = DRIFT_ROUTE.indexOf("await judgeDrift(");
  assert(validate > 0 && guard > 0 && judge > 0, "all three call sites must exist");
  assert(validate < guard, "a malformed body must not spend a limiter token");
  assert(guard < judge, "the role gate runs before a paid model call");
});

Deno.test("wiring: the check is role-gated and org-scoped like every other route", () => {
  assertStringIncludes(INDEX_SRC, 'if (!mem?.role || mem.role === "marketing")');
  assertStringIncludes(INDEX_SRC, "async function guardDriftCheck(userId: string, req: Request)");
  assertStringIncludes(INDEX_SRC, "orgForUser(userId, preferredOrg(req))");
  // The org handed to the audit RPC is the one the JWT resolved to, never one
  // out of the request body.
  assertStringIncludes(DRIFT_ROUTE, "stampProvenanceQc(orgId, provenanceId,");
});

Deno.test("wiring: one judgement per clip — a re-post cannot buy a second verdict", () => {
  assertStringIncludes(DRIFT_ROUTE, "`aidriftjob:${orgId}:${requestId}`");
  assertStringIncludes(DRIFT_ROUTE, '"conflict"');
});

Deno.test("wiring: the retry grant is durable and keyed on the SOURCE photo", () => {
  assertStringIncludes(DRIFT_ROUTE, "driftLineageKey(source.b64)");
  assertStringIncludes(DRIFT_ROUTE, "`aidriftlin:${orgId}:${lineage}`");
  // The client's hint may only ever make it stricter.
  assertStringIncludes(DRIFT_ROUTE, "if (claimed >= 1)");
});

Deno.test("wiring: the refund is bounded, idempotent and never the vendor spend", () => {
  assertStringIncludes(INDEX_SRC, "async function refundRejectedClipAllowance(");
  assertStringIncludes(INDEX_SRC, "`aidriftref:${orgId}:${requestId}`");
  assertStringIncludes(INDEX_SRC, "`aidriftrefmo:${orgId}`");
  assertStringIncludes(INDEX_SRC, "DRIFT_MAX_REFUNDS_PER_MONTH");
  // Only a real, model-delivered failure refunds anything: a `hold` must not
  // turn a provider outage into free clips.
  assertStringIncludes(
    DRIFT_ROUTE,
    'decision.action === "retry" || decision.action === "refuse"',
  );
});

Deno.test("wiring: every judge call writes its own ledger row, feature 'qc'", () => {
  assertStringIncludes(DRIFT_ROUTE, "for (const call of judged.calls)");
  assertStringIncludes(DRIFT_ROUTE, 'feature: "qc"');
  // The audit trail the compliance story needs: what was judged, what it
  // scored, and which provenance row it belongs to.
  for (const field of ["request_id: requestId", "provenance_id", "scores: verdict.scores", "source_sha256"]) {
    assertStringIncludes(DRIFT_ROUTE, field);
  }
});

Deno.test("wiring: /ai-video/status stays backward compatible", () => {
  // The two fields the shipped app decodes from a finished job are untouched,
  // and the drift block is an ADDITIONAL key on the same object.
  assertStringIncludes(
    INDEX_SRC,
    'return json({ status: "completed", video_url: videoUrl, drift: uncheckedDriftBlock() });',
  );
  assertStringIncludes(INDEX_SRC, 'status: "completed",\n    video_url: videoUrl,');
  // Both completion paths — the legacy fal one and the routed one — carry it,
  // so a routed job is not silently the unguarded path.
  assertEquals(
    INDEX_SRC.split("uncheckedDriftBlock()").length - 1,
    2,
    "the legacy fal path and the routed path — a routed job is not the unguarded one",
  );
  // The processing and failed shapes are untouched.
  assertStringIncludes(INDEX_SRC, 'return json({ status: "failed", error: failMsg });');
});

Deno.test("wiring: the grounded aerial no longer builds a rise_reveal prompt", () => {
  const AERIAL_ROUTE = INDEX_SRC.slice(
    INDEX_SRC.indexOf('seg[0] === "aerial"'),
    INDEX_SRC.indexOf('seg[0] === "reel-clip"'),
  );
  assertStringIncludes(AERIAL_ROUTE, "groundedAerialMotion(motion, grounded)");
  assertStringIncludes(AERIAL_ROUTE, "motion: aerialMove.motion,");
  // The caller still learns what it asked for and what it got.
  assertStringIncludes(AERIAL_ROUTE, "motion_requested: aerialMove.requested,");
  // And the enum gate + the shipped default are unchanged, so a shipped build
  // still gets a 202 for exactly the bodies it sends today.
  assertStringIncludes(AERIAL_ROUTE, 'String(body.motion ?? "rise_reveal")');
  assertStringIncludes(AERIAL_ROUTE, "(AERIAL_MOTIONS as readonly string[]).includes(motionRaw)");
});

Deno.test("wiring: the grounded aerial prompt forbids the surface it used to invent", () => {
  const builder = INDEX_SRC.slice(
    INDEX_SRC.indexOf("function buildAerialPrompt"),
    INDEX_SRC.indexOf("interface DroneBody"),
  );
  assert(builder.length > 500, "failed to slice buildAerialPrompt out of index.ts");
  assertStringIncludes(builder, "Never render any surface the reference photograph does not contain");
  assertStringIncludes(builder, "no roof plane");
  // Grounded ONLY: the ungrounded branch has no real building to be unfaithful
  // to and its prompt must not change.
  const grounded = builder.indexOf("if (args.grounded) {");
  const ungrounded = builder.indexOf("} else {");
  const clause = builder.indexOf("Never render any surface");
  assert(grounded < clause && clause < ungrounded, "the clause must sit inside the grounded branch");
});

Deno.test("wiring: the judge's inputs are bounded before they reach a provider", () => {
  assertStringIncludes(INDEX_SRC, "const MAX_DRIFT_IMAGE_B64_CHARS = 2_000_000;");
  assertStringIncludes(INDEX_SRC, "readJsonLimited<DriftBody>(req, MAX_DRIFT_BODY_BYTES)");
  assertStringIncludes(INDEX_SRC, "ALLOWED_IMAGE_MIMES.includes(m)");
});

Deno.test("wiring: a judge that cannot be reached returns a verdict, never a throw", () => {
  // The fail-closed path. If judgeDrift() ever propagated the chain's 503, the
  // app would show a network error and publish the clip anyway.
  assertStringIncludes(INDEX_SRC, "return {\n      verdict: unavailableVerdict(");
  assertStringIncludes(INDEX_SRC, "ai-video: the drift judge could not be reached:");
});
