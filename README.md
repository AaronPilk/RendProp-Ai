# Rendprop

Rendprop brings phone capture, video editing, AI creative tools and property
marketing into one workspace. Capture photos and walkthrough footage on iPhone,
continue a property edit in Studio, and prepare reels and hosted property pages.
Real estate is the primary workflow; the app also supports other space types.

The **6 October release candidate** adds the remaining beta fixes, private media
delivery, a shared budget before paid AI requests, deliberate per-member hosted
portfolios, industry-specific Studio forms and account-data export. The
[launch handoff](docs/handoff/LAUNCH-READINESS-20261006.md) tracks source tests,
deployment order and remaining acceptance. The
[beta reconciliation](docs/handoff/LAUNCH-BETA-20261006.md) covers all 52 reports;
generated-image quality and physical camera tests remain explicitly separate.
Internal **1.0.4 (46) is available**, verified by Apple on **7 October 2026 at
00:47:51 UTC** (6 October locally), from source `7f5879e`. Its
[delivery record](docs/releases/TESTFLIGHT-46-20261006.json) binds the actual
distribution package, one successful upload and twelve successful CI jobs with
their original/rerun provenance. The
[build-46 rollout](docs/handoff/TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md)
records three applied migrations, source-verified me v50, apple-subscriptions v25
and renders v44, and the new Studio version: all 31 application files matched
across 35 served-file/routing requests. Trial configuration is OFF, with no new
funding, pools or serving schedules seeded. Earlier build-45/CAS/Studio receipts
remain historical. Protected-media cutover remains pending. No public App Store
or App Review submission was performed; public **1.0.3 (42)** is unchanged.

**7 October verified follow-up:** `fe0a59c` passed all twelve hosted CI jobs,
with all 270 database invariants passing fresh and replay checks. One selected
`ai-copy` deployment is **v21 ACTIVE**, JWT enabled, with all 21 runtime files
matching the frozen closure. See the [agent-reel rollout](docs/handoff/AGENT-REEL-ROLLOUT-20261007.md).
The [public legal update](docs/handoff/PUBLIC-LEGAL-ROLLOUT-20261007.md) is also
delivered: the downloaded Worker matches the tested bundle, Terms/Privacy match
the authored documents, and the existing listing and site asset checks passed.
Internal build 46 remains available from its immutable `7f5879e` archive.
The [pricing decision sheet](docs/handoff/PRICING-DECISIONS-20261007.md) keeps
trial funding and proposed paid allowances unapproved. Storage, delivery,
compute, email, support, retention and uncertainty still need complete reserve
limits. Real-account identity/private-workspace checks, protected-media/cache
cutover and the phone checklist remain open launch gates. The live trial is OFF;
no sponsor pool or serving schedule has been created.

Pricing uses the owner's target of **75% after Apple's fee**, with provider
attempts and ambiguous outcomes charged against the same funded allowance.
Apple's current USA catalog shows 15% proceeds, but catalog proceeds are not
settled invoices. Storage, delivery, support and retained media need funded,
bounded allocations; passing quota tests alone does not establish a margin.
New subscriptions have an approved **90-day hosting grace period after expiry**;
existing testers are preserved. A paid-AI trial sponsorship proposal remains
unapproved and is not activated.

The [limited trial](docs/studio/subscription-trial.md) is delivered as dormant
behavior: one hosted walkthrough from captured/imported footage, five logical
photo-edit admissions and one distinct publication, within a verified maximum
seven-day window, at most 90 seconds and 1 GiB of upload reservations. The action
counters are independent; photo admissions do not guarantee successful outputs.
The native consumers and purchase safeguards are in available internal build 46;
the backend and Studio are deployed. Owner funding and real StoreKit/phone
acceptance remain separate gates.

Build 46 blocks all new ordinary paid checkout and new plan-change purchases
until reviewed exact-product funding admission exists. Only a freshly validated
funded seven-day trial hold can open a new eligible Apple sheet; dormant
configuration advertises no offer. Existing receipt processing, Restore and
Manage remain available. Proposed $5/$25 trial funding is unapproved; paid
100/200/400 bundles and the 75% margin target remain financially uncertified.

