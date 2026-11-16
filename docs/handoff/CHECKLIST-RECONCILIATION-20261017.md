# Checklist reconciliation against integrated source — October 17, 2026

Reconciles every row of `OWNER-REQUEST-CHECKLIST-20261014.md` (80 rows: A01–A09, P01–P16, V01–V19, W01–W10, O01–O18, R01–R08) against the actual integrated source at branch `feature/launch-checklist82-20261014`, HEAD `7130625`. Read-only against source; nothing was built, deployed, generated or uploaded to produce it.

Each row has four explicit columns:

1. **Implementation** — complete / partial / not started, with the commit(s) or files in HEAD that prove it.
2. **Automated verification** — the test, harness or CI job that covers it (line numbers are `.github/workflows/ci.yml` step lines at HEAD), or "none".
3. **Deployed / delivered** — the live version carrying it, or "not deployed".
4. **Remaining acceptance or known defect** — only the dedicated final gate that genuinely belongs to the row (referenced as G1–G8 from the "Final gates" section) or a named defect. Rows whose remaining item is nothing beyond a gate listed once below say so by reference, not by repeating the gate.

No overall percentage or "closed rows / 80" figure is reported, deliberately: implementation, verification, delivery and owner acceptance are different stages and are kept distinct.

## Owner corrections applied

- Rendprop **1.0.5 (88)** is VALID, IN_BETA_TESTING and AVAILABLE to the existing internal TestFlight group (one upload, build ID `73f712da-…`, 13:00:56 UTC). Older wording in `CURRENT-CLAUDE-TAKEOVER-20261017.md` §"Build88 — local export finished, NOT uploaded" is superseded by that file's own header note and by this document. Build 88 was archived from the immutable fecbfa0 snapshot; `git diff fecbfa0..HEAD -- apps/ios tests/phase1` is empty, so 88 carries every native source change in HEAD.
- No App Store submission is authorized (G8). Paid AI generation is PAUSED (H1); Kie activation is HELD (H2); onboarding is LAST (G7).

## Cross-cutting verification state at HEAD

- **Hosted CI.** The checklist and takeover brief record exact run `39022740808` at `fecbfa0` as 16/16 successful (plus security `39022740805` 7/7) and run `39029975919` at `f74e540` as RED with five known failures. Both are hosted results; they are *claimed in OWNER-REQUEST-CHECKLIST / CURRENT-CLAUDE-TAKEOVER, not confirmable in HEAD*. HEAD `7130625` is nine commits past `f74e540`; it contains the repairs for failures 1, 2, 3 and 5 (`f80dac4` SQL guard + edge test fixes, `4ea7625`, `f135d29`, `547fb7a`) plus the launch-blockers race gate (`14f1a75`, `7130625`). No hosted CI result for HEAD is recorded anywhere in the repository. Failure 4 (tour-host `export-resume-browser.mjs:276`, runner media stall on a historical control) was deliberately not changed (`CLAUDE-CI-REPAIRS-20261017.md` §Item 4); its proposed evidence-gated retry diff is NOT applied.
- **CI jobs at HEAD** (`ci.yml`): audit-harnesses, native-photo-renderer, native-reel-recovery, native-audit-required, web-client-contracts, style-policy, studio, worker-edge, upload-gateway, edge-functions, db-migrations, db-publication-regression, property-video-renderer, python-worker, ios-static, secret-scan (16) plus `dependency-security.yml` (inventory, dependency-review, npm-audit matrix, security-required).
- **Source ↔ deployment lineage.** Every production backend function change in HEAD after the cost rollout (`49a1266`) is covered by a recorded deployment: `a1f1cc6` → ai-chapters44, `3e35f44` → studio42 + migration record 20261017112759, `f74e540` → property30 + migration record 20261017113856. Commits after `f74e540` touch tests and docs only. Studio48 is bound to 467 inputs including `3e35f44`; CPU18 image `4452a048` includes the `fecbfa0` renderer change (the only renderer source change after `1bb247c`). Website79 source is `54a7b72` for `services/edge/tour-host/src` (no later change). These live versions are *claimed in the handoff docs with external receipts under `/Volumes/Rendprop Files/…`, not confirmable from HEAD*; the lineage above is what HEAD can show.
- **Version drift in the checklist text.** The "Current release position" still says studio41 / Coach44 / voice55 / property29 in places; later rows and `COST-ADAPTER-HARDENING-20261017.md` + `STUDIO-GALLERY-UNSELECT-20261017.md` + `RENTCAST-FROZEN-PAYER-20261017.md` record studio42, coach45, ai-voice56, property30. The newer figures are used here.
- **Migrations in HEAD:** 183 files in `services/supabase/migrations`, latest `20261017110114_freeze_property_attempt_liability.sql` and `20261017110321_preserve_gallery_removal_projection_order.sql`. (Applied-history timestamps 20261017113856 / 20261017112759 are the live records of those two files, not separate files.)

