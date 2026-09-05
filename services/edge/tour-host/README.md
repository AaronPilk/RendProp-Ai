# Rendprop — tour-host (Cloudflare Worker)

Serves Rendprop's **public** pages at the edge:

| Route | Renders | Source |
|---|---|---|
| `GET /f/:slug` | the scroll-scrub **tour player** — branded | `GET ${SUPABASE_FUNCTIONS_URL}/tours/:slug` |
| `GET /u/:slug` | the **same tour, unbranded** — MLS-safe | the same payload |
| `GET /a/:handle` | an org's **portfolio grid** (cards → `/f/:slug`) | `GET ${SUPABASE_FUNCTIONS_URL}/portfolio/:handle` |

Each request is server-rendered to a **self-contained HTML page** (no build step, no
client framework) and cached at the edge with a short TTL. The player is a port of the
proven iOS webview player (`apps/ios/Rendprop/Resources/player/index.html`) — same
rAF-lerp scrub loop, buffer gate, chapter rail, room label, jank watchdog and autoplay
fallback — adapted to stream its video instead of bundling a demo file.

This is the component from `docs/BACKEND-ARCHITECTURE.md` §1.5 / step 7.

---

## `/f/` vs `/u/` — the branded link and the MLS link

Every tour has **two** URLs off the same slug and the same payload:

| | `/f/<slug>` — **branded** | `/u/<slug>` — **unbranded** |
|---|---|---|
| Agent card, phone, email, socials | yes | **no** |
| Lead form / CTA / deep link | yes | **no** |
| Zillow + secondary links, house partners, financing | yes | **no** |
| "Made with Rendprop", wordmark, `rendprop.com` links | yes | **no** |
| `og:*` / `twitter:` cards, `rel=canonical` | yes | **no** |
| Property media, address, details, floor plan, chapters | yes | yes |
| **AI disclosure block** (`#disclosure`) | yes | **yes** — it is property information |
| Robots | indexable, self-canonical | `noindex` meta **and** `X-Robots-Tag`, never in the sitemap |
| View beacon | counted | counted, with `unbranded: true` |
| Lead events | fired | never |
| CSP | `frame-ancestors 'self'`, Turnstile allowed | `form-action 'none'`, `frame-ancestors *` (MLS systems iframe it) |

**Use the right one.** MLS unbranded virtual-tour rules ban agent/broker
identification, "comment or contact forms, ratings … or social media profiles",
and "advertising of any kind, including links to additional content or external
sites not related to the specific property". Branding violations are fined (RI
Statewide MLS: $50 for a first offence, escalating). The unbranded field is
also the one that syndicates to Zillow/Realtor.com — so `/u/` is what buyers see
and `/f/` is what the agent sends by email, text, social and open-house QR.

### How the guarantee is enforced

1. **One renderer, no fork.** `renderTourPage(tour, …, { unbranded: true })`.
   A second copy of the page would drift, and the drift is a legal problem.
2. **Stripped at the DATA level, not with CSS.** `sanitizeTourForUnbranded()`
   builds a new tour with `agent_card: {}`, a no-op `cta`, no `share_url`, no
   lat/lng, and the contact/booking/social keys deleted from the freeform
   `details` bag. Nothing branded exists to leak into markup, meta tags, or the
   inline `window.__CFG__`. The end-card CSS and the lead-form half of the
   engine are separate strings that are not even concatenated into the page.
3. **Self-checked at the edge.** Every `/u/` response runs
   `unbrandedSelfCheck()` — a forbidden-token list plus a check that none of
   *this tour's own* agent/CTA values appear in the HTML. On a hit the Worker
   **fails closed**: a neutral 503, never a leaking page. `/u/` 404s and 5xx
   use an unbranded notice page for the same reason.
4. **Gated in CI.** `npm test` (`scripts/check-unbranded.mjs`) renders the real
   renderer with sentinel-loaded branded fields and fails on any leak. It also
   asserts the **branded** page still has the agent card, the form and the
   Zillow link — otherwise the check would pass on an empty page.

```bash
npm run typecheck   # tsc --noEmit
npm test            # the unbranded (MLS-safe) gate
```

