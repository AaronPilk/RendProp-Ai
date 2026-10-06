# Rendprop — tour-host (Cloudflare Worker)

The [6 October launch candidate](../../../docs/handoff/LAUNCH-READINESS-20261006.md)
records the current source contracts and staged rollout gates. The new member
portfolio and protected media routes below are candidate behavior; this document
is not a deployment or public-domain cutover receipt. Earlier delivery snapshots
retain their dated evidence.

The [2 October beta feedback release](../../../docs/handoff/BETA-POLISH-20261002.md)
is live at **100%** on Worker `0d5db590-c2c8-4482-9f3f-77bcf893fcd6`, deployed
at **17:15:45 UTC** from runtime `3615a23`. Selected main photos lead the listing;
compact navigation opens an isolated **Explore** scroll viewer, with **Play video**
for ordinary playback. Closing unloads the decoder and returns to the listing.
All 12 CI jobs passed; four live branded/MLS HTML readbacks match the frozen engine
and CSS, separately from 195 actual-browser assertions using generated local video.
HTML readback does not establish every remote Worker bundle byte or real-phone
playback quality. Routes, variables, secrets and compatibility date are preserved.
See the [delivery receipt](../../../docs/releases/TESTFLIGHT-41-20261002.json).

[Photographer client delivery](../../../docs/studio/photographer-client-delivery.md)
adds explicit `client_mode` and `hide_rendprop_branding` payload flags. Only two
boolean `true` values suppress vendor attribution, promotions, app banners,
favicon and player wordmarks. Client cards and lead forms remain; client pages
never link to the photographer's portfolio. Required property alterations,
original-photo access and privacy links remain. `/u/` retains its existing
contact-free MLS behavior. Worker `4ad3ab1c-0709-442b-bbf9-6426a5fb0bb2` was the
preceding deployment. Its live marketing/MLS demo engine and CSS readbacks matched
the release source; all 12 CI jobs pass. See the
[release handoff](../../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md).
Actual client listing publication and inbox acceptance remain controlled owner tests.

The [1 October listing-first release](../../../docs/handoff/LISTING-FIRST-FLYTHROUGH-20261001.md)
was deployed at 100% traffic on Worker version
`8268c7a9-aad9-43a7-89ac-f1769e75896b`, from source `a87834c`; the subsequent
client-delivery deployment superseded that historical version. Its final production
readback passed 153 assertions on branded/unbranded listings, with photos/details
first and opt-in playback. All 12 CI jobs passed on that exact web source.
Home, pricing, legal and health pages retained their verified normalized bodies
and stable security headers, including the [core release](../../../docs/handoff/CORE-READINESS-20261001.md)'s
subscription-confirmation wording. Routes, bindings and compatibility date are
unchanged. See the [delivery receipt](../../../docs/releases/TESTFLIGHT-37-20261001.json).


