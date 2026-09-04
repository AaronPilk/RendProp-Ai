# Report — W1-F (tour-host Worker · render worker · AI pipeline · web player)

Scope owned: `services/edge/tour-host/**`, `services/worker/**`, `services/pipeline/**`,
`apps/web/player/**`. Nothing outside those paths was edited. Nothing was deployed.

## 1. Changes by file

### services/edge/tour-host (Cloudflare Worker, TypeScript)

**`src/index.ts`**
- `safeDecode()` (l.86): `decodeURIComponent` wrapped; a malformed escape (`/f/%`, `/a/%E0%A4%A`) now
  answers the branded 404 (tour) / portfolio-unavailable page instead of throwing (F-H-11).
- Handler split into `route()` (l.209) + `export default.fetch` (l.258) which wraps everything in
  try/catch → `errorPage()` **500** with `Cache-Control: no-store` (+ `console.error` of the stack).
  A viewer can no longer see Cloudflare's raw "Worker threw exception" page.
- Unknown paths → `notFoundPage("page")` ("There's nothing at this address") instead of "tour not found".
- Header comment rewritten (the Worker owns `rendprop.com/*`; Static Assets serve `./public` first).

**`src/types.ts`** — `Tour` gains `sold_at?`, `status?`, `sold?`, `archived?`, `published_at?`;
`TourListing` gains `sold_at?`, `status?` (W1-E's tours function returns them top-level AND nested;
the renderer reads both). Doc comments: `address` = business NAME for non-RE; `beds/baths/sqft`/`price_cents` 0 = unknown.

**`src/html.ts`**
- `looksLikeEmail()` (l.70), `absolutize()` (l.76).
- `extractAgent()` (l.203): name/title/company go through `displayName()` → an email-looking value
  becomes "" (defence in depth under decision A14); new `title` field; photo keys now include
  `headshot_url` / `logo_url` first (the keys `PATCH /me/brand` allow-lists) and the photo is
  `safeUrl`-checked once here for both pages.
- `notFoundPage(kind)` / `errorPage(kind)` (l.290/309) for tour vs generic-page copy.

