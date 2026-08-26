# Rendprop — tour-host (Cloudflare Worker)

Serves Rendprop's **public** pages at the edge:

| Route | Renders | Source |
|---|---|---|
| `GET /f/:slug` | the scroll-scrub **tour player** | `GET ${SUPABASE_FUNCTIONS_URL}/tours/:slug` |
| `GET /a/:handle` | an org's **portfolio grid** (cards → `/f/:slug`) | `GET ${SUPABASE_FUNCTIONS_URL}/portfolio/:handle` |

Each request is server-rendered to a **self-contained HTML page** (no build step, no
client framework) and cached at the edge with a short TTL. The player is a port of the
proven iOS webview player (`apps/ios/Rendprop/Resources/player/index.html`) — same
rAF-lerp scrub loop, buffer gate, chapter rail, room label, jank watchdog and autoplay
fallback — adapted to stream its video instead of bundling a demo file.

This is the component from `docs/BACKEND-ARCHITECTURE.md` §1.5 / step 7.

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

`wrangler.toml` binds two routes on the apex zone:

```toml
routes = [
  { pattern = "rendprop.com/f/*", zone_name = "rendprop.com" },
  { pattern = "rendprop.com/a/*", zone_name = "rendprop.com" },
]
```

Requirements:
- `rendprop.com` must be an **active zone** on the same Cloudflare account (nameservers on Cloudflare).
- The tour-host owns **only** `/f/*` and `/a/*`; the marketing site keeps everything else. If the apex is served by Pages/another Worker, these routes take precedence for their prefixes.
- First deploy without custom routes? It's also on `https://rendprop-tour-host.<subdomain>.workers.dev` (`workers_dev = true`).

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