Previous internal **TestFlight 1.0.4 (44) was AVAILABLE**, verified **5 October 2026 at
01:32:22 UTC** (4 October locally) for the existing Rendprop team, from source
`9d27fb5`. Apple reports VALID / INTERNAL_ONLY / IN_BETA_TESTING.
All twelve jobs in [CI run 37248967678](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37248967678)
passed on that exact source, and the signed archive has an independent source
and dSYM binding. The [build-44 receipt](docs/releases/TESTFLIGHT-44-20261004.json)
binds the signed archive, retained uploaded IPA, one internal upload, exact Apple
readback and verified English testing notes.

The [5 October full-system audit follow-up](docs/handoff/FULL-SYSTEM-AUDIT-20261005.md)
adds server-authoritative photo edits, Sandbox billing isolation, immutable video
quota receipts, verified lead forwarding and cleanup, native modal/form recovery,
and Studio failed-module recovery. This dated checkpoint preceded the delivered
build 45 and the [6 October rollout](docs/handoff/CAS-AND-STUDIO-ROLLOUT-20261006.md).
Private media revocation, App Review
Sandbox authority, full serving-cost allocation and reviewed legal publication
remain launch gates. The existing owner/family private testing grants remain
active; retail plans and shared-content access are unchanged.

The [4 October audit remediation](docs/handoff/CLAUDE-AUDIT-REMEDIATION-20261004.md)
adds rejected-video hold release, legacy gallery reconciliation, private
measurement saves and export provenance. Both matching database migrations
are applied; **tours v49, listings v41 and ai-video v51** are ACTIVE with JWT
verification and matching returned runtime source files. **Coach v22 and admin
v30 remain deployed**; their new backend contracts are deferred for compatibility
with older clients. The new native Coach privacy and scope changes are in the
signed source. FAL generation access and the earlier rejection cause remain
unverified; real generation still needs a controlled paid canary and output review.

The [floor plan measurements update](docs/floor-plan-measurements.md) is included
in the signed build-44 source: room dimensions, irregular wall outlines,
categorized worksheets, 2D/3D layouts, image/PDF export and an optional ARKit
distance estimator. Calculated closing walls are marked, linked open-below
deductions are subtracted once, and Letter PDFs identify sources and the 3D
phone-ruler limitation. Existing LiDAR scans and blueprint upload remain available.
Physical measurement accuracy, camera quality and owner-device acceptance remain pending.

**Build 44 had an ordinary-listing write bug.** A stale phone's full-row save
could replace newer Studio facts and attachments. Build 45 sends changed-field
intent, and the live 6 October repair returns terminal conflicts with older-client
compatibility preserved. Owned API checks passed; cross-account team behavior
still needs real-user acceptance before a shared-team launch.

The [complete October 5 beta follow-up](docs/handoff/BETA-FEEDBACK-20261005.md)
reviews all 52 submitted reports/53 images, including three reports received during
the review. Its source work replaces Home samples
with an interactive app guide, separates Measurements from Coming soon 3D cards,
adds card-only/selected-listing sharing and JPEG export, simplifies plan selection,
adds authorized Coach context and a distinct hosted business logo, and recovers
accepted reel requests without another paid generation. Mobile public navigation
also supports large text, and reviewed nearby places use explicit Apple Maps lookup.
Personal Profile identity is separated from a selected team's branding, with an
explicit Save action. Verified guest-to-account adoption preserves reviewed cards,
local drafts and pending paid video requests without replacing an existing account
card or allowing an automatic second generation. Video allowances distinguish cloud renders from quality
upgrades without changing plan prices or quotas.
These dated source changes are now included in internal build 45 and the scoped
6 October backend/Studio rollout. Stronger
staging prompts still need real output-quality acceptance. The additional staging
reference-image option is Coming soon and refuses generation before quota or
provider dispatch until its input costs are included in reviewed pricing.

The [full debugging follow-up](docs/handoff/FULL-DEBUGGING-20261004.md) implements
those safeguards on isolated source branch `fix/full-debugging-20261004`, with
retained conflicts, creation-retry protection, account-bound exports/Apple
codes, Studio draft recovery and ordered Apple subscription events. **These
follow-up changes were not deployed or uploaded at that checkpoint.** The later
build-45/core rollout records their delivery. Its report records the
required staged billing rollout and older-client upgrade boundary; build 44's
historical delivery receipt remains unchanged. All twelve
[CI jobs](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37266689307) passed
on exact source `e72503c`; the unsigned ARM64 iPhone Release build also passed.
The final evidence-only documentation update changes no executable or test source.