**`src/player.ts`** (rewritten; canonical engine declared in the header)
- Explicit **video-unavailable state**: `#unavail` panel ("This tour's video isn't available right
  now", Try-again button) shown by `showUnavailable()` (l.673) — on `video.error` with no HLS fallback
  left, when neither source URL exists, and by the 12 s last resort when `readyState === 0`
  (`lastResort()` l.715: dead source → unavailable now; still-loading source gets one more 12 s).
  In that state `begin()` never runs, the scrub track collapses to one viewport, the hint hides, and
  **no view / streamed-minutes beacon is sent** (`reportViewAndDelivery` is now called from the first
  `tick()` with `readyState >= 2`, not from `begin()`; pagehide/visibility beacons are gated on `viewSent`).
- `sizeTrack()` called at setup from `CFG.durationS`, so the scroll math never sees a 0-height track.
- Engine parity with the iOS copy (F-H-07): decaying jank watchdog (`gap > 90 && gap < 1000` → count,
  smooth frames decrement) in `tick()` (l.638), `Math.max(1, total)`, `video.readyState > 0` before
  seeking, rail tap clamped to `[0,1]`, `meter()` (+ view report) inside `loopTick` after fallback.
- hls.js fallback tracked via `hlsJs`; a fatal non-recoverable hls error → native attempt → error → unavailable.
- **SOLD / Archived** (A17, B4): `isSoldOrArchived()` (l.67) reads `sold`/`archived`/`sold_at`/`status`.
  Chip pill "Sold"/"Archived", page title "(Sold)", og:title "— Sold", og:description prefixed, overview
  eyebrow tag + note; real estate: financing block hidden and the CTA becomes the **"Ask about similar
  homes"** lead form (name/phone/email + "What are you looking for?"); other types keep their CTA and show "Archived".
- **Lead form** (F-H-06): `novalidate` removed; real `<label>`s on every field (optional ones marked);
  `maxlength` = server caps (120/40/200); client validation mirrors the server regexes
  (`validate()` l.804: phone `/^[+()\d\s.-]{7,40}$/`, email `/^[^\s@]+@[^\s@]+\.[^\s@]+$/`) with inline
  `.err` slots + `aria-invalid` + focus; on `!res.ok` the server's `{error}` message is shown in a form-level
  `#leadmsg` (429 → "Too many requests…"; 403 shows the Turnstile message), no `alert()`;
  `turnstile.reset()` on every failure (l.821/864). Confirmation copy only promises what exists
  ("your request is with the agent"). A one-line privacy notice + `/privacy` link sits under the button.
- **Deep-link CTAs keep the form** (F-H-12): `renderCtaBlock()` (l.400) renders the deep-link button,
  an "or" divider, then the lead form whenever `lead_fields` is non-empty; on success the page tries
  `window.open(handoffUrl)` and the confirmation card carries a "Continue"/"Book now" button
  (form → then hand off). Retail's email-only opt-in renders as "Get deals and updates / Sign me up"
  regardless of `cta.label` (masks the "Get directions" mislabel in cta.ts) and never hands off to the shop.
  Fitness free-trial flow (`lead_form` + "Book now" secondary) hands off to the booking URL after submit.
- **Per-industry detail sections** (F-H-03b): `industryBlock()` (l.1167) / `renderIndustrySection()`
  (l.1271) render the camelCase keys the app sends, in the spec's customer-info order — venue: starting
  price, capacity ("Seats 220 · 350 standing"), setting, catering, event-type + amenity chips,
  "Check availability"; restaurant: cuisine · price range, hours, phone (tel), feature chips,
  "Reserve a table" / "View menu"; retail: weekly-special banner, store type, hours, phone, how-to-shop +
  department chips, "Shop online"; fitness: free-trial banner, facility, membership "/mo", day pass,
  24/7 or hours, amenity chips, "Book a session"; other: hours, phone, "Visit website". All escaped; URL
  fields via `safeUrl` (a `javascript:` menu URL is dropped — verified); money values formatted from the
  app's integer-dollar strings; "Get directions" (lat/lng, else name) and "Call" buttons.
- Non-RE title = business name (`address`), tagline = meta line / og:description (F-H-13);
  0 beds/baths/sqft and $0 never render (A4; also on the portfolio card).
- `<link rel="canonical" href="{share_url}">` on every tour; `<meta name="robots" content="noindex">` on `?embed=1` (F-H-19).
- "Your agent" fallback only for real estate; business pages fall back to the brand company, then the
  business name, else omit the line (F-H-21); `agent_card.title` rendered under the name.
- Gallery `alt` double-escape fixed (`headingRaw`); dead `RenderOpts.demo` / `CFG.demo` branch removed.
- Poster/scrub/hls/share URLs all pass through `safeUrl`.

**`src/portfolio.ts`** — photo via `extractAgent` (scheme-checked) and `absolutize()`d for `og:image`;
card posters `safeUrl`; name never an email (falls back to company → org name (if not an email) →
"Portfolio"); 0-valued beds/price skipped; `title` line rendered.

**`src/legal.ts`** — effective date **September 3, 2026**. Privacy §1 adds: listing location
(address/business name + rounded coordinate published on the tour page; device approximate location
only on request), leads stored for the owner's Leads inbox **and passed to GoHighLevel/LeadConnector**,
per-visit viewer engagement telemetry (start, watch time, scroll depth) + IP used briefly as a rate-limit
key, Turnstile; §2 wording; §3 table adds GoHighLevel and Turnstile; lede updated. Terms §6 rewritten:
subscription plans published at rendprop.com/pricing, **no in-app purchases**, plans set up/changed/
cancelled through rendprop.com (early access: by arrangement), nothing charged until a plan is agreed,
tours stay live through the paid period.

**`public/robots.txt`** — every AI-crawler group (GPTBot, OAI-SearchBot, ChatGPT-User, ClaudeBot,
Claude-User, Claude-SearchBot, anthropic-ai, PerplexityBot, Perplexity-User, Google-Extended,
Applebot-Extended, CCBot, Bytespider, meta-externalagent) gets `Allow: /f/estate-demo`,
`Disallow: /f/`, `Disallow: /a/`, `Allow: /`. `User-agent: *` unchanged (search engines still index tours).

**`public/_headers`** — `/assets/*` stays immutable for images; `site.css`, `site.js` get
`! Cache-Control` + `public, max-age=3600, stale-while-revalidate=86400`; the two demo mp4s get
`max-age=86400, stale-while-revalidate=604800` (F-H-14). Picked the header rule over fingerprinting
(no build step exists to rewrite the four HTML files).

**Marketing copy truth (`index.html`, `features.html`, `pricing.html`, `compare.html`, `llms.txt`)**
- Portfolio page / handle: every mention removed (JSON-LD featureList, bullets, `rendprop.com/a/your-name`
  pill → `rendprop.com/f/your-listing`, Pro tier bullet, "4K tours and a portfolio" tier line). No "coming soon".
- "delivered to you" / "lands with you" / "straight to you" → "captured in your Leads inbox in the app".
- "your face, your name, your number" → "your card: your name, your brokerage, your number";
  features "name, photo, number" → "name, brokerage, number, accent color".
- Aerials: "generated from the property's address" → "AI-generated from your exterior photo … an AI
  illustration, not real drone footage"; chips/labels say "AI aerial".
- "Builders & construction" → "Other spaces" (card, chips, JSON-LD, meta description, llms industries).
- "single-property website … story, gallery, reel, features, floor plan" → what a real tour renders
  (flythrough, the details you entered, chapters, payment estimate for homes, your card, booking form);
  the demo is described as "a fully dressed example". Section eyebrows/headings updated; compare table row renamed.
- "View tracking" bullets removed (no read API/UI); mock card stats now Tours / Leads / Sold.
- "Instant playback … no buffering wheel" → "Fast playback … short pre-load".
- "Auto captions" / "captioned reels" → address card only (captions unverified per F-H-16).
- **4K**: both engines encode ≤1280 long edge (RenderEngine.swift l.64, ffmpeg_render), so every "4K"
  claim was softened to "60 fps / every frame a keyframe" (index f-card, chips, step 2, compare table +
  lede + chip, features drone-render bullets + phone mock, pricing tier lines + JSON-LD offers + math table,
  llms). **Pricing numbers unchanged** (1/10/1 · 8/150/8/2 · 25/300/20/6 · 80/600/40/15+2+3 seats; $49/$99/$249; add-on prices).
- Pro tier bullets "Portfolio page" + "Priority rendering queue" (unbuilt) replaced with true bullets
  (unlimited links/leads, floor plans, "Everything in Solo, three times over"). Team "3 seats with shared
  listings · extra seats available" → "3 seats on the plan — set up by the Rendprop team during early access".
- Billing copy aligned with Terms §6: no "card required", no "cancel in two taps inside the app", no
  "the app tells you before anything is charged"; now "plans are set up and managed on rendprop.com,
  never inside the app; nothing charged until you confirm a plan; add-ons arranged through rendprop.com".
- Roll-over FAQ now states the real windows: renders reset with the calendar month; photo edits, clips,
  aerials rolling 30-day.
- index.html JSON-LD FAQ synced with the visible FAQ (dropped the invisible "What does Rendprop cost?",
  added "Who owns my footage and photos?"); page `<title>` shortened.
- `sitemap.xml` lastmod → 2026-09-03. README/DEPLOY: routes (`rendprop.com/*`, `workers_dev = false`),
  crawl policy, platform-coupled `node_modules` note.

### services/worker (Python)

**`settings.py`** — `parse_env_line()` (l.31): `export` prefix, quoted values, inline `# comment`
stripping (a `#` preceded by whitespace; `a#b` kept); `_int/_float` print a ⚠ instead of silently
defaulting. `tonemap_hdr` default **True** (auto: applied only when the probe says HDR).

**`enhance_bridge.py`** — `normalize_style()` (l.53: `as_is/as-is/asis/none/null/original/off/""` → no
restage; unknown → problem string; prefers the pipeline's `STYLES` when importable), `wants_enhancement()`
(l.72); `run_enhancement()` normalises first and returns `skipped: unknown style …`; after a pipeline
exception it harvests `manifest.json` (`_read_manifest` l.235) so already-paid stills are persisted
(`reason="partial: …"`); `staged` requires at least one surviving still; docstring schema drift fixed.

**`worker.py`** — `wants_enhancement(enhancements)` gate (l.227) replaces the truthy-`style` check
(F-G-02); `_skip_reason()` (l.146: bucket ≠ uploads / not uploaded / not video) → `db.release_job()`
(l.195) instead of failing; `process_specific` checks the asset **before** claiming; Stream readiness-poll
timeout keeps the UID (F-G-17).

**`db.py`** — `_request()` (l.79) maps `requests.RequestException` → `DBError` for every verb (F-G-06);
claim query `select=*,capture_assets!inner(bucket,uploaded,kind)` + `bucket=eq.uploads`, `uploaded=is.true`,
`kind=eq.video` (l.120–135, F-G-13); `release_job()` (l.154, conditional on `status=eq.processing`);
`fail_job()` conditional on `status=eq.processing`, logs when 0 rows matched (never overwrites `ready`);
`fetch_asset` selects `bucket, uploaded`; `insert_render` distinguishes `renders_slug_key` (new slug) from
`uq_renders_job` (PATCH the existing row's media in place, same slug) (F-G-14); docstring schema fixed.

**`stream.py`** — `_request()` (l.47) maps transport errors → `StreamError`; all three call sites rewired.

**`ffmpeg_render.py`** (rewritten) — `probe_source()` (l.122) returns duration + `pix_fmt`,
`color_transfer/primaries/space`; `SourceInfo.is_hdr` (PQ/HLG transfer, or bt2020 + 10-bit);
`hdr_tonemap_chain()` (l.181) inserts `zscale(tin/pin/min explicit)=linear → gbrpf32le → zscale p=bt709 →
tonemap hable → zscale bt709 tv` **only** for HDR sources, only when `TONEMAP_HDR` and the build has
zscale+tonemap (else warns and re-tags); scale now precedes `fps=`; redundant `-r` dropped;
`threading.Timer` watchdog (l.299) kills the whole process group (`start_new_session=True`,
`os.killpg`) at `FFMPEG_TIMEOUT_S` regardless of stdout (F-G-04); poster at ~12 % but ≥1 s and never in
the last 0.5 s (F-G-23); ffprobe/ffmpeg start failures → `RenderError`.

**`README.md`** — HDR, chapters, bucket filter, style normalisation, direct_upload (not wired), poster,
timeouts, Modal timeout ≥ ffmpeg ceiling, idempotency TODO → heartbeat TODO, `rendprop.` schema mentions removed.
**`.env.example`** — schema comment fixed; `TONEMAP_HDR` documented as auto/on.

### services/pipeline (Python)

**`config.py`** — same `parse_env_line()` (F-G-11) and loud `_int/_float`; `NO_RESTAGE_STYLES`,
`normalize_style()` (raises on unknown), `style_prompt()` refuses unknown / no-restage styles (it used to
emit "restage this room in as_is style: as_is").
**`enhance.py`** — `_run`/`probe_source`/`extract_keyframe` carry timeouts (`FFPROBE_TIMEOUT_S`,
`FFMPEG_KEYFRAME_TIMEOUT_S`, l.125); `probe_source()` (l.143) + `keyframe_vf()` (l.180): keyframes are
downscaled to ≤1568 px and tone-mapped with the same conditional HDR chain; `extract_keyframe` raises
`FileNotFoundError` for a seek past EOF; `enhance_video` wraps each segment in `try/except _SEGMENT_ERRORS`
(l.286/310: ProviderError, ValueError, OSError, CalledProcessError, TimeoutExpired) → `{"status":"error",
"reason"}` and continues; manifest written incrementally (`_write_manifest` l.365); `segment_video`
suffixes duplicate chapter names (`Bedroom-2`) and drops chapters past EOF (F-G-16 partial).
**`providers/base.py`** — read timeouts (`TimeoutError`/`OSError`, not `URLError`) → `ProviderError` (l.84/100).
**`.env.example`** — guard lines without inline comments.

### apps/web/player
`index.html` — header comment marking it an archived prototype and naming the canonical engines
(deletion not chosen: `README.md`, `apps/ios/README.md`, two build prompts and `docs/context/*` reference
the path). `README.md` rewritten: archived status, table of the three copies, "do not fix bugs here".

## 2. Checks run

- `npm ci --ignore-scripts` (temporary) + `npx tsc --noEmit -p services/edge/tour-host` → **exit 0**
  (run twice: after the rewrite and after the final edits). `node_modules` **deleted afterwards** (it is
  Linux-built; the Mac must `rm -rf node_modules && npm ci`).
- Engine script check (scratch `check_engine.mjs`): `ENGINE_JS` contains no backtick / `${`, parses under
  `vm.Script`, and the cooked regexes are exactly `/^[^\s@]+@[^\s@]+\.[^\s@]+$/` and `/^[+()\d\s.-]{7,40}$/`
  (escapes are doubled in the TS template literal on purpose).
- Render test (compiled `player.ts`/`portfolio.ts` run under Node with 9 synthetic tours: demo, RE with
  unknown beds/price, RE sold, venue deeplink+form, restaurant with a `javascript:` menu URL, retail shop +
  email opt-in, fitness free-trial, "other" with an empty agent card, no-video): canonical present, `noindex`
  only on embed, no `0 bd`/`$0`, Sold pill + "Ask about similar homes" + no financing on the sold tour, 4–8
  `<label>`s per form, no `novalidate`, sign-in email never printed, `javascript:` dropped, details section +
  facts/banners per industry, handoff URLs as intended, no `&amp;amp;`, no `CFG.demo`; portfolio: title from
  brokerage (email dropped), `og:image` absolutised, `javascript:` poster dropped.
- All four marketing pages' JSON-LD blocks parse (`json.loads`).
- `python3 -m py_compile` on every touched `.py` → OK. No pytest suite exists in the repo; a scratch
  behavioural test (`scratchpad/pyt/test_worker.py`, 45 assertions) passed: env-line parsing cases; style
  aliases / unknown-style skip / `style_prompt` raising; **watchdog kills a silently-hanging stub at 3.0 s**
  (was 30 s before killpg); `probe_source` on synthetic SDR / PQ-BT.2020-10-bit / untagged clips; tonemap
  chain present only for the PQ clip; real ffmpeg encodes of all three (60 fps, bt709-tagged, poster; PQ
  SATAVG 136 vs the ~23 the audit measured for re-tag-only); poster-time rule; duplicate-chapter suffixing;
  HDR keyframe extraction; EOF keyframe raises; per-segment isolation (`['enhanced','error','enhanced']`,
  `virtually_staged` true); `db.py` network → `DBError`, `set_progress`/`fail_job` swallow it, `fail_job`
  and `release_job` filter on `status=eq.processing`, slug vs `uq_renders_job` collision routing, claim
  filter; `stream.py` network → `StreamError`; `_skip_reason` rules.
- `__pycache__` dirs created by py_compile were removed; `git status` for my slices shows only intended files.

## 3. Deliberately not done (and why)

- **Financing / partner promo strip opt-in (F-H-17)** — product decision pending; unchanged (only hidden on sold homes).
- **`lat/lng` in the public JSON for RE (F-H-21)** — server-side (W1-E); the player now uses them only for the non-RE "Get directions" button.
- **Demo media to R2 / Range check (F-H-10, open Q2)** — needs the Mac + R2 upload; the demo still ships from `/assets`.
- **Heartbeat/lease/reaper (F-G-05), cost-ledger policy inversion (F-G-07), hero `data:` URI (F-G-15), no-chapter segment cap (F-G-16 remainder), disk/`MAX_SOURCE_SECONDS` alignment (F-G-18), QC caching/model ids (F-G-19), budget pre-check bundling (F-G-20), orphan cleanup (F-G-21), marketing-video gen.py (F-G-22), Dockerfile pins (F-G-24)** — outside the instructed list; README TODOs updated where claims were false.
- **`render_jobs.source` filter** in the claim query — migration 0011 (W1-E) adds the column; I did not add `source=neq.app` because a PostgREST 400 on a not-yet-migrated DB would stall every poll. The bucket filter already excludes app assets; add `source` later.
- iOS `Resources/player/index.html` is W1-D's; it already carries the watchdog. It does **not** have the new unavailable state / `sizeTrack()`-at-setup — parity item for a later pass (see §4).

## 4. For the parent / other owners

1. **W1-E `tours/cta.ts`**: retail `lead_form` fallback still returns `label:"Get directions"`; the player now
   labels the email opt-in itself, so it is only cosmetic, but returning `"Get updates"` there would be cleaner.
2. **W1-D iOS player**: optional parity — port `showUnavailable()`/`lastResort()` and the setup-time `sizeTrack()`
   from `player.ts` (`ENGINE_JS`) into `Resources/player/index.html`.
3. **W1-E**: consider `POST /renders` accepting `chapters` for worker jobs (README now says worker tours have no chapters).
4. **Product**: 4K was softened everywhere because neither engine outputs it — confirm, or plan a real 4K tier before the copy goes back.
5. **Product**: Team "3 seats" is published in `plan_entitlements` but there is no invite flow; copy now says "set up by the Rendprop team".
6. **Deploy order**: the tour-host reads `sold_at`/`status`/`sold`/`archived` defensively, so it can deploy before or after W1-E's `tours` function.

## 5. Deploy notes (Worker) — from the Mac, not from here

```bash
cd services/edge/tour-host
rm -rf node_modules && npm ci          # node_modules is platform-coupled; never reuse the Linux tree
npm run typecheck                      # tsc --noEmit
npx wrangler deploy                    # routes: rendprop.com/* ; workers_dev = false
# smoke:
curl -sI https://rendprop.com/f/%                      # → 404 text/html (branded), not 500
curl -s  https://rendprop.com/robots.txt | head -20
curl -sI https://rendprop.com/assets/site.css | grep -i cache-control   # max-age=3600, stale-while-revalidate=86400
open https://rendprop.com/f/estate-demo                # loader → scrub; lead form labels + inline errors
open "https://rendprop.com/f/<real-slug>"              # SOLD pill if sold_at set; industry details on a business tour
```
Worker/pipeline: no deploy target is live (the Python worker is not in the live path); on the next container
build the ffmpeg image must include `zscale`/`tonemap` (libzimg) for the HDR path — otherwise the worker
warns and re-tags only.

## 6. Self-review checklist
- No Swift touched; no files outside my ownership edited; nothing deployed.
- Hard rules: contact email stays aaron@pilk.ai everywhere; no prices added anywhere new; pricing numbers
  unchanged; no "coming soon" for the portfolio handle (removed, not promised).
- XSS: every new user-derived string goes through `escapeHtml`/`escapeAttr`; every URL through `safeUrl`
  (menu/reservation/booking/store/website/directions/poster/scrub/hls/share/photo); `ENGINE_JS` has no
  template tokens; `jsonForScript` still guards `__CFG__` (now including `handoffUrl`).
- The lead form still sends exactly the fields the leads function accepts (`slug`, `name`, `phone`, `email`,
  `extra`, `_hp`, `turnstile_token`); values are trimmed and capped client-side.
- Python: every subprocess has a timeout; every `requests` call maps transport errors; `fail_job` can no
  longer overwrite `ready`; `as_is` can no longer trigger a restage; HDR chain is probe-conditional.
