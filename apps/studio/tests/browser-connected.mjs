#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const args = process.argv.slice(2);
assert.ok(args.every((arg) => arg === "--mutate-clear-on-refresh"), "Unknown argument");
const mutation = args.includes("--mutate-clear-on-refresh");
const root = fileURLToPath(new URL("../", import.meta.url));
const artifacts = await mkdtemp(join(tmpdir(), "rendprop-connected-browser-"));
const dist = join(artifacts, "fixture-dist");
const receipt = { status: "running", mutation, artifacts, checks: [], errors: [], externalRequests: [], skipped: 0,
  proof: "Separately compiled real App + real Studio services with injected offline Auth/fetch. This is NOT a live Apple sign-in or deployed media proof." };
let browser, server, page;
let transformed = false;
const nav = (name) => page.getByRole("navigation", { name: "Studio navigation" }).getByRole("button", { name: new RegExp(`^${name}(?:\\s*NEW)?$`) });
const title = () => page.getByLabel("Title overlay", { exact: true });
const check = (name) => receipt.checks.push(name);
const savedKey = "rendprop-studio:v1:11111111-1111-4111-8111-111111111111:33333333-3333-4333-8333-333333333333:edit";
try {
  await build({ configFile: false, root, publicDir: "public", logLevel: "error",
    plugins: mutation ? [{ name: "deliberate-refresh-regression", enforce: "pre", transform(code, id) {
      if (!id.endsWith("/src/App.tsx")) return;
      const needle = "setBusy(true);\n    // Keep the same verified scope mounted";
      assert.ok(code.includes(needle), "Mutation sentinel not found; negative control cannot be claimed");
      transformed = true;
      return code.replace(needle, "setBusy(true);\n    setWorkspace(null);\n    // Keep the same verified scope mounted");
    } }] : [],
    build: { outDir: dist, emptyOutDir: false, rollupOptions: { input: join(root, "tests/fixtures/connected.html") } },
  });
  if (mutation) assert.ok(transformed, "Deliberate mutation was not applied");
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`) || request.method !== "GET") { response.writeHead(400).end(); return; }
    try {
      response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".svg": "image/svg+xml" })[extname(path)] ?? "application/octet-stream");
      response.end(await readFile(path));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1440, height: 1000 } });
  await context.route("**/*", (route) => {
    if (new URL(route.request().url()).origin === origin && route.request().method() === "GET") return route.continue();
    receipt.externalRequests.push(route.request().url());
    return route.abort();
  });
  page = await context.newPage();
  page.on("pageerror", (error) => receipt.errors.push(error.message));
  page.setDefaultTimeout(8000);
  await page.goto(`${origin}/tests/fixtures/connected.html`, { waitUntil: "networkidle" });
  await expect(page.getByText("Account connected", { exact: true })).toBeVisible();
  await nav("Video editor").click();
  const png = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 800; c.height = 450; const g = c.getContext("2d"); g.fillStyle = "#7d39ec"; g.fillRect(0, 0, c.width, c.height); return c.toDataURL().split(",")[1]; });
  await page.getByLabel("Add photos or videos", { exact: true }).setInputFiles({ name: "isolated.png", mimeType: "image/png", buffer: Buffer.from(png, "base64") });
  await expect(page.getByRole("button", { name: /Select clip 1:/ })).toBeVisible();
  await title().fill("Scoped business edit");
  await expect.poll(() => page.evaluate((key) => JSON.parse(localStorage.getItem(key) ?? "null")?.title, savedKey)).toBe("Scoped business edit");
  check("real App restores fixture account and stores its edit under user + organization");

  await nav("Content library").click();
  await page.evaluate(() => window.studioFixture.setMode("hold"));
  await page.getByRole("button", { name: "Refresh library", exact: true }).click();
  await expect(page.getByText("Connecting…", { exact: true })).toBeVisible();
  await nav("Video editor").click();
  // This is the regression assertion; the deliberate mutation must fail here.
  await expect(title(), "REFRESH_BINDING_REGRESSION: editor must stay mounted during a same-account refresh").toHaveValue("Scoped business edit", { timeout: 2000 });
  await expect(page.getByText(/original file needs reselection/)).toHaveCount(0);
  await page.evaluate(() => window.studioFixture.release());
  await expect(page.getByText("Account connected", { exact: true })).toBeVisible();
  await expect(title()).toHaveValue("Scoped business edit");
  await expect(page.getByText(/original file needs reselection/)).toHaveCount(0);
  check("same-account refresh retains title and live File binding during and after the request");

  await nav("Content library").click();
  await page.evaluate(() => window.studioFixture.setMode("503"));
  await page.getByRole("button", { name: "Refresh library", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "last loaded workspace" })).toBeVisible();
  await nav("Video editor").click();
  await expect(title()).toHaveValue("Scoped business edit");
  await expect(page.getByText(/original file needs reselection/)).toHaveCount(0);
  check("503 leaves an explicit stale-data notice while local file editing remains intact");

  await page.evaluate(() => window.studioFixture.setMode("403"));
  await page.getByRole("button", { name: "Retry connection", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "no longer have access" })).toBeVisible();
  await expect(title()).toHaveCount(0);
  assert.equal(await page.evaluate((key) => JSON.parse(localStorage.getItem(key)).title, savedKey), "Scoped business edit");
  check("403 clears visible workspace/media without deleting its stored draft");

  await page.evaluate(() => window.studioFixture.setMode("ok"));
  await page.getByRole("button", { name: "Retry connection", exact: true }).click();
  await expect(title()).toHaveValue("Scoped business edit");
  await expect(page.getByText("1 original file needs reselection.", { exact: true })).toBeVisible();
  check("verified access recovery restores the right draft and honestly requests original-file reselection");

  await nav("Workspace").click();
  await page.getByRole("combobox", { name: "Workspace", exact: true }).selectOption("44444444-4444-4444-8444-444444444444");
  await expect(page.getByText("Account connected", { exact: true })).toBeVisible();
  await nav("Video editor").click();
  await expect(title()).not.toHaveValue("Scoped business edit");
  await expect(page.getByRole("button", { name: /Select clip 1:/ })).toHaveCount(0);
  await title().fill("Second organization only");
  await page.evaluate(() => window.studioFixture.switchUser("B"));
  await expect(page.locator(".account-button")).toContainText("Fixture B");
  await expect(title()).not.toHaveValue("Second organization only");
  await expect(title()).not.toHaveValue("Scoped business edit");
  check("organization and account switches still fence drafts and in-memory files");

  await page.screenshot({ path: join(artifacts, "connected-fixture.png"), fullPage: true });
  assert.deepEqual(receipt.externalRequests, [], "No provider or external request is permitted");
  assert.deepEqual(receipt.errors, [], "No browser runtime errors");
  receipt.requests = await page.evaluate(() => window.studioFixture.calls());
  assert.ok(receipt.requests.some((call) => call.path === "/functions/v1/listings"));
  receipt.status = "passed";
} catch (error) {
  receipt.status = "failed";
  receipt.failure = error.stack ?? String(error);
  if (page) await page.screenshot({ path: join(artifacts, "failure.png"), fullPage: true }).catch(() => {});
  process.exitCode = 1;
} finally {
  await browser?.close();
  if (server) await new Promise((done) => server.close(done));
  receipt.finishedAt = new Date().toISOString();
  await writeFile(join(artifacts, "receipt.json"), `${JSON.stringify(receipt, null, 2)}\n`);
  console.log(JSON.stringify(receipt, null, 2));
}
