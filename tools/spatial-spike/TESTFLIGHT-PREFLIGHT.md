# Historical TestFlight preflight — superseded by build 17 delivery

> Historical preflight snapshot. The owner subsequently confirmed integration
> into Rendprop's existing TestFlight app. Work continues on
> `feat/spatial-testflight-integration-20260910`; the separate capture-app
> distribution choice below is no longer a blocker. This document's results
> predate the integrated build and must not be presented as its release proof.

2026-09-10. Worktree: `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`.
Branch: `testflight/spatial-validation-20260910`, based on `3643398`.

The owner requested full testing and TestFlight, and will perform the physical
capture on an iPhone 15 Pro **after installing through TestFlight**. Real AR
capture is not a pre-upload gate: the simulator cannot provide it. TestFlight
upload is authorized; no App Review
submission, production data deletion, AI-route enablement, or GPU rental was
performed or inferred. The capture toolkit remains separate from Rendprop.

## Executed results

- `deno test --allow-net --allow-read --no-check ai-copy/`: exit 0,
  **111 passed, 0 failed**. `/tmp/rendprop-testflight-deno-20260910.log`.
- `deno test --allow-read --allow-env --deny-net --node-modules-dir=auto .`:
  exit 0, **526 passed, 0 failed**, with typechecking and runtime network denied.
  `/tmp/rendprop-testflight-all-deno-20260910.log`. No production mutation.
- Latest `bash tools/spatial-spike/capture-ios/verify.sh --build`: **50 Swift
  assertions passed**, known-failure control rejected, unsigned Release generic
  iPhone build and bundle checks passed, exit 0. Artifact:
  `/tmp/spatial-capture-verify.hwkAAP/DerivedData/Build/Products/Release-iphoneos/SpatialSpikeCapture.app`.
  UI-summary checker also rejected ten invalid summaries and accepted its exact
  positive control. This supersedes the earlier 36-assertion capture run.
- Standalone capture Release simulator UI tests: exact result **3 passed,
  0 failures, 0 skipped, 0 expected failures**, total 3 and overall `Passed`;
  shell exit 0. Final rerun: `/tmp/spatial-capture-ui.b6DtMg/results.xcresult`.
  These assert idle controls, unsupported-device behavior and relaunch without
  inventing saved captures. They do not test AR. After adding foreground
  assurance to screenshot collection, the same three tests passed again.
  Individual image inspection resolved an apparent missing-text presentation
  artifact; the final screenshot shows the status and button labels correctly:
  `/tmp/spatial-capture-ui-final.q4HiMG/241CCFAB-2F82-4D4B-90D5-CA2576C8925E.png`.
  The root agent independently inspected this image and the exact result summary.
- Training helper re-ran 24 offline Python tests (zero skipped) and the actual
  pinned upstream reader/CLI compatibility check; both exited 0. Hardware is
  Apple M4 Pro / Darwin ARM64; no NVIDIA CUDA training route on this host.
