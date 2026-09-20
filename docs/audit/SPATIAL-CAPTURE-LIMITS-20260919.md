# Spatial capture limits: native regression evidence

**Result: the cap repair passed the bounded offline regression and the full unsigned Release iPhone app build.** This proves capture completion, preservation, the explicit-use gate and compilation. It does not establish reconstruction quality, ARKit accuracy, real-device usability or deployment readiness.

The baseline is `1ed500931ef16b26c644c25be828a7227a8a5208`. The repaired sources were read from isolated branch `fix/spatial-capture-limits-20260919`. No product files were changed by the test agent; no original phone captures, user account, camera, provider, GPU job or App Store Connect operation was used. Spend: **$0**.

## What actually ran

The native runner compiled the complete production `CaptureRecorder`, `CaptureModel`, `CaptureQuality`, `CaptureControls`, `CaptureArchive` and `NativeRasterWriter`. Synthetic `ARFrame`/camera/session values replace only the ARKit device boundary. The real CoreVideo pixel buffer, Core Image conversion, ImageIO JPEG encoding/decoding, frame selection, disk writes, serial queues, atomic manifest updates and full-file validation execute on macOS.

The only filesystem substitution sends `CaptureArchive.local()` to a new temporary test directory. Queue-control methods are appended to a copied recorder in the same Swift file; actual recorder methods are not rewritten. Controller tests extract the actual completion handler, export button action, `refreshControls` and `verifyAndExport`; lightweight UIKit objects record their state and callbacks. These are native controller logic tests, **not a screenshot or XCUITest**.

The same output then passes through the real Python `training/prepare_capture.py` importer, with real JPEG decoding. The valid repaired 400-photo capture also becomes a 400-image posed dataset using its existing writer. This is CPU-only preparation, not SfM or training.

## Results

| Scenario | Baseline result | Repaired result |
|---|---|---|
| Frame 400 admitted while its disk write is blocked; frame 401 arrives | Exactly 400 frame pairs retained; `limit_reached`; unexportable | Exactly 400 frame pairs retained; `complete`, `frame_limit`; full validation passes |
| Frame at 599.999 seconds pending; frame at 600 arrives | 21 frame pairs retained; `limit_reached`; unexportable | 21 frame pairs retained; `complete`, `duration_limit`; full validation passes |
| Last JPEG move fails while cap finalization is queued | `failed`; unexportable | `failed`; unexportable, with cap reason retained |
| Last JPEG corrupted before cap finalization | Unexportable | Full JPEG validation refuses export |
| Only 19 photos at the duration cap | Unexportable | Still unexportable |
| Interruption / AR session failure | `interrupted` / `failed`; unexportable | Same behavior; originals retained |
| Manual stop after 20 valid photos | Valid; normal handoff | Valid; normal handoff; no cap reason |
| NaN / infinite timestamp / timestamp before epoch | Not part of baseline comparison | `failed`; no cap reason; all prior files retained |

While the final frame write is blocked, the actual recorder immediately closes admission but does **not** emit completion. It writes no 401st image. Releasing the writer lets that final JPEG/sidecar commit before exactly one completion. A late interruption and extra frame after the terminal cap do not change this outcome.

Native assertions: **55 baseline checks across 8 attempts; 86 repaired checks across 11 attempts**. The real importer correctly accepted/refused all **8 baseline and 11 repaired** cases. Its fixed 400-image dataset retained all original JPEG hashes.

Controller checks prove:

- Both normal cap reasons leave an enabled, visible **Use this scan** button and emit no automatic generation handoff.
- An explicit tap runs full archive validation before one handoff.
- Corrupting a separate test copy after completion makes that tap fail validation; it emits no handoff and retains the changed file.
- Invalid/short/failed completions cannot hand off even when a cap reason is present.
- A late callback cannot reopen a closed controller.
- Manual stop preserves its previous validated handoff; standalone export still presents a copy only after an explicit tap.
- Stop reasons round-trip through the real manifest and archive listing. Older manifests without the field decode. Legacy `limit_reached` captures remain unexportable.

`status == complete` still is **not sufficient** for export: the repaired short and corrupt fixtures have normal cap status but fail the unchanged full validator. Failed writes remain `failed`. The optional stop reason describes why admission stopped, never whether the room is valid.

## Preservation and source provenance

Every previously durable original was hashed before each completion and checked afterward. The final pass also rechecked all recorded regular image/sidecar files, including the intentionally retained partial/corrupt test artifacts: **1,079 baseline files and 1,199 repaired files unchanged**. Controller corruption tests use separate copies, leaving the recorder fixtures intact.

The full `RasterWriter.swift` is byte-identical baseline/fixed, SHA-256:

`c0cee22106af6ec37f0ec830af2488aefa3049297441fe46c973001a40da0f48`

