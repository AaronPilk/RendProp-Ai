import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { internalAerialMediaPatterns, isInternalAerialMedia } from "../_shared/property-media-purpose.ts";
import { assertOrdinaryRecordedMedia } from "./internal-media.ts";

const id = (n: number) => `e7000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const scope = { orgId: id(1), listingId: id(2) };
const root = `renders/${scope.orgId}/${scope.listingId}/`;
const clip = id(3);

Deno.test("allocated aerial objects remain typed, including accepted opening and review frames", () => {
  const aerial = [
    `aerial-input/${clip}.jpg`,
    `aerial-provider/${clip}.mp4`,
    `aerial-opening/${clip}.mp4`,
    `aerial-opening/${clip}.jpg`,
    `aerial-review/${clip}/frame-0.jpg`,
    `aerial-review/${clip}/frame-60.jpg`,
    `aerial-review/${clip}/frame-119.jpg`,
    `aerial-review/${clip}/frame-120.jpg`,
  ];
  assertEquals(internalAerialMediaPatterns(scope), ["aerial-input", "aerial-provider", "aerial-opening", "aerial-review"].map(tree => `${root}${tree}/%`));
  for (const suffix of aerial) {
    assert(isInternalAerialMedia(root + suffix, scope));
    assertThrows(() => assertOrdinaryRecordedMedia({ listing_id: scope.listingId, storage_key: root + suffix }, scope), HttpError);
  }
});

Deno.test("ordinary media stays available and aerial classification is scoped to its property", () => {
  for (const key of [
    `${root}walkthrough.mp4`, `${root}first-clip.jpg`,
    `${root}aerial-opening/not-allocated.mp4`,
    `renders/${id(9)}/${scope.listingId}/aerial-opening/${clip}.mp4`,
  ]) {
    assertEquals(isInternalAerialMedia(key, scope), false);
    assertOrdinaryRecordedMedia({ listing_id: scope.listingId, storage_key: key }, scope);
  }
  assertEquals(isInternalAerialMedia(`${root}aerial-opening/${clip}.mp4\n`, scope), false);
  assertThrows(() => assertOrdinaryRecordedMedia({ listing_id: id(9), storage_key: `${root}walkthrough.mp4` }, scope), HttpError);
});
