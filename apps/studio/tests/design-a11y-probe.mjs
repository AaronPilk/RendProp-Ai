#!/usr/bin/env node
// Design accessibility and responsive probe over the synthetic connected
// fixture: text contrast, keyboard focus visibility, touch target sizes on a
// narrow phone, reduced-motion handling and horizontal overflow. Nothing
// private, no network. Exit code 1 when a check fails.
//   node tests/design-a11y-probe.mjs [--out=/path/to/report.json]
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "vite";
import { chromium } from "@playwright/test";

const args = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? true]; }));
const root = fileURLToPath(new URL("../", import.meta.url));
const dist = join(await mkdtemp(join(tmpdir(), "rendprop-design-a11y-")), "dist");
const LISTING = "55555555-5555-4555-8555-555555555500";
const views = ["overview", "properties", "editor", "creative", "library", "workspace"];
const report = { startedAt: new Date().toISOString(), checks: [], failures: [], errors: [] };
const pass = (name, detail) => report.checks.push({ name, detail });
const fail = (name, detail) => report.failures.push({ name, detail });

// WCAG relative luminance / contrast, computed in the page from resolved colours.
const CONTRAST_SCRIPT = `(() => {
  const parse = (c) => { const m = c.match(/rgba?\\(([^)]+)\\)/); if (!m) return null; const [r,g,b,a=1] = m[1].split(",").map(Number); return {r,g,b,a}; };
  const lum = ({r,g,b}) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v/12.92 : ((v+0.055)/1.055) ** 2.4; }; return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b); };
  const blend = (fg, bg) => ({ r: fg.r*fg.a + bg.r*(1-fg.a), g: fg.g*fg.a + bg.g*(1-fg.a), b: fg.b*fg.a + bg.b*(1-fg.a), a: 1 });
  const background = (el) => { let node = el, acc = null; while (node && node !== document.documentElement) { const c = parse(getComputedStyle(node).backgroundColor); if (c && c.a > 0) { acc = acc ? blend(acc, c) : c; if (acc.a >= 1 || c.a >= 1) { if (c.a >= 1) return acc; } } node = node.parentElement; } const page = parse(getComputedStyle(document.body).backgroundColor) ?? {r:255,g:255,b:255,a:1}; return acc ? blend(acc, page) : page; };
  const out = [];
  const seen = new Set();
  for (const el of document.querySelectorAll("button, a, p, span, small, label, h1, h2, h3, strong, summary, legend, option, li")) {
    if (!el.offsetParent && getComputedStyle(el).position !== "fixed") continue;
    const text = (el.childNodes.length && [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) ? el.textContent.trim().slice(0, 40) : "";
    if (!text) continue;
    const cs = getComputedStyle(el); const fg = parse(cs.color); if (!fg) continue;
    const bg = background(el); const f = fg.a < 1 ? blend(fg, bg) : fg;
    const l1 = lum(f), l2 = lum(bg); const ratio = (Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05);
    const size = parseFloat(cs.fontSize); const bold = parseInt(cs.fontWeight, 10) >= 600;
    const large = size >= 24 || (size >= 18.66 && bold);
    const key = el.className + "|" + text; if (seen.has(key)) continue; seen.add(key);
    out.push({ text, selector: (el.tagName.toLowerCase() + (el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\\s+/).join(".") : "")).slice(0, 80), ratio: Math.round(ratio*100)/100, size, large, required: large ? 3 : 4.5 });
  }
  return out;
})()`;

