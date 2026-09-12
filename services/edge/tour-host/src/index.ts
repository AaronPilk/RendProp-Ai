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
//   GET /sitemap.xml the crawl index (src/sitemap.ts). Served here, not from
//                    ./public, so it can grow with what is actually published.
//
// Customer pages are server-rendered with no-store and a fresh upstream lookup
// on every request so old edge HTML cannot outlive publication revocation.
// Only self-contained synthetic demos retain caching. Video is served zero-egress: the all-intra R2
// mp4 (`scrub_url`, byte-range) is the primary scroll-scrub source, with
// Cloudflare Stream HLS (`hls_url`) as fallback only. The browser talks to
// Supabase directly for the lead form (POST /leads) and the view beacon
// (POST /beacon/:slug) — both deployed with --no-verify-jwt.
//
// Routing (wrangler.toml): the Worker owns the whole apex, `rendprop.com/*`.
// Requests that exactly match a file under ./public (the marketing site,
// /assets/*, robots.txt, llms.txt) are answered by Static Assets before this
// script runs; everything else lands in fetch() below. That precedence is why
// public/sitemap.xml had to be deleted when /sitemap.xml became a route: a
// file under ./public wins, and the handler would never have been reached.
//
// Every response is branded: malformed paths (`/f/%`) 404, and any exception
// the handler throws is caught and answered with errorPage() + no-store — a
// viewer must never see Cloudflare's raw "Worker threw exception" page.

import type { Env, Portfolio, Tour } from "./types";
import { appStoreUrl } from "./attribution";
import { buildDemoPortfolio, buildDemoTour, demoSpaceFrom, isDemoHandle, isDemoSlug } from "./demo";
import { errorPage, notFoundPage, portfolioUnavailablePage } from "./html";
import { privacyPage, termsPage } from "./legal";
import { allowsIndexing, renderTourPage, unbrandedNoticePage, unbrandedSelfCheck } from "./player";
import { renderPortfolioPage } from "./portfolio";
import { sitemapXml } from "./sitemap";
import { fetchUpstreamJSON } from "./upstream";
import { spatialData, spatialModule, spatialPage } from "./spatial";

const DEFAULT_TTL = 60; // seconds — synthetic demo HTML only

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
        "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net",
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
        "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://challenges.cloudflare.com",
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

const APEX_HOST = "rendprop.com";

/**
 * Canonical origin for everything the Worker answers: `https://rendprop.com`.
 * Verified live on 2026-09-05: `http://rendprop.com/terms` served the page with
 * a 200 (no HTTPS upgrade — the HSTS header on a plain-HTTP response is ignored
 * by browsers) and `https://www.rendprop.com/` answered Cloudflare's 525 page,
 * because only the apex had a Worker route. A tour link is very often typed or
 * pasted without a scheme, so both cases are ones real viewers hit.
 *
 * Only the production hosts are normalised — `wrangler dev` (localhost, http)
 * and preview hosts are left alone. Static Assets (the marketing pages) are
 * answered before this script runs, so for THOSE paths the zone settings
 * ("Always Use HTTPS" + a www→apex Redirect Rule) are still required; this is
 * the Worker's half of the fix and a safety net if a setting is ever toggled off.
 */
/**
 * apple-app-site-association — what makes a rendprop.com link open the iOS app
 * instead of Safari.
 *
 * Apple fetches this over HTTPS PER HOST in the app's entitlement, does NOT
 * follow redirects, and requires `application/json`. Both of those shape the
 * routing below: it is answered before `canonicalRedirect`, so the www host
 * serves its own copy rather than 301-ing to the apex, and it is served at the
 * legacy root path as well as `/.well-known/` because older iOS versions only
 * look at the root.
 *
 * `components` rather than the deprecated `paths` array (TN3155). `/u/*` is in
 * here on purpose: the MLS-unbranded twin is the same tour, and a buyer who
 * taps one inside the app is not in an MLS context - the page it loads is
 * still the unbranded one, so the gate does not move.
 *
 * The appID is <TeamID>.<bundle id>. If either ever changes, this and
 * apps/ios/Rendprop/Rendprop.entitlements change together or links silently
 * stop opening the app - silently, because a failed AASA fetch looks exactly
 * like a link that was never meant for an app.
 */
const AASA = JSON.stringify({
  applinks: {
    details: [
      {
        appIDs: ["5F5C5G25Y6.com.rendprop.app"],
        components: [
          { "/": "/f/*", comment: "a published tour" },
          { "/": "/a/*", comment: "an agent's portfolio" },
          // /u/* is EXCLUDED, deliberately. It is the URL an agent puts in an
          // MLS field because the MLS forbids agent branding and contact
          // capture on it; opening it in the app wrapped a compliant page in
          // branded chrome. An unbranded link stays a plain web page.
          { "/": "/u/*", exclude: true,
            comment: "MLS-unbranded — never open in the app" },
        ],
      },
    ],
  },
});

