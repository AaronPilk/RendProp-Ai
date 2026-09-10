# Existing-app spatial TestFlight integration — verification record

Date: 2026-09-10. Worktree: `spatial-testflight-20260910`. Branch: `feat/spatial-testflight-integration-20260910`, based on spike `3643398`, preparation `e4d1bdc`, then merge `e0d2ef9` of upstream `feat/agent-reel` (`dbd501b`).

## Scope and limits

This integrates the **private Phase A capture experiment** into the existing Rendprop app, not a new application. It does not implement or claim complete spatial tours. The adopted brief requires one real iPhone room, GPU training from recorded ARKit poses, SOG conversion and real-phone viewer metrics before Phase B. Those physical/GPU results remain outstanding.

The owner authorized TestFlight upload and will perform the physical AR check on iPhone 15 Pro. No App Review submission/attachment, App Store metadata or pricing changes, provider activation, new paid provider, deletion, or external tester invitations are authorized or performed here.

## Implementation

- Explicit `apps/ios/project-spatial-testflight.yml` overlay generates `RendpropSpatialTestFlight.xcodeproj`. Bundle remains `com.rendprop.app`, marketing version 1.0, intended build 17, minimum iOS 16. The original app project, plist, entitlements and backend are unchanged.
- `SPATIAL_CAPTURE_LAB` exposes **Settings → Spatial capture (TestFlight)** only in the explicit experimental build. The normal app project neither defines that flag nor includes the shared capture implementation.
- Six individually listed shared Swift files are compiled; standalone `@main`, scripts, fixtures and documentation do not enter the app. No global ARKit/LiDAR installation restriction is added. Capture checks world-tracking support at runtime; LiDAR is not required.
- The wrapper owns a stable controller. Done/dismantle synchronously closes capture and rejects late callbacks. Idle-timer state is restored. AR preview is allocated only after support and camera authorization checks.
- JPEGs, pose/intrinsics sidecars and manifests stay local. Persistent `Captures/<UUID>` storage is marked excluded from backups and that attribute is read back before recording writes. Failure aborts the attempt.
- **Saved captures** supports reopening/relaunch recovery, paginated listing, honest unreadable/interrupted states and revalidation before every export. Export uses a user-selected Files destination; it is not an automatic upload. Choosing a cloud document provider remains an explicit user transfer.
- A completed manifest alone is not success: export validates the paired native JPEGs and sidecars. No imported/untrusted archive path is exposed. This local-generation boundary is not a general archive-unpacking security library.

## Verification performed

Artifacts are retained under `/tmp/rendprop-spatial-integration.sLQDuM/`; no diagnostic outputs were deleted. All simulator interaction targets only the owned synthetic simulator `D4BAC4B1-5F7D-4C4E-88A5-FC10746C152C` (iPhone 17 Pro, iOS 26.4.1). No physical AR execution is claimed.

### Portable and artifact gates

`bash tools/spatial-spike/capture-ios/verify.sh` returned **0**: **99 assertions passed**, including capture state, native geometry/JPEG pairing, backup exclusion, saved recovery, corruption and pagination. Its deliberate negative control returned **1**. The UI-summary self-test rejected ten invalid summaries.

`python3 tools/spatial-spike/verify_app_bundle.py /tmp/rendprop-spatial-integration.sLQDuM/DerivedData/Build/Products/Release-iphonesimulator/Rendprop.app --build 17 --lab` returned **0**: identity, version, build, minimum OS, capabilities, required resources, binary lab markers and prohibited-resource checks passed. A normal pre-integration app failed the lab expectation as intended. Both Python gates refuse optimized `python -O` execution.

### Optimized build and UI results

The app build and `build-for-testing` both returned **0**, using the explicit experimental project/scheme, `-configuration Release`, the simulator above and `-derivedDataPath /tmp/rendprop-spatial-integration.sLQDuM/DerivedData`. Existing AVFoundation Sendable, deprecated API and nil-coalescing warnings remain; a successful build is not a claim that these were fixed.

`ReviewerWalk.xcresult`: **1 passed, 0 failed, 0 skipped, 0 expected failures**. Independent evidence validation found all **10 required screenshots**. The previously missed sample-detail step now reached the populated bundled sample player; its actual screenshot was inspected. The deletion dialog was opened only against the owned synthetic mock app and canceled; no deletion was confirmed or requested from a backend.

