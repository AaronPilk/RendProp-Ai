# Spatial tour — Phase A experiment

This directory contains the standalone capture harness, dataset adapter,
bounded experiment tools and private SOG viewer. The capture sources and adapter
are also reused by Rendprop's integrated spatial workflow; the directory is no
longer wholly separate from the product. See the [spatial API](../../services/supabase/functions/spatial/README.md)
and [automatic worker](../../services/spatial-worker/README.md) for that path.

**As of the 24 September 2026 evidence review, reconstruction is not accepted
for release.** Seven completed ablations on the owner's 400-frame capture all
failed visual acceptance. There is no winning production profile. Keep the
worker and runtime disabled until real output passes; the successful Studio
release does not enable spatial reconstruction.

The original branch was `spike/spatial-phase-a-20260910`, based on `4e28bb5` with
brand changes through `2c5903f`. [HANDOFF.md](HANDOFF.md) preserves that early
experiment's historical record; its unmeasured fields are not the current
experiment status. The local tooling gate remains:

```sh
# From the repository root; use the adapter environment described in training/.
SPATIAL_PYTHON=/path/to/adapter-venv/bin/python bash tools/spatial-spike/verify-local.sh
```

It checks source symbols, the current Python and viewer suites (including
negative controls), portable Swift checks, an unsigned standalone iPhone build,
and the Swift-to-Python synthetic contract. Use `--no-build` to omit the Xcode
app build. The [training environment](training/README.md), Node 22+, macOS Swift
tools and, for a device build, Xcode/XcodeGen must already be available. The
viewer's browser behavior and real-phone performance are separate checks.

## Current evidence — 24 September 2026

This summary reconciles the owner's `CLAUDE-SPATIAL-REPORT-20260924.md` and
`CODEX-REVIEW-CLAUDE-SPATIAL-20260924.md` handoffs. Those full reports, original
capture, room artifacts and billing receipts are retained privately outside
Git. The review confirmed the seven bills and corrected the seven-run subtotal
to **$13.01280671**. Gross spend including earlier experiments is
**$19.98118436 of the $25 ceiling**, with **$5.01881564 remaining** and no
outstanding holds at that review. These are dated reconciled charges, not a
fresh provider balance or an advertised per-room price.

| Run | Change from its declared comparison | PSNR ↑ | SSIM ↑ | LPIPS ↓ | Gross USD | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| f01 | Baseline, 3,000 steps, pose optimization off | 18.7851 | 0.7957 | 0.5736 | 0.61029876 | NO-GO |
| p01 | Pose optimization on | 18.7285 | 0.7959 | 0.5748 | 0.62267687 | NO-GO |
| s01 | 30,000 steps | 20.8456 | 0.8060 | 0.5012 | 2.19026254 | NO-GO |
| g01 | Hybrid SfM poses and seeds | 19.2525 | 0.7758 | 0.4809 | 2.30056359 | NO-GO |
| c01 | 1,000,000 Gaussian cap | 16.5350 | 0.7793 | 0.5954 | 2.38583029 | NO-GO |
| n01 | MCMC noise learning rate 500,000 → 139,873 | 21.2317 | 0.8077 | 0.4824 | 2.39945690 | NO-GO |
| z01 | World normalization on | 20.8806 | 0.8062 | 0.4932 | 2.50371776 | NO-GO |

All runs use the frozen 400-frame capture with 350 training views and the same
50 held-out views. The measurements belong to separately reviewed experiment
branches; changing a runtime row cannot make the integrated 7,000-step,
1,800-second, pose-optimization-off worker reproduce them. n01 has the highest
PSNR, but none has legible enough detail and stable geometry to ship.

The next priority is capture quality. Measured motion and exposure support blur
as a strong contributor: 303/400 frames used 1/60-second exposure; predicted
central rotational smear exceeded 5 pixels in 221 frames. Independent SfM
registered 393/400 frames and broadly agreed with ARKit, arguing against gross
trajectory failure. **Residual pose error and the benefit of training with
independent SfM remain unresolved**; that registration was not itself trained.
Numerically close scores do not establish statistical equivalence or causality.

No further paid run on this capture is part of the documentation update. The
capture-guidance/blur-guard and train-only adapter changes reviewed separately
are not integrated here. That review identified product source-registration,
frame selection, invalid-exposure, sparse-motion and fixed-holdout issues.
Correct and review them before phone delivery or pre-rental quality claims. Any
future sharp-training subset must preserve the original 50 held-out IDs and
exclude those views from seed construction. A new owner-operated daylight
capture with slow turns, pauses, overlapping views and upper-corner coverage is
the next physical validation; a simulator cannot supply it.

## The hypothesis we are testing

Can original iPhone camera images, ARKit camera poses, and ARKit feature points
produce a usable room reconstruction without running COLMAP/SfM, and can the
compressed result be navigated acceptably in a real phone browser?

