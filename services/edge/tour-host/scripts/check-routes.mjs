#!/usr/bin/env node
// check-routes.mjs — the Worker's routing and failure surface.
//
// WHY THIS EXISTS
// `GET /f/%` used to take the Worker down with an uncaught URIError, so a
// mangled share link — a URL truncated by an SMS client, a copy/paste that
// clipped a percent-escape — served Cloudflare's raw "Worker threw exception"
// page instead of the tour (audit F-H-11). That is a customer's tour link
// failing, in public, from an input anyone can type. This file locks the fix:
//
//   • every malformed path answers with a branded 4xx, never a 500,
//   • an exception ANYWHERE in the handler is caught and answered with the
//     branded error page — and on /u/ with the UNBRANDED one, because an MLS
//     unbranded field must not receive Rendprop chrome even on a bad day,
//   • no response ever leaks a stack trace,
//   • the ordinary routes still answer as documented.
//
// The Worker is imported for real; Cache API, ExecutionContext and all upstream
// fetches are stubbed. No request in this gate leaves the process.
//
// Run: npm test

import { buildSrc } from "./build-src.mjs";

const load = buildSrc("routes-check");

const ENV = {
  SUPABASE_FUNCTIONS_URL: "https://example.supabase.co/functions/v1",
  SUPABASE_ANON_KEY: "anon",
  TOUR_CACHE_TTL: "60",
};

const failures = [];
let checks = 0;
const fail = (m) => failures.push(m);
const ok = (m) => { checks++; if (process.env.VERBOSE) console.log(`  ok  ${m}`); };

function expect(cond, msg) { checks++; if (!cond) fail(msg); else if (process.env.VERBOSE) console.log(`  ok  ${msg}`); }

/** A caches.default that never hits, and optionally throws (to exercise the
 *  Worker's own error boundary from inside the handler). */
function stubCaches({ throwOnMatch = false } = {}) {
  globalThis.caches = {
    default: {
      async match() { if (throwOnMatch) throw new Error("boom: simulated cache failure"); return undefined; },
      async put() {},
    },
  };
}

const ctx = { waitUntil() {}, passThroughOnException() {} };

// This is an offline gate. A forgotten upstream stub must fail, never contact
// even the example host (or a production hostname introduced by a regression).
globalThis.fetch = async () => { throw new Error("unexpected unstubbed network request"); };

async function get(worker, path, { method = "GET" } = {}) {
  const res = await worker.fetch(new Request(`https://rendprop.com${path}`, { method }), ENV, ctx);
  const body = await res.text();
  return { res, body, status: res.status, h: (n) => res.headers.get(n) };
}

/** WH-05: exercise the actual handler with old cached HTML still present. A
 * TTL/header-only repair fails these checks because cache.match returns it
 * before the current upstream publication state can be consulted. */
