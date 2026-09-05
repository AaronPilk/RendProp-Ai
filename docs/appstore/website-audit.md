# rendprop.com — pre-launch website audit

**Audited:** 5 September 2026 · **Scope:** `services/edge/tour-host/public/**` (the static
marketing site) plus the `_headers`, `robots.txt`, `sitemap.xml`, `llms.txt` that ship with it.
**Not in scope (read-only):** `services/edge/tour-host/src/**` — the Worker that serves `/f/*`,
`/u/*`, `/a/*`, `/terms`, `/privacy` and the branded 404.

**Method:** every page read line by line; live pages fetched over HTTPS to confirm the deployed
headers; every claim checked against the product's own sources of truth —
`apps/ios/Rendprop/Purchases/Products.swift` (plan allowances), `src/legal.ts` (Terms/Privacy
wording), `docs/appstore/metadata/en-US/description.txt` (App Store copy),
`docs/appstore/review-notes.md`, `docs/COMPETITIVE-INTEL.md` (competitor facts, researched
26 Aug 2026). Contrast ratios computed with the WCAG 2.1 formula; HTML re-parsed with
`html.parser`; links resolved against the file tree and the Worker's route table.

**Severity:** **P0** ships a lie or breaks a launch requirement · **P1** costs conversions or
credibility · **P2** polish.

---

## 1. Product truth vs. what the site said

The site was written for a **website-billed early-access programme**. The product now sells
**auto-renewable subscriptions through the App Store**. Nearly every commercial statement on the
site contradicted the app, the Terms, and the App Store description.

| # | Sev | Page | Issue | Fix |
|---|-----|------|-------|-----|
| 1.1 | **P0** | pricing, index, llms.txt | Plan named **"Solo"**. The app, the server (`plan_entitlements`) and App Store Connect all call it **Starter**. | Renamed to Starter everywhere. |
| 1.2 | **P0** | pricing (JSON-LD ×3), index (JSON-LD) | `"availability": "https://schema.org/PreOrder"` — a machine-readable claim that the product cannot be bought. | Removed; offers now carry `priceCurrency`, `price`, `category`, and the App Store `url`. |
| 1.3 | **P0** | pricing ×5, index | *"there are no in-app purchases — plans are set up and managed on rendprop.com"*, *"cancel any time through rendprop.com — plans are never managed inside the app"*. The exact inverse of the truth, and a 3.1.1 problem if a reviewer reads it. | Replaced with: prices set by Apple, billed through the App Store, cancel in Settings → your name → Subscriptions. |
| 1.4 | **P0** | pricing | Add-on packs sold off-site ("50 extra photo edits for $10", "10 clips $15", "5 aerials $20", "drone-glide upscale from $19/tour"). Nothing is sold on the website; no such SKUs exist. | Removed entirely. |
| 1.5 | **P0** | pricing, index | Trial described as a metered sample ("1 render, 10 photo edits, 1 clip, 2 aerials, 1 upscale"). The real offer is Apple's **7-day free trial, full plan, once per Apple ID**. | Rewritten to match `legal.ts` §6 and the App Store description. |
| 1.6 | **P0** | every page | **No App Store link anywhere.** Every CTA was `mailto:aaron@pilk.ai?subject=Rendprop early access` (9 of them). | All CTAs now point at `https://apps.apple.com/us/app/id6808982413`, with an "Get it on the App Store" badge on index and pricing. |
| 1.7 | **P0** | — | **No `/support` page** — App Store Connect's Support URL will be `https://rendprop.com/support`, which returned a 404 (verified live). | Added `public/support.html` + footer link on all 5 pages. |
| 1.8 | **P1** | pricing, index | Yearly pricing absent. Starter $490/yr and Pro $990/yr exist; Team is monthly-only at launch. | Both billing periods shown; Team labelled "monthly only at launch". |
| 1.9 | **P1** | index, pricing, features, compare | "Early access", "founding members lock their rate", "invite as spots open", "coming soon to the App Store". None survive launch, and "founding members keep their rate" is a promise the App Store price ladder cannot keep. | All removed. |
| 1.10 | **P1** | pricing | Team's "3 seats — set up by the Rendprop team during early access" and "2 drone-glide upscales". Seat setup is in-product; the upscale allowance is not a launch claim. | Seats stated plainly; upscale line dropped. |
| 1.11 | **P1** | features, compare | Voiceover listed as **"on the roadmap"**. It shipped: reels take your own voiceover with word-by-word captions, or an AI voice. | Corrected on both pages (compare row now a ✓ for Rendprop). |
| 1.12 | **P1** | features, index | The **unbranded MLS-safe link** — a genuine differentiator, and the reason `/u/*` and `check-unbranded.mjs` exist — appeared nowhere on the site. | Added to features (its own section), index, compare (new table row) and support FAQ. |
| 1.13 | **P1** | index, features | AI disclosure described loosely ("labeled", "clearly disclosed"). The product's actual behaviour is stricter: every edit carries a **"Virtually staged"** label and the **untouched original is published beside it**. | Copy now matches the product and the review notes. |
| 1.14 | **P2** | index FAQ + FAQ JSON-LD | "When can I get the app? … in early access ahead of its App Store release." | Replaced with App Store / requirements / support answers; JSON-LD kept in sync with the visible FAQ (Google requires the match). |
| 1.15 | **P2** | index, features | "Free to download, works without an account" — the strongest objection-killer in the App Store description — was missing. | Added to the FAQ and the support page. |

