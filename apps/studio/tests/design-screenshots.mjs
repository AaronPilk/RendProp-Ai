#!/usr/bin/env node
// Design review screenshots of the real App over the synthetic connected
// fixture. Nothing private: fixture accounts, fixture listings, no network.
//   node tests/design-screenshots.mjs --out=/path/to/dir [--label=before]
// Produces <label>-<view>-<width>.png for desktop (1440) and narrow phone (390),
// in light and dark appearance, plus a JSON index. No media is uploaded.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "vite";
import { chromium } from "@playwright/test";

const args = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? true]; }));
const out = resolve(args.out ?? "design-shots");
const label = args.label ?? "shot";
const root = fileURLToPath(new URL("../", import.meta.url));
const dist = join(out, `fixture-dist-${label}`);
await mkdir(out, { recursive: true });
const LISTING = "55555555-5555-4555-8555-555555555500";
const views = [
  ["overview", `?view=overview&listing=${LISTING}`],
  ["properties", `?view=properties&listing=${LISTING}`],
  ["editor", `?view=editor&listing=${LISTING}`],
  ["creative", `?view=creative&listing=${LISTING}`],
  ["library", `?view=library&listing=${LISTING}`],
  ["workspace", `?view=workspace&listing=${LISTING}`],
  ["planner", `?view=planner&listing=${LISTING}`],
  ["noproperties", `?view=properties&noProperties`],
];
const index = { label, startedAt: new Date().toISOString(), shots: [], errors: [], externalRequests: [] };
let server, browser;
try {
  await build({ configFile: false, root, publicDir: "public", logLevel: "error", build: { outDir: dist, emptyOutDir: true, rollupOptions: { input: join(root, "tests/fixtures/connected.html") } } });
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
  for (const [width, height, device] of [[1440, 1000, "desktop"], [390, 844, "phone"]]) {
    for (const scheme of ["light", "dark"]) {
      const context = await browser.newContext({ serviceWorkers: "block", viewport: { width, height }, colorScheme: scheme, deviceScaleFactor: 1, isMobile: device === "phone", hasTouch: device === "phone" });
      await context.route("**/*", (route) => {
        if (new URL(route.request().url()).origin === origin && route.request().method() === "GET") return route.continue();
        index.externalRequests.push(route.request().url());
        return route.abort();
      });
      const page = await context.newPage();
      page.on("pageerror", (error) => index.errors.push(`${device}/${scheme}: ${error.message}`));
      page.setDefaultTimeout(15000);
      for (const [view, query] of views) {
        await page.goto(`${origin}/tests/fixtures/connected.html${query}`, { waitUntil: "networkidle" });
        await page.waitForTimeout(700);
        const file = join(out, `${label}-${view}-${device}-${scheme}.png`);
        await page.screenshot({ path: file, fullPage: true });
        index.shots.push({ view, device, scheme, width, file });
      }
      await context.close();
    }
  }
  index.finishedAt = new Date().toISOString();
  await writeFile(join(out, `${label}-index.json`), JSON.stringify(index, null, 2));
  console.log(JSON.stringify({ shots: index.shots.length, errors: index.errors.length, external: index.externalRequests.length, out }));
} finally {
  await browser?.close();
  server?.close();
}
