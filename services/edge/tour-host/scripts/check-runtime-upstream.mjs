#!/usr/bin/env node
// The actual Workers runtime (workerd, through wrangler's local dev API) making
// an actual subrequest to a loopback upstream. Every other check in this
// directory replaces globalThis.fetch with a stub, so none of them can see a
// fetch option combination the runtime itself refuses. On 2026-10-11 every
// published tour answered 503 for that exact reason: `cache: "no-store"` had
// been paired with `cf: { cacheTtl: 0 }`, workerd threw
// `TypeError: CacheTtl: 0, is not compatible with cache: no-store header`
// inside fetchUpstreamJSON, the error was swallowed as "upstream unavailable",
// and no request ever reached Supabase. This check fails if the Worker cannot
// complete a subrequest end to end, or if the upstream does not see exactly the
// request the Worker is supposed to send.
//
// No credentials, no network beyond 127.0.0.1, no production hosts.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_startWorker } from "wrangler";

const ROOT = resolve(fileURLToPath(import.meta.url), "../..");
const SLUG = "runtime-check-slug";

const tour = {
  slug: SLUG,
  share_url: "https://rendprop.com/f/" + SLUG,
  unbranded_url: "https://rendprop.com/u/" + SLUG,
  space_type: "real_estate",
  status: "ready",
  sold_at: null,
  sold: false,
  archived: false,
  listing: { address: "1 Runtime Check Way", tagline: null, details: {}, beds: 3, baths: 2, sqft: 1500, price_cents: null, price: null, lat: null, lng: null, status: "ready", sold_at: null },
  video_url: "https://media.invalid/runtime-check.mp4",
  scrub_url: "https://media.invalid/runtime-check.mp4",
  hls_url: null,
  poster: "https://media.invalid/runtime-check.jpg",
  cover_url: null,
  duration_s: 12,
  speed_factor: 1,
  published_at: "2026-10-11T00:00:00.000Z",
  chapters: [{ label: "Entry", t_ms: 0, sort: 0 }],
  agent_card: { name: "Fixture Agent", email: "fixture-agent@example.invalid", phone: null, title: null, website: null, brokerage: null, avatar_url: null, handle: null },
  client_mode: false,
  hide_rendprop_branding: false,
  cta: { label: "Book a showing", mode: "lead_form", url: null, secondary: [], lead_fields: [] },
  floorplan_url: null,
  gallery: [],
  staged: false,
  staged_disclosure: null,
  disclosure_chip: null,
  altered_media: [],
};

const hits = [];
const upstream = createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    hits.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString() });
    const json = (status, body) => {
      res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      res.end(JSON.stringify(body));
    };
    if (req.url === "/tours/" + SLUG) return json(200, tour);
    if (req.url.startsWith("/tours/")) return json(404, { error: "Tour not found or not published" });
    if (req.url.startsWith("/portfolio/")) return json(404, { error: "No portfolio" });
    return json(500, { error: "unexpected path " + req.url });
  });
});
await new Promise((ready) => upstream.listen(0, "127.0.0.1", ready));
const base = `http://127.0.0.1:${upstream.address().port}`;