## Final gates (listed once)

| ID | Gate | Owner / nature |
|---|---|---|
| G1 | Physical phone acceptance of the changed UI on the installed accepted normal build (now 1.0.5 (88)); installed 86 observations do not prove 87/88 layouts | Owner, physical |
| G2 | New-apartment whole-property quality acceptance with BOTH landscape and portrait photos: capture → saved edits → selected versions/order → smooth varied AI video → finished website, including owner motion acceptance (the old 14-photo master stays technically playable and aesthetically rejected) | Owner, physical; blocked by H1 for the video step |
| G3 | Genuine $25-per-property Sandbox purchase, recovery, property binding; Apple review screenshot and SKU metadata (currently MISSING_METADATA); Production stays OFF | Owner/Apple, physical |
| G4 | Received Messages buyer link / share card tapped on a phone with the app installed opens the buyer website | Owner, physical |
| G5 | One authorized test enquiry reaches the correct home/contact in Leads with correct delivery status | Owner, physical |
| G6 | Ordinary-account acceptance: member/library isolation (no cross-member access), ordinary paid receipt-backed admission, real invite/sponsored-seat flow; owner-admin success is not ordinary-user proof | Owner, physical |
| G7 | Onboarding remake from accepted FINAL app screens and URL pages (Willow 1.2×, no duration cap) — explicitly LAST | Owner, after everything else |
| G8 | App Store attach/submit/release of an accepted normal candidate — NOT authorized | Owner |

Holds that are not gates: **H1** paid AI generation PAUSED (no new provider POST, no credit top-up on stale messages); **H2** Kie activation HELD (route seeded OFF in `20261016100000_property_video_kie_kling3_4k_profile.sql`, no owner grant, processor notice `docs/legal/RENDPROP-KIE-NOTICE-DRAFT-20261016.md` unpublished).

## Genuine unfinished engineering (code or tests still to write / integrate)

| # | Item | Row(s) | File / area | State in HEAD |
|---|---|---|---|---|
| E1 | Observe one hosted full CI at HEAD after the five repairs; if failure 4 recurs, decide retry diff vs re-run | R01 | `.github/workflows/ci.yml`, `apps/studio/tests/export-resume-browser.mjs` | repairs committed; hosted result unrecorded |
| E2 | Pipeline hold ↔ ledger binding and period-residual accounting (reproduced shared ceiling 8c from one provider POST) | O09, O15 | `services/supabase/functions/_shared/*`, `tools/audit/api_cost_snapshot.sql`, `tools/audit/test_pipeline_cost_residual_report.py` | NOT in HEAD; a local branch `claude/pipeline-hold-binding-20261017` (commits `f3d8c19` WIP, `d40ceff`) carries an unproven candidate; its SQL/portable-PG cases are unexecuted |
| E3 | Supplier request-ID propagation into attempt receipts | O09 | `services/supabase/functions/_shared/provider-attempt-receipt.ts` | open |
| E4 | Decoder dependency upgrade candidate (FFmpeg 5.1.10 / Pillow 13) built offline and run through the unchanged 8 boundary + 13 media tests | O12 | `services/edge/property-video-render/Dockerfile`, `requirements.txt` | no candidate built; external o12 VM import blocked |
| E5 | 62 old-main dependency alerts: reviewed merge of the green pins/locks; broader Python/Deno/OS transitive, provenance and license scopes | O12 | repo settings, `.github/workflows/dependency-security.yml` | open |
| E6 | Drift guard: other-resource collector completeness and shared source-commit/CI binding | O17 | `tools/deploy/verify-rollout-readback.py` | tool complete; collectors incomplete |
| E7 | Public legal example that mentions median launch time (stale after the MetricKit correction) needs a notice correction; fresh authenticated ASC privacy questionnaire read; linked-diagnostic/vendor retention statement | O07 | `services/edge/tour-host` legal source, `docs/appstore/privacy-labels.md` | copy/notice open |
| E8 | Pre-existing RP402 copy inconsistency: `app_video_cost_reserve` legacy pre-check says "Workspace monthly processing budget would be exceeded" while the envelope says "AI usage limit reached"; both map to 402 | O03 | `services/supabase/migrations/20261009192550_team_private_listing_libraries.sql:1157-1160` | noted, unpatched (CLAUDE-CI-REPAIRS §Flake) |
| E9 | Steady-v2 / Kie prospective selector activation path (quality/authority/watchdog review, operator cutover scripts) — only after H1/H2 lift | V18, V19, O04 | `docs/handoff/KIE-ACTIVATION.sql`, `KIE-ROLLBACK.sql`, `services/supabase/functions/_shared/property-video-kie*.ts` | code present, activation deliberately not run |
| E10 | Studio Kit ZIP actual-file acceptance (download observer timed out; file never located) | O06, P11 | `apps/studio/src/features/listings/delivery-kit.ts` | behaviour unproven, not a confirmed defect |
| E11 | Largest-text photo grid reachability on native (CUA scroll failure is not product proof; `8e0eeaa` fixed only the Add/Take wrapping) | P05 | `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` | unresolved observation |

