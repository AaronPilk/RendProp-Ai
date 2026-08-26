// tour-host — the Cloudflare Worker that serves Rendprop's public pages:
//
//   GET /f/:slug     the scroll-scrub tour player (renders GET /tours/:slug)
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
// Routes are bound in wrangler.toml: rendprop.app/f/* and rendprop.app/a/*.

import type { Env, Portfolio, Tour } from "./types";
import { errorPage, notFoundPage, portfolioUnavailablePage } from "./html";
import { privacyPage, termsPage } from "./legal";
import { renderTourPage } from "./player";
import { renderPortfolioPage } from "./portfolio";

const DEFAULT_TTL = 60; // seconds — published HTML can change on republish

function ttl(env: Env): number {
  const n = Number(env.TOUR_CACHE_TTL);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_TTL;
}

function functionsBase(env: Env): string {
  return String(env.SUPABASE_FUNCTIONS_URL || "").replace(/\/+$/, "");
}

function htmlResponse(html: string, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      // CSP: inline styles/scripts (the player engine), hls.js from cdnjs, media
      // from Stream/R2 over https + MSE blobs, and XHR/fetch to Supabase.
      "Content-Security-Policy": [
        "default-src 'self'",
        "base-uri 'self'",
        "img-src 'self' https: data: blob:",
        "media-src 'self' https: data: blob:",
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com",
        "worker-src 'self' blob:",
        "child-src 'self' blob:",
        "connect-src 'self' https:",
        "font-src 'self' data:",
        "form-action 'self' https:",
        "frame-ancestors 'self' https:",
      ].join("; "),
      ...extraHeaders,
    },
  });
}

/** Stable, query-independent cache key so /f/x and /f/x/ share one entry. */
function cacheKeyFor(url: URL, canonicalPath: string): Request {
  return new Request(`${url.origin}${canonicalPath}`, { method: "GET" });
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

async function handleTour(slug: string, req: Request, url: URL, env: Env, ctx: ExecutionContext): Promise<Response> {
  // Slugs are nanoid (base64url) — reject anything else fast.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(slug)) return htmlResponse(notFoundPage(), 404);

  const cache = caches.default;
  const key = cacheKeyFor(url, `/f/${slug}`);
  const hit = await cache.match(key);
  if (hit) return req.method === "HEAD" ? new Response(null, hit) : hit;

  let upstream: Response;
  try {
    upstream = await fetchSupabase(`/tours/${encodeURIComponent(slug)}`, env);
  } catch {
    return htmlResponse(errorPage(), 502, { "Cache-Control": "no-store" });
  }

  if (upstream.status === 404) {
    return htmlResponse(notFoundPage(), 404, { "Cache-Control": "public, max-age=30" });
  }
  if (!upstream.ok) {
    return htmlResponse(errorPage(), 502, { "Cache-Control": "no-store" });
  }

  let tour: Tour;
  try {
    tour = (await upstream.json()) as Tour;
  } catch {
    return htmlResponse(errorPage(), 502, { "Cache-Control": "no-store" });
  }
  if (!tour || !tour.slug) {
    return htmlResponse(notFoundPage(), 404, { "Cache-Control": "public, max-age=30" });
  }

  const t = ttl(env);
  const html = renderTourPage(tour, functionsBase(env), env.SUPABASE_ANON_KEY || "");
  const resp = htmlResponse(html, 200, {
    "Cache-Control": `public, max-age=${t}, s-maxage=${t}`,
  });
  if (req.method === "GET" && t > 0) ctx.waitUntil(cache.put(key, resp.clone()));
  return req.method === "HEAD" ? new Response(null, resp) : resp;
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

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (req.method !== "GET" && req.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }

    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    const fMatch = path.match(/^\/f\/([^/]+)$/);
    if (fMatch) return handleTour(decodeURIComponent(fMatch[1]), req, url, env, ctx);

    const aMatch = path.match(/^\/a\/([^/]+)$/);
    if (aMatch) return handlePortfolio(decodeURIComponent(aMatch[1]), req, url, env, ctx);

    // Legal pages — static HTML, cacheable for an hour.
    if (path === "/terms" || path === "/privacy") {
      const resp = htmlResponse(path === "/terms" ? termsPage() : privacyPage(), 200, {
        "Cache-Control": "public, max-age=3600",
      });
      return req.method === "HEAD" ? new Response(null, resp) : resp;
    }

    if (path === "/healthz") return new Response("ok", { status: 200, headers: { "Content-Type": "text/plain" } });

    // The routes only send /f/* and /a/*, but be friendly if the Worker is hit
    // directly (e.g. `wrangler dev`): bare / and /f, /a → marketing site.
    if (path === "/" || path === "/f" || path === "/a") {
      return Response.redirect("https://rendprop.app", 302);
    }

    return htmlResponse(notFoundPage(), 404);
  },
} satisfies ExportedHandler<Env>;