Serves Rendprop's public marketing, tour and portfolio pages, plus the spatial
viewer shell and permission-checked artifact proxy. This is separate from the
[Studio static Worker](../../../apps/studio/README.md). Studio's
[24 September release](../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
updated its website and Supabase read handlers; it does not establish a new
tour-host deployment version.

Current pricing, structured data and terms describe a seven-day introductory
trial only after confirmation of an eligible Apple subscription in the iPhone
app. Downloading or signing in does not activate a trial. Prices and plan
allowances are unchanged. Source-copy updates require a new Worker/static-asset
deployment; this README alone does not establish that the live site changed.

Routes implemented in the current source:

| Route | Renders | Source |
|---|---|---|
| `GET /f/:slug` | listing details/photos with an optional fly-through — branded | `GET ${SUPABASE_FUNCTIONS_URL}/tours/:slug` |
| `GET /u/:slug` | the same listing/player, unbranded — for the MLS field | the same payload |
| `GET /a/:handle` | a member's deliberately selected owned-listing portfolio (cards → `/f/:slug`); legacy org handles return an empty grid in the candidate | `GET ${SUPABASE_FUNCTIONS_URL}/portfolio/:handle` |
| `GET/HEAD /media/:slug/r2/:key` | exact selected R2 object; `key` is URL-encoded | `GET ${SUPABASE_FUNCTIONS_URL}/tours/:slug/delivery` before bytes/conditional responses |
| `GET/HEAD /media/:slug/stream/:uid[/path]` | protected Stream proxy contract; remains unavailable until separate signed-playback acceptance | the same fresh delivery authority |
| `GET/HEAD /media-brand/renders/:listing/brand/:file` | exact approved business-logo object | scoped `tours/business-logo/:listing` authority |
| `GET /.well-known/security.txt` | expiring public security contact | Worker source; live routing/readback remains required |
| `GET /studio` | redirect to `https://studio.rendprop.com/` | Studio has its own Worker |
| `GET /s/:scene` | spatial viewer shell | `src/spatial.ts` |
| `GET /s/:scene/manifest`, `GET /s/:scene/model` | permission-checked spatial artifacts | Supabase `spatial` handler; no edge cache |
| `GET /join/:code` | team invitation landing | native universal-link handoff |
| `GET /terms`, `GET /privacy`, `GET /healthz` | legal pages and health check | Worker source |
| `GET /sitemap.xml` | the crawl index — marketing + legal + the demo tour and portfolio | `src/sitemap.ts` (no upstream yet — see TODO 5) |

Candidate media routes recheck the current selected object, publication, deletion
and hosting authority before GET, HEAD, Range, conditional responses and bytes.
They emit no-store cache directives. Legacy public R2 ingress must remain enabled
until the separately verified proxy/reader flag and old-domain cutover. Source
implementation alone does not establish that an old URL is withdrawn.

Tour and portfolio requests render HTML without a client framework; Wrangler
bundles the TypeScript Worker at deployment. The spatial viewer additionally loads
its dedicated browser module and runtime assets. Customer pages check upstream
on every request and return `Cache-Control: no-store`; only synthetic demo HTML
remains cacheable. The next release's source opens with the selected property
photo, followed by the address, price and details. `cover_url` is resolved and
visibility-checked by the backend; ordered gallery photos precede the video
poster when there is no selected cover. An explicit empty `gallery` stays empty,
while a missing legacy field may use editorial photos. Photos, rooms, floor plan
and contact navigation scroll independently of video. **Watch fly-through**
opens one dialog in **Explore** mode: scrolling stays inside the video viewer,
with a keyboard-accessible Tour position control. **Play video** switches the
same source to normal playback with sound. **Back to listing** stops decoding
and loading and restores the previous scroll position and focus. No video request
or view beacon occurs before the visitor opens the viewer. `?embed=1` retains
the legacy scroll-driven player, which the native bundled preview also uses.

See [backend architecture](../../../docs/BACKEND-ARCHITECTURE.md) and
[the spatial API](../../supabase/functions/spatial/README.md) for upstream contracts.

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
| Robots | noindex by default; owner opt-in for indexing, self-canonical | `noindex` meta **and** `X-Robots-Tag`, never in the sitemap |
| View beacon | counted | counted, with `unbranded: true` |
| Lead events | fired | never |
| CSP | `frame-ancestors 'self'`, Turnstile allowed | `form-action 'none'`, `frame-ancestors *` (MLS systems iframe it) |

Use `/u/` for an unbranded tour field and `/f/` for the agent's branded sharing
link. The renderer removes agent/contact/promotional content from the unbranded
page; this is not a guarantee that every MLS accepts all submitted property
content. Check the applicable listing service's rules before distribution.

### How unbranded output is enforced

1. **One renderer, no fork.** `renderTourPage(tour, …, { unbranded: true })`.
   Both variants use the same renderer so fixes do not drift between copies.
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
npm test            # unbranded, routes, upstream, lead form, legal, spatial and bundle checks
node scripts/check-listing-browser.mjs # real Chromium + FFmpeg, opt-in playback and cleanup
```

> **Deployment constraint:** the host rules ignore media-delivery URLs (any
> quoted string ending in an image/video extension), so an `R2_PUBLIC_BASE_URL`
> on a `rendprop.com` subdomain is fine. A media URL **without** a file
> extension on that domain would fail the check and 503 the page.

---

## How the player gets its video

The tour JSON exposes two video sources, in this preference order:

- **`scrub_url` — primary.** The published all-intra R2 MP4 is served over HTTP
  byte-range, without a browser re-encode or resolution cap. On normal pages the
  video has `preload="none"` and no source until an explicit open. Closing removes
  the source, pauses playback and empties the decoder. Explore seeks the paused
  timeline; Play video exposes native play/pause, seeking and fullscreen. Room
  buttons seek the same rendered timeline in either mode.
- **`hls_url` — fallback.** Cloudflare Stream HLS is used when the MP4 is absent
  or fails. Safari uses native HLS; other supported browsers lazily load pinned
  hls.js `1.5.20` with SRI. The normal player uses bounded 30/60-second forward
  buffers, a 30-second back buffer, and no player-size quality cap. Network and
  decoder capabilities still determine adaptive quality.
- `video_url` remains compatible: a payload with only this field is classified
  by its `.m3u8` extension.

The player shows the actual decoded dimensions and whether it is playing the
published master or streaming. A larger player cannot restore detail absent
from an existing 720p file. The [listing-first/HD release](../../../docs/handoff/LISTING-FIRST-FLYTHROUGH-20261001.md)
changes new native and optional-worker renders to a maximum 1920-pixel long edge
and a 24 Mbps target, without upscaling. Re-rendering from the original and
publishing creates a **new sharing link**; older links keep their earlier video.
The explicit legacy embed continues its muted scroll-driven loading behavior.

**Chapter timebase:** `t_ms` is already rescaled to the rendered timeline by
publication. Both players use `t_ms/1000` directly, without dividing by
`speed_factor` again.

The browser talks directly to Supabase for the existing lead form and view
beacon. The normal player's beacon starts after a frame has decoded in the opened
viewer, then batches visible playback or recent Explore interaction time and
delivered buffered seconds. Merely reading
a listing does not count as a video view. `scroll_depth` retains its transport
field name but represents maximum video progress in the normal player.
Unbranded pages omit the form and agent/contact content and mark video beacons
unbranded. The legacy embed retains its scroll-playback metering.

The anon key is injected into the page (it's public by design — RLS enforces access, and it already ships in every Supabase client).

---

## Deploy

```bash
cd services/edge/tour-host
npm ci

# 1. Point it at your Supabase project (edit wrangler.toml [vars], or use a secret):
#    SUPABASE_FUNCTIONS_URL = https://<project-ref>.supabase.co/functions/v1
npx wrangler secret put SUPABASE_ANON_KEY      # recommended over the plaintext var

# 2. Ship it
npm run deploy        # = wrangler deploy
```

### Route setup

`wrangler.toml` binds the Worker to the whole apex zone:

```toml
routes = [
  { pattern = "rendprop.com/*", zone_name = "rendprop.com" },
  { pattern = "www.rendprop.com/*", zone_name = "rendprop.com" },
]
```

Requirements:
- `rendprop.com` must be an **active zone** on the same Cloudflare account (nameservers on Cloudflare).
- The Worker owns the whole apex. Requests that exactly match a file under `./public` (the marketing
  site, `/assets/*`, `robots.txt`, `llms.txt`) are served by Workers Static Assets
  before the script runs; `/f/*`, `/u/*`, `/a/*`, `/terms`, `/privacy`, `/sitemap.xml`, `/healthz` and every
  unknown path land in `src/index.ts`; tour errors preserve the branded or
  unbranded variant, while spatial data endpoints return their own bounded errors.
  That precedence is why **`public/sitemap.xml` is deleted**: a file there wins over the route, so
  leaving it in place would make `src/sitemap.ts` unreachable. Do not re-add it.
- `workers_dev = false`: there is no `*.workers.dev` hostname in production (duplicate content +
  an un-branded URL). For a pre-DNS smoke test, temporarily set it to `true` and comment the
  `routes` block out.

### Crawl policy

[public/robots.txt](public/robots.txt) configures the marketing site for search engines and AI crawlers, but customer
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
| `npm test` | unbranded, routes, upstream, lead-form, legal, spatial and bundled-runtime gates |
| `npm run check:spatial` / `npm run check:bundle` | spatial viewer contracts and the actual bundled decoder/runtime output |
| `npm run check:assets` | the demo media that is deliberately not in git is present and under the 25 MiB Static Assets cap (run via `npm run predeploy`) |

### Vars / secrets

| Name | Where | Notes |
|---|---|---|
| `SUPABASE_FUNCTIONS_URL` | `[vars]` | e.g. `https://<ref>.supabase.co/functions/v1` (no trailing slash needed) |
| `SUPABASE_ANON_KEY` | `[vars]` **or** `wrangler secret put` | public legacy anon JWT used as `apikey`/Bearer for server reads and browser lead/beacon; never a service-role key |
| `TURNSTILE_SITE_KEY` | `[vars]` | public widget key; matching secret is verified by the Supabase `leads` handler |
| `TOUR_CACHE_TTL` | `[vars]` (optional) | edge cache seconds for synthetic demo tour HTML only; `0` disables new demo writes; default `60`; customer HTML always bypasses caching |

Preserve each upstream function's existing gateway setting. The 24 September
release has `tours` JWT verification **on** and `portfolio` **off**; public tour
reads pass a legacy anon JWT from the Worker, while handlers restrict results to
published, visible data. Do not use the older all-functions deploy helper to
normalize those flags. Verify upstream access with the actual configured key;
opaque publishable keys are not interchangeable with JWT bearer tokens.

---

## Local dev

```bash
npm run typecheck            # tsc --noEmit
npm run dev                  # wrangler dev  → http://localhost:8787/f/<slug>
```

`wrangler dev` uses the configured Supabase functions for non-demo requests; use
a fixture/test project when developing write-capable flows such as lead capture.
`/` serves the marketing page, bare `/f`, `/u` and `/a` redirect there, and
`/healthz` returns `ok`.

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
  Worker CPU/RSS/latency guarantee. The browser lead form has its own bounded
  submission deadline and does not automatically retry an uncertain submission.
- This is not retroactive erasure: browser/intermediary HTML cached before rollout
  can remain until its old freshness period expires, and already-open pages,
  downloads, search-engine copies and previously issued media URLs are not revoked
  by this change. Deployment cache rules, upstream publication enforcement and media
  access policy need separate validation. No cache purge is required for the Worker's
  own customer cache bypass to work, and none was performed by this patch.
- `HEAD` is served (headers only); non-`GET`/`HEAD` → `405`.
- Tour/portfolio HTML uses `nosniff`, `Referrer-Policy`, and a CSP that
  allows inline styles/scripts (the player engine), hls.js from cdnjs, `blob:` media/workers
  (MSE), and `https:` `connect-src` (Supabase/Stream/R2). Spatial viewer/data routes
  use their dedicated stricter headers and permission checks in `src/spatial.ts`.

---

## TODOs / dependencies

1. ~~`GET /portfolio/:handle` not implemented~~ — **live** (`services/supabase/functions/portfolio`,
   deployed `--no-verify-jwt`). Contract: `{ org, agent_card, tours: [{ slug, share_url,
   space_type, address, tagline, price, poster }] }`; the renderer stays defensive about extras.
2. ~~Scrub-over-HLS fidelity~~ — **resolved**: the tours function now returns `scrub_url`
   (all-intra R2 mp4, primary) + `hls_url` (fallback), and the player prefers `scrub_url`,
   attaching HLS only when there is no scrub source or the mp4 errors before start.
3. **Lead protection is implemented.** The form includes the configured Turnstile
   widget; the Supabase `leads` handler validates the token and applies a durable
   rate limit. Missing server configuration fails closed unless explicitly opted
   out. The public site key in Wrangler does not prove the server secret or live
   delivery works; see [the leads API](../../supabase/functions/leads/README.md).
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
6. **`APPLE_PROVIDER_TOKEN` is an empty source constant** (`src/attribution.ts`). Campaign tokens ride on every App
   Store link already; `pt` is what files them under this provider in App Store Connect's Campaigns
   report. The owner must supply its value before changing the source; this README
   refresh does not access App Store Connect.
