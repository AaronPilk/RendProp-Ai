# Rendprop iOS

Native Swift/SwiftUI app for iPhone, targeting iOS 16 and later. The app captures
and imports property media, creates tours and reels, provides AI photo/video
workflows, and connects a named account's workspace with
[Studio](https://studio.rendprop.com/). The normal build uses the live Supabase
backend; this is no longer an offline-only prototype.

## Release status

[project.yml](project.yml) currently declares **1.0.3 (31)**. The last committed
phone delivery receipt is [22 September 2026](../../docs/handoff/CLAUDE-LIVE-DELIVERY-20260922.md):
internal TestFlight 1.0.3 (31), archived from `337991a`, available to the existing
Rendprop team. These source version numbers alone do not prove that later code
has reached a phone.

The [24 September Studio release](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
deployed the website, database and edge functions, with **no iOS release or App
Store Connect action**. New phone capture planning and multi-video library code
is in this repository; it still needs a matching phone build and the
[real-device agency checklist](../../docs/studio/agency-production-workflow.md#acceptance-on-a-real-phone).
On 24 September, the combined source passed two **unsigned Release builds for
`generic/platform=iOS`**: normal `Rendprop` and the explicit
`RendpropSpatialTestFlight` overlay. Both used `CODE_SIGNING_ALLOWED=NO`; no
simulator, camera, archive, upload or App Store Connect operation was involved.
The [native build handoff](../../docs/handoff/CODEX-NATIVE-BUILD-20260924.md)
records source registration, exact receipt/log hashes and the remaining owner
steps. This proves compilation of the recorded source, not delivery to a phone.
Current public App Store status has not been rechecked for this documentation
refresh. App Store Connect and phone acceptance remain owner-operated.

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
inherits that registration and adds only the explicit `SPATIAL_CAPTURE_LAB`
compilation condition. Keep both generated projects current; neither replaces
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
| Capture | Video recording, room tags, motion sidecars, pause/resume, saved-take recovery and media import. Camera quality, interruptions, lenses and thermal behavior require a real phone. |
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
