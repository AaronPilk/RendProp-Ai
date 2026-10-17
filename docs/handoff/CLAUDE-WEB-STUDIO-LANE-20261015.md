# Claude web + Studio lane — handoff to Codex (October 15, 2026)

This lane delivers reviewable fixes for Codex to integrate. Nothing has been pushed, deployed, merged or submitted. This is not a claim that the app is launch-ready.

## Where to find it

- **Worktree:** `/Users/pilksclaes/Rendprop AI/Rendprop Workspace/Worktrees/Active/claude-launch83-web-studio`
- **Branch:** `claude/launch83-web-studio-20261015`, created from `3483a36467545ac3e1d1a3449b3037a18b47f8ef`. Codex's shared worktree was not read for edits or touched.
- **Commits** (author/committer Aaron Pilk):

| Commit | Contents |
|---|---|
| `7032e0e` | `fix(web)`: property website photo viewer, contrast, compact mobile navigation, Signature typography, location icon, optional `thumb_url` support, plus the new gate `scripts/check-property-site-browser.mjs` |
| `ddb386c` | `fix(studio)`: complete photo pages, coordinator ZIP link re-signing, derived-file exclusion, photo-first tool order, stale job status. Studio detail is in `docs/handoff/CLAUDE-STUDIO-LANE-20261015.md` |
| this document's commit | Docs only |

- **Private evidence (not committed):** `/Users/pilksclaes/Rendprop AI/_bridge/build83-web-studio-claude/`
  - `before/` and `after/` screenshots
  - axe results
  - gate receipts
  - the fail-on-previous-source receipt
  - four negative-control receipts
  - read-only hosted screenshots
- **Changed files:**
  - `services/edge/tour-host/{src/player.ts, src/property-site.ts, src/property-design.ts, package.json, scripts/check-property-site-browser.mjs}`
  - `apps/studio/src/features/{creative/CreativeWorkspace.tsx, creative/photo-lineage.ts, creative/coordinator-photo-export.ts, creative/CoordinatorPhotoExportPanel.tsx, home/features.ts, listings/readiness.ts, sync/MakeVideo.tsx}`
  - `apps/studio/tests/*` (3 new files and 4 edited)
  - two `docs/handoff` files
  - No backend, database, iOS, billing, workflow or deploy file changed.

## Evidence classes used below

- **SRC:** implemented in source.
- **LOCAL:** executed locally, headless Chromium or Node, loopback fixtures only.
- **HOSTED-RO:** read-only GET of rendprop.com.
- **PHONE:** actual-device acceptance. **None of this lane is PHONE.**

## Property website bugs fixed (`7032e0e`)

All three designs were rendered with the actual renderer: Classic (`basic`), Signature Estate and Coastal Luxe. Each was checked on Home, Gallery, Location and Contact, at 390×844 and 1440×1000, with axe-core 4.14.

### W-1 · Photo viewer showed one photo with no way to move between photos (W01, W05)

- **Repro:** Gallery → open any photo. Before: the only control was Close, so 15 photos meant close → tap → reopen for each one. There was no loading indicator for a large master and a blank dialog if the file failed.
- **After:**
  - Previous/Next buttons, ←/→ keys and a horizontal swipe (vertical drags are ignored), with an "N of M" position.
  - An `aria-busy` + status line "Loading the full-size photo…" while the master downloads.
  - A failed file says "This photo could not load…".
  - Focus returns to the last viewed photo. Home's viewer links to "View all N photos".
  - Only the viewed photo is requested, and closing unloads it. Exact master URLs are unchanged.
- **Files:** `property-site.ts` (`PROPERTY_SITE_JS` and CSS), `player.ts` (dialog markup).

### W-2 · WCAG AA contrast failures on every design (W01, W03, W09)

- **Before (axe):** color-contrast failures in 14 of 24 renders:
  - contact-card initials 2.91:1 (Classic) and 4.27:1 (Signature)
  - contact Email/Website links 3.48:1 (Classic)
  - optional-field markers 3.86–4.09:1
  - OpenStreetMap attribution link 3.2:1
  - contact links were only 21 px tall
- **After:** 0 color-contrast violations. Each listed element is ≥4.5:1 in every theme, and the links are ≥24 px tall.
- **Files:** `property-site.ts` CSS. The contact section is also now a named landmark ("Contact the listing agent", `player.ts`), which clears the axe `region` finding for the form.

### W-3 · Video-led mobile navigation wrapped into a 124–144 px sticky bar (W01, W02)