Everything else listed as "remaining" in the tables below is owner/physical acceptance (G1–G8) or an operational hold (H1/H2), not code.

## App flow and layout

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| A01 | complete — `cc1c89e` (Home photo-first guide), `df7707c` (photo-first first-run cards), `69f7db3` (Studio real-estate guidance), `5121609` (tour-host photo-first homepage `public/index.html`) | ci 175 "Native UX preserves drafts, deferred links, consent and archive baselines"; worker-edge ci 1041 public pages (routes 732/SEO 113) | TestFlight 88 (native); Website79; Studio48 | G1, G2 |
| A02 | complete — `apps/ios/Rendprop/Screens/NewListingView.swift`, `HomeListingsView.swift` (Get Started → address form); phone 81/85 observed | ci 237 "Room names and listing coordinates commit the current form values" | 88 | none (CLOSED); final screen capture belongs to R06/G7 |
| A03 | complete — `1eb0fbe` (balanced toolbox, Share last), `a9e64e0` (full-width share card last) | Simulator XCTest normal/largest-text light/dark captures (`apps/ios/RendpropUITests/BetaPolishUITests.swift`); ci 320 "Whole listing package preserves sources and refuses incomplete handovers" | internal 87 and 88 (`1eb0fbe` ≤ `fecbfa0`) | G1 — physical verification on installed 88 |
| A04 | complete — same native layout commits as A03 (`1eb0fbe`) | none dedicated beyond the A03 Simulator captures | 88 | G1 |
| A05 | complete — `apps/ios/Rendprop/Screens/ClientContactView.swift`; contact outside toolbox | ci 426 "Photographer preference, client drafts and confirmed contact transactions"; Studio ci 880 "Contact navigation and account isolation controls" | 88; Website79 contact | G5 — correct buyer-enquiry recipient |
| A06 | complete — `a31ce63`, `2180ec5` (Leads filters, compact Call/Email, no duplicate heading) | ci 179 "Leads tab groups exact listing identities and preserves existing destinations"; XCTest normal+AX5 (8 PNG) | 86 physically observed; 88 | none (CLOSED); isolation is O01/G6 |
| A07 | complete — System appearance default, glass cards (native theme) | native light/dark appearance XCTest captures | 81 physically observed; 88 | none (CLOSED) |
| A08 | complete — `08098a9` (compact photo version actions), `df7707c`, `a31ce63` | ci 199, 209 "Local photo selection retains version review and removal controls"; XCTest 44pt targets normal/largest text | 86 (physical 85/86 read-only observed); 88 | G1 for the final selection/edit controls; G6 |
| A09 | complete — Aerial "Coming soon", lab separated (`e97b04e` wording) | ci 127 "Coming-soon Aerial admission preserves existing accepted jobs and saved clips"; ci 434 "App Store capture isolation and physical UI-test switch boundaries" | 88 | none dedicated; G1 |

