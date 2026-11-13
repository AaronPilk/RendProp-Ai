#!/usr/bin/env node
// check-web-analytics.mjs — Cloudflare Web Analytics on the marketing pages only.
//
// The beacon goes on Rendprop's own static pages (public/: home, features,
// pricing, compare, support, the product pages and the generated blog). It must
// never reach a customer page: published property websites, the unbranded MLS
// twin, portfolios, the spatial viewer, legal pages or anything else the Worker
// renders. Those pages carry an agent's name, phone and the property address.
//
// The static CSP lives in public/_headers and is checked here as one exact
// string, so adding the two Cloudflare hosts cannot quietly loosen anything
// else. Worker-rendered pages keep their own policy, which must not mention the
// beacon hosts at all.
//
// Run: npm test

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { buildSrc, ROOT } from "./build-src.mjs";

const SNIPPET = `<!-- Cloudflare Web Analytics --><script type='module' src='https://static.cloudflareinsights.com/beacon.min.js' data-cf-beacon='{"token": "aee78d818cb24eebace4f3e851895a0e"}'></script><!-- End Cloudflare Web Analytics -->`;
const STATIC_CSP = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'sha256-dPD1Mxbpi+mEqJFUoL8CYPB/4K/8CY+lO1ciNefrhno=' https://static.cloudflareinsights.com; connect-src 'self' https://cloudflareinsights.com; font-src 'self' data:; base-uri 'self'; form-action 'self' mailto:; frame-ancestors 'none'; object-src 'none'";

const failures = [];
let checks = 0;
const expect = (cond, msg) => { checks++; if (!cond) failures.push(msg); };

// ---- static marketing pages ----------------------------------------------
const PUBLIC = join(ROOT, "public");
function htmlFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return htmlFiles(full);
    return name.endsWith(".html") ? [full] : [];
  });
}
const pages = htmlFiles(PUBLIC);
const rel = (f) => relative(PUBLIC, f);
expect(pages.length >= 450, `want the marketing pages and the generated blog (450+ HTML files), found ${pages.length}`);
for (const must of ["index.html", "features.html", "pricing.html", "compare.html", "support.html", "blog.html"]) {
  expect(pages.some((f) => rel(f) === must), `public/${must} is missing`);
}
for (const file of pages) {
  const html = readFileSync(file, "utf8");
  expect(html.split(SNIPPET).length === 2, `public/${rel(file)} must carry the Cloudflare Web Analytics snippet exactly once`);
  expect(html.indexOf(SNIPPET) < html.indexOf("</head>"), `public/${rel(file)} loads the beacon in <head>`);
}

// public/_headers: the /* block's CSP is exactly the expected policy.
const headers = readFileSync(join(PUBLIC, "_headers"), "utf8");
const cspLines = [...headers.matchAll(/^\s+Content-Security-Policy:\s*(.+)$/gm)].map((m) => m[1].trim());
expect(cspLines.length === 1, `public/_headers should set one Content-Security-Policy, found ${cspLines.length}`);
expect(cspLines[0] === STATIC_CSP, `public/_headers CSP changed beyond the two Cloudflare Web Analytics hosts:\n    ${cspLines[0]}`);

// No Worker-rendered template may carry the beacon.
for (const file of readdirSync(join(ROOT, "src")).filter((f) => f.endsWith(".ts"))) {
  const source = readFileSync(join(ROOT, "src", file), "utf8");
  expect(!source.includes("cloudflareinsights"), `src/${file} mentions cloudflareinsights; the beacon belongs in public/ only`);
}

// ---- Worker-rendered customer and legal pages ----------------------------
globalThis.caches = { default: { async match() { return undefined; }, async put() {} } };
const load = buildSrc("web-analytics-check");
const worker = (await load("index")).default;
const { buildDemoTour } = await load("demo");
const ENV = { SUPABASE_FUNCTIONS_URL: "https://offline.invalid/functions/v1", SUPABASE_ANON_KEY: "offline-fixture" };
const ctx = { waitUntil() {}, passThroughOnException() {} };

// One synthetic "customer" publication, served through the real tour route.
const customer = { ...buildDemoTour(), slug: "analytics-fixture", share_url: "https://rendprop.com/f/analytics-fixture", published_at: "2026-11-01T00:00:00Z" };
globalThis.fetch = async (url) => {
  if (String(url) === ENV.SUPABASE_FUNCTIONS_URL + "/tours/analytics-fixture") {
    return new Response(JSON.stringify(customer), { status: 200, headers: { "Content-Type": "application/json" } });
  }
  return new Response("not found", { status: 404 });
};

const routes = [
  ["/f/estate-demo", true],
  ["/f/estate-demo?embed=1", true],
  ["/u/demo", true],
  ["/a/meridian", true],
  ["/f/analytics-fixture", true],
  ["/u/analytics-fixture", true],
  ["/property/analytics-fixture", true],
  ["/property/analytics-fixture?page=contact", true],
  ["/terms", true],
  ["/privacy", true],
  ["/s/00000000-0000-4000-8000-000000000000", false],
  ["/join/ABCD-EFGH-IJKL", false],
  ["/f/not-a-published-slug", false],
  ["/", true], // Worker fallback when the static homepage is unavailable
];
for (const [path, want200] of routes) {
  const res = await worker.fetch(new Request("https://rendprop.com" + path), ENV, ctx);
  const body = await res.text();
  if (want200) expect(res.status === 200, `[${path}] want 200 so the check sees the real page, got ${res.status}`);
  expect(!body.includes("cloudflareinsights"), `[${path}] Worker-rendered page must not load Cloudflare Web Analytics`);
  expect(!(res.headers.get("content-security-policy") || "").includes("cloudflareinsights"),
    `[${path}] Worker-rendered CSP must not allow the analytics hosts`);
}

if (failures.length) {
  console.error(`✖ web analytics check FAILED (${failures.length} of ${checks}):\n` + failures.map((f) => "  - " + f).join("\n"));
  process.exit(1);
}
console.log(`✔ web analytics check passed — ${checks} assertions (beacon once in each of ${pages.length} static pages, exact static CSP, none on ${routes.length} Worker-rendered customer/legal routes).`);
