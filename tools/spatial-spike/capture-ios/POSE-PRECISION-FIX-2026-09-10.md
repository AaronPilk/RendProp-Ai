# Spatial capture stops after 0–3 frames: local fix and evidence

Date: 2026-09-10. Branch: `fix/spatial-pose-validation-20260910`.
Parent: `0f36496909eb45f1ce56303e07c17a3ab3fed7ee`.

## Outcome and limits

The iOS validator rejected legitimate floating-point affine transforms because
it required the camera-to-world matrix's bottom row to be **exactly**
`[0, 0, 0, 1]`. The reconstruction importer already permits an absolute residual
strictly below `1e-6`. This patch aligns that one validation rule, without
changing any recorded matrix values, intrinsics, image orientation or pixels.

The old compiled validator reproduces both immediate failure and the reported
"3 frames saved" failure pattern with synthetic data. The fixed code passes
those regressions and rejects malformed poses. This is a demonstrated code
defect and a plausible explanation of the device observation, **not yet a
verified successful capture on the owner's phone**. No failing ARFrame or raw
matrix from that phone was available; do not invent its numerical residual.

No Apple/App Store Connect/TestFlight action, build-number change, backend
deployment, paid provider call, real-room/GPU run, or user-data deletion was
performed for this fix. Installed build 17 does not receive a local code edit.
The Apple submission freeze remains in effect.

## What the owner observed, and why the screen turns black

The owner confirmed TestFlight 1.0 (17), a briefly visible camera preview, and
then an error. Two screenshots show `Invalid c2w homogeneous row.` after zero
and three saved frames respectively.

The source path is:

1. `Sources/CaptureRecorder.swift:118` snapshots the pose, calibration and other
   metadata from the same ARFrame into a value record; the image buffer comes
   from that same frame at line 106. There is no later `currentFrame` lookup,
   pose transpose, inverse or display-orientation conversion.
2. `Sources/CaptureModel.swift:18` correctly serializes Swift SIMD columns as
   mathematical JSON rows. Float-to-Double widening preserves the Float value;
   it does not create the observed numerical difference.
3. `Sources/CaptureRecorder.swift:129` validates before writing the JPEG at
   line 132 or JSON at line 137. The old exact equality was at
   `CaptureModel.swift:77` in parent `0f36496`, and at line 57 in shipped source
   `22892e9`.
4. The catch at `CaptureRecorder.swift:146` records the error and finalizes the
   attempt. Finalization at lines 59–78 preserves the durable count and marks
   failure. The failing frame's sidecar is not saved, so saved earlier frames
   alone cannot reveal the exact rejected matrix.
5. `SpatialCaptureViewController.swift:58` receives completion and releases the
   preview. `releasePreview()` at line 237 detaches, pauses and removes the
   ARView. The black view is thus explained by failure teardown; it is not
   independent proof of a camera rendering defect.

Paths above are relative to `tools/spatial-spike/capture-ios/`. Unless a commit
is explicitly named, line numbers refer to this fix's local branch, not the
older shipped source.

## Exact implementation

`Sources/CaptureModel.swift:15` defines a named `1e-6` tolerance. Lines 83–89
validate shape and finite values first, then require the maximum absolute
bottom-row deviation to be strictly less than that tolerance. This is the same
component-wise bound as `../training/prepare_capture.py:89`.

Why a tolerance is necessary: a normal rigid transform calculated using Float
SIMD arithmetic can end in `0.9999999403953552` rather than exactly `1`. On this
Mac, a deterministic set of 1,000 matrix inversions produced 380 nonexact rows
without optimization, 379 with `swiftc -O`; the largest last-element residual
was `1.7881393432617188e-7` in both runs. Counts are diagnostic, not portable
assertions about other CPUs or claims about ARKit's internal implementation.
Explicit neighboring Float values make the regression independent of those
optimizer-dependent inverse counts.

The fix **does not** snap the row, divide by its last element, normalize the
rotation, repair a transpose, change calibration, or discard invalid frames
silently. Existing schema/epoch, shape, finite-value, rigid-rotation,
determinant, image/calibration and feature-point checks remain. Matrices beyond
the strict boundary still stop capture. The failure message now includes only
the maximum row residual and bound, not camera positions or a full pose.