## Photos and AI Photo Studio

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| P01 | complete — native cap removed (ci 193 source); Studio partial-import recovery `1bb247c` (`apps/studio/tests/listing-large-import-browser.mjs`); Studio batch policy 200 files (`ListingWorkflow.tsx:271`) | ci 193 "Large photo imports preserve selection order, source bytes and partial failures"; Studio ci 816 "Discard, upload-order and partial-import compiled browser faults" | 88; Studio48 (includes `1bb247c`) | G2 (two-batch >15 import on the new apartment). Known limit: 200 files per Studio batch, not unlimited |
| P02 | complete — Original default tab | ci 191 "Photo versions, retained originals and destination export geometry"; ci 201 | 81+ observed; 88 | none (CLOSED) |
| P03 | complete — history preservation | ci 191, 201 | 81+ observed; 88 | none (CLOSED) |
| P04 | complete — Contemporary label; `apps/ios/Rendprop/Models/Render.swift` keeps `.scandinavian` stored-value compatibility | ci 191 | 81+ observed; 88 | none (CLOSED) |
| P05 | complete — `df7707c`, `08098a9`, `a976c7d`, `8e0eeaa` | ci 199, 201; XCTest normal/largest text | 86 physically observed (fit/pager/Edit); 88 | G1 (largest text), G2 (saved edit / cloud selection); E11 |
| P06 | complete — `960ef4b` (truthful preparation/upload stages), completion push | ci 308 "Reel completion notices and background expiry remain generation scoped", 310 | 88; property-video-jobs15 | G1 (completion/reopen/notification) |
| P07 | complete — server `e768792`+`68218a1` (`20261016163911_native_photo_family_selection.sql`, `20261016171912_native_photo_family_abandon_cover.sql`), native `13c0ee1` (`apps/ios/Rendprop/Photos/PhotoCloudSelectionCoordinator.swift`), Studio `3e35f44` (`gallery-selection.ts`, `gallery-unselect.test.ts`, `20261017110321_preserve_gallery_removal_projection_order.sql`) | ci 203/205/207/209/211 native; ci 1828 "Native photo choices preserve unrelated selections and serialize competing requests"; ci 1919 "Cloud gallery removal preserves partial selections and immutable retries"; `native_photo_family_selection_pg.py` (harness scoped by `f135d29`); Studio ci 757 "Explicit listing selection requires original review and a fresh snapshot"; `services/supabase/functions/studio/gallery-unselect.test.ts` | listings58 + both migrations live; studio42 + migration record 20261017112759; Studio48; native in 88 (`13c0ee1` ≤ `fecbfa0`); owner-admin desktop remove/re-add observed | G1 (native cloud remove/reopen/re-add on 88), G6 |
| P08 | complete — exact-family mapping in `13c0ee1`; backend listings58 | ci 203 "Exact cloud photo family choices and durable typed transport"; ci 1828 | listings58; 88 | G2 (Original → published gallery on the new apartment) |
| P09 | complete for exposed paths — REMOVEONLY declutter `8679e4b`, Pro4K stage/declutter policy (`20261015074002`), structured judge, Improve `ec4ed60` | ci 1883 "Actual saved photo background judge race and no-repeat control"; ci 1905 "Ordinary photo quality stays disabled until each task is approved"; photo-quality-worker tests | ai-photo86, ai-photo-v2 10, photo-quality-worker10 | G2 (whole-home edits). The unsafe TV/cat custom candidate HOLD is correct behaviour, not a defect |
| P10 | complete — retained masters 3584×4780; UIKit exports | native-photo-renderer ci 546 "Actual UIKit JPEG exports, level crops and original-byte preservation"; ci 191 | 88 | G1 (phone save/share) |
| P11 | complete — `1eb0fbe` compact coordinator UI; package assembly | ci 320/322 "Whole listing package …"; UIKit 449 ZIP checks (ci 546) | 87/88; physical 86 773.3 MB ZIP unpacked (15/26/60/28/7 + MLS/Zillow/Instagram) | G1 (review new UI on 88); unobserved: phone README, additional edit/master samples, multipart coverage |
| P12 | complete — native `bae1814`, Studio `711c79b` (orientation + filters), animated capture guide, 0.5× guidance | ci 189 "Photo lens, orientation, level and failed-save handling"; ci 274 "Photo orientation, crop confirmation and optional music preserve exact sources"; `apps/ios/tests/run-capture-orientation.py`; Studio 702 units / 23 browser flows (`4589f01` selector) | Studio48 (live fixture: all 5 photos resolve Portrait after decode); native in 88 (`bae1814` ≤ `fecbfa0`) | G2 (mixed-format apartment on phone) |
| P13 | complete — single-photo Original actions (build 83 source) | ci 199 "Individual photo review edits one retained original without changing bulk editing" | 83+; physical 86 second-photo Edit sheet observed; 88 | G2 (actual single-photo result/progress) |
| P14 | complete — oldest-first grids, batch append (83 source); Studio append order `20261015191916` | ci 201; ci 1821 "Studio uploads append in order across concurrent batches and reordering"; ci 1926 | 88; Studio48; migrations live | G2 (final batch/library/new-video order) |
| P15 | complete — family pager/count (83 source) | ci 201 "Photo family browsing preserves upload order and exact version/edit identity" | physical 86 first→second pager/count observed; 88 | G2 (grid total across batches/devices, swipe, saved edit, cloud selection) |
| P16 | complete — tap-order preservation (83 source) | ci 263 "Selected photo versions retain agent-chosen order and automatic per-shot motion"; ci 278 | physical 86 balcony→living room taps observed; 88 | G2 (generated preview/master order on a new job; blocked by H1) |

