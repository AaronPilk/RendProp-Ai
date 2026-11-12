import assert from "node:assert/strict";
import { mkdir, readFile, writeFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join, extname } from "node:path";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { build } from "vite";
import { chromium, expect } from "@playwright/test";

const root = resolve(import.meta.dirname, "..");
const fault = process.argv.find(arg => arg.startsWith("--fault="))?.slice("--fault=".length) ?? null;
if (fault && !["clear-draft-on-reload", "unsafe-react-logging"].includes(fault)) throw new Error("Unknown recovery fault control");
const PRIVATE_ERROR_SENTINEL = "SYNTHETIC_PRIVATE_URL_SENTINEL";
const artifacts = process.env.RENDPROP_RECOVERY_EVIDENCE ?? await mkdtemp(join(tmpdir(), "rendprop-studio-recovery-"));
await mkdir(artifacts, { recursive: true });
const dist = join(artifacts, "dist");
const paths = ["src/StudioBoundary.tsx", "src/App.tsx", "src/main.tsx", "src/styles.css", "tests/recovery-fixture.html", "tests/recovery-fixture.tsx", "tests/recovery-lazy.tsx", "tests/recovery-browser.mjs"];
const hashes = async () => Object.fromEntries(await Promise.all(paths.map(async p => [p, createHash("sha256").update(await readFile(join(root, p))).digest("hex")])));
const receipt = { passed: false, fault, assertions: [], sourceHashes: await hashes(), limits: ["Actual production React boundary and lazy chunk, synthetic local workspace/draft", "Closed browser network; no Auth, provider or customer operations", "Does not prove server persistence or camera behavior"] };
let unsafeControlCompiled = false;
let server, browser;
try {
  await build({ configFile: false, root, publicDir: false, logLevel: "error", plugins: fault === "unsafe-react-logging" ? [{
    name: "recovery-unsafe-root-control", enforce: "pre",
    transform(source, id) {
      if (id !== join(root, "tests/recovery-fixture.tsx")) return;
      const safe = 'createRoot(document.getElementById("root")!, STUDIO_ROOT_OPTIONS)';
      assert(source.includes(safe), "Compiled unsafe logging control must remove the actual shared root option");
      unsafeControlCompiled = true;
      return source.replace(safe, 'createRoot(document.getElementById("root")!)');
    },
  }] : [], build: { outDir: dist, rollupOptions: { input: join(root, "tests/recovery-fixture.html") } } });
  receipt.unsafeControlCompiled = unsafeControlCompiled;
  assert.equal(unsafeControlCompiled, fault === "unsafe-react-logging");
  await writeFile(join(dist, "seed.html"), "<!doctype html><title>Synthetic recovery storage setup</title>");
  server = createServer(async (req, res) => {
    const path = resolve(dist, "." + new URL(req.url, "http://localhost").pathname);
    if (!path.startsWith(dist + "/") || req.method !== "GET") return res.writeHead(400).end();
    try { res.setHeader("content-type", ({ ".js": "application/javascript", ".html": "text/html", ".css": "text/css" })[extname(path)] ?? "application/octet-stream"); res.end(await readFile(path)); }
    catch { res.writeHead(404).end(); }
  });
  await new Promise(done => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 390, height: 844 } });
  let denyChunk = true, rejected = 0, navigation = 0;
  await context.route("**/*", async route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin || route.request().method() !== "GET") throw new Error("Unexpected external browser request");
    if (denyChunk && /\/assets\/recovery-lazy-/.test(url.pathname)) { rejected++; return route.fulfill({ status: 404, contentType: "text/plain", body: "Missing chunk" }); }
    return route.continue();
  });
  const page = await context.newPage();
  const consoleMessages = [], pageErrors = [];
  page.on("console", message => consoleMessages.push(message.text()));
  page.on("pageerror", error => pageErrors.push(error.message));
  page.on("framenavigated", frame => { if (frame === page.mainFrame()) navigation++; });
  // Seed only once. An init script would recreate the draft on every reload
  // and could falsely report persistence even after an actual storage loss.
  await page.goto(origin + "/seed.html");
  await page.evaluate(() => localStorage.setItem("rendprop.recovery.synthetic", "saved-fixture-draft"));
  navigation = 0;
  await page.goto(origin + "/tests/recovery-fixture.html");
  const alert = page.getByRole("alert");
  await expect(alert.getByRole("heading", { name: "This workspace couldn’t open" })).toBeVisible();
  assert.equal(rejected, 1); receipt.assertions.push("Real missing production lazy chunk is caught and exposes accessible recovery");
  assert.equal(await alert.getAttribute("aria-labelledby"), await alert.getByRole("heading").getAttribute("id")); receipt.assertions.push("Recovery has a unique linked heading");
  await expect(page.getByText("Saved synthetic draft: saved-fixture-draft")).toBeVisible();
  assert.equal(navigation, 1); receipt.assertions.push("Recovery does not automatically reload or discard stored draft");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false); receipt.assertions.push("Recovery fits a narrow phone viewport");
  await page.getByRole("button", { name: "Change fixture workspace" }).click();
  await expect(page.getByText("Second fixture workspace opened")).toBeVisible(); await expect(alert).toHaveCount(0); receipt.assertions.push("Identity reset clears an old workspace failure");
  await page.evaluate(() => localStorage.setItem("rendprop.recovery.synthetic", "edited-fixture-draft"));
  await page.reload(); await expect(alert).toBeVisible();
  assert.equal(await page.evaluate(() => localStorage.getItem("rendprop.recovery.synthetic")), "edited-fixture-draft", "An edited draft must survive the first reload without reseeding");
  denyChunk = false;
  if (fault === "clear-draft-on-reload") await page.evaluate(() => document.addEventListener("click", event => {
    if (event.target instanceof HTMLButtonElement && event.target.textContent === "Reload Studio") localStorage.removeItem("rendprop.recovery.synthetic");
  }, { capture: true, once: true }));
  await page.getByRole("button", { name: "Reload Studio", exact: true }).click();
  await expect(page.getByText("Fixture workspace opened", { exact: true })).toBeVisible(); await expect(alert).toHaveCount(0); receipt.assertions.push("Explicit Reload retrieves the available chunk and recovers");
  assert.equal(await page.evaluate(() => localStorage.getItem("rendprop.recovery.synthetic")), "edited-fixture-draft", "An edited draft must survive explicit Reload without reseeding"); receipt.assertions.push("Synthetic stored draft survives explicit reload");
  await page.getByRole("button", { name: "Throw synthetic private error" }).click();
  await expect(alert.getByRole("heading", { name: "This workspace couldn’t open" })).toBeVisible();
  receipt.assertions.push("A caught render error still exposes recovery");
  assert.equal(consoleMessages.some(message => message.includes(PRIVATE_ERROR_SENTINEL)), false, "Caught React errors must not expose private signed URLs in the browser console");
  assert.equal(pageErrors.some(message => message.includes(PRIVATE_ERROR_SENTINEL)), false, "Caught React errors must not expose private signed URLs as page errors");
  receipt.assertions.push("Shared production root options suppress private error content in console and page errors");
  assert.deepEqual(await hashes(), receipt.sourceHashes); receipt.sourceBoundAtEnd = true; receipt.passed = true;
} catch (error) { receipt.failure = String(error.stack ?? error); throw error; }
finally {
  receipt.endSourceHashes = await hashes();
  receipt.sourceBoundAtEnd = Object.entries(receipt.sourceHashes).every(([path, hash]) => receipt.endSourceHashes[path] === hash);
  await writeFile(join(artifacts, "receipt.json"), JSON.stringify(receipt, null, 2));
  await browser?.close(); await new Promise(done => server ? server.close(done) : done());
  console.log(JSON.stringify({ passed: receipt.passed, checks: receipt.assertions.length, artifacts }));
}
