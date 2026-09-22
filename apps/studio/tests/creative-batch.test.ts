import assert from "node:assert/strict";
import test from "node:test";
import { PhotoBatch, batchEligible, MAX_BATCH_PHOTOS } from "../src/features/creative/BatchPhotoStudio";
import type { BatchPhotoEntry } from "../src/features/creative/BatchPhotoStudio";
import type { StudioPhoto } from "../src/data/contracts";
import type { UploadJournal } from "../src/features/listings/uploads";
import { StudioError } from "../src/data/config";

const listingId = "11111111-1111-4111-8111-111111111111";
const originalId = "22222222-2222-4222-8222-222222222222";
const outputId = "33333333-3333-4333-8333-333333333333";
const proofId = "44444444-4444-4444-8444-444444444444";
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
const choice = { edit: "declutter" as const, style: "modern", prompt: "" };
const photos = (count = 3): StudioPhoto[] => Array.from({ length: count }, (_, index) => ({ id: `photo-${index + 1}`, listingId, url: `https://media.example.invalid/photo-${index + 1}.png`, expiresAt: "2026-09-14T23:59:59Z", caption: `Photo ${index + 1}`, isStaged: false, sort: index }));
function deferred<T = void>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
function fixture() {
  let current = true;
  const events: string[] = [], keys: string[] = [], resumeValues: (UploadJournal | undefined)[] = [];
  const deps = {
    assertScope: () => { if (!current) throw new Error("Account changed"); },
    prepare: async (photo: StudioPhoto) => { events.push(`prepare:${photo.id}`); return { file: new File([photo.id], `${photo.id}.jpg`, { type: "image/jpeg" }), base64: "c291cmNl", mime: "image/jpeg" as const, preview: "data:image/jpeg;base64,c291cmNl" }; },
    upload: async (file: File, role: "original" | "gallery", _signal: AbortSignal, resume?: UploadJournal, onJournal?: (journal: UploadJournal) => void) => {
      events.push(`upload:${role}:${file.name}`); resumeValues.push(resume);
      if (onJournal) onJournal({ version: 1, operationId: "same-operation" } as UploadJournal);
      return { assetId: role === "original" ? originalId : outputId, storageKey: `renders/${role}.png`, contentType: "image/png", kind: "photo" as const, durationSeconds: null };
    },
    generate: async (_source: unknown, original: string, _choice: unknown, key: string, caption: string) => { assert.equal(original, originalId); events.push(`generate:${caption}`); keys.push(key); return { image_b64: png, mime: "image/png", disclosure: "AI altered. Original retained.", provenance: { recorded: true, id: proofId } }; },
    attach: async (entry: BatchPhotoEntry) => { events.push(`attach:${entry.photo.id}`); assert.equal(entry.output?.assetId, outputId); assert.equal(entry.result?.originalAssetId, originalId); assert.equal(entry.result?.provenanceId, proofId); },
  };
  return { deps, events, keys, resumeValues, changeIdentity: () => { current = false; } };
}

test("batch keeps originals and disclosure through explicit review/save; duplicate start never re-dispatches", async () => {
  const f = fixture(), batch = new PhotoBatch(photos(), listingId, choice, f.deps);
  await Promise.all([batch.run(), batch.run()]);
  assert.deepEqual(batch.entries.map(e => e.state), ["ready", "ready", "ready"]);
  assert.equal(f.keys.length, 3); assert.equal(new Set(f.keys).size, 3);
  assert.ok(f.keys.every(key => key.length <= 128));
  assert.equal(f.events.filter(e => e.startsWith("attach")).length, 0, "generation must not publish unreviewed results");
  for (let i = 0; i < 3; i++) {
    const prepareAt = f.events.indexOf(`prepare:photo-${i + 1}`), generationAt = f.events.indexOf(`generate:Photo ${i + 1}`);
    assert.ok(prepareAt < generationAt);
    assert.match(f.events[generationAt - 1]!, /^upload:original:/);
  }
  await batch.save(0); await batch.save(0); await batch.run();
  assert.equal(batch.entries[0]?.state, "saved"); assert.equal(f.keys.length, 3);
  assert.equal(f.events.filter(e => e.startsWith("attach")).length, 1);
});

test("ordinary generation failure preserves completed photos and continues without retrying the failed request", async () => {
  const f = fixture(), generate = f.deps.generate;
  f.deps.generate = async (...args) => { if (args[4] === "Photo 2") { f.events.push("failed:Photo 2"); throw new Error("Reply was lost"); } return generate(...args); };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps);
  await batch.run(); await batch.run();
  assert.deepEqual(batch.entries.map(e => e.state), ["ready", "failed", "ready"]);
  assert.equal(f.events.filter(e => e === "failed:Photo 2").length, 1);
  assert.match(batch.entries[1]!.error!, /may still count/);
  await batch.save(2); assert.equal(batch.entries[2]?.state, "saved");
});

test("quota or authorization failure stops all remaining paid dispatches", async () => {
  for (const status of [401, 402, 403, 429]) {
    const f = fixture(); let calls = 0;
    f.deps.generate = async () => { calls++; throw new StudioError("request-failed", "Try later", status); };
    const batch = new PhotoBatch(photos(), listingId, choice, f.deps);
    await batch.run();
    assert.equal(calls, 1);
    assert.deepEqual(batch.entries.map(e => e.state), ["failed", "stopped", "stopped"]);
  }
});