## Make a video and optional recorded walkthrough

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| V01 | complete — "Make a video", destination-first | ci 259 "Video destination and larger photo sequences survive saved work and recovery" | observed; 88 | none (CLOSED) |
| V02 | complete — Listing 16:9 / Social 9:16 | ci 259, 278 "…recover both output formats", 318 "Clean reel framing preserves intended crop, orientation and voice" | 88; backend | G2 (review accepted Listing master) |
| V03 | complete — recipe cap 100 (`20261014200302_property_video_recipe_allowances.sql`), Studio "Select up to 100" | ci 1926 "Listing gallery appends preserve exact selections through one hundred photos"; ci 278 "Large video batches retain every selected photo…" | live; same 14-source job completed/published | G2 (larger distinct-photo job; blocked by H1); motion quality is V18 |
| V04 | complete — source/provenance contract; staged-version binding | ci 265 "Video sources retain reviewed staged versions instead of newer previews"; ci 1961 "Studio photos and recorded publication exclude video derivatives" | live | G2 |
| V05 | complete — planner default flow, upload-order default | ci 263 | live | G2; whole-property motion is V18 |
| V06 | complete — `VoiceMode .off` default (`FlythroughDetailView.swift:10461`), Advanced disclosures | ci 318; ci 261 "Pending narration cannot freeze stale audio or discard an active recording" | 88 | G1 (exposed setting/playback matrix) |
| V07 | complete — three pinned CC0 tracks (`services/edge/property-video-render/container/music_catalog.py`), default Off | ci 1805 "Actual private CPU encoding, EXIF, motion, captions and audio preflight"; ci 274 | CPU18 | G1 (phone listening, loop/duck, voice balance) |
| V08 | complete for the resolution contract — 1920×1080 master, static fallback `c8da480` | ci 1167 "Actual native and worker HD master encoding"; ci 1805 | CPU18; master published | **Known defect:** owner AESTHETIC FAIL (walking-like motion) → V18 / G2. Resolution alone is not acceptance |
| V09 | complete — background completion + scoped push | ci 308, 310 | live; two-shot push proven, 14-shot job continued after leaving editor | G1 (phone reopen/review) |
| V10 | complete — spinner, last-checked time, safe network feedback (83 source) | ci 269 "Durable property video jobs retain admission, cancellation and same-job recovery" | 88 | G1 (tap/refresh) |
| V11 | complete — exact-job navigation | ci 310 "Global reel banner and completion taps preserve current job identity" | physical 84 observed; 88 | none (CLOSED) |
| V12 | complete — `20261015040518`, `151716`, `184528`, `193930` migrations; retained paid clips | ci 1940 "Terminal quality retry retains paid evidence and same-job owner recovery"; 1996; 2003 | live; same job READY/published | none (CLOSED); motion rejection is V18 |
| V13 | complete — separate optional toolbox tool (`FlythroughDetailView.swift`) | ci 276 | 88 | dedicated: upload/play/tag one real recorded walkthrough on the phone (a G1 item, not yet observed) |
| V14 | complete — slow/steady/gimbal/drone guide (7 native files mention gimbal) | ci 276 | physical 86 observed; 88 | none (CLOSED) |
| V15 | complete — muted Tag rooms with explanatory alert | ci 276 "Room tags require a real recorded or uploaded walkthrough" | physical 86 observed; 88 | none (CLOSED) |
| V16 | complete — abandonment/recovery/identity fences (`property_video_abandon_pg.py`, `property_video_submit_recovery_pg.py`, `791022e`, `8180ca1`, `269db59`) | ci 269, 271, 312 "Moving-photo work refuses changed account, consent and library contexts"; native-reel-recovery ci 573; ci 1808/1814/1954/2010; Studio ci 712 | ai-video90, jobs15, worker15; 88; Studio48 | G1 (physical interruption/cancel), G6 (account switch on device) |
| V17 | complete — Coming soon state | ci 127 | observed; 88 | none (CLOSED) |
| V18 | **partial** — inactive diagnostics/stabilizer `00f797d`+`a739140`, inactive steady-v2 `c054235` (`20261016002000`), Kie profile `2209a45` (route OFF), owner-only negative control `d8b71a3`; no accepted smooth output exists | ci 1863 "Steady video profiles preserve frozen jobs and native frame timing"; ci 1869/1876 Kie; ci 1888 "Native4K output preserves bounded candidate authority"; CPU diagnostics 32/32 | CPU17/18 and backend carry the inactive support; Kie route seeded `enabled=false` | **Core unfinished product gate.** Known defect: owner-rejected walking motion. H1 then one small cost/quality comparison, then G2 owner whole-video acceptance; E9 |
| V19 | complete — steady-v2 CFR24 support, 120/121 frames, legacy 30 pinned | ci 1863; CPU 24fps transition tests (ci 1805) | CPU17/18 + backend read back; prospective selection off | E9 (activation only after review); no phone gate |