- **Repro:** 390 px, a listing with a photo-based video. "Play property video" / "Recorded walkthrough" wrapped to 2–3 lines in the second nav row: about 17% of the screen covered while scrolling and filling the form.
- **After:**
  - Short visible labels "▶ Video" / "Walkthrough" at ≤600 px. Full accessible names are kept ("Play property video", "Open optional recorded walkthrough"); each short label is contained in its name (WCAG 2.5.3).
  - Nav height is now 106–111 px on Home and ≤114 px on all pages, the same ceiling the existing listing gate enforces.
  - Desktop is unchanged. The 200%-text mobile navigation gate in `check-listing-browser.mjs` still passes.

### W-4 · The two premium designs looked identical on a phone apart from colour (W03, W10)

- **After:** Signature Estate uses an editorial serif for display type (Didot / Bodoni 72 / Iowan Old Style, all installed iOS faces; Georgia fallback), with no remote fonts. Coastal Luxe keeps clean sans, including the location address (it previously mixed in Georgia).
- **Not verified:** the Linux test browser lacks Didot, so its screenshots show the Georgia fallback. Actual iPhone appearance is a PHONE check.

### W-5 · Location marker used a font-dependent glyph (W06)

- `⌖` rendered as a missing-glyph box in the test browser. It is now an inline SVG pin, so it no longer depends on device fonts.

### W-6 · Gallery thumbnails are the full masters (W05) — partly addressed; needs a backend contract

- **Measured on owner example `/f/g2afbgmv32` (HOSTED-RO):**
  - The Home 4-photo preview downloads 10.6 MB: two 3024×4032 masters at about 5 MB each, plus two 896×1195 files.
  - The Gallery page downloads about 13.8 MB.
  - Lazy loading defers this but does not shrink it.
- **Done in the renderer (SRC + LOCAL):** an optional gallery field `thumb_url` (safe URL) is used only for grid thumbnails. The anchor, no-JS link and viewer keep the exact master in `url`.
- **Current effect:** none, because the server does not send `thumb_url` yet.
- **PROPOSED CONTRACT for Codex:**
  - `GET /tours/:slug` gallery items: `{ url, label, thumb_url?: string }`.
  - `thumb_url` is a server-made JPEG at ≤1280 px long edge, quality ~0.82, created at publication from the selected published file, stored next to it, and never replacing or cropping the master.
  - Old payloads keep working.
- **Gate:** the gate proves the grid then fetches only `/thumbs/*` and the viewer opens the master.

### Regression gate

- `services/edge/tour-host/scripts/check-property-site-browser.mjs` (`npm run check:property-site-browser`): **85 real-browser assertions pass** on `7032e0e`.
- **On the previous source:** the same gate fails at the first viewer-navigation assertion (`#property-photo-count` absent). Receipt: `_bridge/…/receipts/check-property-site-browser-ON-3483a36-failure.json`.
- **Four one-fix negative controls** each fail at the intended assertion:

| Control | Failing assertion |
|---|---|
| thumbnail → master | "Gallery grid fetches the derivative" |
| contrast | `.agent .social a` 3.49:1 |
| nav labels | home nav 124.6 px |
| viewer error | "A missing photo reports a failure" |

- **Not in CI yet:** Codex needs to add it to the tour-host browser step of `ci.yml` (Claude did not edit workflows).

## Website areas checked without new defects

- **Video-first hero (W02):**
  - A typed server-selected 16:9 ≥1920×1080 master leads with an explicit Play and native controls; nothing autoplays and there is no video request before the tap.
  - A missing or invalid master falls back to the photo hero.
  - A missing poster uses the cover photo.
  - An HTTP failure shows "Retry property video" and leaves the Gallery reachable.
  - The recorded walkthrough is secondary and pauses the hero.
  - Evidence: `check-property-video` 366 + 5 controls, `check-property-video-browser` 62, `check-property-video-controls` 5/5. All LOCAL.
  - Unfinished or private results can only lead if the server selects them; publication authority is backend.
- **Nearby (W06):**
  - Only OSM-sourced places with category/distance/URL validation, attribution, and loading, empty and outage states with a map fallback (`check-listing-browser` 219, `check-nearby-places`, `check-nearby-runtime` 16).
  - HOSTED-RO: the owner Location page lists 9 named OSM places with attribution.
- **Contact (A05, W01):** lead form, Turnstile and privacy copy are unchanged (`check-lead-form` 430). No enquiry was submitted.
- **Links/SEO (W07, W08):**
  - HOSTED-RO, AASA: `/f/*`, `/u/*` and `/a/*` are excluded and `/property/*` is not claimed by the app.
  - Canonical: `/property/855-central-ave-…/g2afbgmv32`.
  - og:title/description/url/image and Twitter card are present.
  - `sitemap-properties.xml` has 3 `/property` URLs and no `/u/`, preview or `/f/` URLs.
  - Preview URL: `noindex, nofollow` header and meta, preview banner, no lead form.
  - LOCAL: `check-property-seo` 113, `check-routes` 732, `check-unbranded` 687, `check-public-links` (AASA 58 + 40).
