# Rendprop owner request checklist — October 14–16, 2026

Updated October 16, 2026, 14:36 EDT. This is the current checklist; chronological evidence and superseded checkpoints remain in `OWNER-CONTEXT-20261014.md` and Git history.

## Current release position

- **Not complete and not ready for App Store submission.** Implementation, deployment and final customer acceptance are different states. No completion percentage is claimed.
- **Main blocker: photo-video quality.** The 14-photo, 70-second Listing video is delivered and playable, but the owner rejects its walking-like motion. Technical playback is not visual acceptance. Cadence and hardened motion diagnostics are implemented/tested but remain inactive; the old Claude stabilization patch is not applied.
- **Paid video tests are paused.** The earlier credit top-up question is superseded; a stale “credits added” answer must not restart generation. The owner has now chosen Kie as the primary provider for new video work; the migration candidate is assigned to Claude in an isolated branch. The switch is not live yet. Quality remains required; no live model, route, default or price was changed.
- **App:** last verified public version is 1.0.4(74). Normal internal TestFlight 1.0.5(87) is AVAILABLE/VALID/IN_BETA_TESTING after one reviewed upload (delivery receipt58d5173d); physical87 installation remains unverified. Physical TestFlight now confirms installed1.0.5(86); Leads all-property/single-property layout is observed on that build. Remaining physical workflow acceptance stays open. Physical84/85 observations are identified by build and are not86 proof. The 1.0.5 App Store draft remains unattached/AFTER_APPROVAL; no new submission or release was made.
- **Web and Studio:** all three property designs remain deployed; Contact touch-target fix is live website76 (73b7b277), with4public body/security readbacks and actual390px checks in all3designs. Studio46 is live90272a75 fromd93c3cb; exact35served assets/3routes/configuration readbacks and independent review pass. Actual owner Kit loads2/2, builds and reports sent to downloads with0alerts. Browser download observer times out and the physical ZIP file is not yet located: file acceptance remains open. The native image-cache hazard is reproduced/fixed; actual failed R2 response cause is unconfirmed.
- **Full CI:** replacement38916048712 is terminal SUCCESS,16/16 jobs at exactc46ff5f, receiptdab37863. Historical d49 failures and strict diagnostics remain retained. This run excludes later Studio1242/77/d93, native1eb, contact597, selection e768 and reporting1a622; final current-source integration CI remains open.
- **Costs:** retained app accounting is not an invoice-complete bill. The rejected14-photo job has19 accepted FAL requests and39.90USD internally settled estimated generation cost, including retries/replacement. QC/processing/storage/delivery are additional; supplier invoice reconciliation and final product pricing/allowance audit remain open.
- **Onboarding stays LAST.** The current118.73-second internal Realtor video is rejected. Rebuild it from actual final app screens and property URL pages after the app/site/video workflow is accepted, then verify that final resource build before submitting.

## Latest retained beta feedback

Fresh read-only October16 16:40UTC succeeds for both submitted screenshot/general and crash feedback since October14. Same three build82 reports: upload order across batches, single-photo editing and retaining bulk AI Photo Studio. Zero submitted crash reports in that response is not crash-free proof. No reports were replied to, marked or deleted. Receipt94020d97 in external build86-beta-feedback-current/20261016T164030Z.

## Status meanings

**Built** = implemented; **tested** names the environment and scope; **deployed** = live code verified; **observed** = a specific real-account or phone behavior was seen. A remaining acceptance item is still open. **Later** means explicitly outside the current release, not completed. Source existence, an upload or a paid-design preview does not close a whole feature.

## App flow and layout