## Property websites, purchases, sharing and SEO

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| W01 | complete — `services/edge/tour-host/src/property-site.ts`, `property-design.ts`, `nearby-places.ts`, `listing-player.ts` | worker-edge ci 1041 "Public pages, media delivery and thumbnail checks", 1072, 1081 "Property website galleries and photo-based video delivery"; preview-clearance guard (`b569680`, 558 local browser assertions) | Website79 (`be21eeae`) | G1 (physical Location/Contact/premium states, assistive technology), G5 |
| W02 | complete — `56ab142` renders57 publication authority; three designs play the master | ci 1072 "Published listing navigation and opt-in video delivery"; 1081 | Website79; renders57 | **Known defect:** published video is owner AESTHETIC FAIL; replace only with a newly accepted output (G2) and verify on phone (G1) |
| W03 | complete — `0204784` luxury layouts, `5121609` glass/fallbacks, `b569680` mobile preview clearance | ci 1041/1081; 289 local browser checks (`0204784` lane) | Website79 | dedicated: owner aesthetic acceptance; then G2/G1 mobile review. Preview is not a paid entitlement |
| W04 | complete — `20261014162938_property_video_websites.sql`, `20261014183851` (2500¢), `apps/ios/Rendprop/Purchases/WebsiteUpgradeStore.swift`, `Screens/WebsiteDesignPickerView.swift`, `functions/_shared/property-website-purchase.ts` | ci 146/148/150 "Property website consumable custody and account recovery controls"; `services/supabase/tests/property_video_websites.sql`; ci 2172 "No compiled digital-goods pricing" | backend live; native in 88; Apple draft SKU `com.rendprop.app.website.premium.property` Sandbox ON / Production OFF | G3 — the dedicated gate. Known: Apple MISSING_METADATA / no review screenshot |
| W05 | complete — point authority `20261015184120_published_photo_delivery.sql`, tours68→70 | ci 1041 thumbnail checks; ci 1982 "Published photo previews retain exact source and hosting authority" | tours70 | G1 (physical loading/detail). Known limits: full master path ≈7.8–9.5 s; historical 896×1195 edit is not 4K |
| W06 | complete — Overpass/OSM with attribution (`nearby-places.ts:37-48`, `index.ts:415`) | ci 1041/1072 (9 OSM places) | Website79 | G2 (real coordinates/places/empty-error on the new property) |
| W07 | complete — `/f/*` excluded from AASA (`index.ts:181`), direct `/property` route | ci 181 "Public buyer links stay in the browser and preserve publication identity"; ci 280 | Website79; 88; typed `/f/g2afbgmv32` opened in physical Safari with app installed | G4 — the dedicated gate; older cached association unproved |
| W08 | complete — `sitemap.ts`, `attribution.ts`, canonical `/f/` | ci 1041 (routes 732 / SEO 113) | Website79 | G4 (shared card), G2 (opted-in publication inspection); no ranking guarantee |
| W09 | complete — shared compact disclosure components; Kie notice draft `014db7f` unpublished | ci 125 "Subscription offer disclosures and durable workspace intent"; legal 110 checks (ci 1041) | Website79; 88 | G1 (phone/site visibility, exported-media labels); H2 holds the Kie notice |
| W10 | complete — designs built to references with Rendprop branding (`property-design.ts`) | none (design judgement) | Website79 | dedicated: owner visual acceptance (same event as W03) |

