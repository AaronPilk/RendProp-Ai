// tour-host — the Cloudflare Worker that serves Rendprop's public pages:
//
//   GET /f/:slug     the scroll-scrub tour player (renders GET /tours/:slug)
//   GET /u/:slug     the SAME tour, unbranded — safe for an MLS unbranded
//                    virtual-tour field: no agent card, no CTA, no lead form,
//                    no socials, no external links, no Rendprop wordmark.
//                    Same renderer, `unbranded: true` (see src/player.ts), and
//                    every response is self-checked before it leaves the edge.
//   GET /a/:handle   an org's portfolio grid  (renders GET /portfolio/:handle)
//   GET /terms       Terms of Service   (static; linked from the iOS app)
//   GET /privacy     Privacy Policy     (static; linked from the iOS app)
//
// The dynamic pages are server-rendered to a self-contained HTML page and cached at the edge
// (Cache API) with a short TTL. Video is served zero-egress: the all-intra R2
// mp4 (`scrub_url`, byte-range) is the primary scroll-scrub source, with
// Cloudflare Stream HLS (`hls_url`) as fallback only. The browser talks to
// Supabase directly for the lead form (POST /leads) and the view beacon
// (POST /beacon/:slug) — both deployed with --no-verify-jwt.
//
// Routing (wrangler.toml): the Worker owns the whole apex, `rendprop.com/*`.
// Requests that exactly match a file under ./public (the marketing site,
// /assets/*, robots.txt, sitemap.xml, llms.txt) are answered by Static Assets
// before this script runs; everything else lands in fetch() below.
//
// Every response is branded: malformed paths (`/f/%`) 404, and any exception
// the handler throws is caught and answered with errorPage() + no-store — a
// viewer must never see Cloudflare's raw "Worker threw exception" page.

import type { Env, Portfolio, Tour } from "./types";
import { buildDemoTour, isDemoSlug } from "./demo";
import { errorPage, notFoundPage, portfolioUnavailablePage } from "./html";
import { privacyPage, termsPage } from "./legal";
import { allowsIndexing, renderTourPage, unbrandedNoticePage, unbrandedSelfCheck } from "./player";
import { renderPortfolioPage } from "./portfolio";

const DEFAULT_TTL = 60; // seconds — published HTML can change on republish

function ttl(env: Env): number {
  const n = Number(env.TOUR_CACHE_TTL);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_TTL;
}

function functionsBase(env: Env): string {
  return String(env.SUPABASE_FUNCTIONS_URL || "").replace(/\/+$/, "");
}

function htmlResponse(
  html: string,
  status = 200,
  extraHeaders: Record<string, string> = {},
  opts: { unbranded?: boolean } = {},
): Response {
  // The unbranded page has no form, no Turnstile and no lead capture, so its
  // policy is strictly tighter — except frame-ancestors: MLS systems and
  // portals commonly iframe an unbranded virtual-tour URL, and the
  // clickjacking risk that motivated 'self' on /f/ (the lead form) does not
  // exist here. Blocking the frame would break the one job this page has.
  const csp = opts.unbranded
    ? [
        "default-src 'self'",
        "base-uri 'self'",
        "img-src 'self' https: data: blob:",
        "media-src 'self' https: data: blob:",
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com",
        "worker-src 'self' blob:",
        "child-src 'self' blob:",
        "frame-src 'none'",
        "connect-src 'self' https:",
        "font-src 'self' data:",
        "form-action 'none'",
        "frame-ancestors *",
      ]
    : [
        // CSP: inline styles/scripts (the player engine), hls.js from cdnjs, media
        // from Stream/R2 over https + MSE blobs, and XHR/fetch to Supabase.
        "default-src 'self'",
        "base-uri 'self'",
        "img-src 'self' https: data: blob:",
        "media-src 'self' https: data: blob:",
        "style-src 'self' 'unsafe-inline'",
        // cdnjs = hls.js fallback; challenges.cloudflare.com = Turnstile widget.
        "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://challenges.cloudflare.com",
        "worker-src 'self' blob:",
        // Turnstile renders its challenge in an iframe from challenges.cloudflare.com.
        "child-src 'self' blob: https://challenges.cloudflare.com",
        "frame-src 'self' https://challenges.cloudflare.com",
        "connect-src 'self' https:",
        "font-src 'self' data:",
        "form-action 'self' https:",
        // 'self' only (audit P2): tour pages carry the lead form — don't let
        // arbitrary https sites iframe them (clickjacking). The iOS demo card
        // loads pages top-level in a WKWebView, which frame-ancestors ignores.
        "frame-ancestors 'self'",
      ];
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      // Static assets pin HSTS via public/_headers, but a tour link is very
      // often the FIRST rendprop.com URL a viewer ever opens (audit F-H-21) —
      // without this, that first visit pins nothing. Same max-age as _headers;
      // no `preload` (that is a one-way commitment for the whole apex).
      "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
      "Content-Security-Policy": csp.join("; "),
      ...extraHeaders,
    },
  });
}

