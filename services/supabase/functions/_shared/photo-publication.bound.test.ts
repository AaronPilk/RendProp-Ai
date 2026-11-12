import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ensureAcceptedPhotoPublication } from "./photo-publication.ts";
import { publicationFixture, publicationID } from "./photo-publication.fixture.ts";

Deno.test("an accepted listing-bound edit retains its exact source and prepared publication", async () => {
  const f = await publicationFixture({ bound: true });
  const result = await ensureAcceptedPhotoPublication(
    f.client, f.scope, f.actor, f.asset,
    { reviewed: true, expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
  );
  assertEquals(result?.id, f.pub);
  assertEquals(result?.sourceProvenanceID, f.original);
  assertEquals(result?.listingID, f.listing);
  assertEquals(f.state.phase, "prepared");
  assertEquals(f.state.writes, 1);
  assertEquals(f.state.reads.includes(f.inputKey), true);
  assertEquals(f.state.reads.includes(f.outputKey), true);
  assertEquals(f.state.calls.map(({ name }) => name).filter((name) => name.startsWith("photo_publication_")), [
    "photo_publication_target", "photo_publication_resolve", "photo_publication_reserve", "photo_publication_finish",
  ]);
});

// Owner decision, 12 Nov 2026: no review tick may block using an AI result.
// iOS build 147 sends `reviewed: false` from "set as cover" and from the first
// publication of a listing; both must publish exactly like a reviewed choice.
Deno.test("an accepted edit is published whether the client says reviewed, not reviewed, or nothing", async () => {
  for (const reviewed of [false, undefined, true]) {
    const f = await publicationFixture({ bound: true });
    const result = await ensureAcceptedPhotoPublication(
      f.client, f.scope, f.actor, f.asset,
      { ...(reviewed === undefined ? {} : { reviewed }), expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
    );
    assertEquals(result?.id, f.pub, `reviewed=${reviewed}`);
    assertEquals(result?.sourceProvenanceID, f.original);
    assertEquals(f.state.phase, "prepared");
    assertEquals(f.state.writes, 1);
    assertEquals(f.state.calls.map(({ name }) => name).filter((name) => name.startsWith("photo_publication_")), [
      "photo_publication_target", "photo_publication_resolve", "photo_publication_reserve", "photo_publication_finish",
    ]);
  }
});

Deno.test("an accepted listing-bound edit can use an uploaded original", async () => {
  const f = await publicationFixture({ bound: true, sourceBucket: "uploads" });
  const result = await ensureAcceptedPhotoPublication(
    f.client, f.scope, f.actor, f.asset,
    { reviewed: true, expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
  );
  assertEquals(result?.id, f.pub);
  assertEquals(f.state.phase, "prepared");
});

Deno.test("listing-bound publication refuses cross-listing and altered original custody", async () => {
  for (const damage of [
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.listing_id = publicationID(99); },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.root.listing_id = null; },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.original_reference!.storage_key += "-changed"; },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.original_reference!.actor_id = publicationID(99); },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { Object.assign(f.state.e.original_reference!, { bucket: "other" }); },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.original_reference!.bucket = "uploads"; },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.original_reference!.storage_key = f.state.root.original_key = `uploads/${publicationID(99)}/${f.listing}/photo.jpg`; },
    (f: Awaited<ReturnType<typeof publicationFixture>>) => { f.state.e.original_reference!.storage_key = f.state.root.original_key = `renders/${f.org}/${f.listing}/nested/photo.jpg`; },
  ]) {
    const f = await publicationFixture({ bound: true });
    damage(f);
    await assertRejects(() => ensureAcceptedPhotoPublication(
      f.client, f.scope, f.actor, f.asset,
      { reviewed: true, expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
    ));
    assertEquals(f.state.writes, 0);
    assertEquals(f.state.calls.some(({ name }) => name === "photo_publication_reserve"), false);
  }
});

Deno.test("a withdrawn upstream source cannot fall through to a fresh publication", async () => {
  const f = await publicationFixture({ bound: true });
  // The database source authority returns this when its Presenter/publication
  // ancestry walk finds a withdrawn original.
  f.state.resolveError = "RP404: This saved photo is unavailable for publication";
  await assertRejects(() => ensureAcceptedPhotoPublication(
    f.client, f.scope, f.actor, f.asset,
    { reviewed: true, expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
  ));
  assertEquals(f.state.writes, 0);
  assertEquals(f.state.calls.some(({ name }) => name === "photo_publication_reserve"), false);
});

Deno.test("library evidence still uses the established NULL-listing publication path", async () => {
  const f = await publicationFixture();
  const result = await ensureAcceptedPhotoPublication(
    f.client, f.scope, f.actor, f.asset,
    { reviewed: true, expected: { sha256: f.outputSHA, bytes: f.output.length } }, f.io,
  );
  assertEquals(result?.id, f.pub);
  assertEquals(f.state.phase, "prepared");
});