## Accounts, costs, Studio and operations

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| O01 | complete — native copy/routes; server membership/library mapping authority | ci 58 "Native account and workspace presentation privacy"; ci 183 "Private library identity, delegation, purchase scope and refusal controls"; ci 185; Studio ci 880 | 88; Studio48; me72 | G6 — the dedicated gate (no Sally-to-Tom access) |
| O02 | complete — existing owner grants/sponsored allowances | ci 131 "Private testing allowance labels preserve ordinary plan displays"; ci 1968 "Owner testing preserves metering…" | live | G6 (real invite/sponsored-seat flow) |
| O03 | complete — paid processing allowance `f1a9765` (`20261015080552`) | ci 1912 "Paid quality processing preserves verified billing and finite shared funding"; ci 1517; `launch_blockers_pg.py` mixed-writer race (`14f1a75`, `7130625`) | live | G6 (ordinary paid receipt-backed admission); E8 copy inconsistency |
| O04 | **partial** — backend `2209a45`/`b84455d`/`5d5dc47` integrated and deployed (`20261016100000`, `20261016110000`, six functions); native `791022e`, Studio `8180ca1` permission clients; legal `014db7f` draft; route OFF | ci 1789/1869/1876 Kie steps; ci 271 native processor permission; Studio ci 712; `b7c4515` gates | backend live (ai-video90 etc.); Studio48; native in 88 | H2 (owner grant, notice publication, operator cutover) then H1 lift, then G2; E9. Historical FAL recovery retained |
| O05 | complete — `b550212` sold availability; cost metered (2.1¢ booked call) | ci 79 "Ask AI offline replies and selected-screen privacy controls"; 72 focused tests | coach45 (checklist text still says Coach44) | G1 (native action execution), G6 (member/library) |
| O06 | complete — `c4fee13` Library pagination, `9c070e8`/`d21bbb0` design, `5121609`, `1bb247c`, `3e35f44` | studio job (ci 650–939): 726 units, type/build/size, a11y 466, workflow suites | Studio48 live (checklist text "Studio47 rollout" is superseded) | G6 (real-account ZIP / two-batch / >50 photos / multipart / full video); E10 |
| O07 | complete (code) — logging minimization `54a7b72` live in 15 functions; `bfbe9d1` trial compatibility; `PrivacyInfo.xcprivacy`, `docs/appstore/privacy-labels.md` | `_shared/ledger.test.ts`, `ai-chapters` gemini tests, `me` tests (106 cases); ci 2184 "Privacy manifest parses and declares what we collect"; edge-functions ci 1414 | me72, studio42, ai-video90 …; 88 | E7 (notice correction, ASC questionnaire, retention statements); G1 (device permission/notification checks) |
| O08 | complete (operational) — archive moves, source bundle restore/fsck | none (operational) | n/a | whole-Mac restore unproved; keep 3 GiB / 8 GiB floors. Not code |
| O09 | **partial** — reporting `37f1f4c`, `b9a1974`, `d0c2e4d`, `5b7182a`, cost adapters `49a1266`, RentCast frozen payer `f74e540`, SQL replay guard `f80dac4` | ci 2017 "API cost reports separate consumption, holds, funding and unpriced usage"; ci 2023; ci 1835; ci 1842 "RentCast settlement keeps admitted billing across binding changes and lost replies"; `tools/audit/test_api_cost_attempts.py`; `rentcast_billing_binding_pg.py`; `provider-liability-boundaries.test.ts` | admin43, property30, ai-voice56, 13 cost packages, Studio41→48 | E2, E3; supplier/infrastructure invoices and final pricing are owner evidence, not code; signed-in admin response unobserved |
| O10 | complete — `20261015170710`, `20261015171923` (no financial activation block for authorized media) | ci 1968, 1975 "Authorized product media stays metered without a financial activation block" | live | sequencing only: final price audit after functional acceptance, before G8 |
| O11 | complete — assessment delivered externally (`build88-infrastructure-readonly-map/INFRASTRUCTURE-19.md`, *not in HEAD*) | none | n/a | none (CLOSED); load/queue/monitoring gates stay under their own rows |
| O12 | **partial** — `dependency-security.yml`, `.github/dependabot.yml`, `tools/audit/npm_package_inventory.py` (`5121609`); aggregate + branch enforcement (`b1cdaa5`); decoder input restriction `1bb247c`; Pillow 12.3.0 pin | dependency-security 4 jobs (hosted 7/7 claimed); `test_npm_package_inventory.py`; `test_dependency_security_status.py`; ci 1049 "Audit production dependencies"; CPU 8 boundary + 13 media tests | CPU18 carries decoder restrictions; GitHub alerts/graph/required checks enabled | E4, E5. Not a phone gate; advisory counts are not exploitability |
| O13 | complete — facts CAS `20261005024702_listing_facts_intent_cas.sql`, gallery CAS, 409 feedback | ci 239 "Actual gallery sync races, warning recovery and provenance fences"; ci 1828, 1933; `tools/audit/run_listing_facts_cas.py` (ci 1688 step) | live; 88; Studio48 | G1 + G6 (delivered round trips in both winner orders on devices) |
| O14 | complete — contract map `SHARED-AUTHORITY-AND-RECOVERY-20261016.md`; scoped server/native authority tests | web-client-contracts ci 605; same tests as O13/O15 | live | G6 (client parity on ordinary accounts); no PWA |
| O15 | complete — GET-first reconciliation (`269db59`, `13c0ee1`, `791022e`, `8180ca1`), cost adapters `49a1266` | ci 1808/1814/1947/1954/1989/2010; native-reel-recovery ci 573; Studio ci 853 "Recovery retains drafts and suppresses private caught errors" | live | G1 (physical interruption/reopen/cancel); E2 belongs to O09 |
| O16 | complete — `9c070e8`/`5121609` design layer; `apps/studio/tests/design-a11y-probe.mjs` (466 checks) | Studio ci 671 "Styled Studio accessibility and beginner entry points" | Studio48 | dedicated: Safari/phone/assistive-technology and Dynamic Type acceptance of Studio; not WCAG certification |
| O17 | complete — `tools/deploy/verify-rollout-readback.py` (`b1cdaa5`), `/*` header-rule correction (`49a1266`) | ci 50 "Exact rollout readback, freshness and artifact refusals (offline)"; `test_verify_rollout_readback.py` (57 + 5 causal) | used for Studio47/48 whole-policy readback | E6 |
| O18 | complete — skip link `services/edge/tour-host/src/listing-player.ts` (`54a7b72`), outer main/contact scope (`5121609`) | ci 1041 routes/SEO/legal; preview-clearance guard (`b569680`); 264 static / 474 browser assertions | Website79 | G1/G2 (browser/phone/assistive behaviour on the opted-in final property) |

