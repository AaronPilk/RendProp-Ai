import { assert, assertEquals, assertStringIncludes, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildTwilightPrompt, buildSkyPrompt, buildLawnPrompt, buildCustomEditPrompt, type PhotoSubject } from "./photo-edit-prompts.ts";
import { analyzeCustomPhotoPrompt } from "./custom-photo-prompt.ts";
import { EXTERIOR_GUARDRAILS, GUARDRAILS } from "./fairhousing.ts";

const home: PhotoSubject = { photo: "real-estate photo", exterior: "house", greenery: "the lawn: lush, healthy, vibrant green grass; remove brown/dead patches, dirt, and weeds", housing: true };
const store: PhotoSubject = { photo: "retail-store photo", exterior: "storefront", greenery: "the outdoor greenery: healthy planters, street trees and any lawn or hedges by the storefront; remove dead foliage, dirt, and weeds", housing: false };
const bytes = (text: string) => new TextEncoder().encode(text).length;

Deno.test("twilight changes the time of day and lights only what is already in the photo", () => {
  const prompt = buildTwilightPrompt(home);
  for (const text of ["as it would look at dusk, about twenty minutes after sunset", "Change the time of day and nothing else.", "deep blue overhead, fading to a soft warm orange and pink glow low on the horizon",
    "The windows that are in the photo glow warm yellow-white from inside", "A light fixture that is already visible in the photo", "Light comes only from those windows and those existing fixtures.",
    "they have exactly the fixtures they have in the photo", "If the photo was taken indoors", "every tree, shrub and planting bed in its place", "Keep the same camera position, framing and aspect ratio."]) assertStringIncludes(prompt, text);
  // The previous prompt asked for "subtle landscape/path lighting"; production
  // reviews then flagged invented path lights, uplights and wall lights.
  assert(!/landscape\/path lighting|path lighting|uplight/i.test(prompt));
});

Deno.test("sky replaces the sky area only, and lawn keeps the lawn's outline", () => {
  const sky = buildSkyPrompt(home), lawn = buildLawnPrompt(home);
  for (const text of ["Change the sky and nothing else.", "fills exactly the area the old sky fills now", "fine branches and wires stay whole in front of it", "the sun in the same direction and the existing shadows in the same places", "If the sky is visible only through a window, change it only there."]) assertStringIncludes(sky, text);
  for (const text of ["Make the lawn in this real-estate photo look healthy and well kept.", "Change the grass and nothing else.", "The lawn keeps its exact outline", "soil, mulch, gravel and paving outside the lawn stay as they are", "If no grass or planting is visible, return the photo unchanged."]) assertStringIncludes(lawn, text);
});

Deno.test("other business types keep their own nouns and their signage", () => {
  for (const prompt of [buildTwilightPrompt(store), buildSkyPrompt(store), buildLawnPrompt(store)]) {
    assertStringIncludes(prompt, "retail-store photo");
    assertStringIncludes(prompt, "the storefront's shape");
    assertStringIncludes(prompt, "signs and lettering");
  }
  assertStringIncludes(buildLawnPrompt(store), store.greenery);
  assert(!buildTwilightPrompt(home).includes("signs and lettering"));
});

Deno.test("a free-text edit carries the quoted request, the fixed-feature sentence and how the change should sit in the photo", () => {
  const idea = "remove the trash cans and turn on the porch light";
  const prompt = buildCustomEditPrompt(home, analyzeCustomPhotoPrompt(idea, "real_estate").prompt!);
  assertStringIncludes(prompt, "Edit this real-estate photo of a real property that is for sale.");
  assertStringIncludes(prompt, JSON.stringify(idea));
  assertStringIncludes(prompt, "garage-door color and finish");
  assertStringIncludes(prompt, "Everything the request does not mention stays exactly as photographed");
  assertStringIncludes(buildCustomEditPrompt(store, "Brighten it."), "a real place that is being marketed");
  for (const invalid of ["", " ", "x".repeat(6001)]) assertThrows(() => buildCustomEditPrompt(home, invalid));
});

Deno.test("subjects are bounded and every finished prompt fits the provider prompt admission with room to spare", () => {
  for (const bad of [{ ...home, photo: "" }, { ...home, exterior: "x".repeat(301) }, { ...home, greenery: "a\nb" }]) assertThrows(() => buildTwilightPrompt(bad));
  for (const subject of [home, store]) {
    for (const prompt of [buildTwilightPrompt(subject), buildSkyPrompt(subject), buildLawnPrompt(subject)]) assert(bytes(prompt + " " + EXTERIOR_GUARDRAILS) < 4096);
    const longest = analyzeCustomPhotoPrompt("é".repeat(590) + " paint it", "real_estate").prompt!;
    assert(bytes(buildCustomEditPrompt(subject, longest) + " " + GUARDRAILS) < 8192);
  }
  assertEquals(buildSkyPrompt(home), buildSkyPrompt({ ...home }), "deterministic");
});
