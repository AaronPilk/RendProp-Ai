// ai-copy — prompt/budget/parsing tests.
//
//   deno test services/supabase/functions/ai-copy/prompt_test.ts
//
// Pure — no env, no network, no Supabase (prompt.ts imports nothing). Covers the
// four things that are load-bearing and cheap to get wrong:
//
//   • THE CHARACTER BUDGET, including the clamp at MAX_SCRIPT_CHARS. The reel
//     stitcher HOLDS THE LAST VIDEO FRAME when the voiceover overruns, so an
//     over-long script is a frozen frame, not a slightly long reel — and a
//     script over 1,000 characters is refused outright by /ai-voice/tts, i.e.
//     a script the user cannot use.
//   • THE {address} PLACEHOLDER SURVIVING every step of the pipeline. The street
//     address is never sent to this function, so the placeholder is the ONLY way
//     the finished voiceover names the property.
//   • STRICT-JSON EXTRACTION, including answers that are not JSON at all.
//   • DEGRADING SENSIBLY on an unknown/absent tone and on empty room tags —
//     the two fields a client is most likely to omit.

import { assert, assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  ADDRESS_PLACEHOLDER,
  CHARS_PER_SECOND,
  MAX_PROMPT_OUTPUT,
  MAX_SCRIPT_CHARS,
  MAX_TARGET_SECONDS,
  MIN_TARGET_SECONDS,
  buildScriptTurn,
  charBudgetFor,
  cleanEditPrompt,
  cleanFacts,
  cleanRoomTags,
  cleanScript,
  cleanTargetSeconds,
  editPromptInstruction,
  estimatedSecondsFor,
  extractJsonObject,
  fitToBudget,
  normalizePlaceholder,
  scriptInstruction,
  scrubStreetAddress,
  spaceTypeOf,
  toneOf,
  userFreeText,
  vocabFor,
} from "./prompt.ts";

const REQ = {
  space: "real_estate" as const,
  tone: "warm" as const,
  targetSeconds: 30,
  charBudget: 330,
  facts: { beds: 4, baths: 3, sqft: 2400, price_label: "$1,500,000" },
  roomTags: ["Entry", "Kitchen", "Primary"],
  photoCount: 6,
};

// ── The character budget ─────────────────────────────────────────────────────

Deno.test("charBudgetFor: 11 characters per second of video, rounded", () => {
  assertEquals(CHARS_PER_SECOND, 11);
  assertEquals(charBudgetFor(10), 110);
  assertEquals(charBudgetFor(30), 330);
  assertEquals(charBudgetFor(45), 495); // the contract's longest reel: 9 clips
  assertEquals(charBudgetFor(12.5), 138); // 137.5 rounds to 138
});

Deno.test("charBudgetFor: clamps hard at MAX_SCRIPT_CHARS (= ai-voice's own cap)", () => {
  assertEquals(MAX_SCRIPT_CHARS, 1000);
  // 91 s x 11 = 1001, the first second past the ceiling.
  assertEquals(charBudgetFor(91), MAX_SCRIPT_CHARS);
  assertEquals(charBudgetFor(600), MAX_SCRIPT_CHARS);
  assertEquals(charBudgetFor(1e9), MAX_SCRIPT_CHARS);
  // …and 90 s, the documented meeting point, is still under it.
  assertEquals(charBudgetFor(90), 990);
  assert(charBudgetFor(90) <= MAX_SCRIPT_CHARS);
});

Deno.test("charBudgetFor: junk and non-positive input is zero, never NaN", () => {
  assertEquals(charBudgetFor(0), 0);
  assertEquals(charBudgetFor(-5), 0);
  assertEquals(charBudgetFor(Number.NaN), 0);
});

Deno.test("cleanTargetSeconds: clamps into the usable range, junk floors", () => {
  assertEquals(cleanTargetSeconds(30), 30);
  assertEquals(cleanTargetSeconds(10), 10);
  assertEquals(cleanTargetSeconds(45), 45);
  assertEquals(cleanTargetSeconds(1), MIN_TARGET_SECONDS);
  assertEquals(cleanTargetSeconds(9999), MAX_TARGET_SECONDS);
  assertEquals(cleanTargetSeconds(undefined), MIN_TARGET_SECONDS);
  assertEquals(cleanTargetSeconds("not a number"), MIN_TARGET_SECONDS);
});

Deno.test("clamped seconds x the rate can never exceed the ceiling", () => {
  for (const raw of [0, 5, 10, 45, 90, 91, 3600, "45", null, undefined]) {
    assert(charBudgetFor(cleanTargetSeconds(raw)) <= MAX_SCRIPT_CHARS);
  }
});

