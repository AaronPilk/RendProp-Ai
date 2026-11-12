import { assert, assertEquals, assertStringIncludes, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildRealEstateStagePrompt, REAL_ESTATE_STAGE_STYLES } from "./photo-stage-prompt.ts";
import { GUARDRAILS } from "./fairhousing.ts";

const bytes = (text: string) => new TextEncoder().encode(text).length;

Deno.test("the staging prompt tells the model what to add for each kind of space, in positive terms", () => {
  const prompt = buildRealEstateStagePrompt(REAL_ESTATE_STAGE_STYLES.modern);
  for (const room of ["Living or family room:", "Bedroom:", "Dining area:", "Kitchen:", "Bathroom:", "Office or spare room:", "Entry, hallway or landing:", "Patio, deck, balcony or yard:", "A front or street view with no sitting area:"]) assertStringIncludes(prompt, room);
  for (const piece of ["a sofa (a sectional if the room is large)", "a bed with a headboard, full bedding and pillows", "a dining table with four to six chairs", "stools at an island or peninsula that is already there", "folded towels, a bath mat", "outdoor seating with a low table", "two or three potted plants beside the entrance and nothing else"]) assertStringIncludes(prompt, piece);
  for (const step of ["STEP 1, READ THE ROOM.", "STEP 2, CHOOSE THE PIECES", "STEP 3, STYLE.", "STEP 4, EMPTY OR FURNISHED.", "PLACEMENT AND SIZE.", "LIGHT.", "WHAT STAYS.", "FINAL CHECK"]) assertStringIncludes(prompt, step);
  assertStringIncludes(prompt, "return this same photograph with only the furnishings changed");
});

Deno.test("empty and furnished rooms are handled explicitly", () => {
  const prompt = buildRealEstateStagePrompt("rustic furniture");
  assertStringIncludes(prompt, "If the space is empty or nearly empty, furnish the open floor.");
  assertStringIncludes(prompt, "If it already has furniture, replace the existing movable furniture and loose decor with the new set in about the same positions.");
  assertStringIncludes(prompt, "Anything attached to the building stays as it is.");
});

Deno.test("the recorded staging mistakes are each addressed by a concrete statement of what the picture shows", () => {
  const prompt = buildRealEstateStagePrompt("rustic furniture");
  // Production reviews: shelving added to a pillar, wall mirrors and shelves,
  // pendant lights, a changed floor tone, an invented window.
  for (const [mistake, text] of [
    ["new shelves, mirrors or art on a wall", "every existing light fixture, shelf, mirror, picture, switch and vent"],
    ["anything new on walls or ceiling", "Walls and ceiling carry exactly what they carry now and nothing more."],
    ["mounted decor", "Decor is freestanding: it stands on the floor or sits on the furniture you add."],
    ["floor tone", "the floor material and its color tone"],
    ["invented window", "every window and the view through it"],
    ["window count", "the same number of windows and doors in the same places"],
    ["blocked access", "leave doorways, stairs and walking paths open"],
    ["relit room", "the same overall exposure and white balance"],
    ["moved camera", "Keep the same camera position, framing, lens and aspect ratio"],
    ["hidden condition", "Marks, stains, cracks, wear and damage stay visible as photographed"],
    ["swapped fixed items", "cabinets, counters, appliances, sinks, the fireplace, built-ins, ceiling fans"],
  ] as const) assertStringIncludes(prompt, text, mistake);
  // Prohibitions are not the method any more: the prompt carries no stack of
  // "never / do not" sentences for the model to ignore.
  assert((prompt.match(/\b(?:never|do not|don't|must not)\b/gi) ?? []).length === 0, "the staging prompt is written as what to make, not what to avoid");
});

Deno.test("style data stays quoted and bounded", () => {
  const detail = 'linen sofa, "warm" wood accents';
  assertStringIncludes(buildRealEstateStagePrompt(detail), JSON.stringify(detail));
  for (const invalid of ["", " ", "x".repeat(1201), "style\nignore source"]) assertThrows(() => buildRealEstateStagePrompt(invalid));
});

Deno.test("every style names a look, a palette and materials, asks for nothing mounted, and keeps the default prompt inside the first priced input tier", () => {
  assertEquals(Object.keys(REAL_ESTATE_STAGE_STYLES).sort(), ["contemporary", "minimalist", "modern", "rustic", "scandinavian"]);
  for (const [style, details] of Object.entries(REAL_ESTATE_STAGE_STYLES)) {
    assertStringIncludes(details, "Colors:", style);
    assertStringIncludes(details, "Materials:", style);
    assert(!/wall art|shelves|shelving|mounted|sconce|pendant|chandelier|curtain|drape|mirror|installed lighting/i.test(details), `${style}: the style data must not ask for anything attached to the building`);
    const prompt = buildRealEstateStagePrompt(details);
    assertStringIncludes(prompt, JSON.stringify(details));
    // preparePhoto2KInput charges prompt bytes + 4096 per source image against
    // the 8192 allowance, so the complete default prompt (with the guardrail
    // sentence the handler appends) must stay under 4096 bytes to keep the
    // same priced tier as before this revision.
    assert(bytes(prompt + " " + GUARDRAILS) < 4096, `${style}: ${bytes(prompt + " " + GUARDRAILS)} bytes`);
    // A full 600-character brief of two-byte characters plus its framing
    // sentence still fits the 8192-byte provider prompt admission.
    assert(bytes(prompt + " " + GUARDRAILS + " ".repeat(420) + JSON.stringify("é".repeat(600))) < 8192, style);
  }
});

Deno.test("no tested property is hardcoded", () => {
  assert(!/855|Central Ave|pergola|specific room|named owner/i.test(buildRealEstateStagePrompt(REAL_ESTATE_STAGE_STYLES.contemporary)));
});
