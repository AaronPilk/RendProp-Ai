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
// The Worker runs first so HTTPS/apex canonicalization applies to static files
// too. Dynamic routes run before the ASSETS binding; other known static files
// retain their normal delivery headers, ranges and MIME types.
//
// Every response is branded: malformed paths (`/f/%`) 404, and any exception
// the handler throws is caught and answered with errorPage() + no-store — a
// viewer must never see Cloudflare's raw "Worker threw exception" page.

import type { Env, Portfolio, Tour } from "./types";
import { appStoreUrl } from "./attribution";
import { buildDemoPortfolio, buildDemoTour, demoSpaceFrom, isDemoHandle, isDemoSlug } from "./demo";
import { errorPage, notFoundPage, portfolioUnavailablePage } from "./html";
import { joinPage, normalizeJoinCode } from "./join";
import { privacyPage, termsPage } from "./legal";
import { allowsIndexing, renderTourPage, unbrandedNoticePage, unbrandedSelfCheck } from "./player";
import { renderPortfolioPage } from "./portfolio";
import { sitemapXml, sitemapCursor, propertySitemapCursors, sitemapIndexXml, propertySitemapXml } from "./sitemap";
import { fetchUpstreamJSON } from "./upstream";
import { spatialData, spatialModule, spatialPage } from "./spatial";
import { handleMediaDelivery } from "./media-delivery";
import { handleRecipientConfirmation } from "./recipient-confirmation";
import { propertyPage } from "./property-site";
import { propertyAddressOnlyPath, propertyAddressPath, propertyAddressSlug } from "./property-seo";
import { previewWebsiteTheme } from "./property-design";
import { isPublicLocation, lookupNearbyPlaces, peekNearbyPlaces, type NearbyPlacesResult } from "./nearby-places";
import { renderNearbyMap } from "./nearby-map";

const DEFAULT_TTL = 60; // seconds — synthetic demo HTML only

function ttl(env: Env): number {
  const n = Number(env.TOUR_CACHE_TTL);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_TTL;
}

function functionsBase(env: Env): string {
  return String(env.SUPABASE_FUNCTIONS_URL || "").replace(/\/+$/, "");
}

/** Keep absence/collision separate from an unavailable authority: a direct
 * address route must never turn a resolver outage into a false 404. */
type AddressLookup = { kind: "unique"; slug: string; claimed: boolean } | { kind: "missing" } | { kind: "unavailable" };
async function uniqueAddressSlug(descriptor: string, env: Env): Promise<AddressLookup> {
  if (env.ADDRESS_ONLY_CANONICAL !== "enabled" || !/^[a-z0-9][a-z0-9-]{0,119}$/.test(descriptor)) return { kind: "missing" };
  const answer = await fetchUpstreamJSON(`/tours/address-lookup/${encodeURIComponent(descriptor)}`, env, false, undefined, true);
  if (answer.kind === "not-found") return { kind: "missing" };
  if (answer.kind !== "ok" || !answer.value || typeof answer.value !== "object" || Array.isArray(answer.value)) return { kind: "unavailable" };
  const value = answer.value as Record<string, unknown>;
  if (Object.keys(value).length === 1 && value.status === "ambiguous") return { kind: "missing" };
  const keys = Object.keys(value).sort().join(",");
  if ((keys !== "slug,status" && keys !== "claimed,slug,status") || value.status !== "unique"
      || (keys === "claimed,slug,status" && value.claimed !== true)
      || typeof value.slug !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(value.slug)) return { kind: "unavailable" };
  return { kind: "unique", slug: value.slug, claimed: value.claimed === true };
}

