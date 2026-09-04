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
// The Worker is imported for real; only the two runtime globals it touches
// (caches.default and ExecutionContext) are stubbed.
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

async function get(worker, path, { method = "GET" } = {}) {
  const res = await worker.fetch(new Request(`https://rendprop.com${path}`, { method }), ENV, ctx);
  const body = method === "HEAD" ? "" : await res.text();
  return { res, body, status: res.status, h: (n) => res.headers.get(n) };
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
  expect(broke.status === 502, `[upstream 500] want 502, got ${broke.status}`);
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
  expect(netDown.status === 502, `[upstream unreachable] want 502, got ${netDown.status}`);
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
  console.log(`✔ route check passed — ${checks} assertions (malformed paths, error boundary, upstream failures, indexing headers, ordinary routes, safeUrl scheme allowlist).`);
}

main().catch((err) => {
  console.error("route check crashed:", err && err.stack ? err.stack : err);
  process.exitCode = 1;
});