- `xcodegen generate` and `xcodebuild build-for-testing -project Rendprop.xcodeproj
  -scheme Rendprop -destination 'platform=iOS Simulator,id=D4BAC4B1-5F7D-4C4E-88A5-FC10746C152C'
  -derivedDataPath /tmp/rendprop-testflight-gates.yMUxlC/DerivedData`:
  `TEST BUILD SUCCEEDED`. Log: `/tmp/rendprop-testflight-gates.yMUxlC/build-for-testing.log`.
  Both UI walks subsequently executed; their coverage failures are below.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/asc -v`:
  exit 0, **208 tests passed**. `/tmp/rendprop-testflight-asc-tests-20260910.log`.
- Supabase: all **21** function entry points passed `deno check`; Python worker:
  **22 distinct functions, 140 assertions passed**. HDR suite did not execute its
  assertions because installed ffmpeg lacks `zscale`; a separate skip-rejection
  gate exited 1. See `BACKEND-RECHECK.md` for commands and evidence.
- Tour Worker: clean `npm ci --ignore-scripts --no-audit --no-fund`, typecheck,
  tests and asset checks all exited 0. **557 unbranded assertions + 361 route
  assertions**, plus **12 gate self-tests**, passed. Both demo MP4s are tracked,
  real ISO media files. `npm audit --omit=dev --audit-level=high --json` reported
  zero advisories. Logs: `/tmp/rendprop-testflight-worker-{install,typecheck,tests,assets}-20260910.log`
  and `/tmp/rendprop-testflight-worker-audit-20260910.json`.
- Wrangler 4.129.0, credentials unset and metrics disabled:
  `wrangler deploy --dry-run --outdir <unique temporary directory> --metafile`
  exited 0: `Total Upload: 181.00 KiB / gzip: 56.13 KiB`; `--dry-run: exiting now.`
  No deployment happened. `/tmp/rendprop-testflight-worker-bundle.pZloC2/bundle-meta.json`
  lists only six application TypeScript inputs, no Miniflare, sharp or ws.
- `node --test tools/spatial-spike/viewer/benchmark.test.mjs`: **7 passed**,
  zero failures/skips, exit 0. `/tmp/rendprop-testflight-viewer-unit-20260910.log`.
- `bash tools/spatial-spike/verification/verify.sh /tmp/spatial-training-verify.rUYL0A/venv/bin/python`:
  exit 0; real Swift raster/model writer produced synthetic JPEG/JSON accepted
  by the Python adapter, and the deliberately transposed pose was rejected.
  `/tmp/rendprop-testflight-interop-20260910.log`. This is interoperability proof,
  not physical capture or reconstruction-quality evidence.
- Apple GET-only lookup verified `com.rendprop.app` exists as app 6808982413,
  and `com.rendprop.spatialspike.capture` has **no app record**. No ASC state
  was changed; credentials were used internally and not printed.

No archive, distribution signing, upload, tester invitation, App Store version
attachment, App Review submission, database migration or backend deployment was
performed. The new isolated simulator above was created solely for these tests,
avoiding existing simulators and their Keychains. No simulator was erased.

## Distribution choice and remaining verification limits

1. Target confirmation remains necessary: the existing Rendprop app contains
   none of the spatial capture toolkit. A separate capture TestFlight app needs
   its own ASC record; adding a test-only entry to Rendprop is a different
   implementation and artifact. Do not upload an unchanged Rendprop binary and
   describe it as the spatial capture build.
2. Both shipping UI walks are screenshot collectors, not asserting
   release tests. `ReviewerWalk.swift:44–47` explicitly avoids assertions;
   `RendpropUITests.swift:11–14` likewise. Their output must be checked for
   actually reached required screens, not merely `TEST SUCCEEDED`.
   Both returned exit 0 and XCTest reported one passing test with zero skips,
   but their activity logs showed internally skipped screens:
   - ReviewerWalk: missing `r04-sample-detail`; required-screen gate exited 1.
     The inspected Homes screenshot shows a sample card lower down the screen;
     this is insufficient test coverage, not proof the sample feature is absent.
   - Main walk: missing `04-reel-studio-voice`; the selected fixture lacked two
     photos, so the reel card was disabled. Required-screen gate exited 1.
   Results and activity evidence are in
   `/tmp/rendprop-testflight-gates.yMUxlC/{ReviewerWalk,MainWalk}.xcresult`,
   `reviewer-activities.json`, `main-activities.json` and their walk logs.
   These runs are not complete shipping-app release gates. They are separate
   from the standalone capture tests. No shipping-app code was changed.
   Some Settings code remains live despite `-uiTesting`; the deletion dialog
   was only opened and cancelled on the fresh simulator, never confirmed.
3. Signing/provisioning for the standalone bundle and Apple build processing
   remain unverified. Its App Store Connect record does not exist. An unsigned
   device build is not an installable TestFlight artifact.
4. Physical AR, real export, sustained memory/thermal behavior and phone-browser
   performance await owner testing after distribution. Older-device eligibility
   is capability-based; older-device performance is not yet measured. No real
   scan or paid GPU training has run, and no GPU host/budget has been selected.
5. DB migration replay and full live-provider end-to-end tests were not run.
   HDR verification is the explicit environment gap described above. Neither
   these unrelated backend gaps nor the future real-room experiment are being
   represented as a requirement to obtain the isolated capture TestFlight app.

## Disk pressure — recovered without deletion

An early attempt to open the ASC test log failed with **no space left on
device** (112 MiB free); that attempt did not execute tests. Shutting down only
the newly owned simulator recovered space. Testing resumed serially; the ASC
suite and all simulator runs listed above subsequently executed. The final
preflight disk check showed about 2.2 GiB free. Recheck before an archive/export;
disk headroom remains narrow. No caches, captures, source, simulator data or
other files were deleted.

## Proposed cleanup — requires owner approval, not executed

Only these seven regenerable compiler-output directories have been identified.
Together they occupy approximately 815 MiB. Their parents' test executables/logs,
all source, all synthetic fixtures, and every actual capture remain untouched.
Removing these directories would remove the redundant unsigned app artifacts
inside them; they can be rebuilt, but an old handoff's build-artifact link may
then need to be updated. More disk space may still be necessary.

```text
/private/tmp/spatial-capture-verify.p3O0l9/DerivedData
/private/tmp/spatial-capture-verify.CGCBSq/DerivedData
/private/tmp/spatial-capture-verify.wYb7a8/DerivedData
/private/tmp/spatial-capture-verify.FuV4Ir/DerivedData
/private/tmp/spatial-capture-verify.cpowk8/DerivedData
/private/tmp/spatial-capture-verify.mn5rGh/DerivedData
/private/tmp/spatial-capture-verify.oqzjau/DerivedData
```

## Compatibility and packaging implemented

The standalone deployment target is now **iOS 15.0**, with `arm64` and `arkit`
required capabilities, plus runtime world-tracking support and camera-permission
checks before allocating ARView. It does not require LiDAR or a Pro model.
The actual start/stop/save/export lifecycle is tested; restart is blocked during
saving/export validation, and the old session delegate is detached during
preview teardown. Capture camera geometry, frame schema and raster contract
were not changed. The app uses the owner's existing icon, includes a local-only
privacy manifest, and defines a separate Release archive scheme. No new SDK,
analytics, backend endpoint, account, networking or paid provider was added.

Compile availability does not prove performance on every older iPhone. Keep
actual device/OS/thermal/quality results separate from capability eligibility.
The owner will supply the iPhone 15 Pro capture through TestFlight. GPU
destination and any spending cap still need approval for subsequent training;
the Mac cannot run the selected CUDA trainer.

Do not execute `tools/asc/bridge-600-archive-upload.sh` unchanged: it removes fixed
archive/export directories and suggests attaching the uploaded build to the
pending App Store version. Use unique outputs and upload only the confirmed
target after its real gates pass. Do not attach/submit an App Store version.

PolyLayout was assessed separately in
`/Users/pilksclaes/Rendprop AI/spatial-phase-a/tools/spatial-spike/POLYLAYOUT-ASSESSMENT.md`.
It is a possible future room-envelope estimator, not a native iOS SDK or
photorealistic 3DGS replacement. Dependency reproducibility and checkpoint
commercial-use rights remain unresolved. Nothing from it was integrated.
