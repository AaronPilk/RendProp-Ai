import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = resolve(import.meta.dirname, "..");
const dir = await mkdtemp(join(tmpdir(), "rendprop-spatial-release-"));
const dist = join(dir, "dist");
await build({ configFile: false, root, publicDir: false, logLevel: "error", build: { outDir: dist, rollupOptions: { input: join(root, "tests/listing-workflow-fixture.html") } } });
const server = createServer(async (request, response) => {
  const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
  if (!path.startsWith(`${dist}/`) || request.method !== "GET") return response.writeHead(400).end();
  try {
    response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css" })[extname(path)] ?? "application/octet-stream");
    response.end(await readFile(path));
  } catch { response.writeHead(404).end(); }
});
await new Promise(done => server.listen(0, "127.0.0.1", done));
const browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
try {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/tests/listing-workflow-fixture.html`);
  await expect(page.getByRole("heading", { name: "10 Oak Street", exact: true })).toBeVisible();
  await expect(page.getByRole("tab", { name: /Floor plan & 3D/ })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "3D rooms from your phone" })).toHaveCount(0);
  await expect(page.locator('input[type="file"][accept=".jpg,.jpeg,.png,.webp"]')).toHaveCount(0);
  await page.getByRole("tab", { name: /Details/ }).click();
  await page.getByRole("tab", { name: /Media/ }).click();
  const calls = await page.evaluate(() => window.listingFixture.calls());
  assert.equal(calls.some(call => call.path.includes("/spatial") || call.path.includes("/floorplan")), false);
  assert.deepEqual(errors, []);
  console.log("Public property workspace has no floor-plan or 3D entry, controls, or API calls.");
} finally {
  await browser.close();
  await new Promise(done => server.close(done));
}
