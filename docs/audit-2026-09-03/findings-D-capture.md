# Findings — D · Capture / Import / Render engine

## Summary
Capture → import → on-device render chain is structurally sound (session config, two-pass reader/writer, cancellation bridging, retime composition, transform composition and crop-margin math check out), but the screen lifecycle fights it: `RenderStatusView.onAppear` unconditionally re-runs the whole render (and re-publishes, and deletes the live tour file first) every time the user comes back to the screen, and `onDisappear` cancels it — a failed/cancelled render leaves the listing stuck at "Working on it" with no retry. The Vision correction sign is very likely inverted on at least one axis; hardware stabilization silently ends up OFF whenever the chosen format doesn't support `.cinematicExtended`. Capture has no idle-timer protection, records an audio track nobody uses, and the 100 Hz gyro sidecar is never read. Import infers "drone" from which picker was used (backwards for DJI Fly), can delete another listing's raw video on a filename collision, and lets undecodable files reach the render dead-end.

## Findings (most severe first)

### F-D-01 · P0 · RenderStatusView re-renders + re-publishes on every re-appearance and deletes the live tour file first
- Where: `RenderStatusView.swift:190` (`.onAppear { start() }`), `:199-205` (no guard), `:207-237`, `:191` (`.onDisappear { pollTask?.cancel() }`); `RenderEngine.swift:133-135` (deterministic `tour-<assetID8>.mp4` + `removeItem` before encoding), `:144-149` (deletes `outURL` on failure/cancel).
- Fix: (1) `start()`: guard on `pollTask == nil && !isReady`; if `model.tours[listing.id] != nil` and no publish pending → `markReady()` and return. (2) Move pipeline into a `RenderCoordinator` (ObservableObject owned by AppModel, in RendpropApp.swift) that survives navigation; cancellation = explicit user action. (3) RenderEngine: encode to a temp URL and move into place atomically only after `.completed`; never `removeItem` the existing tour up front. (4) Publish idempotent per listing.

### F-D-02 · P1 · A failed or cancelled render leaves the listing stuck at "Working on it" with no retry / re-render path
- Where: `ReviewSubmitView.swift:347` (`.processing` set before render), `RenderStatusView.swift:230-235`; no "Render tour" tool in detail.
- Fix: on failure set `.draft`, "Try again" button; "Render tour" card in FlythroughDetailView when `assets[id] != nil && tours[id] == nil`; on launch flip `.processing` without tour back to `.draft`.

### F-D-03 · P1 · Stabilization correction sign very likely inverted (at least on X)
- Where: `RenderEngine.swift:238-247` (`pos += alignmentTransform.tx/ty`), `:264-268` (`correction = (smoothed − raw) × 0.9`), `:411-418`.
- What's wrong: Vision returns the transform aligning the current (floating) frame onto the previous (reference); Σt is the camera path (−content). Smoothing camera path gives s; the content must move by (p − s); code translates by (s − p)·0.9 — opposite direction → ~1.9× jitter on that axis. Vision also uses lower-left origin so `ty` is likely flipped relative to `tx`.
- Fix: determine sign empirically once (synthetic two-frame test) and correct `pos` accumulation (`pos.x - t.tx`, and y per the test). Divide correction by `cropZoom` (F-D-30).

### F-D-04 · P1 · Hardware stabilization silently OFF when format doesn't support `.cinematicExtended` (incl. 4K·60)
- Where: `CameraManager.swift:113-116`, `:136-182`, `:290-297`.
- Fix: prefer formats where `format.isVideoStabilizationModeSupported(.cinematicExtended)`; after commit pick a ladder `.cinematicExtended → .cinematic → .standard → .auto` by testing `activeFormat.isVideoStabilizationModeSupported`; re-run after thermal re-select; show "Stabilization: Enhanced/Standard/Off".

### F-D-05 · P1 · No idle-timer protection; backgrounding unhandled
- Fix: `UIApplication.shared.isIdleTimerDisabled = true` in `CaptureView.onAppear`/false in onDisappear, same around render; `beginBackgroundTask` around render; on `AVError.operationInterrupted` show paused + Retry.

### F-D-06 · P1 · Audio recorded but never used — mic prompt, pauses music, phone calls end the take
- Where: `CameraManager.swift:95-99`; `RenderEngine.swift:177-188` (video-only composition); player muted.
- Fix: remove the audio input (keep plist string); or at least `automaticallyConfiguresApplicationAudioSession = false` + `.mixWithOthers`.

### F-D-07 · P1 · "Drone" inferred from which picker was used — backwards for DJI Fly (saves to Photos)
- Where: `NewListingView.swift:183-193`, `:198,215`; `ReviewSubmitView.swift:88-90` (static label).
- Fix: explicit segmented control on Review & Submit "Handheld walkthrough / Drone footage" pre-filled by metadata heuristic (`make`/`model` containing DJI/Autel/Skydio); write `asset.isDrone` before `start()`; rename picker buttons to "Photos" / "Files".

### F-D-08 · P1 · Files import overwrites any earlier import with the same filename
- Where: `MediaImporter.swift:157-158`. Fix: `import-<UUID8>-<name>` like the Photos path; drop `removeItem`.

### F-D-09 · P1 · Undecodable imports flow into Review with "0:00 · 0p · 0 fps" and dead-end/crash at render
- Where: `MediaImporter.swift:17-33`, `:36-46`; `ReviewSubmitView.swift:79,36`; `RenderEngine.swift:92-98, :107,162-173, :329-332`.
- Fix: validate in `makeAsset` (duration > 0.2, width/height > 0, `isPlayable`); delete copy and alert "This video format isn't supported"; guard `naturalSize > 0` in `renderBody`.

