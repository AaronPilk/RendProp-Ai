import { assert } from "https://deno.land/std@0.224.0/assert/mod.ts";

Deno.test("release disables new Topaz choice while preserving Smooth rendering", async () => {
  const availability = await Deno.readTextFile(new URL("../../../../apps/ios/Rendprop/Support/LaunchFeatureAvailability.swift", import.meta.url));
  const review = await Deno.readTextFile(new URL("../../../../apps/ios/Rendprop/Screens/ReviewSubmitView.swift", import.meta.url));
  const coordinator = await Deno.readTextFile(new URL("../../../../apps/ios/Rendprop/RendpropApp.swift", import.meta.url));
  assert(availability.includes("static let canUseTopaz = false"));
  assert(review.includes("guard LaunchFeatureAvailability.canUseTopaz else { return true }"));
  assert(review.includes("AI enhancement is temporarily unavailable. Smooth rendering runs on your phone."));
  assert(review.includes("guard t.usesServerAI else"), "Local Smooth tier remains selectable");
  assert(review.includes("Temporarily unavailable"), "Unavailable tiers are not advertised as a Team plan upgrade");
  assert(coordinator.includes("guard LaunchFeatureAvailability.canUseTopaz else {\n            setNote(id, run"), "Saved enhancement tiers skip upload before server fallback");
});
