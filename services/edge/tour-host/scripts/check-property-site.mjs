// Actual Worker + rendered property pages. All upstream/storage/provider
// boundaries are closed synthetic fixtures; no account or network is used.
import assert from "node:assert/strict";
import vm from "node:vm";
import { buildSrc } from "./build-src.mjs";
const load = buildSrc("property-site-check");
const { renderTourPage, unbrandedSelfCheck } = await load("player");
const { buildDemoTour } = await load("demo");
const { default: worker } = await load("index");
const { propertyPage } = await load("property-site");
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
let current = fixture(), upstreamStatus = 200;
globalThis.fetch = async (url, init) => {
  fetches.push({ url, init });
  assert.equal(url, env.SUPABASE_FUNCTIONS_URL + "/tours/synthetic-polish", "No provider or arbitrary network call");
  assert.equal(init.cache, "no-store", "Publication read stays uncached");
  return new Response(upstreamStatus === 200 ? JSON.stringify(current) : "not published", { status: upstreamStatus });
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
const gallery = renderTourPage(fixture(), "", "", "", { page: "gallery" });
check(gallery.includes('data-property-photo href="/published-photo.jpg"'), "Gallery complete-photo anchor works without JS");
check(gallery.indexOf('id="gallery"') < gallery.indexOf('id="plan"'), "Dedicated Gallery leads with photos, ahead of floor plans");
check(!gallery.includes('id="endcard"') && !gallery.includes('class="listing-cover"'), "Gallery is its own page, not the Home content repeated");
const location = renderTourPage(fixture(), "", "", "", { page: "location" });
check(location.includes("maps/search/?api=1&amp;query=27.771234%2C-82.641234"), "Location map uses published coordinates");
check(location.includes("An owner-reviewed place note."), "Location keeps owner-reviewed context");
check(location.includes("not travel times") && location.includes("© OpenStreetMap contributors"), "Location declares distance limitations/map attribution");
check(location.includes('<noscript>') && location.includes('data-endpoint="/f/synthetic-polish/nearby"'), "Optional nearby data leaves a no-JS map fallback");
for (const page of ["home", "gallery", "contact"]) check(!renderTourPage(fixture(), "", "", "", { page }).includes('id="property-nearby"'), `${page} cannot initiate nearby requests`);
const contact = renderTourPage(fixture(), "", "", "", { page: "contact" });
check(contact.includes('id="leadform"') && contact.includes('name="showing_date"'), "Contact retains actual enquiry/showing fields");
check(contact.indexOf('id="endcard"') < contact.indexOf('id="disclosure"'), "Contact form comes before detailed disclosures");
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
for (const page of ["home", "gallery", "location", "contact"]) {
  const path = "/f/estate-demo" + (page === "home" ? "" : "?page=" + page);
  const first = await get(path), second = await get(path);
  const body = await first.text();
  check(body.includes(`property-page-${page}`) && body === await second.text(), `Synthetic ${page} uses its own correct cache key`);
  check(!body.includes('id="property-nearby"'), `Synthetic ${page} never asks for real nearby places`);
}
console.log(`Property site: ${assertions} assertions passed; actual renderer/Worker routes, no real network.`);