Camera poses alone do not prove this. The trainer also needs initial 3D points;
ARKit's sparse feature points are a candidate seed, not a quality guarantee.
Tracking drift, low-texture walls, mirrors, moving objects, image orientation,
intrinsics, and insufficient coverage can still spoil a reconstruction. Using
the COLMAP **dataset format** does not mean executing COLMAP or estimating poses
with SfM. The adapter must preserve and test that distinction.

## Three independent pieces

- `capture-ios/`: a separate, disposable iOS harness. It writes camera-native
  JPEGs, their calibration/pose sidecars, and feature points to its own sandbox.
  It does not request a Rendprop login or send a room anywhere.
- `training/`: validate the capture and convert the known poses/points into the
  pinned trainer's input format. Malformed or mixed-coordinate captures must
  fail before any GPU is rented or used.
- `viewer/`: pinned, locally served web viewer and an explicit measurement run.
  A file selected on the phone stays local to the browser; it is not published.

Each directory documents its commands, dependencies, limitations, and tests.
Unit tests and synthetic scenes are engineering checks. They are **not** a
substitute for the real-room acceptance test.

## Baseline actually executed before implementation

On 2026-09-10, from a clean worktree at `4e28bb5`:

```sh
cd services/supabase/functions
deno test --allow-net --allow-read --no-check ai-copy/
```

Exit 0: `111 passed | 0 failed`, with no ignored tests.
Local evidence: `/tmp/rendprop-spatial-baseline-deno-20260910.log`.
This is a unit-test result, not a live-route, TypeScript typecheck, or GPU result.

```sh
cd apps/ios
xcodegen generate
xcrun simctl boot CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E
xcrun simctl bootstatus CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E -b
xcodebuild build-for-testing -project Rendprop.xcodeproj -scheme Rendprop \
  -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E'
```

The simulator was already booted. Build exit 0: `TEST BUILD SUCCEEDED`.
Local evidence: `/tmp/rendprop-spatial-baseline-ios-20260910.log`.
This built the test targets; it did **not** run the reviewer/UI walks or a camera.
Pre-existing RenderEngine Sendable warnings remain outside this experiment.

Negative control: running the Deno command **without** `--allow-read` exited 1
with `NotCapable`, `78 passed | 1 failed`. The permission error is no longer
misreported as two intentionally ignored tests. Evidence:
`/tmp/rendprop-spatial-negative-read-permission-20260910.log`.

## Physical acceptance — not yet established

The owner's total spatial ceiling remains **$25 across all attempts**; it is
not reset for a new run or branch. Reconcile current spend and any outstanding
holds before another paid allocation, and obtain approval before increasing that
ceiling. No automatic paid retry is allowed after an ambiguous provider result.
A real iPhone capture requires someone physically walking through an appropriate
room. Do not reuse unrelated private customer media merely because it is present
on the computer.

Record these values from the actual run, retaining the commands and artifact
hashes. Leave a value unmeasured instead of copying a number from a blog or a
synthetic benchmark:

| Required observation | Evidence as of 24 September |
| --- | --- |
| Real-room accepted frame count | Owner supplied 400 frames; parsing acceptance is not visual acceptance |
| GPU and trainer | L4; pinned gsplat v1.5.3, with separate experiment configurations |
| Training time and cost | Per-run receipts retained privately; gross charges above include setup/CPU/GPU/memory |
| Trained Gaussian count and PLY bytes/hash | Private artifacts and inventories exist; none passes visual acceptance |
| SOG conversion and desktop navigation | Private review performed; desktop movement still shows unacceptable defects |
| Actual physical phone viewer workload/FPS | No accepted real-room phone performance result |
| End-to-end phone upload → automatic queue → accepted private viewer | Not accepted |

Desktop checks cannot establish phone performance. Render-loop timings are not
GPU timing or proof that every submitted frame reached the display. Record what
the viewer measures, including invalidated/background runs and the warmup.

## Privacy and scope boundaries

- Keep test captures and generated artifacts outside version control.
- Use an owner-approved room; remove or cover personal mail, medication,
  photographs, and other private material before this unredacted experiment.
- The standalone harness and viewer do not automatically upload or publish;
  the integrated product's explicit scan handoff uses its authenticated upload
  and private-review path. Do not use the local experiment as a publishing bypass.
- No inference that a private spike supplies the product's privacy-review,
  region-redaction, or room-exclusion requirements. Those remain public-launch
  gates and are deliberately not bypassed here.
- The standalone viewer does not implement the product queue, room waypoints,
  floor-locked navigation, measurement tools or flythrough chapter binding. The
  integrated API/viewer are documented separately; measured dimensions and
  actual region-redaction processing are not supplied by this spike.
- No deployment, App Store Connect changes, disabled-route enabling, deletion,
  or unapproved GPU/provider spending.

## Source boundaries

[PlayCanvas documents SOG](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/)
as lossy web-delivery compression. Its typical compression ratio is not a
guarantee for this room. [gsplat's training example](https://docs.gsplat.studio/main/examples/colmap.html)
describes the training interface; it does not establish ARKit reconstruction
quality, five-minute runs, or a cents-per-room price. Those claims require this
experiment's actual results.