## Verification actually performed

### Before fix: compiled production code fails

New `Tests/PosePrecisionChecks.swift` was compiled against the unchanged model,
raster writer and archive before modifying production code. Preserved binary:
`/tmp/rendprop-pose-fix.FkT3lN/before-checks`.

```text
before-checks
FAIL: Invalid c2w homogeneous row.
exit 1

before-checks --export-only
FAIL: Synthetic frame 4 rejected after 3 saved: Invalid c2w homogeneous row.
exit 1

before-checks --force-failure
FAIL: intentional pose-precision failure
exit 1
```

These checks explicitly assert exit 1, not merely any nonzero/crash. Another
agent independently reran all three. The failure-pattern fixture uses actual
record validation before its file writes, but it does **not** instantiate
ARFrame or execute CaptureRecorder's delegate/writer queues.

### After fix: local capture gate

Command from repository root:

```sh
bash tools/spatial-spike/capture-ios/verify.sh
```

Exit 0. Log: `/tmp/rendprop-pose-fix.FkT3lN/after-verify.log`.

- 3,076 new pose precision assertions, zero skipped.
- 115 existing geometry/schema/cadence/completion/native JPEG assertions.
- Seven archive adversarial cases and eight JPEG resource cases; zero failures
  or skips.
- UI-summary parser self-test rejects ten invalid summaries. This is a parser
  negative-control test, not a new simulator UI walk.
- Deliberate failing controls return exactly 1; their `FAIL` messages in the
  log are intentional and are checked before trusting the positive run.

The new suite executes the production SIMD serializer, FrameRecord validator,
JSON encode/decode, full on-disk export validator and saved-capture export path.
It verifies unchanged raw pose/calibration values and sidecar bytes, accepts
bounded roundoff, rejects the strict boundary and invalid/nonfinite,
translated-transpose, reflected or scaled matrices, and keeps failed attempts
nonexportable. The exported 20-frame fixture is synthetic, not room capture.

An additional `swiftc -O` build of the same regression passed all 3,076
assertions with exit 0; its deliberate negative control exited 1. Compile/run
logs are `release-compile.log`, `release-run.log` and `release-negative.log` in
`/tmp/rendprop-pose-fix.FkT3lN/`. This is an optimized macOS test executable,
**not** an archived Release iOS app.

### Python importer

```sh
PYTHONDONTWRITEBYTECODE=1 /tmp/spatial-training-verify.rUYL0A/venv/bin/python \
  -m unittest discover -s tools/spatial-spike/training -p 'test_*.py' -v
```

Exit 0: 33 tests, including nine new precision cases; no failures or skips.
Log: `/tmp/rendprop-pose-regression.IliPfZ/full-training.log`.
The new file tests the actual importer, including raw-value/negative-zero
preservation, Float32 neighbors, both sides of the strict boundary, and
invalid/projective/nonfinite/transpose/reflection/scale/shear cases. An
independent in-memory permissive-validator mutation makes the boundary test
fail with exit 1. No production importer policy was changed.

### Actual Swift-to-Python file interoperability

```sh
PYTHONDONTWRITEBYTECODE=1 bash tools/spatial-spike/verification/verify.sh \
  /tmp/spatial-training-verify.rUYL0A/venv/bin/python
```

The existing canonical fixture still goes through its independent binary
parser. A new separate `--pose-roundoff` fixture sets a real SIMD Float element
to `Float(1).nextUp`, then uses the production serializer, validator, native
JPEG writer and JSON encoder. The real Python CLI validates and exports it.
The check asserts 20 frames/120 seeds, byte-snapshotted raw pose preservation,
unchanged calibration, unchanged source fingerprints/JPEGs, and equality of all
three output binaries with the independently checked canonical dataset. This
tests the existing affine interpretation, not a division by homogeneous w.
The transposed negative fixture must fail with the right reason and exit 1.
Final root-run exit: 0. Log:
`/tmp/rendprop-pose-fix.FkT3lN/interop-final.log`. Preserved artifacts:
`/tmp/rendprop-spatial-interop.H0765P`.

