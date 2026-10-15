# Rendprop owner request checklist — October 14–15, 2026

This is the consolidated acceptance list for the owner's messages, not a claim that
all work is finished. Latest explicit decisions override earlier wording/prices.
Updated October 15 around 12:15 p.m. Eastern. Earlier detailed ledger is retained at
`_bridge/build83-owner-checklist/CHECKLIST-PRE-CONSOLIDATION-20261015-1503.md`
(relative to the outer Rendprop AI folder).

## Current truth

- Public: **1.0.4 (74)** remains live. Owner's actual phone: **1.0.5 (82)**,
  installed through TestFlight today. **83 is being prepared, not yet uploaded.**
- App Store 1.0.5 remains an unattached PREPARE_FOR_SUBMISSION draft configured
  AFTER_APPROVAL. No latest-build App Store submission or release is claimed.
- Exact prior source 2fe6d669 passed all 16 CI jobs today. Latest 83 changes are
  additional work and are not covered merely by that earlier green result.
- Today's actual 14-photo Listing 16:9 job continued after leaving the editor,
  then failed in its quality-retry path. That retry repair is now deployed; root
  resumed the SAME job from the actual phone at 11:23 a.m. Eastern, preserving
  completed paid clips. It advanced to five ready shots, then stopped on a
  separate FAL completed-result HTTP403. This is a delivery failure, not proof
  that generation failed. Same-receipt recovery is now deployed and independently
  verified (ai-video81 / worker8 / jobs7); actual-phone Resume is still pending;
  no master video/publication/completed-video push exists. Do not call it passed.
- Use only the actual mirrored iPhone for UI acceptance. Backend/SDK/CI tests are
  allowed, separately identified. All four available execution slots are active; Claude is confirmed working in a separate web/Studio worktree.
- The owner approved existing portrait/cropped photos for this test and will
  capture a properly framed new home later. Do not invent a 20-photo or fresh
  landscape-input prerequisite for finishing this approved 14-photo test.
- Native83's first signed archive stopped at two concrete Swift compiler errors
  before any upload. Failed evidence is retained; narrow fixes and the newest
  parent/agent feedback are being integrated before a reviewed new attempt.
- Claude's three web/Studio commits and the follow-up preserving explicit input
  order are integrated locally. Root Studio verify and tour-host typecheck pass;
  these integrated changes have not yet been deployed.

## Latest beta feedback

Fresh read-only App Store Connect fetch at 11:13 a.m. Eastern found three
screenshot/general submissions since October14, all build82: two comments on
single-photo editing (one explicitly preserves bulk editing) and one on upload
order across batches. Zero crash feedback submissions in that interval; this is
not a claim that no unsubmitted crash occurred. Original reports/screenshots are
retained privately; no feedback was replied to, marked or deleted. New items P13
and P14 are part of this build, not deferred.

## Status meanings

**Observed** = specific real-phone behavior observed; it does not certify every
edge case. **Built** = implemented, with source/automated checks where noted;
remaining acceptance is explicit. **Active** = implementation or recovery in
progress. **Open** = not completed. **Later** = deliberately outside this release.
No whole feature is closed by source existence, upload or a preview alone.

## App flow and layout

| ID | Owner request | October 14–15 result | Remaining |
|---|---|---|---|
| A01 | Lead with photos → AI edits → photo-based video → property website | Built; photo-first Home and listing tools observed on phone | Complete one accepted published property workflow |
| A02 | Get Started opens address/add-home form | Built; prior phone observation retained | Include exact final screen in onboarding |
| A03 | Manage listing details at very top; toolbox above tour | Built; actual phone order observed | Check final 83 changed screens |
| A04 | Move Studio below primary tools and compliance near bottom | Built; layout changed | Final phone pass; compact disclosures stay accessible |
| A05 | Listing contact outside toolbox, without duplicate entry | Built | Verify save and correct buyer-enquiry recipient |
| A06 | Dedicated Leads bottom tab, grouped by home | Built; tab/grouping observed on actual phone | Final account/library isolation acceptance |
| A07 | iPhone system light/dark by default; glass cards/images/faint purple ring | Built; prior real-phone appearance checked and restored to System | Preserve through newest UI changes |
| A08 | Replace tiny generic purple buttons with Rendprop branded controls | Active; latest screenshots explicitly included | Finish, compile and inspect actual 83 phone |
| A09 | Consistent beginner labels across Home/listing/Settings | Built for MVP; lab separation remains experimental | No misleading active 3D/Aerial claim |

