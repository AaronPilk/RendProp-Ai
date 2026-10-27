import { assert } from "https://deno.land/std@0.224.0/assert/mod.ts";

Deno.test("iOS closes only the local aerial extra route and retains accepted opening first in the server recipe", async () => {
  const source = await Deno.readTextFile(new URL("../../../../apps/ios/Rendprop/Screens/FlythroughDetailView.swift", import.meta.url));
  const studio = source.slice(source.indexOf("struct ReelStudioView"));
  const card = studio.slice(studio.indexOf("private var clipsCard: some View"), studio.indexOf("private var generateTitle:"));
  assert(!card.includes("selectedExtras.append"), "Legacy local aerial extras must not be selectable");
  assert(card.includes("Older clips on this phone cannot be added"));
  assert(studio.includes("private var canGenerate: Bool { selectedExtras.isEmpty"));
  assert(studio.includes("guard phase == .setup, canGenerate, selectedExtras.isEmpty else { return }"));
  assert(studio.includes("private var chosenOpening: PropertyVideoAcceptedOpening?"));
  assert(studio.includes("opening: frozenOpening?.reference"), "Accepted opening stays in the server recipe");
  assert(studio.includes("var clipURLs: [URL] = extras"), "Saved recovery code remains available for old jobs");
});