Deno.test("estimatedSecondsFor: the same rate, back the other way", () => {
  assertEquals(estimatedSecondsFor(330), 30);
  assertEquals(estimatedSecondsFor(0), 0);
  assertEquals(estimatedSecondsFor(-1), 0);
  // 1,000 characters is ai-voice's own "about 90 seconds of speech".
  assertEquals(estimatedSecondsFor(MAX_SCRIPT_CHARS), 90.9);
});

Deno.test("fitToBudget: prefers a sentence end, never cuts mid-word, no ellipsis", () => {
  const text = "Four bedrooms open onto the water. The kitchen was rebuilt last year. Book a showing.";
  const fitted = fitToBudget(text, 70);
  assertEquals(fitted, "Four bedrooms open onto the water. The kitchen was rebuilt last year.");
  assert(!fitted.includes("…"));

  // No sentence end inside the budget → the last word boundary, still no cut word.
  const runOn = "a".repeat(30) + " " + "b".repeat(30) + " " + "c".repeat(30);
  const cut = fitToBudget(runOn, 70);
  assertEquals(cut, "a".repeat(30) + " " + "b".repeat(30));
  assert(cut.length <= 70);

  // Already short enough: untouched.
  assertEquals(fitToBudget("Short.", 100), "Short.");
  assertEquals(fitToBudget("anything", 0), "");
});

Deno.test("cleanScript: the whole pipeline lands inside the budget", () => {
  const raw = "```\n**Hook line here.**  \n\n(pause)  Four bedrooms, three baths. " +
    "Twenty-four hundred square feet. Book a showing.\n```";
  const out = cleanScript(raw, 200);
  assert(out.length <= 200);
  assert(!out.includes("*"), "markdown must not survive into a TTS script");
  assert(!out.includes("```"));
  assert(!out.toLowerCase().includes("(pause)"), "stage directions must not be spoken");
  assertStringIncludes(out, "Four bedrooms");
});

// ── The {address} placeholder ────────────────────────────────────────────────

Deno.test("the {address} placeholder survives the whole cleaning pipeline", () => {
  const raw = "  Four bedrooms   on the water.\n\nThis is {address}. Book a showing.  ";
  const out = cleanScript(raw, 300);
  assertStringIncludes(out, ADDRESS_PLACEHOLDER);
  assertEquals(ADDRESS_PLACEHOLDER, "{address}");
});

Deno.test("normalizePlaceholder: the near-misses a model reaches for all normalise", () => {
  for (
    const variant of [
      "{{address}}",
      "[address]",
      "{Address}",
      "{ADDRESS}",
      "{the address}",
      "{property address}",
      "{ address }",
    ]
  ) {
    assertEquals(
      normalizePlaceholder(`Welcome home to ${variant}.`),
      `Welcome home to ${ADDRESS_PLACEHOLDER}.`,
      `variant ${variant} did not normalise`,
    );
  }
});

Deno.test("normalizePlaceholder: leaves ordinary prose alone", () => {
  const prose = "The address is on the flyer.";
  assertEquals(normalizePlaceholder(prose), prose);
});

Deno.test("scrubStreetAddress: an INVENTED street address becomes the placeholder", () => {
  // The address is never in the request, so any street address in the answer was
  // made up — and a made-up house number spoken over the owner's own footage is
  // worse than none at all.
  assertEquals(
    scrubStreetAddress("Welcome to 1247 Hillcrest Drive, where the light is."),
    `Welcome to ${ADDRESS_PLACEHOLDER}, where the light is.`,
  );
  assertEquals(scrubStreetAddress("Set on 2 Bakery Lane."), `Set on ${ADDRESS_PLACEHOLDER}`);
});

Deno.test("scrubStreetAddress: ordinary numbers are not addresses", () => {
  for (
    const keep of [
      "Three bedrooms and 2 full baths.",
      "2,400 square feet over two floors.",
      "Seats 220 guests.",
      "Open 7 days a week.",
    ]
  ) {
    assertEquals(scrubStreetAddress(keep), keep);
  }
});

Deno.test("a placeholder written as {{address}} survives cleanScript too", () => {
  const out = cleanScript('{"noise":0} {{address}} is on the market. Book a showing.', 200);
  assertStringIncludes(out, ADDRESS_PLACEHOLDER);
});

// ── Strict-JSON extraction ───────────────────────────────────────────────────

Deno.test("extractJsonObject: plain JSON parses directly", () => {
  assertEquals(extractJsonObject('{"script":"hi"}')?.script, "hi");
});

