# Rendprop iOS

Native Swift/SwiftUI app for iPhone, targeting iOS 16 and later. The app captures
and imports property media, creates tours and reels, provides AI photo/video
workflows, and connects a named account's workspace with
[Studio](https://studio.rendprop.com/). The normal build uses the live Supabase
backend; this is no longer an offline-only prototype.

The [Measurements addition](../../docs/floor-plan-measurements.md) is implemented
in the signed **1.0.4 (44)** source `9d27fb5`: named room dimensions in
feet/inches or metres, irregular wall outlines, categorized area worksheets,
image and all-floors PDF export, 3D shapes and optional ARKit estimates.
Calculated closing walls stay labeled; linked open-below deductions subtract
once. It retains existing scans/uploads and uses private measurement metadata.
The [4 October audit fixes](../../docs/handoff/CLAUDE-AUDIT-REMEDIATION-20261004.md)
add an independent compare-and-set save, preserved conflicting local copies,
safe create retries, legacy snapshot recovery, photo gallery reconciliation and
export source/date records, US Letter PDFs and explicit phone-ruler limitations.
Both matching migrations and tours v49/listings v41/ai-video v51 are deployed.
Coach v22/admin v30 remain for older-client compatibility; the new native Coach
privacy and scope changes are included. Build 44 is available to the existing
internal Rendprop team. Physical AR accuracy, camera quality and phone Files/Photos delivery
need owner checks.

## Release status

The [October 5 complete feedback follow-up](../../docs/handoff/BETA-FEEDBACK-20261005.md)
is isolated source work after build 44. Home and collections use a clickable app
guide instead of sample listings. Measurements remains usable for entered rooms,
outlines, worksheets and uploaded plans; automatic 3D capture cards say Coming soon
and saved scans remain viewable. Profile gains contact-only business-card sharing,
chosen portfolio listings and a distinct hosted business logo. Personal cards use
account identity rather than the selected workspace's branding and have an explicit
Save action. Identically named workspaces show distinct workspace IDs. Other changes include
verified guest-card/draft recovery and retained paid-request blockers during sign-in,
JPEG/Files download, clearer plan selection, scoped Coach recovery, reviewed nearby
places and recovery of existing accepted reel jobs. The report distinguishes source
checks from signed release, real camera/AR and paid AI output acceptance.

Internal **TestFlight 1.0.4 (44): AVAILABLE**, verified **5 October 2026 at
01:32:22 UTC** (4 October locally) for the existing Rendprop team. Apple reports
VALID / INTERNAL_ONLY / IN_BETA_TESTING, with the build included in that group.
The signed archive uses source `9d27fb5`, with all twelve
jobs passing in [CI run 37248967678](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37248967678).
Its independent archive check binds 226 source inputs, 142 tracked Swift inputs,
one generated Swift input and matching archive/DerivedData dSYM bytes and UUID.
The [build-44 receipt](../../docs/releases/TESTFLIGHT-44-20261004.json) records
one successful internal upload and Apple build ID
`2cab4332-f370-408a-92bf-7608d5d7915e`. The actual uploaded IPA is retained;
English testing notes were verified at **01:34:36 UTC on 5 October 2026**. This is an internal lab build, including Measurements, spatial
capture and the retained Bria beta workflow.

**The ordinary full-row listing bug remains in 44.** A stale main-photo or
coordinate save can overwrite newer Studio facts, sold/archive state and plan
attachments. Measurements use an independent CAS and retain conflicting local
geometry; that protection does not repair ordinary writes. Shared-team launch
needs explicit changed-field intent, atomic conflict handling and an older-client
upgrade boundary. Paid FAL output, camera/AR quality, two-device sync and actual
phone Files/Photos delivery remain acceptance checks.

Internal **TestFlight 1.0.3 (43): recorded AVAILABLE**, verified **3 October 2026 at
00:55:46 UTC** (2 October locally). Apple reports VALID / INTERNAL_ONLY /
IN_BETA_TESTING in the existing Rendprop team group; English testing notes were
verified at 00:56:33 UTC. The [delivery receipt](../../docs/releases/TESTFLIGHT-43-20261002.json)
binds uploaded runtime `8de8fd0`, all twelve passing CI jobs, the signed archive
and the retained actual Apple Distribution IPA.
The [Bria and saved-photo versions handoff](../../docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md)
records the new direct-Bria consent v3, an internal-scheme acknowledgement plus
explicit server tester allowlist, saved Latest/Decluttered/Staged libraries,
viewed-version downloads and separate listing selection. Photo history remains
local to the iPhone. Reel generation now stops on the first failure and retains
completed clips for finishing without regeneration; the underlying fal 502 cause
remains unproven. All 27 available beta attachments were reviewed with zero new
crash reports surfaced. At that historical delivery, **ai-video v47** was deployed; all 30
files, schema bodies, grants and private beta configuration were verified.
Six Debug UI cases and one focused Release/arm64 simulator case passed across
preserved runs using production native code identical to the archive, synthetic
photos and MockAPIClient. Camera/media quality, real provider output and Files/Photos delivery
remain phone checks. The submitted build-42 snapshot remains unchanged.

Regular **App Store 1.0.3 (42)** is now reported **READY_FOR_SALE** by Apple GET
preflight at **01:18:40 UTC on 5 October 2026** (4 October locally), still bound
to the original build-42 ID. The
[receipt](../../docs/releases/APPSTORE-42-20261002.json) and
[handoff](../../docs/handoff/APPSTORE-42-20261002.md) preserve the original
2 October submission and Waiting for Review snapshot; the
[build-44 receipt](../../docs/releases/TESTFLIGHT-44-20261004.json) records this
newer readback. Public runtime `204594a` passed all twelve CI jobs and uses the
regular scheme, which hides spatial capture and blocks new spatial admission
and inherited upload recovery. AI photo batches stop unsent requests after
consent revocation. Physical builds ignore simulator UI-test switches.
Build 42 excludes the internal experimental entry points. Apple release state
does not certify physical camera or media quality.

The [beta feedback release](../../docs/handoff/BETA-POLISH-20261002.md) is available
as internal **TestFlight 1.0.3 (41)**, verified **2 October 2026 at 17:23:58 UTC**
for the existing Rendprop team. It adds labeled client cards/private routing,
unit entry, prominent property editing, keyboard-safe room tags, top photo progress
across navigation, permitted completion notifications and saved-version publication.
All 12 CI jobs passed on archived runtime `3615a23`; the
[delivery receipt](../../docs/releases/TESTFLIGHT-41-20261002.json) binds the signed
archive, one internal upload and Apple availability/English notes. Five beta UI
cases passed across preserved runs; final queue navigation and cold toolbox runs
use native inputs identical to the archive. This is not one all-green twelve-case
UI run. Jobs do not resume automatically after force-quit. Staging output and real
walking motion still need review; software checks are not camera acceptance.

[Crash hardening](../../docs/handoff/IOS-CRASH-HARDENING-20261002.md) was delivered
as internal **TestFlight 1.0.3 (40)**, verified **2 October 2026 at 01:18:15 UTC**
for the existing Rendprop team. All 12 CI jobs passed on archived source
`4580f76`; [the delivery receipt](../../docs/releases/TESTFLIGHT-40-20261002.json)
binds the signed archive, one upload, Apple availability and English testing notes.
Named concrete listing-toolbox and launch views bound Swift metadata construction;
checked duration/FPS conversion and duplicate-ID detection remove two independently
reproduced traps while retaining saved work. Nineteen selected Release UI cases
passed across separate runs with identical production app source. Simulator
fixtures are absent from the signed device binary. The owner reported repeated
cold opens on 40 working. Repeat acceptance on 41 without deleting the app or
recordings. Live `events` v26 retains narrow diagnostic build strings.

[Photographer client delivery](../../docs/studio/photographer-client-delivery.md)
adds a real estate role choice, per-property client contact/photo editing,
independent offline contact drafts and current server-state verification before
either publish entry, with dirty contact edits saved first. Client lead status
and deliberate resends remain tied to the
selected account and workspace. The preceding internal **TestFlight 1.0.3 (39)** is available,
verified at **23:41:47 UTC on 1 October 2026**, with all 12 exact-source CI jobs
passing. [The receipt](../../docs/releases/TESTFLIGHT-39-20261001.json) and
[handoff](../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md) bind the
signed source, single upload, production readbacks and testing notes. Actual
phone-to-Studio contact sync and client inbox delivery require controlled acceptance.

The [handheld room-tour update](../../docs/handoff/ROOM-TOUR-HANDHELD-20261001.md)
is available as internal **TestFlight 1.0.3 (38)** to the existing Rendprop team,
verified **1 October 2026 at 22:17:40 UTC**. All 12 CI jobs passed on archived
source `ba5c52c`; [the delivery receipt](../../docs/releases/TESTFLIGHT-38-20261001.json)
binds the source, signed archive, one upload, Apple availability and testing notes.
It sets the viewpoint from
the first admitted still photo, makes floor markers optional, distinguishes the
yellow photo target, permits natural adjustment within explicit geometry bounds,
and uses gentler ceiling/floor angles with saved-photo haptics. Both iPhone targets
compile and three navigation-only UI checks pass. Existing v1 exports remain
compatible; real-phone usability and stitching acceptance are pending.

The [listing-first fly-through update](../../docs/handoff/LISTING-FIRST-FLYTHROUGH-20261001.md)
is available as internal **TestFlight 1.0.3 (37)** to the existing Rendprop team.
Apple availability was verified on **1 October 2026 at 20:50:00 UTC**: `VALID`,
`INTERNAL_ONLY`, `IN_BETA_TESTING`. All 12 CI jobs passed on archived source
`512fb8b`; [the delivery receipt](../../docs/releases/TESTFLIGHT-37-20261001.json)
binds source, signed archive, one upload and Apple readback. English testing notes
were read back at 20:54:55 UTC. Public listing pages are also live, with final
readback of the web-only follow-up `a87834c` passing 153 assertions.

New native renders retain up to a **1920-pixel long edge** at a **24 Mbps target**,
without upscaling, and move MP4 metadata to the front. Open the Fly-through detail
screen and choose **Re-render fly-through** using the original local recording.
Publishing creates a **new sharing link**; old links keep their earlier video.
Real footage, phone render/storage/upload costs and mobile Safari playback still
need owner acceptance. Build37 retains the guided room/photo, workspace and
subscription changes below.

The [room-guidance and photo-delivery release](../../docs/handoff/ROOM-TOUR-PHOTO-DELIVERY-20261001.md)
is available as internal **TestFlight 1.0.3 (36)** to the existing Rendprop team.
Apple availability was verified on **1 October 2026 at 19:42:18 UTC**: `VALID`,
`INTERNAL_ONLY`, `IN_BETA_TESTING`. All 12 CI jobs passed on the archived source
`0e7c78c`; [the delivery receipt](../../docs/releases/TESTFLIGHT-36-20261001.json)
binds source, signed archive, single upload and Apple readback.
Guided room tour now starts with floor-based spot suggestions or a manual fallback,
then shows automatic 38-photo viewpoint progress. Photos keeps local immutable
versions/originals and adds single/batch export to Files or Photos, destination
disclosures and previewed aspect choices. Published gallery uploads remain append-only;
local version selection does not yet synchronize as a shared history contract.

Run `bash apps/ios/tests/run-photo-delivery.sh` and
`bash tools/spatial-spike/capture-ios/verify-room-guidance.sh` from the repository root.

The [guided photo-camera update](../../docs/handoff/GUIDED-PHOTO-CAPTURE-20261001.md)
is available as internal **TestFlight 1.0.3 (35)** to the existing Rendprop team,
verified **1 October 2026 at 17:06:20 UTC**. It adds supported physical 0.5×/1×
lenses, grid/level, landscape guidance and full-photo review/retake to Photos and
exterior capture. Save failures keep the captured image available to retry.
Apple reports `VALID`, `INTERNAL_ONLY` and `IN_BETA_TESTING`; all 12 source CI
jobs passed. See the [delivery receipt](../../docs/releases/TESTFLIGHT-35-20261001.json).
Physical camera quality and preview-to-photo framing still need phone acceptance.

Run its pure policy and file-retention checks with
`bash apps/ios/tests/run-photo-capture.sh` from the repository root.

The preceding core release, **TestFlight 1.0.3 (34)**, was verified available to
the existing Rendprop team on **1 October 2026 at 15:30:20 UTC**. It adds subscription-confirmed trials,
**Settings → Plan & usage** controls, explicit personal/team workspace selection,
and account/draft/branding recovery fixes. Apple reports `VALID`, `INTERNAL_ONLY`
and `IN_BETA_TESTING`; all 12 source CI jobs passed. See the
[core audit and phone checklist](../../docs/handoff/CORE-READINESS-20261001.md) and
[delivery receipt](../../docs/releases/TESTFLIGHT-34-20261001.json). Actual Apple
sandbox purchase/restore and camera acceptance remain phone tests. The existing
guided room-tour lab is retained unchanged.

The [1 October guided room-tour build](../../docs/handoff/GUIDED-PANORAMA-TESTFLIGHT-20261001.md)
adds stationary scan positions, optional native LiDAR depth, local 4K panorama
previews and saved-tour export. Internal TestFlight **1.0.3 (33)** was delivered to the existing Rendprop team,
verified **1 October 2026 at 13:37:54 UTC**. Apple reports `VALID`,
`INTERNAL_ONLY` and `IN_BETA_TESTING`; all 12 CI jobs passed. The
[delivery receipt](../../docs/releases/TESTFLIGHT-33-20261001.json) binds source,
archive, upload and Apple readback. Open
**Home → Guided room tour**. This prototype saves on the phone and does not yet
publish or synchronize panoramic tours, provide a dollhouse, or certify dimensions.

The preceding [internal TestFlight 1.0.3 (32)](../../docs/handoff/CODEX-IOS-SPATIAL-PHONE-20260930.md)
was delivered to the existing Rendprop team, verified **30 September 2026 at
18:32 UTC**. Apple reports `VALID`, `INTERNAL_ONLY` and `IN_BETA_TESTING`.
The archive is from `79ee683` and includes the motion-blur guard, capture planning,
multi-video library and native sync/recovery fixes. Physical-phone acceptance is
still pending. [project.yml](project.yml) declares **1.0.3 (31)**; this archive
explicitly used build 32. The previous delivered build was
[31 on 22 September](../../docs/handoff/CLAUDE-LIVE-DELIVERY-20260922.md).

The [24 September Studio release](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
deployed the website, database and edge functions without an iOS release. The
[native build handoff](../../docs/handoff/CODEX-NATIVE-BUILD-20260924.md) records
that day's unsigned compilation checks. Capture-plan and multi-video library
code is now included in build 32 and still needs the
[real-device agency checklist](../../docs/studio/agency-production-workflow.md#acceptance-on-a-real-phone).

On 30 September the owner explicitly authorized the TestFlight upload. One
upload succeeded and build availability was read back from Apple; no App Store
version attachment or review submission occurred. The earlier local development
candidate was not installed directly. The
[delivery receipt](../../docs/releases/TESTFLIGHT-32-20260930.json) binds source,
artifact and test evidence. Production reconstruction remains off. The earlier walking-capture diagnostic
remains at **Settings → TestFlight lab → Spatial capture (TestFlight)**; use
**Home → Guided room tour** for the build-33 panorama test.

## Build locally

Use a Mac with Xcode, its installed iOS SDK, and XcodeGen.
Run from an isolated checkout when another developer is working in the repo:

```bash
cd apps/ios
xcodegen generate --spec project.yml
open Rendprop.xcodeproj
```

`project.yml` is the source of truth for targets, source membership, signing,
version settings and the shared scheme. Regenerate after adding Swift files;
review the generated project diff before committing it. The generated project
includes the shared spatial capture sources from `tools/spatial-spike/capture-ios`,
including `CaptureBlur.swift`. The separate `project-spatial-testflight.yml`
inherits that registration and adds the explicit `SPATIAL_CAPTURE_LAB`
compilation condition plus the station/panorama sources. Keep both generated projects current; neither replaces
the existing production-plan and video-library source references.
Do not change the production bundle identity (`com.rendprop.app`) to bypass a
signing error: Apple sign-in, entitlements and purchases depend on it.

Select a simulator for navigation and synthetic-media checks. For actual
capture, the owner must select a physical iPhone and grant camera, microphone,
photos and motion permissions as needed. Signing and provisioning must match
the selected team and device.

## App and backend responsibilities

| Area | Repository implementation and boundary |
| --- | --- |
| Capture | Guided still photos with physical lens selection, grid/level, review/retake and acknowledged saves; video recording, room tags, motion sidecars, pause/resume, saved-take recovery and media import. Camera quality, preview-to-photo framing, interruptions, lenses and thermal behavior require a real phone. |
| Uploads | Live uploads choose the server's single/multipart path, with persistent recovery and a cellular warning. Local originals must finish uploading before another device can use them. There is no current Settings picker for simulate/direct/tus. |
| Authentication | Sign in with Apple through Supabase; tokens in Keychain. Local capture and editing remain usable offline. Anonymous sessions support eligible server actions; use the same named account and workspace for phone/desktop continuity. |
| Sync | Property data, uploaded media, supported native reel setup and property documents use the shared backend. This does not mean the native and desktop editors have identical timelines or features. |
| Creation | AI Photo Studio, reels, aerial intros, reflection workflows, scripts and Coach call server-side APIs. Availability, consent, plans and provider configuration still apply. No provider secret belongs in the app. |
| Production workflow | Property capture plans, checklist state and separate video clip imports; see the agency guide for review/copy/version behavior on desktop. A checked shot is not a media-quality certificate. |
| Spatial | Product UI, capture/upload and viewer integration exist. Hardware support and server runtime gates determine availability; this README does not enable them or certify real-room quality. |
| Plans and notifications | StoreKit 2 products/entitlement sync and APNs registration are implemented. Product prices come from StoreKit; successful sandbox/device checks are separate from local fixtures. |
| Tours | The bundled WKWebView player, branded/unbranded publication surfaces, business card and leads use the existing tour system. |

[Config.swift](Rendprop/Config.swift) selects `useLiveBackend`, `enableAuth`,
`enableIAP` and `enablePush` (currently true). `makeAPIClient()` normally creates
`LiveAPIClient`; `-uiTesting` selects `MockAPIClient`. The Debug-only
`-sessionNetworkTesting` path instead uses loopback HTTP fixtures. These testing
modes do not establish production health.

The Supabase URL and public client key can be supplied through
`RENDPROP_SUPABASE_URL` / `RENDPROP_SUPABASE_ANON_KEY` in Info.plist. Never put a
service-role key, Apple private key or provider credential in the app bundle.
Money is represented as integer cents.

## Tests and phone acceptance

- [Build-44 audit verification and remaining limits](../../docs/handoff/CLAUDE-AUDIT-REMEDIATION-20261004.md#verification)
- [Historical build-43 tests and phone checklist](../../docs/handoff/BRIA-PHOTO-VERSIONS-BETA-20261002.md#verification-and-evidence-boundaries)
  links the new actual-source consent, photo-history, reflection and reel failure
  checks. The new Release saved-photo UI case uses MockAPIClient and synthetic
  photos; provider output, Files/Photos delivery and physical capture need phone
  acceptance after delivery gates pass.
- [UI tests](RendpropUITests/README.md) distinguish screenshot walks, assertion
  tests, synthetic saved-take recovery and loopback session tests. Some cases
  require fixtures; running the entire bundle blindly is not a release check.
- [Native tests](tests/) contain focused Swift regression fixtures.
- [Guided photo camera](../../docs/handoff/GUIDED-PHOTO-CAPTURE-20261001.md#phone-acceptance)
  covers both lenses, orientation, framing, saving and real-phone interruptions.
  Its executable checks verify software policy and file retention, not camera hardware.
- [Agency workflow](../../docs/studio/agency-production-workflow.md) covers the
  phone → upload → desktop edit → review path and its current limits.
- [Studio creation](../../docs/studio/conversational-creation.md) documents chat
  editing and reviewed prompt enhancement. These are deployed web capabilities,
  not a claim that the current TestFlight app contains the desktop UI.
- [Spatial phone checklist](../../tools/spatial-spike/IPHONE-TESTFLIGHT-CHECKLIST.md)
  covers physical capture. Simulator results cannot certify camera, AR tracking,
  room coverage or output quality.

Keep [the bundled player](Rendprop/Resources/player/) consistent with
[the production tour host](../../services/edge/tour-host/README.md) when changing
shared playback behavior. The standalone `apps/web/player` prototype is archived.
