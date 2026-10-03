# Rendprop

Rendprop brings phone capture, video editing, AI creative tools and property
marketing into one workspace. Capture photos and walkthrough footage on iPhone,
continue a property edit in Studio, and prepare reels and hosted property pages.
Real estate is the primary workflow; the app also supports other space types.

Internal **TestFlight 1.0.3 (43) is AVAILABLE**, verified **3 October 2026 at
00:55:46 UTC** (2 October locally) for the existing Rendprop team.
The [Bria and saved-photo beta handoff](docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md)
records consent v3, direct Bria limited to the internal scheme and an explicit
authenticated tester allowlist, Latest/Decluttered/Staged downloads, separate
listing selection and reel stop/resume with retained completed clips. All twelve
CI jobs passed on uploaded runtime `8de8fd0`. Backend **ai-video v47** is live,
JWT verification is enabled and all 30 deployed files match. The
[delivery receipt](docs/releases/TESTFLIGHT-43-20261002.json) binds the signed
archive, one internal upload, Apple availability, testing notes and schema readbacks.
The single historical Bria output CDN is a narrow beta starting allowlist, with
possible paid outputs stranded at unknown hosts. Normal fal processing and the
existing AI clip allowance/budget contract remain. Local tests do not certify
camera or generated-media quality.

Regular **App Store 1.0.3 (42)** was submitted **2 October 2026 at 20:17:03 UTC**
and is **Waiting for Review**, with automatic release after approval. All twelve
CI jobs passed on uploaded runtime `204594a`. Spatial capture remains confined
to internal **TestFlight 43**; select **Previous Builds → 1.0.3 (43)** to keep
testing it. The [App Store receipt](docs/releases/APPSTORE-42-20261002.json) and
[release handoff](docs/handoff/APPSTORE-42-20261002.md) record the exact binary,
Apple state and verification limits. Studio now waits for original media to be
saved before accepting newly imported media; this fix is deployed and all 31 live assets
match the release. Direct Bria was not enabled in build 42; its delivery snapshot
is separate from the delivered internal build 43. The public build-42 binding and
Waiting for Review state were read back after the internal upload.

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
and the backend, released in build 39 and retained in current build 43. All 12
workflow exact-source CI jobs passed; see the
[release handoff](docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md) for live
readbacks and the controlled phone/inbox acceptance still required.

Apple subscription plans are selected, upgraded and changed in the iPhone app
under **Settings → Plan & usage**. A seven-day trial starts only after confirming
an eligible Apple subscription offer; installing the app or signing in does not
activate a trial. Studio uses the same account/workspace subscription.

[Open Studio](https://studio.rendprop.com/) · [Website](https://rendprop.com/) ·
[Core readiness release](docs/handoff/CORE-READINESS-20261001.md) ·
[App Store submission receipt](docs/releases/APPSTORE-42-20261002.json) ·
[Current internal TestFlight receipt](docs/releases/TESTFLIGHT-43-20261002.json) ·
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

## Production status — 2 October 2026

| Area | Current state |
| --- | --- |
| Studio web | Live: Create with chat editing, Simple/Pro controls, named projects, music mixing, captions, editing-copy preparation and browser MP4/WebM export. |
| Prompt enhancement | Live guided and model-backed suggestions, reviewed before use; AI editing and reviewed speech captions are enabled with bounded costs. |
| Prompt library | Ten original recipes, adaptation, saved personal collections and result notes. Copying a prompt does not generate media. |
| Property workflow | Account-scoped media, one private edit per user/property, saved conversation, capture plans, versions and team review. Save project to account explicitly uploads general-project originals. |
| AI Presenter | Preparation, approvals and execution controls deployed; Higgsfield generation remains disabled. |
| Published listing pages | Live: selected main photo/details first, compact navigation and optional Explore scroll viewer or Play video. Closing unloads the viewer and restores the listing position. Existing low-resolution files need a fresh original-source render and new link. |
| Photographer client delivery | Live: role choice, per-listing client card/headshot, private inquiry email, retained lead history and confirmed forwarding/resends. Optional promotional branding removal keeps domain/privacy disclosure. Actual cross-device and inbox acceptance remains pending. |
| iOS | Regular **1.0.3 (42)** submitted and **Waiting for Review**; public release follows Apple approval. Internal **43** is available for spatial and Bria beta tests. Camera/room quality, purchase/restore, client inbox and phone-to-Studio acceptance remain. |
| Internal beta | **1.0.3 (43)** delivered; direct-Bria backend **ai-video v47** deployed with one trusted tester, fresh consent, existing AI clip limits and budgets. Saved-photo libraries/downloads and reel failure recovery are delivered. Real provider quality and phone acceptance remain; see the [handoff](docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md). |
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