Deno.test("extractJsonObject: a ```json fence is stripped", () => {
  assertEquals(extractJsonObject('```json\n{"script":"hi"}\n```')?.script, "hi");
});

Deno.test("extractJsonObject: prose around the object is ignored", () => {
  assertEquals(
    extractJsonObject('Sure! Here you go:\n{"prompt":"Repaint the walls."}\nHope that helps.')?.prompt,
    "Repaint the walls.",
  );
});

Deno.test("extractJsonObject: a brace inside a string value doesn't end the scan early", () => {
  const obj = extractJsonObject('{"script":"say {address} out loud","characters":0}');
  assertEquals(obj?.script, "say {address} out loud");
});

Deno.test("extractJsonObject: MALFORMED answers return null rather than half an object", () => {
  assertEquals(extractJsonObject('{"script":"unterminated'), null);
  assertEquals(extractJsonObject("just prose, no braces at all"), null);
  assertEquals(extractJsonObject('{"script": }'), null);
  assertEquals(extractJsonObject(""), null);
  assertEquals(extractJsonObject("   "), null);
  // A bare array is not the object — coercing one is how a malformed answer
  // becomes a confidently wrong result.
  assertEquals(extractJsonObject('["script","hi"]'), null);
});

Deno.test("a malformed answer still yields usable text: the raw string is the fallback", () => {
  // This is exactly what index.ts's `clean` does when extraction fails: fall
  // back to the model's plain prose rather than losing a paid generation.
  const raw = "Four bedrooms open onto the water. Book a showing.";
  assertEquals(extractJsonObject(raw), null);
  assertEquals(cleanScript(raw, 200), raw);
});

// ── Degrading sensibly ───────────────────────────────────────────────────────

Deno.test("toneOf: unknown, absent and junk tones all become warm", () => {
  assertEquals(toneOf("punchy"), "punchy");
  assertEquals(toneOf("LUXURY"), "luxury");
  assertEquals(toneOf(" warm "), "warm");
  assertEquals(toneOf("aggressive"), "warm");
  assertEquals(toneOf(undefined), "warm");
  assertEquals(toneOf(null), "warm");
  assertEquals(toneOf(42), "warm");
});

Deno.test("scriptInstruction: an unknown tone still produces one style direction", () => {
  const unknown = scriptInstruction({ ...REQ, tone: toneOf("shouty") });
  const warm = scriptInstruction({ ...REQ, tone: "warm" });
  assertEquals(unknown, warm);
  assertStringIncludes(unknown, "STYLE: ");
});

Deno.test("scriptInstruction: EMPTY room tags never ask the model to name rooms", () => {
  const withTags = scriptInstruction(REQ);
  assertStringIncludes(withTags, "Entry → Kitchen → Primary");
  assertStringIncludes(withTags, "SPINE");

  const without = scriptInstruction({ ...REQ, roomTags: [] });
  assert(!without.includes("SPINE"), "no walk order means no spine to follow");
  assertStringIncludes(without, "do not name specific rooms");
  assertStringIncludes(without, "you would be guessing at what is on screen");
});

Deno.test("buildScriptTurn: empty room tags say so explicitly, never silently", () => {
  assertStringIncludes(buildScriptTurn({ ...REQ, roomTags: [] }), "(none captured)");
  assertStringIncludes(buildScriptTurn(REQ), "Entry, Kitchen, Primary");
});

Deno.test("cleanRoomTags: dedupes and bounds but NEVER sorts — walk order is the value", () => {
  assertEquals(cleanRoomTags(["Kitchen", "Entry", "kitchen", "  Primary  "]), [
    "Kitchen",
    "Entry",
    "Primary",
  ]);
  assertEquals(cleanRoomTags(undefined), []);
  assertEquals(cleanRoomTags("Kitchen"), []);
  assertEquals(cleanRoomTags([""]), []);
  assertEquals(cleanRoomTags(Array.from({ length: 100 }, (_, i) => `Room ${i}`)).length, 24);
});

Deno.test("cleanFacts: numbers are bounded and a street address is not a region", () => {
  const facts = cleanFacts({
    beds: 4,
    baths: "3",
    sqft: 2400.7,
    price_label: "$1,500,000",
    region: "Sausalito, CA",
    tagline: "  Water on three sides  ",
    details: { Capacity: "220 seated", "": "dropped", Ignored: "" },
    junk: "dropped",
  });
  assertEquals(facts.beds, 4);
  assertEquals(facts.baths, 3);
  assertEquals(facts.sqft, 2401);
  assertEquals(facts.price_label, "$1,500,000");
  assertEquals(facts.region, "Sausalito, CA");
  assertEquals(facts.tagline, "Water on three sides");
  assertEquals(facts.details, { Capacity: "220 seated" });

  // A house number is a street, not a region — the same test ai-video applies.
  assertEquals(cleanFacts({ region: "1247 Hillcrest Dr, Sausalito" }).region, undefined);
  // Nothing at all is an empty object, never a throw.
  assertEquals(cleanFacts(undefined), {});
  assertEquals(cleanFacts("nonsense"), {});
});

