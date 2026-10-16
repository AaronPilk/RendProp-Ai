#!/usr/bin/env node
// Real rendered property website pages in Chromium, exclusively on loopback.
// Covers the full-size photo viewer (previous/next, arrow keys, swipe,
// loading and failure states, focus return), WCAG AA contrast of the contact
// card/form/attribution text in all three designs, and the compact mobile
// navigation when a photo-based property video leads the page.
// No phone, customer content, purchase, provider or production request.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { buildSrc, ROOT } from "./build-src.mjs";

const arg = (name) => process.argv.slice(2).find((x) => x.startsWith(name + "="))?.slice(name.length + 1);
const evidence = arg("--evidence") ? resolve(arg("--evidence")) : mkdtempSync(join(tmpdir(), "rendprop-property-site-browser-"));
mkdirSync(evidence, { recursive: true });
const { chromium } = await import(pathToFileURL(arg("--playwright") || resolve(ROOT, "../../../apps/studio/node_modules/@playwright/test/index.mjs")).href);
const load = buildSrc("property-site-browser-" + process.pid);
const { renderTourPage } = await load("player");
const { buildDemoTour } = await load("demo");
const { propertyPage } = await load("property-site");

const checks = [];
const check = (condition, label) => { assert.ok(condition, label); checks.push(label); };
const svg = (label, color) => `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1200"><rect width="1600" height="1200" fill="${color}"/><text x="80" y="600" font-size="96" fill="white">SYNTHETIC ${label}</text></svg>`;
const PHOTOS = [["Front exterior", "#264653"], ["Living room", "#2a9d8f"], ["Kitchen", "#8a5a44"], ["Primary bedroom", "#6d597a"], ["Terrace", "#355070"], ["Broken file", "#000000"]];
const photoPath = (i) => i === 5 ? "/photos/missing-5.svg" : `/photos/photo-${i}.svg`;
let theme = "basic", useThumbs = false, thumbFailure = false;
function fixture() {
  const t = buildDemoTour();
  t.slug = "synthetic-site"; t.website_theme = theme;
  t.listing = { address: "123 Synthetic Lane, Example, FL 33000", tagline: null, details: { story: "Synthetic description.", show_app_cta: false, show_partners: false }, beds: 3, baths: 2, sqft: 1800, price_cents: 50000000, price: null, lat: 27.9, lng: -82.5 };
  t.cover_url = photoPath(0); t.poster = "/posters/poster.svg";
  t.gallery = PHOTOS.map(([label], i) => ({ url: photoPath(i), label, ...(useThumbs ? { thumb_url: photoPath(i).replace("/photos/", "/thumbs/") } : {}) }));
  t.listing_video = { url: "/media/master.mp4", poster_url: "/posters/poster.svg", width: 1920, height: 1080, duration_s: 30, disclosure: "Synthetic photo-based video.", branding_policy: "unbranded" };
  t.video_url = t.scrub_url = "/media/recorded.mp4"; t.hls_url = null; t.duration_s = 30; t.chapters = [];
  t.staged = false; t.altered_media = []; t.floorplan_url = null; t.published_at = "2026-10-01T00:00:00Z";
  t.agent_card = { name: "Synthetic Contact", brokerage: "Example Realty", phone: "5550100100", email: "contact@example.invalid", website: "https://contact.example.invalid", instagram: "synthetic-agent", twitter: "synthetic-agent" };
  t.cta = { mode: "lead_form", label: "Request a showing", url: null, secondary: [], lead_fields: ["name", "phone", "email", "message"] };
  return t;
}
const requests = [];
let origin;
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1"); requests.push(url.pathname);
  if (thumbFailure && url.pathname === "/thumbs/photo-0.svg") { res.writeHead(503); res.end("synthetic thumbnail outage"); return; }
  if (url.pathname === "/posters/poster.svg") { res.writeHead(200, { "Content-Type": "image/svg+xml" }); res.end(svg("POSTER", "#333333")); return; }
  const photo = url.pathname.match(/^\/(?:photos|thumbs)\/photo-(\d)\.svg$/);
  if (photo) { res.writeHead(200, { "Content-Type": "image/svg+xml", "Cache-Control": "no-store" }); res.end(svg(PHOTOS[Number(photo[1])][0], PHOTOS[Number(photo[1])][1])); return; }
  if (url.pathname === "/f/synthetic-site/nearby") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ status: "available", places: [{ name: "Synthetic Café", category: "Cafe", distance_m: 300, source_url: "https://www.openstreetmap.org/node/1" }] })); return; }
  if (url.pathname === "/property/synthetic-site") {
    const html = renderTourPage(fixture(), origin + "/closed-api", "", "", { origin, page: propertyPage(url.searchParams.get("page")), publicBase: "/property" });
    res.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" }); res.end(html); return;
  }
  res.writeHead(404); res.end("not found");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
