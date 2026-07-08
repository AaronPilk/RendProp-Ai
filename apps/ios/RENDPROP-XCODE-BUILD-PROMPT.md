# RENDPROP — XCODE BUILD PROMPT (Phase 1 iOS, on-device)
### Stand up the real native iOS app in Xcode, get it on a physical iPhone, with camera + import + large-file resumable upload.

> **HOW TO USE:** Run this on a **Mac with Xcode 15+** using **Claude Code** (or a senior iOS dev). Paste this whole file as the task. It produces a **runnable** native SwiftUI app named **Rendprop** that installs on a physical iPhone via Xcode. It intentionally scopes to Phase 1 essentials and **stubs the backend** so the app runs end-to-end offline first; the camera, motion logging, media import, and large-file upload are REAL. The full product spec is `docs/MASTER-BUILD-PROMPT.md` in this repo — this prompt is the concrete Xcode bring-up of Part 4 / Part 34 of that spec.
>
> **App name:** Rendprop · **Bundle ID:** `com.rendprop.app` · **Min iOS:** 16.0 · **Language:** Swift 5.9+, SwiftUI lifecycle · **Location:** build in `apps/ios/` of this repo.

---

## 0. DELIVERABLE (definition of done for THIS prompt)
A Swift/SwiftUI app that, when opened in Xcode and run on a connected iPhone:
1. Launches to an Apple-native UI (SF Pro, SF Symbols, system materials, haptics, dark mode, large titles).
2. **Records video with the camera** (AVFoundation), with live guided-capture overlays (level bubble, pace ring, light warning).
3. **Logs a gyro/IMU sidecar** (CoreMotion) time-synced to the recording and saves it next to the video.
4. **Imports existing videos** from Photos (PHPicker) and Files (drone clips, UIDocumentPicker) without loading them into memory.
5. **Tags rooms** on a timeline (chapter markers).
6. **Uploads large files (multi-GB) reliably**: chunked, streamed from disk, background `URLSession`, resumable across app-kill/network-loss, with a cellular-size warning — to a **configurable endpoint** (presigned PUT/multipart) with a **dev "simulate upload" fallback** so it runs with no backend.
7. Shows a **My Listings** home, a **New Listing** flow, a **Review/Submit** screen (mock pricing), and a **Settings** screen — all driven by a **stubbed API layer** (protocol + mock impl) so nothing requires a live server.
8. Embeds the existing web player (`apps/web/player/index.html`) in a `WKWebView` for the flythrough preview.
9. Builds with **zero warnings-as-errors issues** and runs on a **free personal provisioning profile** (7-day) or a paid dev account. Include on-device run instructions.

Anything not in Phase 1 (Apple IAP, Sign in with Apple, APNs, MLS) is **stubbed behind feature flags** so the app still builds and runs; leave clean TODOs referencing the master spec.

---

## 1. PROJECT GENERATION — use XcodeGen (reproducible)
Do NOT hand-craft a `.xcodeproj` by clicking Xcode. Use **XcodeGen** so the project is declarative and regenerable by an agent.

- Add a `project.yml` at `apps/ios/`. Install XcodeGen if needed (`brew install xcodegen`) and run `xcodegen generate`.
- Also add a **Swift Package Manager** setup for dependencies (XcodeGen supports SPM packages in `project.yml`).

**`apps/ios/project.yml` (author this):**
```yaml
name: Rendprop
options:
  bundleIdPrefix: com.rendprop
  deploymentTarget:
    iOS: "16.0"
  createIntermediateGroups: true
settings:
  base:
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "5.9"
    DEVELOPMENT_TEAM: ""          # set to your Team ID for device signing
    CODE_SIGN_STYLE: Automatic
    GENERATE_INFOPLIST_FILE: NO
    INFOPLIST_FILE: Rendprop/Info.plist
    ENABLE_USER_SCRIPT_SANDBOXING: YES
packages:
  # Resumable upload (tus). If you don't stand up a tus server yet, the app's
  # DirectUploader (presigned multipart) path + Simulate mode cover dev.
  TUSKit:
    url: https://github.com/tus/TUSKit
    from: 3.4.0
targets:
  Rendprop:
    type: application
    platform: iOS
    sources: [Rendprop]
    entitlements:
      path: Rendprop/Rendprop.entitlements
      properties:
        aps-environment: development        # remove until APNs is wired if it blocks free signing
    dependencies:
      - package: TUSKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.rendprop.app
        TARGETED_DEVICE_FAMILY: "1"          # iPhone
        SUPPORTS_MACCATALYST: NO
```
> Note: for a **free personal team** (7-day on-device), remove capabilities that require a paid account (APNs/`aps-environment`, Sign in with Apple, IAP). Keep them behind flags. Document both paths.

