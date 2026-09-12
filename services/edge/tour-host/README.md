# Rendprop — tour-host (Cloudflare Worker)

Serves Rendprop's **public** pages at the edge:

| Route | Renders | Source |
|---|---|---|
| `GET /f/:slug` | the scroll-scrub **tour player** — branded | `GET ${SUPABASE_FUNCTIONS_URL}/tours/:slug` |
| `GET /u/:slug` | the **same tour, unbranded** — MLS-safe | the same payload |
| `GET /a/:handle` | an org's **portfolio grid** (cards → `/f/:slug`) | `GET ${SUPABASE_FUNCTIONS_URL}/portfolio/:handle` |
| `GET /sitemap.xml` | the crawl index — marketing + legal + the demo tour and portfolio | `src/sitemap.ts` (no upstream yet — see TODO 5) |

Each request is server-rendered to a **self-contained HTML page** (no build step, no
client framework). Customer pages check upstream on every request and return
`Cache-Control: no-store`; only synthetic demo HTML remains cacheable. The player is a port of the
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
| JSON-LD structured data | yes — **only when the owner opted that tour into indexing** | **no** |
| Share control (`navigator.share` / copy link) | yes | **no** |
| App Store CTA + `ct=` campaign, `?ref=` on outbound links | yes | **no** |
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
  site, `/assets/*`, `robots.txt`, `llms.txt`) are served by Workers Static Assets
  before the script runs; `/f/*`, `/u/*`, `/a/*`, `/terms`, `/privacy`, `/sitemap.xml`, `/healthz` and every
  unknown path land in `src/index.ts`, which always answers with a branded page (404/500 included).
  That precedence is why **`public/sitemap.xml` is deleted**: a file there wins over the route, so
  leaving it in place would make `src/sitemap.ts` unreachable. Do not re-add it.
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

**Structured data follows that same opt-in.** `src/jsonld.ts` emits one
`<script type="application/ld+json">` per page: on `/f/<slug>` only when `allowsIndexing(tour)`
is true (a `RealEstateListing` — or `EventVenue`/`Restaurant`/`Store`/`ExerciseGym`/`LocalBusiness`
per `space_type` — plus the space, a `VideoObject` for the flythrough, an `Offer` where there is a
price, the agent and a `BreadcrumbList`), and on `/a/<handle>` unconditionally (`ProfilePage` +
the agent + an `ItemList` mirroring the visible grid). **Never on `/u/*` or `?embed=1`** — it names
the agent, their phone and rendprop.com, so `unbrandedViolations()` lists `application/ld+json` and
fails an unbranded page closed if a guard is ever broken. Every field is dropped when there is no
real value for it; nothing is ever emitted as a placeholder.

`/a/<handle>` is **indexable by default** and `/f/<slug>` is not, on purpose: a portfolio is a
public profile at a handle its owner chose and publishing it *is* the opt-in, whereas a tour page
puts an owner's name, phone and email beside a specific street address.

### Acquisition attribution

Outbound links carry where they came from — see `src/attribution.ts`, which is the only place that
builds one:

- **App Store**: `?ct=<surface>&mt=8`, with `<surface>` one of `tour-<slug>`, `portfolio`, `site`.
  Shows up in App Store Connect → App Analytics → Acquisition → Sources, dimension *Campaign*.
  `pt` (the provider token) is **not in this repo** — it is an account-level value the owner has to
  copy out of App Store Connect into `APPLE_PROVIDER_TOKEN`; the links work without it and start
  filing under the Campaigns report once it is set. See the TODO in that file.
- **rendprop.com**: `?ref=tour` / `?ref=portfolio` on the "Made with Rendprop" links.
  `public/assets/site.js` deliberately does **not** read it — no cookie, no `localStorage`, no
  pixel, no third-party script. The privacy policy's "no third-party analytics SDK, no advertising
  SDK, no advertising identifier (IDFA), and no tracking pixel" stays literally true.

Neither parameter exists on `/u/*`: both are in `UNBRANDED_FORBIDDEN` and in the CI gate.

### Sharing

The branded tour page carries a small **Share** control over the stage (`#share`): `navigator.share`
where the browser has it, clipboard otherwise, with an explicit "Link copied" / "Press Ctrl+C"
state so a silent failure is impossible. It is a real `<button>` (tab + Enter/Space for free), makes
no network call and stores nothing. Absent from `/u/*` **and** from `?embed=1`, in the markup *and*
in the emitted script.

### Checks