| ID | Owner request | Latest verified result | Remaining |
|---|---|---|---|
| A01 | Lead with photos → AI edits → photo-based video → property website | Built; same14-photo Listing video explicitly published and browser-played in all3 designs; Home guide cc1c89e corrected | Final changed-screen and physical workflow acceptance |
| A02 | Get Started opens address/add-home form | Built; prior phone observation retained | Include exact final screen in onboarding |
| A03 | Manage listing details at very top; toolbox above tour; Share everything LAST spanning both columns | Native1eb0fbe in AVAILABLE internal87:8paired cards, optional full-width Rerender and final full-width Share. Normal/largest-text light/dark captures and coordinator/ordinary export checks pass; final3-case rerun plus2explicit reused passes | Install87 and physically verify; installed86 observations do not prove87 |
| A04 | Move Studio below primary tools and compliance near bottom | Built; layout changed | Final phone pass; compact disclosures stay accessible |
| A05 | Listing contact outside toolbox, without duplicate entry | Built | Verify save and correct buyer-enquiry recipient |
| A06 | Dedicated Leads bottom tab, grouped by home | Built; physical86 All listings/2 leads and selected Sold855/1 lead observed, no duplicate selected-home heading | Final account/library isolation acceptance |
| A07 | iPhone system light/dark by default; glass cards/images/faint purple ring | Built; prior real-phone appearance checked and restored to System | Preserve through newest UI changes |
| A08 | Replace tiny generic purple buttons with Rendprop branded controls | Compact native review controls in internal86; normal/largest-text checks pass,44pt targets retained; physical85 read-only appearance observed | Leads normal-text physical86 layout observed; final relevant selection/edit controls and account isolation |
| A09 | Consistent beginner labels across Home/listing/Settings | Built for MVP; lab separation remains experimental | No misleading active 3D/Aerial claim |

## Photos and AI Photo Studio

| ID | Owner request | Latest verified result | Remaining |
|---|---|---|---|
| P01 | Remove 15-photo upload ceiling; allow repeated imports | Built; cap removed | Actual >15 import/repeat/partial-failure check still open; do not advertise infinite storage |
| P02 | Original tab is default edit starting point | Built; Original/Latest/Decluttered/Staged observed today | Retest only changed final selection behavior |
| P03 | Keep all saved declutter/staging versions; try new style from Original | Built; history preservation tested and earlier phone observation retained | Whole-home fresh capture later |
| P04 | Contemporary instead of Scandinavian | Built; saved Contemporary/Modern history observed | Preserve older stored style compatibility |
| P05 | Clean tab labels, selection badges and photo-version review layout | Internal86 includes Original-first adaptive choices, compact Edit/Compare and image-ratio preview; normal/largest-text Simulator checks pass; physical86 full portrait fit/pager/correct current-photo Edit observed | Saved edit/new cloud selection and largest-text reachability acceptance remain |
| P06 | Real progress while editing/uploading; background work and notification | Built stage/count reporting, not invented AI percentage | Physical completion/reopen/notification acceptance for exposed paths |
| P07 | Select AND unselect a photo for listing without deleting original/edits | Atomic servere768+682 plus native13c0ee1 integrated. Native79core/28wire/44initial-delete/8automatic/24local,18compiled controls; independentGO and normal176-unit build pass. Server178migration proof retained | Live catalog baseline independently passes25dependencies/9helpersabsent; targeted2migration/function rollout, finalcurrentCI/newnormaldelivery/device and actual cloudremove/reopen/re-add/history/cover acceptance |
| P08 | Original can replace an edited public selection without false disclosure error | Earlier Original proof retained; new prospective family operation replaces first family slot while preserving unrelated order/cover | Native exact-family mapping built/reviewed in13c0ee1; hosted deployment/currentCI/newnormaldelivery and actual Original→published gallery acceptance remain |
| P09 | AI preserves structure; staging/declutter actually look professional | Prior stage/declutter retained; current Sky4K, Suggest, normal Improve and improved-prompt custom-lighting actual acceptance passed. Unsafe TV/cat candidate remains HOLD; Original/gallery/cover unchanged | Appropriate whole-home edits and final device acceptance; one image does not prove every home |
| P10 | Genuine high-quality exports, not screenshots or fake 4K | Real accepted photo outputs 3584×4780, retained-master bytes checked | Actual phone save/share and final coordinator ZIP |
| P11 | Organized ZIP: Originals / Decluttered / Staged and listing/social copies | Actual phone86 Sold-home773.3MB ZIP unpacked:15Originals/26Decluttered/60Enhanced/28StagingPreviews/7videos and MLS/Zillow/Instagram. Full-sizeOriginal opens;70s landscape playback completes. Compact coordinator UI and ordinary photo Form checks pass; delivered internal87 | Install87/review new UI; phone README/additional edit/master samples and multipart coverage remain open |
| P12 | Landscape listing capture; portrait social capture; 0.5× when whole room needs it | Guide/crop detection built; guidance now placed before video photo grid | Actual camera/lens/orientation and final branded framing footer |
| P13 | NEW beta: edit one photo directly from Photo versions; KEEP bulk editing | Delivered 83 single-photo Original actions; 50 focused checks +6 fault controls, review/lifecycle checks passed | Physical86 second-photo Edit opens the correct balcony-only sheet and cancels; actual single-photo result/progress remains, bulk unchanged |
| P14 | NEW beta: preserve upload order 1,2,3 and append later batches underneath, through new videos | Delivered 83 oldest-first grids and batch append; ordering/import controls passed | Final batch/library/new-video order; admitted jobs remain unchanged |
| P15 | NEW recorded feedback: Photos shows total photo count; viewer swipes left/right with position/count and edits the current photo directly | Delivered 83 family pager/count; Photos header has total family count;39checks+6controls, current-family edit preserved | Physical86 first→second pager/count and correct current-photo Edit observed. Grid total agrees across batches/devices, swipe, saved edit and new cloud selection/history acceptance remain |
| P16 | NEW clarification: video grid follows upload order, but manual taps can choose a different sequence | Delivered 83 tap-order preservation; two-batch append and B2→A1 recipe controls passed | Physical86 balcony→livingroom taps display shot1→2 without reordering grid; choices cleared, no Create. Generated preview/master order still open; admitted jobs unchanged |

