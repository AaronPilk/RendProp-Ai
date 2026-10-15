import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";
// Studio Photos keeps upload order: earlier photos saved before positions existed,
// two later batches whose file names restart at IMG_0001, an explicit reorder that
// survives a fresh mount, and a third batch that still lands underneath. The
// fixture follows the server gallery contract and gives later uploads LOWER UUIDs.
const fault = process.argv.find(value => value.startsWith("--fault="))?.slice(8);
const FAULTS = { "uuid-tie-break": ["/src/features/listings/model.ts", "a.sort - b.sort || attachTime(a) - attachTime(b) || a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id)", "a.sort - b.sort || a.id.localeCompare(b.id)"] };
if (fault && !FAULTS[fault]) throw Error("Unknown closed upload-order control");
let faultApplied = false;
const root = fileURLToPath(new URL("../", import.meta.url)), artifacts = await mkdtemp(join(tmpdir(), "rendprop-listing-order-")), dist = join(artifacts, "dist");
const receipt = { fault: fault ?? null, proof: "Actual ListingWorkflow upload, attach, gallery order and reorder UI against a closed fixture of the server gallery contract. No live account or uploads.", checks: [], externalRequests: [], errors: [] };
let browser, server, page;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", plugins: [{ name: "closed-upload-order-control", enforce: "pre", transform(code, id) { if (!fault) return; const [file, before, after] = FAULTS[fault]; if (!id.endsWith(file)) return; assert.equal(code.split(before).length - 1, 1, "Exact compiled control anchor"); faultApplied = true; return code.replace(before, after); } }], build: { outDir: dist, rollupOptions: { input: join(root, "tests/listing-upload-order-fixture.html") } } });
  if (fault) assert.equal(faultApplied, true, "Control must compile the actual runtime source");
  server = createServer(async (request, response) => { const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`); if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end(); try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); } catch { response.writeHead(404).end(); } });
  await new Promise((done) => server.listen(0, "127.0.0.1", done)); const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, serviceWorkers: "block" });
  await context.route("**/*", (route) => { if (new URL(route.request().url()).origin === origin && route.request().method() === "GET") return route.continue(); receipt.externalRequests.push(route.request().url()); return route.abort(); });
  page = await context.newPage(); page.on("pageerror", (error) => receipt.errors.push(error.message)); page.setDefaultTimeout(8000);
  await page.goto(`${origin}/tests/listing-upload-order-fixture.html`);
  await expect(page.getByRole("heading", { name: "10 Oak Street", exact: true })).toBeVisible();
  await page.getByRole("tab", { name: /Media/ }).click();
  const titles = () => page.locator(".lw-gallery-photo strong").allTextContents();
  const snapshot = () => page.evaluate(() => window.listingFixture.snapshot());
  const png = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 200; c.height = 150; c.getContext("2d").fillRect(0, 0, 200, 150); return c.toDataURL().split(",")[1]; });
  const files = (...names) => names.map((name, n) => ({ name, mimeType: "image/png", buffer: Buffer.concat([Buffer.from(png, "base64"), Buffer.from(`${name}:${n}:${Math.random()}`)]) }));
  const uploaded = async (count) => { await expect(page.getByRole("status").filter({ hasText: "media is uploaded" })).toBeVisible(); await expect(page.locator(".lw-gallery-photo")).toHaveCount(count); };

  // 1. Photos saved before positions existed (sort 0) show in upload order, not UUID order.
  await expect(page.locator(".lw-gallery-photo")).toHaveCount(3);
  assert.deepEqual(await titles(), ["Front door", "Kitchen", "Garden"], "earlier photos keep their upload order");
  receipt.checks.push("Photos attached before gallery positions existed show in upload order despite reverse UUIDs");

  // 2. Two upload batches, the second restarting at IMG_0001, append underneath.
  await page.locator('input[type="file"][multiple]').setInputFiles(files("IMG_0001.png", "IMG_0002.png", "IMG_0003.png"));
  await uploaded(6);
  await page.locator('input[type="file"][multiple]').setInputFiles(files("IMG_0001.png", "IMG_0002.png"));
  await uploaded(8);
  assert.deepEqual(await titles(), ["Front door", "Kitchen", "Garden", "IMG_0001", "IMG_0002", "IMG_0003", "IMG_0001", "IMG_0002"]);
  let state = await snapshot();
  const batchIds = state.photos.filter(photo => photo.caption?.startsWith("IMG_")).map(photo => photo.id);
  assert.equal(new Set(batchIds).size, 5, "repeated file names never overwrite an earlier upload");
  assert.equal(new Set(state.assets.filter(asset => asset.kind === "photo").map(asset => asset.storage_key)).size, 8);
  receipt.checks.push("Two batches with file names restarting at IMG_0001 append in order; repeated names are distinct photos");

  // 3. An explicit move survives a fresh mount.
  await page.getByRole("button", { name: "Move photo 7 earlier" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Photo order saved." })).toBeVisible();
  const moved = ["Front door", "Kitchen", "Garden", "IMG_0001", "IMG_0002", "IMG_0001", "IMG_0003", "IMG_0002"];
  assert.deepEqual(await titles(), moved);
  await page.evaluate(() => window.listingFixture.reopen()); await page.getByRole("tab", { name: /Media/ }).click();
  await expect(page.locator(".lw-gallery-photo")).toHaveCount(8); assert.deepEqual(await titles(), moved, "explicit order survives a fresh property mount");
  receipt.checks.push("A move saves the whole displayed order (including legacy ties) and survives a fresh mount");

  // 4. A third batch after the explicit reorder still lands underneath.
  await page.locator('input[type="file"][multiple]').setInputFiles(files("IMG_0001.png"));
  await uploaded(9);
  assert.deepEqual(await titles(), [...moved, "IMG_0001"]);
  state = await snapshot();
  assert.equal(new Set(state.photos.map(photo => photo.sort)).size, 9, "every photo has its own saved position");
  receipt.checks.push("A later batch appends after an explicit reorder instead of jumping to the front");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack; process.exitCode = 1; await page?.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {}); }
finally { await browser?.close(); if (server) await new Promise(done => server.close(done)); await writeFile(join(artifacts, "receipt.json"), JSON.stringify({ ...receipt, artifacts }, null, 2)); console.log(JSON.stringify({ ...receipt, artifacts }, null, 2)); }