The [2 October audit follow-up](docs/handoff/CLAUDE-AUDIT-FOLLOWUP-20261002.md)
checks Claude's older report against the delivered source and live database.
It records stricter AI admission, compatible guest subscription access,
mandatory paid request keys and ordinary-video cost reservation races. Its
delivery section is the authority for the subsequent backend rollout; the
build-43 receipt below remains the historical upload snapshot. Backend rollout
was verified at that rollout: **ai-video v49**, all fifteen affected functions ACTIVE, 12/12 CI
jobs passed, and the live billing migration/grants checked. See the
[audit release receipt](docs/releases/AUDIT-COST-GUARDS-20261002.json).

Internal **TestFlight 1.0.3 (43) was AVAILABLE**, verified **3 October 2026 at
00:55:46 UTC** (2 October locally) for the existing Rendprop team.
The [Bria and saved-photo beta handoff](docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md)
records consent v3, direct Bria limited to the internal scheme and an explicit
authenticated tester allowlist, Latest/Decluttered/Staged downloads, separate
listing selection and reel stop/resume with retained completed clips. All twelve
CI jobs passed on uploaded runtime `8de8fd0`. At that delivery, backend **ai-video v47** was live,
JWT verification is enabled and all 30 deployed files match. The
[delivery receipt](docs/releases/TESTFLIGHT-43-20261002.json) binds the signed
archive, one internal upload, Apple availability, testing notes and schema readbacks.
The single historical Bria output CDN is a narrow beta starting allowlist, with
possible paid outputs stranded at unknown hosts. Normal fal processing and the
existing AI clip allowance/budget contract remain. Local tests do not certify
camera or generated-media quality.

Regular **App Store 1.0.3 (42)** is now reported **READY_FOR_SALE**, verified by
Apple GET preflight on **5 October 2026 at 01:18:40 UTC** (4 October locally).
Apple still binds that public version to the original build-42 ID. The
[App Store receipt](docs/releases/APPSTORE-42-20261002.json) and
[release handoff](docs/handoff/APPSTORE-42-20261002.md) preserve the original
2 October submission and its historical Waiting for Review state; the
[build-44 receipt](docs/releases/TESTFLIGHT-44-20261004.json) records the newer GET.
All twelve CI jobs passed on public runtime `204594a`. Spatial capture remains
confined to the internal lab scheme; public build 42 excludes those entry points
and direct Bria. Studio's original-media persistence fix is deployed with all
31 live assets matched at that release. This App Store state does not establish
physical-camera, purchase/restore or phone-to-Studio acceptance.

Internal **TestFlight 1.0.3 (41)** is available to the existing Rendprop team,
verified **2 October 2026 at 17:23:58 UTC**. The
[beta feedback release](docs/handoff/BETA-POLISH-20261002.md) adds main-photo-first
publishing, separate Explore/Play video modes, branded client editing, apartment
units, keyboard-safe room tags, top photo-work progress and saved-version selection.
The public Worker and gallery-selection backend are live; all 12 CI jobs passed
on runtime `3615a23`. The [delivery receipt](docs/releases/TESTFLIGHT-41-20261002.json)
binds the archive, one internal upload, Apple availability, notes and live readbacks.
You can leave Photo Studio during a batch; force-quit does not resume unfinished
work. Whole-video declutter, staging consistency and drone-like walking quality
remain unfinished and are not certified by the software tests.

The preceding internal **TestFlight 1.0.3 (40)** delivered crash hardening.
The [crash-hardening release](docs/handoff/IOS-CRASH-HARDENING-20261002.md)
bounds the listing toolbox's SwiftUI types, safely formats invalid duration/FPS
metadata and handles duplicate saved listing IDs without discarding rows/media.
All 12 exact-source CI jobs pass; 19 selected Release UI cases passed across
separate runs with identical production app source. The signed device archive
excludes simulator fixtures. Crash diagnostic build attribution is fixed in
live `events` v26. The owner reported repeated cold opens on 40 working;
build 41's new flows still need phone acceptance.