Evidence directory: `/tmp/rendprop-spatial-limits-20260919-second`

- `receipt.json`: native check/case counts.
- `baseline/source-hashes.json`, `fixed/source-hashes.json`: full original and compiled source hashes.
- `baseline/sources/`, `fixed/sources/`: exact compiled source snapshots.
- `baseline/compile.log`, `fixed/compile.log`: successful native compiler logs.
- `baseline/runtime.log`, `fixed/runtime.log`: native regression outcomes.
- `baseline/fixtures/recorder.json`, `fixed/fixtures/recorder.json`: every assertion, manifest, path and source hash.
- `baseline/importer.json`, `fixed/importer.json`: real importer outcomes and refusal reasons.
- `fixed/posed-dataset/`: 400-image CPU-only posed dataset.
- `final-media-check.json`: final independent original-file hash counts.

The first harness attempt at `/tmp/rendprop-spatial-limits-20260919-first` preserves a Swift compiler failure in a synthetic point-grid expression. Replacing that expression with an explicitly typed loop fixed only the harness. No product failure was hidden by that iteration.

## Delayed notice race and caller wiring

A second, focused native suite verifies the parent's subsequent `SpatialTourView` race repair. It extracts the real `inspectCaptures` and `invalidateCaptureInspection` methods, the actual scan-button, accepted-handoff, account-change and dismissal closure bodies, and the real `SpatialCaptureHandoff.accepts` implementation. The UI state lives in a small native host; the upload boundary is a recording spy.

A test-only barrier pauses entry into the **actual** `CaptureArchive.validateForExport`. It then runs the real caller actions while A's detached inspection is pending and releases validation afterward. The dismissal task handle is retained for deterministic awaiting; the task's actual method call is unchanged. Fixture copies use the original repaired recorder's 400-photo room. Their photo and sidecar bytes remain real native output.

**31 assertions passed across five traces:** the same presentation, B actively recording, B opened then closed before its separate inspection, B successfully handed off, and account A→B→A. The same presentation publishes a fully validated notice for explicit use. Every stale A trace publishes nothing; only the explicitly accepted B handoff reaches the upload spy.

Four negative controls each compiled successfully and then failed a behavioral assertion:

| Mutation | Observed assertion failure |
|---|---|
| Remove invalidation from the actual scan button | Scan action no longer rotates inspection identity |
| Remove invalidation from the accepted-handoff closure | Accepted handoff no longer invalidates the old inspection |
| Remove invalidation from the actual account-change closure | Account change no longer invalidates pending inspection |
| Remove the publication-time identity guard | Late A publishes a stale notice after B opens and closes |

Evidence: `/tmp/rendprop-spatial-inspection-20260919-first`. `source-hashes.json` records all five product source hashes; `SpatialTourView.original.swift` retains the full read; each variant contains exact extracted sources, native compiler/runtime logs and assertion JSON. No remaining compiler process belongs to this suite.

The parent independently ran the existing `capture-ios/verify.sh` successfully in `/tmp/rendprop-spatial-existing-checks-20260919-9e3on7fj` (64.33 seconds): **115 core, 7 adversarial, 8 JPEG and 3,076 pose assertions**, including its quality negative controls. The initial simulator app build also passed before the notice-race repair.

The final full unsigned **Release iOS-device build passed** after the race repair in **260.03 seconds**. Evidence: `/tmp/rendprop-spatial-limits-device-build-20260919-0qewy2lb/build-receipt.json`, `build.log`, and `build.xcresult`. All eight recorded product source hashes remained unchanged throughout compilation. The built executable is `DerivedData/Build/Products/Release-iphoneos/Rendprop.app/Rendprop` in that evidence directory. No device installation, signing, App Store Connect operation or physical runtime test occurred.

## Reproduction

Run from any directory on this macOS host; the runner chooses a fresh temporary directory. Python needs Pillow; the shown bundled interpreter already has it. The runner never installs packages or opens a network connection.

```sh
python3 '/Users/pilksclaes/Rendprop AI/spatial-capture-limits-20260919/tools/audit/spatial-limits-20260919/run.py' --python '/Users/pilksclaes/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
```

`--baseline <revision>` selects a different exact baseline; default is the tested commit above. `--only baseline` or `--only fixed` narrows execution. Use a fresh directory when specifying `--output` so evidence is not overwritten.

After the recorder suite, run the focused inspection test using the emitted fixed recorder receipt:

```sh
python3 '/Users/pilksclaes/Rendprop AI/spatial-capture-limits-20260919/tools/audit/spatial-limits-20260919/inspection.py' --fixture-receipt /tmp/rendprop-spatial-limits-20260919-second/fixed/fixtures/recorder.json
```

Remaining integration checks are to exercise the cap notice and explicit-use screen on a real device and continue the ordered spatial-quality ablation before deciding to ship output. No claim about those checks is made here.
