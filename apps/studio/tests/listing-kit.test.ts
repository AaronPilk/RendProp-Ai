import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { archivePath, createStoredZip, KIT_MAX_BYTES, KIT_MAX_FILE_BYTES } from "../src/features/listings/kit-archive";
import { buildKit, kitText, loadKit } from "../src/features/listings/delivery-kit";
import { createTourQR } from "../src/features/listings/qr";
import { kitFixture, listingA, listingB, png, workspace } from "./kit-fixtures";
test("ZIP opens with system unzip and retains exact UTF-8 and binary files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "rendprop-kit-archive-"));
  const blob = await createStoredZip([{ path: "photos/kitchen.png", bytes: png }, { path: "café.txt", bytes: new TextEncoder().encode("Exact saved caption\nこんにちは") }]);
  const zip = join(dir, "kit.zip"); await writeFile(zip, Buffer.from(await blob.arrayBuffer()));
  assert.match(execFileSync("unzip", ["-t", zip], { encoding: "utf8" }), /No errors detected/);
  assert.deepEqual(execFileSync("unzip", ["-p", zip, "photos/kitchen.png"]), Buffer.from(png));
  execFileSync("python3", ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.read('café.txt').decode() == 'Exact saved caption\\nこんにちは'", zip]);
});
test("ZIP refuses unsafe names, duplicate aliases and size limits before packing", async () => {
  for (const path of ["../a", "/a", "a/../b", "a\\b", "a//b", "CON.txt", "a:", 'x".png', "x?.png", "x*.png", "trailing. "]) assert.throws(() => archivePath(path));
  const entry = (path: string, size = 1) => ({ path, bytes: new Uint8Array(size) });
  await assert.rejects(createStoredZip([entry("a.txt"), entry("A.txt")]));
  await assert.rejects(createStoredZip([entry("a", KIT_MAX_FILE_BYTES + 1)]));
  const half = new Uint8Array(KIT_MAX_BYTES / 2); await assert.rejects(createStoredZip([{ path: "a", bytes: half }, { path: "b", bytes: half }, entry("c")]));
});
test("ZIP can cancel before and during packing", async () => {
  const before = new AbortController(); before.abort(); await assert.rejects(createStoredZip([{ path: "a", bytes: png }], before.signal));
  const during = new AbortController(); const promise = createStoredZip([{ path: "a", bytes: new Uint8Array(8 * 1024 * 1024) }], during.signal); setTimeout(() => during.abort(), 0); await assert.rejects(promise);
});
test("catalog pairs altered originals, excludes unreviewed outputs, preserves actual published links and saved copy", async () => {
  const f = kitFixture(), snapshot = await loadKit(f.services, workspace, listingA, new AbortController().signal);
  assert.equal(snapshot.items.length, 3); assert.equal(snapshot.excluded.length, 2); assert.equal(snapshot.items[1].originalLabel, "Paired original");
  assert.equal(snapshot.items[2].originalUrl, null); assert.equal(snapshot.published?.slug, "fixture-live-property"); assert.match(snapshot.script, /Saved listing script/);
  assert(f.calls.every(call => call.method === "GET"));
  const other = await loadKit(f.services, workspace, listingB, new AbortController().signal); assert.equal(other.published, null); assert.equal(other.items.length, 0);
});
test("downloaded kit has exact originals, escaped HTML and redacted private data with no expiring URLs", async () => {
  const f = kitFixture(), signal = new AbortController().signal, snapshot = await loadKit(f.services, workspace, listingA, signal);
  const requests: RequestInit[] = [];
  const kit = await buildKit(snapshot, snapshot.items.filter(item => item.kind === "photo").map(item => item.id), { services: f.services, workspace, signal, progress: () => {}, fetcher: async (_url, options) => { requests.push(options!); return new Response(png, { headers: { "content-type": "image/png" } }); } });
  const dir = await mkdtemp(join(tmpdir(), "rendprop-kit-content-")), zip = join(dir, kit.filename); await writeFile(zip, Buffer.from(await kit.blob.arrayBuffer()));
  execFileSync("unzip", ["-q", zip, "-d", join(dir, "opened")]);
  const manifest = JSON.parse(await readFile(join(dir, "opened/manifest.json"), "utf8")); assert.equal(manifest.files.length, 2);
  assert.deepEqual(await readFile(join(dir, "opened", manifest.files[1].originalPath)), Buffer.from(png));
  const html = await readFile(join(dir, "opened/START-HERE.html"), "utf8"); assert(html.includes("&lt;script&gt;")); assert(!html.includes("<script>"));
  const script = await readFile(join(dir, "opened/saved-script.txt"), "utf8"); assert(!script.includes("access_token")); assert(script.includes("[private link omitted]"));
  assert(!JSON.stringify(manifest).includes("X-Amz")); assert(!JSON.stringify(manifest).includes("MUST-NOT-EXPORT"));
  assert(requests.every(options => options.cache === "no-store" && options.credentials === "omit" && options.redirect === "error" && options.referrerPolicy === "no-referrer"));
});
test("published kit exports one verified address URL consistently across links, manifest, HTML and QR", async () => {
  const f = kitFixture(), signal = new AbortController().signal;
  const snapshot = await loadKit(f.services, workspace, listingA, signal);
  const slug = "fixture-live-property", endpoint = `https://rendprop.com/f/${slug}/share-link`;
  const branded = `https://rendprop.com/property/10-oak-street/20260922.${slug}`;
  let requested = 0;
  const kit = await buildKit(snapshot, [], { services: f.services, workspace, signal, progress: () => {}, shareFetcher: async (input, init) => {
    requested++; assert.equal(input, endpoint); assert.equal(init?.credentials, "omit");
    const result = new Response(JSON.stringify({ url: branded, address_only: false }), { headers: { "content-type": "application/json" } });
    Object.defineProperty(result, "url", { value: endpoint });
    return result;
  } });
  assert.equal(requested, 1);
  const dir = await mkdtemp(join(tmpdir(), "rendprop-address-kit-")), zip = join(dir, kit.filename);
  await writeFile(zip, Buffer.from(await kit.blob.arrayBuffer()));
  const readZip = (name: string) => execFileSync("unzip", ["-p", zip, name], { encoding: "utf8" });
  assert.match(readZip("sharing-links.txt"), new RegExp(branded.replaceAll(".", "\\.")));
  assert.match(readZip("sharing-links.txt"), new RegExp(`https://rendprop.com/u/${slug}`));
  assert.deepEqual(JSON.parse(readZip("manifest.json")).publishedLinks, { branded, unbranded: `https://rendprop.com/u/${slug}` });
  assert.ok(readZip("START-HERE.html").includes(`href="${branded}"`));
  assert.equal(readZip("sharing/marketing-qr.svg"), await createTourQR(slug, "branded", { links: { branded, unbranded: `https://rendprop.com/u/${slug}` }, verified: true, addressOnly: false }));
});
test("authoritative not_found omits revoked tour links and QR from the listing kit", async () => {
  const f = kitFixture(), signal = new AbortController().signal;
  const snapshot = await loadKit(f.services, workspace, listingA, signal);
  const endpoint = "https://rendprop.com/f/fixture-live-property/share-link";
  const missing = new Response(JSON.stringify({ error: "not_found" }), { status: 404, headers: { "content-type": "application/json" } });
  Object.defineProperty(missing, "url", { value: endpoint });
  const kit = await buildKit(snapshot, [], { services: f.services, workspace, signal, progress: () => {}, shareFetcher: async () => missing });
  const dir = await mkdtemp(join(tmpdir(), "rendprop-revoked-kit-")), zip = join(dir, kit.filename);
  await writeFile(zip, Buffer.from(await kit.blob.arrayBuffer()));
  const names = execFileSync("unzip", ["-Z1", zip], { encoding: "utf8" });
  assert(!names.includes("sharing/")); assert(!names.includes("sharing-links.txt"));
  const manifest = JSON.parse(execFileSync("unzip", ["-p", zip, "manifest.json"], { encoding: "utf8" }));
  assert.equal(manifest.publishedLinks, null);
  assert.match(execFileSync("unzip", ["-p", zip, "START-HERE.html"], { encoding: "utf8" }), /No published tour was available/);
});
test("a late address response cannot finish an export after the account changes", async () => {
  const f = kitFixture(), signal = new AbortController().signal;
  const snapshot = await loadKit(f.services, workspace, listingA, signal);
  let release!: (response: Response) => void;
  let requestStarted!: () => void;
  const started = new Promise<void>(resolve => { requestStarted = resolve; });
  const pending = buildKit(snapshot, [], { services: f.services, workspace, signal, progress: () => {}, shareFetcher: async () => {
    requestStarted(); return new Promise<Response>(resolve => { release = resolve; });
  } });
  await started;
  f.changeAccount();
  const endpoint = "https://rendprop.com/f/fixture-live-property/share-link";
  const result = new Response(JSON.stringify({ url: "https://rendprop.com/property/10-oak-street/20260922.fixture-live-property", address_only: false }));
  Object.defineProperty(result, "url", { value: endpoint }); release(result);
  await assert.rejects(pending, /account changed/i);
});
test("failed, oversized, malformed or cross-account download cannot return a kit", async () => {
  const f = kitFixture(), controller = new AbortController(), snapshot = await loadKit(f.services, workspace, listingA, controller.signal), selected = [snapshot.items[0].id];
  const options = { services: f.services, workspace, signal: controller.signal, progress: () => {} };
  await assert.rejects(buildKit(snapshot, selected, { ...options, fetcher: async () => new Response("missing", { status: 404 }) }));
  await assert.rejects(buildKit(snapshot, selected, { ...options, fetcher: async () => new Response(png, { headers: { "content-length": String(KIT_MAX_FILE_BYTES + 1) } }) }));
  await assert.rejects(buildKit(snapshot, selected, { ...options, fetcher: async () => new Response("<html>Not an image</html>", { headers: { "content-type": "image/png" } }) }));
  let dispatched = false; f.changeAccount(); await assert.rejects(buildKit(snapshot, selected, { ...options, fetcher: async () => { dispatched = true; return new Response(png); } })); assert.equal(dispatched, false);
  assert.equal(kitText("https://x.invalid/?X-Amz-Signature=abc"), "[private link omitted]");
  assert.equal(kitText("https://uploads.rendprop.com/v2/fixture?expires=123&signature=abc"), "[private link omitted]");
});
test("delayed old-account catalog and mismatched same-property file identity are rejected", async () => {
  const f = kitFixture(); f.delayRead(); const promise = loadKit(f.services, workspace, listingA, new AbortController().signal); await new Promise(resolve => setTimeout(resolve, 0)); f.changeAccount(); f.releaseRead(); await assert.rejects(promise);
  const other = kitFixture(), read = other.services.listMedia; other.services.listMedia = async (...args) => { const media = await read(...args); return { ...media, photos: media.photos.map((row, index) => index ? row : { ...row, url: media.photos[1].url }) }; };
  await assert.rejects(loadKit(other.services, workspace, listingA, new AbortController().signal), /no longer matches/);
});
