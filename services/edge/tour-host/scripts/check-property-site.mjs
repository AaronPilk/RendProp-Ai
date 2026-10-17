// Actual Worker + rendered property pages. All upstream/storage/provider
// boundaries are closed synthetic fixtures; no account or network is used.
import assert from "node:assert/strict";
import vm from "node:vm";
import { buildSrc } from "./build-src.mjs";
const load = buildSrc("property-site-check");
const { renderTourPage, unbrandedSelfCheck } = await load("player");
const { buildDemoTour } = await load("demo");
const { default: worker } = await load("index");
const { propertyPage, PROPERTY_SITE_JS } = await load("property-site");
let assertions = 0, fetches = [];
const check = (value, reason) => { assertions++; assert.ok(value, reason); };
const fixture = () => ({ ...buildDemoTour(), slug: "synthetic-polish", published_at: "2026-01-01T00:00:00Z",
  listing: { ...buildDemoTour().listing, address: '123 Synthetic Avenue <script>private()</script>',
    lat: 27.771234, lng: -82.641234, details: { story: "Published description.", gallery: ["/published-photo.jpg"],
      show_partners: false, show_app_cta: false, nearbyAttractions: "An owner-reviewed place note." } },
  cover_url: "/published-cover.jpg", gallery: ["/published-photo.jpg"], floorplan_url: "/published-plan.jpg",
  agent_card: { name: "Synthetic Contact", email: "contact@example.invalid", phone: "555-010-1000" },
  cta: { mode: "lead_form", label: "Request a showing", lead_fields: ["message", "showing_date"], secondary: [], url: null },
});
const env = { SUPABASE_FUNCTIONS_URL: "https://property-fixture.invalid/functions/v1", SUPABASE_ANON_KEY: "synthetic-anon", TOUR_CACHE_TTL: "60" };
const ctx = { waitUntil() {}, passThroughOnException() {} };
const entries = new Map();
globalThis.caches = { default: { async match(request) { return entries.get(request.url)?.clone(); }, async put(request, response) { entries.set(request.url, response.clone()); } } };
let current = fixture(), upstreamStatus = 200, locationOverride;
const publicLocation = () => ({ slug: current.slug, space_type: current.space_type || "real_estate", published_at: current.published_at,
  listing: { lat: current.listing.lat == null ? null : Math.round(current.listing.lat * 1000) / 1000,
    lng: current.listing.lng == null ? null : Math.round(current.listing.lng * 1000) / 1000 } });
globalThis.fetch = async (url, init) => {
  fetches.push({ url, init });
  const location = url.endsWith("/location");
  assert.equal(url, env.SUPABASE_FUNCTIONS_URL + "/tours/synthetic-polish" + (location ? "/location" : ""), "No provider or arbitrary network call");
  assert.equal(init.cache, "no-store", "Publication read stays uncached");
  return new Response(upstreamStatus === 200 ? JSON.stringify(location ? locationOverride || publicLocation() : current) : "not published", { status: upstreamStatus });
};
const get = (path, method = "GET") => worker.fetch(new Request("https://rendprop.com" + path, { method }), env, ctx);
for (const page of ["home", "gallery", "location", "contact"]) {
  const html = renderTourPage(fixture(), env.SUPABASE_FUNCTIONS_URL, "synthetic-anon", "", { page });
  for (const target of ["home", "gallery", "location", "contact"]) {
    const path = "/f/synthetic-polish" + (target === "home" ? "" : "?page=" + target);
    check(html.includes(`href="${path}"${target === page ? ' aria-current="page"' : ""}`), `${page} has real ${target} navigation/current state`);
  }
  check(html.includes("123 Synthetic Avenue &lt;script&gt;private()&lt;/script&gt;"), `${page} escapes property text`);
  check(!/<video[^>]*\ssrc=/i.test(html), `${page} does not attach the opt-in tour`);
  check(!html.includes("googletagmanager") && !html.includes("fbevents") && !html.includes("fonts.googleapis.com"), `${page} imports no template tracking/fonts`);
  for (const [, script] of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) { new vm.Script(script); assertions++; }
  check(html.includes('id="disclosure"'), `${page} preserves alteration disclosure/originals`);
  const response = await get("/f/synthetic-polish" + (page === "home" ? "" : "?page=" + page));
  check(response.status === 200 && response.headers.get("cache-control") === "no-store", `${page} is freshly published uncached HTML`);
  check((await response.text()).includes(`property-page-${page}`), `${page} route actually selects content`);
  upstreamStatus = 404;
  const revoked = await get("/f/synthetic-polish?page=" + page);
  check(revoked.status === 404 && !(await revoked.text()).includes("123 Synthetic"), `${page} cannot retain revoked customer HTML`);
  upstreamStatus = 200;
}
// A main landmark and native keyboard bypass belong only to polished pages.
// These are actual renderer outputs; neither modal nor page chrome is moved.
for (const theme of ["basic", "signature-estate", "coastal-luxe"]) for (const page of ["home", "gallery", "location", "contact"]) {
  const html = renderTourPage({ ...fixture(), website_theme:theme }, "", "", "", { page });
  const main = '<main id="property-content" tabindex="-1">', skip = '<a class="property-skip-link" href="#property-content">Skip to property content</a>';
  check((html.match(/<main\b/g) || []).length === 1 && html.includes(main), `${theme}/${page} has one focusable main landmark`);
  check((html.match(/class="property-skip-link"/g) || []).length === 1 && html.includes(skip), `${theme}/${page} has one exact native bypass link`);
  const body = html.slice(html.indexOf("<body"));
  check(body.match(/<(?:a|button|input|textarea|select|summary)\b[^>]*>/)?.[0] === skip.slice(0, skip.indexOf(">") + 1), `${theme}/${page} bypass is the first keyboard control`);
  const start=html.indexOf(main), end=html.indexOf("</main>");
  check(html.indexOf("</nav>") < start && start < end, `${theme}/${page} navigation stays outside main`);
  for (const id of ["overview", "endcard", "disclosure"]) {
    const at=html.indexOf(`id="${id}"`);
    check(at < 0 || at > start && at < end, `${theme}/${page} ${id} content stays inside main`);
  }
  for (const marker of ["<footer", '<dialog id="property-photo-modal"', '<dialog id="flythrough-modal"']) {
    check(html.indexOf(marker) > end, `${theme}/${page} ${marker} stays outside main`);
  }
}
for (const opts of [{embed:true}, {unbranded:true}]) {
  const html=renderTourPage(fixture(), "", "", "", opts);
  check(!html.includes('<main id="property-content"') && !html.includes('class="property-skip-link"'), "Embed/unbranded do not receive the polished bypass wrapper");
}
const nonProperty=renderTourPage({...fixture(),space_type:"venue"},"","","",{});
check(!nonProperty.includes('<main id="property-content"') && !nonProperty.includes('class="property-skip-link"'), "Non-property renderer does not receive the polished wrapper");