origin = "http://127.0.0.1:" + server.address().port;
const browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
const errors = [];
const measurements = [];
try {
  for (theme of ["basic", "signature-estate", "coastal-luxe"]) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await context.route("**/*", (route) => { const u = new URL(route.request().url()); return u.origin === origin || u.protocol === "data:" ? route.continue() : route.abort(); });
    const page = await context.newPage(); page.on("pageerror", (e) => errors.push(theme + ": " + e));

    // Photo viewer on the dedicated Gallery page.
    await page.goto(origin + "/property/synthetic-site?page=gallery", { waitUntil: "networkidle" });
    const links = page.locator("[data-property-photo]");
    check(await links.count() === PHOTOS.length, theme + ": Gallery keeps every published photo");
    const full = page.locator("#property-photo-full"), count = page.locator("#property-photo-count"), status = page.locator("#property-photo-status");
    const href = (i) => origin + photoPath(i);
    await links.nth(0).click();
    await page.waitForFunction(() => document.querySelector("#property-photo-full").naturalWidth > 0);
    check(await page.locator("#property-photo-modal").evaluate((el) => el.open), theme + ": Photo opens in the full-size viewer");
    check(await count.innerText() === "1 of " + PHOTOS.length && await page.locator("#property-photo-prev").isDisabled() && !(await page.locator("#property-photo-next").isDisabled()), theme + ": Viewer shows position and offers Next from the first photo");
    await page.keyboard.press("ArrowRight");
    await page.waitForFunction(() => document.querySelector("#property-photo-full").complete);
    check(await full.evaluate((img) => img.src) === href(1) && await count.innerText() === "2 of " + PHOTOS.length, theme + ": Right arrow shows the next exact published photo");
    check(await page.locator("#property-photo-title").innerText() === "Living room", theme + ": Viewer title follows the photo label");
    await page.locator("#property-photo-next").click();
    check(await full.evaluate((img) => img.src) === href(2), theme + ": Next button advances");
    await full.evaluate((img) => {
      const r = img.getBoundingClientRect(), y = r.top + r.height / 2;
      img.dispatchEvent(new PointerEvent("pointerdown", { pointerId: 7, pointerType: "touch", clientX: r.left + r.width * .8, clientY: y, bubbles: true }));
      img.dispatchEvent(new PointerEvent("pointerup", { pointerId: 7, pointerType: "touch", clientX: r.left + r.width * .2, clientY: y + 6, bubbles: true }));
    });
    check(await full.evaluate((img) => img.src) === href(3), theme + ": A left swipe shows the next photo");
    await full.evaluate((img) => {
      const r = img.getBoundingClientRect(), x = r.left + r.width / 2;
      img.dispatchEvent(new PointerEvent("pointerdown", { pointerId: 8, pointerType: "touch", clientX: x, clientY: r.top + 20, bubbles: true }));
      img.dispatchEvent(new PointerEvent("pointerup", { pointerId: 8, pointerType: "touch", clientX: x + 30, clientY: r.top + 220, bubbles: true }));
    });
    check(await full.evaluate((img) => img.src) === href(3), theme + ": A vertical drag does not change photos");
    await page.keyboard.press("ArrowLeft");
    check(await full.evaluate((img) => img.src) === href(2), theme + ": Left arrow returns to the previous photo");

    await page.keyboard.press("ArrowRight");
    await page.waitForFunction(() => !document.querySelector("#property-photo-modal").hasAttribute("aria-busy"));
    // Read the state in the same task as the step: no load event can have run yet.
    const pending = await page.evaluate(() => { const modal = document.getElementById("property-photo-modal"); modal.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); return { busy: modal.getAttribute("aria-busy"), status: document.getElementById("property-photo-status").textContent }; });
    check(pending.busy === "true" && pending.status.includes("Loading the full-size photo"), theme + ": A full-size photo shows an honest loading state until it arrives");
    await page.waitForFunction(() => !document.querySelector("#property-photo-modal").hasAttribute("aria-busy"));
    check(await status.innerText() === "" && await full.evaluate((img) => img.naturalWidth > 0) && await full.evaluate((img) => img.src) === href(4), theme + ": Loading state clears once the photo arrives");
    await page.locator("#property-photo-next").click();
    await page.waitForFunction(() => !document.querySelector("#property-photo-modal").hasAttribute("aria-busy"));
    check((await status.innerText()).includes("could not load") && await page.locator("#property-photo-next").isDisabled(), theme + ": A missing photo reports a failure instead of a blank viewer");
    check(await page.evaluate(() => document.activeElement && document.activeElement.id) === "property-photo-prev", theme + ": Focus moves to Previous when Next ends");
    await page.keyboard.press("Escape");
    check(await full.getAttribute("src") === null && await links.nth(5).evaluate((el) => document.activeElement === el), theme + ": Escape closes, unloads the photo and focuses the last viewed photo");

    // Mobile navigation and contact contrast on Home.
    await page.goto(origin + "/property/synthetic-site", { waitUntil: "networkidle" });
    check(await page.getByRole("button", { name: "Play property video" }).first().isVisible(), theme + ": Navigation play button keeps its full accessible name");
    for (const target of ["home", "gallery"]) {
      if (target === "gallery") await page.goto(origin + "/property/synthetic-site?page=gallery", { waitUntil: "networkidle" });
      const nav = await page.evaluate(() => {
        const n = document.getElementById("listing-nav").getBoundingClientRect();
        const actions = [...document.querySelectorAll(".listing-nav-actions > *")].map((el) => { const r = el.getBoundingClientRect(); return { top: r.top, height: r.height, width: r.width }; });
        return { height: n.height, actions };
      });
      measurements.push({ theme, target, ...nav });
      check(nav.height <= 114, `${theme}: ${target} navigation stays within the compact mobile height (${nav.height}px)`);
      check(nav.actions.every((a) => a.height >= 44 && a.width >= 44 && Math.abs(a.top - nav.actions[0].top) < 1), `${theme}: ${target} navigation actions stay aligned and tappable`);
    }
    await page.goto(origin + "/property/synthetic-site", { waitUntil: "networkidle" });
    check(await page.locator("#property-photo-modal .property-photo-all").getAttribute("href") === "/property/synthetic-site?page=gallery", theme + ": Home photo viewer links to the complete Gallery when it previews a subset");

    const contrast = async (selector) => page.locator(selector).first().evaluate((el) => {
      const parse = (c) => { const m = c.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(/[ ,/]+/).filter(Boolean).map(Number); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; };
      const layers = []; for (let n = el; n; n = n.parentElement) { const b = parse(getComputedStyle(n).backgroundColor); if (b && b.a > 0) { layers.push(b); if (b.a >= 1) break; } }
      let bg = { r: 255, g: 255, b: 255 }; for (const l of layers.reverse()) bg = { r: l.r * l.a + bg.r * (1 - l.a), g: l.g * l.a + bg.g * (1 - l.a), b: l.b * l.a + bg.b * (1 - l.a) };
      const fgRaw = parse(getComputedStyle(el).color), opacity = [...function* () { for (let n = el; n; n = n.parentElement) yield Number(getComputedStyle(n).opacity); }()].reduce((a, b) => a * b, 1);
      const alpha = fgRaw.a * opacity, fg = { r: fgRaw.r * alpha + bg.r * (1 - alpha), g: fgRaw.g * alpha + bg.g * (1 - alpha), b: fgRaw.b * alpha + bg.b * (1 - alpha) };
      const lum = ({ r, g, b }) => [r, g, b].map((v) => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }).reduce((s, v, i) => s + v * [.2126, .7152, .0722][i], 0);
      const [hi, lo] = [lum(fg), lum(bg)].sort((a, b) => b - a); return (hi + .05) / (lo + .05);
    });
    for (const selector of [".agent .avatar", ".agent .social a", ".field .lbl .opt"]) {
      const ratio = await contrast(selector); measurements.push({ theme, selector, ratio });
      check(ratio >= 4.5, `${theme}: ${selector} text meets 4.5:1 contrast (${ratio.toFixed(2)})`);
    }
    const checkContactTargets = async (pageName) => {
      for (const selector of [".agent .who .bk a[href^='tel:']", ".agent .social a"]) {
        const targets = await page.locator(selector).all();
        check(targets.length > 0, theme + ": " + pageName + " exercises " + selector);
        for (const target of targets) {
          const box = await target.boundingBox();
          const fontSize = await target.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
          measurements.push({ theme, pageName, selector, label: await target.innerText(), ...box, fontSize });
          check(box && box.height >= 44 && box.width >= 44, theme + ": " + pageName + " phone and contact links have 44px touch targets (" + selector + ")");
          check(fontSize <= 14 && box.height <= 52, theme + ": " + pageName + " contact targets keep compact text and spacing");
          check(box.x >= 0 && box.x + box.width <= 390, theme + ": " + pageName + " contact targets fit the phone viewport");
        }
      }
      check(await page.locator(".agent .social a[href^='mailto:']").count() === 1 && await page.locator(".agent .social a").filter({ hasText: /^Website$/ }).count() === 1, theme + ": " + pageName + " explicitly exercises Email and Website");
    };
    await checkContactTargets("Home");
    await page.goto(origin + "/property/synthetic-site?page=location", { waitUntil: "networkidle" });
    const attribution = await contrast(".lp-fine a"); measurements.push({ theme, selector: ".lp-fine a", ratio: attribution });
    check(attribution >= 4.5, `${theme}: map attribution link meets 4.5:1 contrast (${attribution.toFixed(2)})`);
    check(await page.locator(".property-location-visual svg").count() === 1, theme + ": Location marker is drawn as an icon, not a font-dependent glyph");
    await page.screenshot({ path: join(evidence, theme + "-mobile-location.png") });
    await page.goto(origin + "/property/synthetic-site?page=contact", { waitUntil: "networkidle" });
    check(await page.getByRole("region", { name: "Contact the listing agent" }).locator("#leadform").count() === 1, theme + ": Contact card and form sit in a named landmark");
    await checkContactTargets("Contact");
    await page.screenshot({ path: join(evidence, theme + "-mobile-contact.png") });
    await context.close();
  }

  // Optional server derivative (`thumb_url`): the grid downloads only the
  // smaller files; the viewer and the no-JS link still open the exact master.
  theme = "basic"; useThumbs = true;
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await context.route("**/*", (route) => { const u = new URL(route.request().url()); return u.origin === origin || u.protocol === "data:" ? route.continue() : route.abort(); });
    const page = await context.newPage(); page.on("pageerror", (e) => errors.push("thumbs: " + e));
    requests.length = 0;
    await page.goto(origin + "/property/synthetic-site?page=gallery", { waitUntil: "networkidle" });
    for (const image of await page.locator("img.property-thumb").all()) await image.scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    check(requests.some((p) => p.startsWith("/thumbs/")) && !requests.some((p) => p.startsWith("/photos/") && p !== photoPath(5)), "Gallery grid fetches working derivatives, not their full masters");
    check(await page.locator("[data-property-photo]").first().getAttribute("href") === photoPath(0), "Photo link still targets the exact published master");
    await page.locator("[data-property-photo]").first().click();
    await page.waitForFunction(() => document.querySelector("#property-photo-full").naturalWidth > 0);
    check(await page.locator("#property-photo-full").evaluate((img) => new URL(img.src).pathname) === photoPath(0), "Viewer opens the exact master, not the derivative");
    thumbFailure = true; requests.length = 0;
    await page.goto(origin + "/property/synthetic-site?page=gallery", { waitUntil: "networkidle" });
    const firstThumb = page.locator("img.property-thumb").first();
    await firstThumb.scrollIntoViewIfNeeded();
    await page.waitForFunction(() => { const image = document.querySelector('img.property-thumb'); return image.naturalWidth > 0 && new URL(image.src).pathname === '/photos/photo-0.svg'; });
    check(await firstThumb.evaluate((img) => new URL(img.src).pathname) === photoPath(0), "Thumbnail outage falls back to the exact published master");
    check(requests.filter((p) => p === "/thumbs/photo-0.svg").length === 1 && requests.filter((p) => p === photoPath(0)).length === 1, "Thumbnail fallback makes one bounded attempt for each exact file");
    check(await page.locator("[data-property-photo]").first().getAttribute("href") === photoPath(0), "Thumbnail fallback leaves the full-size photo link unchanged");
    thumbFailure = false;
    await context.close();
  }
  useThumbs = false;
  check(errors.length === 0, "No page JavaScript errors: " + errors.join("; "));
  writeFileSync(join(evidence, "receipt.json"), JSON.stringify({ passed: true, checks, measurements, scope: "Synthetic loopback pages and SVG photos; no customer media, phone or production request." }, null, 2));
  console.log(`Property site browser: ${checks.length} real-browser assertions passed; receipt ${join(evidence, "receipt.json")}`);
} catch (error) {
  writeFileSync(join(evidence, "failure.json"), JSON.stringify({ passed: false, error: String(error && error.message || error), checks, measurements, errors }, null, 2));
  throw error;
} finally {
  await browser.close(); server.close();
}
