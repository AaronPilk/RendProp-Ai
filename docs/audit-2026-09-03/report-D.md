# Report — W1-D (Settings · Capture · Import · Render · Player · plists)

Files touched (all inside my ownership): `Screens/SettingsView.swift`, `Screens/PlayerWebView.swift`,
`Resources/player/index.html`, `Capture/CameraManager.swift`, `Capture/CaptureView.swift`,
`Capture/MotionRecorder.swift`, `Capture/GuidanceOverlays.swift`, `Capture/RoomTagBar.swift`,
`Import/MediaImporter.swift`, `Render/RenderEngine.swift`, `Info.plist`, `PrivacyInfo.xcprivacy`,
`apps/ios/project.yml`. No new .swift files. Cannot compile here — every file was re-read end to end and
bracket/string-balance checked with a Swift-aware scanner; the player JS was syntax-checked with node.

## 1. SettingsView.swift (rewritten)
- **`LeadsView(listing: Listing? = nil)`** (new, in this file per B3): sign-in gate (presents the existing
  `SignInView`), `api.leads(listingServerID: listing?.serverID)`, grouped by day (Today / Yesterday / date),
  newest first, `LeadRow` with `tel:` (digits-only href) / `mailto:` links, message, `extra` fields
  ("party_size" → "Party size"), source. States: sample listing ("don't collect leads"), unpublished listing
  ("Publish this X to start collecting leads"), error (server message via `UserFacingError`, "Try again"),
  loading, empty ("Leads from your tours appear here — email alerts are coming."), `.refreshable`, reload on
  sign-in change. Already used by W1-B (`RendpropApp.swift:1600` `LeadsView()`) and W1-A
  (`FlythroughDetailView.swift:594` `LeadsView(listing:)`) — signatures match.
- **`UserFacingError`** (new enum): `message(_:fallback:)` → server message for `APIError.server`, 401 →
  "Please sign in again…", 429 → "try again in a few minutes", URLError offline copy; `isQuota` / `isUnauthorized`
  helpers; `pricingURL` (https://rendprop.com/pricing). AI Photo Studio shows an "Upgrade plan" link on 402 (no
  prices in-app) and re-prompts sign-in on 401; it also gates "Enhance photo" on sign-in up front.
- **Account section**: "Sign in with Apple" (sheet → `SignInView`) when signed out; "Sign out" (confirmation
  dialog → `auth.signOut()`, clears usage) when signed in; label from `auth.displayName`; "Watch the intro again"
  confirms when an upload is running. Honest footers per state / offline build.
- **Deletion**: signed-out user on the live backend → alert "Sign in to delete your account" with **Sign in** /
  **Clear this phone only** / Cancel — never claims the account was removed. Separate destructive row
  **"Clear data on this phone"** (honest copy: account + published tours untouched). Signed-in path unchanged
  (server DELETE /me first, then local wipe). Offline (mock) build: Delete account = local wipe with copy saying so.
- **Plan & usage**: gated on sign-in; rows from `UsageSummary.entitlements` — Plan, Trial ends, "Tour renders
  2 of 10", "Photo edits 7 of 150", Reel clips, Aerial intros, Drone-glide upscales ("Not included" when cap 0),
  Leads this month. No "AI spend"/cost row, no prices. Falls back to `renderCount/leadCount/planName` on older
  servers. `.refreshable` on the Form; errors via `UserFacingError` + "Try again". A **Leads** section (count
  when known) links to `LeadsView()`.
- **Uploads**: toggle renamed "Ask before uploading on cellular" (same key `wifiOnlyUploads`; W1-B/W1-C already
  `register(defaults:)`), footer "Videos over 500 MB always ask…", "Start on cellular now" button when the upload
  is `.queued` awaiting `pendingCellularConfirmation`, status label "Waiting for Wi-Fi".
- **Business type** row → real `NavigationLink { BusinessTypeView() }` (BusinessTypeView title now "Business
  type", inline). "Accent · Rendprop Gold" row removed.
- **Brand kit**: `AgentCard.key(_:for:)`, `card(for:)`, `headshotURL(for:)`, `brandFields`, `primaryBrandType`
  (UserDefaults `brand.primaryType`), `lastPushedKey`. **`AgentCard.syncToBrandKit(for:api:force:)`** pushes ONLY
  when the card `isSet` and ONLY for the org's primary type (= `SpaceType.current` when the first card was
  pushed; adopts it then), skipping identical payloads. Editor `onDisappear` and `ProfileView.onAppear` both go
  through it — an empty editor can never erase the hosted card again. Editor shows "Use this card on hosted
  tours" when editing a non-primary type; Settings/editor footers explain "one hosted card per account".