## Make a video and optional recorded walkthrough

| ID | Owner request | Latest verified result | Remaining |
|---|---|---|---|
| V01 | Make a reel → Make a video; Listing or Social first | Built; naming/destination observed | Final end-to-end destination tests |
| V02 | Listing landscape 16:9 / Social portrait 9:16 | Built; actual Listing crop review observed today | Review accepted Listing master; originals remain unchanged |
| V03 | More than eight photos; current video recipe up to 100 | Same14-source job completed/published;70s1080p browser playback and physical86 reel06 whole70s playback pass | Larger distinct-photo capacity, chosen-version/order and owner motion quality acceptance remain |
| V04 | Video uses chosen reviewed staged/decluttered bytes without re-upload questions | Built source/provenance contract; unsafe staged photo refused in today's picker | Verify final chosen clips/versions against accepted video |
| V05 | Automatic useful motion; preserve uploaded order by default; no per-photo editing | Planner/default flow built; current beta requires upload-order preservation | Verify new-job order and whole-property motion |
| V06 | Simple default UI; Advanced voice/style/transitions; Voice Off hides spoken captions | Built | Actual exposed setting/playback matrix still open |
| V07 | Commercially reusable optional music; default Off | Three pinned CC0 tracks and mix/encoding checks built | Actual phone listening, loop/duck and voice balance |
| V08 | At least1080p; no black bars, blurred panels or severe zoom | Hosted Listing master is1920×1080 but owner rejects its motion/travel; resolution alone is not quality acceptance | Representative faithful, smooth Listing result and full owner playback |
| V09 | Finish accepted work away from editor; notify and review private result | Two-shot hosted completion/push proven; today's 14-shot job continued after leaving editor | Larger14-source job READY and one completion push sent; actual phone reopen/review remains, no auto-publication |
| V10 | Check status must visibly respond | Delivered 83 spinner, actual last-checked time and safe network feedback; SDK passed | Actual phone tap/refresh acceptance |
| V11 | Ready banner Review must open exact video, including while modal is closing | Delivered83 exact-job navigation;50checks+20controls; root physically observed84 Review opens SAME Sold855 home video | Preserve exact-job/account fencing in final candidate; unavailable-home banners stay suppressed |
| V12 | Fix quality-retry failure; retain already paid/accepted clips | SAME14-source job functionally READY/published, paid/source identities unchanged; physical84 Review opened it. Owner AESTHETICFAIL remains authoritative | Do not describe READY/published as acceptable motion or regenerate/rewrite historical paid receipts |
| V13 | Recorded drone-style walkthrough is separate optional toolbox tool | Built; optional route observed | Final upload/play/tag check with real recorded video |
| V14 | Explain slow/steady drone-like capture, gimbal and actual drone options | Built; physical86 guide observed: slow/level/steady, gentle turns, gimbal and existing drone upload; separate from photo video | Camera/orientation animation and genuine upload/play remain separate |
| V15 | Tag rooms muted until genuine recorded/uploaded walkthrough; tap explains requirement | Delivered predicate/entrypoint proof32checks+5controls. Physical86 muted no-source card opens explicit Add a walkthrough first alert, distinguishing photo video/sample; Open walkthrough reaches correct capture guide | Genuine recorded upload/play/tag remains open |
| V16 | Cancellation, lost replies and account switches do not duplicate charges or misroute media | Existing recovery/authority automated gates passed | Final changed behavior and real recovery acceptance remain open |
| V17 | Aerial Intro Coming soon; future exterior opening integrates with photo video | Coming-soon state built/observed | No current generation/publish promise |
| V18 | NEW owner quality priority: smooth varied AI shots, not walking-like camera motion | Claude diagnosis integrated; hardened temporal-v2/stabilizer and steady-v2 remain inactive. Owner-only negative control live87; attempted comparison refused403/nocharge, second not sent | Paid tests PAUSED; choose a small cost/quality comparison, then fidelity/temporal review and owner whole-video acceptance. No claim that stabilization fixes generation |
| V19 | Preserve native frame cadence without changing accepted historical jobs | Inactive steady-v2 nativeCFR24 committedc054235; exact120/121frame/transition/audio/caption+PG/Edge checks pass; legacy30commands pinned | Prospective runtime activation only after quality/authority/watchdog review; no historical recipe rewrite |