> **Deployment constraint:** the host rules ignore media-delivery URLs (any
> quoted string ending in an image/video extension), so an `R2_PUBLIC_BASE_URL`
> on a `rendprop.com` subdomain is fine. A media URL **without** a file
> extension on that domain would fail the check and 503 the page.

---

## How the player gets its video

The tour JSON exposes two sources (both **zero-egress**), and the player's order is
part of the product:

- **`scrub_url` — PRIMARY.** The **all-intra R2 mp4** (every frame a keyframe) served
  over HTTP byte-range. Set directly as `video.src` with `preload="auto"`; because
  every frame is an I-frame, `currentTime` seeks are **frame-accurate**, which is what
  makes the scroll-scrub buttery. This is the crown jewel — never trade it away.
- **`hls_url` — FALLBACK ONLY.** Cloudflare Stream HLS (`…/manifest/video.m3u8`).
  Stream re-encodes with normal GOPs, so seeking **snaps to keyframes** and degrades
  the scrub. Used only when `scrub_url` is absent (or the mp4 errors before playback
  starts): **native HLS** on Safari/iOS, **hls.js** elsewhere (lazy-loaded from cdnjs,
  pinned `1.5.20` + SRI, big MSE buffers so seeks land inside the buffered range).
- `video_url` (= `scrub_url ?? hls_url`) is kept for back-compat; if a payload only
  has `video_url`, it's classified by `.m3u8` extension.

The `<video>` is `muted playsinline webkit-playsinline preload=auto` for reliable
inline autoplay-less scrubbing on iOS Safari.

> **Chapter timebase:** chapter `t_ms` is already rescaled to the rendered timeline by
> the app before publish (it divides by `speed_factor`). The player uses `t_ms/1000`
> against `duration_s` directly — it must **not** divide by `speed_factor` again.

The browser talks to Supabase **directly** for:
- **Lead form** → `POST ${SUPABASE_FUNCTIONS_URL}/leads` (`{slug,name,phone,email?,extra,_hp}`; honeypot + per-type fields).
- **View beacon** → `POST ${SUPABASE_FUNCTIONS_URL}/beacon/:slug` via `navigator.sendBeacon` (CORS-simple `text/plain`, `apikey` in the query string, so it fires reliably on `pagehide`). It counts one view + `streamed_minutes ≈ duration` at start, then batches `watch_ms` deltas + `max scroll_depth`.