/** A5: `/u/` is never indexed — the branded `/f/` page is the canonical one. */
const UNBRANDED_HEADERS: Record<string, string> = { "X-Robots-Tag": "noindex, nofollow" };

/** 404 / 5xx on `/u/` must ALSO be unbranded: the ordinary fallback pages
 *  carry the RENDPROP mark and a rendprop.com button, which would be a
 *  violation if an MLS or a portal fetched a dead unbranded link. */
function unbrandedFallback(kind: "notfound" | "error" | "blocked"): string {
  if (kind === "notfound") {
    return unbrandedNoticePage(
      "This tour isn't available",
      "The link may have expired, been unpublished, or mistyped.",
    );
  }
  return unbrandedNoticePage(
    "This tour is temporarily unavailable",
    "Please try again in a few minutes.",
  );
}

/** Stable, query-independent cache key so /f/x and /f/x/ share one entry. */
function cacheKeyFor(url: URL, canonicalPath: string): Request {
  return new Request(`${url.origin}${canonicalPath}`, { method: "GET" });
}

/**
 * `URL.pathname` keeps malformed percent-escapes (`/f/%`, `/f/%E0%A4%A`), and
 * decodeURIComponent throws a URIError on them (audit F-H-11: the exception
 * escaped fetch() → unbranded HTTP 500). null → caller answers 404.
 */
function safeDecode(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/** Fetch JSON from a Supabase Edge Function with the anon key attached. */
async function fetchSupabase(path: string, env: Env): Promise<Response> {
  const key = env.SUPABASE_ANON_KEY || "";
  return fetch(`${functionsBase(env)}${path}`, {
    method: "GET",
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      Accept: "application/json",
    },
    // Don't let the runtime cache the upstream API response; we manage our own
    // edge cache on the rendered HTML.
    cf: { cacheTtl: 0, cacheEverything: false },
  });
}

async function handleTour(
  slug: string,
  req: Request,
  url: URL,
  env: Env,
  ctx: ExecutionContext,
  unbranded = false,
): Promise<Response> {
  const base = unbranded ? UNBRANDED_HEADERS : {};
  const notFound = () =>
    unbranded
      ? htmlResponse(unbrandedFallback("notfound"), 404, { ...base, "Cache-Control": "public, max-age=30" }, { unbranded })
      : htmlResponse(notFoundPage(), 404, { "Cache-Control": "public, max-age=30" });
  const upstreamError = () =>
    unbranded
      ? htmlResponse(unbrandedFallback("error"), 502, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(errorPage(), 502, { "Cache-Control": "no-store" });

  // Slugs are nanoid (base64url) — reject anything else fast.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) {
    return unbranded
      ? htmlResponse(unbrandedFallback("notfound"), 404, base, { unbranded })
      : htmlResponse(notFoundPage(), 404);
  }

  // ?embed=1 renders ONLY the flythrough hero (for the in-app "See it in
  // action" card); the full page is served otherwise. Keep separate cache keys.
  const embed = url.searchParams.has("embed");

  const cache = caches.default;
  const key = cacheKeyFor(url, `/${unbranded ? "u" : "f"}/${slug}${embed ? "?embed=1" : ""}`);
  const hit = await cache.match(key);
  if (hit) return req.method === "HEAD" ? new Response(null, hit) : hit;

  const renderOpts = { embed, unbranded, origin: url.origin };

  /** Render + (on `/u/`) refuse to serve anything that trips the self-check. */
  const finish = (tour: Tour): Response => {
    const t = ttl(env);
    const html = renderTourPage(
      tour,
      functionsBase(env),
      env.SUPABASE_ANON_KEY || "",
      env.TURNSTILE_SITE_KEY || "",
      renderOpts,
    );
    if (unbranded) {
      // Fail CLOSED. An MLS unbranded field must never receive a page with
      // agent branding, a contact form or an external link in it — a neutral
      // "temporarily unavailable" page is the safe failure, a leak is not.
      const violations = unbrandedSelfCheck(html, tour);
      if (violations.length) {
        console.error(`tour-host UNBRANDED SELF-CHECK FAILED slug=${slug} violations=${violations.join(",")}`);
        return htmlResponse(unbrandedFallback("blocked"), 503, { ...base, "Cache-Control": "no-store" }, { unbranded });
      }
    }
    // F-H-19: the page already carries a robots meta tag; send the header too,
    // so a crawler that never parses the body (and anything reading the cached
    // response) gets the same answer. `/u/` has its own noindex in `base`.
    const robots: Record<string, string> =
      unbranded || allowsIndexing(tour) ? {} : { "X-Robots-Tag": "noindex, nofollow" };
    const resp = htmlResponse(
      html,
      200,
      { ...base, ...robots, "Cache-Control": `public, max-age=${t}, s-maxage=${t}` },
      { unbranded },
    );
    if (req.method === "GET" && t > 0) ctx.waitUntil(cache.put(key, resp.clone()));
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  };

  // Demo tour — self-contained, no DB. Renders through the SAME renderer a real
  // listing uses, so rendprop.com/f/estate-demo IS the product (and powers the
  // in-app Home demo). /u/estate-demo is the MLS-safe cut of the same tour.
  if (isDemoSlug(slug)) return finish(buildDemoTour());

  let upstream: Response;
  try {
    upstream = await fetchSupabase(`/tours/${encodeURIComponent(slug)}`, env);
  } catch {
    return upstreamError();
  }

  if (upstream.status === 404) return notFound();
  if (!upstream.ok) return upstreamError();

  let tour: Tour;
  try {
    tour = (await upstream.json()) as Tour;
  } catch {
    return upstreamError();
  }
  if (!tour || !tour.slug) return notFound();

  return finish(tour);
}

