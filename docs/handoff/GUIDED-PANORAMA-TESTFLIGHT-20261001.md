# Guided room tour — TestFlight handoff, 2026-10-01

## Scope and release boundary

The owner explicitly requested a TestFlight build of guided stationary scan positions after reviewing the Matterport capture research. This is a **local photographic room-tour prototype**: it does not yet provide verified 3D geometry, a dollhouse, measurements, published links, or Studio synchronization. Do not describe it as a completed Matterport replacement. The original walking capture, product upload flow, and account features remain available.

Isolated branch: `feat/guided-panorama-testflight-20261001`, based on shipped build 32 (`aedf861a6e4a35d2b552390b7e9ffc029fc39454`). No shared branch force-push or edits to Claude's checkout. Proposed version **1.0.3 (33)**; only an authenticated Apple receipt confirms availability. The final release receipt is recorded separately after upload.

Explicit TestFlight overlay only: `apps/ios/project-spatial-testflight.yml`. `SPATIAL_CAPTURE_LAB` exposes **Home → Guided room tour** and **Settings → TestFlight lab → Guided room tour**. Normal App Store compilation does not expose these screens. No App Store review submission or commercial setting changes are authorized by this release.

## Owner's first phone test

1. Install the confirmed new build in TestFlight. Open **Home → Guided room tour → Start a room tour**.
2. Choose one well-lit room and a clear spot away from close furniture. Hold the camera level, let tracking settle, then tap **Scan this position**.
3. Keep the camera lens over the same spot while turning around it. Follow the target and pause until each photo saves. The sequence covers the middle, upper and lower rings, then ceiling and floor. It turns counterclockwise; do not walk around the room during one position.
4. Open **Preview this position**. Drag around, checking straight door frames, room corners, nearby furniture, ceiling, floor and the wraparound seam. Gray means a direction was not captured; there is no generated fill.
5. Move a few feet to another position with overlapping room details. Scan again, then **Finish and save**. Open the saved room tour and switch positions.
6. Close and reopen the app. Confirm both positions reopen. Use **Export scan files → Save to Files** to share the original archive for diagnosis.
7. Separately test stopping a position early and a phone call/background interruption. Previously saved photos should remain available as a partial tour. An interrupted tour is never resumed into a new coordinate system; start a new tour.

Please report iPhone model, iOS version, position/photo counts, whether targets were easy to follow, how often the pivot warning appeared, preview time, and screenshots of seams/gaps. The exported original photos/poses/depth are more useful than only a screen recording. Keep room media private.

## Capture and preview contracts

- 38 provisional directions per position: 12 at each of 0°, +50°, −50°, plus zenith and nadir. Maximum 8 positions, bounded archive storage, one admitted frame being written at a time.
- Target acceptance: within 5°, within 10 cm of the station pivot (warn at 5 cm), 0.35 s stable dwell, angular speed at most 3°/s, predicted rotational smear at most 2 px. These are test values, not a proven real-room quality threshold.
- Each saved JPEG, native intrinsics, pose, timestamp, raw feature points, exposure, and optional scene depth/confidence come from the same ARFrame. Original sensor raster orientation is preserved. Depth is explicit when unavailable; non-LiDAR phones are allowed.
- Storage format `rendprop-station-capture`, separate from the walking-capture archive. Files live in `Documents/StationCaptures/<UUID>`. No automatic upload or provider job occurs. Archives are excluded from device backup.
- Admission counts advance only after durable files and manifest commit. Partial files are preserved and invalid exports fail closed. Relocalization, timestamp rollback, interruption, backgrounding and closing end the capture epoch.
- After a force-quit, the inactive library can finalize an abandoned capture as interrupted only after validating the exact durable file set. Original bytes are untouched; orphan or corrupt files prevent automatic recovery and remain preserved for diagnosis.
- On-device CPU reprojection uses measured rotation/intrinsics, selecting the most central source for each ray. It produces a 4096×2048 equirectangular PNG with transparent missing coverage. It does not perform SfM, seam optimization, exposure blending, depth warping, inpainting or reconstruction.
- Preview caches live separately in `Library/Caches/GuidedPanoramaPreviews`. Source fingerprints and image hashes prevent stale/corrupt cache reuse. Canceling preview leaves original files intact.
- Station views preserve global heading when switching. Station buttons select saved photographs; they do not assert a collision-free route or verified geometry.

## Verification and limits

Software checks include the actual archive/policy/depth code, synthetic spherical projection with known colors, camera orientation/wrap/poles, invalid inputs, resource limits, cancellation, device compilation/signing, and navigation without using a camera. Reproducible commands:

```sh
bash tools/spatial-spike/capture-ios/verify-station.sh
bash tools/spatial-spike/capture-ios/verify-panorama.sh
bash apps/ios/tests/verify-guided-panorama-preview-store.sh
bash tools/spatial-spike/capture-ios/verify.sh
node --test tests/phase1/*.test.mjs
bash apps/ios/tests/run-production-writer.sh
```

Recorded local results: **178** station/storage/depth assertions, **45** panorama assertions, **24** cache assertions, and **3/3** navigation UI tests passed. The spherical color oracle RMSE was **0.737/255** (maximum channel error 5, including JPEG compression). A fresh-process synthetic stress run rendered 38 native-size photos to 4K in **1.707 seconds**, with **184 MiB peak RSS on this Mac**. These results are software evidence only. Legacy capture checks, 22 Phase 1 tests, and 11 production writer/recovery checks also passed.

Real-room optical quality, handheld pivot tolerance, phone memory/temperature, LiDAR alignment and physical interruptions require the owner's phone test. Synthetic coverage and Mac speed are not physical-device evidence. Hardware camera tests must not be claimed from a simulator.

No GPU experiment, production spatial runtime change, provider enablement, migration or paid generation is part of this work. The recorded spatial experiment total remains **$22.11834445 / $25**, with **$2.88165555 remaining** and zero active holds.

## Implementation map

- `tools/spatial-spike/capture-ios/Sources/StationCapture{Models,Policy,Recorder}.swift`: durable archive, admission, epoch and native depth.
- `tools/spatial-spike/capture-ios/Sources/Panorama{Projection,Renderer,PreviewViewController}.swift`: measured projection, PNG and look-around viewer.
- `apps/ios/Rendprop/Capture/GuidedPanorama{CaptureController,LabView,PreviewStore}.swift`: branded guided camera, local library and cache.
- Existing walking validator deliberately does not accept this new archive; do not add these files to walking uploads without an explicit backend contract.
- Older standalone iOS 15 capture diagnostic excludes new Station/Panorama sources. The integrated app test target is iOS 16+.

Read the original Matterport capture research and spatial reports before subsequent reconstruction changes. Preserve the controlled ablation evidence and spend ledger; this prototype does not retroactively make those Gaussian-splat outputs a quality pass.
