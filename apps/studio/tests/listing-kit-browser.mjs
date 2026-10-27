import { verifyPrivateKitCache } from "./listing-kit-cache-browser.mjs";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { crc32 } from "node:zlib";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";
const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-listing-kit-browser-")), dist = join(artifacts, "dist");
const receipt = { proof: "Actual ListingWorkflow and listing-kit UI, generated media, system-unzipped browser downloads; isolated fixture only, no production or paid calls.", checks: [], externalRequests: [], errors: [] };
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==", "base64");
const publicationSlug = "fixture-live-property";
const addressLink = `https://rendprop.com/property/10-oak-street/20260922.${publicationSlug}`;
let addressLookups = 0;
const KIT_MAX_FILE_BYTES = 128 * 1024 * 1024, OVERSIZE_COPY = "This kit exceeds its download size. Choose fewer files, or download a large video separately.";
/** Independent ZIP reader (no archive dependency): walks the end-of-central-directory record and every central-directory header of a saved download. */
function readZipDirectory(buffer) {
  const eocd = buffer.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06])); assert(eocd >= 0, "end of central directory record missing");
  const count = buffer.readUInt16LE(eocd + 10), size = buffer.readUInt32LE(eocd + 12), start = buffer.readUInt32LE(eocd + 16); assert.equal(buffer.readUInt16LE(eocd + 8), count);
  const entries = []; let offset = start;
  for (let index = 0; index < count; index++) {
    assert.equal(buffer.readUInt32LE(offset), 0x02014b50, `central directory header ${index} missing`);
    const method = buffer.readUInt16LE(offset + 10), crc = buffer.readUInt32LE(offset + 16), compressed = buffer.readUInt32LE(offset + 20), uncompressed = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28), extraLength = buffer.readUInt16LE(offset + 30), commentLength = buffer.readUInt16LE(offset + 32), local = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLength).toString("utf8");
    assert.equal(buffer.readUInt32LE(local), 0x04034b50, `${name}: local header missing`);
    const dataStart = local + 30 + buffer.readUInt16LE(local + 26) + buffer.readUInt16LE(local + 28);
    entries.push({ name, method, crc, compressed, uncompressed, bytes: method === 0 ? buffer.subarray(dataStart, dataStart + compressed) : null });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  assert.equal(offset - start, size); return entries;
}
let browser, server, page, mode = "normal", held = [], downloads = [];
try {
  receipt.cache = await verifyPrivateKitCache({ root, artifacts: join(artifacts, "cache-regression"), executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  receipt.checks.push("Actual Kit bypasses non-CORS image cache for public and heuristic freshness, emits Origin-bearing GETs and preserves exact ZIP photo bytes");
  const moviePath = join(artifacts, "synthetic.mp4");
  execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=purple:s=128x128:r=15:d=1", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", moviePath], { timeout: 20000 }); const movie = await readFile(moviePath);
  await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/listing-kit-fixture.html") } } });
  server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname, base = pathname.startsWith("/opened/") ? artifacts : dist;
    const path = resolve(base, `.${pathname}`); if (!path.startsWith(`${base}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); } catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1080 }, serviceWorkers: "block" });
  await context.route("**/*", async route => {
    const req = route.request(), url = new URL(req.url());
    if (url.origin === origin && req.method() === "GET") return route.continue();
    if (url.origin === "https://rendprop.com" && url.pathname === `/f/${publicationSlug}/share-link` && req.method() === "GET") {
      addressLookups++;
      return route.fulfill({ status: 200, contentType: "application/json", headers: { "Access-Control-Allow-Origin": origin, "Cache-Control": "no-store" }, body: JSON.stringify({ url: addressLink, address_only: false }) });
    }
    if (url.hostname === `${"a".repeat(32)}.r2.cloudflarestorage.com` && req.method() === "GET") {
      if (req.resourceType() === "fetch" && mode === "hold") { held.push(route); return; }
      if (req.resourceType() === "fetch" && mode === "fail") return route.fulfill({ status: 404, headers: { "Access-Control-Allow-Origin": "*" } });
      if (req.resourceType() === "fetch" && mode === "oversize") return route.fulfill({ status: 200, contentType: "image/png", headers: { "Access-Control-Allow-Origin": "*", "Content-Length": String(KIT_MAX_FILE_BYTES + 1) }, body: png });
      return route.fulfill({ status: 200, contentType: url.pathname.endsWith(".mp4") ? "video/mp4" : "image/png", headers: { "Access-Control-Allow-Origin": "*" }, body: url.pathname.endsWith(".mp4") ? movie : png });
    }
    receipt.externalRequests.push({ origin: url.origin, path: url.pathname, method: req.method() }); return route.abort();
  });
  page = await context.newPage(); page.on("pageerror", error => receipt.errors.push(error.message)); page.on("download", download => downloads.push(download)); page.setDefaultTimeout(8000);
  const openKit = async () => { await page.getByRole("button", { name: "Choose kit materials" }).click(); await expect(page.getByText("2 of 3 media items selected", { exact: true })).toBeVisible(); };
  const review = () => page.getByLabel("I reviewed the selected materials", { exact: false });
  await page.goto(`${origin}/tests/listing-kit-fixture.html`);
  await expect(page.getByRole("link", { name: "Open live property" })).toHaveAttribute("href", addressLink);
  await page.getByRole("tab", { name: "Create & publish", exact: false }).click();
  await expect(page.getByRole("link", { name: "Open branded tour" })).toHaveAttribute("href", addressLink);
  await expect(page.getByRole("link", { name: "Open MLS tour" })).toHaveAttribute("href", `https://rendprop.com/u/${publicationSlug}`);
  receipt.checks.push("Actual published-tour and finish-listing UI show the same verified dated address link while MLS stays unbranded");
  const beforeReload = addressLookups;
  await page.evaluate(() => window.kitFixture.reloadSameAccount());
  await expect.poll(() => addressLookups).toBeGreaterThan(beforeReload);
  const qrPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download marketing QR" }).click();
  const qrDownload = await qrPromise;
  assert.equal(qrDownload.suggestedFilename(), `rendprop-branded-${publicationSlug}-qr.svg`);
  const qrPath = join(artifacts, "refreshed-marketing-qr.svg");
  await qrDownload.saveAs(qrPath);
  assert.match(await readFile(qrPath, "utf8"), /<svg/);
  await expect(page.getByRole("link", { name: "Open branded tour" })).toHaveAttribute("href", addressLink);
  receipt.checks.push("Same-account workspace refresh invalidates the old read scope, reacquires the address proof and still downloads its marketing QR");
  await page.getByRole("tab", { name: "Details", exact: true }).click(); await page.getByLabel("Headline", { exact: true }).fill("Unsaved office headline must stay");
  await openKit(); await expect(page.getByLabel("Headline", { exact: true })).toHaveValue("Unsaved office headline must stay");
  await expect(page.getByRole("button", { name: "Download ZIP", exact: true })).toBeDisabled();
  await expect(page.getByLabel("Include Reviewed office reel", { exact: true })).not.toBeChecked();
  await page.getByText("2 item(s) unavailable for this kit", { exact: true }).click(); await expect(page.getByText("Video needing review: completion", { exact: false })).toBeVisible();
  await page.getByLabel("Include Reviewed office reel", { exact: true }).check(); await review().check();
  const downloadPromise = page.waitForEvent("download"); await page.getByRole("button", { name: "Download ZIP", exact: true }).click(); const download = await downloadPromise;
  const zip = join(artifacts, "listing-kit.zip"); await download.saveAs(zip); assert.equal(download.suggestedFilename(), "10-Oak-Street-listing-kit.zip");
  assert.equal(await download.failure(), null); const zipStat = await stat(zip); assert(zipStat.isFile() && zipStat.size > png.length + movie.length, "saved download must be a real non-empty file");
  const expected = await page.evaluate(({ listingA }) => {
    const photos = window.kitFixture.media(listingA).photos, altered = photos.filter(row => row.isAltered && row.originalUrl && row.originalUrl !== row.url), plain = photos.filter(row => !row.isAltered);
    const videos = window.kitFixture.state(listingA).assets.filter(row => row.kind === "video" && row.qc_publishable);
    return { edited: plain.length + altered.length, originals: altered.length, videos: videos.length, excluded: photos.length - plain.length - altered.length + window.kitFixture.state(listingA).assets.length - videos.length };
  }, { listingA: "20000000-0000-4000-8000-000000000002" });
  assert.deepEqual(expected, { edited: 2, originals: 1, videos: 1, excluded: 2 });
  const entries = readZipDirectory(await readFile(zip)), entryNames = entries.map(entry => entry.name);
  assert(["START-HERE.html", "manifest.json", "disclosures.txt", "property-details.txt"].every(name => entryNames.includes(name)));
  assert.equal(entryNames.filter(name => name.startsWith("photos/")).length, expected.edited); assert.equal(entryNames.filter(name => name.startsWith("originals/")).length, expected.originals); assert.equal(entryNames.filter(name => name.startsWith("videos/")).length, expected.videos);
  assert.equal(new Set(entryNames).size, entryNames.length); assert(entries.every(entry => entry.method === 0 && entry.compressed === entry.uncompressed && entry.bytes?.length === entry.uncompressed && crc32(entry.bytes) === entry.crc));
  assert.deepEqual(entries.filter(entry => entry.name.startsWith("originals/")).map(entry => Buffer.from(entry.bytes)), [png]); assert.deepEqual(entries.find(entry => entry.name.startsWith("videos/")).bytes, movie);
  const inlineManifest = JSON.parse(Buffer.from(entries.find(entry => entry.name === "manifest.json").bytes).toString("utf8"));
  assert.equal(inlineManifest.selectedMediaCount, expected.edited + expected.videos); assert.equal(inlineManifest.availableMediaCount, expected.edited + expected.videos); assert.equal(inlineManifest.excluded.length, expected.excluded);
  assert.match(execFileSync("unzip", ["-t", zip], { encoding: "utf8" }), /No errors detected/); execFileSync("unzip", ["-q", zip, "-d", join(artifacts, "opened")]);
  receipt.zip = { path: zip, bytes: zipStat.size, entries: entryNames };
  const manifest = JSON.parse(await readFile(join(artifacts, "opened/manifest.json"), "utf8")); assert.equal(manifest.files.length, 3); assert.equal(manifest.files[1].originalRelationship, "Paired original");
  assert.equal(manifest.publishedLinks.branded, addressLink);
  assert.ok((await readFile(join(artifacts, "opened/sharing-links.txt"), "utf8")).includes(addressLink));
  assert.deepEqual(await readFile(join(artifacts, "opened", manifest.files[1].originalPath)), png); assert.deepEqual(await readFile(join(artifacts, "opened", manifest.files[2].path)), movie);
  assert.equal(manifest.files[2].originalPath, null); assert.match(manifest.files[2].sourceNote, /No single unaltered original/);
  assert.match(await readFile(join(artifacts, "opened/disclosures.txt"), "utf8"), /Virtually staged/); assert.match(await readFile(join(artifacts, "opened/sharing/marketing-qr.svg"), "utf8"), /<svg/);
  assert(!JSON.stringify(manifest).includes("X-Amz")); assert(!JSON.stringify(manifest).includes("internal_secret"));
  await expect(page.getByLabel("Headline", { exact: true })).toHaveValue("Unsaved office headline must stay");
  receipt.checks.push("Actual property UI preserves dirty details; selected gallery+original+reviewed MP4 download as a valid ZIP with exact bytes, saved facts/copy, disclosure and real published-link QR");
  const opened = await context.newPage(); await opened.goto(`${origin}/opened/START-HERE.html`); await expect(opened.getByRole("heading", { name: "10 Oak Street", exact: true })).toBeVisible();
  await expect(opened.getByText('A bright home <script>alert("unsafe")</script>', { exact: false })).toBeVisible();
  await expect(opened.getByRole("link", { name: "Open marketing tour", exact: true })).toHaveAttribute("href", addressLink);
  await opened.screenshot({ path: join(artifacts, "opened-kit.png"), fullPage: true }); await opened.close(); receipt.checks.push("Unzipped START-HERE page opens, escapes saved HTML and links the actual selected files and existing published tour");
  await page.getByLabel("Include Photo 1", { exact: true }).uncheck(); await expect(review()).not.toBeChecked(); await expect(page.getByRole("button", { name: "Download ZIP", exact: true })).toBeDisabled();
  await review().check(); mode = "fail"; const count = downloads.length; await page.getByRole("button", { name: "Download ZIP", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "No incomplete kit" })).toBeVisible(); assert.equal(downloads.length, count); mode = "normal";
  receipt.checks.push("Changing selection clears review; a missing selected asset reports failure and never emits a partial ZIP");
  await review().check(); mode = "oversize"; await page.getByRole("button", { name: "Download ZIP", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(OVERSIZE_COPY); assert.equal(downloads.length, count); mode = "normal";
  await expect(page.getByRole("button", { name: "Download ZIP", exact: true })).toBeEnabled(); await expect(page.getByLabel("Headline", { exact: true })).toHaveValue("Unsaved office headline must stay");
  receipt.checks.push(`Control: a selected file declared over the ${KIT_MAX_FILE_BYTES / 1024 / 1024} MB per-file cap is refused with the exact delivery-kit copy and no ZIP is emitted`);
  const releaseHeld = async () => { const routes = held; held = []; await Promise.all(routes.map(route => route.fulfill({ status: 200, contentType: "image/png", headers: { "Access-Control-Allow-Origin": "*" }, body: png }).catch(() => {}))); };
  mode = "hold"; await page.getByRole("button", { name: "Download ZIP", exact: true }).click(); await expect.poll(() => held.length).toBeGreaterThan(0);
  await page.getByRole("button", { name: "Cancel download", exact: true }).click(); mode = "normal"; await releaseHeld(); await page.waitForTimeout(100);
  assert.equal(downloads.length, count); await expect(page.getByText("Download cancelled.", { exact: false })).toBeVisible(); await expect(page.getByLabel("Headline", { exact: true })).toHaveValue("Unsaved office headline must stay");
  receipt.checks.push("Cancel during a held media response leaves saved data and dirty details intact and emits no late download");
  mode = "hold"; await page.getByRole("button", { name: "Download ZIP", exact: true }).click(); await expect.poll(() => held.length).toBeGreaterThan(0);
  await page.getByLabel("Working on", { exact: true }).selectOption("20000000-0000-4000-8000-000000000003"); mode = "normal"; await releaseHeld(); await page.waitForTimeout(100); assert.equal(downloads.length, count);
  await page.getByRole("button", { name: "Choose kit materials" }).click(); await expect(page.getByText("No tour has been published", { exact: false })).toBeVisible(); await review().check();
  const detailsPromise = page.waitForEvent("download"); await page.getByRole("button", { name: "Download ZIP", exact: true }).click(); const details = await detailsPromise; const detailsZip = join(artifacts, "details-only.zip"); await details.saveAs(detailsZip);
  const names = execFileSync("unzip", ["-Z1", detailsZip], { encoding: "utf8" }); assert(!names.includes("sharing")); assert(!names.includes("photos/"));
  const detailsManifest = JSON.parse(execFileSync("unzip", ["-p", detailsZip, "manifest.json"], { encoding: "utf8" })); assert.equal(detailsManifest.facts.address, "20 Maple Avenue"); assert.equal(detailsManifest.publishedLinks, null);
  receipt.checks.push("Property switch cancels the old download; an unpublished property gets a coherent details-only kit with no invented tour links or QR");
  await page.getByLabel("Working on", { exact: true }).selectOption("20000000-0000-4000-8000-000000000002"); await openKit(); await review().check();
  mode = "hold"; const beforeAccount = downloads.length; await page.getByRole("button", { name: "Download ZIP", exact: true }).click(); await expect.poll(() => held.length).toBeGreaterThan(0);
  await page.evaluate(() => window.kitFixture.changeAccount()); mode = "normal"; await releaseHeld(); await page.waitForTimeout(100); assert.equal(downloads.length, beforeAccount); await expect(page.getByRole("alert").filter({ hasText: "Your account changed" })).toBeVisible();
  receipt.checks.push("Account identity change aborts media in flight, clears old selections and cannot trigger a stale ZIP download");
  await page.reload(); await openKit(); await page.setViewportSize({ width: 390, height: 844 }); assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
  await page.screenshot({ path: join(artifacts, "kit-mobile.png"), fullPage: true }); await page.setViewportSize({ width: 1440, height: 1080 }); await page.screenshot({ path: join(artifacts, "kit-desktop.png"), fullPage: true });
  receipt.checks.push("Branded selection UI fits a 390px viewport with readable progress, original pairing and disclosure controls");
  const calls = await page.evaluate(() => window.kitFixture.calls); assert(calls.every(call => call.method === "GET")); assert(addressLookups >= 1); assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack ?? String(error); process.exitCode = 1; if (page) await page.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {}); }
finally { await browser?.close(); if (server) await new Promise(done => server.close(done)); await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2)); console.log(JSON.stringify({ ...receipt, artifacts }, null, 2)); }