const gallery = renderTourPage(fixture(), "", "", "", { page: "gallery" });
check(gallery.includes('data-property-photo href="/published-photo.jpg"'), "Gallery complete-photo anchor works without JS");
check(gallery.includes('<noscript><img src="/published-photo.jpg"'), "No-JS Gallery displays the real image, not a placeholder");
const many = fixture(); many.gallery = Array.from({ length: 13 }, (_, n) => ({ url: `/published-${n}.jpg`, label: `Photo ${n}` }));
const preview = renderTourPage(many, "", "", "", { page: "home" });
const fullGallery = renderTourPage(many, "", "", "", { page: "gallery" });
check((preview.match(/data-property-photo href=/g) || []).length === 4 && preview.includes('View all 13 photos'), "Home previews four photos and links to the complete Gallery");
check((fullGallery.match(/data-property-photo href=/g) || []).length === 13, "Dedicated Gallery preserves all published selections");
check(fullGallery.includes('href="/published-12.jpg"') && fullGallery.includes('data-property-src="/published-12.jpg"'), "Deferred image and full-size link retain the same actual source");
// Execute the actual progressive loader with closed DOM/observer boundaries.
// Offscreen master files are not assigned until a viewport intersection; older
// browsers without IntersectionObserver still display every published image.
function checkPhotoLoading(script, supportsObserver = true) {
  const images = ["/first-master.jpg", "/second-master.jpg"].map(source => ({
    src: "placeholder", loading: "lazy", source, listeners: new Map(),
    link: { href: source.replace("-master", "-full-master") },
    getAttribute(name) { return name === "data-property-src" ? this.source : null; },
    removeAttribute(name) { if (name === "data-property-src") this.source = null; },
    closest(selector) { assert.equal(selector, "[data-property-photo]"); return this.link; },
    addEventListener(type, handler, options) { assert.equal(type, "error"); assert.equal(options.once, true); this.listeners.set(type, handler); },
    error() { const handler = this.listeners.get("error"); if (handler) { this.listeners.delete("error"); handler(); } },
  }));
  const observed = [], unobserved = []; let callback, options;
  const document = { querySelectorAll(selector) { assert.equal(selector, "img[data-property-src]"); return images; }, getElementById() { return null; } };
  const context = { document };
  if (supportsObserver) context.IntersectionObserver = function(handler, opts) {
    callback = handler; options = opts;
    this.observe = image => observed.push(image); this.unobserve = image => unobserved.push(image);
  };
  vm.runInNewContext(script, context);
  if (!supportsObserver) {
    assert.deepEqual(images.map(image => image.src), ["/first-master.jpg", "/second-master.jpg"]);
    return;
  }
  assert.equal(options.rootMargin, "160px 0px");
  assert.deepEqual(images.map(image => image.src), ["placeholder", "placeholder"], "Offscreen sources are not eagerly assigned");
  assert.equal(observed.length, 2);
  callback([{ target: images[0], isIntersecting: false }]);
  assert.equal(images[0].src, "placeholder", "Non-intersection cannot fetch a master");
  callback([{ target: images[0], isIntersecting: true }]);
  assert.equal(images[0].src, "/first-master.jpg"); assert.equal(images[0].source, null);
  assert.equal(images[1].src, "placeholder"); assert.equal(unobserved.length, 1);
  images[0].error();
  assert.equal(images[0].src, "/first-full-master.jpg", "Failed preview falls back to its exact published master");
  images[0].link.href = "/changed-after-first-error.jpg";
  images[0].error();
  assert.equal(images[0].src, "/first-full-master.jpg", "A failed master cannot trigger another fallback request");
}
checkPhotoLoading(PROPERTY_SITE_JS); assertions += 10;
checkPhotoLoading(PROPERTY_SITE_JS, false); assertions++;
assert.throws(() => checkPhotoLoading(PROPERTY_SITE_JS.replace("propertyThumbs.forEach(function(image){propertyPhotoObserver.observe(image);});", "propertyThumbs.forEach(loadPropertyThumb);")), /Offscreen sources are not eagerly assigned/); assertions++;
assert.throws(() => checkPhotoLoading(PROPERTY_SITE_JS.replace("if(entry.isIntersecting)", "if(true)")), /Non-intersection cannot fetch a master/); assertions++;
// Room-grouped editorial Gallery on the premium designs. Groups follow the
// first appearance of each label and photos keep their published order inside
// a group, so the document order the photo viewer walks is the visual order.
const roomLabels = ["Kitchen", "Living room", "Kitchen", "Primary bedroom", "", "kitchen ", "Living room"];
const roomed = fixture(); roomed.gallery = roomLabels.map((label, n) => ({ url: `/room-${n}.jpg`, label }));
const hrefOrder = html => [...html.matchAll(/data-property-photo href="([^"]+)"/g)].map(m => m[1]);
for (const theme of ["signature-estate", "coastal-luxe"]) {
  const html = renderTourPage({ ...roomed, website_theme: theme }, "", "", "", { page: "gallery" });
  const titles = [...html.matchAll(/<h2 class="lp-gal-room-title" id="lp-gal-room-(\d)">([^<]+)(?:<span class="lp-gal-room-count">([^<]+)<\/span>)?<\/h2>/g)].map(m => [m[1], m[2], m[3] || ""]);
  check(JSON.stringify(titles) === JSON.stringify([["1", "Kitchen", "3 photos"], ["2", "Living room", "2 photos"], ["3", "Primary bedroom", ""], ["4", "More of the home", ""]]), `${theme}: rooms are grouped by label in first-appearance order, case/space-insensitively, unlabelled photos last`);
  check(JSON.stringify(hrefOrder(html)) === JSON.stringify(["/room-0.jpg", "/room-2.jpg", "/room-5.jpg", "/room-1.jpg", "/room-6.jpg", "/room-3.jpg", "/room-4.jpg"]) && (html.match(/<section class="lp-gal-room" aria-labelledby="lp-gal-room-\d">/g) || []).length === 4, `${theme}: every photo is kept once, in group order`);
  const gallerySection = html.slice(html.indexOf('id="gallery"'), html.indexOf('id="disclosure"'));
  check(!gallerySection.includes("<figcaption>") && html.includes('alt="Kitchen"') && html.includes('aria-label="View full photo: Kitchen"'), `${theme}: the room heading replaces per-photo captions while alt text and viewer titles keep the label`);
  check(gallerySection.includes('class="lp-fine lp-mediadate"') && gallerySection.indexOf("lp-mediadate") > gallerySection.lastIndexOf('<section class="lp-gal-room"'), `${theme}: the media date note follows the last room`);
  const blockOrder = h => [...h.matchAll(/<div class="lp-gal-run">|<section class="lp-gal-room" aria-labelledby="lp-gal-room-(\d)">/g)].map(m => m[1] ? "room" + m[1] : "run");
  check(JSON.stringify(blockOrder(html)) === JSON.stringify(["room1", "room2", "run", "room3", "room4"]) && html.includes('</section></div><p class="lp-fine lp-mediadate">'), `${theme}: consecutive one-photo rooms share one row grid, after the multi-photo rooms`);
  const split = renderTourPage({ ...roomed, website_theme: theme, gallery: ["Den", "Kitchen", "Kitchen", "Bath"].map((label, n) => ({ url: `/split-${n}.jpg`, label })) }, "", "", "", { page: "gallery" });
  check(JSON.stringify(blockOrder(split)) === JSON.stringify(["run", "room1", "room2", "run", "room3"]) && JSON.stringify(hrefOrder(split)) === JSON.stringify(["/split-0.jpg", "/split-1.jpg", "/split-2.jpg", "/split-3.jpg"]), `${theme}: a multi-photo room ends a run of one-photo rooms and document order is kept`);
  const home = renderTourPage({ ...roomed, website_theme: theme }, "", "", "", { page: "home" });
  check(!home.includes('<section class="lp-gal-room"') && hrefOrder(home).length === 4, `${theme}: Home keeps its flat four-photo preview`);
  const oneRoom = renderTourPage({ ...roomed, website_theme: theme, gallery: roomLabels.map((_, n) => ({ url: `/room-${n}.jpg`, label: n === 1 ? "" : "Kitchen" })) }, "", "", "", { page: "gallery" });
  check(!oneRoom.includes('<section class="lp-gal-room"') && hrefOrder(oneRoom).length === 7 && oneRoom.includes("<figcaption>Kitchen</figcaption>"), `${theme}: fewer than two distinct labels keeps the flat grid`);
  const unlabelled = renderTourPage({ ...roomed, website_theme: theme, gallery: roomLabels.map((_, n) => ({ url: `/room-${n}.jpg` })) }, "", "", "", { page: "gallery" });
  check(!unlabelled.includes('<section class="lp-gal-room"') && hrefOrder(unlabelled).length === 7, `${theme}: real listings without labels keep the flat grid`);
  const captions = ["Twilight arrival", "Chef's kitchen", "Great room", "Primary bath", "", "Sunken lounge", "The estate"];
  const captioned = renderTourPage({ ...roomed, website_theme: theme, gallery: captions.map((label, n) => ({ url: `/room-${n}.jpg`, label })) }, "", "", "", { page: "gallery" });
  const captionedSection = captioned.slice(captioned.indexOf('id="gallery"'), captioned.indexOf('id="disclosure"'));
  check(!captioned.includes('<section class="lp-gal-room"') && JSON.stringify(hrefOrder(captioned)) === JSON.stringify(captions.map((_, n) => `/room-${n}.jpg`)) && (captionedSection.match(/<figcaption>/g) || []).length === 6 && captionedSection.includes("<figcaption>Chef&#39;s kitchen</figcaption>"), `${theme}: labels that never repeat are captions, so the captioned flat grid stays (no one-photo rooms)`);
  const previewed = renderTourPage(roomed, "", "", "", { page: "gallery", previewTheme: theme });
  check((previewed.match(/<section class="lp-gal-room"/g) || []).length === 4, `${theme}: design preview shows the grouped gallery`);
}
const classicRooms = renderTourPage(roomed, "", "", "", { page: "gallery" });
check(!classicRooms.includes('<section class="lp-gal-room"') && JSON.stringify(hrefOrder(classicRooms)) === JSON.stringify(roomLabels.map((_, n) => `/room-${n}.jpg`)) && (classicRooms.slice(classicRooms.indexOf('id="gallery"'), classicRooms.indexOf('id="disclosure"')).match(/<figcaption>/g) || []).length === 6, "Classic Gallery is unchanged: flat grid, published order, captions");
check(gallery.indexOf('id="gallery"') < gallery.indexOf('id="plan"'), "Dedicated Gallery leads with photos, ahead of floor plans");
check(!gallery.includes('id="endcard"') && !gallery.includes('class="listing-cover"'), "Gallery is its own page, not the Home content repeated");
const location = renderTourPage(fixture(), "", "", "", { page: "location" });
check(location.includes("maps/search/?api=1&amp;query=27.771234%2C-82.641234"), "Location map uses published coordinates");
check(location.includes("An owner-reviewed place note."), "Location keeps owner-reviewed context");
check(location.includes("not travel times") && location.includes("© OpenStreetMap contributors"), "Location declares distance limitations/map attribution");
check(location.includes('<noscript>') && location.includes('data-endpoint="/f/synthetic-polish/nearby"'), "Optional nearby data leaves a no-JS map fallback");
check(location.includes('id="property-nearby-map" hidden>') && !location.includes('<g class="nm-place">'), "Cold cache renders no map and no coordinates, only the scripted lookup");
for (const page of ["home", "gallery", "contact"]) check(!renderTourPage(fixture(), "", "", "", { page }).includes('id="property-nearby"'), `${page} cannot initiate nearby requests`);
// Neighbourhood map: a static inline SVG drawn only from the nearby result.
// Already-cached places render as markup needing neither script nor request;
// the scripted path receives the same drawing from the nearby endpoint.
const { renderNearbyMap, renderNearbyList, nearbyMapSummary, labelBox: nearbyLabelBox, ringLabelBox: nearbyRingLabelBox } = await load("nearby-map");
const mapOrigin = { lat: 27.771, lng: -82.641 };
const mapPlace = (name, category, bearing, metres, id) => {
  const rad = bearing * Math.PI / 180;
  const degree = 6_371_008.8 * Math.PI / 180;
  return { name, category, lat: mapOrigin.lat + metres * Math.cos(rad) / degree, lng: mapOrigin.lng + metres * Math.sin(rad) / (degree * Math.cos(mapOrigin.lat * Math.PI / 180)), distance_m: metres, source_url: `https://www.openstreetmap.org/node/${id}` };
};
const ninePlaces = [mapPlace("Harbor <Grill> & \"Oyster\" House", "Restaurant", 35, 420, 1), mapPlace("Trattoria Luna", "Restaurant", 120, 760, 2), mapPlace("The Longest Restaurant Name In Town Ever", "Restaurant", 200, 1180, 3),
  mapPlace("Kahwa Coffee", "Cafe", 60, 300, 4), mapPlace("Bandit Coffee Co.", "Cafe", 250, 640, 5), mapPlace("Black Crow Café", "Cafe", 300, 1320, 6),
  mapPlace("Publix", "Shop", 170, 980, 7), mapPlace("Rollin' Oats Market", "Shop", 320, 450, 8), mapPlace("Haslam's Books", "Shop", 90, 1450, 9)];