## Photos and AI Photo Studio

| ID | Owner request | October 14–15 result | Remaining |
|---|---|---|---|
| P01 | Remove 15-photo upload ceiling; allow repeated imports | Built; cap removed | Actual >15 import/repeat/partial-failure check still open; do not advertise infinite storage |
| P02 | Original tab is default edit starting point | Built; Original/Latest/Decluttered/Staged observed today | Retest any changed 83 selection path |
| P03 | Keep all saved declutter/staging versions; try new style from Original | Built; history preservation tested and earlier phone observation retained | Whole-home fresh capture later |
| P04 | Contemporary instead of Scandinavian | Built; saved Contemporary/Modern history observed | Preserve older stored style compatibility |
| P05 | Clean tab labels, selection badges and photo-version review layout | Built and partly observed | Final changed-footer/button inspection |
| P06 | Real progress while editing/uploading; background work and notification | Built stage/count reporting, not invented AI percentage | Physical completion/reopen/notification acceptance for exposed paths |
| P07 | Select AND unselect a photo for listing without deleting original/edits | 83 native fix built/tested; atomic server removal deployed today | Install 83; remove/reopen/re-add; verify gallery and cover |
| P08 | Original can replace an edited public selection without false disclosure error | Genuine Original proof/sync fix built/tested for 83 | Actual original selection → published gallery sync |
| P09 | AI preserves structure; staging/declutter actually look professional | New Pro4K routes and stricter removal-only declutter prompt live; real stage/declutter outputs accepted | Broader actual-home output review; other exposed edits/masking remain open |
| P10 | Genuine high-quality exports, not screenshots or fake 4K | Real accepted photo outputs 3584×4780, retained-master bytes checked | Actual phone save/share and final coordinator ZIP |
| P11 | Organized ZIP: Originals / Decluttered / Staged and listing/social copies | Native/Studio implementation built; masters retained | Open final full export in Files, verify folders, dimensions and completeness |
| P12 | Landscape listing capture; portrait social capture; 0.5× when whole room needs it | Guide/crop detection built; guidance now placed before video photo grid | Actual camera/lens/orientation and branded framing footer on 83 |
| P13 | NEW beta: edit one photo directly from Photo versions; KEEP bulk editing | 83 single-photo Original actions built; 47 focused checks +6 fault controls, prior review/lifecycle checks passed | Actual phone83 Declutter/Stage action, result/progress and bulk unchanged |
| P14 | NEW beta: preserve upload order 1,2,3 and append later batches underneath, through new videos | 83 ordering built/tested,26 compiled controls; latest explicit upload-order choice supersedes automatic scene reordering by default | Actual phone83 batch/library/new-video order; admitted jobs remain unchanged |
| P15 | NEW recorded feedback: Photos viewer swipes left/right between photos, shows position/count and edits the current photo directly | Active; single-photo edit exists, family browsing/count being added | Real phone first/middle/last swipe, exact current-photo edit and saved selection/history |
| P16 | NEW clarification: video grid follows upload order, but manual taps can choose a different sequence | Active; preserve tap order rather than forcing grid order; later uploads append even when filenames restart at1 | Two-batch append and B2→A1 manual selection controls, exact recipe/preview; existing admitted jobs unchanged |

## Make a video and optional recorded walkthrough