[Photographer client delivery](docs/studio/photographer-client-delivery.md) adds
an Agent / Photographer onboarding choice, a separate client contact and photo
per listing, private lead email routing, retained inquiry history and confirmed
resends. Client pages can hide service promotions while retaining the contact
form and privacy disclosure. This workflow is deployed to Studio, public pages
and the backend, released in build 39 and retained in the signed build-44 source. All 12
workflow exact-source CI jobs passed; see the
[release handoff](docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md) for live
readbacks and the controlled phone/inbox acceptance still required.

Existing Apple subscriptions can be restored or managed in the iPhone app under
**Settings → Plan & usage**. New paid checkout and plan changes are temporarily
unavailable in build 46. A new trial requires Apple eligibility and an exact
funded server reservation; dormant configuration stops before Apple's purchase
sheet. Signing in does not activate a trial or advance Apple's renewal date.
Studio uses the same account/workspace subscription and has no separate checkout.

[Open Studio](https://studio.rendprop.com/) · [Website](https://rendprop.com/) ·
[Core readiness release](docs/handoff/CORE-READINESS-20261001.md) ·
[App Store submission receipt](docs/releases/APPSTORE-42-20261002.json) ·
[Current internal TestFlight receipt](docs/releases/TESTFLIGHT-46-20261006.json) ·
[Public-page delivery receipt](docs/releases/TESTFLIGHT-37-20261001.json)

The [handheld room-tour update](docs/handoff/ROOM-TOUR-HANDHELD-20261001.md)
is available as internal **TestFlight 1.0.3 (38)**: a first-photo viewpoint anchor,
optional standing markers, a distinct yellow camera target, bounded hand movement,
gentler ceiling/floor angles and feedback after each saved photo. Older room
exports remain compatible. All 12 exact-source CI jobs, both iPhone-target builds
and three navigation-only UI checks pass. Apple availability was verified on
1 October 2026 at 22:17:40 UTC. Phone comfort and stitching quality still need acceptance.

The [room-guidance and photo-delivery update](docs/handoff/ROOM-TOUR-PHOTO-DELIVERY-20261001.md)
adds floor-based standing suggestions, clear automatic 38-photo viewpoint capture,
saved-view markers, retained photo versions and MLS/web/social downloads. Software
checks pass; internal **TestFlight 1.0.3 (36)** is available and Studio is live.
All 12 CI jobs passed on the archived source; all 30 Studio application assets match it.
Browser video export also prepares sources ahead and handles delayed animation callbacks.
Photo version history is local to iPhone. Build 41 adds local saved-version
publication; shared durable family/history selection remains separate work.
Physical room/camera quality still needs phone testing.

The [listing-first fly-through update](docs/handoff/LISTING-FIRST-FLYTHROUGH-20261001.md)
is live on public listing pages, with internal **TestFlight 1.0.3 (37)** available
to the existing Rendprop team. Photos and details load first; Watch fly-through
opens video separately and closing restores the listing position. New native
renders retain up to a 1920-pixel long edge at a 24 Mbps target, without upscaling,
and put MP4 metadata first. Re-render from the original local recording and
publish a **new sharing link** for higher quality; old links keep their earlier
video. Both exact runtime sources passed all 12 CI jobs; final live page checks
passed 153 assertions. Physical iPhone/Safari and real-footage acceptance remain.

## Production status — 4 October 2026

| Area | Current state |
| --- | --- |
| Studio web | Live: Create with chat editing, Simple/Pro controls, named projects, music mixing, captions, editing-copy preparation and browser MP4/WebM export. |
| Prompt enhancement | Live guided and model-backed suggestions, reviewed before use; AI editing and reviewed speech captions are enabled with bounded costs. |
| Prompt library | Ten original recipes, adaptation, saved personal collections and result notes. Copying a prompt does not generate media. |
| Property workflow | Account-scoped media, one private edit per user/property, saved conversation, capture plans, versions and team review. Save project to account explicitly uploads general-project originals. |
| AI Presenter | Preparation, approvals and execution controls deployed; Higgsfield generation remains disabled. |
| Published listing pages | Live: selected main photo/details first, compact navigation and optional Explore scroll viewer or Play video. Closing unloads the viewer and restores the listing position. Existing low-resolution files need a fresh original-source render and new link. |
| Photographer client delivery | Live: role choice, per-listing client card/headshot, private inquiry email, retained lead history and confirmed forwarding/resends. Optional promotional branding removal keeps domain/privacy disclosure. Actual cross-device and inbox acceptance remains pending. |
| iOS | Internal **1.0.4 (46)** is **AVAILABLE**, verified on 7 October at 00:47:51 UTC (6 October locally). Public **1.0.3 (42)** last reported **READY_FOR_SALE** at the 5 October read; no new public submission was made. Camera/room quality, purchase/restore, client inbox and phone-to-Studio acceptance remain. |
| Internal beta | Build **46** includes Measurements, the full-system audit fixes and dormant trial/purchase safeguards. The [current rollout](docs/handoff/TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md) records three trial migrations, three updated functions and verified Studio files. Trial funding/activation, protected-media, financial, provider-quality and phone acceptance remain open. |
| 3D walkthrough | Capture/upload/viewer and worker controls exist. Reconstruction quality has not passed acceptance; see the [spatial status](services/spatial-worker/README.md). |

The [1 October core release](docs/handoff/CORE-READINESS-20261001.md) deployed the
subscription/team backend fixes and Studio project-recovery fixes. All 12 CI jobs
passed on the archived source; all 30 live Studio files and 45 deployed backend
source copies were verified. That release delivered internal TestFlight 34. The
[guided-photo update](docs/handoff/GUIDED-PHOTO-CAPTURE-20261001.md) is now available
as [TestFlight 35](docs/releases/TESTFLIGHT-35-20261001.json), with all 12 CI jobs
passing on its archived source. Broad rollout still requires the documented phone
camera, purchase, restore, invitation and sync checks.

The earlier 27 September website release passed exact verification of **30 web files**; Studio API v12
matched **44 runtime source files**. Signed-in synthetic production checks passed
for source uploads, AI enhancement/editing, reviewed speech captions and a real
MP4 export. A full-page reload restored the QA project, sources and conversation.
Final CI passed **12/12 jobs**, and
[PR #8](https://github.com/AaronPilk/RendProp-Ai/pull/8) merged to main as `10e2b22`. The
[release record](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md) keeps these checks
separate from physical-phone, fresh Apple sign-in and second-browser acceptance.

## New creation tools

Studio now includes named private video projects with uploaded originals and
cross-browser restoration, imported music with mixing/fades/ducking, reviewed
beat-cut proposals, source-timed speech captions and speaking-passage suggestions.
An explicit local editing-copy tool prepares large recordings for the browser.
General projects need no property; property reels retain their agency review and
delivery workflow. See [projects and finishing](docs/studio/projects-and-finishing.md).

The [27 September release checkpoint](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
confirms the new website, four database migrations and Studio API v12 are deployed.
Bounded AI editing, prompt enhancement and speech analysis are activated, with a
successful signed-in synthetic upload-to-export-and-reload smoke. Four single-attempt
provider calls totaled **$0.2415 in estimated ledger cost**, not an invoice charge. [Editing intelligence activation](docs/studio/editing-intelligence-activation.md)
records gates, pricing estimates and acceptance checks. Presenter generation stays
disabled, and this work does not establish phone or spatial-quality acceptance.

## Pricing and cost safety

The [3 October pricing audit](docs/PRICING-AUDIT-20261003.md) verifies the current
US subscription prices and live plan/routing configuration. **A 75% minimum
margin is not currently enforced.** The report distinguishes customer-payment
and net-receipts margins, annual discounts, actual provider billing units and
paid paths that still need financial admission. Its proposed budgets are not
deployed; the older pricing documents are marked historical.

The [Claude audit reconciliation](docs/handoff/CLAUDE-AUDIT-RECONCILIATION-20261003.md)
confirms the deployed versions and available crash-feedback inventory, corrects
the 86% margin and anonymous-photo claims, and records why the older photo patch
would regress the separate saved libraries already shipped in build 43.

The [4 October Topaz and margin follow-up](docs/handoff/TOPAZ-AND-MARGIN-20261004.md)
records confirmed Small Business approval, the owner's 75% floor after Apple's
fee, and the correction deployed in `ai-video` v50 for a 4K source requested
at the 1080p tier. All Topaz
jobs retain the highest published tariff as a conservative budget reservation
until trusted decoding or invoice reconciliation supports a lower amount.

The [plan feature and allowance proposal](docs/PLAN-ALLOWANCES-20261004.md)
compares current photo/video/voice/chapter quantities with a shared weighted
AI balance. It includes concrete monthly and annual scenarios, keeps recurring
cost assumptions explicit, and records the unfinished financial admission.
These proposed quantities and customer credit packs are not deployed.

## Start developing

For Studio, use Node.js **22.12 or newer**:

```sh
cd apps/studio
npm ci
npm run dev
```

Local creation works without a backend. A connected workspace requires the
public Supabase configuration described in the [Studio README](apps/studio/README.md).
Never put service-role or provider credentials in frontend environment variables.

```sh
# From apps/studio: unit tests, typecheck, build and distribution checks
npm run verify
```

Browser media tests also exercise real encoded synthetic videos. See the
[CI workflow](.github/workflows/ci.yml) and each component's test instructions for
the required browser, Deno, Python, PostgreSQL and Xcode environments. Simulator
tests cannot validate physical camera, ARKit/LiDAR capture or thermal behavior.

## Repository map

| Path | Purpose |
| --- | --- |
| [apps/ios](apps/ios/README.md) | Swift/SwiftUI app and device workflow |
| [apps/studio](apps/studio/README.md) | React/Vite production Studio |
| [services/supabase/functions](services/supabase/functions/README.md) | Authenticated APIs, public handlers and provider orchestration |
| [services/supabase/migrations](services/supabase/migrations) | Current database schema, RLS and RPC migration history |
| [services/edge/tour-host](services/edge/tour-host/README.md) | Public website, hosted tours, agent pages and lead capture |
| [services/edge/upload-gateway](services/edge/upload-gateway) | Upload transport gateway |
| [services/worker](services/worker/README.md) | Optional server render worker, ownership leases and publication |
| [services/pipeline](services/pipeline/README.md) | Python image/hero enhancement and cost accounting |
| [services/spatial-worker](services/spatial-worker/README.md) | Gated spatial queue controller and provider lifecycle |
| [tools/spatial-spike](tools/spatial-spike/README.md) | Capture/training/viewer experiments and evaluation |
| [tools/style-policy](tools/style-policy/README.md) | Offline style plans and blind-comparison protocol |
| [services/marketing-video](services/marketing-video/README.md) | Standalone marketing-video composition prototypes |
| [apps/web/player](apps/web/player/README.md) | Archived standalone scroll-player prototype |
| [services/api](services/api/README.md), [infra](infra/README.md) | Historical API design and infrastructure pointers |

## Workflow and release documentation

- [Delivered Bria and saved-photo versions internal beta](docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md)
- [Create with chat and Improve prompt](docs/studio/conversational-creation.md)
- [Agency production, capture plans and review](docs/studio/agency-production-workflow.md)
- [Named video projects, music, captions and editing copies](docs/studio/projects-and-finishing.md)
- [Editing intelligence activation and acceptance](docs/studio/editing-intelligence-activation.md)
- [Prompt library](docs/studio/prompt-library.md)
- [AI Presenter and activation requirements](docs/studio/ai-presenter.md)
- [Brand assets](docs/brand/README.md)
- [iOS test boundaries](apps/ios/RendpropUITests/README.md)
- [Room guidance, edited-photo downloads and disclosure boundaries](docs/handoff/ROOM-TOUR-PHOTO-DELIVERY-20261001.md)
- [Current photographer client delivery release](docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md)
- [27 September Studio release record](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
- [24 September production baseline](docs/handoff/CODEX-STUDIO-LIVE-20260924.md)

The [original master build prompt](docs/MASTER-BUILD-PROMPT.md) records product
intent and planned work. Current source, tests and dated deployment receipts
establish what is implemented and live; roadmap language is not a shipping claim.
Historical audit and release folders retain their original measurements.

Use isolated branches when collaborating. Preserve migration history and existing
function authentication settings; apply schema before dependent handlers and web
assets. The updated [backend deployment helper](apps/studio/scripts/deploy-backend.mjs)
requires explicit function selection, stages offline by default and preserves
the declared JWT policy. With `--run`, it checks live policy and verifies deployed
source hashes. No disabled provider or spatial gate
should be activated merely to complete a UI demonstration.