test("stop during active generation keeps its preview and never sends the next photo", async () => {
  const f = fixture(), wait = deferred(), entered = deferred(), generate = f.deps.generate;
  f.deps.generate = async (...args) => { entered.resolve(); await wait.promise; return generate(...args); };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps), running = batch.run();
  await entered.promise; batch.stop(); wait.resolve(); await running;
  assert.deepEqual(batch.entries.map(e => e.state), ["ready", "stopped", "stopped"]);
  assert.equal(f.keys.length, 1); await batch.save(0); assert.equal(batch.entries[0]?.state, "saved");
});

test("stop while preparing source prevents every AI call", async () => {
  const f = fixture(), wait = deferred(), entered = deferred(), prepare = f.deps.prepare;
  f.deps.prepare = async (...args) => { entered.resolve(); await wait.promise; return prepare(...args); };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps), running = batch.run();
  await entered.promise; batch.stop(); wait.resolve(); await running;
  assert.equal(f.keys.length, 0); assert.deepEqual(batch.entries.map(e => e.state), ["stopped", "stopped", "stopped"]);
});

test("identity switch after source preparation prevents upload and paid dispatch", async () => {
  const f = fixture(), prepare = f.deps.prepare;
  f.deps.prepare = async (...args) => { const result = await prepare(...args); f.changeIdentity(); return result; };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps);
  await assert.rejects(batch.run(), /Account changed/);
  assert.equal(f.events.filter(e => e.startsWith("upload")).length, 0); assert.equal(f.keys.length, 0);
});

test("identity switch during generation cannot attach its response to another account", async () => {
  const f = fixture(), generate = f.deps.generate;
  f.deps.generate = async (...args) => { const result = await generate(...args); f.changeIdentity(); return result; };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps);
  await assert.rejects(batch.run(), /Account changed/);
  assert.equal(f.keys.length, 1); assert.equal(batch.entries[0]?.result, undefined);
  assert.equal(f.events.some(e => e.startsWith("attach")), false);
});

test("component disposal stops pending work without dispatching or committing another item", async () => {
  const f = fixture(), wait = deferred(), entered = deferred(), prepare = f.deps.prepare;
  f.deps.prepare = async (...args) => { entered.resolve(); await wait.promise; return prepare(...args); };
  const batch = new PhotoBatch(photos(), listingId, choice, f.deps), running = batch.run();
  await entered.promise; batch.dispose(); wait.resolve(); await assert.rejects(running, /abort/i);
  assert.equal(f.keys.length, 0); assert.equal(batch.busy, false);
});

test("failed gallery attachment retries with the same uploaded output and no new generation", async () => {
  const f = fixture(), attach = f.deps.attach; let attempts = 0;
  f.deps.attach = async entry => { attempts++; if (attempts === 1) throw new Error("Connection interrupted"); await attach(entry); };
  const batch = new PhotoBatch(photos(1), listingId, choice, f.deps);
  await batch.run(); await batch.save(0);
  assert.equal(batch.entries[0]?.state, "ready"); assert.match(batch.entries[0]!.error!, /does not generate/);
  await batch.save(0);
  assert.equal(batch.entries[0]?.state, "saved"); assert.equal(f.keys.length, 1);
  assert.equal(f.events.filter(e => e.startsWith("upload:gallery")).length, 1);
  assert.equal(attempts, 2);
});

test("interrupted gallery upload retains its journal so save recovery renews the original ticket", async () => {
  const f = fixture(), upload = f.deps.upload; let interrupted = false;
  f.deps.upload = async (...args) => {
    if (args[1] === "gallery" && !interrupted) { interrupted = true; args[4]?.({ version: 1, operationId: "recover-me" } as UploadJournal); throw new Error("Upload reply lost"); }
    if (args[1] === "gallery") assert.equal(args[3]?.operationId, "recover-me");
    return upload(...args);
  };
  const batch = new PhotoBatch(photos(1), listingId, choice, f.deps);
  await batch.run(); await batch.save(0); await batch.save(0);
  assert.equal(batch.entries[0]?.state, "saved"); assert.equal(f.keys.length, 1);
});

test("missing provenance retains a downloadable preview but never offers a gallery save", async () => {
  const f = fixture(), generate = f.deps.generate;
  f.deps.generate = async (...args) => ({ ...await generate(...args), provenance: { recorded: false } } as Awaited<ReturnType<typeof generate>>);
  const batch = new PhotoBatch(photos(1), listingId, choice, f.deps);
  await batch.run(); await batch.save(0);
  assert.equal(batch.entries[0]?.state, "ready"); assert.ok(batch.entries[0]?.result?.file.size);
  assert.equal(batch.entries[0]?.result?.provenanceId, null);
  assert.equal(f.events.some(e => e.startsWith("attach")), false);
});

test("selection bounds, listing scope, originals, edit and staging settings are validated before work", () => {
  const f = fixture(), original = photos(1)[0]!;
  assert.equal(batchEligible({ ...original, isAltered: true, originalUrl: null }, listingId), false);
  assert.equal(batchEligible({ ...original, isAltered: true, originalUrl: "https://media.example.invalid/original.png" }, listingId), true);
  for (const list of [[], photos(MAX_BATCH_PHOTOS + 1), [original, original], [{ ...original, listingId: "other" }], [{ ...original, isStaged: true }]]) assert.throws(() => new PhotoBatch(list, listingId, choice, f.deps), /Choose/);
  assert.throws(() => new PhotoBatch([original], listingId, { ...choice, edit: "custom", prompt: " " }, f.deps), /settings/);
  assert.throws(() => new PhotoBatch([original], listingId, { ...choice, edit: "stage", style: "invented" }, f.deps), /settings/);
  assert.equal(f.keys.length, 0);
});
