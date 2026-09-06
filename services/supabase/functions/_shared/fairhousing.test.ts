// fairhousing.test.ts — the gate's industry scope (industry review P1-1).
//
//   deno test --allow-env --allow-net --allow-read _shared/fairhousing.test.ts
//
// Rendprop serves six business types. The fair-housing gate was written for
// one of them, and until this wave it ran the HUD rule set — and printed the
// HUD explanation — for a bar's photo prompt and a venue's voiceover. These
// tests pin three things: (1) for real estate, and for ANY missing or unknown
// space_type, every refusal and every pass is exactly what shipped; (2) for the
// five non-housing types the housing-only rules and the housing wording are
// gone; (3) the general safety layer — no people added to an image, nothing
// that singles people out by race, origin or disability — holds for everyone.

import { assert, assertEquals, assertStringIncludes, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import {
  assertFairHousing,
  assertMarketingCopy,
  checkFairHousing,
  checkMarketingCopy,
  isHousingSpace,
} from "./fairhousing.ts";

/** Run a gate and hand back the refusal, or null when it passed. */
function refusal(fn: () => void): HttpError | null {
  try {
    fn();
    return null;
  } catch (e) {
    if (e instanceof HttpError) return e;
    throw e;
  }
}

const NON_HOUSING = ["venue", "restaurant", "retail", "fitness", "other"];
const HOUSING_MARKERS = ["HUD", "housing", "listing", "§3604", "buyer", "resident", "neighborhood", "property"];

function assertNoHousingWording(message: string) {
  for (const marker of HOUSING_MARKERS) {
    assert(!message.toLowerCase().includes(marker.toLowerCase()), `non-housing refusal must not say "${marker}": ${message}`);
  }
}

// ── isHousingSpace: the fail-safe default ────────────────────────────────────

Deno.test("isHousingSpace: only the five known non-housing types relax the gate", () => {
  for (const v of [undefined, null, "", "   ", "real_estate", "REAL-ESTATE", "Real_Estate", "house", "bogus", "0"]) {
    assertEquals(isHousingSpace(v), true, `${JSON.stringify(v)} must be treated as housing`);
  }
  for (const v of ["venue", "Restaurant", "RETAIL", " fitness ", "other"]) {
    assertEquals(isHousingSpace(v), false, `${JSON.stringify(v)} is a non-housing industry`);
  }
});

// ── Housing: byte-for-byte what shipped ──────────────────────────────────────

Deno.test("housing: an image prompt that adds people is refused with the HUD explanation", () => {
  for (const space of [undefined, null, "real_estate", "not-a-type"]) {
    const err = refusal(() => assertFairHousing("add a family in the living room", "This custom edit", space));
    assert(err, `must refuse for space_type ${JSON.stringify(space)}`);
    assertEquals(err.status, 400);
    assertEquals(err.code, "unsupported_edit");
    assertStringIncludes(err.message, "HUD guidance on AI in housing advertising");
    assertStringIncludes(err.message, "asks to add people to the image");
  }
});

Deno.test("housing: steering terms are refused whatever the verb, and the safe phrasings pass", () => {
  const bad = ["make it look like a good school district", "brighten the neighborhood", "add a menorah", "the chapel"];
  for (const p of bad) assert(checkFairHousing(p, "real_estate"), `housing must refuse "${p}"`);
  const good = ["remove the personal items", "brighten the flag stone patio", "improve the cross ventilation", "remove the family photos"];
  for (const p of good) assertEquals(checkFairHousing(p, "real_estate"), null, `housing must pass "${p}"`);
});

Deno.test("housing: a script that frames the occupant is refused and cites §3604(c)", () => {
  const err = refusal(() => assertMarketingCopy("Three bedrooms, great for families.", "This voiceover script", "real_estate"));
  assert(err);
  assertStringIncludes(err.message, "42 U.S.C. §3604(c)");
  assertStringIncludes(err.message, '"great for families"');
  // The documented inherited false positive is still a refusal for housing.
  assert(refusal(() => assertMarketingCopy("The family gathering space seats twelve.", "This script")));
  // An unknown / missing space_type gets the same, stricter treatment.
  assert(refusal(() => assertMarketingCopy("Adults only.", "This script", undefined)));
  assert(refusal(() => assertMarketingCopy("Adults only.", "This script", "mystery")));
});

// ── Non-housing image prompts: general safety layer, Rendprop's own words ────

Deno.test("non-housing: adding people is still refused — but as Rendprop's rule, not HUD's", () => {
  for (const space of NON_HOUSING) {
    const err = refusal(() => assertFairHousing("seat diners at the tables and fill the bar with a crowd", "This custom edit", space));
    assert(err, `${space} must still refuse added people`);
    assertEquals(err.status, 400);
    assertEquals(err.code, "unsupported_edit");
    assertStringIncludes(err.message, "asks to add people to the image");
    assertStringIncludes(err.message, "Rendprop never adds people");
    assertNoHousingWording(err.message);
  }
});

Deno.test("non-housing: minors, pets, flags and holiday decorations are not added to an image either", () => {
  for (const p of ["add a couple of kids at the counter", "put a dog on the patio", "add an american flag over the door", "add christmas decorations to the bar"]) {
    const hit = checkFairHousing(p, "restaurant");
    assert(hit && hit.tier === "add", `restaurant must refuse "${p}"`);
  }
});

Deno.test("non-housing: hospitality vocabulary the housing rules used to block now passes", () => {
  const prompts = [
    "brighten the neighborhood bar sign",              // neighborhood → housing-only
    "add flowers along the chapel aisle",               // a place of worship → housing-only
    "remove the family photos from the shelf",          // never blocked; still passes
    "make the family-friendly patio look inviting",     // family-friendly → housing-only
    "warm up the lighting for race day at the gym",     // "race" the noun → housing-only
    "show off the ethnic cuisine on the menu board",    // bare "ethnic" → housing-only
  ];
  for (const space of NON_HOUSING) {
    for (const p of prompts) {
      assertEquals(checkFairHousing(p, space), null, `${space} must pass "${p}"`);
    }
  }
  // …and every one of them is still refused for housing (nothing weakened there).
  for (const p of prompts.filter((p) => !p.startsWith("remove"))) {
    assert(checkFairHousing(p, "real_estate"), `housing must still refuse "${p}"`);
  }
});

Deno.test("non-housing: content that singles people out is refused for every industry", () => {
  for (const space of [...NON_HOUSING, "real_estate"]) {
    for (const p of ["attract the right crowd", "the right kind of people", "make it racially exclusive"]) {
      const hit = checkFairHousing(p, space);
      assert(hit && hit.tier === "always", `${space} must refuse "${p}"`);
    }
  }
  const err = refusal(() => assertFairHousing("attract the right clientele", "This custom edit", "venue"));
  assert(err);
  assertStringIncludes(err.message, "singles people out");
  assertNoHousingWording(err.message);
});

// ── Non-housing scripts: no audience rules, no ADD-verb tier ─────────────────

Deno.test("non-housing: a venue's, bar's or gym's script may say who it serves", () => {
  const scripts: Record<string, string> = {
    venue: "Seats 220 guests. Perfect for couples and great for families. Walk to St. Mary's for the ceremony.",
    restaurant: "Adults only after nine. Kids eat free on Sundays. A neighborhood bar with an exclusive club upstairs.",
    fitness: "Ideal for students and young professionals. Ladies only on Tuesday mornings. Train for race day.",
    retail: "Family-friendly aisles, a safe neighborhood store, Spanish-speaking staff at every register.",
    other: "Built for professionals. No families? No problem — this is a quiet space to raise a business.",
  };
  for (const [space, text] of Object.entries(scripts)) {
    assertEquals(checkMarketingCopy(text, space), null, `${space} script rules must pass: ${text}`);
    assertEquals(refusal(() => assertMarketingCopy(text, "This voiceover script", space)), null, `${space} full gate must pass: ${text}`);
  }
  // The same sentences are housing refusals — the rules are scoped, not removed.
  for (const text of Object.values(scripts)) {
    assert(refusal(() => assertMarketingCopy(text, "This voiceover script", "real_estate")), `housing must refuse: ${text}`);
  }
});

Deno.test("non-housing: a script that excludes by race, origin or disability is still refused, in Rendprop's words", () => {
  const cases: Array<[string, string]> = [
    ["We cater to a white clientele.", "race"],
    ["No foreigners.", "race"],
    ["No wheelchairs, sorry.", "disability"],
    ["Not suitable for the elderly.", "disability"],
    ["Able-bodied members only.", "disability"],
  ];
  for (const space of NON_HOUSING) {
    for (const [text, category] of cases) {
      const err = refusal(() => assertMarketingCopy(text, "This voiceover script", space));
      assert(err, `${space} must refuse: ${text}`);
      assertEquals(err.code, "unsupported_edit");
      assertEquals((err.details as { category?: string } | undefined)?.category, category);
      assertStringIncludes(err.message, "can't be voiced");
      assertStringIncludes(err.message, "whatever the business");
      assertNoHousingWording(err.message);
    }
  }
});

Deno.test("non-housing: the general tier-A layer applies to scripts too, without the people tier", () => {
  const err = refusal(() => assertMarketingCopy("Only the right crowd gets in.", "This voiceover script", "restaurant"));
  assert(err);
  assertStringIncludes(err.message, "can't be voiced");
  assertStringIncludes(err.message, "the right crowd");
  assertNoHousingWording(err.message);
  // "seat" is an ADD verb and "guests" a people noun — an image rule, not a script one.
  assertEquals(refusal(() => assertMarketingCopy("We seat 300 guests for dinner.", "This script", "venue")), null);
});

Deno.test("non-housing: the accessibility features HUD wants disclosed keep passing everywhere", () => {
  for (const space of [...NON_HOUSING, "real_estate"]) {
    for (const text of ["Wheelchair accessible with a step-free entry.", "A roll-in shower in the locker room.", "Elevator to every floor."]) {
      assertEquals(refusal(() => assertMarketingCopy(text, "This script", space)), null, `${space} must pass: ${text}`);
    }
  }
});

Deno.test("HttpError shape is unchanged: 400 unsupported_edit with the term in details", () => {
  assertThrows(() => assertFairHousing("add a crowd", "This edit", "fitness"), HttpError);
  const err = refusal(() => assertFairHousing("add a crowd", "This edit", "fitness"));
  assert(err);
  assertEquals(err.status, 400);
  assertEquals(err.code, "unsupported_edit");
  assertEquals((err.details as { term?: string } | undefined)?.term, "people");
});