function aasaResponse(): Response {
  return new Response(AASA, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      // Short enough that a bundle-id or team-id change propagates the same
      // day, long enough that it is not fetched on every cold start.
      "Cache-Control": "public, max-age=3600",
    },
  });
}

function canonicalRedirect(url: URL): Response | null {
  const host = url.hostname.toLowerCase();
  const isApex = host === APEX_HOST;
  const isWww = host === `www.${APEX_HOST}`;
  if (!isApex && !isWww) return null;
  if (isApex && url.protocol === "https:") return null;
  const location = `https://${APEX_HOST}${url.pathname}${url.search}`;
  return new Response(null, {
    status: 301,
    headers: {
      Location: location,
      "Cache-Control": "public, max-age=3600",
      "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    },
  });
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Minimum renderer contract, not a replacement for upstream field validation. */
function isTour(value: unknown): value is Tour {
  return isRecord(value) && typeof value.slug === "string" && value.slug.length > 0 &&
    isRecord(value.listing) && isRecord(value.agent_card) && isRecord(value.cta) &&
    Array.isArray(value.chapters) && value.chapters.every(isRecord);
}

function isPortfolio(value: unknown): value is Portfolio {
  return isRecord(value) && isRecord(value.agent_card) &&
    (value.org === undefined || isRecord(value.org)) &&
    (value.tours === undefined || (Array.isArray(value.tours) && value.tours.every(isRecord))) &&
    (value.listings === undefined || (Array.isArray(value.listings) && value.listings.every(isRecord)));
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
      ? htmlResponse(unbrandedFallback("notfound"), 404, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(notFoundPage(), 404, { "Cache-Control": "no-store" });
  const upstreamError = (status: 502 | 503 = 502) =>
    unbranded
      ? htmlResponse(unbrandedFallback("error"), status, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(errorPage(), status, { "Cache-Control": "no-store" });

  // Slugs are nanoid (base64url) — reject anything else fast.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) {
    return unbranded
      ? htmlResponse(unbrandedFallback("notfound"), 404, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(notFoundPage(), 404, { "Cache-Control": "no-store" });
  }

  // ?embed=1 renders ONLY the flythrough hero (for the in-app "See it in
  // action" card); the full page is served otherwise. Keep separate cache keys.
  const embed = url.searchParams.has("embed");
  const demo = isDemoSlug(slug);
  // The in-app card for a venue / bar / store / gym asks the demo to present
  // itself as a sample tour rather than a home listing (`?embed=1&space=venue`).
  // Only the demo slug honours it, only in embed mode, and only for a known
  // business type; it is part of the cache key so the two renders never mix.
  const demoAs = embed && demo ? demoSpaceFrom(url.searchParams.get("space")) : undefined;

  // WH-05: changing only the response TTL leaves old cache hits reachable.
  // Customer HTML must bypass both reads AND writes, including entries from a
  // previous deployment. The explicit demo slugs have no revocable user data.
  const cache = demo ? caches.default : null;
  const key = cacheKeyFor(url, `/${unbranded ? "u" : "f"}/${slug}${embed ? "?embed=1" : ""}${demoAs ? `&space=${demoAs}` : ""}`);
  if (cache) {
    const hit = await cache.match(key);
    if (hit) return req.method === "HEAD" ? new Response(null, hit) : hit;
  }

  const renderOpts = { embed, unbranded, origin: url.origin };

  /** Render + (on `/u/`) refuse to serve anything that trips the self-check. */
  const finish = (tour: Tour): Response => {
    const t = demo ? ttl(env) : 0;
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
      { ...base, ...robots, "Cache-Control": demo ? `public, max-age=${t}, s-maxage=${t}` : "no-store" },
      { unbranded },
    );
    if (cache && req.method === "GET" && t > 0) ctx.waitUntil(cache.put(key, resp.clone()));
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  };

  // Demo tour — self-contained, no DB. Renders through the SAME renderer a real
  // listing uses, so rendprop.com/f/estate-demo IS the product (and powers the
  // in-app Home demo). /u/estate-demo is the MLS-safe cut of the same tour.
  if (demo) return finish(buildDemoTour(demoAs));

  const upstream = await fetchUpstreamJSON(`/tours/${encodeURIComponent(slug)}`, env);
  if (upstream.kind === "not-found") return notFound();
  if (upstream.kind === "error") return upstreamError(upstream.status);
  if (!isTour(upstream.value)) return upstreamError();
  try {
    return finish(upstream.value);
  } catch {
    // A malformed nested field is an invalid upstream response, not a missing
    // published tour. Never render its raw JSON/error text into the public page.
    return upstreamError();
  }
}

async function handlePortfolio(handle: string, req: Request, url: URL, env: Env): Promise<Response> {
  if (!/^[A-Za-z0-9_.-]{1,64}$/.test(handle)) return htmlResponse(portfolioUnavailablePage(handle), 404, { "Cache-Control": "no-store" });

  // The canonical and the structured data are absolute-URL affordances, so the
  // renderer needs the handle this page was served at and the request origin.
  const renderOpts = { handle, origin: url.origin };

  // The demo agent is fictional, so no org answers for the handle. Served
  // from here for the same reason the demo TOUR is, and before the upstream
  // lookup so it never depends on an upstream that cannot know about it.
  if (isDemoHandle(handle)) {
    const resp = htmlResponse(renderPortfolioPage(buildDemoPortfolio(), renderOpts), 200, {
      "Cache-Control": "public, max-age=300",
    });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  // A portfolio contains revocable customer addresses/photos/links too. Do not
  // consult or refresh any customer HTML cached by an earlier deployment.

  const upstream = await fetchUpstreamJSON(`/portfolio/${encodeURIComponent(handle)}`, env);
  if (upstream.kind === "not-found") {
    return htmlResponse(portfolioUnavailablePage(handle), 404, { "Cache-Control": "no-store" });
  }
  const upstreamError = (status: 502 | 503) => htmlResponse(errorPage("page"), status, { "Cache-Control": "no-store" });
  if (upstream.kind === "error") return upstreamError(upstream.status);
  if (!isPortfolio(upstream.value)) return upstreamError(502);
  try {
    const resp = htmlResponse(renderPortfolioPage(upstream.value, renderOpts), 200, { "Cache-Control": "no-store" });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  } catch {
    return upstreamError(502);
  }
}

/**
 * GET /sitemap.xml — served by the Worker, not by Static Assets.
 *
 * `public/sitemap.xml` (a hand-maintained eight-URL file that never once named
 * a real tour) was DELETED as part of this route: an exact file match under
 * ./public is answered by Static Assets before this script runs, so leaving it
 * in place would have made this handler unreachable.
 *
 * What it can and cannot enumerate today, and the upstream endpoint that would
 * let it list real tours, are documented in src/sitemap.ts. Both of that file's
 * hard rules — no `/u/` URL, and no tour that is not opted into indexing — are
 * enforced by construction: this handler passes no tours at all, because there
 * is no endpoint that can tell it which ones qualify.
 *
 * Cached for an hour at the edge and in the browser. A sitemap is polled by
 * crawlers, not by people, and an hour is short enough that a newly published
 * tour appears the same day once the upstream index exists.
 */
function sitemapResponse(url: URL): Response {
  return new Response(sitemapXml(url.origin), {
    status: 200,
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Cache-Control": "public, max-age=3600, s-maxage=3600",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

async function route(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }

  const url = new URL(req.url);
  // BEFORE the canonical redirect: Apple does not follow redirects when it
  // fetches the association file, and it fetches one per host, so www must
  // answer for itself.
  const rawPath = url.pathname.replace(/\/+$/, "") || "/";
  if (rawPath === "/.well-known/apple-app-site-association" ||
      rawPath === "/apple-app-site-association") {
    const resp = aasaResponse();
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  const canonical = canonicalRedirect(url);
  if (canonical) return canonical;

  const path = rawPath;

  if (path === "/spatial-viewer.js") {
    const response = spatialModule();
    return req.method === "HEAD" ? new Response(null, response) : response;
  }
  const spatial = path.match(/^\/s\/([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(?:\/(manifest|model))?$/i);
  if (spatial) {
    const response = spatial[2]
      ? await spatialData(req, env, spatial[1].toLowerCase(), spatial[2] as "manifest" | "model")
      : spatialPage(spatial[1].toLowerCase());
    return req.method === "HEAD" ? new Response(null, response) : response;
  }

  const fMatch = path.match(/^\/f\/([^/]+)$/);
  if (fMatch) {
    const slug = safeDecode(fMatch[1]);
    if (slug === null) return htmlResponse(notFoundPage(), 404, { "Cache-Control": "no-store" });
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
        { ...UNBRANDED_HEADERS, "Cache-Control": "no-store" },
        { unbranded: true },
      );
    }
    return handleTour(slug, req, url, env, ctx, true);
  }

  const aMatch = path.match(/^\/a\/([^/]+)$/);
  if (aMatch) {
    const handle = safeDecode(aMatch[1]);
    if (handle === null) return htmlResponse(portfolioUnavailablePage("?"), 404, { "Cache-Control": "no-store" });
    return handlePortfolio(handle, req, url, env);
  }

  if (path === "/sitemap.xml") {
    const resp = sitemapResponse(url);
    return req.method === "HEAD" ? new Response(null, resp) : resp;
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
  <h1>Win the listing.<br>Skip the film crew.</h1>
  <p class="sub">A walkthrough video goes in. A smooth, drone-style tour comes out — with AI-enhanced
  photos, social reels, floor plans, and a link buyers scroll through like it's social.</p>
  <div>
    <a class="pill" href="${appStoreUrl("site")}">Download on the App Store</a>
    <span class="soon">Free on iPhone · iOS 16 or later</span>
  </div>
  <footer>
    <a href="/terms">Terms</a> · <a href="/privacy">Privacy</a> · <a href="mailto:aaron@pilk.ai">Contact</a>
  </footer>
</body>
</html>`;
}