`MainWalk.xcresult`: initial run **failed**, exit **65**, with `Required AI Photo Studio tile is missing from Home.` Release was held. The activity trace proved the test had opened a listing, failed to scroll past its embedded player, then searched for Home controls without returning home. The narrow test-only correction uses the actual Home feature routes and keeps the synthetic-project, two-photo, two-selected, and Voice Record assertions. No application navigation was changed to make it pass.

`MainWalk2.xcresult`: corrected run returned **0**, **1 passed, 0 failed/skipped/expected failures**. Independent evidence validation found all **9 required screenshots**. Actual Photo Studio, Reel Studio and Settings screenshots were inspected: two unmistakably synthetic photos loaded, both selected, and the real My voice → Record control visible. No microphone recording or generation was started.

`SpatialIntegration.xcresult`: initial **3 passed, 0 failed/skipped/expected failures**, including safe Done, simulator rejection and relaunch/Saved captures. Idle and empty-library screenshots rendered correctly. The unsupported-state screenshot was taken only 82 ms after activation and lacked the composited SwiftUI header, although Done was then found hittable and successfully used. It was **not** accepted as visually green. The test now asserts header/disclosure/Done after activation, waits one bounded second for compositing, and reasserts the exit. A second run must pass and its screenshots be inspected before archiving.

`SpatialIntegration2.xcresult`: **3 passed, 0 failed/skipped/expected failures**, exit **0** after rebuilding the final UI test. The settled unsupported screenshot visibly includes Done, title and disclosure; the previous header omission was a snapshot-timing artifact. The full `verify_ui_evidence.py ReviewerWalk.xcresult MainWalk2.xcresult SpatialIntegration2.xcresult` gate passed **all 5 exact tests and 22 required screenshots**. All three commands explicitly used Release; final app functionality is unchanged across the test-only navigation/screenshot corrections. A comment-only Settings edit was rebuilt before MainWalk2. The owned simulator was already shut down by the test runner at completion; no erase or uninstall occurred.

All UI commands use `xcodebuild test-without-building -quiet -project apps/ios/RendpropSpatialTestFlight.xcodeproj -scheme RendpropSpatialTestFlight -configuration Release -destination 'platform=iOS Simulator,id=D4BAC4B1-5F7D-4C4E-88A5-FC10746C152C' -derivedDataPath /tmp/rendprop-spatial-integration.sLQDuM/DerivedData -parallel-testing-enabled NO`, with a unique result bundle and explicit `-only-testing` selection. The evidence parser checks exact tests/counts/attachments; build configuration and source provenance come from the retained commands, not inferred screenshot names. Screenshots require visual inspection too.

## Distribution status

**Not yet archived or uploaded at this checkpoint.** Read-only App Store Connect preflight found latest build **16 VALID**, app-store version **1.0 WAITING_FOR_REVIEW**, still attached to build 16. Existing internal group **Rendprop team** has access to all builds and one installed tester. These must be checked again immediately before distribution.

`tools/asc/exportOptions-spatial-testflight.plist` requests upload with `testFlightInternalTestingOnly=true` and `manageAppVersionAndBuildNumber=false`. Installed Xcode help independently confirms internal-only builds cannot be distributed externally or submitted to the App Store. Upload is not permission to change the pending submission.

## Other work and manual gates

- The external skill was assessed, not installed or executed. See `RE-WALKTHROUGH-PRO-ASSESSMENT.md`; recommendation is **do not install**. It is a Claude/Higgsfield/Apify/ffmpeg workflow, not an iOS/AR reconstruction component.
- See `IPHONE-TESTFLIGHT-CHECKLIST.md` for the owner's capture, recovery and export checks after delivery is confirmed.
- Earlier broader backend/Worker/Python checks are in `BACKEND-RECHECK.md` and the explicitly historical `TESTFLIGHT-PREFLIGHT.md`. They are not a new production end-to-end audit. The backend remains unchanged from that checkpoint.
- No real room, CUDA GPU training, SOG reconstruction quality, actual backup-service behavior, document-provider export, thermal/storage behavior or older-phone performance was exercised here. No complete release-readiness GO is asserted for the entire app.