## Property websites, purchases, sharing and SEO

| ID | Owner request | Latest verified result | Remaining |
|---|---|---|---|
| W01 | Professional property website: Home, Gallery, Location/Nearby and Contact | Deployed76; actual390px browser checks9primarycontact links across3designs at44px, nooverflow; previews noform, Classic blankform/headshot works. Prior browser gallery and9nearby places retained | Physical lightbox/Location/Contact/premium states and authorized enquiry remain open |
| W02 | Finished photo-based Listing video is main presentation; recorded swipe tour secondary | Built/deployed; normal owner publication200/SAMEhome/link and70s1080p browserplay3designs proved delivery | Published video has owner AESTHETICFAIL; replace only with newly accepted output and verify physical website playback |
| W03 | Attractive included Classic plus two distinct luxury designs with restrained glass/motion | Classic + Signature Estate + Coastal Luxe built/deployed previews | Final phone aesthetic/accessibility acceptance; preview ≠ paid entitlement |
| W04 | Luxury design $25 one-time PER PROPERTY, switching both paid designs for that home | Backend/native product routing built; Apple draft SKU exists | Genuine Sandbox buy/recovery/property binding; real review screenshot/metadata; Production still OFF |
| W05 | Fast loading, full-quality images; old low-detail edited files not called 4K | Point authority LIVE: tours68/SQL184120 exact. SAME saved-edit preview repeat6.5564→1.6701s; exact master/preview bytes and geometry retained | Inspect initial hero/gallery use and physical loading/detail. Full master path remains about7.8–9.5s; historical896×1195 edit is not4K |
| W06 | Real nearby shops/restaurants/location at low cost | Live OpenStreetMap data: nine named places with attribution | Actual coordinate/place/map/empty-error acceptance |
| W07 | Buyer links open website rather than app; preserve old links | Direct /property route and association exclusions deployed; typed existing /f/g2afbgmv32 opens buyer website in physical Safari while app86 is installed | Real received Messages-link tap/share card and older cached association still unproved |
| W08 | Readable address URLs, canonical/share metadata, privacy-aware sitemap | Built/deployed and automated checks passed | Actual shared card; genuine opted-in publication inspection; no SEO ranking guarantee |
| W09 | Compact truthful disclosures; not overwhelming central screen | Built shared components; originals/provenance retained | Final phone/site visibility and exported-media labels |
| W10 | Photographer reference sites / PILK templates inform premium quality | Designs built for references and original Rendprop branding | Owner visual acceptance, not a claim of exact cloned copyrighted material |