| ID | Owner request | October 14–15 result | Remaining |
|---|---|---|---|
| V01 | Make a reel → Make a video; Listing or Social first | Built; naming/destination observed | Final end-to-end destination tests |
| V02 | Listing landscape 16:9 / Social portrait 9:16 | Built; actual Listing crop review observed today | Review accepted Listing master; originals remain unchanged |
| V03 | More than eight photos; current video recipe up to 100 | Built; actual 14-source job admitted today | Finish/recover that job; larger capacity still not physically certified |
| V04 | Video uses chosen reviewed staged/decluttered bytes without re-upload questions | Built source/provenance contract; unsafe staged photo refused in today's picker | Verify final chosen clips/versions against accepted video |
| V05 | Automatic useful motion; preserve uploaded order by default; no per-photo editing | Planner/default flow built; current beta requires upload-order preservation | Verify new-job order and whole-property motion |
| V06 | Simple default UI; Advanced voice/style/transitions; Voice Off hides spoken captions | Built | Actual exposed setting/playback matrix still open |
| V07 | Commercially reusable optional music; default Off | Three pinned CC0 tracks and mix/encoding checks built | Actual phone listening, loop/duck and voice balance |
| V08 | At least 1080p; no black bars, blurred panels or severe zoom | Real normal-route two-shot Social master 1080×1920; decoded/sample-frame checks passed | Full actual-phone playback and representative Listing result |
| V09 | Finish accepted work away from editor; notify and review private result | Two-shot hosted completion/push proven; today's 14-shot job continued after leaving editor | Recover larger job; actual push/reopen/review, no auto-publication |
| V10 | Check status must visibly respond | 83 code built: spinner, actual last-checked time, safe network feedback | Compile/new phone build and tap acceptance |
| V11 | Ready banner Review must open exact video, including while modal is closing | 83 navigation/context fix built; exact job intent retained | Focused proof and actual phone opening; unavailable-home banners suppressed |
| V12 | Fix today's quality-retry failure; retain already paid/accepted clips | Quality and same-receipt delivery recovery repairs live; prior same-job quality Resume observed on actual phone, paid clips preserved | Actual phone Resume of delivery issue, classify result403 if it persists; complete master still open |
| V13 | Recorded drone-style walkthrough is separate optional toolbox tool | Built; optional route observed | Final upload/play/tag check with real recorded video |
| V14 | Explain slow/steady drone-like capture, gimbal and actual drone options | Built capture guidance | Final phone copy/animation inspection |
| V15 | Tag rooms muted until genuine recorded/uploaded walkthrough; tap explains requirement | 83 implementation in progress; generated/sample video must not unlock it | Predicate/entrypoint checks, then actual no-source/upload/tag phone tests |
| V16 | Cancellation, lost replies and account switches do not duplicate charges or misroute media | Existing recovery/authority automated gates passed | New 83 changes and real final recovery acceptance remain open |
| V17 | Aerial Intro Coming soon; future exterior opening integrates with photo video | Coming-soon state built/observed | No current generation/publish promise |

## Property websites, purchases, sharing and SEO

| ID | Owner request | October 14–15 result | Remaining |
|---|---|---|---|
| W01 | Professional property website: Home, Gallery, Location/Nearby and Contact | Built/deployed; distinct routes return content | Actual phone navigation, image lightbox and authorized enquiry |
| W02 | Finished photo-based Listing video is main presentation; recorded swipe tour secondary | Built/deployed renderer | Accepted Listing video explicitly published on SAME home and played |
| W03 | Attractive included Classic plus two distinct luxury designs with restrained glass/motion | Classic + Signature Estate + Coastal Luxe built/deployed previews | Final phone aesthetic/accessibility acceptance; preview ≠ paid entitlement |
| W04 | Luxury design $25 one-time PER PROPERTY, switching both paid designs for that home | Backend/native product routing built; Apple draft SKU exists | Genuine Sandbox buy/recovery/property binding; real review screenshot/metadata; Production still OFF |
| W05 | Fast loading, full-quality images; old low-detail edited files not called 4K | Delivered readback: median HTML request 3.921→1.479s; masters separated from thumbnails | Actual phone loading/detail; old public low-resolution result is not magically replaced |
| W06 | Real nearby shops/restaurants/location at low cost | Live OpenStreetMap data: nine named places with attribution | Actual coordinate/place/map/empty-error acceptance |
| W07 | Buyer links open website rather than app; preserve old links | Direct /property route and association exclusions deployed | Real Messages/Safari share/open including older cached association |
| W08 | Readable address URLs, canonical/share metadata, privacy-aware sitemap | Built/deployed and automated checks passed | Actual shared card; genuine opted-in publication inspection; no SEO ranking guarantee |
| W09 | Compact truthful disclosures; not overwhelming central screen | Built shared components; originals/provenance retained | Final phone/site visibility and exported-media labels |
| W10 | Photographer reference sites / PILK templates inform premium quality | Designs built for references and original Rendprop branding | Owner visual acceptance, not a claim of exact cloned copyrighted material |

## Accounts, costs, Studio and operations