const worker = await unstable_startWorker({
  config: resolve(ROOT, "wrangler.toml"),
  // `origin` makes the Worker see https://rendprop.com (the configured route);
  // without it the local proxy presents http://rendprop.com and the canonical
  // https redirect loops.
  dev: { remote: false, server: { hostname: "127.0.0.1", port: 0 }, origin: { hostname: "rendprop.com", secure: true }, inspector: false, logLevel: "error", persist: false },
  bindings: {
    SUPABASE_FUNCTIONS_URL: { type: "plain_text", value: base },
    SUPABASE_ANON_KEY: { type: "plain_text", value: "runtime-check-anon-key" },
    SUPABASE_READ_REGION: { type: "plain_text", value: "us-west-2" },
    TURNSTILE_SITE_KEY: { type: "plain_text", value: "runtime-check-turnstile" },
    TOUR_CACHE_TTL: { type: "plain_text", value: "60" },
  },
});
let failed = false;
try {
  await worker.ready;
  const get = async (path) => {
    const response = await worker.fetch("https://rendprop.com" + path, { headers: { Accept: "text/html" } });
    return { status: response.status, text: await response.text(), cacheControl: response.headers.get("cache-control") };
  };

  // 1. A published tour renders through a real subrequest.
  const live = await get("/f/" + SLUG);
  assert.equal(live.status, 200, "published tour must render (got " + live.status + ")");
  assert.ok(live.text.includes("1 Runtime Check Way"), "rendered page carries the upstream listing");
  assert.equal(live.cacheControl, "no-store", "customer HTML is never cached");
  assert.equal(hits.length, 1, "exactly one upstream request for one page view");
  assert.equal(hits[0].method, "GET");
  assert.equal(hits[0].url, "/tours/" + SLUG, "exact upstream route");
  assert.equal(hits[0].headers.apikey, "runtime-check-anon-key", "apikey header reaches the upstream");
  assert.equal(hits[0].headers.accept, "application/json");
  assert.equal(hits[0].headers["x-region"], "us-west-2", "trusted DB region reaches the actual upstream");
  assert.equal(hits[0].headers["cache-control"], "no-cache", "cache:\"no-store\" is honoured by the runtime (it adds Cache-Control: no-cache)");

  // 2. A missing tour is a 404 from the upstream, not a swallowed runtime error.
  const missing = await get("/f/no-such-" + SLUG);
  assert.equal(missing.status, 404, "unknown slug must be 404, never 503 (got " + missing.status + ")");
  assert.ok(missing.text.includes("Tour not found"), "branded not-found page");
  assert.equal(hits.length, 2, "the 404 came from the upstream");

  // 3. Same path for the MLS-safe twin and for portfolios.
  const unbranded = await get("/u/" + SLUG);
  assert.equal(unbranded.status, 200, "unbranded tour renders (got " + unbranded.status + ")");
  const portfolio = await get("/a/no-such-handle");
  assert.equal(portfolio.status, 404, "unknown portfolio must be 404, never 503 (got " + portfolio.status + ")");
  assert.equal(hits.length, 4);

  // 4. Negative control: the runtime must still refuse the combination that
  // caused the incident, so this check keeps meaning something. Done inside
  // the Worker's own runtime through a throwaway module, not in Node.
  const probe = await unstable_startWorker({
    name: "rendprop-runtime-probe",
    entrypoint: resolve(ROOT, "scripts/runtime-probe-worker.mjs"),
    compatibilityDate: "2026-09-07",
    dev: { remote: false, server: { hostname: "127.0.0.1", port: 0 }, inspector: false, logLevel: "error", persist: false },
    bindings: { UPSTREAM: { type: "plain_text", value: base } },
  });
  try {
    await probe.ready;
    const combined = await (await probe.fetch("https://probe.invalid/combined")).json();
    assert.equal(combined.ok, false, "cache:no-store + cf.cacheTtl must still throw in the runtime");
    assert.match(String(combined.error), /not compatible with cache/i, "the incident error is the one being guarded");
    const alone = await (await probe.fetch("https://probe.invalid/alone")).json();
    assert.equal(alone.ok, true, "cache:no-store alone completes a subrequest: " + JSON.stringify(alone));
  } finally {
    await probe.dispose();
  }
  console.log("check-runtime-upstream: real workerd subrequests reach the upstream (tour 200, unknown 404, unbranded 200, portfolio 404); incident combination still rejected by the runtime");
} catch (error) {
  failed = true;
  console.error("check-runtime-upstream FAILED:", error instanceof Error ? error.message : error);
} finally {
  await worker.dispose().catch(() => {});
  upstream.close();
}
process.exit(failed ? 1 : 0);