Deno.test("userFreeText: the gate reads the user's WORDS, not their numbers", () => {
  const facts = cleanFacts({ beds: 4, tagline: "Great for families", region: "Sausalito, CA" });
  const text = userFreeText(facts, ["Kitchen"]);
  assertStringIncludes(text, "Great for families");
  assertStringIncludes(text, "Sausalito, CA");
  assertStringIncludes(text, "Kitchen");
  assert(!text.includes("4"), "a bed count cannot trip a fair-housing rule");
});

// ── Industry vocabulary (the mirror of SpaceType in Models/Listing.swift) ─────

Deno.test("spaceTypeOf: unknown and absent become real_estate, like the app's own default", () => {
  assertEquals(spaceTypeOf("venue"), "venue");
  assertEquals(spaceTypeOf("REAL-ESTATE"), "real_estate");
  assertEquals(spaceTypeOf("warehouse"), "real_estate");
  assertEquals(spaceTypeOf(undefined), "real_estate");
});

Deno.test("scriptInstruction: speaks each industry's own words, never the model's", () => {
  const venue = scriptInstruction({ ...REQ, space: "venue" });
  assertStringIncludes(venue, "planners"); // customerNoun
  assertStringIncludes(venue, "Plan your event"); // ctaTitle
  assertStringIncludes(venue, "Book more events"); // pitch
  assertStringIncludes(venue, "areas"); // areaNoun
  assert(!venue.includes("buyers"), "a venue never has buyers");

  const gym = scriptInstruction({ ...REQ, space: "fitness" });
  assertStringIncludes(gym, "members");
  assertStringIncludes(gym, "Book a session");
  assertEquals(vocabFor("fitness").space, "studio");
});

Deno.test("scriptInstruction: hook first, the length constraint, and the placeholder rule", () => {
  const s = scriptInstruction(REQ);
  assertStringIncludes(s, "HOOK FIRST");
  assertStringIncludes(s, '"Welcome to"'); // the banned opener is named
  assertStringIncludes(s, "AT MOST 330 characters");
  assertStringIncludes(s, "FREEZES"); // why length is not a suggestion
  assertStringIncludes(s, ADDRESS_PLACEHOLDER);
  assertStringIncludes(s, "never invent one");
  assertStringIncludes(s, '{"script":"<the script>"}');
});

// ── The shared photo-edit-prompt instruction (ai-photo imports this) ─────────

Deno.test("editPromptInstruction: asks for a PRESET's density of direction", () => {
  const s = editPromptInstruction("real_estate");
  assertStringIncludes(s, "WHAT CHANGES");
  assertStringIncludes(s, "IDENTICAL");
  assertStringIncludes(s, "shadows and"); // "shadows and reflections that match"
  assertStringIncludes(s, "real-estate photo"); // ai-photo's own noun
  assertStringIncludes(s, "a real-estate agent"); // ai-photo's own audience
  assertStringIncludes(s, String(MAX_PROMPT_OUTPUT));
  assertStringIncludes(s, '{"prompt":"<the rewritten instruction>"}');
});

Deno.test("editPromptInstruction: never duplicates the guardrails ai-photo appends", () => {
  const s = editPromptInstruction("restaurant", "patio");
  assertStringIncludes(s, "of the patio");
  assertStringIncludes(s, "Do NOT add boilerplate");
  assertStringIncludes(s, "the system appends all of that separately");
  // The LOCK text itself must never be produced here — ai-photo adds it, and a
  // doubled instruction is a model that weights it twice.
  assert(!s.includes("Do not change the building's architecture"));
});

Deno.test("cleanEditPrompt: one flat paragraph inside the cap", () => {
  const raw = '```json\n{"prompt":"x"}\n```';
  assert(cleanEditPrompt(raw, MAX_PROMPT_OUTPUT).length <= MAX_PROMPT_OUTPUT);
  const long = "Repaint the cabinets a soft matte white. ".repeat(40);
  const out = cleanEditPrompt(long, MAX_PROMPT_OUTPUT);
  assert(out.length <= MAX_PROMPT_OUTPUT);
  assert(!out.endsWith(" "));
});