The anon key is injected into the page (it's public by design — RLS enforces access, and it already ships in every Supabase client).

---

## Deploy

```bash
cd services/edge/tour-host
npm install

# 1. Point it at your Supabase project (edit wrangler.toml [vars], or use a secret):
#    SUPABASE_FUNCTIONS_URL = https://<project-ref>.supabase.co/functions/v1
wrangler secret put SUPABASE_ANON_KEY      # recommended over the plaintext var

# 2. Ship it
npm run deploy        # = wrangler deploy
```

### Route setup

`wrangler.toml` binds the Worker to the whole apex zone:

```toml
routes = [
  { pattern = "rendprop.com/*", zone_name = "rendprop.com" },
]
```

Requirements:
- `rendprop.com` must be an **active zone** on the same Cloudflare account (nameservers on Cloudflare).
- The Worker owns the whole apex. Requests that exactly match a file under `./public` (the marketing
  site, `/assets/*`, `robots.txt`, `sitemap.xml`, `llms.txt`) are served by Workers Static Assets
  before the script runs; `/f/*`, `/u/*`, `/a/*`, `/terms`, `/privacy`, `/healthz` and every unknown path
  land in `src/index.ts`, which always answers with a branded page (404/500 included).
- `workers_dev = false`: there is no `*.workers.dev` hostname in production (duplicate content +
  an un-branded URL). For a pre-DNS smoke test, temporarily set it to `true` and comment the
  `routes` block out.

### Crawl policy

`public/robots.txt` opens the marketing site to search engines and AI crawlers, but customer
tour pages (`/f/*`), the MLS-unbranded twin (`/u/*`) and portfolios (`/a/*`) are disallowed for
the AI-crawler user agents (they carry agents' names and phone numbers); only `/f/estate-demo`
stays open to them.

Ordinary search engines are handled **per page, not in robots.txt** (audit F-H-19): a tour ships
`<meta name="robots" content="noindex, nofollow">` unless its owner opted in — `allow_indexing`
(also `allowIndexing` / `search_indexing`) truthy in the listing's `details` or in the org's
brand kit. A crawler has to be able to *fetch* the page to read that tag, which is why `/f/` is
not `Disallow`ed for `*`. A non-opted-in tour sends `X-Robots-Tag: noindex, nofollow` as well as the meta tag, so a crawler
that never parses the body gets the same answer. `?embed=1` and `/u/*` are always `noindex`, and
every branded tour page carries a canonical link to its `share_url`.

### Checks

| Command | What it guards |
|---|---|
| `npm run typecheck` | `tsc --noEmit` |
| `npm run check:unbranded` | the MLS-safe `/u/<slug>` page: no sentinel, no branding, no form, no external link, and the required property content + AI disclosure still present. Also asserts the promo/indexing defaults from F-H-17/F-H-19 |
| `npm run check:routes` | malformed paths (`/f/%`) answer with a branded 404 not a 500, the global error boundary, `/u/` failing unbranded, HSTS, and the ordinary routes |
| `npm test` | both of the above |
| `npm run check:assets` | the demo media that is deliberately not in git is present and under the 25 MiB Static Assets cap (run via `npm run predeploy`) |

### Vars / secrets

| Name | Where | Notes |
|---|---|---|
| `SUPABASE_FUNCTIONS_URL` | `[vars]` | e.g. `https://<ref>.supabase.co/functions/v1` (no trailing slash needed) |
| `SUPABASE_ANON_KEY` | `[vars]` **or** `wrangler secret put` | public anon/publishable key; used as `apikey`/Bearer for the server read + browser lead/beacon |
| `TOUR_CACHE_TTL` | `[vars]` (optional) | edge cache seconds for rendered HTML; `0` disables; default `60` |

The upstream `tours`/`leads`/`beacon`/`portfolio` functions must be deployed **`--no-verify-jwt`** (they are, per `services/supabase/deploy-functions.sh`) so these anon-key calls pass the gateway.

---

## Local dev

```bash
npm run typecheck            # tsc --noEmit
npm run dev                  # wrangler dev  → http://localhost:8787/f/<slug>
```

`wrangler dev` proxies to your real Supabase functions (set the vars first). Bare `/`,
`/f`, `/a` redirect to the marketing site; `/healthz` returns `ok`.

---

## Caching & errors

- Published HTML is cached in the **Cache API** (`caches.default`) under a query-independent
  key (`/f/:slug`, `/a/:handle`) with `Cache-Control: public, max-age=<ttl>, s-maxage=<ttl>`.
  Republishing a tour is visible after at most `TOUR_CACHE_TTL` seconds.
- Unknown/invalid slug or upstream `404` → branded **404** page (short-cached).
- Upstream network/5xx → **502** page (`no-store`).
- `HEAD` is served (headers only); non-`GET`/`HEAD` → `405`.
- Security headers on every HTML response: `nosniff`, `Referrer-Policy`, and a CSP that
  allows inline styles/scripts (the player engine), hls.js from cdnjs, `blob:` media/workers
  (MSE), and `https:` `connect-src` (Supabase/Stream/R2).

---

## TODOs / dependencies

1. ~~`GET /portfolio/:handle` not implemented~~ — **live** (`services/supabase/functions/portfolio`,
   deployed `--no-verify-jwt`). Contract: `{ org, agent_card, tours: [{ slug, share_url,
   space_type, address, tagline, price, poster }] }`; the renderer stays defensive about extras.
2. ~~Scrub-over-HLS fidelity~~ — **resolved**: the tours function now returns `scrub_url`
   (all-intra R2 mp4, primary) + `hls_url` (fallback), and the player prefers `scrub_url`,
   attaching HLS only when there is no scrub source or the mp4 errors before start.
3. **Rate-limit / Turnstile** on `/leads` + `/beacon` is best-effort in the Supabase
   functions today (noted in their README). Add Cloudflare Turnstile to the lead form and a
   durable limiter before launch; this Worker is the natural place to verify the Turnstile token.
4. **`streamed_minutes`** is reported once as `≈ duration` per session (honest "delivery"
   accounting since the clip is downloaded once for scrubbing). Revisit if Stream billing
   should reflect re-buffered bytes.