- **Headshot copy**: photo section footer "Shows in the app and in your in-app previews. Hosted tour pages show
  your initials for now — photo upload is coming."; preview header "Preview (in-app)".
- **Social normalization**: `instagram.com/me`, `www.x.com/…`, anything with a `/` or a known TLD → `https://`
  + input; `@handle` / dotted handles stay handles; website accepts bare domains.
- **Portfolio**: `PortfolioExporter.eligible(_:)` is the single filter used by the button count and the export;
  0 eligible but real listings exist → "Publish a tour to share your portfolio — only published, active Xs are
  included."; export built off-main (`Task.detached`), photos downscaled to 800 px / q0.72 before base64;
  copy says it's a file. "Your leads" button on the Profile tab.
- **`wipeLocalData`**: cancels coordinator jobs, clears listings/assets/tours/renders/`pendingPublish`/
  `uploadedRenderAssets`, wipes **Documents wholesale** (hidden files included) then recreates Recordings/Imports,
  removes `Caches/player-demo` and tmp contents, `WKWebsiteDataStore` all types since `.distantPast`, every
  per-type card key + `brand.primaryType`/`brand.lastPushed`/auth names, then reseeds samples.
- Copy: shoot tips keep "normal pace" (capture coaching is the source of truth); Advanced footer no longer claims
  60 fps "smoothing"; "up to 10 minutes" per take.