- **Premium entitlement (W04):**
  - The theme comes only from server `website_theme`. Raw details flags and unknown values fall back to Classic.
  - The preview carries the "does not … unlock a paid design" banner, a watermark, no form and noindex.
  - The renderer has no price/purchase copy. The $25-per-property purchase and its server binding stay native/backend and are not exercised here.
- **Disclosures (W09):** a compact "Digitally edited or AI-generated media · N items · View details and originals" control, with originals linked. The hero media labels are one line each.

## Studio (`ddb386c`)

- **Five bugs fixed**, each with a regression that fails on `3483a36` and passes after. Coordinator re-verified the fail-before runs:
  - S1: 57 expected, 51 received.
  - S4: shows job B.
  - Unit: 5 tests fail on the old source.
- **The bugs:**
  - **S1:** AI Photo Studio saw only the first 50 media rows (P01, P02, P03, O06).
  - **S2:** a large coordinator ZIP could never finish once signed links expired after 10 minutes. It now re-signs the same saved list and refuses on change (P11).
  - **S3:** tools now follow the iPhone order: photos → AI Photo Studio → Make a video → optional recorded walkthrough (V01, V02, A01).
  - **S4:** a stale status reply no longer swaps the opened video (V09, V16).
  - **S5:** server video processing copies and poster frames are no longer treated as photo versions or ZIP masters (P10, P11). This is a client stopgap; see contract C1.
- **Verified unchanged and correct** (see Studio doc for line numbers):
  - Voice Off hides spoken captions.
  - Advanced is optional; per-photo motion is automatic and new videos keep the explicit input sequence.
  - A 100-photo bound, no 8 or 15 cap.
  - Journaled single dispatch, recover/resume of the same job, server-confirmed cancel.
  - Private results; explicit 16:9 publish only.
  - New styles start from Original and history is preserved.
  - Exact ZIP masters, no universal-MLS claim.
  - No design or purchase UI in Studio.
- **Contracts for Codex:**
  - C1: `studio/media` lists derived files as photos.
  - C2: an abandon endpoint for an unaccepted operation.
  - C3: a silent duplicate-key drop.
  - C4: confirm generic publish refuses photo-video outputs.
- **Pre-existing, not in CI:** `tests/feature-entry-browser.mjs` still expects "Scandinavian" (renamed Contemporary in P04).

## Commands and results (LOCAL; `/tmp` copies of this worktree)

| Command | Before (`3483a36`) | After |
|---|---|---|
| tour-host `npx tsc --noEmit` | pass | pass |
| tour-host `npm test` (18 suites incl. workerd runtime) | exit 0 | **exit 0** |
| `check-listing-browser.mjs` | 219 pass | **219 pass** |
| `check-property-video-browser.mjs` | 62 pass | **62 pass** |
| `check-property-video-controls.mjs` | 5/5 faults rejected | **5/5** |
| `check-property-seo.mjs` | 113 pass | **113 pass** |
| `render-property-design-preview.mjs` (24 captures + 1080p playback) | pass | **pass** |
| `check-property-site-browser.mjs` (new) | **fails** | **85 pass** + 4 controls fail as intended |
| axe-core, 3 themes × 4 pages × 2 sizes | 14 renders with color-contrast | **0** |
| Studio `npm test` | 565/565 | **570/570** |
| Studio `npm run build` + `check-dist` | pass, gzip 374,258 | **pass, gzip 374,927 / 400,000** |
| Studio browser runners (25 CI + make-video, photo-recovery + 2 new) | — | **29/29 pass** (new ones fail on `3483a36`) |

- **Environment notes:**
  - Headless Chromium is Playwright `chromium-1243` on linux-arm64, with `libXdamage` supplied via `LD_LIBRARY_PATH`. CI uses the locked full Chromium on macOS.
  - No Apple fonts in the test browser.

## Hosted read-only observations (owner's attention, not code defects)

- `sitemap-properties.xml` publicly lists `/property/2320-chantilly-cy/j9hhnxdtr8`. That is the earlier **test** listing whose gallery photos are app screenshots. If it should not be public or indexed, its owner should unpublish it or turn indexing off. Claude did not change it.
- Cloudflare's auto-injected Web Analytics beacon is blocked by the site CSP (console error only, no user impact). Either remove it at the zone or allow it deliberately; that is a zone/infra decision.
- The owner example `/f/g2afbgmv32` is Classic, sold, with no photo-based video, so the recorded "Fly-through" is its primary video action. That is expected.