## Accounts, costs, Studio and operations

| ID | Owner request | Latest verified result | Remaining |
|---|---|---|---|
| O01 | Personal accounts avoid workspace jargon; ONLY team owner switches member libraries | Existing authority retained; native copy/routes built | Final member isolation/account-switch tests; no Sally-to-Tom access |
| O02 | Owner can sponsor/invite testers with expanded usage while costs tracked | Existing owner grants preserved | Confirm real invite/sponsored-seat flow; owner success is not normal paid-user proof |
| O03 | Quality/functionality outrank old 75% margin; avoid premature normal-user spending blocks | Paid processing allowance aligned and live today; no retail price/counter reset | Ordinary paid receipt-backed admission; trial/free unchanged and not claimed solved |
| O04 | Choose actual AI providers by quality; Kie becomes primary for new video work | Owner chose Kie October16; concrete isolated migration/quote/recovery/testing assignment prepared for Claude. Current live routes remain unchanged; existing paid FAL jobs must retain recovery | Integrate and verify the Kie candidate, deploy/read back safely, then separately validate smooth/fidelity/native output quality. Paid tests remain paused; no untested lower tier or silent new FAL fallback |
| O05 | Ask AI is contextual app support and cost is measured | Coach43 live: server-derived sold availability and photo-first guidance. Actual selected Sold-home query200 correctly targeted same home; one2.1-cent booked call,72 focused tests | Native action execution and member/library device acceptance; owner query is not retail billing proof |
| O06 | Rendprop Studio matches native purpose, versions, jobs, settings and exports | Studio46 LIVE90272a75 fromd93c3cb. Earlier699units/81focused plus new7unit/typecheck/native-cache regression,24connected browser checks,35served assets/3routes/configuration independently pass. Actual2-photo Kit builds and reports sent to downloads,0alerts | Browser observer times out; actual ZIP file/contents acceptance remains open. Then two-batch/>50photos/multipart/fullvideo/account-library checks; private fixture never published |
| O07 | Necessary permission/privacy experience, truthful billing/trial statements | Existing implemented paths retained; no new blanket permission prompt assumed necessary | Final actual device permission/notification/account checks and disclosure consistency |
| O08 | Clean old files; organize Mac/1TB external drive without breaking active work | Prior 6.2GB/3,469-file move and cache cleanup retained. Later 67 inactive bridge folders moved externally with all hashes verified and compatibility symlinks; 8.54GiB free before successful 83 archive | Preserve current Mac files/source/keys and release evidence. Time Machine completed2026-10-16-103752;10current critical source/docs plus exact468bcommit/ref verified in actual backupData. Subsequent Studio/native edits are later; whole-disk restore coverage remains unproven; manual archives separate. Active App/index pointers corrected to current build82, with reversible metadata retained |
| O09 | Retain all app API-cost records and distinguish usage from added credits | Ledger/holds/funding retained separately; c40 job19accepted requests/39.90USD estimated generation. Reporting1a622 locally integrated:23report tests/3admin tests plus peerGO; exact basis and bounded attempt usage, no amount changes | Admin deployment, broader call journaling, supplier invoices/refunds and infrastructure/serving reconciliation remain incomplete; partial ledger is not an all-time bill |
| O10 | Functional testing first; final prices/margins audited after acceptance | Owner and general product-media SQL LIVE; authorized media no longer has a financial reserve activation block; request/byte metering retained | Actual loading/UX acceptance remains separate. Audit final prices after functional acceptance, before submission; no invented cash/reserve/cost receipts |

