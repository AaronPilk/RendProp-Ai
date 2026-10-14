#!/usr/bin/env node
// Actual AASA response and ordered route rules. All network boundaries refuse.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { buildSrc, ROOT } from "./build-src.mjs";

globalThis.fetch = async () => { throw Error("No network is permitted in the public-link gate"); };
const load = buildSrc("public-links-check");
const worker = (await load("index")).default;
const env = { SUPABASE_FUNCTIONS_URL: "https://offline.invalid/functions/v1", SUPABASE_ANON_KEY: "offline-fixture" };
const ctx = { waitUntil() { throw Error("AASA must not start background work"); } };
const checks = [];
function accepted(document, path) {
  const detail = document.applinks.details[0];
  for (const entry of detail.components) {
    const pattern = entry["/"].replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\\\*/g, ".*");
    if (new RegExp("^" + pattern + "$", "u").test(path)) return entry.exclude !== true;
  }
  return false;
}
async function inspect(target, record = false) {
  let count = 0;
  const assert = (ok, message) => { count++; if (!ok) throw Error(message); };
  const entitlement = readFileSync(join(ROOT, "../../../apps/ios/Rendprop/Rendprop.entitlements"), "utf8");
  for (const host of ["rendprop.com", "www.rendprop.com"]) {
    assert(entitlement.includes("applinks:" + host), "AASA host must match existing signed entitlement");
    for (const path of ["/.well-known/apple-app-site-association", "/apple-app-site-association"]) {
      const get = await target.fetch(new Request("https://" + host + path), env, ctx);
      assert(get.status === 200 && !get.headers.has("location"), "AASA must not redirect on either host");
      assert(get.headers.get("content-type") === "application/json", "AASA must remain JSON");
      const document = await get.json();
      assert(JSON.stringify(document.applinks.details[0].appIDs) === JSON.stringify(["5F5C5G25Y6.com.rendprop.app"]), "Existing app identity is retained");
      for (const publicPath of ["/f/demo", "/f/fixture/gallery", "/u/demo", "/a/fixture-agent"]) {
        assert(!accepted(document, publicPath), "Buyer/public page must remain in browser: " + publicPath);
      }
      assert(accepted(document, "/join/ABCD-EFGH-IJKL"), "Existing team invite must open Join");
      for (const other of ["/terms", "/privacy", "/private-media/x", "/auth/callback", "/property/fixture"]) {
        assert(!accepted(document, other), "No new broad app claim: " + other);
      }
      const head = await target.fetch(new Request("https://" + host + path, { method: "HEAD" }), env, ctx);
      assert(head.status === 200 && !head.headers.has("location") && (await head.text()) === "", "HEAD AASA preserves headers without body");
      if (record) checks.push({ host, path, status: get.status, components: document.applinks.details[0].components });
    }
  }
  return count;
}
const count = await inspect(worker, true);
const { buildDemoTour } = await load("demo");
const existing = { ...buildDemoTour(), slug: "closed-published", share_url: "https://rendprop.com/f/closed-published", published_at: "2026-10-14T00:00:00Z" };
let published = true, reads = 0;
globalThis.fetch = async (url, init) => {
  if (url !== env.SUPABASE_FUNCTIONS_URL + "/tours/closed-published" || init.cache !== "no-store") throw Error("Unexpected alias upstream");
  reads++;
  return new Response(published ? JSON.stringify(existing) : "not published", { status: published ? 200 : 404 });
};
let aliasChecks = 0;
const aliasAssert = (ok, reason) => { aliasChecks++; if (!ok) throw Error(reason); };
for (const page of ["home", "gallery", "location", "contact"]) {
  const path = "/property/closed-published" + (page === "home" ? "" : "?page=" + page);
  const response = await worker.fetch(new Request("https://rendprop.com" + path), env, ctx);
  const html = await response.text();
  aliasAssert(response.status === 200 && !response.headers.has("location"), "Public alias must serve directly without /f redirect");
  aliasAssert(response.headers.get("cache-control") === "no-store", "Alias must check current publication");
  aliasAssert(html.includes("property-page-" + page), "Alias selects actual property page");
  for (const target of ["home", "gallery", "location", "contact"]) {
    const href = "/property/closed-published" + (target === "home" ? "" : "?page=" + target);
    aliasAssert(html.includes('href="' + href + '"'), "Alias navigation must stay in the browser-only path");
  }
  aliasAssert(!html.includes('href="/f/closed-published'), "No internal navigation returns to cached app-only path");
  aliasAssert(html.includes("https://rendprop.com/f/closed-published"), "Canonical published identity remains /f");
  if (page === "contact") aliasAssert(html.includes('id="leadform"') && html.includes('closed-published'), "Alias retains actual listing enquiry form/token");
}
aliasAssert(reads === 4, "Every alias page performs one current published lookup");
published = false;
const revoked = await worker.fetch(new Request("https://rendprop.com/property/closed-published"), env, ctx);
aliasAssert(revoked.status === 404 && revoked.headers.get("cache-control") === "no-store", "Unpublishing revokes alias with the same server lookup");
// These are the actual pre-fix path rules read from origin and Apple's CDN.
const prior = { applinks: { details: [{ components: [{ "/": "/f/*" }, { "/": "/a/*" }, { "/": "/join/*" }, { "/": "/u/*", exclude: true }] }] } };
aliasAssert(accepted(prior, "/f/closed-published") && !accepted(prior, "/property/closed-published"), "Browser-only alias avoids verified old cached association");
// A compiled former rule must fail the same recipient routing test, not just
// a string check over the JSON source.
const built = join(ROOT, "node_modules/.cache/public-links-check/index.js");
const actual = readFileSync(built, "utf8");
const needle = '"/": "/f/*", exclude: true';
if (actual.split(needle).length !== 2) throw Error("Compiled public AASA control anchor changed");
const mutant = join(ROOT, "node_modules/.cache/public-links-check/index-public-mutant.js");
writeFileSync(mutant, actual.replace(needle, '"/": "/f/*", exclude: false'));
let refused = false;
try { await inspect((await import(pathToFileURL(mutant).href)).default); }
catch (error) { refused = String(error).includes("Buyer/public page must remain in browser"); }
if (!refused) throw Error("Former buyer link interception was not caught by actual response checks");
console.log(`Public website AASA passed: ${count} checks + ${aliasChecks} direct-alias checks; former /f/ interception rejected`);