let server, browser;
try {
  await build({ configFile: false, root, publicDir: "public", logLevel: "error", build: { outDir: dist, emptyOutDir: true, rollupOptions: { input: join(root, "tests/fixtures/connected.html") } } });
  server = createServer(async (request, response) => {
    const path = resolve(dist, `.${new URL(request.url, "http://localhost").pathname}`);
    if (!path.startsWith(`${dist}/`) || request.method !== "GET") { response.writeHead(400).end(); return; }
    try { response.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".svg": "image/svg+xml" })[extname(path)] ?? "application/octet-stream"); response.end(await readFile(path)); } catch { response.writeHead(404).end(); }
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const open = async (context, view) => { const page = await context.newPage(); page.on("pageerror", (e) => report.errors.push(`${view}: ${e.message}`)); await page.goto(`${origin}/tests/fixtures/connected.html?view=${view}&listing=${LISTING}`, { waitUntil: "networkidle" }); await page.waitForTimeout(500); return page; };

  // 1. Contrast in light and dark, desktop.
  for (const scheme of ["light", "dark"]) {
    const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1440, height: 1000 }, colorScheme: scheme });
    let worst = []; let count = 0;
    for (const view of views) {
      const page = await open(context, view);
      const rows = await page.evaluate(CONTRAST_SCRIPT);
      count += rows.length;
      for (const row of rows) if (row.ratio < row.required) worst.push({ view, ...row });
      await page.close();
    }
    worst.sort((a, b) => a.ratio - b.ratio);
    report[`contrast-${scheme}`] = { sampled: count, below: worst.slice(0, 40) };
    const blocking = worst.filter((r) => r.ratio < 3);
    (blocking.length ? fail : pass)(`contrast ${scheme}`, `${count} text samples; ${worst.length} below WCAG AA target (${blocking.length} below 3:1)`);
    await context.close();
  }

  // 2. Keyboard focus visibility: Tab through the first 24 stops on each view.
  {
    const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1440, height: 1000 } });
    let stops = 0, invisible = [];
    for (const view of ["overview", "properties", "editor"]) {
      const page = await open(context, view);
      for (let i = 0; i < 24; i++) {
        await page.keyboard.press("Tab");
        const info = await page.evaluate(() => { const el = document.activeElement; if (!el || el === document.body) return null; const cs = getComputedStyle(el); return { tag: el.tagName, text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 30), outline: cs.outlineStyle, width: parseFloat(cs.outlineWidth), box: cs.boxShadow !== "none", border: cs.borderColor }; });
        if (!info) continue; stops++;
        const visible = (info.outline !== "none" && info.width >= 2) || info.box;
        if (!visible) invisible.push({ view, ...info });
      }
      await page.close();
    }
    report.focus = { stops, invisible };
    (invisible.length ? fail : pass)("focus visible", `${stops} tab stops; ${invisible.length} without a ≥2px outline or focus shadow`);
    await context.close();
  }

  // 3. Touch targets and horizontal overflow on a 390px phone.
  {
    const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
    let small = [], overflow = [], targets = 0;
    for (const view of views) {
      const page = await open(context, view);
      const width = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, inner: innerWidth }));
      if (width.scroll > width.inner + 1) overflow.push({ view, ...width });
      const rows = await page.evaluate(() => [...document.querySelectorAll("button, [role=tab], input[type=checkbox], input[type=radio], select, summary, .nav-item")].filter((el) => el.offsetParent || getComputedStyle(el).position === "fixed").map((el) => { const r = el.getBoundingClientRect(); return { tag: el.tagName, cls: String(el.className).slice(0, 40), text: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 30), w: Math.round(r.width), h: Math.round(r.height) }; }).filter((r) => r.w > 0 && r.h > 0));
      targets += rows.length;
      for (const row of rows) if (row.h < 40 && !/radio|checkbox/i.test(row.tag + row.cls) && row.tag !== "INPUT") small.push({ view, ...row });
      await page.close();
    }
    report.touch = { targets, small, overflow };
    (overflow.length ? fail : pass)("no horizontal overflow at 390px", `${views.length} views; ${overflow.length} overflowing`);
    (small.length ? fail : pass)("touch targets ≥40px on phone", `${targets} controls; ${small.length} shorter than 40px (18px checkbox/radio inputs sit inside ≥40px rows)`);
    await context.close();
  }

  // 4. Reduced motion: transitions and hover transforms are off.
  {
    const context = await browser.newContext({ serviceWorkers: "block", viewport: { width: 1440, height: 1000 }, reducedMotion: "reduce" });
    const page = await open(context, "properties");
    const card = page.locator(".app-feature-card").first();
    await card.hover();
    const motion = await card.evaluate((el) => { const cs = getComputedStyle(el); return { transition: cs.transitionDuration, transform: cs.transform }; });
    report.reducedMotion = motion;
    const ok = motion.transition.split(",").every((d) => parseFloat(d) === 0) && (motion.transform === "none" || motion.transform === "matrix(1, 0, 0, 1, 0, 0)");
    (ok ? pass : fail)("reduced motion", `feature card on hover: transition ${motion.transition}, transform ${motion.transform}`);
    await context.close();
  }
  report.status = report.failures.length || report.errors.length ? "failed" : "passed";
} catch (error) {
  report.status = "failed"; report.failure = error.stack ?? String(error);
} finally {
  await browser?.close(); server?.close();
  report.finishedAt = new Date().toISOString();
  if (args.out) { await mkdir(dirname(resolve(args.out)), { recursive: true }); await writeFile(resolve(args.out), `${JSON.stringify(report, null, 2)}\n`); }
  console.log(JSON.stringify({ status: report.status, checks: report.checks, failures: report.failures, errors: report.errors }, null, 2));
  if (report.status !== "passed") process.exitCode = 1;
}