async function handlePortfolio(handle: string, req: Request, url: URL, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (!/^[A-Za-z0-9_.-]{1,64}$/.test(handle)) return htmlResponse(portfolioUnavailablePage(handle), 404);

  const cache = caches.default;
  const key = cacheKeyFor(url, `/a/${handle}`);
  const hit = await cache.match(key);
  if (hit) return req.method === "HEAD" ? new Response(null, hit) : hit;

  // GET /portfolio/:handle is live (services/supabase/functions/portfolio) but
  // stay graceful: any non-2xx / network error / malformed body → branded 404.
  let data: Portfolio | null = null;
  try {
    const upstream = await fetchSupabase(`/portfolio/${encodeURIComponent(handle)}`, env);
    if (upstream.ok) {
      data = (await upstream.json()) as Portfolio;
    }
  } catch {
    data = null;
  }

  if (!data || !data.agent_card) {
    return htmlResponse(portfolioUnavailablePage(handle), 404, { "Cache-Control": "public, max-age=30" });
  }

  const t = ttl(env);
  const html = renderPortfolioPage(data);
  const resp = htmlResponse(html, 200, {
    "Cache-Control": `public, max-age=${t}, s-maxage=${t}`,
  });
  if (req.method === "GET" && t > 0) ctx.waitUntil(cache.put(key, resp.clone()));
  return req.method === "HEAD" ? new Response(null, resp) : resp;
}

