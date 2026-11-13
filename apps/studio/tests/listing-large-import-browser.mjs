import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const args = process.argv.slice(2);
assert(args.length === 0 || args.length === 1 && args[0] === "--fault=omit-partial-refresh", "Unknown import control");
const fault = args[0]?.slice(8);
const root = fileURLToPath(new URL("../", import.meta.url));
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-large-import-")), dist = join(artifacts, "dist");
const anchor = "      if (alive.current && services.getSnapshot().identityVersion === uploadIdentity)\n        await refresh();";
const sourcePaths = ["src/features/listings/ListingWorkflow.tsx", "src/features/listings/uploads.ts", "tests/listing-upload-order-fixture.tsx", "tests/listing-large-import-browser.mjs"];
const sourceHashes = Object.fromEntries(await Promise.all(sourcePaths.map(async path => [path, createHash("sha256").update(await readFile(join(root, path))).digest("hex")])));
const receipt = { fault: fault ?? null, sourceHashes, scope: "Actual ListingWorkflow, upload journals and local File bytes; closed service transport fixture, no hosted account, cloud upload, paid call or phone import proof.", checks: [], externalRequests: [], errors: [] };
let browser, server, page, applied = false;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", plugins: [{ name: "closed-partial-import-control", enforce: "pre", transform(code, id) {
    if (!fault || !id.endsWith("/src/features/listings/ListingWorkflow.tsx")) return;
    assert.equal(code.split(anchor).length, 2, "Exact compiled partial-refresh anchor"); applied = true;
    return code.replace(anchor, "      // Compiled omission: retain uploaded bytes and original error, omit only the readback.");
  } }], build: { outDir: dist, rollupOptions: { input: join(root, "tests/listing-upload-order-fixture.html") } } });
  if (fault) assert(applied, "Omission must compile the actual component");
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`)) return response.writeHead(400).end();
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); }
    catch { response.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, serviceWorkers: "block" });
  await context.route("**/*", route => { if (new URL(route.request().url()).origin === origin && route.request().method() === "GET") return route.continue(); receipt.externalRequests.push(route.request().url()); return route.abort(); });
  page = await context.newPage(); page.setDefaultTimeout(8000); page.on("pageerror", error => receipt.errors.push(error.message));
  await page.goto(`${origin}/tests/listing-upload-order-fixture.html`);
  await page.getByRole("tab", { name: /Media/ }).click();
  await expect(page.locator(".lw-gallery-photo")).toHaveCount(3);
  const pngs = await page.evaluate(() => Array.from({ length: 40 }, (_, n) => {
    const canvas = document.createElement("canvas"); canvas.width = 200; canvas.height = 150;
    const paint = canvas.getContext("2d"); paint.fillStyle = `rgb(${n * 5},90,150)`; paint.fillRect(0, 0, 200, 150);
    paint.fillStyle = "white"; paint.fillText(String(n), 20, 30); return canvas.toDataURL("image/png").split(",")[1];
  }));
  const file = (index, name) => ({ name, mimeType: "image/png", buffer: Buffer.from(pngs[index], "base64") });
  const first = Array.from({ length: 20 }, (_, i) => file(i, `IMG_${String(i + 1).padStart(4, "0")}.png`));
  const second = Array.from({ length: 17 }, (_, i) => file(i + 20, `IMG_${String(i + 1).padStart(4, "0")}.png`));
  const input = page.locator('input[type="file"][multiple]');
  const uploaded = async count => { await expect(page.getByRole("status").filter({ hasText: "media is uploaded" })).toBeVisible(); await expect(page.locator(".lw-gallery-photo")).toHaveCount(count); };
  const titles = () => page.locator(".lw-gallery-photo strong").allTextContents();
  const snapshot = () => page.evaluate(() => window.listingFixture.snapshot());
  await input.setInputFiles(first); await uploaded(23);
  await input.setInputFiles(second); await uploaded(40);
  const expected = ["Front door", "Kitchen", "Garden", ...first.map(item => item.name.slice(0, -4)), ...second.map(item => item.name.slice(0, -4))];
  assert.deepEqual(await titles(), expected, "A 20-photo batch and later 17-photo batch preserve selection order");
  let state = await snapshot();
  assert.equal(new Set(state.photos.map(photo => photo.id)).size, 40);
  assert.equal(new Set(state.assets.filter(asset => asset.kind === "photo").map(asset => asset.storage_key)).size, 40);
  assert.equal((await page.evaluate(() => window.listingFixture.uploadBodies())).length, 37);
  receipt.checks.push("20 and 17 real File objects import through the normal UI without a 15-photo ceiling; repeated filenames retain distinct assets and append order");

  const last = [file(37, "NEXT_01.png"), file(38, "NEXT_02.png"), file(39, "NEXT_03.png")];
  await page.evaluate(() => window.listingFixture.failUpload("NEXT_02.png"));
  await input.setInputFiles(last);
  await expect(page.getByRole("alert").filter({ hasText: "Fixture upload interrupted" })).toBeVisible();
  // The error is rendered after the recovery read. Never focus/reopen/wait for
  // the 30-second refresh to mask whether the successful prefix is visible.
  assert.equal((await snapshot()).photos.length, 41, "The first file was actually saved before the later transport failure");
  assert.equal(await page.locator(".lw-gallery-photo").count(), 41, "Saved prefix must remain visible immediately after a later upload fails");
  assert.deepEqual(await titles(), [...expected, "NEXT_01"]);
  const reservations = await page.evaluate(() => window.listingFixture.reservations());
  assert.equal(reservations.length, 39, "Unattempted final file must not have an upload reservation");
  const journals = await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("rendprop-studio-uploads:")).flatMap(key => JSON.parse(localStorage.getItem(key))));
  assert.equal(journals.length, 1); assert.equal(journals[0].filename, "NEXT_02.png");
  assert.equal(journals[0].assetId, reservations.at(-1).id);
  assert(!JSON.stringify(journals).includes("https://"), "Recovery journal must not retain upload capabilities");
  receipt.checks.push("A later transport error preserves its original error and recovery journal, immediately shows the saved prefix and leaves the unattempted suffix untouched");

  await page.evaluate(() => window.listingFixture.reopen()); await page.getByRole("tab", { name: /Media/ }).click();
  await expect(page.locator(".lw-gallery-photo")).toHaveCount(41);
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"), page.getByRole("button", { name: "Resume", exact: true }).click()]);
  await chooser.setFiles(last[1]); await uploaded(42);
  assert.equal((await page.evaluate(() => window.listingFixture.reservations())).length, 39, "Resume must renew the same asset rather than reserve a duplicate");
  await expect(page.locator(".lw-recovery")).toHaveCount(0);
  await input.setInputFiles(last[2]); await uploaded(43);
  assert.deepEqual(await titles(), [...expected, "NEXT_01", "NEXT_02", "NEXT_03"]);
  state = await snapshot(); assert.equal(new Set(state.photos.map(photo => photo.id)).size, 43);
  const puts = await page.evaluate(() => window.listingFixture.uploadBodies());
  assert.equal(puts.filter(item => item.failed).length, 1);
  assert.equal(puts.filter(item => item.filename === "NEXT_01.png").length, 1);
  assert.equal(puts.filter(item => item.filename === "NEXT_02.png").length, 2);
  assert.equal(puts.filter(item => item.filename === "NEXT_03.png").length, 1);
  receipt.checks.push("Reopen retains recovery; Resume renews the same asset, avoids replaying saved files, and the reselected suffix appends once in order");
  const callsBeforeSwitch = await page.evaluate(() => window.listingFixture.calls().length);
  await page.evaluate(() => window.listingFixture.failUpload("ACCOUNT_SWITCH.png", true));
  await input.setInputFiles(file(0, "ACCOUNT_SWITCH.png"));
  await expect(page.getByRole("alert").filter({ hasText: "Fixture upload interrupted" })).toBeVisible();
  const switchCalls = await page.evaluate(n => window.listingFixture.calls().slice(n), callsBeforeSwitch);
  assert.equal(switchCalls.length, 1, "An account change must not trigger a read of the old property after the failed reservation/PUT");
  assert.equal(switchCalls[0].method, "POST"); assert.equal(switchCalls[0].path, "/functions/v1/uploads");
  assert.equal(await page.locator(".lw-gallery-photo").count(), 43);
  receipt.checks.push("If identity changes during the failed PUT, recovery does not read the old property with the new identity");
  assert.deepEqual(receipt.errors, []); assert.deepEqual(receipt.externalRequests, []); receipt.status = "passed";
} catch (error) { receipt.status = "failed"; receipt.failure = error.stack; process.exitCode = 1; await page?.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {}); }
finally { await browser?.close(); if (server) await new Promise(done => server.close(done)); await writeFile(join(artifacts, "receipt.json"), JSON.stringify({ ...receipt, artifacts }, null, 2)); console.log(JSON.stringify({ ...receipt, artifacts }, null, 2)); }
