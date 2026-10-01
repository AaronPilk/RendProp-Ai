# Rendprop iOS

Native Swift/SwiftUI app for iPhone, targeting iOS 16 and later. The app captures
and imports property media, creates tours and reels, provides AI photo/video
workflows, and connects a named account's workspace with
[Studio](https://studio.rendprop.com/). The normal build uses the live Supabase
backend; this is no longer an offline-only prototype.

## Release status

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
