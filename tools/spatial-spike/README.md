# Spatial tour — Phase A experiment

This is a **private experiment, not a released feature**. It is isolated from
Rendprop's shipping app, database, AI routes, public tour pages, and billing.
The branch is `spike/spatial-phase-a-20260910`, initially based on `4e28bb5` of
`origin/feat/agent-reel`, with brand-only upstream commits through `2c5903f`
integrated. The owner's Phase A approval is required before any
Phase B–E product work.

Start with [HANDOFF.md](HANDOFF.md) for what was actually executed, evidence
locations, limitations, and the next physical test. The local gate is:

```sh
# From the repository root; use the adapter environment described in training/.
SPATIAL_PYTHON=/path/to/adapter-venv/bin/python bash tools/spatial-spike/verify-local.sh
```

It checks source symbols, 24 Python tests, 7 viewer tests, 36 Swift assertions,
an unsigned standalone iPhone build, and the Swift-to-Python synthetic contract.
The viewer's browser behavior and real-phone performance are separate checks.

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

Before renting a new GPU or using a new provider, obtain the owner's explicit
approval and a cost ceiling. A real iPhone capture requires someone physically
walking through an appropriate room. Do not reuse private customer media merely
because it is present on the computer.

Record these values from the actual run, retaining the commands and artifact
hashes. Leave a value unmeasured instead of copying a number from a blog or a
synthetic benchmark:

| Required observation | Current evidence |
| --- | --- |
| Real-room accepted frame count and capture device | Not measured |
| GPU model, VRAM, trainer commit/configuration | No GPU run |
| Training wall-clock minutes and actual billed cost | Not measured |
| Trained Gaussian count and PLY bytes/hash | No real-room artifact |
| SOG bytes/hash and conversion version | No real-room artifact |
| Actual phone model, OS, browser, canvas resolution | Not measured |
| Visible, moving real-room browser frame rate | Not measured |
| Visual quality, failure regions, and navigation evidence | Not observed |

Desktop checks cannot establish phone performance. Render-loop timings are not
GPU timing or proof that every submitted frame reached the display. Record what
the viewer measures, including invalidated/background runs and the warmup.

## Privacy and scope boundaries

- Keep test captures and generated artifacts outside version control.
- Use an owner-approved room; remove or cover personal mail, medication,
  photographs, and other private material before this unredacted experiment.
- No automatic upload, public hosting, share link, or production R2 destination.
- No inference that a private spike supplies the product's privacy-review,
  region-redaction, or room-exclusion requirements. Those remain public-launch
  gates and are deliberately not bypassed here.
- No job queue, plan gating, room waypoints, floor-locked product navigation,
  measurement tool, flythrough chapter binding, or changes to `/t/` and `/u/`.
- No deployment, App Store Connect changes, disabled-route enabling, deletion,
  or unapproved GPU/provider spending.

## Source boundaries

[PlayCanvas documents SOG](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/)
as lossy web-delivery compression. Its typical compression ratio is not a
guarantee for this room. [gsplat's training example](https://docs.gsplat.studio/main/examples/colmap.html)
describes the training interface; it does not establish ARKit reconstruction
quality, five-minute runs, or a cents-per-room price. Those claims require this
experiment's actual results.