async function checkRevocation(worker, realTour) {
  function memoryCache() {
    const entries = new Map();
    const calls = { match: 0, put: 0 };
    const prime = (path, body) => entries.set(`https://rendprop.com${path}`, new Response(body, {
      headers: { "Content-Type": "text/html", "Cache-Control": "public, max-age=60, s-maxage=60" },
    }));
    globalThis.caches = { default: {
      async match(key) { calls.match++; return entries.get(key.url)?.clone(); },
      async put(key, response) { calls.put++; entries.set(key.url, response.clone()); },
    } };
    return { calls, prime };
  }

  const fixtures = [
    { path: "/f/private123", upstreamPath: "/tours/private123", data: { ...realTour, slug: "private123" } },
    { path: "/u/private123", upstreamPath: "/tours/private123", data: { ...realTour, slug: "private123" } },
    { path: "/a/private-agent", upstreamPath: "/portfolio/private-agent", data: {
      agent_card: { name: "Synthetic Review Agent", handle: "private-agent" },
      tours: [{ slug: "private123", address: "14 Sycamore Row", share_url: "https://rendprop.com/f/private123" }],
    } },
  ];
  for (const fixture of fixtures) {
    const cache = memoryCache();
    let upstreamStatus = 200;
    let upstreamData = fixture.data;
    let calls = 0;
    globalThis.fetch = async (url, init) => {
      calls++;
      expect(url === ENV.SUPABASE_FUNCTIONS_URL + fixture.upstreamPath,
        `[revocation ${fixture.path}] current upstream path`);
      expect(init.cf.cacheTtl === 0 && init.cf.cacheEverything === false,
        `[revocation ${fixture.path}] upstream caching remains disabled`);
      return new Response(upstreamStatus === 200 ? JSON.stringify(upstreamData) : "not published", {
        status: upstreamStatus, headers: { "Content-Type": "application/json" },
      });
    };
    const first = await get(worker, fixture.path);
    expect(first.status === 200 && first.body.includes("14 Sycamore Row"), `[${fixture.path}] current customer content renders`);
    expect(first.h("cache-control") === "no-store", `[${fixture.path}] successful customer HTML is no-store`);
    const second = await get(worker, fixture.path);
    expect(second.status === 200 && calls === 2, `[${fixture.path}] every new request checks publication`);
    expect(cache.calls.match === 0 && cache.calls.put === 0, `[${fixture.path}] no customer edge reads or writes`);
    if (fixture.path.startsWith("/a/")) {
      // Unpublishing one tour normally leaves the agent's portfolio available.
      // Its still-200 page must drop the revoked card, not keep a cached grid.
      upstreamData = { ...fixture.data, tours: [] };
      const updated = await get(worker, fixture.path);
      expect(updated.status === 200 && calls === 3, "[portfolio] live portfolio remains available after a tour is removed");
      expect(!updated.body.includes("14 Sycamore Row"), "[portfolio] removed tour card is absent from the current grid");
      expect(updated.h("cache-control") === "no-store", "[portfolio] updated grid remains no-store");
    }

    // Model HTML put by an older deployment; never clear/purge it to make the
    // test pass. Include each real canonical cache key and HEAD request path.
    cache.prime(fixture.path, first.body);
    cache.prime(`${fixture.path}?embed=1`, first.body);
    upstreamStatus = 404;
    for (const method of ["GET", "HEAD"]) {
      const paths = [fixture.path, `${fixture.path}/?utm_source=old-link`];
      if (!fixture.path.startsWith("/a/")) paths.push(`${fixture.path}?embed=1&space=venue`);
      for (const path of paths) {
        const before = calls;
        const revoked = await get(worker, path, { method });
        expect(revoked.status === 404, `[${method} ${path}] primed old HTML must not survive upstream revocation`);
        expect(calls === before + 1, `[${method} ${path}] authoritative route was consulted`);
        expect(revoked.h("cache-control") === "no-store", `[${method} ${path}] revoked response is no-store`);
        expect(!revoked.body.includes("14 Sycamore Row"), `[${method} ${path}] no cached customer address`);
        if (method === "GET") {
          if (fixture.path.startsWith("/u/")) assertUnbrandedBody(path, revoked.body);
          else expect(revoked.body.includes("RENDPROP"), `[${path}] existing branded unavailable page is retained`);
          assertNoStack(path, revoked.body);
        }
      }
    }
    expect(cache.calls.match === 0 && cache.calls.put === 0, `[${fixture.path}] old customer cache remains bypassed after revocation`);
  }

  // The explicit synthetic demos are not customer publication state. Preserve
  // their existing cache keys, embed variants, TTL, HEAD behavior and branding.
  globalThis.fetch = async () => { throw new Error("synthetic demos must not fetch upstream"); };
  for (const path of ["/f/estate-demo", "/u/demo", "/f/demo?embed=1", "/f/estate-demo?embed=1&space=venue"]) {
    const cache = memoryCache();
    const first = await get(worker, path);
    const second = await get(worker, path);
    const head = await get(worker, path, { method: "HEAD" });
    expect(first.status === 200 && second.status === 200 && head.status === 200, `[${path}] synthetic demo remains available`);
    expect(first.h("cache-control") === "public, max-age=60, s-maxage=60", `[${path}] synthetic demo retains TTL`);
    expect(first.body === second.body, `[${path}] cached synthetic response is byte-identical`);
    expect(cache.calls.match === 3 && cache.calls.put === 1, `[${path}] synthetic GET cached once; HEAD reuses it`);
  }
  for (const path of ["/a/meridian", "/a/demo"]) {
    const demo = await get(worker, path);
    expect(demo.status === 200 && demo.h("cache-control") === "public, max-age=300", `[${path}] fictional portfolio keeps its existing browser cache`);
  }
  stubCaches();
  ok("WH-05 customer HTML bypasses primed caches and follows revocation; synthetic demo caching is preserved");
}