**Fair-housing sweep:** no mention of people, families, neighbourhoods, schools, demographics or
"young professionals" was found on any page, before or after the edits. The banned-term grep is
now part of the validator and runs clean.

---

## 2. SEO / structured data

| # | Sev | Page | Issue | Fix |
|---|-----|------|-------|-----|
| 2.1 | **P0** | index | JSON-LD used `MobileApplication` with a single `PreOrder` offer at $49 and `applicationCategory: MultimediaApplication`. | Now `SoftwareApplication`, `operatingSystem: "iOS"`, `applicationCategory: "BusinessApplication"`, three `Offer` nodes (49 / 99 / 249 USD) each with `url` → the App Store, plus `softwareVersion`, `installUrl` and `downloadUrl`. |
| 2.2 | **P1** | pricing | `Product` offers named Solo/Pro/Team, all `PreOrder`, `url` → `/pricing`. | Starter/Pro/Team, monthly **and** yearly `Offer`s, `url` → the App Store. |
| 2.3 | **P1** | sitemap.xml | `/support` missing; `lastmod` stale (2026-09-03) on every URL. | `/support` added, all `lastmod` → 2026-09-05, formatting normalised. |
| 2.4 | **P1** | llms.txt | Still described Solo, off-site billing, add-on packs and the metered trial — i.e. it fed assistants the wrong prices. | Rewritten against the product truth; `/support` added to the page list; dates refreshed. |
| 2.5 | **P2** | robots.txt | Accurate and unusually well reasoned (the per-page `noindex` rationale is right). Only the date context was stale. | Comment refreshed; AI-crawler and demo-tour rules left exactly as they were. |
| 2.6 | **P2** | features, pricing, compare | `og:image:alt` present only on index; no `og:image:width/height` outside index. | Added to all pages. |
| 2.7 | **P2** | all | No Smart App Banner. | `<meta name="apple-itunes-app" content="app-id=6808982413">` added — Safari on iOS shows it only once the app is live. |
| 2.8 | ok | all | Unique `<title>`, unique meta description, `canonical`, OG + Twitter cards, `theme-color` (light/dark) all present and correct. `og.jpg` exists at 1200×630, 161 KB. | No change needed. |

---

## 3. Accessibility

| # | Sev | Where | Issue | Fix |
|---|-----|-------|-------|-----|
| 3.1 | **P1** | site.css | **No `:focus-visible` styling anywhere.** Keyboard users got only the UA default ring, which is nearly invisible on the dark bands and the gradient buttons. | Added one `:focus-visible` rule (2px accent outline + offset) for links, buttons, `summary` and the range inputs. |
| 3.2 | **P1** | site.css `--faint` | 12–13px text (`.tbl-note`, `.ba-caption`, `.mock-note`, `.price-note`, footer small print, compare "✗" cells) at **2.68:1** light / **3.28:1** dark. WCAG AA needs 4.5:1. | Alpha raised: light .42 → .60 (**4.64:1**), dark .38 → .55 (**5.75:1**). Same hue, same design. |
| 3.3 | **P1** | site.css `--ok` | `#0f9d58` on the light background = **3.26:1** — used for every green ✓ in the comparison table and the `$99/mo` total. | Light value → `#0a7a44` (**5.03:1**). Dark `#34d399` was already fine. |
| 3.4 | **P2** | site.css `.math-total .bad` | `#e5484d` = 3.64:1 on light. | Themed `--bad` token: `#cc2f35` light (4.85:1), `#e5484d` dark. |
| 3.5 | **P1** | compare.html | Heading order jumped **h1 → h3** (the three "core difference" cards had no section heading). | Section heading added. All pages now have exactly one `h1` and no skipped levels. |
| 3.6 | **P2** | all pages | No skip link — the fixed nav and hero sit ahead of the content for every keyboard and screen-reader user. | "Skip to content" link added to all 5 pages (visually hidden until focused), `<main id="main">`. |
| 3.7 | **P2** | all pages | Theme toggle used an inline `onclick`. | Bound in `site.js`; `aria-expanded`/`aria-label` handled there too. (Also what makes §5.1 possible.) |
| 3.8 | ok | all | Every `<img>` has `alt` (decorative ones `alt=""`), all have `width`/`height` (no CLS), `lang="en"`, `aria-current="page"`, labelled range sliders, `prefers-reduced-motion` honoured. | No change needed. |