---

## 2. CAPABILITIES & INFO.PLIST (author these files)

**`Rendprop/Info.plist` — required purpose strings (app crashes/rejects without them):**
```xml
<key>NSCameraUsageDescription</key>
<string>Rendprop uses your camera to record a walkthrough of the property.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Rendprop records audio with your walkthrough (optional; muted in the flythrough).</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Import an existing walkthrough or drone video from your photo library.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Save rendered flythroughs and teasers to your photo library.</string>
<key>NSMotionUsageDescription</key>
<string>Rendprop reads motion data to stabilize your video and guide a steady, level walkthrough.</string>
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
<key>UISupportedInterfaceOrientations</key>
<array><string>UIInterfaceOrientationPortrait</string></array>
<key>UILaunchScreen</key>
<dict/>
```
(Background URLSession does not require a background mode entry, but keep `processing` for finalize tasks. Add `NSUserTrackingUsageDescription` only if you later add ATT. Add Associated Domains + Push + Sign in with Apple entitlements in Phase 2.)

**`Rendprop/Rendprop.entitlements`:** start minimal (empty dict) for free signing; add `com.apple.developer.applesignin`, `aps-environment`, and `com.apple.developer.associated-domains` when on a paid team.

---

## 3. FILE / FOLDER MANIFEST (create these under `apps/ios/Rendprop/`)
```
RendpropApp.swift                 // @main App, root navigation, appearance setup
Config.swift                      // API base URL, feature flags, upload mode (direct|tus|simulate)
DesignSystem/
  Theme.swift                     // colors (brand gold #D9A441 accent on near-black), spacing, radii
  Typography.swift                // SF Pro text styles, Dynamic Type
  Haptics.swift                   // UIFeedbackGenerator wrappers
  Components.swift                // PrimaryButton, Card, StatusChip, GlassBar (.ultraThinMaterial)
Models/
  Listing.swift  Render.swift  CaptureAsset.swift  RoomTag.swift  Money.swift
Networking/
  APIClient.swift                 // protocol
  MockAPIClient.swift             // returns sample listings/renders — app runs offline
  LiveAPIClient.swift             // real impl (stub endpoints, ready to point at services/api)
Auth/
  AuthStore.swift                 // Keychain token store; stub "signed-in" for dev
Capture/
  CameraManager.swift             // AVCaptureSession + AVCaptureMovieFileOutput/AVAssetWriter
  MotionRecorder.swift            // CMMotionManager → gyro sidecar JSON (PTS-synced)
  CaptureView.swift               // SwiftUI camera screen + overlays
  GuidanceOverlays.swift          // level bubble, pace ring + haptics, light meter, grid
  RoomTagBar.swift                // live room-tag buttons
Import/
  MediaImporter.swift             // PHPicker (videos) + UIDocumentPicker (Files), file-URL based
Upload/
  UploadManager.swift             // background URLSession, chunked, resumable, persisted state
  DirectUploader.swift            // presigned multipart/PUT (no server dep beyond signed URLs)
  UploadStore.swift               // persist offsets/sessions to disk (resume across launches)
Screens/
  OnboardingView.swift  HomeListingsView.swift  NewListingView.swift
  ReviewSubmitView.swift  RenderStatusView.swift  FlythroughDetailView.swift
  PlayerWebView.swift             // WKWebView wrapping apps/web/player
  SettingsView.swift
Support/
  FileStore.swift                 // app container paths, free-space checks
  Formatters.swift
Resources/
  Assets.xcassets                 // AppIcon (Rendprop), accent color, symbols
  player/                         // bundle a copy of apps/web/player for offline preview (or load remote)
```

---

## 4. MODULE SPECS (implement these; keep it Apple-idiomatic + Swift Concurrency)

