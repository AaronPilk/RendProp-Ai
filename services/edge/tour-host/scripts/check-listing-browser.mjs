#!/usr/bin/env node
// Actual rendered public page + real H.264/AAC media, entirely on loopback.
// No owner account, camera, customer assets, providers or production requests.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join, basename } from "node:path";
import { pathToFileURL } from "node:url";
import { buildSrc, ROOT } from "./build-src.mjs";

const argv = process.argv.slice(2);
const arg = (name) => argv.find((item) => item.startsWith(name + "="))?.slice(name.length + 1);
const evidence = arg("--evidence") ? resolve(arg("--evidence")) : mkdtempSync(join(tmpdir(), "rendprop-listing-browser-"));
mkdirSync(evidence, { recursive: true });
const playwrightPath = arg("--playwright") || resolve(ROOT, "../../../apps/studio/node_modules/@playwright/test/index.mjs");
const { chromium } = await import(pathToFileURL(playwrightPath).href);
const fault = arg("--fault") || null;
assert.ok(!fault || ["eager-media", "retain-media", "queued-close", "poster-cover", "explore-no-seek", "stale-explore-reference", "explore-rewind"].includes(fault), "Unknown negative control");
const sourceHash = createHash("sha256").update(readFileSync(join(ROOT, "src/player.ts"))).digest("hex");
const sourceHashes = Object.fromEntries(readdirSync(join(ROOT, "src")).filter((name) => name.endsWith(".ts")).map((name) => ["src/" + name, createHash("sha256").update(readFileSync(join(ROOT, "src", name))).digest("hex")]));
sourceHashes["scripts/check-listing-browser.mjs"] = createHash("sha256").update(readFileSync(join(ROOT, "scripts/check-listing-browser.mjs"))).digest("hex");
const moviePath = join(evidence, "SYNTHETIC-NOT-A-LISTING.mp4");
// Fast-start MP4 allows ordinary range seeking and gives the browser a real
// audio track. 720p is a known fixture dimension, not a production quality claim.
execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=8", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8", "-c:v", "libx264", "-preset", "veryfast", "-crf", "24", "-g", "24", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-shortest", moviePath], { timeout: 60000 });
const movie = readFileSync(moviePath);
const movieHash = createHash("sha256").update(movie).digest("hex");
const load = buildSrc("listing-browser-check-" + process.pid);
const { renderTourPage, unbrandedSelfCheck } = await load("player");
const { buildDemoTour } = await load("demo");
const { spatialModule } = await load("spatial");
const spatialFixturePath = arg("--spatial-fixture"), spatialEnginePath = arg("--spatial-engine");
assert.equal(Boolean(spatialFixturePath), Boolean(spatialEnginePath), "Spatial fixture and pinned engine must be supplied together");
const sceneId = "11111111-1111-4111-8111-111111111111", artifactRevision = "22222222-2222-4222-8222-222222222222";
let spatialModel = null, spatialEngine = null, spatialRuntime = null;
if (spatialFixturePath) {
  assert.equal(basename(spatialFixturePath), "SYNTHETIC-NOT-A-ROOM.sog", "Spatial browser fixture must be explicitly synthetic");
  spatialModel = readFileSync(spatialFixturePath); spatialEngine = readFileSync(spatialEnginePath);
  assert.equal(createHash("sha384").update(spatialEngine).digest("base64"), "2sYsYZfrbYhDV41s7X2ecMMRNZ8xTYBbSZcu3t9x0fpAFoqDtCQVeQtiq+mx0Fwz", "Actual PlayCanvas engine must match the existing pinned SRI");
  const { inspectSpatialSog } = await load("spatial-sog"); inspectSpatialSog(spatialModel, 2048);
  spatialRuntime = (await spatialModule().text()).replace("https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js", "/vendor/playcanvas.min.js");
}
const spatialManifest = spatialModel ? { schema_version: 1, scene_id: sceneId, artifact_revision: artifactRevision, format: "sog", bytes: spatialModel.length, sha256: createHash("sha256").update(spatialModel).digest("hex"), gaussian_count: 2048, bounds: { min: [-5, -2, -5], max: [5, 4, 5] }, floor_y: -1.6, eye_height: 1.6, floor_source: "capture_estimate", navigation_bounds_source: "capture_estimate", initial_camera: { position: [0, 0, 3], target: [0, 0, 0] }, rooms: [{ id: "synthetic", label: "Synthetic test", position: [1, 0, 3], target: [0, 0, 0] }], provenance: "synthetic", privacy_reviewed: true } : null;
const requests = [], pageErrors = [], checks = [], navigationMeasurements = [], mediaState = { active: 0, aborted: 0 };
let failVideoRequests = true;
const check = (value, message) => { assert.ok(value, message); checks.push(message); };
const waitUntil = async (predicate, message, timeout = 5000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (predicate()) return; await new Promise((r) => setTimeout(r, 30)); }
  assert.fail(message);
};
const svg = (label) => `<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><rect width="1280" height="720" fill="#5b2bbd"/><text x="40" y="120" fill="white" font-size="52">SYNTHETIC ${label}</text></svg>`;
function fixture({ slow = false, missing = false, failed = false, spatial = false, client = null } = {}) {
  const tour = buildDemoTour();
  tour.slug = slow ? "synthetic-slow" : missing ? "synthetic-no-video" : failed ? "synthetic-failed" : spatial ? "synthetic-spatial" : "synthetic-listing";
  tour.share_url = "http://127.0.0.1/f/" + tour.slug;
  tour.listing = { ...tour.listing, address: "SYNTHETIC TEST — 123 Listing Avenue", tagline: "Synthetic browser test. Not a property.", details: { story: "A useful property description remains available before loading any flythrough.", gallery: [{ url: "/synthetic-gallery.svg", label: "Synthetic gallery photo" }], show_partners: false, show_app_cta: false }, lat: null, lng: null };
  tour.gallery = [{ url: "/synthetic-gallery.svg", label: "Synthetic gallery photo" }];
  tour.floorplan_url = "/synthetic-floorplan.svg";
  tour.poster = "/synthetic-poster.svg";
  tour.cover_url = "/synthetic-main-photo.svg";
  tour.video_url = missing ? null : slow ? "/synthetic-slow.mp4" : failed ? "/synthetic-failed.mp4" : "/synthetic-video.mp4";
  tour.scrub_url = tour.video_url;
  tour.hls_url = null;
  tour.duration_s = missing ? null : 8;
  tour.chapters = [{ label: "Synthetic entry", t_ms: 0, sort: 0 }, { label: "Synthetic kitchen", t_ms: 4000, sort: 1 }];
  if (spatial) tour.chapters[0].spatial_anchor = { scene_id: sceneId, room_id: "synthetic" };
  tour.agent_card = { name: "Synthetic Branded Agent", phone: "(555) 010-2020", email: "synthetic-agent@example.test", brokerage: "Synthetic Brokerage" };
  tour.cta = { label: "Book a showing", mode: "lead_form", url: null, secondary: [], lead_fields: ["name", "email", "message"] };
  tour.altered_media = [{ label: "Synthetic gallery photo", kind: "declutter", disclosure: "Objects were removed digitally.", original_url: "/synthetic-original.svg", altered_url: "/synthetic-gallery.svg" }];
  if (client) {
    tour.slug = "synthetic-client-" + client;
    tour.client_mode = true;
    tour.hide_rendprop_branding = true;
    tour.agent_card = { name: "Synthetic Client " + client, phone: "555-010-2020", email: client + "@example.invalid", brokerage: "Client Brokerage " + client, avatar_url: "/synthetic-client-" + client + ".svg", handle: "photographer-private-portfolio" };
    tour.listing.details = { ...tour.listing.details, show_partners: true, show_app_cta: true, show_financing: true };
  }
  return tour;
}