---

## 4. Mobile

| # | Sev | Issue | Fix |
|---|-----|-------|-----|
| 4.1 | **P1** | At ≤900px `site.css` hid **every** nav link except the CTA (`.nav-links a:not(.nav-cta):not(.theme-btn) { display:none }`). On a phone — the majority of this audience — there was no way to reach Features, Pricing, Compare or Support from the header at all. | Added a menu button that reveals the existing links in a panel under the nav bar (`aria-expanded`, Escape and outside-click close). Desktop is untouched. |
| 4.2 | **P2** | The header bar was already close to overflowing at 375px (brand + theme + CTA ≈ 359px of a 375px viewport), and the new menu button adds ~48px. | A ≤620px rule tightens the wordmark, the gaps and the CTA padding — the row now measures ~342px, so it fits a 360px phone with the extra control. |
| 4.3 | ok | Layout: grids collapse at 980/920/880/600px, tables scroll inside `.tbl-wrap`, `viewport-fit=cover`, no horizontal body scroll. | No change needed. |

---

## 5. Security headers (`_headers`) and 404

| # | Sev | Issue | Fix |
|---|-----|-------|-----|
| 5.1 | **P1** | CSP carried `script-src 'self' 'unsafe-inline'` — which is what an injected `<script>` needs to run, so the CSP was not buying much. | Every page's pre-paint theme boot is now byte-identical, and CSP pins its **SHA-256 hash** instead: `script-src 'self' 'sha256-…'`. Inline `onclick` removed (§3.7) so nothing else needs inline execution. |
| 5.2 | **P2** | No `Cross-Origin-Opener-Policy`. | `Cross-Origin-Opener-Policy: same-origin` added. |
| 5.3 | ok | HSTS `max-age=31536000; includeSubDomains`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` camera/mic/geo off — all present and verified live. Asset caching (immutable for fingerprinted media, `stale-while-revalidate` for `site.css`/`site.js`) is correct. | No change needed. |
| 5.4 | ok | **404:** verified live — `/support` and `/nope` both returned a branded, dark-themed 404 from the Worker with the right copy ("There's nothing at this address"), status 404, no stack trace. `/support` now returns 200. | Worker-owned; no change. |
| 5.5 | note | HSTS has no `preload` token. Only add it if the owner intends to submit the domain to the preload list — it is effectively irreversible. | Left alone deliberately. |

---

## 6. Performance

| # | Sev | Issue | Status |
|---|-----|-------|--------|
| 6.1 | ok | Render-blocking: one 32 KB stylesheet, one ~300-byte inline boot script, `site.js` deferred. Hero images preloaded with `fetchpriority="high"` and a 1280px mobile variant. Everything else `loading="lazy"`. | No change needed. |
| 6.2 | **P2** | `hero-twilight-modern-home.webp` is 292 KB at 2400×1340 — the single largest byte on the critical path for desktop. | Left as-is: it is the LCP image, under the 300 KB budget, and re-encoding risks visible quality loss for ~80 KB. Noted for a future 1920px variant. |
| 6.3 | ok | All 29 assets ≤ 300 KB; `og.jpg` 161 KB. No web fonts (system stack), no third-party scripts, no cookies, no analytics tags. | No change needed. |

---

## 7. Links

Every internal link on every page now resolves to a file in `public/` or a Worker route
(`/terms`, `/privacy`, `/f/estate-demo`), every in-page `#anchor` has a target, and every
cross-page `#anchor` exists in the destination file. Checked automatically (see §8).

