import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = resolve(import.meta.dirname, ".."), artifacts = await mkdtemp(join(tmpdir(), "rendprop-photo-delivery-browser-")), dist = join(artifacts, "dist");
const receipt = { proof: "Real photo UI, canvas JPEGs and ZIP downloads with isolated synthetic provider replies; no paid generation", checks: [], artifacts: [], externalRequests: [], errors: [] };
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
let browser, server;
function unzip(bytes) {
  const files = new Map(); let offset = 0;
  while (bytes.readUInt32LE(offset) === 0x04034b50) {
    assert.equal(bytes.readUInt16LE(offset + 8), 0);
    const size = bytes.readUInt32LE(offset + 18), nameLength = bytes.readUInt16LE(offset + 26), extra = bytes.readUInt16LE(offset + 28), start = offset + 30 + nameLength + extra;
    files.set(bytes.subarray(offset + 30, offset + 30 + nameLength).toString(), bytes.subarray(start, start + size)); offset = start + size;
  }
  return files;
}
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/creative-fixture.html") } } });
  server = createServer(async (req, res) => {
    const path = resolve(dist, `.${new URL(req.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return res.writeHead(400).end();
    try { res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); res.end(await readFile(path)); } catch { res.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block" });
  const images = {};
  await context.route("**/*", route => {
    const url = new URL(route.request().url()); if (url.origin === origin) return route.continue();
    if (url.hostname === "012345678901234567890123456789ab.r2.cloudflarestorage.com") return route.fulfill({ status: 200, contentType: "image/png", headers: { "Access-Control-Allow-Origin": "*" }, body: images[url.pathname.includes("edited") ? "red" : "blue"] });
    receipt.externalRequests.push(url.origin); return route.abort();
  });
  const page = await context.newPage(); page.setDefaultTimeout(12000); page.on("pageerror", error => receipt.errors.push(error.message));
  await page.goto(`${origin}/tests/creative-fixture.html`); await expect(page.getByText("Your saved draft is ready", { exact: true })).toBeVisible();
  for (const color of ["blue", "green", "yellow", "magenta", "red"]) {
    const b64 = await page.evaluate(color => { const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 600; const ctx = canvas.getContext("2d"); ctx.fillStyle = color; ctx.fillRect(0, 0, 800, 600); return canvas.toDataURL("image/png").split(",")[1]; }, color);
    images[color] = Buffer.from(b64, "base64");
  }
  const inspect = async bytes => page.evaluate(async b64 => {
    const bitmap = await createImageBitmap(await (await fetch(`data:image/jpeg;base64,${b64}`)).blob());
    const canvas = document.createElement("canvas"); canvas.width = bitmap.width; canvas.height = bitmap.height;
    const ctx = canvas.getContext("2d"); ctx.drawImage(bitmap, 0, 0); bitmap.close();
    return { width: canvas.width, height: canvas.height, center: [...ctx.getImageData(canvas.width / 2, canvas.height / 2, 1, 1).data], bottom: [...ctx.getImageData(canvas.width - 5, canvas.height - 5, 1, 1).data] };
  }, Buffer.from(bytes).toString("base64"));
  const response = (color, disclosure) => ({ image_b64: images[color].toString("base64"), disclosure });
  await page.evaluate(responses => window.creativeFixture.photoResponses(responses), [response("green", "Movable clutter removed with AI."), response("yellow", "Furniture digitally added with AI."), response("magenta", "Twilight generated with AI."), response("red", "Furniture digitally added with AI.")]);
  await page.locator('input[type="file"]').setInputFiles({ name: "original-room.png", mimeType: "image/png", buffer: images.blue });
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Continue editing this result", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: /^Staging\s+Add/ }).click();
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Continue editing this result", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: /^Make it twilight\s+Warm/ }).click();
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Continue editing this result", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: /^Staging\s+Add/ }).click();
  await expect(page.getByText("Restyling starts from this pre-staging image. Changes made after staging are not included in the new version.", { exact: true })).toBeVisible();
  const stageBasePixels = await inspect(Buffer.from((await page.getByAltText("Pre-staging input for new style", { exact: true }).getAttribute("src")).split(",")[1], "base64"));
  assert.ok(stageBasePixels.center[1] > 110 && stageBasePixels.center[0] < 10, "user sees the actual green pre-stage input");
  await page.getByRole("group", { name: "Staging style", exact: true }).getByRole("button", { name: "Rustic", exact: true }).click();
  await page.getByRole("button", { name: "Generate preview", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review your edit", exact: true })).toBeVisible();
  const calls = await page.evaluate(() => window.creativeFixture.calls()), generations = calls.filter(c => c.path.endsWith("ai-photo") && c.body.edit !== "suggest");
  assert.deepEqual(generations.map(c => c.body.edit), ["declutter", "stage", "twilight", "stage"]);
  const inputPixels = await Promise.all(generations.map(c => inspect(Buffer.from(c.body.image_b64, "base64"))));
  assert.ok(inputPixels[0].center[2] > 240 && inputPixels[0].center[0] < 10, "first edit starts with original blue pixels");
  assert.ok(inputPixels[2].center[0] > 240 && inputPixels[2].center[1] > 240 && inputPixels[2].center[2] < 10, "twilight receives the actual yellow staged photo");
  for (const pixels of [inputPixels[1], inputPixels[3]]) assert.ok(pixels.center[1] > 110 && pixels.center[0] < 10 && pixels.center[2] < 10, "stage and restyle use green decluttered pixels");
  const uploads = await page.evaluate(() => window.creativeFixture.uploadedFiles());
  assert.equal(uploads.length, 1); assert.equal(uploads[0].sha256, hash(images.blue));
  assert.equal(new Set(generations.map(c => c.body.original_asset_id)).size, 1);
  receipt.checks.push("Declutter → stage → twilight → restyle previews and sends the correct current/pre-stage pixels while retaining one immutable original");
  const review = page.locator("section").filter({ has: page.getByRole("heading", { name: "Review your edit", exact: true }) }).last();
  await review.getByRole("button", { name: "Download photo", exact: true }).click();
  const panel = review.getByRole("region", { name: "Download photos", exact: true });
  async function download(panel, name) {
    await expect(panel.getByRole("button", { name: "Download photo package", exact: true })).toBeEnabled();
    const next = page.waitForEvent("download"); await panel.getByRole("button", { name: "Download photo package", exact: true }).click();
    const artifact = await next, path = join(artifacts, name); await artifact.saveAs(path); const bytes = await readFile(path);
    receipt.artifacts.push({ path: name, bytes: bytes.length, sha256: hash(bytes) }); return unzip(bytes);
  }
  const clean = await download(panel, "mls.zip"), cleanProof = JSON.parse(clean.get("provenance.json")), cleanRecord = cleanProof.files[0];
  assert.deepEqual(clean.get(cleanRecord.original.path), images.blue);
  assert.equal(cleanRecord.original.sha256, hash(images.blue));
  assert.equal(cleanRecord.editedSHA256, hash(clean.get(cleanRecord.editedPath)));
  const cleanPixels = await inspect(clean.get(cleanRecord.editedPath));
  assert.deepEqual([cleanPixels.width, cleanPixels.height], [800, 600]);
  assert.ok(cleanPixels.bottom[0] > 240 && cleanPixels.bottom[1] < 10, "MLS has no dark label overlay");
  assert.match(clean.get("captions.txt").toString(), /Movable clutter removed with AI/); assert.match(clean.get("captions.txt").toString(), /Furniture digitally added with AI/);
  assert.equal(cleanRecord.visibleLabel, null); assert.equal(cleanProof.publicOriginalURL, null);
  assert.ok(!clean.get("captions.txt").toString().includes("Twilight"), "restyle disclosure must not claim a later edit excluded from its actual input");
  await panel.getByRole("combobox", { name: "Photo shape", exact: true }).selectOption("16:9");
  const wide = await download(panel, "mls-wide.zip"), wideRecord = JSON.parse(wide.get("provenance.json")).files[0], widePixels = await inspect(wide.get(wideRecord.editedPath));
  assert.deepEqual([widePixels.width, widePixels.height], [800, 450]); assert.equal(wideRecord.crop.y, 75);
  assert.deepEqual(wide.get(wideRecord.original.path), images.blue);
  receipt.checks.push("MLS ZIP contains a full-size clean JPEG, byte-exact original, cumulative captions and independently checked SHA-256 hashes");
  await panel.getByRole("button", { name: "Zillow / web", exact: true }).click();
  await panel.getByRole("combobox", { name: "Photo shape", exact: true }).selectOption("4:5");
  const web = await download(panel, "web-crop.zip"), webRecord = JSON.parse(web.get("provenance.json")).files[0], webPixels = await inspect(web.get(webRecord.editedPath));
  assert.deepEqual([webPixels.width, webPixels.height], [480, 600]); assert.ok(webPixels.center[0] > 240 && webPixels.bottom[0] < 60);
  assert.equal(webRecord.crop.x, 160); assert.match(webRecord.visibleLabel, /Digitally decluttered.*Virtually staged/); assert.ok(!webRecord.visibleLabel.includes("twilight"));
  assert.deepEqual(web.get(webRecord.original.path), images.blue);
  const previewPixels = await page.evaluate(async () => { const img = [...document.querySelectorAll('.photo-delivery img')].at(-1); const bytes = await (await fetch(img.src)).arrayBuffer(); return [...new Uint8Array(bytes)]; });
  assert.equal(hash(Buffer.from(previewPixels)), hash(web.get(webRecord.editedPath)), "preview is the exact JPEG generated for download");
  receipt.checks.push("Web center crop produces 480×600 pixels with visible cumulative disclosure; preview and download match while original remains 800×600");

  await review.getByRole("button", { name: "Save to property gallery", exact: true }).click();
  await expect(review.getByRole("button", { name: "Saved to gallery", exact: true })).toBeDisabled();
  const savedPhoto = await page.evaluate(() => window.creativeFixture.calls().filter(call => call.path.endsWith("studio/photos")).at(-1));
  assert.match(savedPhoto.body.caption, /Movable clutter removed/); assert.ok(!savedPhoto.body.caption.includes("Twilight"));
  const org = "22222222-2222-4222-8222-222222222222", listing = "33333333-3333-4333-8333-333333333333", other = "33333333-3333-4333-8333-333333333334";
  const mediaURL = name => `https://012345678901234567890123456789ab.r2.cloudflarestorage.com/rendprop-renders/renders/${org}/${listing}/${name}.png?X-Amz-Signature=fixture`;
  const legacy = { id: "44444444-4444-4444-8444-444444444445", listingId: listing, url: mediaURL("edited"), originalUrl: mediaURL("source"), isAltered: true, isStaged: true, expiresAt: "2099-01-01T00:00:00Z", caption: "Earlier furniture edit.", sort: 1 };
  await page.evaluate(photos => window.creativeFixture.photos(photos), [legacy, { ...legacy, id: "44444444-4444-4444-8444-444444444446", originalUrl: null, caption: "Original unavailable." }]);
  await page.getByRole("combobox", { name: "Property", exact: true }).selectOption(other); await page.getByRole("combobox", { name: "Property", exact: true }).selectOption(listing);
  await page.getByRole("combobox", { name: "Source property photo", exact: true }).selectOption(legacy.id);
  await expect(page.getByAltText("Paired source to verify", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Generate preview", exact: true })).toBeDisabled();
  await page.locator(".creative-source").getByRole("button", { name: "Download photo", exact: true }).click();
  const legacyPanel = page.locator(".creative-source .photo-delivery");
  const unverified = await download(legacyPanel, "legacy-unverified.zip");
  assert.equal(JSON.parse(unverified.get("provenance.json")).files[0].original, null); assert.match(unverified.get("captions.txt").toString(), /history is unverified/);
  await legacyPanel.getByText("Review the paired source", { exact: true }).click();
  await legacyPanel.getByRole("checkbox").check();
  const reviewed = await download(legacyPanel, "legacy-reviewed.zip"), reviewedRecord = JSON.parse(reviewed.get("provenance.json")).files[0];
  assert.deepEqual(reviewed.get(reviewedRecord.original.path), images.blue);
  await page.getByRole("combobox", { name: "Source property photo", exact: true }).selectOption("44444444-4444-4444-8444-444444444446");
  await expect(page.locator(".creative-source .photo-delivery").getByText(/paired original is unavailable/)).toBeVisible();
  const missing = await download(page.locator(".creative-source .photo-delivery"), "legacy-missing-original.zip");
  assert.equal(JSON.parse(missing.get("provenance.json")).files[0].original, null);
  assert.ok([...missing.keys()].some(path => path.endsWith("edited.jpg")));
  receipt.checks.push("Legacy edited photos remain downloadable with unverified history; separate source is included only after review, and switching to a missing original cannot reuse confirmation");

  const batch = page.getByRole("region", { name: "Edit several photos", exact: true });
  await batch.getByRole("checkbox", { name: legacy.caption, exact: true }).check();
  await batch.getByText(`Verify the original for ${legacy.caption}`, { exact: true }).click(); await batch.getByRole("checkbox", { name: "This is the actual unedited original.", exact: true }).check();
  await page.evaluate(responses => window.creativeFixture.photoResponses(responses), [response("green", "Movable clutter removed with AI.")]);
  await batch.getByRole("button", { name: "Generate 1 photo previews", exact: true }).click(); await expect(batch.getByText("Review your preview", { exact: true })).toBeVisible();
  const batchCall = await page.evaluate(() => window.creativeFixture.calls().filter(c => c.path.endsWith("ai-photo")).at(-1));
  const batchInput = await inspect(Buffer.from(batchCall.body.image_b64, "base64")); assert.ok(batchInput.center[0] > 240 && batchInput.center[2] < 10);
  assert.equal((await page.evaluate(() => window.creativeFixture.uploadedFiles())).at(-1).sha256, hash(images.blue));
  await batch.getByRole("button", { name: "Download photo", exact: true }).first().click();
  const batchZip = await download(batch.getByRole("region", { name: "Download photos", exact: true }), "batch.zip");
  assert.match(batchZip.get("captions.txt").toString(), /Earlier furniture edit/); assert.match(batchZip.get("captions.txt").toString(), /Movable clutter removed/);
  receipt.checks.push("Batch editing sends the current edited pixels, uploads the separate original and exports cumulative disclosure");
  await page.screenshot({ path: join(artifacts, "photo-delivery-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 2));
  await batch.getByRole("region", { name: "Download photos", exact: true }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: join(artifacts, "photo-delivery-mobile.png") }); receipt.checks.push("Photo review/download layout fits a 390px viewport without horizontal overflow");
  const guarded = batch.getByRole("region", { name: "Download photos", exact: true });
  await page.evaluate(() => { const actual = HTMLCanvasElement.prototype.toBlob; HTMLCanvasElement.prototype.toBlob = function (...args) { window.photoExportHeld = true; window.releasePhotoExport = () => actual.apply(this, args); }; });
  let downloadsAfterAccountChange = 0; page.on("download", () => downloadsAfterAccountChange++);
  await guarded.getByRole("button", { name: "Download photo package", exact: true }).click();
  await page.waitForFunction(() => window.photoExportHeld);
  await page.evaluate(() => { window.creativeFixture.changeIdentity(); window.releasePhotoExport(); });
  await expect(guarded.getByRole("alert")).toContainText("account"); assert.equal(downloadsAfterAccountChange, 0);
  receipt.checks.push("Identity changes while the actual canvas JPEG is encoding refuse the download");
  assert.deepEqual(receipt.externalRequests, []); assert.deepEqual(receipt.errors, []);
  receipt.sourceHashes = Object.fromEntries(await Promise.all(["src/features/creative/photo-lineage.ts", "src/features/creative/photo-export.ts", "src/features/creative/PhotoExportPanel.tsx", "src/features/creative/CreativeWorkspace.tsx", "src/features/creative/BatchPhotoStudio.tsx", "tests/photo-delivery-browser.mjs"].map(async path => [path, hash(await readFile(join(root, path)))])));
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({ ...receipt, artifacts }, null, 2));
} catch (error) { console.error(JSON.stringify({ ...receipt, artifacts, error: error.stack }, null, 2)); throw error; }
finally { await browser?.close(); await new Promise(done => server?.close(done) ?? done()); }