### 4.1 Camera (the crown jewel)
- `AVCaptureSession` on a dedicated queue; discover best `AVCaptureDevice.Format` supporting **4K/60** (fallback 4K/30 → 1080p/60); set `AVCaptureConnection.preferredVideoStabilizationMode = .cinematicExtended`; lock orientation to portrait for v1.
- Record via `AVCaptureMovieFileOutput` (simplest) to the app container; expose start/stop; handle `AVCaptureSessionRuntimeError`, interruptions (`AVCaptureSessionWasInterrupted`/`InterruptionEnded` — calls, Control Center) and **finalize partial recordings safely (never lose footage).**
- Monitor `ProcessInfo.processInfo.thermalState`; if `.serious/.critical`, drop to 4K/30 or 1080p and show a toast. Pre-flight free-space check via `FileStore`; warn at low battery for long captures.
- Store true capture fps + dimensions in a metadata sidecar for the pipeline.

### 4.2 Motion sidecar (the #1 quality lever — do not skip)
- `CMMotionManager` at ~100Hz: capture `deviceMotion` (attitude quaternion, rotationRate, gravity, userAcceleration). Timestamp each sample against the recording clock (align `CMDeviceMotion.timestamp` / mach time to the movie start) and write a **`<video>.motion.json`** sidecar alongside the video. This enables Gyroflow-grade server stabilization later.
- Use `gravity` to drive the **level bubble** in the overlay; use `userAcceleration`/`rotationRate` magnitude for the **pace ring** (green = good, amber = slow down) with a subtle haptic tick as a metronome.

### 4.3 Guidance overlays (must feel 60fps)
Level bubble, pace ring + haptic metronome, light meter (sample average luminance from the preview / a low-rate video-data output; warn "too dark"), rule-of-thirds grid, and floating **room-tag buttons** that append `RoomTag(name, tMs)` at the current record time. Overlays are SwiftUI drawn over the camera preview layer; do all math off the main thread and publish smoothed values.