Outbound links (`pilk.ai`, `tractrealestate.com`, `wsmlending.com`, `reportaproblem.apple.com`,
`apps.apple.com`) all carry `rel="noopener"` where they open a new tab.

---

## 8. How this is verified

`npm test` in `services/edge/tour-host` (the Worker's own route + unbranded-compliance suites)
must stay green — it does: 531 + 297 assertions pass, and `npm run typecheck` is clean. Those suites
do not read `public/**`, so every page was additionally parsed and checked by hand-run script against
the list below. **Re-run this list after any copy change** — most of it is a few lines of
`html.parser` and a grep:

* HTML that parses with `html.parser` — no stray or unclosed tags;
* one `h1` per page, no skipped heading levels;
* unique `<title>` and meta description, canonical, OG + Twitter tags, and an OG image that
  exists and is ≤ 300 KB;
* JSON-LD that parses;
* every `<img>` carrying `alt`;
* every internal link and anchor resolving;
* Terms · Privacy · Support · Contact present in every footer;
* banned terms absent: *Solo, PreOrder, pre-order, coming soon, beta, early access, founding
  member, families, neighborhood, school, kids, professionals*;
* sitemap covering every page and nothing dead.

---

## 9. Only the owner can close these

1. **The App Store link 404s until Apple approves version 1.0.** `https://apps.apple.com/us/app/id6808982413` is on every page. The site never claims the app is live — it says "Free on iPhone · iOS 16 or later" and, under the hero, "the App Store link opens the moment Apple approves version 1.0". Delete that one sentence (index.html, the `.hero-note` paragraph) on approval day.
2. **Set the Support URL** in App Store Connect to `https://rendprop.com/support` (and Marketing URL to `https://rendprop.com`). `docs/APP-STORE-CHECKLIST.md` line 72 still says the Support URL is the bare domain — update it there too.
3. ~~**Team yearly.**~~ Resolved while this audit was being written: `LAUNCH-CONTRACT.md`, `Products.swift` (`notSoldAtLaunch`) and `description.txt` were all changed on 2026-09-05 to "Starter and Pro monthly or yearly, Team monthly". The site now says exactly that, and its yearly framing ("2 months free") matches the app's own `annualBadge`. Nothing left to do — just don't re-add `com.rendprop.app.team.annual` to App Store Connect without updating `/pricing` in the same change.
4. **Competitor facts are dated 26 August 2026** (`docs/COMPETITIVE-INTEL.md`). `/compare` states that date in the table note and the footer. Re-check the four published price ranges before any paid campaign points at that page.
5. **The Worker's fallback landing page** (`src/index.ts` `landingPage()`) still reads "iOS app — coming soon" and links `mailto:` for early access. It only renders if the static assets are missing, but it is the one string left on the domain that contradicts the launch. `src/` was out of scope for this pass.
6. **`docs/APP-STORE-CHECKLIST.md` §7** is superseded by `review-notes.md`; it still contains the "nothing is charged in this version" sentence that must never reach App Store Connect.

---

# Pass 2 — 5 September 2026 (post-deploy, live site)

**Scope:** the live site as deployed at 12:23 EDT — `/`, `/pricing`, `/features`, `/compare`,
`/support`, `/privacy`, `/terms`, `/sitemap.xml`, `/robots.txt`, `/llms.txt`, `/nope`,
`/f/estate-demo`, `/u/estate-demo`, every referenced `/assets/*`, the outbound links, and the
response headers — plus the sources, this time including `src/**` (the Worker) and `wrangler.toml`.
**Ground truth:** `docs/LAUNCH-CONTRACT.md`, `Products.swift`, `Listing.swift`
(`heroHeadline`/`heroSubline`), `docs/appstore/metadata/en-US/*.txt`, `src/legal.ts`,
`docs/appstore/review-readiness.md`, `SettingsView.swift` (`supportEmail`), and the app/server code
for every product claim (AI voice picker, 9:16/16:9 exports, 4/6/8 s aerial lengths with time-of-day
and camera-move pickers, Suggest / Improve-my-prompt, "skip AI enhance & publish now", sold-listing
form copy, RoomPlan furniture footprints, allowance refunds on failure, calendar-month renders vs
30-day meters, the 10-minute capture/import cap, 0.5× default lens, 60 fps output — all confirmed).
Pages were checked as rendered at 375 px and 1440 px in both themes, not only as parsed HTML.

Severity scale as above. Everything marked *fixed* is in the working tree, tests green, **not deployed**.

## P2-1. Rendering bugs (visible to every visitor)

| # | Sev | Page | Issue | Fix |
|---|-----|------|-------|-----|
| P2-1.1 | **P1** | features (light theme) | The "Handheld in. Drone-smooth out." section sits in a dark band but its paragraph and four bullets inherit the light theme's `--dim`/`--ink` — **dark text on the dark band, i.e. invisible** to every light-mode visitor. "This is the heart of the app" could not be read. | `site.css`: `.band-dark .fcopy p/li/strong` and `.band-dark .tick` now use the band's light ink. |
| P2-1.2 | **P1** | index (phones) | The two floating glass cards are positioned against the whole hero (`right:38%; top:18%`). Once the grid stacks (≤980 px) the "Tour ready" card lands **on top of the H1** — it hid the word "crew." in "Skip the film crew." on a 375 px phone — and "New enquiry" covers the phone mock's caption. | Hidden at ≤980 px (both are `aria-hidden` decoration). Desktop unchanged. |
| P2-1.3 | **P1** | compare (phones) | The "Three differences" cards carried an inline `style="grid-template-columns:repeat(3,1fr)"`, which outranks the stylesheet's ≤880 px collapse. On a phone the three cards rendered as **three one-word-wide columns** with clipped text ("unbrande", "Rendprop"). | Inline style removed; the stylesheet already sets three columns on desktop. |
| P2-1.4 | **P2** | all pages, footer | The Tract wordmark PNGs were wired backwards (`tract-word-dark.png` is the *white* art, `tract-word-light.png` the *black* art) **and** the show/hide rules lost to `.foot-brands img { display:block }` on specificity — so light mode showed both variants (one a near-invisible ghost taking 120 px) and dark mode showed only the black one, illegible on the dark footer. | Sources swapped in all five footers; every toggle selector now carries `.foot-brands`. Verified in both themes. |
| P2-1.5 | **P2** | index hero | `.hero-note` was `display:flex`, so the trailing "See everything it does →" link became a second flex column beside the (now two-sentence) note and wrapped word-by-word on phones and desktop. | Plain block; the link now follows the sentence. |
| P2-1.6 | **P2** | pricing (system-dark users) | Pass 1's `--bad` token (§3.4) was added to `html[data-theme="dark"]` but **not** to the `prefers-color-scheme: dark` block, so a visitor on system dark with no explicit choice got the light-theme `#cc2f35` on the dark panel — 3.6:1 on the "$635–1,450" total. | `--bad: #ff6b6f` added to the media-query block. |
| P2-1.7 | **P2** | all pages, footer | The three partner logos had no `width`/`height` (Pass 1 §3.8 said every image did). | Intrinsic sizes added (`640×118`, `260×108`); CSS still sets the display height. |

## P2-2. Product truth and copy

| # | Sev | Page | Issue | Fix |
|---|-----|------|-------|-----|
| P2-2.1 | **P1** | /terms §6 | "Starter, Pro, and Team, each billed monthly or yearly" — Team yearly is **not sold at launch** (`LAUNCH-CONTRACT.md`, `Products.swift notSoldAtLaunch`); the Terms contradicted `/pricing` and the App Store description. | Now "Starter and Pro, billed monthly or yearly, and Team, billed monthly", and "billing periods" added to what the app is the source of truth for. Locked by a route-test assertion. |
| P2-2.2 | **P1** | all 7 App Store badges | The badge read **"Get it on the App Store"** — that is Google Play's badge phrase ("GET IT ON Google Play"); Apple's is "Download on the App Store". | Wording changed on all seven badges (index ×2, pricing ×2, features, compare, support) and in the Worker's fallback landing page. The badge artwork is **custom** (a phone-outline glyph, no Apple logo) — see owner item 3. |
| P2-2.3 | **P2** | compare | Chip "Any length — not 75 seconds": captures and imports are capped at 10 minutes (`CameraManager.maxRecordingSeconds`, `MediaImporter.maxDurationSeconds` = 600). | "Up to 10 minutes — not 75 seconds". |
| P2-2.4 | **P2** | index | "One tap. Four seconds." — a latency figure nothing in the product backs (the edit runs an image model plus an automated quality check; the server allows up to 60 s). | "One tap. Seconds, not days." — true, and it lands the same punch against the 2–5 day turnaround on `/pricing`. |
| P2-2.5 | **P2** | pricing | "Cancel in two taps" — the path the same card describes is Settings → your name → Subscriptions → Rendprop → Cancel. | "Cancel in a few taps". |
| P2-2.6 | **P2** | llms.txt | The cost-context line gave different market rates from `/pricing` for the same items (video $250–600 vs $250–500, drone $100–350 vs $150–350, staging $15–50 vs $5–15 per photo, website $9–150/mo vs $15–75) — an assistant quoting both would contradict the site. | Rewritten to the `/pricing` table's figures, with the $635–1,450 per-listing total and 2–5 day turnaround. (The ranges themselves are not independently verifiable from the repo — see "not verified".) |
| P2-2.7 | **P2** | features | "stabilizes" — the only American spelling on a site written in British English (stabilised, labelled, colour, enquiries — matching the App Store copy). | "stabilises". |
| P2-2.8 | **P2** | index, support | FAQ JSON-LD had drifted from the visible questions/answers (index: "How is Rendprop different…" vs visible "How is this different…", plus two answers; support: "Something failed to render or upload" vs visible "A render or upload failed"). | JSON-LD now mirrors the visible text. |
| P2-2.9 | **P2** | compare | `Article.dateModified` still `2026-08-26` although the page changed on 09-05 (Pass 1) and the sitemap says so. | `2026-09-05`. |
| P2-2.10 | ok | all | Plan names, prices ($49/$490, $99/$990, $249 monthly-only), allowances (8/150/8/2, 25/300/20/6, 80/600/40/15 + 3 seats), 7-day trial once per Apple ID, Apple-set prices, US launch, support address `aaron@pilk.ai` (= `SettingsView.supportEmail`), hero copy (= `heroHeadline`/`heroSubline`), effective date Sept 5 2026 — all consistent across pages, JSON-LD, llms.txt, Terms and the App Store metadata. Banned-term sweep (Solo, PreOrder, early access, coming soon, beta, founding member, no in-app purchases, waitlist, fair-housing terms) clean on every live page including the demo tour. `codespell` clean. | No change. |

## P2-3. SEO / metadata

| # | Sev | Page | Issue | Fix |
|---|-----|------|-------|-----|
| P2-3.1 | **P2** | all 5 | Meta descriptions 172–247 characters; search engines truncate at ~160. | Trimmed to 156–163 without losing a claim. |
| P2-3.2 | **P2** | /terms, /privacy | No canonical, no favicon (browsers requested `/favicon.ico` → branded 404), footer had no Support link although every static page's does. | Canonical, `favicon.svg`, apple-touch-icon and a Support link added to the legal shell. |
| P2-3.3 | **P2** | 404 / 5xx pages, /f/* | No favicon link either. | Added to `headMeta()` (branded fallback pages) and to the branded tour head — **not** to `/u/*`, which must stay chrome-free; a test asserts it. |
| P2-3.4 | ok | all | Titles unique (58–83 chars), one `h1`, no skipped headings, every `img` has `alt`, JSON-LD parses, every internal link and anchor resolves, `og.jpg` exists (1200×630, 161 KB, no baked-in text), sitemap = real routes, canonical = og:url, CSP hash = the inline boot script (`sha256-dPD1Mx…`), `lang="en"` everywhere. | No change. |

## P2-4. Edge / transport (found only by fetching live)

| # | Sev | Where | Issue | Fix |
|---|-----|-------|-------|-----|
| P2-4.1 | **P1** | zone | **`http://rendprop.com/…` serves every page over plain HTTP with a 200** — no upgrade to HTTPS (Cloudflare "Always Use HTTPS" is off). HSTS on a plain-HTTP response is ignored, so a viewer who types or is texted a scheme-less link stays on HTTP. | Worker: `canonicalRedirect()` 301s every path it owns (`/f/*`, `/u/*`, `/a/*`, `/terms`, `/privacy`, 404s) to `https://rendprop.com`; dev/preview hosts untouched; tested. The **static pages need the zone setting** — owner item 1. |
| P2-4.2 | **P1** | zone | **`https://www.rendprop.com/` is a Cloudflare 525 page** — `www` is a proxied record in the zone but had no Worker route, so it fell through to the placeholder origin (the same failure mode the apex had before its catch-all route). | `wrangler.toml`: `www.rendprop.com/*` route added; the Worker 301s www → apex for its paths, and Static Assets serve the marketing pages (canonical already points at the apex). A zone Redirect Rule makes those a 301 too — owner item 1. **Integrator: this adds a route on deploy.** |
| P2-4.3 | **P1** | zone | Cloudflare **Bot Fight Mode / JS Detections injects an inline `<script>`** (`/cdn-cgi/challenge-platform/…`) into every HTML response. The marketing CSP pins `script-src` to one hash, so the browser **blocks it and logs a CSP violation on every page**; the detection never runs. Its payload carries per-request values, so it cannot be hashed, and `_headers` cannot carry a nonce. | Nothing sane in-repo (`'unsafe-inline'` would undo Pass 1 §5.1). Owner item 2. |
| P2-4.4 | **P1** | zone | Cloudflare's **managed robots.txt** is prepended to ours live: `User-agent: GPTBot / ClaudeBot / CCBot / Google-Extended / Applebot-Extended / Bytespider / meta-externalagent / Amazonbot → Disallow: /` plus `Content-Signal: ai-train=no`. That is the opposite of `public/robots.txt`, which deliberately opens the marketing site and `/llms.txt` to AI assistants and closes only customer tours. First-match crawlers will read Cloudflare's block and skip the whole site. | Policy decision — owner item 2. |
| P2-4.5 | ok | live headers | HSTS, CSP (hash matches), X-Content-Type-Options, Referrer-Policy, X-Frame-Options, Permissions-Policy, COOP all present on the static pages; the Worker pages carry their own CSP/HSTS; `/nope` is the branded 404 with status 404; `/index.html`, `/pricing.html`, `/pricing/` 307 to the clean URL; all 22 referenced assets and both demo videos return 200 with the intended cache headers; outbound links (pilk.ai, tractrealestate.com, wsmlending.com, reportaproblem.apple.com, Apple's EULA) all 200. | No change. |

## P2-5. Not changed, or not verifiable from the repo

1. **`https://apps.apple.com/us/app/id6808982413` returns 404** — as expected before approval. The hero-note sentence "The App Store link opens the moment Apple approves version 1.0." is the honest cover for the 15 CTAs that point there; it is still the one line to delete on approval day (`index.html`, `.hero-note`).
2. **Market-rate figures** ($250–500 video, $5–15/photo staging, $635–1,450 per listing, $2,500–5,000 retainers, "$9–150 a month" single-property sites) have no source in the repo; Pass 2 only made the site agree with itself. `index`/`features` quote single-property *tools* at $9–150/month while `/pricing` costs a single-property *page* at $15–75 per listing — different framings, left as they are.
3. **AI voice on reels** is a shipped picker (Off / My voice / AI voice, `FlythroughDetailView.swift:4806`), but it depends on the ElevenLabs key being configured in production, which the repo cannot show. If it is not, remove "or an AI voice" from `/features`, `/pricing` (Starter card) and `/compare` (voiceover row) before launch.
4. **The App Store badge is custom art** (black pill, phone-outline glyph, no Apple logo). Apple's marketing guidelines ask for the official badge; the official SVG was deliberately not downloaded here. Swapping it in is a one-file change to the seven `<a class="app-badge">` blocks.
5. `/f/estate-demo` and `/u/estate-demo` were read in full: copy, disclosures, lead form and footer are consistent with the site; the only "neighborhood" on the domain is the demo's location section (marina, dining, trails — no protected-class language).

## P2-6. Only the owner can close these (Cloudflare dashboard, all one-click)

1. **SSL/TLS → Edge Certificates → Always Use HTTPS: On**, and **Rules → Redirect Rules → "Redirect from WWW to root"**. Until then the static pages still answer over plain HTTP and at `www.` (P2-4.1/4.2).
2. **Security → Settings → JS Detections: Off** (unless a WAF rule uses `cf.bot_management.js_detection.passed`), and decide the **managed robots.txt / Content Signals** policy — turn it off if the intended policy is the one in `public/robots.txt` (P2-4.3/4.4). Both are also written up in `services/edge/tour-host/DEPLOY.md` §3.
3. **Deploying picks up a new route** (`www.rendprop.com/*`). If wrangler refuses it, remove that one line and rely on the Redirect Rule instead.
4. Approval day: delete the `.hero-note` sentence (item P2-5.1), then re-run `npm test` and the checks in §8 above.