## Final sequence — not yet complete

| ID | Required action | State |
|---|---|---|
| R01 | Freeze latest source, peer review, compile and run appropriate checks | Native13c0ee1 and legacy64ca9c2 integrated after independentGO; actual normal176-unit Release build passes148.39s,394inputs exact. New4native gates wiredCI. Remaining: fullcurrentCI; old16/16 c46 run doesnotcoverlateredits |
| R02 | Deliver newest internal normal TestFlight from reviewed native source | Normal1.0.5(87) AVAILABLE/VALID/IN_BETA_TESTING, one upload and root receipt58d5173d; automatic existing-group membership,0groupPOST; public74/unattacheddraft unchanged. Delivered87 is1eb0fbe Share/toolbox UI; new13c0ee1 adapter is NOT delivered. Remaining: physical87 UI check, backend rollout and future adapter delivery/device acceptance; old86 proof stays distinct |
| R03 | Test final changed UI and inspect actual whole-property output | Current14-photo job is READY/published but owner motionFAIL. Normal/largest-text review/Home/Leads Simulator checks pass; specific physical84/85 behavior observed. Physical86 installation and normal-text changed Leads layout observed; remaining changed-screen/media acceptance and final output approval open |
| R04 | Finish real paid website/ordinary-account/export/site/Studio acceptance above | Open; no fake transactions or claims that previews prove purchases |
| R05 | Final Codex + Claude audit with current full context, not stale build 58 text | Open; prepare concrete current handoff; no external message without authorization |
| R06 | LAST: remake **Rendprop for Realtors** onboarding from actual FINAL screens and URL pages | Deliberately LAST; current 118.73s version REJECTED, not finished |
| R07 | Use each exact page while narrated, logical workflow/best practices, Willow 1.2×/natural excitement, no duration cap | Part of R06; do not regenerate before app/sites complete |
| R08 | Verify final video/resource build on phone, then submit newest accepted normal candidate | Open; automatic distribution AFTER_APPROVAL already configured; no latest submission yet |

Continue a focused acceptance sequence. The c46 fullCI is terminal16/16. Preserve its exact source attribution; later edits need their own scoped proofs and final integration verification. Preserve all existing quality and authority checks. On the phone, verify remaining changed behavior: current-photo edit/progress, remove/reopen/re-add and Original sync, manual video order, exact status/Review, recorded-only Tags, sharing/Files, voice/music/notifications and the final Leads layout. Build85 observations do not certify86, but unchanged checks need not be repeated solely for a build number.

The existing14-photo master decodes and plays in all three hosted designs; its motion is still rejected. Do not replay exhausted recovery operations, rewrite historical receipts, or regenerate a whole paid job while comparisons are paused. Continue ordinary-account, large-library/export, real Studio and site acceptance. Genuine25USD-per-property purchase/recovery and authorized enquiry remain separate tests. Remake Realtor onboarding LAST, verify its final resource build, then submit only an accepted candidate.

## Retained future requests — not forgotten, not this MVP release

- **3D tours** are the next internal TestFlight priority after release; separate
  from combined floor plans/measurements. Guided room/spatial routes must be
  understandable. Blender/Unreal and paid model services need actual research and
  capture/output tests; not a promise that a few photos equal Matterport.
- Measurements are last priority and must be accurate; do not claim certified
  dimensions. Floor plan/measurement labels should logically group together.