## 2. Capture
- **CameraManager**: microphone input removed (video-only; class comment explains). States gain `.finalizing`
  (renamed from `finishing`) and `.restricted`. Format ladder now prefers, among same-size/fps formats, one
  supporting `.cinematicExtended` (then `.cinematic`). **Stabilization ladder** `cinematicExtended → cinematic →
  standard → auto` per `activeFormat.isVideoStabilizationModeSupported`, re-applied after thermal reselects;
  `@Published stabilizationLabel` ("Stabilization: Enhanced/Cinematic/Standard/Auto/Off") corrected from
  `activeVideoStabilizationMode` once running. `maxRecordedDuration = 600 s`. Luma sampler asks the data output
  for 8-bit 420v and bails on any non-8-bit buffer. `onRecordingStarted` (from `didStartRecordingTo`) starts the
  motion sidecar clock. `currentRecordedSeconds` reads `movieOutput.recordedDuration`. Storage pre-flight uses
  `estimatedBytesPerMinute` from the active format (Apple's HEVC rates) and shows a banner with real numbers
  (`storageMessage`) instead of a dead-end `.failed`. Interruption copy per `InterruptionReason` (+ "the take so
  far is being saved" while recording); thermal copy tells the truth (mid-take: "wrap up soon"; 4K·60 users:
  "capturing at 4K · 30 until it cools"; others: "let it cool"), and goes back up when cooled. No haptic in the
  delegate any more (CaptureView fires the single success haptic). Recordings dir marked `isExcludedFromBackup`.
  `IdleTimer` (ref-counted `isIdleTimerDisabled`) lives here.
- **CaptureView**: idle timer hold on appear / release on disappear; `camera.onFinish = nil` +
  `onRecordingStarted = nil` on disappear (retain cycle); X while recording = confirmation dialog "Stop and
  discard this take?" → stop + delete file & sidecar; **"Use this take / Retake"** review overlay with a muted
  looping `VideoPlayer`, duration/tag count/format; Use → `MediaImporter.makeAsset(…, deleteOnFailure: false)`
  validation then `onComplete`; Retake deletes file + sidecar and resets tags; "Saving take…" capsule while
  `.finalizing`; no metronome, no duplicate haptics (lens toggle haptic only inside `toggleLens`); "Hold your
  phone upright" banner when |roll| > 60°; `.restricted` screen without a useless "Open Settings"; stabilization
  label under the format label; "takes stop on their own at 10:00" caption.
- **RoomTagBar(isRecording:tags:currentTime:)**: time from the movie clock at tap; same tag within 2 s ignored,
  different tag within 2 s replaces the last; "Undo <tag>" chip.
- **MotionRecorder**: lock covers `isLogging`/`startUptime`/`samples`; `beginLogging()` at first frame;
  `cancelLogging()`; `sidecarURL(for:)`; pace low-pass ~0.4 s with rotation weighted up (less flicker).
- **GuidanceOverlays**: level bubble x negated — both axes now "bubble floats to the high side" (F-D-15), comment
  documents the sign derivation.

## 3. MediaImporter — API for callers (W1-B already uses it)
```swift
enum MediaImporter {
    static let maxDurationSeconds = 600.0, minDurationSeconds = 0.2
    struct ProbeResult { duration, fps, width, height (ORIENTED), hasVideoTrack, isPlayable, looksLikeDrone }
    enum ImportError: LocalizedError { unreadable, noVideoTrack, tooShort(Double), tooLong(Double),
                                       badDimensions, notPlayable, copyFailed }   // errorDescription = user copy
    static func probe(url:) async -> ProbeResult
    static func looksLikeDrone(_ asset: AVAsset) async -> Bool      // DJI/Autel/Skydio/Parrot… in make/model/software
    static func makeAsset(from url: URL, isDrone: Bool?, deleteOnFailure: Bool = true) async throws -> CaptureAsset
        // isDrone nil → heuristic decides; throws ImportError; deletes the (our-copy) file on failure by default
    static func excludeFromBackup(_ dir: URL)
    static func uniqueImportURL(originalName:) -> URL               // Imports/import-<uuid8>-<name>
}
struct PhotoVideoPicker { onPicked, onProgress, onFailed: (() -> Void)?, onFailedWithMessage: ((String?) -> Void)? }
    // preferredAssetRepresentationMode = .current
struct FilesVideoPicker { onPicked, onFailed: ((String) -> Void)? }  // unique names; never overwrites; copy fallback
```
`NewListingView.importFile` (`try await MediaImporter.makeAsset(from: url, isDrone: false)`) compiles against this.

## 4. RenderEngine
- **VISION-SIGN applied**: `pos = (pos.x - t.tx, pos.y + t.ty)`; correction stays `(smoothed − raw) × 0.9`;
  `stabilizeTransform` translates by `correction / zoom` (translate before the zoom-about-center).
- Output written to a unique `.tour-<id8>-<uuid8>.part.mp4` in Recordings, moved into place with
  `replaceItemAt` / `moveItem` only after `.completed`; the live tour is never deleted first; stale `.part`
  files > 1 h are swept.
- Pass-1: any error other than `RenderError.cancelled` / `CancellationError` → unstabilized fallback;
  implausible registration shifts (> 8 % of the frame) count as failures.
- 709 primaries/transfer/matrix set on BOTH compositions (`tag709`); `naturalSize > 0` (+ finite, render size ≥ 2)
  guard → `badDimensions`; `AVVideoExpectedSourceFrameRateKey: 60`; progress throttled (~10 Hz / ≥2 % steps)
  via `ProgressThrottle`; `maxSourceSeconds = MediaImporter.maxDurationSeconds` (600) → `tooLong(seconds)`
  with a clear message; `tooShort`; all-intra settings unchanged. Signature `render(asset:progress:)` unchanged.
- Deliberately NOT holding the idle timer inside the engine: W1-B's `RenderCoordinator` already keeps
  `isIdleTimerDisabled` for the whole render+publish job (two authorities would fight).

## 5. PlayerWebView + index.html
- One template pass (`renderTemplate`) for demo AND local preview. `demo.mp4` missing → still type-adapted, `src`
  removed, `VIDEO_MISSING = true` → loader shows "Sample video unavailable" (never the raw house template, never a
  black stage). A local file that fails to load → "Video unavailable" state via the `error` event; 12 s last
  resort now shows the message unless something actually buffered. `PREVIEW = true` on every in-app page:
  inputs + submit disabled, visible "Preview — the form is disabled here…" note, no fake "Request sent", no
  beacon. `VIRTUALLY_STAGED` injected from `PlayerWebView.virtuallyStaged` (default false; decision A5).
- End card: brokerage and contact split; phone → `tel:`, email → `mailto:` (`.contact` row; hidden when empty);
  sample non-RE identity uses the sample's `details.phone`. Non-RE listing with an `actionURL` → deep-link CTA
  block replaces the form (mirrors hosted). Real non-RE listing with empty tagline no longer inherits the sample
  tagline (`identityIsSample`). Demo page file is per type AND per real-listing id.
- Read grant: pages beside videos in Recordings/Imports (folder grant). Root-Documents videos
  (`enhanced-<id>.mp4`) are hard-linked into `Documents/Previews/` and that folder is granted; stale links whose
  original is gone are swept; falls back to the wide grant only if linking fails.
- iOS engine already had the decaying jank watchdog, `Math.max(1,total)` and `readyState > 0`; kept, plus
  `meter()` in the fallback loop and a clamped rail jump. `PlayerWebView(remoteURL:)`, `PlayerWebView(listing:)`,
  `PlayerWebView(localVideoURL:roomTags:listing:)` call sites unchanged.

## 6. Info.plist / PrivacyInfo / project.yml
- `NSPrivacyCollectedDataTypeUserID` added (linked, not tracking, app functionality).
- `NSMicrophoneUsageDescription` KEPT (decision A10 says keep) but reworded honestly ("Flythroughs are silent…
  would only be requested if you add a voice-over in a future update"). No code references audio any more —
  parent may delete the key outright if preferred.
- project.yml: comment only (player folder reference already bundles `demo.mp4` if present; runtime folders
  need nothing). Deployment target stays 16.0; no iOS-17-only API used (`.onChange(of:) { _ in }`,
  `.statusBarHidden()`, `VideoPlayer`, `.refreshable`, `LabeledContent`, `confirmationDialog` are all ≤ 16).

## PARENT MUST APPLY (other owners' files)
1. **W1-B `NewListingView` / `AddVideoFlowView`** (optional but recommended): pass `isDrone: nil` to
   `MediaImporter.makeAsset` (or read `probe.looksLikeDrone`) to prefill the Review "Handheld / Drone" control
   per decision A8; wire `FilesVideoPicker(onPicked:onFailed:)`'s new `onFailed: (String) -> Void` and
   `PhotoVideoPicker.onFailedWithMessage` into the existing import alert (currently only the throw path is
   surfaced, which is fine).
2. **W1-B `FileStore.removeVideoAndPreview` / `AppModel.remove`**: also delete `Documents/Previews/<name>` and
   `Documents/Previews/preview-<base>.html` for root-Documents videos (hard links keep bytes alive until the
   next preview render sweeps them). Better: write `enhanced-<id>.mp4` into `Recordings/` so the link path is
   never used. `FileStore.subdir` should set `isExcludedFromBackup` (I set it on Recordings at record start and
   on Imports at import; Aerials is W1-B's).
3. **W1-B `RenderCoordinator.refreshIdleTimer`/`reportProgress`** write `isIdleTimerDisabled` directly; the
   capture screen uses the ref-counted `IdleTimer.hold()/release()` (CameraManager.swift). A job finishing while
   the camera is open would drop the capture hold — route the coordinator through `IdleTimer` (one hold per run)
   to be exact.
4. **W1-B Home copy** (`RendpropApp.swift`, "Walk the home slowly on the 0.5× wide lens"): align with capture
   coaching + Settings ("Walk at your normal pace — steady beats slow").
5. **W1-F tour-host `normalizeSocial`**: mirror the bare-domain rule (`instagram.com/me` → `https://…`, never
   `https://instagram.com/instagram.com/me`).
6. Nothing needed from W1-C — `Lead`, `Entitlements`, `UsageSummary.entitlements`, `api.leads`, `APIError.server`
   + helpers, `AuthStore.displayName/signOut` all landed and match.

## Deliberately not done
- Per-industry extra lead fields in the in-app preview (hosted `lead_fields`) — the in-app form is inert anyway.
- Bitrate/GOP change (F-D-14 product decision): all-intra 14 Mb/s kept.
- Gyro sidecar fusion (F-D-10): still written (first-frame synced) for the server path; engine doesn't read it.

## Self-review checklist
- Force unwraps: none added (`URL(string: "https://rendprop.com/terms")!` legal links pre-existing, literal).
- `@MainActor`: `loadUsage`, `deleteAccount`, `clearLocalDataTapped`, `wipeLocalData`, `LeadsView.load`,
  `AgentCard.syncToBrandKit`, `IdleTimer`; UI state only mutated on main (`MainActor.run` in Tasks).
- Optional persisted fields: none added to models (UserDefaults keys only).
- Hard rules: no prices/purchase copy in-app ("Upgrade plan" is a link to the website); destination-based
  NavigationLinks only; contact email untouched; no new .swift files; entitlements unchanged.