| Command | What it guards |
|---|---|
| `npm run typecheck` | `tsc --noEmit` |
| `npm run check:unbranded` | the MLS-safe `/u/<slug>` page: no sentinel, no branding, no form, no external link, and the required property content + AI disclosure still present. Also asserts the promo/indexing defaults from F-H-17/F-H-19 |
| `npm run check:routes` | malformed paths (`/f/%`) answer with a branded 404 not a 500, the global error boundary, `/u/` failing unbranded, HSTS, customer revocation despite primed old caches, synthetic demo caching, and ordinary routes |
| `node scripts/check-upstream.mjs` | actual-handler upstream deadline, decoded-body cap, malformed/absent/unavailable classification, cancellation, generic branded and MLS-neutral failures; synthetic offline inputs only |
| `npm test` | unbranded, route and upstream gates |
| `npm run check:assets` | the demo media that is deliberately not in git is present and under the 25 MiB Static Assets cap (run via `npm run predeploy`) |

### Vars / secrets

| Name | Where | Notes |
|---|---|---|
| `SUPABASE_FUNCTIONS_URL` | `[vars]` | e.g. `https://<ref>.supabase.co/functions/v1` (no trailing slash needed) |
| `SUPABASE_ANON_KEY` | `[vars]` **or** `wrangler secret put` | public anon/publishable key; used as `apikey`/Bearer for the server read + browser lead/beacon |
| `TOUR_CACHE_TTL` | `[vars]` (optional) | edge cache seconds for synthetic demo tour HTML only; `0` disables new demo writes; default `60`; customer HTML always bypasses caching |

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

- Customer `/f/:slug`, `/u/:slug` and `/a/:handle` HTML bypasses **all Cache API reads
  and writes**, including entries written by an older deployment. Each request reaching
  this Worker checks upstream and returns `Cache-Control: no-store`, so a stale edge
  page cannot override the upstream publication state.
- Explicit synthetic demo tour slugs (`estate-demo`, `demo`) retain their existing
  Cache API keys, embed variants and `public, max-age=<ttl>, s-maxage=<ttl>` policy.
  Fictional portfolio handles (`meridian`, `demo`) keep `public, max-age=300`.
- Unknown/invalid customer slug or upstream `404` → branded **404** page with
  `no-store`; `/u/` keeps its neutral MLS-safe notice instead of branded content.
- Tour and portfolio upstream network/read/deadline failures, 429 and 5xx →
  **503** (`no-store`). Invalid JSON/UTF-8, invalid required renderer shape,
  oversized responses and other bad upstream statuses → **502** (`no-store`).
  Only an actual upstream 404 is reported as missing. Errors retain branded
  pages on `/f/` and `/a/`, neutral MLS-safe notices on `/u/`.
- One **8-second** timer covers fetching headers and reading the response body.
  The reader caps decoded JSON at **4 MiB**, checking every chunk before retaining
  it, independent of `Content-Length`, and refuses more than 64 consecutive empty
  chunks. It aborts/cancels failures without waiting indefinitely for cancellation.
  Redirects are not followed and there are no retries. These are operational
  budgets, not a provider SLA: freeform metadata/portfolio size is not fully bounded
  upstream, so an over-cap response is refused rather than silently truncated.
  Timers cannot preempt synchronous JSON parsing or rendering; this is not a total
  Worker CPU/RSS/latency guarantee. Browser lead-form deadlines are separate work.
- This is not retroactive erasure: browser/intermediary HTML cached before rollout
  can remain until its old freshness period expires, and already-open pages,
  downloads, search-engine copies and previously issued media URLs are not revoked
  by this change. Deployment cache rules, upstream publication enforcement and media
  access policy need separate validation. No cache purge is required for the Worker's
  own customer cache bypass to work, and none was performed by this patch.
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
5. **`GET /tours/index` does not exist**, so `/sitemap.xml` lists only what this Worker can know
   on its own: the marketing pages, the legal pages, `/f/estate-demo` and `/a/meridian`. Nothing in
   `services/supabase/functions` can enumerate published tours — `tours/` answers one slug and
   `portfolio/` answers one handle. The exact shape the sitemap needs (slug, `published_at`, the
   **server-resolved** `allow_indexing`, the org handle, a cursor) is specified at the top of
   `src/sitemap.ts`; `sitemapXml()` already takes it. Until it ships, no tour of a real customer is
   in the sitemap — which is correct, not a gap to paper over: an entry is a *request to index*, and
   only the owner's opt-in may put one there.
6. **`APPLE_PROVIDER_TOKEN` is empty** (`src/attribution.ts`). Campaign tokens ride on every App
   Store link already; `pt` is what files them under this provider in App Store Connect's Campaigns
   report. One paste, no code change.
