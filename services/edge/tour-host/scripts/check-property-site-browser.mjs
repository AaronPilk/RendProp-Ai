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

const checks = [];
const check = (condition, label) => { assert.ok(condition, label); checks.push(label); };
const svg = (label, color, portrait = false) => `<svg xmlns="http://www.w3.org/2000/svg" width="${portrait ? 900 : 1600}" height="${portrait ? 1600 : 1200}"><rect width="100%" height="100%" fill="${color}"/><text x="80" y="600" font-size="96" fill="white">SYNTHETIC ${label}</text></svg>`;
const PHOTOS = [["Front exterior", "#264653"], ["Living room", "#2a9d8f"], ["Kitchen", "#8a5a44"], ["Primary bedroom", "#6d597a"], ["Terrace", "#355070"], ["Broken file", "#000000"]];
const photoPath = (i) => i === 5 ? "/photos/missing-5.svg" : `/photos/photo-${i}.svg`;
let theme = "basic", useThumbs = false, thumbFailure = false, presentation = "video", longAddress = false;
function fixture() {
  const t = buildDemoTour();
  t.slug = "synthetic-site"; t.website_theme = theme;
  t.listing = { address: "123 Synthetic Lane, Example, FL 33000", tagline: null, details: { story: "Synthetic description.", show_app_cta: false, show_partners: false }, beds: 3, baths: 2, sqft: 1800, price_cents: 50000000, price: null, lat: 27.9, lng: -82.5 };
  if (longAddress) { t.listing.address = "12345 Synthetic Architectural Promenade, Residence Twelve, Example, FL 33000"; t.listing.price_cents = null; }
  t.cover_url = photoPath(0); t.poster = "/posters/poster.svg";
  t.gallery = PHOTOS.map(([label], i) => ({ url: photoPath(i), label, ...(useThumbs ? { thumb_url: photoPath(i).replace("/photos/", "/thumbs/") } : {}) }));
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
  if (url.pathname === "/f/synthetic-site/nearby") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify({ status: "available", places: [{ name: "Synthetic Café", category: "Cafe", distance_m: 300, source_url: "https://www.openstreetmap.org/node/1" }] })); return; }
  if (url.pathname === "/property/synthetic-site") {
    let html = renderTourPage(fixture(), origin + "/closed-api", "", "", { origin, page: propertyPage(url.searchParams.get("page")), publicBase: "/property", previewTheme:url.searchParams.get("preview_theme") });
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
        return { media:box(media),copy:box(document.querySelector(".property-hero-copy")),title:box(document.querySelector(".property-hero-title")),nav:box(document.querySelector("#listing-nav")),overflow:document.documentElement.scrollWidth > innerWidth,bodyText:document.body.innerText,watchContrast,contain:document.querySelector("#property-video") ? getComputedStyle(document.querySelector("#property-video")).objectFit : null };
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
      if (theme !== "basic") presentationChecks.push([composition.watchContrast.length > 0 && composition.watchContrast.every(ratio => ratio >= 4.5),tag+": film navigation text meets 4.5:1 contrast with either primary media"]);
      if (theme === "signature-estate") presentationChecks.push([composition.media.bottom <= composition.copy.y+1,tag+": Signature leads with complete media before editorial copy"]);
      if (theme === "coastal-luxe") {
        presentationChecks.push([width === 390 ? composition.copy.bottom <= composition.media.y+1 : composition.copy.x < composition.media.x && composition.copy.y <= composition.media.y+1,tag+": Coastal leads with address and price before the media"]);
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
    check((await page.locator(".property-hero-title").innerText()).includes("Architectural Promenade, Residence Twelve"),theme+": long actual address is complete");
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
    const fallback=await page.locator("#listing-nav").evaluate(el=>({background:getComputedStyle(el).backgroundColor,blur:getComputedStyle(el).backdropFilter,animation:getComputedStyle(document.querySelector(".property-hero-copy")).animationName,opacity:getComputedStyle(document.querySelector(".property-hero-copy")).opacity}));
    check(fallback.blur==="none"&&!fallback.background.startsWith("rgba")&&fallback.animation==="none"&&fallback.opacity==="1",theme+": actual reduced-transparency/motion preferences keep opaque visible content");
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
  check(errors.length === 0, "No page JavaScript errors: " + errors.join("; "));
  writeFileSync(join(evidence, "receipt.json"), JSON.stringify({ passed: true, checks, measurements, scope: "Synthetic loopback pages and SVG photos; no customer media, phone or production request." }, null, 2));
  console.log(`Property site browser: ${checks.length} real-browser assertions passed; receipt ${join(evidence, "receipt.json")}`);
} catch (error) {
  writeFileSync(join(evidence, "failure.json"), JSON.stringify({ passed: false, error: String(error && error.message || error), checks, measurements, errors }, null, 2));
  throw error;
} finally {
  await browser.close(); server.close();
}