## Checklist status (this lane only)

| ID | Status in this lane |
|---|---|
| W01 | SRC + LOCAL fixed (viewer, contrast, nav, landmark). HOSTED-RO pages render. PHONE open |
| W02 | LOCAL verified (hero, poster, error, secondary walkthrough). Real accepted Listing video published on the same home: PHONE/production open |
| W03 | SRC + LOCAL distinctness and accessibility. Owner aesthetic acceptance on device open |
| W04 | LOCAL renderer authority verified. Sandbox purchase, binding and metadata are Codex/native, open |
| W05 | Renderer ready for `thumb_url`. Backend derivative (contract) open. Masters untouched |
| W06 | LOCAL + HOSTED-RO verified (9 OSM places). Real coordinate acceptance PHONE open |
| W07 | HOSTED-RO AASA verified. Real Messages/Safari open with the app installed: PHONE open |
| W08 | HOSTED-RO canonical, og and sitemap verified. Shared-card rendering in Messages: PHONE open |
| W09 | LOCAL compact disclosure unchanged and accessible. PHONE visibility open |
| W10 | Original Rendprop styling, no copied media. Owner visual acceptance open |
| O06, P02, P03, P11, V01–V07, V09, V16 (Studio) | Fixes S1–S5 LOCAL. Real authenticated Studio, more than 50 rows hosted, a real multi-part ZIP in Files and the full Make-a-video lifecycle remain open |

## Codex-owned lanes not touched

- iOS/native
- Mirroring/phone
- Supabase, database, migrations and Edge Functions (including `tours` for `thumb_url` and `studio/media` for C1/C3)
- Video generation, render and QC
- Job `c40f4860-bb9d-4e12-93a2-406fa53bf4cd` (not touched, rerolled or rejudged)
- Billing, entitlements and StoreKit
- `.github/workflows/ci.yml`
- Deployments, TestFlight and App Store
- Onboarding video (not remade)
- 3D, CMA and measurements; pitch deck
- John Apple

## Remaining phone/production checks for Codex

1. **Website on the actual iPhone** (Classic + one premium, after deploy):
   - Gallery viewer next/previous/swipe/close; slow-network loading message.
   - Contact card legibility; mobile nav labels; Signature serif appearance; location pin.
2. **The same home with an accepted, explicitly published 16:9 Listing video:**
   - It leads with Play, plays with sound and does not autoplay.
   - Recorded walkthrough is secondary.
3. **Buyer link from Messages/Safari** opens the website even with Rendprop installed (an older cached AASA included). Check the shared-card preview.
4. **One authorized QA enquiry** to Aaron's controlled recipient: correct listing contact and lead record.
5. **After `thumb_url` ships:** re-measure Home/Gallery bytes on the owner example and confirm the viewer still opens the 3024×4032 master.
6. **Studio, signed in as a real account:**
   - More than 50 photos.
   - Multi-part coordinator ZIP over 10 minutes opened in Files.
   - Make a video → leave → recover → review → explicit publish on the same job.

## Codex follow-up: preserve selected photo order

The latest owner feedback supersedes automatic room-based ordering. New video recipes now save `automatic:false`; the arrange-scenes control is removed. The planner validates the same selected photo and asset identities, then keeps their exact input sequence while applying per-photo motion. Still-unplanned restored recipes ignore the legacy automatic-order flag. Accepted jobs and already-frozen request bodies are never re-sorted.

Focused validation: 23 Node tests, Studio typecheck, and the actual MakeVideo browser lifecycle pass. The browser restores an unplanned legacy `automatic:true` recipe after a lost preparation reply, receives a reversed planner response, and confirms selected order, per-photo motion, and an unchanged admitted manifest after a lost accepted reply/reload. Two compiled controls reintroducing the new-recipe default and room sorting fail at the intended assertions. Evidence is external at `/Volumes/Rendprop Files/Builds/Active/build83-normal-release/guards/studio-upload-order/FINAL-SOURCE-BINDING.json`. The initial missing headless-shell environment failure and narrow journal-selector fixture failure are retained; the final run uses installed full Chromium 1243. No hosted or paid calls, deployment, or physical-phone acceptance are claimed.

Integration still needs CI registration for the new property-site viewer, complete-photo-page and stale-job browser gates (and MakeVideo lifecycle gate, not previously invoked by CI). The optional `thumb_url` backend contract remains intentionally unimplemented.