| ID | Owner request | October 14–15 result | Remaining |
|---|---|---|---|
| O01 | Personal accounts avoid workspace jargon; ONLY team owner switches member libraries | Existing authority retained; native copy/routes built | Final member isolation/account-switch tests; no Sally-to-Tom access |
| O02 | Owner can sponsor/invite testers with expanded usage while costs tracked | Existing owner grants preserved | Confirm real invite/sponsored-seat flow; owner success is not normal paid-user proof |
| O03 | Quality/functionality outrank old 75% margin; avoid premature normal-user spending blocks | Paid processing allowance aligned and live today; no retail price/counter reset | Ordinary paid receipt-backed admission; trial/free unchanged and not claimed solved |
| O04 | Choose actual AI providers by quality, Kie backup available | Real model comparisons and normal FAL4K + Pro4K routes tested/live | Finish current real workflow; provider migration not assumed universal fix |
| O05 | Ask AI is contextual app support and cost is measured | Built/deployed; earlier three ordinary queries6.3¢ catalog estimate. Today actual Sold-home context defect fixed/tested114scope checks+17faults/offline47 | 83 phone retest of exact selected Sold/Archived home, logical member library and navigation |
| O06 | Rendprop Studio matches native purpose, versions, jobs, settings and exports | Built/deployed; hosted byte/security readbacks and automated flows passed | Real authenticated account/library/recovery/native parity acceptance |
| O07 | Necessary permission/privacy experience, truthful billing/trial statements | Existing implemented paths retained; no new blanket permission prompt assumed necessary | Final actual device permission/notification/account checks and disclosure consistency |
| O08 | Clean old files; organize Mac/1TB external drive without breaking active work | Completed verified archive move: 6.2GB / 3,469 files; old worktrees/docs organized. Today removed5.93GiB inactive Rendprop build caches, restored6.02GiB free | Preserve active source/keys and release files; no further unrelated cleanup |

## Final sequence — not yet complete

| ID | Required action | State |
|---|---|---|
| R01 | Freeze latest native fixes, peer review, compile and run appropriate checks | Active; latest source is additional to earlier 16/16 green CI |
| R02 | Push frozen changes to GitHub and deliver internal normal TestFlight 83 | Open; archive/upload held until latest fixes are ready |
| R03 | Install actual phone 83 and test changes; recover 14-photo job and inspect final output | Open; only actual mirrored iPhone counts as UI acceptance |
| R04 | Finish real paid website/ordinary-account/export/site/Studio acceptance above | Open; no fake transactions or claims that previews prove purchases |
| R05 | Final Codex + Claude audit with current full context, not stale build 58 text | Open; prepare concrete current handoff; no external message without authorization |
| R06 | LAST: remake **Rendprop for Realtors** onboarding from actual FINAL screens and URL pages | Deliberately LAST; current 118.73s version REJECTED, not finished |
| R07 | Use each exact page while narrated, logical workflow/best practices, Willow 1.2×/natural excitement, no duration cap | Part of R06; do not regenerate before app/sites complete |
| R08 | Verify final video/resource build on phone, then submit newest accepted normal candidate | Open; automatic distribution AFTER_APPROVAL already configured; no latest submission yet |

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

- Real phone82 install/observations: `_bridge/build82-phone-acceptance/PROGRESS-20261015-1402.json`.
- Actual14-shot terminal failure: `_bridge/build82-phone-video-c40f4860/TERMINAL-READONLY-RECEIPT-20261015T145238Z.json`.
- Previous-source 16/16 CI: `_bridge/build82-ci-2fe6d669/FINAL-CI-RECEIPT.json`.
- Atomic gallery removal deployed today: `_bridge/build83-gallery-deselect/FINAL-DEPLOYED-RECEIPT.json`.
- Native photo proof: `_bridge/build83-photo-listing-toggle/FINAL-NATIVE-SOURCE-BINDING.json`.
- Apple13:50UTC read-only truth: `_bridge/build82-release-readonly-refresh/20261015T135013Z/READONLY-RECEIPT.json`.
- Studio/accepted AI outputs/earlier delivery receipts retain their detailed history
  in the archived checklist and OWNER-CONTEXT-20261014.md. Evidence paths are relative
  to outer `/Users/pilksclaes/Rendprop AI`, not this Git worktree.