const nineResult = { status: "available", places: ninePlaces, attribution: "© OpenStreetMap contributors" };
const mapHtml = renderNearbyMap(nineResult, mapOrigin);
check(/^<figure class="property-nearby-map"><svg class="property-nearby-map-svg" viewBox="0 0 360 360" role="img" aria-label="[^"]+" focusable="false">/.test(mapHtml) && mapHtml.endsWith("</figure>"), "Map is one inline SVG figure with an image role and label");
const drawing = mapHtml.slice(0, mapHtml.indexOf("</svg>")), legend = mapHtml.slice(mapHtml.indexOf("<figcaption"));
check((drawing.match(/<g class="nm-place">/g) || []).length === 9 && (drawing.match(/<circle class="nm-dot nm-restaurant"/g) || []).length === 3 && (drawing.match(/<rect class="nm-dot nm-cafe"/g) || []).length === 3 && (drawing.match(/<polygon class="nm-dot nm-shop"/g) || []).length === 3, "Map draws nine places with a distinct shape per category");
check(["nm-restaurant", "nm-cafe", "nm-shop", "nm-home-dot"].every(c => legend.split(c).length === 2) && legend.includes(">Restaurants</span>") && legend.includes(">Cafés</span>") && legend.includes(">Shops</span>") && legend.includes(">The property</span>"), "Legend explains each marker shape and the property marker");
check(mapHtml.includes('aria-label="Map of 9 nearby places within 1 mi of the property: 3 restaurants, 3 cafés, 3 shops. Positions are approximate."') && nearbyMapSummary(ninePlaces.slice(0, 1)).startsWith("Map of 1 nearby place within 0.3 mi of the property: 1 restaurant."), "Accessible name states count, radius and categories");
check((mapHtml.match(/<circle class="nm-ring"/g) || []).length === 2 && mapHtml.includes(">0.5 mi<") && mapHtml.includes(">1 mi<") && (renderNearbyMap({ status: "available", places: ninePlaces.filter(p => p.distance_m <= 1100) }, mapOrigin).match(/<circle class="nm-ring"/g) || []).length === 3, "Distance rings scale to the furthest place in quarter- or half-mile steps");
check(mapHtml.includes("Harbor &lt;Grill&gt; &amp; &quot;Oyste…") && !mapHtml.includes("<Grill>"), "Place names are escaped and shortened in the drawing");
check(!/https?:|xlink|<image|<use|<script|<foreignObject|<a\b|href=|url\(|27\.7|-82\.6|\b-?\d{2}\.\d{4,}/.test(mapHtml), "Map embeds no external host, link, script, tile or coordinate");
const labels = [...mapHtml.matchAll(/<text class="nm-label" x="([\d.]+)" y="([\d.]+)" text-anchor="(\w+)">([^<]+)</g)].map(m => ({ x: +m[1], y: +m[2], anchor: m[3], text: m[4].replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&") }));
const labelBox = l => nearbyLabelBox(l.text, l.x, l.y, l.anchor);
check(labels.length === 9 && labels.every((a, i) => labels.slice(i + 1).every(b => { const p = labelBox(a), q = labelBox(b); return p.x + p.w <= q.x || q.x + q.w <= p.x || p.y + p.h <= q.y || q.y + q.h <= p.y; })) && labels.every(l => { const b = labelBox(l); return b.x >= 0 && b.y >= 0 && b.x + b.w <= 360 && b.y + b.h <= 360; }), "Nine labels stay on the paper without overlapping each other");
check(renderNearbyMap(nineResult, mapOrigin) === mapHtml, "Map rendering is deterministic");
// A dense downtown block: nine places within 300 m with long names. The rings
// fit the places in tenth-mile steps, and names, ring distances and the paper
// edge never collide. The original layout overlapped two names and covered a
// ring distance with a third on exactly this block.
const downtown = [mapPlace("Central Oyster Bar & Grill", "Restaurant", 60, 140, 21), mapPlace("Harborside Trattoria", "Restaurant", 125, 210, 22), mapPlace("Mezcal Cantina", "Restaurant", 300, 260, 23),
  mapPlace("Morning Ritual Coffee Roasters", "Cafe", 20, 95, 24), mapPlace("Banyan Tree Café", "Cafe", 160, 120, 25), mapPlace("Black Crow Coffee", "Cafe", 235, 230, 26),
  mapPlace("Downtown Fresh Market", "Shop", 95, 175, 27), mapPlace("Tombolo Books", "Shop", 275, 110, 28), mapPlace("Waterfront Gallery Shop", "Shop", 345, 300, 29)];
const downtownHtml = renderNearbyMap({ status: "available", places: downtown }, mapOrigin);
check((downtownHtml.match(/<circle class="nm-ring"/g) || []).length === 2 && downtownHtml.includes(">0.1 mi<") && downtownHtml.includes(">0.2 mi<") && downtownHtml.includes('aria-label="Map of 9 nearby places within 0.2 mi of the property: 3 restaurants, 3 cafés, 3 shops.'), "A dense block gets tenth-mile rings that fit its places, not an oversized half-mile circle");
const unescape = s => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");
const downtownNames = [...downtownHtml.matchAll(/<text class="nm-label" x="([\d.]+)" y="([\d.]+)" text-anchor="(\w+)">([^<]+)</g)].map(m => nearbyLabelBox(unescape(m[4]), +m[1], +m[2], m[3]));
const downtownRings = [...downtownHtml.matchAll(/<text class="nm-ring-label" x="([\d.]+)" y="([\d.]+)"( text-anchor="end")?>([^<]+)</g)].map(m => nearbyRingLabelBox(unescape(m[4]), +m[1], +m[2], !!m[3]));
const apart = (p, q) => p.x + p.w <= q.x || q.x + q.w <= p.x || p.y + p.h <= q.y || q.y + q.h <= p.y, onPaper = b => b.x >= 0 && b.y >= 0 && b.x + b.w <= 360 && b.y + b.h <= 360;
check(downtownNames.length === 9 && downtownRings.length === 2 && downtownNames.every((a, i) => downtownNames.slice(i + 1).every(b => apart(a, b)) && downtownRings.every(r => apart(a, r))) && [...downtownNames, ...downtownRings].every(onPaper), "A dense block's names keep clear of each other, of the ring distances and of the paper edge");
check(downtownHtml.includes(">Harborside…<") && !downtownHtml.includes(">Harborside Trattoria<") && renderNearbyList(downtown).includes(">Harborside Trattoria</a>"), "A name with no clear spot in a crowded block is shortened on the map, and the list keeps it in full");
for (const [why, result, origin] of [["empty", { status: "empty", places: [] }, mapOrigin], ["unavailable", { status: "unavailable", places: [] }, mapOrigin], ["no places", { status: "available", places: [] }, mapOrigin], ["no origin", nineResult, { lat: null, lng: null }]]) {
  check(renderNearbyMap(result, origin) === "", `No map without places (${why})`);
}
const staticLocation = renderTourPage(fixture(), "", "", "", { page: "location", nearby: nineResult });
check(staticLocation.includes(mapHtml.slice(0, 120)) && (staticLocation.match(/<g class="nm-place">/g) || []).length === 9 && !staticLocation.includes("data-endpoint=") && !staticLocation.includes("<noscript><p class=\"lp-tag\">Open the map above"), "Cached places render the map and list as static markup with no further request");
check((staticLocation.match(/<li><a href="https:\/\/www\.openstreetmap\.org\/node\/\d+" target="_blank" rel="noopener nofollow">/g) || []).length === 9 && staticLocation.includes("Harbor &lt;Grill&gt; &amp; &quot;Oyster&quot; House</a><span>Restaurant · approximately 0.3 mi away</span>") && !staticLocation.includes("Loading nearby places"), "Static list matches the scripted list shape and escapes names");
check(staticLocation.includes("© OpenStreetMap contributors") && staticLocation.includes("maps/search/?api=1&amp;query=27.771234%2C-82.641234"), "Static map keeps the OSM attribution and the external map link");
for (const page of ["home", "gallery", "contact"]) check(!renderTourPage(fixture(), "", "", "", { page, nearby: nineResult }).includes('<g class="nm-place">'), `${page} never renders the neighbourhood map`);
for (const theme of ["basic", "signature-estate", "coastal-luxe"]) {
  const themed = renderTourPage({ ...fixture(), website_theme: theme }, "", "", "", { page: "location", nearby: nineResult });
  check((themed.match(/<g class="nm-place">/g) || []).length === 9 && !/style="/.test(themed.slice(themed.indexOf("property-nearby-map"), themed.indexOf("</figure>"))), `${theme}: map is themed through CSS, not inline styles`);
}
const nearbyScript = (await load("property-site")).NEARBY_PLACES_JS;
new vm.Script(nearbyScript); assertions++;
check(nearbyScript.includes("if (!panel || !panel.getAttribute('data-endpoint')) return;"), "Scripted lookup stands down when the server already rendered the places");
// The scripted path accepts only the server's exact static figure.
function runNearbyScript(payload) {
  const elements = { "property-nearby": { attrs: { "data-endpoint": "/f/x/nearby" }, isConnected: true, getAttribute(n) { return this.attrs[n]; } }, "property-nearby-status": { textContent: "" }, "property-nearby-list": { hidden: true, children: [], appendChild(c) { this.children.push(c); } }, "property-nearby-map": { hidden: true, innerHTML: "" } };
  const el = () => ({ children: [], appendChild(c) { this.children.push(c); } });
  const context = { document: { getElementById: id => elements[id], createElement: el }, AbortController: class { signal = { aborted: false }; abort() {} }, setTimeout: () => 0, clearTimeout() {}, addEventListener() {}, URL, Number, Array, Error, Math,
    fetch: async () => ({ ok: true, json: async () => payload }) };
  vm.runInNewContext(nearbyScript, context);
  return new Promise(resolve => setImmediate(() => setImmediate(() => resolve(elements))));
}
const accepted = await runNearbyScript({ status: "available", places: ninePlaces, map_html: mapHtml });
check(accepted["property-nearby-map"].hidden === false && accepted["property-nearby-map"].innerHTML === mapHtml && accepted["property-nearby-list"].children.length === 9, "Scripted path inserts the server-drawn map with the list");
for (const [why, bad] of [["script", mapHtml.replace("</svg>", "<script>1</script></svg>")], ["link", mapHtml.replace("</svg>", "<a href=\"https://evil.invalid\">x</a></svg>")], ["image", mapHtml.replace("</svg>", "<image href=\"https://evil.invalid/t.png\"/></svg>")], ["handler", mapHtml.replace("<circle class=\"nm-ring\"", "<circle onload=\"1\" class=\"nm-ring\"")], ["foreign", mapHtml.replace("</svg>", "<foreignObject></foreignObject></svg>")], ["prefix", "<div>" + mapHtml + "</div>"], ["type", 42], ["oversize", mapHtml.replace("</figure>", " ".repeat(40000) + "</figure>")]]) {
  const rejected = await runNearbyScript({ status: "available", places: ninePlaces, map_html: bad });
  check(rejected["property-nearby-map"].hidden === true && rejected["property-nearby-map"].innerHTML === "" && rejected["property-nearby-list"].children.length === 9, `Scripted path refuses a tampered drawing (${why}) and keeps the list`);
}
const contact = renderTourPage(fixture(), "", "", "", { page: "contact" });
check(contact.includes('id="leadform"') && contact.includes('name="showing_date"'), "Contact retains actual enquiry/showing fields");
check(contact.indexOf('id="endcard"') < contact.indexOf('id="disclosure"'), "Contact form comes before detailed disclosures");
for (const theme of ["basic", "signature-estate", "coastal-luxe"]) {
  for (const status of ["active", "sold", "archived"]) {
    const tour = fixture(); tour.website_theme = theme; tour.status = status;
    const rendered = renderTourPage(tour, "", "", "", { page: "contact" });
    const expected = status === "active" ? "Arrange a visit" : "Ask about similar homes";
    check(rendered.includes(`<h1>${expected}</h1>`), `${theme}/${status}: Contact page heading matches actual availability`);
    check(rendered.includes('id="leadform"'), `${theme}/${status}: Existing Contact enquiry remains available`);
    if (status !== "active") check(rendered.includes("This home has sold."), `${theme}/${status}: Sold form retains truthful similar-home context`);
    if (theme !== "basic") {
      const preview = renderTourPage(tour, "", "", "", { page: "contact", previewTheme: theme });
      check(preview.includes(`<h1>${expected}</h1>`) && !preview.includes('<form'), `${theme}/${status}: Preview heading matches without enabling enquiries`);
    }
  }
}
const unbranded = renderTourPage(fixture(), "", "", "", { page: "contact", unbranded: true });
check(unbrandedSelfCheck(unbranded, fixture()).length === 0 && !unbranded.includes('property-site'), "Unbranded stays MLS-safe and preserves its renderer");
const embedded = renderTourPage(fixture(), "", "", "", { page: "contact", embed: true });
check(embedded.includes('id="track"') && !embedded.includes('property-site'), "Existing embedded scroll experience remains unchanged");
check(propertyPage("invalid") === "home" && propertyPage("<script>") === "home", "Unknown page values resolve to Home");
const empty = fixture(); empty.gallery = []; empty.chapters = []; empty.floorplan_url = null;
check(renderTourPage(empty, "", "", "", { page: "gallery" }).includes("No property photos have been published yet."), "Empty Gallery tells the truth instead of template sample photos");
for (const path of ["/f/estate-demo/nearby", "/f/demo/nearby", "/f/%/nearby", "/f/synthetic-polish/nearby?embed=1"]) {
  const before = fetches.length, response = await get(path);
  check(response.status === 404 && fetches.length === before, `${path} cannot query a provider`);
}
let before = fetches.length;
check((await get("/f/synthetic-polish/nearby", "HEAD")).status === 405 && fetches.length === before, "HEAD has no nearby/provider side effect");
upstreamStatus = 404; before = fetches.length;
const missing = await get("/f/synthetic-polish/nearby");
check(missing.status === 404 && fetches.length === before + 1, "Revoked nearby request consults publication before any lookup");
upstreamStatus = 200; current = { ...fixture(), space_type: "venue" };
check((await get("/f/synthetic-polish/nearby")).status === 404, "Non-property tour cannot query nearby data");
current = fixture(); before = fetches.length;
const fallback = await get("/f/synthetic-polish/nearby?lat=0&lng=0&provider=https://wrong.invalid");
check(fallback.status === 200 && fallback.headers.get("cache-control") === "no-store", "Nearby JSON is uncached and optional");
const result = await fallback.json();
check(result.status === "unavailable" && result.places.length === 0 && fetches.length === before + 1, "Missing private cache fails gracefully, ignores client location/provider");
check(fetches.at(-1).url.endsWith("/tours/synthetic-polish/location"), "Nearby uses the fresh authorized location projection without fetching gallery/contact/media metadata");
locationOverride = { ...publicLocation(), slug: "another-property" };
check((await get("/f/synthetic-polish/nearby")).status === 404, "Location projection for a different slug cannot authorize enrichment");
locationOverride = { ...publicLocation(), listing: { lat: 27.771234, lng: -82.641234 } };
check((await get("/f/synthetic-polish/nearby")).status === 404, "Unrounded private coordinates cannot enter the public enrichment path");
locationOverride = { ...publicLocation(), published_at: null };
check((await get("/f/synthetic-polish/nearby")).status === 404, "Missing fresh publication evidence cannot authorize enrichment");
locationOverride = undefined;
// Warm private cache: the nearby endpoint returns the server-drawn map with
// the places, and the Location page itself renders both as static markup
// through a cache-only read (no lease, budget, provider call or write).
class WarmBucket {
  constructor() { this.objects = new Map(); this.puts = 0; this.gets = []; this.hang = false; }
  seed(key, value) { this.objects.set(key, JSON.stringify(value)); }
  async get(key) { this.gets.push(key); if (this.hang) return new Promise(() => {}); const text = this.objects.get(key); return text ? { etag: "e1", size: Buffer.byteLength(text), body: new Response(text).body, text: async () => text } : null; }
  async put() { this.puts++; return { etag: "e2" }; }
}
const warm = new WarmBucket();
warm.seed("public-location-v1/pois/27.771,-82.641.json", { version: 1, provider: "https://overpass-api.de/api/interpreter", expires_at: Date.now() + 3_600_000, license: "https://www.openstreetmap.org/copyright", result: { ...nineResult, fetched_at: "2026-10-13T12:00:00.000Z" } });
const warmEnv = { ...env, MEDIA_RENDERS: warm };
const getWarm = (path) => worker.fetch(new Request("https://rendprop.com" + path), warmEnv, ctx);
before = fetches.length;
const warmJson = await (await getWarm("/f/synthetic-polish/nearby")).json();
check(warmJson.status === "available" && warmJson.places.length === 9 && warmJson.map_html === mapHtml && warmJson.license_url === "https://www.openstreetmap.org/copyright", "Nearby endpoint ships the identical server-drawn map with cached places");
check(fetches.length === before + 1 && warm.puts === 0, "Cached nearby reply makes no provider call or write");
before = fetches.length; warm.gets.length = 0;
const warmPage = await getWarm("/f/synthetic-polish?page=location");
const warmHtml = await warmPage.text();
check(warmPage.status === 200 && warmPage.headers.get("cache-control") === "no-store" && warmHtml.includes(mapHtml) && (warmHtml.match(/<li><a href="https:\/\/www\.openstreetmap\.org\/node\/\d+"/g) || []).length === 9 && !warmHtml.includes("data-endpoint="), "Location page renders cached places as static map and list, with no scripted request left");
check(fetches.length === before + 1 && fetches.at(-1).url.endsWith("/tours/synthetic-polish") && warm.puts === 0 && JSON.stringify(warm.gets) === JSON.stringify(["public-location-v1/pois/27.771,-82.641.json"]), "Static render reads only the one coarsened cache cell: no location projection, provider, lease or budget write");
for (const path of ["/f/synthetic-polish", "/f/synthetic-polish?page=gallery", "/f/synthetic-polish?page=contact", "/u/synthetic-polish", "/f/synthetic-polish?embed=1"]) {
  warm.gets.length = 0;
  const other = await (await getWarm(path)).text();
  check(warm.gets.length === 0 && !other.includes('<g class="nm-place">'), `${path} never reads or renders nearby places`);
}
const expired = new WarmBucket(); expired.seed("public-location-v1/pois/27.771,-82.641.json", { version: 1, provider: "https://overpass-api.de/api/interpreter", expires_at: Date.now() - 1, license: "https://www.openstreetmap.org/copyright", result: nineResult });
const expiredHtml = await (await worker.fetch(new Request("https://rendprop.com/f/synthetic-polish?page=location"), { ...env, MEDIA_RENDERS: expired }, ctx)).text();
check(!expiredHtml.includes('<g class="nm-place">') && expiredHtml.includes('data-endpoint="/f/synthetic-polish/nearby"') && expired.puts === 0, "An expired cache entry is not rendered and leaves the scripted lookup in place");
warm.hang = true;
const hungStart = Date.now();
const hungHtml = await (await getWarm("/f/synthetic-polish?page=location")).text();
check(Date.now() - hungStart < 2_500 && hungHtml.includes('data-endpoint="/f/synthetic-polish/nearby"') && !hungHtml.includes('<g class="nm-place">'), "Unresponsive storage cannot delay the Location page beyond the bounded peek; the scripted path remains");
warm.hang = false;
for (const page of ["home", "gallery", "location", "contact"]) {
  const path = "/f/estate-demo" + (page === "home" ? "" : "?page=" + page);
  const first = await get(path), second = await get(path);
  const body = await first.text();
  check(body.includes(`property-page-${page}`) && body === await second.text(), `Synthetic ${page} uses its own correct cache key`);
  check(!body.includes('id="property-nearby"'), `Synthetic ${page} never asks for real nearby places`);
}
console.log(`Property site: ${assertions} assertions passed; actual renderer/Worker routes, no real network.`);