Two additional **test-harness** problems were found and corrected:

- Before modification, the existing generator wrote an extra
  `SYNTHETIC-NOT-A-ROOM.txt` into the capture root, violating the newer strict
  file-set rule. The full pre-edit gate correctly returned 1 with "Capture
  contains unexpected files or directories"; a later component PASS did not
  make the gate green. `verification/main.swift` now stops generating that
  extra file. Synthetic naming remains in directories, manifests and output.
  No existing file was deleted and the production file-set rule was not
  loosened. Evidence: `/tmp/rendprop-roundoff-interop-proof.k9VNo0/before.log`.
- `verification/check_contract.py` previously allowed `python -O` to disable
  its assertions. Root proved this by feeding its canonical checker the
  noncanonical roundoff fixture: normal execution rejected it with exit 1,
  optimized execution incorrectly printed PASS and returned 0. The standalone
  checker, full-harness preflight and new inline checker now explicitly refuse
  disabled assertions. `PYTHONOPTIMIZE=1` full-harness and `python -O` checker
  controls both return 1. Logs: `contract-normal-before.log`,
  `contract-optimized-before.log`, `contract-optimized-after.log` and
  `interop-optimized-after.log` in `/tmp/rendprop-pose-fix.FkT3lN/`.

The raw-preservation check snapshots matrix bytes before invoking validation;
comparing input/output objects only after a call could miss an in-place
normalizer. An independent reviewer executed the actual inline checker with
an in-memory normalizing validator: normalization during loading fails with
`load_capture changed the raw pose` and exit 1; normalization delayed until
the explicit validation call fails with `validate_pose mutated its input`
and exit 1. The unmodified checker passes with exit 0. No test fixture here
establishes actual ARKit frame accuracy.

### iOS source and build-input checks

All seven capture Swift sources passed `xcrun swiftc -typecheck
-parse-as-library -target arm64-apple-ios16.0-simulator` against the installed
iPhoneSimulator26.4 SDK, exit 0, no diagnostics. Evidence:
`/tmp/rendprop-pose-fix.FkT3lN/ios-typecheck.log`.
This is typechecking, not linking, a fresh integrated app build or device AR.

`apps/ios/project-spatial-testflight.yml:20` explicitly includes the shared
modified model. Independent parsed-project graph assertions confirm it appears
exactly once in the generated spatial project's Rendprop Sources phase and
that Release enables `SPATIAL_CAPTURE_LAB`. The normal project excludes the
experimental sources by design. No stale copied model or second production
validator was found. Tests grep implementation symbols before compilation.

## Remaining gates and follow-up work

- After the Apple freeze is lifted and a new internal build is authorized,
  capture a fresh room on the iPhone 15 Pro. Confirm the preview persists,
  capture continues well beyond three frames, Stop and save works, and saved
  export works after reopening. For the actual reconstruction experiment,
  follow the existing 150–250-frame room-capture guidance. Do not reinstall the
  app, delete old captures, or relabel failed attempts as successful.
- If it still stops with this error, retain the new residual-bearing message.
  The previous generic error did not establish whether the actual device's
  residual is within this fix's bound.
- A successful phone capture must then pass the real importer, bounded GPU
  reconstruction and real-phone viewer checks. This local Phase A screen does
  not yet generate a finished 3D tour; tests here do not close Phases B–E.
- Separate existing contract drift remains: iOS rotation/determinant tolerance
  is `0.01` at `CaptureModel.swift:94,100`, while the importer uses `1e-3` at
  `prepare_capture.py:95,100`; importer calibration checks are also stricter.
  This fix aligns **only the homogeneous-row rule**, not all pose acceptance
  policies. Reconcile those contracts with real data in a separate change;
  do not casually loosen the importer to get a green report.
- Structural matrix validation cannot detect a transposed pure rotation at
  zero translation: it is another valid rotation. Keep serializer/coordinate
  interoperability checks rather than promising universal transpose detection.

An independent code review found no blocking issue in the narrow fix. The
owner's successful physical capture remains explicitly unverified.
