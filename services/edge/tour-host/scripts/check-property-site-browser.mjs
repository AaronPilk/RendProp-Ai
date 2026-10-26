#!/usr/bin/env node
// Real rendered property website pages in Chromium, exclusively on loopback.
// Covers the full-size photo viewer (previous/next, arrow keys, swipe,
// loading and failure states, focus return), WCAG AA contrast of the contact
// card/form/attribution text in all three designs, and the compact mobile
// navigation when a photo-based property video leads the page.
// No phone, customer content, purchase, provider or production request.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
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
const { renderNearbyMap } = await load("nearby-map");

const checks = [];
const check = (condition, label) => { assert.ok(condition, label); checks.push(label); };
const svg = (label, color, portrait = false) => `<svg xmlns="http://www.w3.org/2000/svg" width="${portrait ? 900 : 1600}" height="${portrait ? 1600 : 1200}"><rect width="100%" height="100%" fill="${color}"/><text x="80" y="600" font-size="96" fill="white">SYNTHETIC ${label}</text></svg>`;
const PHOTOS = [["Front exterior", "#264653"], ["Living room", "#2a9d8f"], ["Kitchen", "#8a5a44"], ["Primary bedroom", "#6d597a"], ["Terrace", "#355070"], ["Broken file", "#000000"]];
const photoPath = (i) => i === 5 ? "/photos/missing-5.svg" : `/photos/photo-${i}.svg`;
let theme = "basic", useThumbs = false, thumbFailure = false, presentation = "video", longAddress = false, roomLabels = false, noAddress = false;
// Nine synthetic places around the coarsened fixture origin; the map is
// drawn by the real server function and served the way the Worker serves it.
const mapOrigin = { lat: 27.9, lng: -82.5 }, degree = 6_371_008.8 * Math.PI / 180;
const nearbyPlace = (name, category, bearing, metres, id) => { const rad = bearing * Math.PI / 180; return { name, category, lat: mapOrigin.lat + metres * Math.cos(rad) / degree, lng: mapOrigin.lng + metres * Math.sin(rad) / (degree * Math.cos(mapOrigin.lat * Math.PI / 180)), distance_m: metres, source_url: `https://www.openstreetmap.org/node/${id}` }; };
const nearbyResult = { status: "available", attribution: "© OpenStreetMap contributors", places: [nearbyPlace("Harbor Grill & Oyster House", "Restaurant", 35, 420, 1), nearbyPlace("Trattoria Luna", "Restaurant", 120, 760, 2), nearbyPlace("The Longest Restaurant Name In Town Ever", "Restaurant", 200, 1180, 3), nearbyPlace("Kahwa Coffee", "Cafe", 60, 300, 4), nearbyPlace("Bandit Coffee Co.", "Cafe", 250, 640, 5), nearbyPlace("Black Crow Café", "Cafe", 300, 1320, 6), nearbyPlace("Publix", "Shop", 170, 980, 7), nearbyPlace("Rollin' Oats Market", "Shop", 320, 450, 8), nearbyPlace("Haslam's Books", "Shop", 90, 1450, 9)] };
const nearbyMapHtml = renderNearbyMap(nearbyResult, mapOrigin);
// A dense downtown block: nine places within 300 m with long names, the case
// where the original label layout overlapped names and covered a ring distance.
const downtownResult = { status: "available", attribution: "© OpenStreetMap contributors", places: [nearbyPlace("Central Oyster Bar & Grill", "Restaurant", 60, 140, 21), nearbyPlace("Harborside Trattoria", "Restaurant", 125, 210, 22), nearbyPlace("Mezcal Cantina", "Restaurant", 300, 260, 23), nearbyPlace("Morning Ritual Coffee Roasters", "Cafe", 20, 95, 24), nearbyPlace("Banyan Tree Café", "Cafe", 160, 120, 25), nearbyPlace("Black Crow Coffee", "Cafe", 235, 230, 26), nearbyPlace("Downtown Fresh Market", "Shop", 95, 175, 27), nearbyPlace("Tombolo Books", "Shop", 275, 110, 28), nearbyPlace("Waterfront Gallery Shop", "Shop", 345, 300, 29)] };
function fixture() {
  const t = buildDemoTour();
  t.slug = "synthetic-site"; t.website_theme = theme;
  t.listing = { address: "123 Synthetic Lane, Example, FL 33000", tagline: null, details: { story: "Synthetic description.", show_app_cta: false, show_partners: false }, beds: 3, baths: 2, sqft: 1800, price_cents: 50000000, price: null, lat: 27.9, lng: -82.5 };
  if (longAddress) { t.listing.address = "12345 Synthetic Architectural Promenade, Residence Twelve, Example, FL 33000"; t.listing.price_cents = null; }
  if (noAddress) t.listing.address = null;
  t.cover_url = photoPath(0); t.poster = "/posters/poster.svg";
  t.gallery = PHOTOS.map(([label], i) => ({ url: photoPath(i), label: roomLabels ? ["Kitchen", "Living room", "Kitchen", "Primary bedroom", "Terrace", "Kitchen"][i] : label, ...(useThumbs ? { thumb_url: photoPath(i).replace("/photos/", "/thumbs/") } : {}) }));
  t.listing_video = { url: "/media/master.mp4", poster_url: "/posters/poster.svg", width: 1920, height: 1080, duration_s: 30, disclosure: "Synthetic photo-based video.", branding_policy: "unbranded" };
  if (presentation === "photo") t.listing_video = null;
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
  if (photo) { res.writeHead(200, { "Content-Type": "image/svg+xml", "Cache-Control": "no-store" }); res.end(svg(PHOTOS[Number(photo[1])][0], PHOTOS[Number(photo[1])][1], Number(photo[1]) === 1)); return; }
  if (url.pathname === "/f/synthetic-site/nearby") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ ...nearbyResult, map_html: nearbyMapHtml, license_url: "https://www.openstreetmap.org/copyright" })); return; }
  if (url.pathname === "/property/synthetic-site") {
    noAddress = url.searchParams.has("noaddress");
    let html = renderTourPage(fixture(), origin + "/closed-api", "", "", { origin, page: propertyPage(url.searchParams.get("page")), publicBase: "/property", previewTheme:url.searchParams.get("preview_theme"), nearby: url.searchParams.get("cached") === "downtown" ? downtownResult : url.searchParams.has("cached") ? nearbyResult : null });
    if (arg("--fault") === "omit-preview-offset") {
      assert.equal(html.split("Math.max(navHeight,previewHeight)").length - 1, 1, "one exact preview-offset expression is omitted");
      html = html.replace("Math.max(navHeight,previewHeight)", "navHeight");
    }
    res.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" }); res.end(arg("--fault")==="skip-target" ? html.replace('class="property-skip-link" href="#property-content"','class="property-skip-link" href="#listing-top"') : html); return;
  }
  res.writeHead(404); res.end("not found");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