// Actual property-cover priority, without an account or media fetch.
for (const test of [
  { name: "explicit selected cover", cover: "/synthetic-main.svg", gallery: ["/synthetic-sign.svg", "/synthetic-main.svg"], expected: "/synthetic-main.svg" },
  { name: "legacy ordered gallery", cover: null, gallery: ["/synthetic-gallery.svg"], expected: "/synthetic-gallery.svg" },
  { name: "invalid cover URL", cover: "javascript:alert(1)", gallery: ["/synthetic-gallery.svg"], expected: "/synthetic-gallery.svg" },
  { name: "video-only fallback", cover: null, gallery: [], expected: "/synthetic-poster.svg" },
  { name: "explicit empty gallery", cover: null, gallery: [], detailsGallery: ["/synthetic-stale-original.svg"], expected: "/synthetic-poster.svg" },
]) {
  const tour = fixture(); tour.cover_url = test.cover; tour.gallery = test.gallery; tour.listing.details.gallery = test.detailsGallery || test.gallery;
  const html = renderTourPage(tour, "http://127.0.0.1/api", "", "", { origin: "http://127.0.0.1" });
  check(html.match(/class="listing-cover"[^>]*>\s*<img src="([^"]+)"/)?.[1] === test.expected, test.name + " takes the correct actual cover priority");
  check(html.includes('property="og:image" content="http://127.0.0.1' + test.expected + '"'), test.name + " social preview uses the same property cover");
  check(html.indexOf('class="listing-cover"') < html.indexOf('id="overview"'), test.name + " property photo appears before listing details");
}