## Final sequence

| ID | Implementation | Automated verification | Deployed / delivered | Remaining acceptance or known defect |
|---|---|---|---|---|
| R01 | **partial** — frozen `fecbfa0` snapshot compiled/archived; five CI repairs in HEAD (`f80dac4`, `4ea7625`, `f135d29`, `547fb7a`, `14f1a75`, `7130625`) | full `ci.yml` (16 jobs) + `dependency-security.yml`; local proofs in `CLAUDE-CI-REPAIRS-20261017.md` | 88 from `fecbfa0`; CPU18; Studio48; Website79 | E1 (hosted CI at HEAD unrecorded; failure 4 runner stall unrepaired by design). No green claim for HEAD |
| R02 | complete — 1.0.5 (88) VALID / IN_BETA_TESTING / AVAILABLE, one upload | root 212-input binding, signature/7 entitlements (external receipts, not in HEAD) | TestFlight 88 | none (CLOSED). Never reuse/reupload 87 or 88 |
| R03 | not started (owner physical) | Simulator/scoped automation only | n/a | G1, G2 |
| R04 | not started (owner physical) | none | n/a | G3, G6, hosted/export acceptance |
| R05 | not started — this reconciliation is an input to, not a substitute for, the final Codex + Claude audit | none | n/a | run both audits against HEAD and retained evidence |
| R06 | not started (deliberately LAST); 118.73 s version rejected | ci 229 covers only the old quick-start duration/transcript | old video retained in builds for internal QA only | G7 |
| R07 | not started (part of R06) | none | n/a | G7 |
| R08 | not started; AFTER_APPROVAL distribution configured | none | public 1.0.4 (74) unchanged; draft 1.0.5 unattached | G8 — not authorized |

## Claims that could not be confirmed in HEAD

- Hosted CI run results (`39022740808` 16/16, `39022740805` and `39029975888` 7/7, `39029975919` RED, diagnostic runs `39010301637`, `39011942719`, `39013826317`): claimed in OWNER-REQUEST-CHECKLIST / CURRENT-CLAUDE-TAKEOVER / CLAUDE-CI-REPAIRS; hosted, not in HEAD.
- Live versions Studio48, backend function versions, CPU18 `e7a31406`/image `4452a048`, Website79 `be21eeae`, TestFlight 88, applied migration records 20261017112759/113856: claimed in the handoff docs with receipts under `/Volumes/Rendprop Files/Builds/Active/…`; only the source lineage is confirmable here.
- All physical phone observations (81/84/85/86) and the owner-admin Studio48 fixture QA: claimed in OWNER-CONTEXT / STUDIO-GALLERY-UNSELECT; not reproducible from source.
- O11 `INFRASTRUCTURE-19.md`: claimed in the checklist; external file, not in HEAD.
- Mac-local commit `1065075` (Codex's replay-guard repair): not in this repository; `f80dac4` carries the identical tree per CLAUDE-CI-REPAIRS.
- Claude motion branch commits `92c2ede`/`86863c1`/`081c5f0` and diagnostic refs `2b3bfd16`/`887dbbe3`/`406727`: not in this repository; their integrated equivalents (`00f797d`, `40f145f`, `a739140`) are.
- Checklist text "studio41", "Coach44", "voice55", "property29" in the release position: superseded by studio42, coach45, ai-voice56, property30 per the dated handoff files; the newer values are used above.
- CI job count: the checklist says "Main requires all16 CI checks plus the security aggregate" and elsewhere "17 required checks"; `ci.yml` defines 16 jobs and `dependency-security.yml` one required aggregate, consistent with 16 + 1.

## Row-id counts by implementation state

- complete: 69 — A01–A09, P01–P16, V01–V17, V19, W01–W10, O01–O03, O05–O08, O10, O11, O13–O18, R02
- partial: 5 — V18, O04, O09, O12, R01
- not started: 6 — R03, R04, R05, R06, R07, R08

These are implementation-state counts only; they say nothing about owner acceptance, which is tracked by G1–G8 above.