### F-D-10 · P2 · 100 Hz motion sidecar is dead data; not synced to first frame; unlocked cross-thread reads
- Where: `MotionRecorder.swift`; `CaptureView.swift:156`.
- Fix (decision): fuse into stabilization (roll correction) with first-frame sync from `didStartRecordingTo`, or stop writing the sidecar and drop the badge; keep model field Optional.

### F-D-11 · P2 · HDR → SDR only tagged on the writer, not tone-mapped in the composition
- Where: `RenderEngine.swift:203-211`, `:290-316`, `:333-337`.
- Fix: set `vc.colorPrimaries/colorTransferFunction/colorYCbCrMatrix` to 709 on both compositions (compositor tone-maps).

### F-D-12 · P2 · Pass-1 analysis error fails the whole render instead of falling back
- Where: `RenderEngine.swift:117-121`. Fix: only `.cancelled` rethrows; other errors → `result = nil`, `stabilized: false`.

### F-D-13 · P2 · No way to cancel a render; back/swipe disabled for the whole wait
- Where: `RenderStatusView.swift:189`. Fix: Cancel button → cancel task, reset `.draft`, pop.

### F-D-14 · P2 · No duration cap; 60 fps all-intra at 14 Mb/s (~105 MB/min) — big files, low per-frame bit budget
- Where: `RenderEngine.swift:63-64,343-346`; `CameraManager.swift:212-230`.
- Fix (decision): cap at 10 min raw; raise bitrate (24–30 Mb/s) or short GOP; set `AVVideoExpectedSourceFrameRateKey: 60`.

### F-D-15 · P2 · Level indicator: roll and pitch use opposite sign conventions
- Where: `GuidanceOverlays.swift:46-47`, `MotionRecorder.swift:57-58`. Fix: negate x for a bubble metaphor; comment it.

### F-D-16 · P2 · Capture has no discard/retake; X while recording goes to Review; draft listing lingers
- Where: `CaptureView.swift:69-78`, `:240-264`; `NewListingView.swift:84-96`.
- Fix: "Use this take / Retake" interstitial; X during recording = stop and discard (confirm); create listing lazily.

### F-D-17 · P2 · Retain cycle: `CameraManager.onFinish = handleFinished` keeps session alive
- Where: `CaptureView.swift:46`. Fix: `camera.onFinish = nil` in `onDisappear`.

### F-D-18 · P2 · Landscape neither supported nor detected — rotated phone records sideways
- Where: Info.plist portrait; `CameraManager.swift:117-119`. Fix: "Hold your phone upright" banner driven by gravity when `abs(roll) > 60°`, or set orientation from gravity at start.

### F-D-19 · P2 · Raw captures/imports/renders in Documents without backup exclusion
- Where: `FileStore.swift:5-22`. Fix: `isExcludedFromBackup = true` on Recordings/Imports dirs.

### F-D-20 · P2 · Interruption / thermal banners say things that aren't happening
- Where: `CameraManager.swift:252-258`, `:283-298`. Fix: accurate copy per state.

### F-D-21 · P2 · Second recording can start while the previous is still finalizing
- Where: `CaptureView.swift:240-264`, `:172`. Fix: `.finalizing` UI state disabling the button.

### F-D-22 · P3 · `.restricted` camera status shows "Open Settings" copy that cannot help
### F-D-23 · P3 · Luma sampler assumes 8-bit Y plane — set `videoSettings` to 420v 8-bit or bail
### F-D-24 · P3 · Pace ring flickers on footfalls — weight rotation, 0.5 s low-pass, hysteresis
### F-D-25 · P3 · Haptic tick every second while recording; duplicates on lens toggle/finish — remove
### F-D-26 · P3 · Room-tag timestamp from 250 ms polled timer — read `movieOutput.recordedDuration` at tap; add Undo; collapse repeated tap within 2 s
### F-D-27 · P3 · Free-space pre-flight 4× too conservative (400 MB/min vs ~100) and message has no number
### F-D-28 · P3 · Preview `.resizeAspectFill` so grid doesn't match recorded frame
### F-D-29 · P3 · Photos import `.automatic` may transcode — use `.current`; surface provider error text
### F-D-30 · P3 · Correction applied before zoom → effective shift `zoom × correction` — translate by `correction / zoom`
### F-D-31 · P3 · One composition instruction per output frame; one Task per progress callback at 60 Hz — throttle progress to 10 Hz
### F-D-32 · P3 · Vision failure only counts exceptions — treat |t| > 8% frame as failure
### F-D-33 · P3 · `RoomTaggerView` allocates an `AVPlayer` in `init` on every parent re-render; probe width/height un-oriented

## Verified OK
Permission flow (authorized/notDetermined/denied) with Simulator degrade (no back camera → `.failed`, no crash); serial session queue; format ladder; dual-wide zoom mapping; recording state machine; fragment interval; luma sampling; file naming; room tag timebase consistency (raw asset URL for both tagger entry points; playback and publish divide by `speedFactor`); Photos import (PHPicker, temp copy, iCloud progress); RenderEngine geometry / zoom-about-center / clamp margins / instruction ranges / Gaussian; retime; writer all-intra (`MaxKeyFrameInterval: 1`, no reordering, High, 709 tags); cancellation; adaptive speed.

## Open questions
1. Audio: voice-over ever planned? 2. Gyro fuse or delete? 3. Portrait-only vs landscape. 4. Length cap + bitrate/GOP. 5. Drone UX: toggle vs heuristic. 6. `demo.mp4` absent from repo. 7. Is `/renders/publish-app` idempotent per listing?