- CMA is a future exceptionally in-depth, evidence-based paid report. Accuracy,
  licensed sold comps, sources/dates, explained adjustments and agent review first.
  $5 research cost and $25–$30+ pricing are acceptable; 75% is not a hard gate.
  MLS/data access remains unknown; no CMA SKU/engine/data licence activated.
- Separate Bars/Restaurants onboarding later. Current video is Realtors only.
- Partner deck uses anonymized examples, accurate source-backed figures and
  explicitly proposed brokerage pricing. App bugs remain higher priority.
- Fresh correctly captured whole-home owner test follows current checklist/audits.

## Evidence anchors

- Concrete Claude Kie assignment: `docs/handoff/CLAUDE-KIE-VIDEO-MIGRATION-20261016.md`.
- Current internal86 delivery: `/Users/pilksclaes/Rendprop AI/_bridge/build86-normal-testflight/FINAL-INTERNAL-DELIVERY-RECEIPT.json`.
- Current Studio46 rollout: `/Volumes/Rendprop Files/Builds/Active/build86-studio-kit-refresh-diagnosis/connected46/rollout46/FINAL-DEPLOYED-STUDIO46-RECEIPT.json`.
- Studio46 actual owner UI success/download observation limit: `/Volumes/Rendprop Files/Builds/Active/build86-studio-kit-refresh-diagnosis/connected46/rollout46/ACTUAL-OWNER-UI-DOWNLOAD-RESULT-REPORTED.json`.
- Actual Studio45 kit read/download observation: `/Volumes/Rendprop Files/Builds/Active/build86-studio-kit-refresh-diagnosis/ROOT-ACTUAL-STUDIO45-KIT-OBSERVATION.json`.
- Committed no-store fix: `/Volumes/Rendprop Files/Builds/Active/build86-studio-kit-refresh-diagnosis/download-transport-diagnosis/cache-source-candidate/COMMITTED-CACHE-RECEIPT.json`.
- Actual private owner selection/reorder/restoration: `/Volumes/Rendprop Files/Builds/Active/build86-studio-actual-read-diagnosis/FRONTEND43-ACTUAL-ORDER-RESTORED.json`.
- Latest completed full CI,16/16 PASS atc46: `/Volumes/Rendprop Files/Builds/Active/build86-integrated-ci-c46ff5f/FINAL-16-JOB-RECEIPT.json`.
- Lifecycle fixture repair: `/Volumes/Rendprop Files/Builds/Active/build86-reel-lifecycle-harness-repair/FINAL-COMMITTED-RECEIPT.json`.
- Renderer test repair, exact Linux: `/Volumes/Rendprop Files/Builds/Active/build86-ci-cpu-test-repair/FOCUSED-REPAIR-FINAL-RECEIPT.json`.
- Current motion diagnostics, inactive: `/Volumes/Rendprop Files/Builds/Active/build86-claude-motion-review/FINAL-HARDENED-DIAGNOSTIC-RECEIPT.json`.
- Exact rejected-job generation cost: `/Volumes/Rendprop Files/Builds/Active/build86-video-cost-review/C40-JOB-GENERATION-ATTRIBUTION.json`.
- Official provider/model price comparison: `/Volumes/Rendprop Files/Builds/Active/build86-video-cost-review/KIE-OFFICIAL-PRICE-COMPARISON.json`.
- Historical evidence below retains its original build/date; it does not supersede the current release position.
- Real phone82 install/observations: `_bridge/build82-phone-acceptance/PROGRESS-20261015-1402.json`.
- Actual14-shot terminal failure: `_bridge/build82-phone-video-c40f4860/TERMINAL-READONLY-RECEIPT-20261015T145238Z.json`.
- Previous-source 16/16 CI: `_bridge/build82-ci-2fe6d669/FINAL-CI-RECEIPT.json`.
- Atomic gallery removal deployed today: `_bridge/build83-gallery-deselect/FINAL-DEPLOYED-RECEIPT.json`.
- Native photo proof: `_bridge/build83-photo-listing-toggle/FINAL-NATIVE-SOURCE-BINDING.json`.
- Historical normal83 delivery: `_bridge/build83-normal-testflight/attempt3/FINAL-TESTFLIGHT83-DELIVERY-RECEIPT.json`.
- Historical normal84 delivery: `_bridge/build84-normal-testflight/FINAL-TESTFLIGHT84-DELIVERY-RECEIPT.json`.
- Historical build84 native gate: `_bridge/build84-normal-testflight/FINAL-INTEGRATED-GATES.json`.
- Simulator fixture classification: `_bridge/build84-simulator-stall-classification/FINAL-FIXTURE-CLASSIFICATION-RECEIPT.json`.
- Simulator actual UI/control receipts: `/Volumes/Rendprop Files/Builds/Active/build84-simulator-acceptance/{UI-ACCEPTANCE-RECEIPT,FIXTURE-CONTROL-RECEIPT}.json`.
- Prospective accessibility layout/source proof: `/Volumes/Rendprop Files/Builds/Active/build84-simulator-acceptance/accessibility-layout-control/FINAL-RECEIPT.json`.
- Retained CI failure and focused harness repair: `_bridge/build84-ci-native-privacy-failure/HARNESS-REPAIR-RECEIPT.json`.
- C2 complete live rollout: `_bridge/build84-c2-rollout/FINAL-ROLLOUT-RECEIPT.json`.
- Hosted completed14-source master: `_bridge/build84-static-compose-repair/FINAL-ACTUAL-READY-RECEIPT.json`; exact master/temporal samples external `Builds/Active/build84-static-compose-hosted-ready/`.
- Current Sky acceptance: `_bridge/build84-sky-current-v2/FINAL-CANARY-RECEIPT.json`; actual sponsored usage26.6156 cents, separate from ordinary paid admission and invoices.
- Exposed feature audit and retained Improve/custom refusals: `_bridge/build84-exposed-ai-audit/REPORT.md` and `_bridge/build84-exposed-ai-small-batch/`.
- CPU exact-image tests and staged repair: `_bridge/build84-static-compose-repair/FINAL-PREDEPLOY-READINESS-v2.json`; original strict-ETag failure is retained; `DEPLOYED-IMAGE-GET-RECONCILIATION.json` proves the comment-only difference.
- Native prepaid source floor: `_bridge/build85-video-source-floor/SOURCE-BINDING.json`; compile-only plan in `_bridge/build84-postdelivery-native-sdk/COMPILE-PLAN.json`.
- Historical cost coverage: `/Volumes/Rendprop Files/Builds/Active/build84-owner-api-costs/20261015T1854Z/ACCOUNTING-READONLY-RECEIPT.json`.
- Backup read-only status: `/Volumes/Rendprop Files/Builds/Active/build84-backup-readonly/STATUS-20261015T1930Z.json`.
- Product-media SQL/cost coverage: `_bridge/build84-product-media-serving/FINAL-CLOSURE.private.json` and `cost-export/report.private.json`.
- Missing paid-result recovery: `_bridge/build83-fal-missing-result/FINAL-DEPLOYED-RECEIPT.json`.
- C1/C4 deployed authority: `_bridge/build83-studio-recorded-source/ROOT-DEPLOYED-READBACK.json`.
- Matched gateway configuration: `_bridge/build83-media-gateway-configuration/FINAL-CONFIGURATION-RECEIPT.json`.
- Apple13:50UTC read-only truth: `_bridge/build82-release-readonly-refresh/20261015T135013Z/READONLY-RECEIPT.json`.
- Studio/accepted AI outputs/earlier delivery receipts retain their detailed history
  in the archived checklist and OWNER-CONTEXT-20261014.md. Except explicit external
  paths, evidence paths are relative to outer `/Users/pilksclaes/Rendprop AI`, not
  this Git worktree.