/** A page that must be safe to hand to an MLS unbranded field. */
function assertUnbrandedBody(label, body) {
  for (const token of ["rendprop", "mailto:", "<form", "<input", "pilk.ai"]) {
    checks++;
    if (body.toLowerCase().includes(token)) fail(`[${label}] leaked ${JSON.stringify(token)} into an unbranded response`);
  }
}

/** No response may ever show a viewer our internals. */
function assertNoStack(label, body) {
  for (const token of ["at Object.", "at async ", ".ts:", "/src/", "URIError", "simulated cache failure", "Error:"]) {
    checks++;
    if (body.includes(token)) fail(`[${label}] leaked internals: found ${JSON.stringify(token)}`);
  }
}

async function main() {
  const worker = (await load("index")).default;

  // ---- F-H-11: malformed percent-escapes -------------------------------------
  // URL.pathname preserves these; decodeURIComponent throws on all of them.
  stubCaches();
  for (const bad of ["%", "%E0%A4%A", "%zz", "%FF%FE", "a%", "%C0%80"]) {
    const { status, body, h } = await get(worker, `/f/${bad}`);
    expect(status === 404, `[/f/${bad}] want 404, got ${status}`);
    expect((h("content-type") || "").includes("text/html"), `[/f/${bad}] want an HTML page, got ${h("content-type")}`);
    expect(body.includes("RENDPROP"), `[/f/${bad}] want the branded 404 page`);
    assertNoStack(`/f/${bad}`, body);

    const a = await get(worker, `/a/${bad}`);
    expect(a.status === 404, `[/a/${bad}] want 404, got ${a.status}`);
    assertNoStack(`/a/${bad}`, a.body);

    // The MLS twin must fail unbranded, not just fail.
    const u = await get(worker, `/u/${bad}`);
    expect(u.status === 404, `[/u/${bad}] want 404, got ${u.status}`);
    expect(u.h("x-robots-tag") === "noindex, nofollow", `[/u/${bad}] want X-Robots-Tag noindex, got ${u.h("x-robots-tag")}`);
    assertUnbrandedBody(`/u/${bad}`, u.body);
    assertNoStack(`/u/${bad}`, u.body);
  }
  ok("malformed percent-escapes 404 on /f/, /u/ and /a/");

  // A slug that decodes fine but is not slug-shaped is also a 404, not a fetch.
  for (const p of ["/f/../etc/passwd", "/f/" + "x".repeat(200), "/f/has%20space"]) {
    const { status } = await get(worker, p);
    expect(status === 404, `[${p}] want 404, got ${status}`);
  }

  // ---- the global error boundary ---------------------------------------------
  // Anything the handler throws must come back as OUR page, with no-store.
  // The Worker logs the exception on purpose; swallow that here so a passing
  // run is quiet and a real problem is the only thing on screen.
  stubCaches({ throwOnMatch: true });
  const realError = console.error;
  console.error = () => {};
  const br = await get(worker, "/f/estate-demo");
  expect(br.status === 500, `[boundary /f/] want 500, got ${br.status}`);
  expect(br.body.includes("RENDPROP"), "[boundary /f/] want the branded error page");
  expect((br.h("cache-control") || "").includes("no-store"), "[boundary /f/] a transient failure must not be cached");
  assertNoStack("boundary /f/", br.body);

  const un = await get(worker, "/u/estate-demo");
  expect(un.status === 500, `[boundary /u/] want 500, got ${un.status}`);
  expect(un.h("x-robots-tag") === "noindex, nofollow", "[boundary /u/] want X-Robots-Tag noindex");
  assertUnbrandedBody("boundary /u/", un.body);
  assertNoStack("boundary /u/", un.body);
  console.error = realError;
  ok("an exception in the handler is answered with a branded (and on /u/, unbranded) page");

  // ---- the ordinary routes still work ----------------------------------------
  stubCaches();
  const demo = await get(worker, "/f/estate-demo");
  expect(demo.status === 200, `[/f/estate-demo] want 200, got ${demo.status}`);
  expect(demo.h("strict-transport-security") === "max-age=31536000; includeSubDomains",
    `[/f/estate-demo] want HSTS on the first page a viewer ever opens, got ${demo.h("strict-transport-security")}`);
  expect(!demo.body.includes('name="robots"'), "[/f/estate-demo] the demo opts into indexing");

  const demoUn = await get(worker, "/u/estate-demo");
  expect(demoUn.status === 200, `[/u/estate-demo] want 200, got ${demoUn.status}`);
  assertUnbrandedBody("/u/estate-demo", demoUn.body);
  expect(demoUn.h("x-robots-tag") === "noindex, nofollow", "[/u/estate-demo] want X-Robots-Tag noindex");
  expect((demoUn.h("content-security-policy") || "").includes("frame-ancestors *"),
    "[/u/estate-demo] MLS systems iframe the unbranded tour — frame-ancestors must stay open");

  // ---- the in-app demo card for a venue / bar / store / gym ----------------
  // `?embed=1&space=<type>` presents the ONE launch demo (a house) as a
  // "Sample tour" instead of a $4.25M listing. Real estate and the full page
  // are untouched; an unknown type falls back to the plain embed.
  const embedRE = await get(worker, "/f/estate-demo?embed=1");
  expect(embedRE.status === 200, `[/f/estate-demo?embed=1] want 200, got ${embedRE.status}`);
  expect(embedRE.body.includes("5 bd · 6 ba · 6,200 sqft"), "[embed] the real-estate demo keeps its listing chip");
  expect(embedRE.body.includes("1180 Crestline Ridge") && embedRE.body.includes("$4,250,000") && !embedRE.body.includes("Sample tour"),
    "[embed] the real-estate demo is unchanged");
  for (const space of ["venue", "restaurant", "retail", "fitness", "other"]) {
    const e = await get(worker, `/f/estate-demo?embed=1&space=${space}`);
    expect(e.status === 200, `[embed&space=${space}] want 200, got ${e.status}`);
    expect(!e.body.includes(" bd · ") && !e.body.includes("$4,250,000") && !e.body.includes("1180 Crestline"),
      `[embed&space=${space}] must not present the demo as a home listing`);
    expect(e.body.includes("Sample tour"), `[embed&space=${space}] the chip says "Sample tour"`);
    expect(!e.body.includes("Alexandra Reyes") && !e.body.includes("Meridian Estates"),
      `[embed&space=${space}] no real-estate agent card on a ${space}`);
    expect(e.body.includes("Chef's kitchen"), `[embed&space=${space}] the footage and its chapters are unchanged`);
  }
  const embedBad = await get(worker, "/f/estate-demo?embed=1&space=spaceship");
  expect(embedBad.status === 200 && embedBad.body.includes("5 bd · 6 ba · 6,200 sqft"),
    "[embed&space=unknown] falls back to the plain real-estate embed");
  const fullVenue = await get(worker, "/f/estate-demo?space=venue");
  expect(fullVenue.body.includes("5 bd · 6 ba · 6,200 sqft"), "[/f/estate-demo?space=venue] the full page ignores the param");
  ok("the in-app demo card presents itself as a sample tour for non-real-estate types");

  // ---- the upstream path: a real (non-demo) slug --------------------------
  // GET /tours/:slug is stubbed so this exercises handleTour end to end without
  // a network call: the happy path, the indexing header, and the three ways
  // upstream can fail.
  const realTour = {
    slug: "abc123", space_type: "real_estate",
    listing: { address: "14 Sycamore Row", tagline: null, details: {}, beds: 3, baths: 2, sqft: 1800,
               price_cents: 42500000, price: "$425,000", lat: null, lng: null },
    video_url: "https://cdn.example.com/t.mp4", scrub_url: "https://cdn.example.com/t.mp4", hls_url: null,
    poster: null, duration_s: 90, speed_factor: 1, chapters: [],
    agent_card: { name: "Dana Whitfield", brokerage: "Northline Realty", phone: "(704) 555-0134" },
    cta: { label: "Book a showing", mode: "lead_form", url: null, secondary: [], lead_fields: [] },
    staged: false, staged_disclosure: null, disclosure_chip: null,
  };
  await checkRevocation(worker, realTour);
  let upstream = { status: 200, body: () => JSON.stringify(realTour) };
  globalThis.fetch = async () => new Response(upstream.status === 200 ? upstream.body() : "nope", {
    status: upstream.status,
    headers: { "Content-Type": "application/json" },
  });

  const live = await get(worker, "/f/abc123");
  expect(live.status === 200, `[/f/abc123] want 200, got ${live.status}`);
  expect(live.body.includes("14 Sycamore Row"), "[/f/abc123] want the listing rendered");
  expect(live.h("x-robots-tag") === "noindex, nofollow",
    `[/f/abc123] a customer tour is noindex until its owner opts in, got ${live.h("x-robots-tag")}`);
  expect(live.body.includes('<meta name="robots" content="noindex, nofollow">'),
    "[/f/abc123] want the robots meta tag as well as the header");

  upstream = { status: 200, body: () => JSON.stringify({ ...realTour, agent_card: { ...realTour.agent_card, allow_indexing: true } }) };
  const liveOptIn = await get(worker, "/f/abc124");
  expect(!liveOptIn.h("x-robots-tag"), `[/f/abc124] an opted-in tour must have no X-Robots-Tag, got ${liveOptIn.h("x-robots-tag")}`);
  expect(!liveOptIn.body.includes('name="robots"'), "[/f/abc124] an opted-in tour must have no robots meta");

  // The MLS twin of the SAME opted-in tour stays noindex, both ways.
  const liveOptInUn = await get(worker, "/u/abc125");
  expect(liveOptInUn.h("x-robots-tag") === "noindex, nofollow", "[/u/abc125] the MLS page is never indexable");
  assertUnbrandedBody("/u/abc125", liveOptInUn.body);

  upstream = { status: 404, body: () => "" };
  const gone = await get(worker, "/f/abc126");
  expect(gone.status === 404, `[upstream 404] want 404, got ${gone.status}`);
  expect(gone.body.includes("This tour isn&#39;t available"), "[upstream 404] want the branded tour-404 copy");

  upstream = { status: 500, body: () => "" };
  const broke = await get(worker, "/f/abc127");
  expect(broke.status === 503, `[upstream 500] want 503, got ${broke.status}`);
  expect((broke.h("cache-control") || "").includes("no-store"), "[upstream 500] must not be cached");
  assertNoStack("upstream 500", broke.body);

  upstream = { status: 200, body: () => "{not json" };
  const junk = await get(worker, "/f/abc128");
  expect(junk.status === 502, `[upstream junk] want 502, got ${junk.status}`);
  assertNoStack("upstream junk", junk.body);

  const netDown = await (async () => {
    globalThis.fetch = async () => { throw new Error("network is down"); };
    return get(worker, "/f/abc129");
  })();
  expect(netDown.status === 503, `[upstream unreachable] want 503, got ${netDown.status}`);
  assertNoStack("upstream unreachable", netDown.body);
  ok("the upstream path: happy render, indexing opt-in, 404, 5xx, junk body, unreachable");

  const health = await get(worker, "/healthz");
  expect(health.status === 200 && health.body === "ok", "[/healthz] want 200 ok");

  for (const [path, needle] of [["/terms", "Terms of Service"], ["/privacy", "Privacy Policy"]]) {
    const r = await get(worker, path);
    expect(r.status === 200 && r.body.includes(needle), `[${path}] want the ${needle} page`);
  }

  const unknown = await get(worker, "/definitely-not-a-page");
  expect(unknown.status === 404, `[/definitely-not-a-page] want 404, got ${unknown.status}`);
  expect(unknown.body.includes("There&#39;s nothing at this address"),
    "[/definitely-not-a-page] an unknown path must not claim a tour is missing");

  const post = await get(worker, "/f/estate-demo", { method: "POST" });
  expect(post.status === 405 && post.res.headers.get("Allow") === "GET, HEAD", "[POST /f/] want 405 + Allow");

  const head = await get(worker, "/f/estate-demo", { method: "HEAD" });
  expect(head.status === 200, `[HEAD /f/estate-demo] want 200, got ${head.status}`);

  for (const bare of ["/f", "/u", "/a"]) {
    const r = await worker.fetch(new Request(`https://rendprop.com${bare}`), ENV, ctx);
    checks++;
    if (r.status !== 302) fail(`[${bare}] want a 302 to the marketing site, got ${r.status}`);
  }
  ok("ordinary routes answer as documented");

  // ---- canonical origin: https + apex ---------------------------------------
  // Live on 2026-09-05, http://rendprop.com/terms answered 200 over plain HTTP
  // and https://www.rendprop.com/ was a Cloudflare 525. The Worker's own paths
  // now 301 to https://rendprop.com; dev/preview hosts are left alone.
  for (const [from, to] of [
    ["http://rendprop.com/terms", "https://rendprop.com/terms"],
    ["http://rendprop.com/f/estate-demo?embed=1", "https://rendprop.com/f/estate-demo?embed=1"],
    ["https://www.rendprop.com/f/estate-demo", "https://rendprop.com/f/estate-demo"],
    ["http://www.rendprop.com/privacy", "https://rendprop.com/privacy"],
    ["https://WWW.Rendprop.com/u/estate-demo", "https://rendprop.com/u/estate-demo"],
  ]) {
    const r = await worker.fetch(new Request(from), ENV, ctx);
    expect(r.status === 301, `[${from}] want 301, got ${r.status}`);
    expect(r.headers.get("location") === to, `[${from}] want Location ${to}, got ${r.headers.get("location")}`);
    expect(!!r.headers.get("strict-transport-security"), `[${from}] the redirect itself should pin HSTS`);
  }
  for (const untouched of ["http://localhost:8787/terms", "http://127.0.0.1:8787/f/estate-demo", "https://rendprop-tour-host.example.workers.dev/terms"]) {
    const r = await worker.fetch(new Request(untouched), ENV, ctx);
    expect(r.status === 200, `[${untouched}] dev/preview hosts must not be redirected, got ${r.status}`);
  }
  ok("http:// and www. requests 301 to https://rendprop.com; dev hosts are untouched");

  // ---- branded pages carry the favicon; the unbranded one never does --------
  for (const [path, label] of [["/terms", "Terms"], ["/privacy", "Privacy"], ["/definitely-not-a-page", "404"], ["/f/estate-demo", "demo tour"]]) {
    const r = await get(worker, path);
    expect(r.body.includes('<link rel="icon" href="/favicon.svg"'), `[${label}] want the Rendprop favicon`);
  }
  for (const path of ["/terms", "/privacy"]) {
    const r = await get(worker, path);
    expect(r.body.includes(`<link rel="canonical" href="https://rendprop.com${path}">`), `[${path}] want a canonical link`);
    expect(r.body.includes('href="/support"'), `[${path}] want the Support link in the footer`);
  }
  const unbrandedDemo = await get(worker, "/u/estate-demo");
  expect(!unbrandedDemo.body.includes("favicon"), "[/u/estate-demo] the MLS page must not carry the Rendprop favicon");
  ok("favicon + canonical on branded pages only");

  // ---- the legal pages match the launch line-up ------------------------------
  const terms = await get(worker, "/terms");
  expect(/Starter and Pro, billed monthly\s+or yearly, and Team, billed monthly/.test(terms.body),
    "[/terms] §6 must say Starter and Pro bill monthly or yearly and Team bills monthly (LAUNCH-CONTRACT: Team yearly is not sold)");
  expect(!/each\s+billed monthly or yearly/.test(terms.body), "[/terms] must not claim every plan bills yearly");
  expect(terms.body.includes("Effective September 5, 2026"), "[/terms] effective date");
  ok("terms reflect the launch plan line-up");

  // ── safeUrl scheme allowlist (audit P1 re-open) ──────────────────────────
  // Browsers strip C0 control characters from a URL BEFORE resolving its
  // scheme, so a raw-string regex test let "java\nscript:" through and the
  // tour CSP allows unsafe-inline. Every publisher-supplied URL on a tour
  // page goes through safeUrl: cta.url, secondary[].url, floorplan_url,
  // reel_url and lender_url — the last of which is writable by any account
  // holder via PATCH /listings/:id, so this is a stored-XSS sink.
  {
    const { safeUrl } = await load("html");
    const C = (n) => String.fromCharCode(n);
    const evil = [
      "javascript:alert(1)",
      "java" + C(10) + "script:alert(1)",
      "java" + C(9) + "script:alert(1)",
      "JaVa" + C(13) + "SCRIPT:alert(1)",
      "java" + C(0) + "script:alert(1)",
      "  javascript:alert(1)",
      "data:text/html,<script>alert(1)</script>",
      "vbscript:msgbox(1)",
    ];
    for (const u of evil) {
      expect(safeUrl(u) === "",
        `[safeUrl] must reject ${JSON.stringify(u)} — got ${JSON.stringify(safeUrl(u))}`);
    }
    expect(safeUrl("https://example.com/x?a=1") === "https://example.com/x?a=1",
      "[safeUrl] must pass an ordinary https URL through unchanged");
    expect(safeUrl("/tours/abc") === "/tours/abc", "[safeUrl] must allow a relative path");
    expect(safeUrl("#gallery") === "#gallery", "[safeUrl] must allow an anchor");
    expect(safeUrl("tel:+15551234") === "", "[safeUrl] must reject tel: unless opted in");
    expect(safeUrl("tel:+15551234", ["tel"]) === "tel:+15551234",
      "[safeUrl] must allow tel: when the call site opts in");
    ok("safeUrl rejects control-character-obfuscated javascript: URLs");
  }

  if (failures.length) {
    console.error(`\n✖ route check FAILED — ${failures.length} problem(s) across ${checks} assertions:\n`);
    for (const f of failures) console.error("  - " + f);
    console.error("\n  A malformed URL must never take a customer's tour link down (F-H-11).\n");
    process.exitCode = 1;
    return;
  }
  console.log(`✔ route check passed — ${checks} assertions (malformed paths, error boundary, upstream failures, customer revocation/cache bypass, synthetic demo caching, indexing headers, ordinary routes, canonical origin, favicon/legal pages, safeUrl scheme allowlist).`);
}

main().catch((err) => {
  console.error("route check crashed:", err && err.stack ? err.stack : err);
  process.exitCode = 1;
});