let browser, server, browserPage;
try {
  server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const record = { path: url.pathname, method: req.method, range: req.headers.range || null, bytes: 0, status: null };
    requests.push(record);
    const send = (status, body, headers = {}) => { record.status = status; record.bytes = Buffer.byteLength(body); res.writeHead(status, { "Cache-Control": "no-store", ...headers }); res.end(body); };
    if (url.pathname === "/spatial-viewer.js") return send(spatialRuntime ? 200 : 503, spatialRuntime || "Synthetic spatial unavailable", { "Content-Type": "text/javascript" });
    if (url.pathname === "/vendor/playcanvas.min.js" && spatialEngine) return send(200, spatialEngine, { "Content-Type": "text/javascript" });
    if (url.pathname === "/s/" + sceneId + "/manifest" && spatialManifest) return send(200, JSON.stringify(spatialManifest), { "Content-Type": "application/json" });
    if (url.pathname === "/s/" + sceneId + "/model" && spatialModel) { assert.equal(url.searchParams.get("revision"), artifactRevision); return send(200, spatialModel, { "Content-Type": "application/octet-stream" }); }
    if (url.pathname.endsWith(".svg")) return send(200, svg(url.pathname), { "Content-Type": "image/svg+xml" });
    if (url.pathname.endsWith(".mp4")) {
      if (url.pathname === "/synthetic-failed.mp4" && failVideoRequests) return send(503, "Synthetic unavailable video", { "Content-Type": "text/plain" });
      const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || "");
      const start = match ? Number(match[1]) : 0, end = match?.[2] ? Math.min(Number(match[2]), movie.length - 1) : movie.length - 1;
      if (start >= movie.length || end < start) return send(416, "", { "Content-Range": `bytes */${movie.length}` });
      const headers = { "Content-Type": "video/mp4", "Accept-Ranges": "bytes", "Cache-Control": "no-store", "Content-Length": String(end - start + 1) };
      if (match) headers["Content-Range"] = `bytes ${start}-${end}/${movie.length}`;
      record.status = match ? 206 : 200; res.writeHead(record.status, headers);
      if (url.pathname !== "/synthetic-slow.mp4") { record.bytes = end - start + 1; return res.end(movie.subarray(start, end + 1)); }
      // Hold a real, incomplete media transfer open until close unloads it.
      let cursor = start, complete = false; mediaState.active++;
      const write = () => { const next = Math.min(cursor + 1024, end + 1); const chunk = movie.subarray(cursor, next); record.bytes += chunk.length; res.write(chunk); cursor = next; if (cursor > end) { complete = true; clearInterval(timer); res.end(); } };
      const timer = setInterval(write, 100); write();
      res.once("close", () => { clearInterval(timer); mediaState.active--; if (!complete) { mediaState.aborted++; record.aborted = true; } });
      return;
    }
    if (url.pathname.startsWith("/api/beacon")) {
      let body = ""; req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => { try { record.payload = JSON.parse(body); } catch { record.payload = null; } send(200, "{}", { "Content-Type": "application/json" }); });
      return;
    }
    if (url.pathname === "/api/leads") {
      let body = ""; req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => { record.payload = JSON.parse(body); send(201, JSON.stringify({ ok: true, id: "11111111-1111-4111-8111-111111111111" }), { "Content-Type": "application/json" }); });
      return;
    }
    if (url.pathname.startsWith("/f/") || url.pathname.startsWith("/u/")) {
      const unbranded = url.pathname.startsWith("/u/");
      const tour = fixture({ slow: url.pathname.includes("slow"), missing: url.pathname.includes("no-video"), failed: url.pathname.includes("failed"), spatial: url.pathname.includes("spatial"), client: url.pathname.includes("client-alpha") ? "alpha" : url.pathname.includes("client-beta") ? "beta" : null });
      let html = renderTourPage(tour, "http://127.0.0.1:" + server.address().port + "/api", "", "", { unbranded, origin: "http://127.0.0.1:" + server.address().port });
      if (unbranded) assert.deepEqual(unbrandedSelfCheck(html, tour), [], "Actual unbranded renderer must pass its unchanged security gate");
      if (fault === "eager-media") html = html.replace("</body>", '<script>document.getElementById("flythrough-video").src="/synthetic-video.mp4";document.getElementById("flythrough-video").load();</script></body>');
      if (fault === "retain-media") html = html.replace("</body>", '<script>var v=document.getElementById("flythrough-video");var remove=v.removeAttribute.bind(v);v.removeAttribute=function(name){if(name!=="src")remove(name)};var load=v.load.bind(v);v.load=function(){if(!v.currentSrc)load()};</script></body>');
      if (fault === "queued-close") { assert.ok(html.includes("if (active && !modal.open) closeVideo(false)"), "Queued-close control must mutate the actual fixed listener"); html = html.replace("if (active && !modal.open) closeVideo(false)", "if (active) closeVideo(false)"); }
      if (fault === "poster-cover") html = html.replace('src="/synthetic-main-photo.svg" alt=', 'src="/synthetic-poster.svg" alt=');
      if (fault === "explore-no-seek") html = html.replace('queueSeek(fraction*usableDuration());', '/* fault: scrolling does not seek */');
      if (fault === "explore-rewind") {
        const boundary = 'if (active) syncPosition(pendingSeek===null?video.currentTime:pendingSeek);';
        assert.ok(html.includes(boundary), "Explore rewind control must alter the actual mode handoff");
        html = html.replace(boundary, 'video.currentTime=0; ' + boundary);
      }
      return send(200, html, { "Content-Type": "text/html; charset=utf-8" });
    }
    if (url.pathname === "/favicon.svg") return send(204, "");
    send(404, "Synthetic route missing");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = "http://127.0.0.1:" + server.address().port;
  browser = await chromium.launch({ headless: true, executablePath: process.env.STUDIO_BROWSER_EXECUTABLE });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, reducedMotion: "reduce" });
  await context.addInitScript(() => {
    window.__spatialDraws = 0;
    if (typeof WebGL2RenderingContext === "undefined") return;
    for (const name of ["drawArraysInstanced", "drawElementsInstanced"]) {
      const original = WebGL2RenderingContext.prototype[name];
      WebGL2RenderingContext.prototype[name] = function (...args) { if (this.getParameter(this.DRAW_FRAMEBUFFER_BINDING) === null && args[1] > 0 && args.at(-1) > 0) window.__spatialDraws++; return original.apply(this, args); };
    }
  });
  const externalRequests = [];
  await context.route("**/*", async (route) => { if (new URL(route.request().url()).origin === base) await route.continue(); else { externalRequests.push(route.request().url()); await route.abort(); } });
  const page = await context.newPage();
  browserPage = page;
  page.setDefaultTimeout(5000);
  page.on("pageerror", (error) => pageErrors.push(error.message));
  const video = page.locator("#flythrough-video");
  const modal = page.locator("#flythrough-modal");
  const entry = page.locator("#open-flythrough");
  const close = page.locator("#flythrough-close");
  const mediaRequests = () => requests.filter((r) => /\.(mp4|m3u8|ts)$/.test(r.path));
  const snapshot = () => page.evaluate(() => { const v = document.querySelector("#flythrough-video"); return { time: v.currentTime, paused: v.paused, src: v.getAttribute("src"), currentSrc: v.currentSrc, ready: v.readyState, network: v.networkState, width: v.videoWidth, height: v.videoHeight, rate: v.playbackRate, controls: v.controls, muted: v.muted }; });
  const unloaded = () => page.waitForFunction(() => { const v = document.querySelector("#flythrough-video"); return v.getAttribute("src") === null && v.networkState === v.NETWORK_EMPTY && v.readyState === v.HAVE_NOTHING && v.paused; });
  const open = async ({ watch = true } = {}) => { await entry.click(); await modal.waitFor({ state: "visible" }); await page.waitForFunction(() => document.querySelector("#flythrough-video").readyState >= 2); if (watch) await page.locator("#flythrough-watch").click(); };
  const closeAndCheck = async (label) => {
    await close.click(); await modal.waitFor({ state: "hidden" });
    // Chromium may retain currentSrc's last selected URL after load() clears
    // the media. NETWORK_EMPTY/HAVE_NOTHING and the actual socket-abort check
    // below are the resource state; the stale URL string is not a decoder.
    await unloaded();
    const after = await snapshot();
    check(after.paused && after.src === null && after.network === 0 && after.ready === 0, label + ": close unloads decoder/source and pauses media");
    check(await page.evaluate(() => document.activeElement?.id === "open-flythrough"), label + ": original entry regains focus");
    check(await page.evaluate(() => Math.abs(scrollY - window.__savedScroll) <= 1), label + ": close restores the saved listing scroll position");
    const count = mediaRequests().length; await page.waitForTimeout(300);
    check(mediaRequests().length === count, label + ": media does not fetch again while closed");
    check(await page.evaluate(() => !document.body.inert && !document.querySelector("#listing-page").inert && getComputedStyle(document.body).overflow !== "hidden"), label + ": listing is interactive again");
    return after;
  };

  await page.goto(base + "/f/synthetic-listing");
  await page.locator("#overview").waitFor({ state: "visible" });
  await page.waitForTimeout(400);
  check(await modal.isHidden(), "Initial public listing does not present a blocking video modal");
  check(await video.getAttribute("src") === null, "Initial video element has no attached source");
  check(mediaRequests().length === 0, "Initial listing has made zero video, HLS or segment requests");
  check(requests.filter((r) => r.path.startsWith("/api/beacon")).length === 0, "Viewing listing content alone does not record a flythrough view or delivery");
  check(await page.locator("#overview").innerText().then((text) => text.includes("123 Listing Avenue")), "Property address/details render without media readiness");
  check(await page.locator("#gallery img").count() === 1, "Property photos remain available without a flythrough");
  check(await page.locator(".listing-cover img").getAttribute("src") === "/synthetic-main-photo.svg", "Actual browser opens on the selected main photo instead of the video thumbnail");
  check(await page.evaluate(() => document.querySelector(".listing-cover").getBoundingClientRect().top < document.querySelector("#overview").getBoundingClientRect().top), "The main photo is above details in the rendered page");
  check(await page.locator("#leadform").count() === 1, "Branded lead form remains available before watching video");
  await page.screenshot({ path: join(evidence, "listing-first-mobile.png") });

  // The regression reported by the user: navigation through listing sections
  // must never seek or force the visitor through a massive scroll/video track.
  await page.locator('#listing-nav a[href="#gallery"]').click();
  await page.locator("#gallery").waitFor({ state: "visible" });
  await page.waitForTimeout(150);
  check(await page.evaluate(() => document.querySelector("#gallery").getBoundingClientRect().top < innerHeight), "Photos navigation reaches photos in a normal page scroll");
  await page.locator('#listing-nav a[href="#overview"]').click();
  await page.waitForTimeout(150);
  check(await page.evaluate(() => Math.abs(document.querySelector("#overview").getBoundingClientRect().top) < 180), "Details navigation returns directly to the listing overview");
  check(mediaRequests().length === 0, "Browsing photos/details and returning to the top does not fetch video");
  check(await page.locator("#track").count() === 0, "Public listing has no legacy duration-sized scrub track");

  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({ width, height: 844 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "Listing has no horizontal overflow at " + width + "px");
    const box = await entry.boundingBox();
    check(box && box.width >= 44 && box.height >= 44, "Watch control is at least 44×44px at " + width + "px");
    const geometry = await page.evaluate(() => {
      const nav=document.querySelector('#listing-nav').getBoundingClientRect();
      const actions=Array.from(document.querySelectorAll('.listing-nav-actions > *')).map(el=>{const r=el.getBoundingClientRect();return {id:el.id||el.className,top:r.top,bottom:r.bottom,left:r.left,right:r.right,width:r.width,height:r.height};});
      const links=Array.from(document.querySelectorAll('.listing-nav-links > *')).map(el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,height:r.height};});
      return {width:innerWidth,height:nav.height,top:nav.top,bottom:nav.bottom,actions,links};
    });
    navigationMeasurements.push({ target: "nav-layout", ...geometry });
    check(geometry.height <= (width <= 600 ? 114 : 76), "Navigation stays compact without an orphan Top row at " + width + "px");
    check(geometry.actions.every(a=>a.height>=44 && a.width>=44 && a.left>=0 && a.right<=width && Math.abs(a.top-geometry.actions[0].top)<1), "Watch, Share and Top stay aligned and tappable at " + width + "px");
    check(geometry.links.every(a=>a.height>=44 && a.left>=0 && a.right<=width), "All section links remain visible without sideways scrolling at " + width + "px");
    check(width>600 || Math.abs(geometry.actions.at(-1).right-(width-12))<1, "Mobile actions use the full row with consistent side margins at " + width + "px");
    if (width===1440) { await page.locator('.listing-backtop').click(); await page.screenshot({ path: join(evidence, "listing-first-desktop.png") }); }
    for (const target of ["gallery", "overview", "endcard"]) {
      await page.locator('#listing-nav a[href="#' + target + '"]').click(); await page.waitForTimeout(100);
      const measurement = await page.evaluate((id) => { const nav = document.querySelector("#listing-nav").getBoundingClientRect(), heading = document.querySelector("#" + id + (id === "endcard" ? " .agent .nm" : " .lp-h")).getBoundingClientRect(); return { width: innerWidth, target: id, navBottom: nav.bottom, headingTop: heading.top, headingBottom: heading.bottom }; }, target);
      navigationMeasurements.push(measurement);
      check(measurement.headingTop >= measurement.navBottom - 1 && measurement.headingBottom < 844, target + " heading is visible below the actual wrapped navigation at " + width + "px");
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => { scrollTo(0, 120); window.__savedScroll = scrollY; });
  await open({ watch: false });
  check(mediaRequests().length > 0 && mediaRequests().every((r) => r.path === "/synthetic-video.mp4"), "Only opening the flythrough initiates the real video source");
  check(await modal.getAttribute("aria-labelledby") === "flythrough-title", "Flythrough dialog has an accessible title");
  check(await page.evaluate(() => document.querySelector("#flythrough-modal").open), "Flythrough opens as an actual native dialog");
  check(await page.evaluate(() => document.activeElement?.id === "flythrough-close"), "Initial modal focus provides an immediate working exit");
  const explored = await snapshot();
  check(explored.width === 1280 && explored.height === 720 && explored.paused && explored.muted && !explored.controls, "Explore opens on the actual decoded master with scrolling and no automatic playback");
  check(await page.locator("#flythrough-explore").getAttribute("aria-pressed") === "true", "Explore is the clear default view after opening");
  await page.screenshot({ path: join(evidence, "flythrough-explore-mobile.png") });
  const viewer = page.locator("#flythrough-viewer");
  await viewer.hover(); await page.mouse.wheel(0, 800);
  await page.waitForFunction(() => { const v=document.querySelector('#flythrough-video'); return v.currentTime>1 && !v.seeking; });
  check((await snapshot()).paused && (await snapshot()).time>1, "A real wheel scroll inside Explore seeks the actual paused media timeline");
  check(await page.evaluate(() => scrollY===0 && document.body.style.top===-window.__savedScroll+'px'), "Explore scrolling stays inside the viewer while the listing remains fixed");
  const exploreFrame = await page.evaluate(() => new Promise((resolveFrame,reject)=>{
    const v=document.querySelector('#flythrough-video'), viewer=document.querySelector('#flythrough-viewer');
    const timer=setTimeout(()=>reject(new Error('No decoded Explore frame after internal scroll')),3000);
    function next(){v.requestVideoFrameCallback((_,m)=>{if(Math.abs(m.mediaTime-4)<.2){clearTimeout(timer);resolveFrame({time:m.mediaTime,width:m.width,height:m.height});}else next();});}
    next(); viewer.scrollTop=(viewer.scrollHeight-viewer.clientHeight)/2;
  }));
  check(Math.abs(exploreFrame.time-4)<.2 && exploreFrame.width===1280 && exploreFrame.height===720, "Internal scroll presents a real decoded frame at the chosen tour position");
  await page.locator('#flythrough-position').focus(); await page.keyboard.press('Home');
  await page.waitForFunction(()=>{const v=document.querySelector('#flythrough-video');return v.currentTime<.1&&!v.seeking;});
  check(await page.locator('#flythrough-position').getAttribute('aria-valuenow') === '0', "Explore position has a working keyboard-accessible slider");
  const mediaBeforeSwitch=mediaRequests().length;
  await page.locator('#flythrough-watch').click();
  check(await page.locator('#flythrough-watch').getAttribute('aria-pressed') === 'true' && await viewer.evaluate(el=>el.classList.contains('watch-mode')), "Play video switches the same viewer to ordinary playback");
  const loaded = await snapshot();
  check(loaded.width === 1280 && loaded.height === 720 && loaded.controls && loaded.rate === 1, "Actual decoded 720p video uses ordinary controls and normal speed");
  check((await page.locator("#flythrough-quality").innerText()).includes("1280 × 720"), "Visible quality label reflects actual decoded source dimensions");
  check(!loaded.muted, "Flythrough starts with its real audio track available");
  check(mediaRequests().length === mediaBeforeSwitch, "Switching Explore to Play video reuses the existing source instead of a second decoder");
  await page.evaluate(() => document.querySelector("#flythrough-video").pause());
  const pausedAt = (await snapshot()).time; await page.waitForTimeout(350);
  check(Math.abs((await snapshot()).time - pausedAt) < .08, "Real media pause stops the playhead");
  await video.focus(); await page.keyboard.press("Space");
  await page.waitForFunction(() => !document.querySelector("#flythrough-video").paused);
  // paused=false records playback intent, not advancement of the media clock.
  // Require the actual media clock to advance, with a bounded stall failure,
  // instead of racing decoder startup against a fixed wall-clock sleep.
  await page.waitForFunction((time) => {
    const v = document.querySelector("#flythrough-video");
    return !v.paused && v.currentTime > time + .2;
  }, pausedAt, { timeout: 4000 });
  check((await snapshot()).time > pausedAt + .2, "Native keyboard play control advances normal playback independently of page scroll");
  await page.keyboard.press("Space");
  await page.waitForFunction(() => document.querySelector("#flythrough-video").paused, undefined, { timeout: 2000 });
  check((await snapshot()).paused, "Native keyboard pause control works");
  await page.evaluate(() => { const v = document.querySelector("#flythrough-video"); v.pause(); v.currentTime = 1; });
  await page.waitForFunction(() => Math.abs(document.querySelector("#flythrough-video").currentTime - 1) < .08 && !document.querySelector("#flythrough-video").seeking);
  await page.locator('#flythrough-modal [data-video-seek="4"]').click();
  await page.waitForFunction(() => Math.abs(document.querySelector("#flythrough-video").currentTime - 4) < .15 && !document.querySelector("#flythrough-video").seeking);
  check(Math.abs((await snapshot()).time - 4) < .15, "Room chapter seeks the actual media timeline");
  // `currentTime` and `seeking=false` describe the media timeline, not the
  // compositor. Wait for a presented decoded frame before reading its pixels.
  const presented = await page.evaluate(() => new Promise((resolveFrame, reject) => {
    const v = document.querySelector("#flythrough-video");
    const timer = setTimeout(() => reject(new Error("No decoded frame was presented after the chapter seek")), 2500);
    v.requestVideoFrameCallback((_, metadata) => { clearTimeout(timer); resolveFrame({ mediaTime: metadata.mediaTime, width: metadata.width, height: metadata.height }); });
  }));
  check(presented.mediaTime >= 3.9 && presented.mediaTime < 5 && presented.width === 1280 && presented.height === 720, "Browser presents an actual decoded frame at the selected chapter");
  const frame = await page.evaluate(() => { const v = document.querySelector("#flythrough-video"), c = document.createElement("canvas"); c.width = 32; c.height = 18; const ctx = c.getContext("2d"); ctx.drawImage(v, 0, 0, 32, 18); return Array.from(ctx.getImageData(0, 0, 32, 18).data); });
  writeFileSync(join(evidence, "decoded-frame.json"), JSON.stringify({ presented, channelValues: new Set(frame.filter((_, i) => i % 4 !== 3)).size, pixels: frame }, null, 2) + "\n");
  check(new Set(frame.filter((_, i) => i % 4 !== 3)).size > 80, "Seeking yields a real nonempty decoded test-pattern frame");
  const beforeExplore = await snapshot();
  await page.evaluate(() => {
    document.querySelector('#flythrough-explore').addEventListener('click', () => {
      const v = document.querySelector('#flythrough-video');
      window.__exploreHandoff = { time: v.currentTime, currentSrc: v.currentSrc, duration: v.duration };
    }, { capture: true, once: true });
  });
  // The chapter action resumes playback. A sample before Playwright dispatches
  // the click is already stale by the time the production handler pauses it.
  // Exercise real media-clock advancement, then sample at that exact boundary.
  await page.waitForFunction((time) => {
    const v = document.querySelector('#flythrough-video');
    return !v.paused && v.currentTime > time + .2;
  }, beforeExplore.time, { timeout: 4000 });
  await page.locator('#flythrough-explore').click();
  await page.waitForFunction(()=>document.querySelector('#flythrough-video').paused);
  const handoff = await page.evaluate(() => window.__exploreHandoff), afterExplore = await snapshot();
  const switchAt = fault === 'stale-explore-reference' ? beforeExplore.time : handoff.time;
  const positionPercent = Number(await page.locator('#flythrough-position').getAttribute('aria-valuenow'));
  writeFileSync(join(evidence, 'explore-handoff.json'), JSON.stringify({ beforeExplore, handoff, afterExplore,
    positionPercent, toleranceSeconds: .15, staleDelta: afterExplore.time-beforeExplore.time,
    handoffDelta: afterExplore.time-handoff.time }, null, 2) + '\n');
  check(!afterExplore.controls && afterExplore.muted && Math.abs(afterExplore.time-switchAt)<.15, "Returning to Explore pauses at the current playback position without losing the tour");
  check(afterExplore.currentSrc===handoff.currentSrc && Math.abs(positionPercent-100*handoff.time/handoff.duration)<=1, "Reverse switch retains source and synchronizes accessible position");
  await page.evaluate(()=>{const v=document.querySelector('#flythrough-viewer');v.scrollTop=(v.scrollHeight-v.clientHeight)*.25;v.dispatchEvent(new Event('scroll'));v.scrollTop=(v.scrollHeight-v.clientHeight)*.75;v.dispatchEvent(new Event('scroll'));});
  await page.waitForFunction(()=>{const v=document.querySelector('#flythrough-video');return Math.abs(v.currentTime-6)<.1&&!v.seeking;});
  check(Math.abs((await snapshot()).time-6)<.1 && (await snapshot()).paused, "Rapid Explore scroll changes resolve to the latest requested decoded position");
  await page.evaluate(()=>{const v=document.querySelector('#flythrough-video');window.__originalPlay=v.play;v.play=()=>new Promise((resolve,reject)=>{window.__rejectPlay=reject;});});
  await page.locator('#flythrough-watch').click(); await page.locator('#flythrough-explore').click();
  await page.evaluate(()=>{window.__rejectPlay(new Error('Synthetic delayed autoplay rejection'));document.querySelector('#flythrough-video').play=window.__originalPlay;});
  await page.waitForTimeout(50);
  check(await page.locator('#flythrough-play').isHidden() && await page.locator('#flythrough-status').innerText().then(t=>t.includes('Scroll on the video')), "A delayed playback rejection cannot replace the current Explore controls or instructions");
  await page.locator('#flythrough-watch').click();
  for (let i = 0; i < 15; i++) { await page.keyboard.press("Tab"); check(await page.evaluate(() => document.querySelector("#flythrough-modal").contains(document.activeElement)), "Native dialog keeps keyboard focus inside, tab " + (i + 1)); }
  await page.keyboard.press("Shift+Tab");
  check(await page.evaluate(() => document.querySelector("#flythrough-modal").contains(document.activeElement)), "Reverse Tab stays inside the dialog");
  for (const [width, height] of [[320, 568], [390, 844], [844, 390], [1440, 900]]) {
    await page.setViewportSize({ width, height });
    const bounds = await modal.boundingBox(), exit = await close.boundingBox();
    check(bounds && bounds.x >= -1 && bounds.y >= -1 && bounds.x + bounds.width <= width + 1 && bounds.y + bounds.height <= height + 1, "Dialog fits viewport " + width + "×" + height);
    check(exit && exit.width >= 44 && exit.height >= 44 && exit.x >= 0 && exit.y >= 0 && exit.x + exit.width <= width && exit.y + exit.height <= height, "Close stays visible and tappable at " + width + "×" + height);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: join(evidence, "flythrough-mobile.png") });
  await closeAndCheck("First close");
  for (let i = 0; i < 3; i++) { await page.evaluate(() => { window.__savedScroll = scrollY; }); await open(); check(await page.locator("#flythrough-video").count() === 1 && await page.locator("#flythrough-modal[open]").count() === 1, "Repeated open " + (i + 1) + " has one player/dialog"); await closeAndCheck("Repeated close " + (i + 1)); }
  await page.evaluate(() => { window.__savedScroll = scrollY; const watch = document.querySelector("#open-flythrough"); watch.click(); document.querySelector("#flythrough-close").click(); watch.click(); });
  await page.waitForTimeout(150);
  check(await page.evaluate(() => document.querySelector("#flythrough-modal").open), "A queued previous Close event cannot close a rapidly reopened dialog");
  await page.waitForFunction(() => document.querySelector("#flythrough-modal").open && document.querySelector("#flythrough-video").readyState >= 2);
  check((await snapshot()).width === 1280 && (await snapshot()).paused && await page.locator('#flythrough-explore').getAttribute('aria-pressed') === 'true', "Rapid close/reopen produces a decoded Explore view in the current session");
  await closeAndCheck("Rapid reopen close");
  await entry.scrollIntoViewIfNeeded();
  await page.evaluate(() => { window.__savedScroll = scrollY; }); await open();
  await page.keyboard.press("Escape"); await modal.waitFor({ state: "hidden" });
  await unloaded();
  check((await snapshot()).src === null && (await snapshot()).ready === 0 && (await snapshot()).network === 0 && (await snapshot()).paused, "Escape invokes complete media cleanup");
  check(await page.evaluate(() => document.activeElement?.id === "open-flythrough" && Math.abs(scrollY - window.__savedScroll) <= 1), "Escape restores entry focus and original listing position");
  await page.screenshot({ path: join(evidence, "listing-mobile.png") });

  const planRoom = page.locator('#plan [data-seek="4"]');
  await planRoom.scrollIntoViewIfNeeded();
  await page.evaluate(() => { window.__savedScroll = scrollY; });
  await planRoom.click(); await modal.waitFor({ state: "visible" });
  await page.waitForFunction(() => { const v = document.querySelector("#flythrough-video"); return v.readyState >= 2 && !v.seeking && Math.abs(v.currentTime - 4) < .15; });
  check(Math.abs((await snapshot()).time - 4) < .15, "Listing floor-plan room opens the optional player at the actual chapter");
  await close.click(); await modal.waitFor({ state: "hidden" });
  await unloaded();
  check(await page.evaluate(() => document.activeElement?.getAttribute("data-seek") === "4" && Math.abs(scrollY - window.__savedScroll) <= 1), "Closing a floor-plan chapter restores its own opener and listing position");
  check((await snapshot()).src === null && (await snapshot()).ready === 0 && (await snapshot()).network === 0, "Floor-plan entry uses the same complete media teardown");

  // Close while headers/body/metadata are still arriving. A paused video with
  // src retained would continue the request and fails this actual socket check.
  await page.goto(base + "/f/synthetic-slow");
  const slowBefore = mediaRequests().length;
  await entry.click(); await modal.waitFor({ state: "visible" });
  await waitUntil(() => mediaRequests().length > slowBefore && mediaState.active > 0, "Slow media must be genuinely transferring");
  await close.click(); await modal.waitFor({ state: "hidden" });
  await unloaded();
  await waitUntil(() => mediaState.active === 0 && mediaState.aborted > 0, "Close must cancel unfinished real video transfer", 6000);
  check(mediaState.aborted > 0 && mediaState.active === 0, "Closing during load aborts the real incomplete byte-range transfer");
  const slowCount = mediaRequests().length; await page.waitForTimeout(500);
  check(mediaRequests().length === slowCount && (await snapshot()).src === null && (await snapshot()).network === 0, "Late metadata/loader callbacks do not reattach closed media");

  await page.goto(base + "/f/synthetic-failed");
  await entry.click(); await modal.waitFor({ state: "visible" });
  await page.locator("#flythrough-retry").waitFor({ state: "visible" });
  check((await snapshot()).ready === 0, "A real failed video request offers retry instead of pretending media is ready");
  failVideoRequests = false;
  await page.locator("#flythrough-retry").click();
  await page.waitForFunction(() => document.querySelector("#flythrough-video").readyState >= 2);
  check((await snapshot()).width === 1280, "Explicit retry recovers and decodes the real media source");
  await close.click(); await modal.waitFor({ state: "hidden" });
  await unloaded();
  check(await page.locator("#overview").isVisible() && (await snapshot()).src === null && (await snapshot()).network === 0, "Failed/retried video can still return to normal listing details");

  const spatialMediaStart = mediaRequests().length;
  await page.goto(base + "/f/synthetic-spatial");
  const spatialEntry = page.locator("#plan [data-spatial-scene]");
  const enterSpatial = async (button) => {
    await button.click();
    if (spatialModel) {
      await page.getByRole("status").filter({ hasText: "Reviewed room." }).waitFor();
      await page.waitForFunction(() => window.__spatialDraws > 0);
      check(await page.locator("canvas").count() === 1, "Normal listing enters actual PlayCanvas/SOG canvas");
      check(await page.evaluate(() => window.__spatialDraws > 0), "Normal listing 3D entry produces a real nonempty instanced framebuffer draw");
    } else {
      await page.getByRole("status").filter({ hasText: "3D could not load" }).waitFor();
      check(await page.locator("canvas").count() === 0, "Actual spatial-module failure offers a return without fake rendering");
    }
  };
  const exitSpatial = async () => {
    await page.getByRole("button", { name: spatialModel ? "Close 3D" : "Back to listing", exact: true }).click();
    check(await page.locator("canvas").count() === 0 && await page.locator(".spatial-view").count() === 0, "Spatial exit tears down its actual canvas/UI");
    if (spatialModel) check(await page.evaluate(() => !window.pc.Application.getApplication()), "Spatial exit destroys the actual PlayCanvas application");
  };
  await spatialEntry.scrollIntoViewIfNeeded(); await page.evaluate(() => { window.__savedScroll = scrollY; });
  await enterSpatial(spatialEntry); await exitSpatial();
  check(mediaRequests().length === spatialMediaStart, "Listing-to-3D-to-listing never fetches a hidden flythrough");
  check(await page.evaluate(() => document.activeElement?.hasAttribute("data-spatial-scene") && Math.abs(scrollY - window.__savedScroll) <= 1), "Spatial return restores its listing opener and original scroll position");
  await entry.scrollIntoViewIfNeeded(); await page.evaluate(() => { window.__savedScroll = scrollY; }); await open();
  check(mediaRequests().length > spatialMediaStart, "Flythrough after spatial return loads only on the user's separate watch action");
  await enterSpatial(page.locator("#flythrough-modal [data-spatial-scene]"));
  check((await snapshot()).src === null && (await snapshot()).network === 0 && (await snapshot()).paused, "Opening spatial from flythrough unloads and pauses the real media");
  const switchedCount = mediaRequests().length; await exitSpatial(); await page.waitForTimeout(350);
  check(mediaRequests().length === switchedCount && (await snapshot()).src === null && (await snapshot()).network === 0, "Returning from spatial does not restart the previously open flythrough");
  check(await page.evaluate(() => document.activeElement?.id === "open-flythrough"), "Returning from a former video chapter focuses a visible listing watch action");

  const clientMediaStart = mediaRequests().length;
  for (const client of ["alpha", "beta"]) {
    await page.goto(base + "/f/synthetic-client-" + client);
    await page.locator('#listing-nav a[href="#endcard"]').click();
    await page.waitForFunction(() => { const img = document.querySelector("#endcard .avatar img"); return img?.complete && img.naturalWidth > 0; });
    check(await page.locator("#endcard .nm").innerText() === "Synthetic Client " + client, "Client " + client + " listing displays its own contact name");
    check(await page.locator("#endcard .avatar img").evaluate((img) => img.complete && img.naturalWidth > 0 && img.getAttribute("src").includes("client-")), "Client " + client + " headshot loads as real browser image");
    check(await page.locator("#endcard a[href^='mailto:']").getAttribute("href") === "mailto:" + client + "@example.invalid", "Client " + client + " email opens its own contact address");
    check(await page.locator("#getapp,#brand,#wm,.lp-partner,.lp-madeby,meta[name='apple-itunes-app'],link[href='/favicon.svg'],a[href^='/a/']").count() === 0, "Client page removes vendor promotions and photographer portfolio without stripping contact");
    check(await page.locator("#leadform .privacy").innerText().then((text) => text.includes("photographer or video producer") && text.includes("Rendprop")), "Client enquiry transparently discloses who stores and receives buyer details");
    check(await page.locator("#disclosure").count() === 1 && await page.locator(".lp-legal a[href='/privacy']").count() === 1, "Client page retains alteration disclosure and privacy access");
    check(mediaRequests().length === clientMediaStart, "Client details and contact require no hidden flythrough load");
  }
  await page.locator('#leadform input[name="name"]').fill("Synthetic Buyer");
  await page.locator('#leadform input[name="phone"]').fill("555-010-3030");
  await page.locator('#leadform input[name="email"]').fill("buyer@example.invalid");
  await page.locator('#leadform textarea[name="message"]').fill("Synthetic request only. No external email.");
  await page.locator('#leadform button[type="submit"]').click();
  await page.locator("#leadok").waitFor({ state: "visible" });
  const clientLead = requests.filter((r) => r.path === "/api/leads");
  check(clientLead.length === 1 && clientLead[0].payload.slug === "synthetic-client-beta", "Actual client form sends only the current listing's slug to the lead API");
  check(clientLead[0].payload.name === "Synthetic Buyer" && !Object.hasOwn(clientLead[0].payload, "recipient_email"), "Public form records buyer details without trusting a browser-selected client recipient");
  await page.screenshot({ path: join(evidence, "client-contact-mobile.png") });

  const unbrandedStart = mediaRequests().length;
  await page.goto(base + "/u/synthetic-listing"); await page.waitForTimeout(300);
  check(mediaRequests().length === unbrandedStart, "Unbranded listing also waits for an explicit watch action");
  check(await page.locator("form,input,textarea,#share,#brand,#wm,#endcard").count() === 0, "Unbranded DOM has no agent, lead, brand or share surface");
  check(!(await page.content()).match(/Synthetic Branded Agent|Synthetic Brokerage|synthetic-agent@example\.test|rendprop\.com|book a showing/i), "Unbranded markup, script and metadata leak no sentinel identity/promotion");
  check((await page.locator("#disclosure summary").innerText()).includes("digitally altered or AI-generated"), "Unbranded alteration summary stays visible even when mobile details are collapsed");
  if (!(await page.locator("#disclosure details").evaluate((el) => el.open))) await page.locator("#disclosure summary").click();
  check(await page.locator("#disclosure").innerText().then((text) => text.includes("Objects were removed digitally.")), "Unbranded user can expand and read the exact AI alteration disclosure");
  await entry.scrollIntoViewIfNeeded();
  await page.evaluate(() => { window.__savedScroll = scrollY; }); await open();
  check((await snapshot()).width === 1280, "Unbranded explicit watch decodes the same actual property media");
  await closeAndCheck("Unbranded close");

  const noVideoStart = mediaRequests().length;
  await page.goto(base + "/f/synthetic-no-video"); await page.waitForTimeout(300);
  check(mediaRequests().length === noVideoStart, "No-media listing never probes a nonexistent video");
  check(await page.locator("#overview").isVisible() && await page.locator("#gallery").count() === 1 && await page.locator("#leadform").count() === 1, "Listing without a flythrough still provides details/photos/enquiry");
  check(await entry.count() === 0 || await entry.isDisabled(), "No-media listing does not present a working watch action");
  check(pageErrors.length === 0, "No uncaught JavaScript errors: " + pageErrors.join("; "));
  check(externalRequests.length === 0, "All actual browser requests stayed on isolated loopback");
  const receipt = { passed: true, assertions: checks.length, sourcePlayerSha256: sourceHash, sourceHashes, fault, browser: await browser.version(), fixture: { name: "SYNTHETIC-NOT-A-LISTING.mp4", bytes: movie.length, sha256: movieHash, width: 1280, height: 720, seconds: 8, codecs: "H.264/AAC" }, spatial: spatialManifest ? { synthetic: true, actualEngineAndDraw: true, modelBytes: spatialManifest.bytes, sha256: spatialManifest.sha256, count: 2048 } : { synthetic: true, actualModuleFailureReturn: true, actualEngineAndDraw: false }, checks, navigationMeasurements, requests, mediaState, pageErrors, externalRequests, limitation: "Synthetic real Chromium media and renderer. No iPhone/Safari camera, customer listing, production upload resolution, real reconstructed room or HLS proof." };
  writeFileSync(join(evidence, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
  console.log(`Listing browser: ${checks.length} assertions passed; real rendered page/720p H.264-AAC/ranges/transfer cancellation. Receipt: ${join(evidence, "receipt.json")}`);
} catch (error) {
  const failureState = await browserPage?.evaluate(() => { const v = document.querySelector("#flythrough-video"); return v ? { src: v.getAttribute("src"), currentSrc: v.currentSrc, paused: v.paused, ready: v.readyState, network: v.networkState, error: v.error?.message, modalOpen: document.querySelector("#flythrough-modal")?.open, focus: document.activeElement?.id, scrollY, expectedScrollY: window.__savedScroll } : null; }).catch(() => null);
  await browserPage?.screenshot({ path: join(evidence, "failure.png") }).catch(() => {});
  writeFileSync(join(evidence, "receipt.json"), JSON.stringify({ passed: false, sourcePlayerSha256: sourceHash, sourceHashes, fault, error: error.message, checks, navigationMeasurements, requests, mediaState, pageErrors, failureState }, null, 2) + "\n");
  throw error;
} finally {
  await browser?.close();
  if (server) { server.closeAllConnections(); await new Promise((r) => server.close(r)); }
}