### 4.4 Import
- **Photos:** `PHPickerViewController` filtered to videos; get a **file URL** (request the asset's file representation; do NOT load into memory).
- **Files/drone:** `UIDocumentPickerViewController` for `public.movie`; security-scoped URL → copy into app container.
- Validate duration/res/fps/codec; expose an "This is a drone shot" toggle (skips stabilization server-side).

### 4.5 Large-file resumable upload (must handle multi-GB)
- **Never load the file into memory.** Stream from disk (`InputStream`/file handle) in chunks.
- **Background `URLSession`** (`URLSessionConfiguration.background(withIdentifier:)`) so uploads continue when backgrounded/killed; implement `urlSessionDidFinishEvents(forBackgroundURLSession:)` and the app-delegate `handleEventsForBackgroundURLSession` hook.
- Three modes behind `Config.uploadMode`:
  1. **`.direct`** — request presigned multipart/PUT URLs from the API (stubbed to return a dev endpoint or a local mock), upload parts, complete. This is the default that works with R2/S3-style signed URLs.
  2. **`.tus`** — TUSKit against a tus server (persist the upload URL in `UploadStore`; RN/tus caveat n/a here but still persist offset).
  3. **`.simulate`** — no network: chunk-read the file, report realistic progress, mark complete. **This makes the app fully runnable on-device with no backend.**
- **Persist upload state** (`UploadStore` on disk): file URL, upload id/URL, byte offset, part etags → resume across app launch, network loss, reboot.
- **Cellular guard:** detect connection type (`NWPathMonitor`); if cellular and file > threshold (e.g. 500 MB), prompt "Upload on Wi-Fi or continue on cellular?" (Wi-Fi-only default toggle in Settings).
- Persistent upload progress mini-bar across screens; pause/resume; auto-retry with backoff; checksum (SHA-256) for integrity.

### 4.6 Screens & navigation (Apple aesthetics)
- SwiftUI `NavigationStack`; large titles; `.ultraThinMaterial` bars; SF Symbols; system list styling; `.tint(Theme.accent)`; full **Dynamic Type + VoiceOver + dark mode**; haptics on key actions; skeleton loaders; offline banner.
- **Home/My Listings:** mock listings from `MockAPIClient` with status chips (Draft/Uploading/Processing/Ready/Expired); "＋ New Listing".
- **New Listing:** address (MapKit autocomplete optional; plain field OK for v1) + beds/baths/price; "Record now" or "Import".
- **Capture / Import → Room Tagging → Review & Submit:** Review shows a mock **duration-band price** (see master spec Part 20) + tier selector; "Submit" enqueues a mock render and navigates to **Render Status** (simulated progress) → **Flythrough Detail**.
- **Flythrough Detail:** `PlayerWebView` (WKWebView) loading the bundled/remote player; Share sheet (link/QR); mock analytics.
- **Settings:** brand accent, Wi-Fi-only uploads, upload mode, notifications (stub), **Delete account** (stub), legal links, "How to shoot" tip sheet.

### 4.7 Design system (Apple-native, premium)
- Palette: near-black background `#0B0D10`, ink `#F2F3F5`, dimmed ink, **accent gold `#D9A441`** (or make it configurable), glass cards via `.ultraThinMaterial`. Match the existing web player's aesthetic (it already uses `-apple-system`, gold accent) for brand continuity.
- Typography: SF Pro via system fonts + `.dynamicTypeSize`. Corner radius 16. Generous spacing. Motion: gentle springs, no gratuitous animation.
- Haptics: selection on room-tag, success on capture finish + upload complete, warning on quality issues.

---

## 5. STUBBED BACKEND / CONFIG (so it runs today)
- `Config.swift`: `apiBaseURL` (empty in dev), `uploadMode = .simulate` by default (switch to `.direct` when you have signed URLs), feature flags: `enableAuth=false`, `enableIAP=false`, `enablePush=false`.
- `APIClient` protocol with methods: `listings()`, `createListing()`, `requestUpload()`, `completeUpload()`, `createRender()`, `renderStatus()`. `MockAPIClient` returns believable data + simulated render progress. `LiveAPIClient` implements the same against `services/api` (leave endpoints per master spec Part 8.3; OK to stub bodies).
- `AuthStore` returns a fake signed-in user in dev (real Sign in with Apple is Phase 2).

---

## 6. RUN ON A PHYSICAL iPHONE (document in `apps/ios/README` too)
**Prereqs:** a Mac with Xcode 15+, an Apple ID. Free tier = 7-day on-device installs; a paid Apple Developer account ($99/yr) = TestFlight + longer provisioning.
1. `cd apps/ios && brew install xcodegen && xcodegen generate && open Rendprop.xcodeproj`
2. In Xcode → target **Rendprop → Signing & Capabilities** → check "Automatically manage signing" → select your **Team** (personal team is fine). Set a unique bundle id if `com.rendprop.app` is taken (e.g. `com.<you>.rendprop`).
3. Connect your iPhone via cable; select it as the run destination; **Product → Run (⌘R)**.
4. On the iPhone: **Settings → General → VPN & Device Management → Trust** your developer certificate the first time.
5. Grant camera/mic/photos/motion permissions when prompted. Record a walkthrough; import a drone clip; watch the resumable upload (Simulate mode) run and survive backgrounding.
6. For testers later: create an **App Store Connect** app record, archive, and distribute via **TestFlight**.

---

## 7. ACCEPTANCE CHECKLIST (this prompt is done when…)
- [ ] `xcodegen generate` produces a project that builds clean and runs on a physical iPhone.
- [ ] Camera records 4K (or best available) with `.cinematicExtended` stabilization; interruptions never lose footage; thermal fallback works.
- [ ] A `.motion.json` gyro sidecar is written and time-synced to each recording.
- [ ] Level bubble + pace ring + light warning update smoothly (no main-thread jank) during capture.
- [ ] PHPicker + Files import work on real large videos via file URLs (no memory spike).
- [ ] A multi-GB file uploads chunked in the background, survives app-kill + network drop + relaunch (resume from offset); cellular warning fires; Simulate mode works with no backend.
- [ ] Room tagging writes chapter timestamps; Review shows a duration-band mock price + tier selector.
- [ ] Flythrough preview renders the web player in a WKWebView.
- [ ] UI is Apple-native: SF Pro, SF Symbols, materials, haptics, Dynamic Type, VoiceOver labels, dark mode, safe areas.
- [ ] All Phase-2 items (Auth/IAP/Push/MLS) are cleanly stubbed behind flags with TODOs referencing the master spec — nothing blocks the build.

---

## 8. GUARDRAILS
- Keep it **buildable and runnable at every commit** — stub, don't block.
- No third-party UI frameworks; pure SwiftUI + Apple frameworks (only dependency allowed: TUSKit for the tus path, optional).
- Money as integer cents; never floats for currency.
- Do not put "buy cheaper on the web" language anywhere (App Store rule) — real purchases come later via StoreKit 2.
- Follow the master spec (`docs/MASTER-BUILD-PROMPT.md`) for anything unspecified here; this prompt is the Xcode bring-up of Parts 4 & 34.

**Rename note:** the repo/docs still say "ROAM" in places — the product is now **Rendprop**. Use "Rendprop" for the app display name, bundle id, and all new UI copy; a global find/replace of ROAM→Rendprop in docs/READMEs can follow.