async function route(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }

  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  const fMatch = path.match(/^\/f\/([^/]+)$/);
  if (fMatch) {
    const slug = safeDecode(fMatch[1]);
    if (slug === null) return htmlResponse(notFoundPage(), 404, { "Cache-Control": "public, max-age=30" });
    return handleTour(slug, req, url, env, ctx);
  }

  // The MLS-safe twin of /f/. Same slug, same payload, same renderer.
  const uMatch = path.match(/^\/u\/([^/]+)$/);
  if (uMatch) {
    const slug = safeDecode(uMatch[1]);
    if (slug === null) {
      return htmlResponse(
        unbrandedFallback("notfound"),
        404,
        { ...UNBRANDED_HEADERS, "Cache-Control": "public, max-age=30" },
        { unbranded: true },
      );
    }
    return handleTour(slug, req, url, env, ctx, true);
  }

  const aMatch = path.match(/^\/a\/([^/]+)$/);
  if (aMatch) {
    const handle = safeDecode(aMatch[1]);
    if (handle === null) return htmlResponse(portfolioUnavailablePage("?"), 404, { "Cache-Control": "public, max-age=30" });
    return handlePortfolio(handle, req, url, env, ctx);
  }

  // Legal pages — static HTML, cacheable for an hour.
  if (path === "/terms" || path === "/privacy") {
    const resp = htmlResponse(path === "/terms" ? termsPage() : privacyPage(), 200, {
      "Cache-Control": "public, max-age=3600",
    });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  if (path === "/healthz") return new Response("ok", { status: 200, headers: { "Content-Type": "text/plain" } });

  // Bare /f, /u and /a aren't tours — send them to the marketing site.
  if (path === "/f" || path === "/u" || path === "/a") {
    return Response.redirect(`${url.origin}/`, 302);
  }

  // Root: normally served by the static assets (public/index.html) before the
  // Worker ever runs. This branch is a safety net in case assets are missing.
  if (path === "/") {
    const resp = htmlResponse(landingPage(), 200, {
      "Cache-Control": "public, max-age=300",
    });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  return htmlResponse(notFoundPage("page"), 404);
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await route(req, env, ctx);
    } catch (err) {
      // Last line of defence: never let an exception escape as an unbranded
      // Cloudflare error page. no-store so a transient bug isn't cached.
      console.error("tour-host unhandled error", err instanceof Error ? err.stack || err.message : String(err));
      let kind: "tour" | "page" = "page";
      let unbranded = false;
      try {
        const p = new URL(req.url).pathname;
        kind = /^\/f\//.test(p) ? "tour" : "page";
        // A crash on /u/ must not answer with the branded error page.
        unbranded = /^\/u\//.test(p);
      } catch { /* keep "page" */ }
      const resp = unbranded
        ? htmlResponse(unbrandedFallback("error"), 500, { ...UNBRANDED_HEADERS, "Cache-Control": "no-store" }, { unbranded: true })
        : htmlResponse(errorPage(kind), 500, { "Cache-Control": "no-store" });
      return req.method === "HEAD" ? new Response(null, resp) : resp;
    }
  },
} satisfies ExportedHandler<Env>;

/** Minimal branded landing for the apex domain until the marketing site ships. */
function landingPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Rendprop — drone-style tours from a phone walkthrough</title>
<meta name="description" content="Film a walkthrough on your phone. Rendprop turns it into a smooth, drone-style tour buyers scroll through — with AI photos, reels, and floor plans.">
<meta name="theme-color" content="#0e0d14">
<style>
  :root { --accent:#7c3aed; --accent2:#9b6dff; --bg:#faf9fc; --ink:#1c192d; --dim:rgba(28,25,45,.6); --card:#fff; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0e0d14; --ink:#f2f0fa; --dim:rgba(242,240,250,.6); --card:#1a1825; --accent:#9b6dff; }
  }
  * { margin:0; box-sizing:border-box; }
  body { font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         background:var(--bg); color:var(--ink); min-height:100svh;
         display:flex; flex-direction:column; align-items:center; justify-content:center;
         text-align:center; padding:32px 20px; }
  .mark { font-weight:800; letter-spacing:.28em; font-size:13px; color:var(--accent); margin-bottom:28px; }
  h1 { font-size:clamp(30px,6vw,52px); line-height:1.12; font-weight:800; max-width:16em;
       background:linear-gradient(120deg, var(--accent), var(--accent2)); -webkit-background-clip:text;
       background-clip:text; -webkit-text-fill-color:transparent; }
  p.sub { max-width:34em; color:var(--dim); margin:18px auto 30px; font-size:clamp(15px,2.4vw,18px); }
  .pill { display:inline-block; padding:12px 22px; border-radius:999px; font-weight:700;
          background:var(--accent); color:#fff; text-decoration:none; }
  .soon { display:inline-block; margin-left:10px; padding:12px 18px; border-radius:999px;
          font-weight:600; color:var(--accent); background:color-mix(in srgb, var(--accent) 12%, transparent);
          text-decoration:none; }
  footer { margin-top:56px; font-size:13px; color:var(--dim); }
  footer a { color:var(--dim); text-decoration:none; margin:0 8px; }
  footer a:hover { color:var(--accent); }
</style>
</head>
<body>
  <div class="mark">RENDPROP</div>
  <h1>Film it on your phone.<br>Show it like a film.</h1>
  <p class="sub">A walkthrough video goes in. A smooth, drone-style tour comes out — with AI-enhanced
  photos, social reels, floor plans, and a link buyers scroll through like it's social.</p>
  <div>
    <a class="pill" href="mailto:aaron@pilk.ai">Get early access</a>
    <span class="soon">iOS app — coming soon</span>
  </div>
  <footer>
    <a href="/terms">Terms</a> · <a href="/privacy">Privacy</a> · <a href="mailto:aaron@pilk.ai">Contact</a>
  </footer>
</body>
</html>`;
}