origin = "http://127.0.0.1:" + server.address().port;
const browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
const errors = [];
const measurements = [];
const presentationChecks = [];
function withoutPropertyBypass(html) {
  const legacyMain='<main id="listing-page">';
  if (html.includes(legacyMain)) {
    check(html.split(legacyMain).length===2 && (html.match(/<main\b/g)||[]).length===1 && html.split("</main>").length===2, "Classic comparison relocates only the one existing listing-page landmark");
    html=html.replace(legacyMain,'<div id="listing-page">').replace("</main>","</div>");
  }
  const parts = ['<a class="property-skip-link" href="#property-content">Skip to property content</a>\n', '<main id="property-content" tabindex="-1">\n', '</main>\n'];
  const counts=parts.map(part=>html.split(part).length-1);
  if (counts.every(count=>count===0)) return html;
  check(counts.every(count=>count===1), "Classic comparison permits only one exact skip link and main wrapper");
  return parts.reduce((value,part)=>value.replace(part,""),html);
}

try {
  // Same actual listing/media rendered in each composition. This regression
  // fails the former phone layout where both premiums put film before copy.
  for (const width of [390, 1440]) for (presentation of ["video", "photo"]) {
    for (theme of ["basic", "signature-estate", "coastal-luxe"]) {
      const context = await browser.newContext({ viewport: { width, height: width === 390 ? 844 : 1000 } });
      await context.route("**/*", route => new URL(route.request().url()).origin === origin || route.request().url().startsWith("data:") ? route.continue() : route.abort());
      const page = await context.newPage(); page.on("pageerror", e => errors.push(theme + ": " + e));
      await page.goto(origin + "/property/synthetic-site", { waitUntil: "networkidle" });
      const composition = await page.evaluate(() => {
        const box = el => { const r = el.getBoundingClientRect(); return { x:r.x,y:r.y,width:r.width,height:r.height,bottom:r.bottom,right:r.right }; };
        const media = document.querySelector(".property-video-stage") || document.querySelector(".listing-cover > img,.property-hero-media > img");
        const lum = color => color.match(/[\d.]+/g).slice(0,3).map(Number).map(value => { value /= 255; return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4; }).reduce((sum,value,index) => sum + value * [.2126,.7152,.0722][index],0);
        const watchContrast = [...document.querySelectorAll("#listing-nav .watch-button")].map(button => { const style = getComputedStyle(button); const [hi,lo] = [lum(style.color),lum(style.backgroundColor)].sort((a,b) => b-a); return (hi+.05)/(lo+.05); });
        const stage = document.querySelector(".property-video-stage"), status = document.getElementById("property-video-status"), play = document.getElementById("property-video-play");
        const hero = stage ? { film:stage.classList.contains("property-film"),text:stage.textContent.replace(/\s+/g," ").trim(),status:status.textContent,statusLive:status.getAttribute("aria-live"),statusRole:status.getAttribute("role"),label:stage.querySelector(".property-film-label")?.textContent ?? null,play:play.textContent.replace(/\s+/g," ").trim(),playHidden:play.hidden,videoLabel:document.getElementById("property-video").getAttribute("aria-label"),preload:document.getElementById("property-video").getAttribute("preload"),src:document.getElementById("property-video").getAttribute("src"),backdrop:stage.querySelectorAll(".property-film-backdrop").length } : null;
        return { media:box(media),copy:box(document.querySelector(".property-hero-copy")),title:box(document.querySelector(".property-hero-title")),nav:box(document.querySelector("#listing-nav")),overflow:document.documentElement.scrollWidth > innerWidth,bodyText:document.body.innerText,watchContrast,contain:document.querySelector("#property-video") ? getComputedStyle(document.querySelector("#property-video")).objectFit : null,hero };
      });
      measurements.push({ theme,width,presentation,composition });
      const tag = `${theme}-${width}-${presentation}`;
      for (const image of await page.locator("img.property-thumb").all()) {
        await image.scrollIntoViewIfNeeded();
        await image.evaluate(img => img.naturalWidth > 1 ? Promise.resolve() : new Promise((resolve,reject) => { img.addEventListener("load",resolve,{once:true});img.addEventListener("error",reject,{once:true}); }));
      }
      await page.evaluate(() => scrollTo(0,0));
      await page.screenshot({path:join(evidence,tag+"-viewport.png")});
      await page.screenshot({ path:join(evidence,tag+".png"),fullPage:true });
      if (theme === "basic") {
        const html = renderTourPage(fixture(), origin + "/closed-api", "", "", { origin,page:"home",publicBase:"/property" }).replace(/<style>[\s\S]*?<\/style>/g,"<style></style>").replaceAll(origin,"http://closed-loopback.invalid");
        writeFileSync(join(evidence,tag+".html"),html);
        if(arg("--classic-baseline")) check(withoutPropertyBypass(html) === withoutPropertyBypass(readFileSync(join(resolve(arg("--classic-baseline")),tag+".html"),"utf8")),tag+": Classic markup changes only by the exact semantic bypass link/main wrapper outside existing CSS checks");
      }
      check(!composition.overflow,tag+": no horizontal overflow");
      if(presentation === "video") check(composition.contain === "contain" && Math.abs(composition.media.width/composition.media.height-16/9)<.01,tag+": full16:9 film remains contain, independent of page height");
      // W1 hero copy per design. Premium designs present a film (running time,
      // one quiet play mark, loading-only status); Classic keeps its exact copy.
      if (presentation === "video") {
        const hero = composition.hero;
        check(hero && hero.statusRole === "status" && hero.statusLive === "polite" && hero.preload === "none" && hero.src === null && !hero.playHidden, tag+": every design keeps explicit opt-in play and the polite status region");
        if (theme === "basic") {
          check(!hero.film && hero.backdrop === 0 && hero.label === null, tag+": Classic hero is not the premium film presentation");
          check(hero.status === "1920 × 1080 · Select Play to load the video." && hero.play === "Play property video ▶" && hero.videoLabel === "Property video for 123 Synthetic Lane, Example, FL 33000", tag+": Classic hero keeps its exact dimension/status copy and play label");
        } else {
          check(hero.film && hero.backdrop === 1, tag+": premium hero is the film presentation with a full-bleed poster backdrop");
          check(!/\d\s*×\s*\d/.test(hero.text) && !hero.text.includes("Select Play") && !hero.text.includes("1920"), tag+": premium hero shows no pixel-dimension string");
          check(hero.label === "Property film · 0:30" && hero.status === "" && hero.play === "Play the film" && hero.videoLabel === "Property film for 123 Synthetic Lane, Example, FL 33000", tag+": premium hero reads as a film with its running time, one play control and a silent status until loading");
          const settled = await page.evaluate(async () => {
            await Promise.all(document.getAnimations().map(a => a.finished.catch(() => {})));
            const stage = document.querySelector(".property-video-stage"), video = document.getElementById("property-video"), play = document.getElementById("property-video-play");
            return { stage:getComputedStyle(stage).opacity, stageTransform:getComputedStyle(stage).transform, video:getComputedStyle(video).transform, play:getComputedStyle(play).opacity, label:getComputedStyle(stage.querySelector(".property-film-label")).opacity, reduced:matchMedia("(prefers-reduced-motion: reduce)").matches };
          });
          measurements.push({ theme, width, presentation, settled });
          const identity = value => value === "none" || value === "matrix(1, 0, 0, 1, 0, 0)";
          check(settled.stage === "1" && identity(settled.stageTransform) && identity(settled.video) && settled.play === "1" && settled.label === "1", tag+": film arrive motion settles to fully visible, untransformed media");
        }
      }
      if (theme !== "basic") presentationChecks.push([composition.watchContrast.length > 0 && composition.watchContrast.every(ratio => ratio >= 4.5),tag+": film navigation text meets 4.5:1 contrast with either primary media"]);
      if (theme !== "basic") {
        // Photo-led paid pages place the address on the property image. A real
        // 16:9 Listing film stays uncropped; on phones its address follows the
        // film in the same first screen instead of covering the play target.
        const photoOverlay = presentation === "photo" && composition.copy.y >= composition.media.y && composition.copy.bottom <= composition.media.bottom + 1;
        const phoneFilm = presentation === "video" && width === 390 && composition.copy.y >= composition.media.bottom - 1;
        const desktopFilm = presentation === "video" && width !== 390 && composition.copy.y >= composition.media.y && composition.copy.bottom <= composition.media.bottom + 1 && composition.copy.x < composition.media.x + composition.media.width / 2;
        presentationChecks.push([photoOverlay || phoneFilm || desktopFilm,tag+": paid identity follows the immersive photo or uncropped film layout"]);
        presentationChecks.push([composition.title.y < (width === 390 ? 844 : 1000),tag+": property address is visible in the opening viewport"]);
      }
      await context.close();
    }
  }
  for (const [condition,label] of presentationChecks) check(condition,label);
  presentation = "video";
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
    check(await full.evaluate(img => img.naturalHeight > img.naturalWidth && getComputedStyle(img).objectFit === "contain"),theme+": portrait master stays complete in the mixed-aspect viewer");
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
        return { height: n.height, actions:actions.filter(a => a.width > 0 && a.height > 0) };
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
    for (const selector of [".agent .avatar", ".agent .social a", ".field .lbl .opt", ...(theme === "basic" ? [] : [".property-hero-title", ".property-hero-price", ".lp-stat .k", ".property-page-menu summary"])]) {
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
    if (theme === "signature-estate") {
      const display = await page.locator(".panel h2").first().evaluate(el => ({ family:getComputedStyle(el).fontFamily,weight:getComputedStyle(el).fontWeight }));
      check(/Georgia|Palatino|Iowan/.test(display.family) && display.weight === "400", "Signature contact keeps its editorial serif instead of being reset by shared sans rules");
    }
    await page.screenshot({ path: join(evidence, theme + "-mobile-contact.png") });
    await context.close();
  }

  // Native anchor navigation must work without scripts in every page/theme.
  // The link cannot play media, submit a form, or depend on an onclick hook.
  for (const width of [390,1440]) for (theme of ["basic","signature-estate","coastal-luxe"]) for (const target of width===390 ? ["home","gallery","location","contact"] : ["home"]) {
    const context=await browser.newContext({viewport:{width,height:844},javaScriptEnabled:false});
    await context.route("**/*",route=>new URL(route.request().url()).origin===origin || route.request().url().startsWith("data:") ? route.continue() : route.abort());
    const page=await context.newPage();
    for (const preview of target==="home" ? [false,true] : [false]) {
      const params=new URLSearchParams();if(target!=="home")params.set("page",target);if(preview)params.set("preview_theme",theme);
      await page.goto(origin+"/property/synthetic-site"+(params.size?"?"+params:""),{waitUntil:"networkidle"});
      const tag=`${theme}/${target}/${width}/${preview?"preview":"published"}`;
      const main=page.getByRole("main"),skip=page.getByRole("link",{name:"Skip to property content",exact:true});
      check(await main.count()===1 && await skip.count()===1,tag+": one semantic main and native bypass");
      await page.keyboard.press("Tab");
      check(await skip.evaluate(el=>document.activeElement===el),tag+": first Tab reaches bypass before repeated navigation");
      const visible=await skip.evaluate(el=>{const r=el.getBoundingClientRect();return r.top>=0 && r.left>=0 && r.right<=innerWidth && r.height>=44 && el.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));});
      check(visible,tag+": focused bypass is visible, unobscured and44px");
      const mediaBefore=requests.filter(path=>path.startsWith("/media/")).length;
      await page.keyboard.press("Enter");
      check(await main.evaluate(el=>document.activeElement===el),tag+": native Enter focuses main with JavaScript disabled");
      const geometry=await main.evaluate(el=>{const top=el.getBoundingClientRect().top;const obstruction=[...document.querySelectorAll('#listing-nav,.property-preview-banner')].filter(node=>getComputedStyle(node).position==='sticky').reduce((max,node)=>Math.max(max,node.getBoundingClientRect().bottom),0);return{top,obstruction};});
      measurements.push({tag,...geometry});
      check(geometry.top>=geometry.obstruction-1,tag+": main target clears sticky navigation/preview chrome");
      const tabbable=await main.locator('a[href],button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),summary,video[controls]').count();
      if(tabbable){await page.keyboard.press("Tab");check(await main.evaluate(el=>el.contains(document.activeElement)),tag+": next Tab stays in property content");}
      check(requests.filter(path=>path.startsWith("/media/")).length===mediaBefore,tag+": bypass does not start opt-in media");
      check(await main.locator("nav,footer,dialog").count()===0,tag+": page chrome and dialogs stay outside main");
      check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),tag+": semantic wrapper adds no horizontal overflow");
    }
    await context.close();
  }

  // Real script-enabled anchors must clear whichever preview/header surface
  // actually remains sticky. A short premium nav must not hide a taller banner.
  // The existing no-script, full-size viewer, media and header checks stay below.
  for (const width of [390,1440]) for (theme of ["basic","signature-estate","coastal-luxe"]) {
    const context=await browser.newContext({viewport:{width,height:844}});
    await context.route("**/*",route=>new URL(route.request().url()).origin===origin || route.request().url().startsWith("data:") ? route.continue() : route.abort());
    const page=await context.newPage();page.on("pageerror",error=>errors.push("scripted-skip: "+error));
    for (const preview of [false,true]) {
      await page.goto(origin+"/property/synthetic-site"+(preview?"?preview_theme="+theme:""),{waitUntil:"networkidle"});
      const tag=`scripted/${theme}/home/${width}/${preview?"preview":"published"}`;
      const main=page.getByRole("main"),skip=page.getByRole("link",{name:"Skip to property content",exact:true});
      const chrome=await page.evaluate(()=>{
        const box=node=>{if(!node)return null;const rect=node.getBoundingClientRect(),style=getComputedStyle(node);return{height:rect.height,top:rect.top,bottom:rect.bottom,position:style.position,stickyTop:style.top};};
        return{nav:box(document.getElementById("listing-nav")),banner:box(document.querySelector(".property-preview-banner")),offset:getComputedStyle(document.documentElement).getPropertyValue("--listing-nav-offset")};
      });
      measurements.push({tag,type:"scripted-skip-before",...chrome});
      check(preview ? chrome.nav.position==="relative" && chrome.banner?.position==="sticky" && chrome.banner.stickyTop==="0px" : chrome.nav.position==="sticky" && chrome.banner===null,tag+": preview banner and published navigation retain their actual separate positioning");
      check(await main.count()===1 && await skip.count()===1,tag+": one real main and native bypass");
      await page.keyboard.press("Tab");check(await skip.evaluate(el=>document.activeElement===el),tag+": first Tab reaches bypass");
      const mediaBefore=requests.filter(path=>path.startsWith("/media/")).length;
      await page.keyboard.press("Enter");
      check(await main.evaluate(el=>document.activeElement===el),tag+": native Enter focuses main with JavaScript enabled");
      await main.evaluate(el=>new Promise((resolve,reject)=>{
        let previous=null,stable=0;const deadline=performance.now()+3000;
        function frame(){const top=el.getBoundingClientRect().top;stable=previous!==null&&Math.abs(top-previous)<.01?stable+1:0;previous=top;if(stable>=3)return resolve();if(performance.now()>deadline)return reject(Error("Main scroll did not settle"));requestAnimationFrame(frame);}
        requestAnimationFrame(frame);
      }));
      const geometry=await main.evaluate(el=>{
        const surfaces=[...document.querySelectorAll("#listing-nav,.property-preview-banner")].map(node=>{const rect=node.getBoundingClientRect();return{selector:node.id?"#"+node.id:".property-preview-banner",position:getComputedStyle(node).position,top:rect.top,bottom:rect.bottom,height:rect.height};});
        return{top:el.getBoundingClientRect().top,obstruction:surfaces.filter(node=>node.position==="sticky").reduce((max,node)=>Math.max(max,node.bottom),0),surfaces,active:document.activeElement===el,scrollMargin:getComputedStyle(el).scrollMarginTop};
      });
      measurements.push({tag,type:"scripted-skip-clearance",...geometry});
      check(geometry.active && geometry.top>=geometry.obstruction-1,tag+": script-enabled main target clears actual sticky navigation/preview chrome");
      check(requests.filter(path=>path.startsWith("/media/")).length===mediaBefore,tag+": native bypass does not start opt-in media");
      check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),tag+": header clearance adds no horizontal overflow");
    }
    await context.close();
  }

  // Premium navigation remains native and complete with scripts disabled.
  // Reduced-motion/transparency are actual browser preferences, not CSS injected
  // to hide failures. All four page URLs remain normal public anchors.
  for (theme of ["signature-estate", "coastal-luxe"]) {
    const context = await browser.newContext({ viewport:{width:390,height:844},javaScriptEnabled:false,reducedMotion:"reduce" });
    await context.route("**/*",route => new URL(route.request().url()).origin === origin || route.request().url().startsWith("data:") ? route.continue() : route.abort());
    const page = await context.newPage();
    longAddress = true; presentation = "video";
    await page.goto(origin+"/property/synthetic-site",{waitUntil:"networkidle"});
    check(await page.locator(".property-hero-price").count() === 0,theme+": missing price is omitted without invented facts");
    check(await page.locator(".property-hero-title").getAttribute("aria-label") === fixture().listing.address && (await page.locator(".property-hero-title").textContent()).includes("Architectural Promenade") && (await page.locator(".property-hero-locality").textContent()) === "Residence Twelve, Example, FL 33000",theme+": long address has exact complete accessible name and complete visible street/locality without leading punctuation");
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),theme+": long address has no phone overflow");
    const menu=page.locator(".property-page-menu"),summary=menu.locator("summary");
    check(!(await menu.evaluate(el=>el.open)),theme+": compact menu starts closed without script");
    const nav=await page.locator("#listing-nav").boundingBox();check(nav.height<=72,theme+": premium phone header is a single compact material surface");
    const target=await summary.boundingBox();check(target.height>=44&&target.width>=44,theme+": native page menu keeps44px target");
    await summary.focus();await page.keyboard.press("Enter");check(await menu.evaluate(el=>el.open),theme+": keyboard opens native menu with JavaScript disabled");
    for(const name of ["Home","Gallery","Location","Contact"]){
      const link=menu.getByRole("link",{name,exact:true});check(await link.isVisible(),theme+": no-script menu exposes "+name);
      const box=await link.boundingBox();check(box.height>=44&&box.width>=44,theme+": "+name+" remains44px");
    }
    check(await menu.getByRole("link",{name:"Back to top ↑",exact:true}).isVisible(),theme+": top action remains discoverable");
    await menu.getByRole("link",{name:"Gallery",exact:true}).click();
    check(new URL(page.url()).searchParams.get("page")==="gallery"&&await page.locator("[data-property-photo]").count()===PHOTOS.length,theme+": native no-script Gallery navigation preserves every photo");
    check(await page.locator(".property-photo noscript img").count()===PHOTOS.length && await page.locator(".property-photo noscript img").first().isVisible(),theme+": existing noscript master images remain available");
    await page.goto(origin+"/property/synthetic-site",{waitUntil:"networkidle"});
    const session=await context.newCDPSession(page);await session.send("Emulation.setEmulatedMedia",{features:[{name:"prefers-reduced-motion",value:"reduce"},{name:"prefers-reduced-transparency",value:"reduce"}]});
    const fallback=await page.locator("#listing-nav").evaluate(el=>({background:getComputedStyle(el).backgroundColor,blur:getComputedStyle(el).backdropFilter,animation:getComputedStyle(document.querySelector(".property-hero-copy")).animationName,opacity:getComputedStyle(document.querySelector(".property-hero-copy")).opacity,film:[".property-video-stage.property-film",".property-video-stage.property-film > video","#property-video-play",".property-film-label"].map(selector=>{const node=document.querySelector(selector);return node?getComputedStyle(node).animationName+"/"+getComputedStyle(node).opacity+"/"+getComputedStyle(node).transitionDuration:"missing";})}));
    check(fallback.blur==="none"&&!fallback.background.startsWith("rgba")&&fallback.animation==="none"&&fallback.opacity==="1",theme+": actual reduced-transparency/motion preferences keep opaque visible content");
    check(fallback.film.length===4&&fallback.film.every(value=>value==="none/1/0s"),theme+": reduced motion removes every film hero animation and transition while keeping the poster, play mark and running time fully visible");
    await page.screenshot({path:join(evidence,theme+"-390-long-no-price-no-script-opaque.png"),fullPage:true});
    await page.goto(origin+"/property/synthetic-site?preview_theme="+theme,{waitUntil:"networkidle"});
    check(await page.locator(".property-preview-banner").isVisible() && await page.locator("form").count()===0,theme+": actual design preview retains its label and omits enquiry");
    check(await page.locator("#listing-nav").evaluate(el=>getComputedStyle(el).position)==="relative",theme+": preview navigation preserves its non-sticky placement beneath the sticky preview banner");
    check(await page.locator(".property-page-menu-links a[href*='preview_theme="+theme+"']").count()===4,theme+": native preview menu preserves all four preview URLs");
    await page.screenshot({path:join(evidence,theme+"-390-preview-native-menu.png"),fullPage:true});
    await context.close();longAddress=false;
  }

  // Classic preview chrome is shared with the existing mobile design preview.
  // A premium restyle must retain those exact compact banner/watermark sizes.
  theme = "basic"; presentation = "video";
  {
    const context = await browser.newContext({viewport:{width:390,height:844},javaScriptEnabled:false});
    await context.route("**/*",route=>new URL(route.request().url()).origin===origin||route.request().url().startsWith("data:")?route.continue():route.abort());
    const page = await context.newPage();
    await page.goto(origin+"/property/synthetic-site?preview_theme=basic",{waitUntil:"networkidle"});
    const style = selector=>page.locator(selector).evaluate(el=>({font:getComputedStyle(el).fontSize,padding:getComputedStyle(el).padding}));
    const banner = await style(".property-preview-banner"),watermark = await style(".property-preview-watermark");
    measurements.push({theme,presentation:"classic-preview",banner,watermark});
    check(banner.font==="12px"&&banner.padding==="10px 16px","Classic390 design-preview banner retains its exact original mobile font and padding");
    check(watermark.font==="10px"&&watermark.padding==="6px 9px","Classic390 design-preview watermark retains its exact original mobile font and padding");
    await page.screenshot({path:join(evidence,"basic-390-preview-original-chrome.png"),fullPage:true});
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

  // Neighbourhood map on the Location page: the server-drawn SVG arrives with
  // the nearby reply (scripts on) or as static markup from a cached lookup
  // (scripts off); it fits the phone and desktop viewports, the nine markers
  // and their labels stay inside the paper and legible, the halo animation
  // yields to reduced motion, and no request leaves the loopback origin.
  presentation = "photo";
  for (const width of [390, 1440]) for (theme of ["basic", "signature-estate", "coastal-luxe"]) for (const scripted of [true, false]) {
    const context = await browser.newContext({ viewport: { width, height: width === 390 ? 844 : 1000 }, javaScriptEnabled: scripted, reducedMotion: scripted ? "no-preference" : "reduce" });
    const external = [];
    await context.route("**/*", route => { const u = new URL(route.request().url()); if (u.origin === origin || u.protocol === "data:") return route.continue(); external.push(u.href); return route.abort(); });
    const page = await context.newPage(); page.on("pageerror", e => errors.push("nearby-map " + theme + ": " + e));
    await page.goto(origin + "/property/synthetic-site?page=location" + (scripted ? "" : "&cached=1"), { waitUntil: "networkidle" });
    const tag = `${theme}/${width}/${scripted ? "scripted" : "no-script-cached"}`;
    if (scripted) await page.waitForSelector("#property-nearby-map:not([hidden]) svg", { timeout: 5000 });
    await page.locator("#property-nearby").scrollIntoViewIfNeeded();
    const map = await page.evaluate(() => {
      const svg = document.querySelector("#property-nearby-map svg"), rect = svg.getBoundingClientRect();
      const paper = svg.querySelector(".nm-paper").getBoundingClientRect();
      const inPaper = el => { const r = el.getBoundingClientRect(); return r.left >= paper.left - .5 && r.right <= paper.right + .5 && r.top >= paper.top - .5 && r.bottom <= paper.bottom + .5; };
      const labels = [...svg.querySelectorAll(".nm-label")].map(el => ({ text: el.textContent, box: el.getBoundingClientRect(), font: parseFloat(getComputedStyle(el).fontSize), inside: inPaper(el) }));
      const overlaps = labels.flatMap((a, i) => labels.slice(i + 1).filter(b => !(a.box.right <= b.box.left || b.box.right <= a.box.left || a.box.bottom <= b.box.top || b.box.bottom <= a.box.top)).map(b => a.text + " / " + b.text));
      return { role: svg.getAttribute("role"), label: svg.getAttribute("aria-label"), places: svg.querySelectorAll(".nm-place").length, rings: svg.querySelectorAll(".nm-ring").length, markersInside: [...svg.querySelectorAll(".nm-dot")].every(inPaper), labelsInside: labels.every(l => l.inside), minFont: Math.min(...labels.map(l => l.font)) * rect.width / 360, overlaps,
        x: rect.left, right: rect.right, width: rect.width, height: rect.height, top: rect.top, figureBottom: svg.closest("figure").getBoundingClientRect().bottom, listTop: document.getElementById("property-nearby-list").getBoundingClientRect().top, overflow: document.documentElement.scrollWidth > innerWidth, list: document.querySelectorAll("#property-nearby-list li").length, endpoint: document.getElementById("property-nearby").hasAttribute("data-endpoint"),
        status: document.getElementById("property-nearby-status").textContent, legend: document.querySelectorAll(".property-nearby-legend .nm-key").length, halo: getComputedStyle(svg.querySelector(".nm-home-halo")).animationName, fill: getComputedStyle(svg.querySelector(".nm-restaurant")).fill, attribution: !!document.querySelector("#property-nearby a[href='https://www.openstreetmap.org/copyright']"), googleLink: !!document.querySelector(".property-location-copy a[href^='https://www.google.com/maps/']") };
    });
    measurements.push({ tag, type: "nearby-map", ...map });
    check(map.role === "img" && map.label.startsWith("Map of 9 nearby places within 1 mi of the property: 3 restaurants, 3 cafés, 3 shops."), tag + ": map is an image with an accessible summary");
    check(map.places === 9 && map.rings === 2 && map.legend === 4 && map.list === 9, tag + ": nine markers, two rings, legend and nine list items");
    check(map.x >= 0 && map.right <= width && !map.overflow && map.width >= (width === 390 ? 300 : 440) && Math.abs(map.width - map.height) < 1, tag + ": square map fits the viewport without horizontal overflow");
    check(width === 390 ? map.listTop >= map.figureBottom : Math.abs(map.listTop - map.top) <= 1, tag + (width === 390 ? ": the list follows the map and its legend" : ": map and list start on the same line beside each other"));
    check(map.markersInside && map.labelsInside && map.overlaps.length === 0 && map.minFont >= 10, tag + ": markers and labels stay on the paper, do not overlap, and remain legible (" + map.minFont.toFixed(1) + "px)");
    check(map.attribution && map.googleLink && map.fill !== "rgb(0, 0, 0)" && map.fill !== "none", tag + ": OSM attribution and the external map link remain; markers take the theme colour");
    check(map.endpoint === scripted && map.status.startsWith("Restaurants, cafés and shops listed in OpenStreetMap"), tag + (scripted ? ": scripted lookup filled the section" : ": cached places render as static markup with no endpoint left"));
    if (!scripted) check(map.halo === "none", tag + ": reduced motion stops the property-marker pulse");
    if (scripted) check(map.halo === "nearby-home-pulse", tag + ": the property marker pulses when motion is allowed");
    check(external.length === 0 && !requests.some(path => path.startsWith("/tile") || path.includes("openstreetmap")), tag + ": no request leaves the loopback origin and no tile is fetched");
    // Evidence: the section at real size, captured from the top of the page so
    // sticky navigation stays at the top instead of painting over the map.
    const clip = await page.evaluate(() => { scrollTo(0, 0); const r = document.getElementById("property-nearby").getBoundingClientRect(); return { x: 0, y: Math.floor(r.top + scrollY), width: innerWidth, height: Math.ceil(r.height) }; });
    await page.screenshot({ path: join(evidence, `nearby-map-${theme}-${width}-${scripted ? "scripted" : "no-script"}.png`), fullPage: true, clip });
    await context.close();
  }

  // Dense downtown block (cached static markup, scripts off): the real glyph
  // boxes of the names, ring distances and north mark never collide or leave
  // the paper, and the rings fit the block in tenth-mile steps.
  for (const width of [390, 1440]) for (theme of ["basic", "signature-estate", "coastal-luxe"]) {
    const context = await browser.newContext({ viewport: { width, height: width === 390 ? 844 : 1000 }, javaScriptEnabled: false });
    await context.route("**/*", route => { const u = new URL(route.request().url()); return u.origin === origin || u.protocol === "data:" ? route.continue() : route.abort(); });
    const page = await context.newPage();
    await page.goto(origin + "/property/synthetic-site?page=location&cached=downtown", { waitUntil: "networkidle" });
    const tag = `downtown/${theme}/${width}`;
    const dense = await page.evaluate(() => {
      const svg = document.querySelector("#property-nearby-map svg"), rect = svg.getBoundingClientRect(), paper = svg.querySelector(".nm-paper").getBoundingClientRect();
      const boxes = selector => [...svg.querySelectorAll(selector)].map(el => ({ text: el.textContent, box: el.getBoundingClientRect() }));
      const names = boxes(".nm-label"), marks = boxes(".nm-ring-label, .nm-compass");
      const hit = (a, b) => !(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top);
      const onPaper = b => b.left >= paper.left - .5 && b.right <= paper.right + .5 && b.top >= paper.top - .5 && b.bottom <= paper.bottom + .5;
      return { places: svg.querySelectorAll(".nm-place").length, rings: marks.filter(m => m.text !== "N").map(m => m.text), summary: svg.getAttribute("aria-label"), labels: names.map(n => n.text),
        collisions: names.flatMap((a, i) => [...names.slice(i + 1), ...marks].filter(b => hit(a.box, b.box)).map(b => a.text + " / " + b.text)),
        offPaper: [...names, ...marks].filter(n => !onPaper(n.box)).map(n => n.text), minFont: Math.min(...[...svg.querySelectorAll(".nm-label")].map(el => parseFloat(getComputedStyle(el).fontSize))) * rect.width / 360 };
    });
    measurements.push({ tag, type: "downtown-map", ...dense });
    check(dense.places === 9 && JSON.stringify(dense.rings) === JSON.stringify(["0.1 mi", "0.2 mi"]) && dense.summary.startsWith("Map of 9 nearby places within 0.2 mi of the property"), tag + ": a dense block gets tenth-mile rings that fit its nine places");
    check(dense.collisions.length === 0 && dense.offPaper.length === 0 && dense.minFont >= 10, tag + ": names, ring distances and the north mark never collide or leave the paper " + JSON.stringify(dense.collisions.concat(dense.offPaper)));
    const clip = await page.evaluate(() => { const r = document.getElementById("property-nearby").getBoundingClientRect(); return { x: 0, y: Math.floor(r.top + scrollY), width: innerWidth, height: Math.ceil(r.height) }; });
    await page.screenshot({ path: join(evidence, `nearby-map-downtown-${theme}-${width}.png`), fullPage: true, clip });
    await context.close();
  }

  // No published address: the page withholds the location, so neither path
  // draws the map; the list alone takes the whole row and nothing leaves the
  // loopback origin.
  for (const width of [390, 1440]) for (theme of ["basic", "signature-estate", "coastal-luxe"]) for (const scripted of [true, false]) {
    const context = await browser.newContext({ viewport: { width, height: width === 390 ? 844 : 1000 }, javaScriptEnabled: scripted });
    const external = [];
    await context.route("**/*", route => { const u = new URL(route.request().url()); if (u.origin === origin || u.protocol === "data:") return route.continue(); external.push(u.href); return route.abort(); });
    const page = await context.newPage(); page.on("pageerror", e => errors.push("unaddressed " + theme + ": " + e));
    await page.goto(origin + "/property/synthetic-site?page=location&noaddress=1" + (scripted ? "" : "&cached=1"), { waitUntil: "networkidle" });
    if (scripted) await page.waitForFunction(() => document.querySelectorAll("#property-nearby-list li").length === 9);
    const tag = `unaddressed/${theme}/${width}/${scripted ? "scripted" : "no-script-cached"}`;
    const shown = await page.evaluate(() => { const list = document.getElementById("property-nearby-list"), wrap = list.parentElement.getBoundingClientRect(), pad = getComputedStyle(list.parentElement), box = list.getBoundingClientRect();
      return { notice: document.body.innerText.includes("An address has not been published for this listing."), maps: document.querySelectorAll("#property-nearby svg, a[href*='google.com/maps']").length, slotHidden: document.getElementById("property-nearby-map").hidden, items: list.querySelectorAll("li").length, visible: box.height > 0, left: box.left - (wrap.left + parseFloat(pad.paddingLeft)), right: wrap.right - parseFloat(pad.paddingRight) - box.right, overflow: document.documentElement.scrollWidth > innerWidth }; });
    measurements.push({ tag, type: "unaddressed", ...shown });
    check(shown.notice && shown.maps === 0 && shown.slotHidden && shown.items === 9 && shown.visible && !shown.overflow, tag + ": no published address means no map, only the list");
    check(Math.abs(shown.left) <= 1 && Math.abs(shown.right) <= 1, tag + ": the list takes the whole row, with no empty map column");
    check(external.length === 0, tag + ": no request leaves the loopback origin");
    await context.close();
  }
  presentation = "video";

  // Room-grouped Gallery on the premium designs: the headings follow label
  // first appearance, the on-screen order (rows top to bottom, left to right)
  // equals document order, and the full-size viewer's Next/Previous walk that
  // same order. Classic keeps the flat published order.
  roomLabels = true;
  const expectedGrouped = [0, 2, 5, 1, 3, 4].map(photoPath), expectedFlat = PHOTOS.map((_, i) => photoPath(i));
  for (const width of [390, 1440]) for (theme of ["basic", "signature-estate", "coastal-luxe"]) {
    const context = await browser.newContext({ viewport: { width, height: width === 390 ? 844 : 1000 } });
    await context.route("**/*", route => new URL(route.request().url()).origin === origin || route.request().url().startsWith("data:") ? route.continue() : route.abort());
    const page = await context.newPage(); page.on("pageerror", e => errors.push("rooms " + theme + ": " + e));
    await page.goto(origin + "/property/synthetic-site?page=gallery", { waitUntil: "networkidle" });
    const tag = `rooms/${theme}/${width}`;
    const grouped = theme !== "basic";
    const layout = await page.evaluate(() => {
      const links = [...document.querySelectorAll("[data-property-photo]")].map(a => ({ href: new URL(a.href).pathname, box: a.getBoundingClientRect() }));
      const rows = []; for (const link of [...links].sort((a, b) => a.box.top - b.box.top)) { const row = rows.find(r => Math.abs(r.top - link.box.top) < link.box.height * .5); if (row) row.items.push(link); else rows.push({ top: link.box.top, items: [link] }); }
      const visual = rows.sort((a, b) => a.top - b.top).flatMap(r => r.items.sort((a, b) => a.box.left - b.box.left).map(l => l.href));
      // Every row grid (a room's photos, or a run of one-photo rooms): the gap
      // between each row's outer cells and the grid edges, and cells per row.
      const fill = [...document.querySelectorAll(".lp-gal-room > .lp-gal, .lp-gal-run")].flatMap(grid => {
        const box = grid.getBoundingClientRect(), lines = [];
        for (const cell of [...grid.children].map(c => c.getBoundingClientRect())) { const line = lines.find(l => Math.abs(l.top - cell.top) < cell.height * .5); if (line) line.cells.push(cell); else lines.push({ top: cell.top, cells: [cell] }); }
        return lines.map(l => ({ kind: grid.classList.contains("lp-gal-run") ? "run" : "room", left: Math.min(...l.cells.map(c => c.left)) - box.left, right: box.right - Math.max(...l.cells.map(c => c.right)), photos: l.cells.length }));
      });
      const rules = [...document.querySelectorAll(".lp-gal-room-title")].map(h => { const after = getComputedStyle(h, "::after"); return after.display === "none" ? null : parseFloat(after.width); }).filter(w => w !== null);
      return { dom: links.map(l => l.href), visual, fill, rules, headings: [...document.querySelectorAll("h2.lp-gal-room-title")].map(h => h.textContent), captions: document.querySelectorAll("#gallery figcaption").length, overflow: document.documentElement.scrollWidth > innerWidth };
    });
    measurements.push({ tag, type: "rooms", ...layout });
    check(JSON.stringify(layout.dom) === JSON.stringify(grouped ? expectedGrouped : expectedFlat), tag + (grouped ? ": photos are grouped by room in document order" : ": Classic keeps the published order"));
    check(JSON.stringify(layout.visual) === JSON.stringify(layout.dom) && !layout.overflow, tag + ": on-screen order equals document order");
    if (grouped) {
      check(layout.fill.length >= 4 && layout.fill.every(row => Math.abs(row.left) <= 1 && Math.abs(row.right) <= 1), tag + ": every row of every room is filled edge to edge, with no empty column beside a photo");
      // Living room, Primary bedroom and Terrace hold one photo each: they share
      // rows at the ordinary photo size; only a run's leftover photo widens.
      const runRows = layout.fill.filter(row => row.kind === "run").map(row => row.photos), expectedRun = { "signature-estate": { 390: [1, 1, 1], 1440: [2, 1] }, "coastal-luxe": { 390: [2, 1], 1440: [3] } }[theme][width];
      check(JSON.stringify(runRows) === JSON.stringify(expectedRun), tag + ": consecutive one-photo rooms sit side by side (" + JSON.stringify(runRows) + ")");
      check(layout.rules.length >= 2 && layout.rules.every(w => w >= 24), tag + ": every visible room-heading rule is a real line, never a stub (" + layout.rules.map(w => Math.round(w)).join(",") + "px)");
    }
    check(JSON.stringify(layout.headings) === JSON.stringify(grouped ? ["Kitchen3 photos", "Living room", "Primary bedroom", "Terrace"] : []) && layout.captions === (grouped ? 0 : PHOTOS.length), tag + (grouped ? ": room headings replace captions" : ": no room headings or lost captions on Classic"));
    const links = page.locator("[data-property-photo]");
    await links.nth(0).click();
    await page.waitForFunction(() => document.querySelector("#property-photo-modal").open);
    const walked = [await page.locator("#property-photo-full").evaluate(img => new URL(img.getAttribute("src"), location.href).pathname)];
    for (let step = 1; step < PHOTOS.length; step++) {
      await page.keyboard.press("ArrowRight");
      walked.push(await page.locator("#property-photo-full").evaluate((img, n) => { const src = img.getAttribute("src"); if (!src) throw new Error("viewer lost its photo at step " + n); return new URL(src, location.href).pathname; }, step));
    }
    check(JSON.stringify(walked) === JSON.stringify(layout.visual) && await page.locator("#property-photo-next").isDisabled(), tag + ": viewer Next walks the on-screen order and stops at the last photo");
    await page.keyboard.press("ArrowLeft");
    check(await page.locator("#property-photo-full").evaluate(img => new URL(img.getAttribute("src"), location.href).pathname) === layout.visual[PHOTOS.length - 2] && (await page.locator("#property-photo-count").innerText()) === `${PHOTOS.length - 1} of ${PHOTOS.length}`, tag + ": viewer Previous returns along the same order");
    await page.keyboard.press("Escape");
    // Evidence capture: every thumb has been handed its file and has settled,
    // loaded or failed (the fixture's sixth file is deliberately missing, and
    // its error may already have fired, so no event is awaited). Bounded, so a
    // stuck image fails loudly instead of hanging the suite.
    for (const image of await page.locator("img.property-thumb").all()) {
      await image.scrollIntoViewIfNeeded();
      await image.evaluate(img => new Promise((resolve, reject) => { const limit = performance.now() + 8000; const poll = () => { if (!img.hasAttribute("data-property-src") && img.complete) resolve(); else if (performance.now() > limit) reject(new Error("gallery thumb did not settle: " + img.alt)); else requestAnimationFrame(poll); }; poll(); }));
    }
    await page.evaluate(() => { document.activeElement?.blur(); scrollTo(0, 0); });
    await page.screenshot({ path: join(evidence, `gallery-rooms-${theme}-${width}.png`), fullPage: true });
    await context.close();
  }
  roomLabels = false;
  check(errors.length === 0, "No page JavaScript errors: " + errors.join("; "));
  writeFileSync(join(evidence, "receipt.json"), JSON.stringify({ passed: true, checks, measurements, scope: "Synthetic loopback pages and SVG photos; no customer media, phone or production request." }, null, 2));
  console.log(`Property site browser: ${checks.length} real-browser assertions passed; receipt ${join(evidence, "receipt.json")}`);
} catch (error) {
  writeFileSync(join(evidence, "failure.json"), JSON.stringify({ passed: false, error: String(error && error.message || error), checks, measurements, errors }, null, 2));
  throw error;
} finally {
  await browser.close(); server.close();
}