async function hasUniqueAddress(tour: Tour, env: Env): Promise<"unique" | "not-unique" | "unavailable"> {
  // Noindex remains private-by-address unless a previously exposed bare URL
  // was reserved for this exact listing before the dated-link migration.
  const descriptor = propertyAddressSlug(tour.listing?.address);
  if (!descriptor) return "not-unique";
  const lookup = await uniqueAddressSlug(descriptor, env);
  if (lookup.kind === "unavailable") return "unavailable";
  if (lookup.kind !== "unique" || lookup.slug !== tour.slug) return "not-unique";
  // After dated URLs are enabled, only already-reserved bare addresses keep
  // their single-segment identity. Every new publication gets a collision-
  // proof address+date+slug link, so a later duplicate cannot break its link.
  if (env.PROPERTY_DATE_SUFFIX === "enabled" && !lookup.claimed) return "not-unique";
  if (!allowsIndexing(tour) && !lookup.claimed) return "not-unique";
  // A one-segment legacy publication slug must continue to name its existing
  // property, even if it happens to equal another listing's address spelling.
  if (/^[A-Za-z0-9_-]{1,64}$/.test(descriptor) && descriptor !== tour.slug) {
    const alias = await fetchUpstreamJSON(`/tours/${encodeURIComponent(descriptor)}`, env);
    if (alias.kind === "error") return "unavailable";
    if (alias.kind === "ok") {
      if (!isTour(alias.value)) return "unavailable";
      if (alias.value.slug !== tour.slug) return "not-unique";
    }
  }
  return "unique";
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
      ...(extraHeaders["Cache-Control"]?.startsWith("no-store") ? {
        "CDN-Cache-Control": "no-store", "Cloudflare-CDN-Cache-Control": "no-store",
      } : {}),
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
/** Buyer-facing property pages stay in the browser, including when Rendprop
 * is installed. Only team invites use HTTPS app routing. Apple fetches AASA
 * per entitled host without redirects, so serve both hosts before canonical
 * normalization. Devices may cache the previous rules; the native incoming
 * URL handler also hands public pages back to the browser. */
const AASA = JSON.stringify({
  applinks: {
    details: [
      {
        appIDs: ["5F5C5G25Y6.com.rendprop.app"],
        components: [
          { "/": "/f/*", exclude: true, comment: "published property website — open in browser" },
          { "/": "/u/*", exclude: true, comment: "MLS-unbranded property website — open in browser" },
          { "/": "/a/*", exclude: true, comment: "public agent portfolio — open in browser" },
          { "/": "/join/*", comment: "a team invite" },
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
  addressLookupOn404 = false,
  expectedAddress?: string,
): Promise<Response> {
  const base = unbranded ? UNBRANDED_HEADERS : {};
  const notFound = () =>
    unbranded
      ? htmlResponse(unbrandedFallback("notfound"), 404, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(notFoundPage(), 404, { "Cache-Control": "no-store" });
  const upstreamError = (status: 429 | 502 | 503 = 502) =>
    unbranded
      ? htmlResponse(unbrandedFallback("error"), status, { ...base, "Cache-Control": "no-store" }, { unbranded })
      : htmlResponse(errorPage(), status, { "Cache-Control": "no-store" });

  // Slugs are nanoid (base64url) — reject anything else fast. The dated
  // browser alias has already been parsed to its full publication slug.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) {
    if (addressLookupOn404 && !expectedAddress) {
      const resolved = await uniqueAddressSlug(slug, env);
      if (resolved.kind === "unique") return handleTour(resolved.slug, req, url, env, ctx, false, false, slug);
      if (resolved.kind === "unavailable") return upstreamError(503);
    }
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
  const page = !embed && !unbranded ? propertyPage(url.searchParams.get("page")) : "home";
  const previewTheme = !embed && !unbranded ? previewWebsiteTheme(url.searchParams.get("preview_theme")) : null;

  // WH-05: changing only the response TTL leaves old cache hits reachable.
  // Customer HTML must bypass both reads AND writes, including entries from a
  // previous deployment. The explicit demo slugs have no revocable user data.
  const cache = demo && !previewTheme ? caches.default : null;
  const key = cacheKeyFor(url, `/${unbranded ? "u" : "f"}/${slug}${embed ? "?embed=1" : page === "home" ? "" : `?page=${page}`}${demoAs ? `&space=${demoAs}` : ""}`);
  if (cache) {
    const hit = await cache.match(key);
    if (hit) return req.method === "HEAD" ? new Response(null, hit) : hit;
  }

  const publicBase: "/f" | "/property" = url.pathname.startsWith("/property/") ? "/property" : "/f";
  const renderOpts = { embed, unbranded, origin: url.origin, page, publicBase, previewTheme,
    addressUrls: !demo, datedAddressCanonical: env.PROPERTY_DATE_SUFFIX === "enabled" };

  /** Render + (on `/u/`) refuse to serve anything that trips the self-check. */
  const finish = (tour: Tour, nearby: NearbyPlacesResult | null = null, addressOnly = false): Response => {
    if (previewTheme && (tour.space_type || "real_estate") !== "real_estate") return notFound();
    // Resolve the address only after the normal current-publication/hosting
    // authority has admitted this tour. Old short links keep working; an old
    // address spelling redirects to today's actual property without leaking a
    // private/unpublished address or treating the descriptor as identity.
    if (!demo && (tour.space_type || "real_estate") === "real_estate"
        && (unbranded ? /^\/u\/[^/]+\/[^/]+$/ : /^\/property\/[^/]+\/[^/]+$/).test(url.pathname)) {
      const canonicalPath = addressOnly ? propertyAddressOnlyPath(tour.listing?.address)!
        : propertyAddressPath(tour.slug, tour.listing?.address, unbranded ? "/u" : "/property",
          !unbranded && env.PROPERTY_DATE_SUFFIX === "enabled" ? tour.published_at : undefined);
      if (url.pathname !== canonicalPath) {
        const target = new URL(canonicalPath, url.origin); target.search = url.search;
        return new Response(null, { status: 308, headers: { ...(unbranded ? UNBRANDED_HEADERS : {}), Location: target.href, "Cache-Control": "no-store" } });
      }
    }
    const t = demo && !previewTheme ? ttl(env) : 0;
    const html = renderTourPage(
      tour,
      functionsBase(env),
      env.SUPABASE_ANON_KEY || "",
      env.TURNSTILE_SITE_KEY || "",
      nearby ? { ...renderOpts, nearby, addressOnlyCanonical: addressOnly } : { ...renderOpts, addressOnlyCanonical: addressOnly },
    );
    if (unbranded) {
      // Fail CLOSED. An MLS unbranded field must never receive a page with
      // agent branding, a contact form or an external link in it — a neutral
      // "temporarily unavailable" page is the safe failure, a leak is not.
      const violations = unbrandedSelfCheck(html, tour);
      if (violations.length) {
        console.error(JSON.stringify({ event: "unbranded_self_check_failed", count: violations.length }));
        return htmlResponse(unbrandedFallback("blocked"), 503, { ...base, "Cache-Control": "no-store" }, { unbranded });
      }
    }
    // F-H-19: the page already carries a robots meta tag; send the header too,
    // so a crawler that never parses the body (and anything reading the cached
    // response) gets the same answer. `/u/` has its own noindex in `base`.
    const robots: Record<string, string> =
      !previewTheme && (unbranded || allowsIndexing(tour)) ? {} : { "X-Robots-Tag": "noindex, nofollow" };
    const resp = htmlResponse(
      html,
      200,
      { ...base, ...robots, "Cache-Control": demo && !previewTheme ? `public, max-age=${t}, s-maxage=${t}` : "no-store" },
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
  if (upstream.kind === "not-found") {
    if (addressLookupOn404 && !expectedAddress) {
      const resolved = await uniqueAddressSlug(slug, env);
      if (resolved.kind === "unique") return handleTour(resolved.slug, req, url, env, ctx, false, false, slug);
      if (resolved.kind === "unavailable") return upstreamError(503);
    }
    return notFound();
  }
  if (upstream.kind === "error") return upstreamError(upstream.status);
  if (!isTour(upstream.value)) return upstreamError();
  try {
    const addressEligible = !unbranded && !embed && !previewTheme
      && (upstream.value.space_type || "real_estate") === "real_estate"
    const addressState = addressEligible ? await hasUniqueAddress(upstream.value, env) : "not-unique";
    if (expectedAddress && addressState === "unavailable") return upstreamError(503);
    const addressOnly = addressState === "unique";
    // A resolver result is never publication authority by itself: re-read the
    // actual tour and require a fresh proof for this exact requested alias.
    // A reserved, previously shared bare address can outlive a text address
    // correction, but may never point to another listing's publication.
    if (expectedAddress) {
      const expected = await uniqueAddressSlug(expectedAddress, env);
      if (expected.kind === "unavailable") return upstreamError(503);
      if (expected.kind !== "unique" || expected.slug !== upstream.value.slug
          || (env.PROPERTY_DATE_SUFFIX === "enabled" && !expected.claimed)
          || (!expected.claimed && propertyAddressSlug(upstream.value.listing?.address) !== expectedAddress)
          || (!allowsIndexing(upstream.value) && !expected.claimed)) return notFound();
    }
    // Already-cached neighbourhood places become static markup on the Location
    // page (map + list, no script needed). Cache-only: never a provider call,
    // lease or budget charge, and bounded so storage cannot delay the HTML.
    const nearby = page === "location" && !embed && !unbranded && (upstream.value.space_type || "real_estate") === "real_estate"
      ? await peekNearbyPlaces({ space_type: "real_estate", published_at: String(upstream.value.published_at || ""), listing: { lat: typeof upstream.value.listing?.lat === "number" ? upstream.value.listing.lat : null, lng: typeof upstream.value.listing?.lng === "number" ? upstream.value.listing.lng : null } }, env)
      : null;
    return finish(upstream.value, nearby, addressOnly);
  } catch {
    // A malformed nested field is an invalid upstream response, not a missing
    // published tour. Never render its raw JSON/error text into the public page.
    return upstreamError();
  }
}

async function handlePortfolio(handle: string, req: Request, url: URL, env: Env): Promise<Response> {
  if (!/^[A-Za-z0-9_.-]{1,64}$/.test(handle)) return htmlResponse(portfolioUnavailablePage(handle), 404, { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });

  // The canonical and the structured data are absolute-URL affordances, so the
  // renderer needs the handle this page was served at and the request origin.
  const renderOpts = { handle, origin: url.origin };

  // The demo agent is fictional, so no org answers for the handle. Served
  // from here for the same reason the demo TOUR is, and before the upstream
  // lookup so it never depends on an upstream that cannot know about it.
  if (isDemoHandle(handle)) {
    const resp = htmlResponse(renderPortfolioPage(buildDemoPortfolio(), renderOpts), 200, {
      "Cache-Control": "public, max-age=300", "X-Robots-Tag": "noindex, nofollow",
    });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  // A portfolio contains revocable customer addresses/photos/links too. Do not
  // consult or refresh any customer HTML cached by an earlier deployment.

  const upstream = await fetchUpstreamJSON(`/portfolio/${encodeURIComponent(handle)}`, env);
  if (upstream.kind === "not-found") {
    return htmlResponse(portfolioUnavailablePage(handle), 404, { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  }
  const upstreamError = (status: 429 | 502 | 503) => htmlResponse(errorPage("page"), status, { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
  if (upstream.kind === "error") return upstreamError(upstream.status);
  if (!isPortfolio(upstream.value)) return upstreamError(502);
  try {
    const resp = htmlResponse(renderPortfolioPage(upstream.value, renderOpts), 200, { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  } catch {
    return upstreamError(502);
  }
}

// Location data is requested separately so a best-effort map provider cannot
// delay the listing HTML. Every request rechecks current publication; neither
// a client coordinate nor an old cached listing can select the query location.
async function handleNearbyPlaces(slug: string, req: Request, url: URL, env: Env): Promise<Response> {
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Robots-Tag": "noindex, nofollow" },
  });
  if (req.method !== "GET") return reply(405, { status: "unavailable", places: [] });
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug) || isDemoSlug(slug) || url.searchParams.has("embed")) return reply(404, { status: "unavailable", places: [] });
  const upstream = await fetchUpstreamJSON(`/tours/${encodeURIComponent(slug)}/location`, env);
  if (upstream.kind === "not-found") return reply(404, { status: "unavailable", places: [] });
  if (upstream.kind === "error") return reply(upstream.status, { status: "unavailable", places: [] });
  if (!isPublicLocation(upstream.value) || upstream.value.slug !== slug) return reply(404, { status: "unavailable", places: [] });
  const result = await lookupNearbyPlaces(upstream.value, env);
  // The map is drawn here, from the same places and the same coarsened origin,
  // so the page never needs coordinates, tiles or a map script of its own.
  const map = renderNearbyMap(result, upstream.value.listing);
  return reply(200, { ...result, ...(map ? { map_html: map } : {}), license_url: "https://www.openstreetmap.org/copyright" });
}

/** A share control starts with an already-public publication slug. This read
 * checks the current hosted tour and returns the same branded canonical path
 * that the page renderer would use. It never accepts an address as input. */
async function handleShareLink(slug: string, req: Request, url: URL, env: Env): Promise<Response> {
  const headers = { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow",
    "X-Content-Type-Options": "nosniff", "Content-Type": "application/json; charset=utf-8" };
  const reply = (status: number, body: unknown) => {
    const response = new Response(JSON.stringify(body), { status, headers });
    return req.method === "HEAD" ? new Response(null, response) : response;
  };
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug) || isDemoSlug(slug) || url.search) {
    return reply(404, { error: "not_found" });
  }
  const upstream = await fetchUpstreamJSON(`/tours/${encodeURIComponent(slug)}`, env);
  if (upstream.kind === "not-found") return reply(404, { error: "not_found" });
  if (upstream.kind === "error") return reply(upstream.status, { error: "unavailable" });
  if (!isTour(upstream.value) || upstream.value.slug !== slug) return reply(502, { error: "unavailable" });
  try {
    const tour = upstream.value;
    const realEstate = (tour.space_type || "real_estate") === "real_estate";
    const unique = realEstate && await hasUniqueAddress(tour, env) === "unique";
    const path = realEstate
      ? unique ? propertyAddressOnlyPath(tour.listing.address)! : propertyAddressPath(slug, tour.listing.address,
          "/property", env.PROPERTY_DATE_SUFFIX === "enabled" ? tour.published_at : undefined)
      : `/f/${encodeURIComponent(slug)}`;
    return reply(200, { url: new URL(path, url.origin).href, address_only: unique });
  } catch {
    return reply(502, { error: "unavailable" });
  }
}

/** Static marketing and fresh, opt-in customer child sitemaps. Customer
 * enumeration is bounded by the same public authority as the property page. */
async function sitemapResponse(url: URL, env: Env): Promise<Response> {
  const siteOnly = url.pathname === "/sitemap-site.xml";
  const headers = { "Content-Type": "application/xml; charset=utf-8",
    "Cache-Control": siteOnly ? "public, max-age=3600, s-maxage=3600" : "no-store",
    "X-Content-Type-Options": "nosniff" };
  if (siteOnly) return new Response(sitemapXml(url.origin), {headers});
  const page = url.pathname === "/sitemap-properties.xml";
  const keys = [...url.searchParams.keys()], cursor = url.searchParams.get("cursor");
  if (keys.length > (page ? 1 : 0) || keys.some(key => key !== "cursor")
      || (page && keys.length > 0 && !sitemapCursor(cursor))) {
    return new Response("Invalid sitemap page.", {status:400, headers:{"Cache-Control":"no-store","X-Robots-Tag":"noindex"}});
  }
  const query = page ? "?limit=200" + (cursor ? "&cursor=" + encodeURIComponent(cursor) : "") : "?pages=1";
  const upstream = await fetchUpstreamJSON("/tours/index" + query, env);
  let body: string | null = null;
  if (upstream.kind === "ok") {
    if (page) body = propertySitemapXml(url.origin, upstream.value);
    else {
      const cursors = propertySitemapCursors(upstream.value);
      if (cursors) body = sitemapIndexXml(url.origin, cursors);
    }
  }
  return body === null
    ? new Response("Sitemap temporarily unavailable.", {status:503,headers:{"Cache-Control":"no-store","X-Robots-Tag":"noindex","Retry-After":"60"}})
    : new Response(body, {headers});
}

async function route(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(req.url);
  if (url.pathname === "/verify-client-email") {
    const canonical = canonicalRedirect(url);
    if (canonical) return canonical;
    return handleRecipientConfirmation(req, env);
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
  }

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
  if (path.startsWith("/media/") || path.startsWith("/media-brand/") || path.startsWith("/private-media/")) return handleMediaDelivery(req,env);

  // Keep the discoverable apex entry pointed at the deployed browser app.
  // The destination is fixed; query strings do not cross into the app.
  if (path === "/studio") {
    return new Response(null, {
      status: 302,
      headers: {
        Location: "https://studio.rendprop.com/",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
      },
    });
  }

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

  const nearbyMatch = path.match(/^\/f\/([^/]+)\/nearby$/);
  if (nearbyMatch) {
    const slug = safeDecode(nearbyMatch[1]);
    return handleNearbyPlaces(slug || "", req, url, env);
  }
  const shareLinkMatch = path.match(/^\/f\/([^/]+)\/share-link$/);
  if (shareLinkMatch) {
    const slug = safeDecode(shareLinkMatch[1]);
    return handleShareLink(slug || "", req, url, env);
  }
  // A browser-only alias avoids previously cached app-link rules. This is
  // the same validated published slug/read path, never a redirect to /f/.
  // The dot separates dated aliases from all legacy publication slugs, whose
  // alphabet has never included a dot. A shared old token cannot be hijacked.
  const datedAddressMatch = path.match(/^\/property\/([a-z0-9][a-z0-9-]{0,119})\/\d{8}\.([A-Za-z0-9_-]{1,64})$/);
  const addressMatch = path.match(/^\/property\/([a-z0-9][a-z0-9-]{0,119})\/([^/]+)$/);
  const fMatch = datedAddressMatch || addressMatch || path.match(/^\/(?:f|property)\/([^/]+)$/);
  if (fMatch) {
    const slug = safeDecode(fMatch[datedAddressMatch || addressMatch ? 2 : 1]);
    if (slug === null) return htmlResponse(notFoundPage(), 404, { "Cache-Control": "no-store" });
    return handleTour(slug, req, url, env, ctx, false, !datedAddressMatch && !addressMatch && path.startsWith("/property/"));
  }

  // The MLS-safe twin of /f/. Same slug, same payload, same renderer.
  const uAddressMatch = path.match(/^\/u\/([a-z0-9][a-z0-9-]{0,119})\/([^/]+)$/);
  const uMatch = uAddressMatch || path.match(/^\/u\/([^/]+)$/);
  if (uMatch) {
    const slug = safeDecode(uMatch[uAddressMatch ? 2 : 1]);
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

  // ── /join/<code> ─────────────────────────────────────────────────────────
  // The landing page for a team invite. no-store and noindex because the URL
  // carries a single-use code; the Worker never validates it (it has no
  // database, and a page that told a stranger whether a code was real would be
  // an oracle for guessing them) — acceptance stays in POST /team/accept.
  if (path === "/join" || path.startsWith("/join/")) {
    const fromPath = path === "/join" ? null : path.slice("/join/".length);
    const code = normalizeJoinCode(fromPath ?? url.searchParams.get("code"));
    const resp = htmlResponse(joinPage(code), code ? 200 : 404, {
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex, nofollow",
    });
    return req.method === "HEAD" ? new Response(null, resp) : resp;
  }

  if (["/sitemap.xml", "/sitemap-site.xml", "/sitemap-properties.xml"].includes(path)) {
    const resp = await sitemapResponse(url, env);
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

  // Static files pass through the same canonical-origin checks as tours.
  // The binding preserves asset MIME types, ranges, ETags and _headers.
  if (env.ASSETS) {
    const asset = await env.ASSETS.fetch(req);
    if (asset.status !== 404) return asset;
  }

  // Safety net for local tests or a deployment without the asset binding.
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
      return withSafetyHeaders(await route(req, env, ctx), req);
    } catch (err) {
      // Last line of defence: never let an exception escape as an unbranded
      // Cloudflare error page. no-store so a transient bug isn't cached.
      // Exceptions may contain upstream URLs, signed capabilities or headers.
      console.error(JSON.stringify({ event: "tour_host_unhandled_error", kind: err instanceof Error ? "error" : "unknown" }));
      let kind: "tour" | "page" = "page";
      let unbranded = false;
      try {
        const p = new URL(req.url).pathname;
        kind = /^\/(?:f|property)\//.test(p) ? "tour" : "page";
        // A crash on /u/ must not answer with the branded error page.
        unbranded = /^\/u\//.test(p);
      } catch { /* keep "page" */ }
      const resp = unbranded
        ? htmlResponse(unbrandedFallback("error"), 500, { ...UNBRANDED_HEADERS, "Cache-Control": "no-store" }, { unbranded: true })
        : htmlResponse(errorPage(kind), 500, { "Cache-Control": "no-store" });
      return withSafetyHeaders(req.method === "HEAD" ? new Response(null, resp) : resp, req);
    }
  },
} satisfies ExportedHandler<Env>;

function withSafetyHeaders(response: Response, req: Request): Response {
  const headers = new Headers(response.headers);
  headers.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  // MLS embeds are an intentional public, unbranded delivery surface.
  if (!/^\/u(?:\/|$)/.test(new URL(req.url).pathname) && !headers.has("X-Frame-Options")) headers.set("X-Frame-Options", "SAMEORIGIN");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

/** Minimal branded landing for the apex domain until the marketing site ships. */
function landingPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Rendprop — Property Photos, Videos &amp; Websites for iPhone</title>
<meta name="description" content="Start with property photos, review optional AI edits, create a listing or social video, and publish a property website. Recorded walkthroughs are optional. Aerial intros are Coming soon.">
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
  <p class="sub">Start with landscape property photos, review optional AI edits, create a listing video or a
  vertical social video, then review and publish your property website. Recorded walkthroughs are optional
  and separate. Aerial intros are Coming soon; new aerial creation is not available or included in any plan.</p>
  <div>
    <a class="pill" href="${appStoreUrl("site")}">Download on the App Store</a>
    <a class="soon" href="https://studio.rendprop.com/">Open Studio</a>
    <span class="soon">Free on iPhone · iOS 16 or later</span>
  </div>
  <footer>
    <a href="/terms">Terms</a> · <a href="/privacy">Privacy</a> · <a href="mailto:aaron@pilk.ai">Contact</a>
  </footer>
</body>
</html>`;
}
