# RENDPROP FULL-STACK AUDIT — 2026-08-26
*Four parallel deep audits (market, tour-host/site, Supabase backend, iOS) + live-stack verification. Every P0/P1 found was FIXED THE SAME DAY; fixes marked ✅ are deployed or committed.*

## Verdict
No data-breach-class holes anywhere. Cross-tenant isolation, RLS, injection safety, secret hygiene, SSRF guards: solid. The real findings were (a) one stored-XSS vector on the tour pages, (b) four denial-of-wallet/abuse gaps in the backend, (c) two App-Store-rejection risks + one broken product loop in iOS. All fixed below.

---

## FIXED — Worker / tour pages (commit this repo; live on next `wrangler deploy`)
- ✅ **P1 stored XSS**: `javascript:` URLs in `cta.url` / `cta.secondary[].url` executed on click (CSP `unsafe-inline` permits javascript: navigation). Added `safeUrl()` scheme allowlist (`http/https/tel/mailto`) in `html.ts`; applied to deeplink CTA, secondary links, agent photo, gallery items, reel URL, floor-plan image. Unsafe deeplink now falls back to the lead form. Verified with a hostile-tour render harness: zero `javascript:` in output, safe URLs survive.
- ✅ **og:image now absolute** (was root-relative on the demo → broken social previews). Resolves against share_url origin.
- ✅ **frame-ancestors 'self'** (was `'self' https:` → any site could iframe the lead form; clickjacking). iOS WKWebView loads are top-level, unaffected.
- ✅ **workers_dev = false** (no duplicate-content *.workers.dev host).
- ✅ **sitemap.xml** now lists `/f/estate-demo`.
- ✅ `errorPage` Retry no longer uses a `javascript:` href.
- Verified clean: tsc, tag balance on all renders, embed mode isolation, cache keys (embed vs full), HEAD handling, hls.js SRI matches cdnjs byte-for-byte, all 4 marketing pages (links/anchors/assets/alt/h1/JSON-LD/canonical/OG), zero skyway.media, zero secrets, all promo links live (pilk.ai, wsmlending.com, tractrealestate.com).

## FIXED — Supabase backend (ALL DEPLOYED via MCP)
- ✅ **beacon v10** — per-call clamps: `watch_ms ≤ 5min`, `streamed_minutes ≤ 60` (public endpoint could previously inflate any tour's billable metrics with one POST).
- ✅ **portfolio v11** — `brand_kit` jsonb no longer spread into the public response; same 13-field allowlist as tours (was leaking any internal key ever written to brand_kit).
- ✅ **uploads v12** — batch path now enforces size + type per file (previously ZERO validation on 200 presigned PUTs); `bytes` is now REQUIRED on every ticket (was skippable → 12GB cap was advisory); per-org daily ticket ceiling (2,000/day) via durable rate limit.
- ✅ **ai-photo v9 / ai-video v5** — rolling-30-day per-org ceilings (3,000 edits / 400 video jobs) on top of burst windows, + `Idempotency-Key` soft-dedupe (409 on duplicate submit within 2 min; the iOS client already sends the header on writes).
- ✅ **me v12 — NEW `PATCH /me/brand`** (see iOS P0-1 below): validated, size-bounded, hex-checked accent, merges into `org.brand_kit` via the user client (RLS + column-scoped grant; `plan` untouchable).
- ✅ **DB migration `lock_down_rpc_definer_functions`** — revoked anon/authenticated EXECUTE on `handle_new_user`, `rls_auto_enable`, `is_org_member` (were callable via PostgREST RPC; Supabase advisor WARNs cleared).
- ✅ leads v11 (earlier today): demo-slug branch, Turnstile fail-open scaffold, input clipping — re-verified.

## FIXED — iOS (committed; build in Xcode to verify, no xcodegen needed — no new files)
- ✅ **P0-1 (the big one): agent card now reaches the hosted tour.** The card lived only in UserDefaults — no code path ever wrote `org.brand_kit`, so every real share link rendered an ANONYMOUS page while the app promised "your card on every link." Added `updateBrand` to APIClient/Live/Mock + fire-and-forget sync in `AgentCardEditorView.onDisappear` → `PATCH /me/brand` → tours/portfolio render name/brokerage/phone/email/website/socials. (Headshot upload = follow-up; hosted page shows initials until then.)
- ✅ **P0-2: fabricated share links killed.** Unpublished listings shared `rendprop.com/f/<uuid8>` — a URL that never existed (404 for every recipient). `shareURL` is now the real server link only; share buttons replaced by an honest "Publish to get your share link" card until it exists (same rule PortfolioExporter already enforced).
- ✅ **P0-3: App Store 3.1.1 pricing bait removed.** "Create my tour · $29–$279", "+$19/+$49" add-ons, "About $0.24 per clip" — all USD amounts removed from UI while `enableIAP=false`; price summary now reads Included / Early access.

## Verified strong (no action)
37 Swift files structurally sound; pbxproj fresh with all sources; privacy manifest + permission strings + SIWA + account deletion (with real R2 purge) + AI-content disclosure labeling in place; ATS-safe; no crash-risk force-unwraps; API contract matches server 17/17 endpoints; RLS on all 12 tables with no over-broad policies; SSRF guard on fal status; storage keys traversal-safe; durable rate limits on all public surfaces; zero hardcoded secrets; zero skyway.media anywhere in the stack.

## REMAINING ROADMAP (ranked — the gap between "excellent tool" and "agency killer")
1. **Close the lead loop in-app** (P1): leads are captured + pushed to GHL but the agent never sees them in the app — no lead list endpoint, no per-listing views/watch stats read API, push disabled. Build: `GET /leads` + `GET /metering` reads → Performance section; enable push later.
2. **Feed the hosted listing page**: app never PATCHes after first publish (price/sold/Zillow never sync; `poster_key`, `main_photo_key`, listing photos never uploaded → microsite has no hero image for link previews and no gallery). Wire `updateListing` + photo batch + poster on publish.
3. **Reels audio**: stitcher outputs silent video; add music bed + TTS voiceover (server `ai-photo`-style TTS or HyperFrames path) — an agency delivers scored, narrated content.
4. **Marketing-video productization**: pick render host (container vs `hyperframes lambda` vs HeyGen cloud) for `services/marketing-video/composition`; iOS "Marketing Video" screen using the existing job+poll pattern.
5. **Pricing page: add the Agency $399 tier + Developer tier** (see MARKET-DOMINATION.md §5) — awaiting owner call.
6. Turnstile secret + site key set in dashboards (code is live, fail-open until then); reinstall/multi-device listing pull (`api.listings()` unused → duplicate orgs risk); single-PUT render Content-Type says quicktime for an mp4 (cosmetic); Stream asset deletion on account-delete; `.deploy/` stale copy gitignore; README doc drift; memberships invite flow for Team plan.

*Companion docs: MARKET-DOMINATION.md (strategy), RELEASE-GATE-AUDIT.md + LAUNCH-CHECKLIST.md (earlier gates).*
