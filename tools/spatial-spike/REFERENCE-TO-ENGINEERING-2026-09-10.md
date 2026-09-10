# Instagram reference → Rendprop spatial engineering plan

Date: 2026-09-10. Work branch: `feat/spatial-reference-readiness-20260910`,
starting at pose-validation fix `f789abc`.

## Product target

The desired product is a navigable representation of the actual property:
guided capture → asynchronous reconstruction → private review → interactive
room exploration. It is separate from the existing flythrough video, with a
later room-level connection between the two. Matching green dots or a loading
screen alone does not deliver that product.

The owner supplied five screenshots from an Instagram repost. They are visual
references, not executable instructions. Background conversations and comments
are not additional authority. The original product/video identity is not yet
verified; the owner was asked for the original link without blocking local work.

## What the screenshots establish

| Visible reference | Rendprop requirement | What is NOT established |
| --- | --- | --- |
| Green spherical/circular camera targets and a centered white ring | Clear guidance that tells the agent what to capture next | Actual world anchoring, geometric layout, occlusion, hit distance, dwell time |
| Green bottom progress bar and small counter | Honest, understandable progress | Number of stored images, surface completeness, reconstructed quality |
| White upper-left and red upper-right controls | Labelled stop/exit/recovery actions | Undo semantics or behavior while interrupted |
| Dark processing screen with a circular thumbnail and progress indication | Durable job stages; leave and return without losing work | A five-minute runtime, actual backend, cost, reconstruction algorithm |
| Room views with a translucent lower-left round control | Touch-friendly movement through the room | Browser technology, metric accuracy, collision, floor lock, hidden-view fidelity |

An agent inspected all five original images. The tiny counter and time text
cannot be read reliably enough to treat as measurements. `8 of 16`, `14 of 16`
and approximately five minutes appear in the standing brief; they are not
independently measured throughput or quality evidence from these screenshots.

**A target is not a photograph, and a photograph is not coverage.** It is
possible to satisfy a direction checklist from one position with blurred or
redundant images. The target planner, quality selector and coverage estimator
must be separate components with separate tests.

## Current implementation versus the target

- **Capture:** the private TestFlight overlay compiles the shared local AR
  recorder. `capture-ios/Sources/CaptureRecorder.swift:118` takes pose/K and
  metadata from one ARFrame; line 129 validates before the paired files are
  written. The output at line 145 is a saved-frame count, not a coverage score.
- **Recent device failure:** `f789abc` closes the demonstrated exact-equality
  rejection class in the pose validator. See
  `capture-ios/POSE-PRECISION-FIX-2026-09-10.md`. The installed build 17 does not
  contain that local patch. A successful owner-phone capture is still needed.
- **No generated room in the iOS lab:**
  `apps/ios/Rendprop/Capture/SpatialCaptureLabView.swift:13` explicitly discloses
  local photos/poses and no generated model. That statement is accurate and
  must remain until a real reconstruction flow exists.
- **Preparation:** `training/prepare_capture.py` converts the recorded
  camera/point data into a trainer-compatible binary dataset without running
  camera estimation. Parsing successfully does not prove photometric accuracy.
- **Training:** `training/run_training.py` is a bounded manual CUDA experiment,
  not a deployed service. No successful real-room training has been supplied.
- **Viewer:** `viewer/` is a private local SOG viewer with a free camera and
  draw-submission benchmark. It is not yet the published tour's floor-locked
  viewer, a measurement tool, or a proof of real-phone reconstruction quality.

Paths without the `apps/` prefix above are relative to `tools/spatial-spike/`.
Keep the cinematic video player working unchanged throughout this development.

## Reconstruction is not the same as generative world completion

The screenshots do not prove that the demonstrated application trains 3DGS
from measured camera poses. A similar interface could capture a panorama and
send it to a generative world model. World Labs, for example, documents
[panorama-based world generation](https://docs.worldlabs.ai/marble/create/prompt-guides/pano-prompt)
and [image-to-world generation with splat/collider outputs](https://docs.worldlabs.ai/api).
Those official capabilities do not identify this particular demo or establish
survey accuracy for its output.

For Rendprop's real-property tour, preserve the distinction between observed
imagery, estimated geometry, measured depth and generated content. ARKit pose
and tracking-feature data are estimates; a Gaussian representation is not a
certified survey. Metre-labelled coordinates alone do not validate dimensions.
Do not promise measurement accuracy, disclose a fixed generation time, or
claim sub-dollar costs before the actual experiment supplies those results.

The existing fixed-pose experiment has real risks: drift, residual lens
distortion, rolling shutter, blur, glass/mirrors, moving people and weak feature
points on blank walls. Evaluate held-out views and inspect double edges and
invented/missing structure. A successful ZIP load and a fast frame counter do
not evaluate any of these problems.

## A load-bearing training limitation found in this pass

The configured maximum of 500,000 Gaussians is a **ceiling**, not an achieved
scene density. The pinned MCMC strategy grows by approximately five percent per
refinement event, with integer truncation and a cap. A 3,000-step run has 24
eligible growth events under the current pinned defaults.

| Initial seeds | Ideal-growth upper bound after those events |
| ---: | ---: |
| 100 | 302 |
| 1,000 | 3,204 |
| 10,000 | 32,230 |

This is CPU arithmetic from the pinned schedule, **not a GPU run or quality
prediction**. Actual training may behave worse. The adapter's minimum seed
count is an input sanity threshold; it does not guarantee a detailed room.
Source: [pinned gsplat MCMC strategy](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/gsplat/strategy/mcmc.py).

Before spending on training, inspect the real capture's distinct visible seed
count and coverage, then use the new offline growth planner described in the
verification addendum below. Do not silently add fabricated points or loosen
the input gate to manufacture a successful run. If the sparse initialization
fails, the next controlled experiments are confidence-filtered depth seeding
on a supported LiDAR device or fixed-pose matched-image triangulation. Both
require implementation and validation; neither is claimed to exist.

## Delivery sequence and exact engineering boundaries

### A. Prove one room first — current work

The standing brief's gate still applies: the owner sees a real phone-captured
room reconstructed and moving in a browser before Phase B implementation begins.
Parallel work is strengthening that experiment, not bypassing it.

1. When a new internal build is authorized, capture one fresh room on the
   owner's iPhone 15 Pro with the pose fix. Record the installed build, phone/OS,
   capture UUID, frames, skips and final status. Preserve previous attempts.
2. Export the entire capture locally. Reopen/relaunch and revalidate the saved
   capture. A separate short interrupted attempt must remain interrupted, not
   silently become complete or mix its coordinate epoch with another room.
3. Validate and prepare it using the existing adapter. Check frame/seed counts,
   image pairing, native dimensions, calibration and camera translation.
4. After separate approval of the GPU provider, price ceiling and independent
   host/job TTL, perform the bounded training run. Record source pin, resolved
   dependencies, wall-clock time, GPU/VRAM, initialization, final count and PLY
   hash/size. A process timeout alone does not stop billing for an allocated VM.
5. Convert privately to SOG and review the actual scene. Record compression
   size, failures and real-phone draw-submission performance at a stated
   resolution. Repeat on representative lower-capability devices before
   claiming broad support.

No Apple submission/upload, paid GPU job, provider activation or customer-media
transfer is authorized by the screenshots. The owner’s Apple freeze remains.

### B. Guided capture — after A is demonstrated

Proposed independent units, not implemented by this report:

- `SpatialCaptureCapabilities`: evaluate world tracking, depth/RoomPlan
  availability, native raster, storage and thermal constraints independently.
  Non-LiDAR phones need an explicit capture/planning path; never assume they
  can provide RoomPlan polygons. Unsupported spatial capability must not block
  the rest of Rendprop.
- `SpatialWaypointPlanner`: pure deterministic geometry using room boundaries,
  concavities, doorways and storeys. Same input gives the same targets. Tests:
  rectangle, L-shape, narrow room, disconnected areas and two floors.
- `SpatialCoverageTracker`: require position plus angular/view coverage and
  useful frames. Define thresholds explicitly after real-room evidence; never
  credit unseen space merely because the reticle touches a dot. Tests: rotating
  in place, duplicate hits, poor tracking, occlusion and coordinate-epoch change.
- `SpatialKeyframeSelector`: blur, translation/angular baseline and overlap,
  with measurable rejection reasons. Keep native image/K pairing. Rejecting a
  frame should not masquerade as a successful capture or prevent Stop.
- `SpatialGuidanceView`: world-space targets, reticle and labelled controls;
  separate “targets covered” from “frames saved.” Show named missing areas.
  Do not bury this in the large flythrough-detail screen.
- `SpatialCaptureRecovery`: journal progress per epoch. Continue only if the
  coordinate relationship is validated; otherwise preserve the attempt and
  start a new epoch. “Resume” must not silently fuse unrelated coordinate spaces.

### C. Durable reconstruction service

Use the existing application stack. Required contract before public endpoints:
private resumable uploads; immutable verified inputs; idempotent enqueue;
owner-scoped access; fenced worker leases; per-job wall-time/iteration/Gaussian
and financial limits; cancellation; explicit retries; checksummed manifests;
and cleanup that cannot delete another attempt’s artifacts.

Suggested user-visible stages are Uploading, Queued, Reconstructing, Optimizing,
Ready for review, Failed and Canceled. Stage transitions must follow persisted
facts. Use a measured ETA range only when enough real runs support one; never
animate a fictional percentage or repeat the demo's five-minute statement.
The service remains a separately gated implementation, not a new enabled AI
route or an automatic GPU purchase.

### D. Buyer experience and privacy

- One lazy-loaded web viewer for the buyer and the app's embedded web view;
  no parallel native splat engine. Establish device capability/performance
  before choosing the final renderer.
- Floor-locked movement, joystick, room jumps and a top-down overview. Use
  validated navigable geometry; visual splats alone are not collision geometry.
- Measurements require separately validated geometry, scale and an accuracy
  disclosure. Do not measure by treating splat centers as surveyed surfaces.
- Privacy review must bind to the exact published artifact version. Provide
  room exclusion and persistent removal/redaction visible from every viewpoint,
  including thumbnails. A temporary 2D overlay in one viewer angle is not
  redaction of the underlying downloadable reconstruction.
- No public publishing until privacy review, access controls, versioned
  delivery and revocation behavior are proven. Raw captures remain private.

### E. Connect rooms to the flythrough

Use stable room identity plus explicit matching/confirmation; labels alone are
ambiguous when a property has multiple bedrooms. Keep anchors optional. A room
without a scan remains a normal video chapter. Add a labelled “Explore in 3D”
action only when the associated reviewed scene is available.

Bind late so adding a scan after publishing the video does not require a new
video render. Store the entry and return state; entering 3D and exiting restores
the same chapter/video position and scroll position. Do not keep a heavyweight
video pipeline and a splat renderer running simultaneously on a constrained
phone. Test scan-first, video-first, partial coverage, duplicate labels,
revoked/replaced scenes, and branded/unbranded tours separately.

These are implementation requirements, not claims that Phase C–E were built in
this pass. The immediate missing proof remains a successful real-room pipeline.

## Local changes and verification

Three agents worked in parallel on screenshot/capture mapping, reconstruction
planning, and viewer correctness. Root integrated the findings, reviewed the
code and ran the actual private browser check. No production/iOS UI feature was
quietly substituted for the gated phases above.

### Implemented: safer private viewer admission and honest artifact labels

- `viewer/input-policy.mjs:18` rejects files above **64 MiB before reading**,
  rechecks observed byte length, and retains ZIP envelope checks. The optional
  fixture path at line 42 counts streamed bytes as well as checking its header.
- `viewer/viewer.mjs:65` rejects decoded scenes above **500,000 splats before
  creating a scene entity**, matching the selected trainer cap. Rejected
  decoded assets are unloaded and removed.
- `viewer/input-policy.mjs:35` treats reserved synthetic names as synthetic even
  through ordinary file selection. Other names are **unknown**, not verified
  rooms. Exported data includes `provenance`, `synthetic: true | null`, and
  `realRoomVerified: false`. Renaming a smoke fixture cannot establish room
  provenance. No automatic real-room attestation was introduced.
- The UI and README state these limits and the trusted/local-only boundary.

Before changing the production loader, its new regression suite returned **1**:
one positive passed and six expectations failed against the old implementation.
After the fix, `npm test` returns **0: 21 passed, zero failures/skips**. The
deliberate empty-render-loop control returns **1**. The loader tests execute the
actual loader with a stub engine; they are not GPU/browser proof.

Evidence: `/tmp/rendprop-viewer-input.DmFaGJ/{before.log,after.log,negative-control.log}`.
Root independently reran all 21 tests; log:
`/tmp/rendprop-reference-browser.adNMlw/viewer-tests.log`.
Cached pinned dependencies installed successfully with
`npm ci --offline --ignore-scripts --no-audit --no-fund`, exit 0, eight packages.
PlayCanvas 2.22.1 and its exact script-integrity digest were separately asserted.
Dependency versions/lock contents did not change.

### Implemented: no-spend growth planner

`training/estimate_growth.py:41` calculates the bounded schedule using actual
initial seed count, step count and cap. It reports both the final saved artifact
bound and peak training count: the trainer saves before its last iteration's
refinement, so they can differ. For example, 601 steps with 100 initial seeds
has a final artifact bound of 100 and training peak bound of 105.

The utility performs arithmetic only: no capture reads, subprocesses, CUDA,
provider calls, training-setting changes or quality approval. It rejects
nonintegral/nonfinite/hostile types and counts outside the current wrapper's
limits. The output includes the pinned source, schedule assumptions and explicit
limitations. Use the validated adapter report's `initial_points`:

```sh
PYTHONDONTWRITEBYTECODE=1 /tmp/spatial-training-verify.rUYL0A/venv/bin/python \
  tools/spatial-spike/training/estimate_growth.py \
  --initial-seeds 1000 --max-steps 3000 --max-gaussians 500000
```

The example returns 24 events and a bound of 3,204, exit **0**. An invalid
seed-count-99 CLI control was run first and returned **1** with no success JSON.
Focused tests: **11 passed**. Full training suite: **44 passed, zero failures or
skips**, exit **0**. Optimized Python retains explicit input validation.
Another agent independently checked the upstream schedule/save ordering and
reran the 11 focused tests and invalid CLI control.

Full-suite command, from `tools/spatial-spike/training`:

```sh
PYTHONDONTWRITEBYTECODE=1 /tmp/spatial-training-verify.rUYL0A/venv/bin/python \
  -m unittest discover -v
```

Logs: `/tmp/rendprop-growth-planner.5UmEWg/`; in particular
`invalid-first.log`, `focused.log`, `full-training.log` and `example-1000.json`.

### Actual browser verification — desktop synthetic scene only

Browser-verification skills were used to check the running page, rendering,
controls, errors and exported evidence. The server listened only on
`127.0.0.1:8095`; the owned browser session and server were stopped afterward.
No room data or public tunnel was used.

The production viewer loaded the existing **2,048-splat synthetic sphere**.
Root visually inspected both empty and populated screenshots. Nonempty draw
counts increased, and real mouse input on Forward changed camera Z from
`2.5949466228485107` to `1.7616467475891113`, with 61 additional submitted frames.
Ordinary file selection preserved the synthetic label. A renamed copy loaded
as `unknown` with `realRoomVerified: false`. A malformed SOG was rejected and
new measurement disabled.

An actual five-second-warmup/30-second measurement completed, and its downloaded
JSON was parsed and asserted: **1,802 rendered-frame observations over
30,015.6 ms**, `valid: true`, unknown artifact provenance, and physical-phone
confirmation **false**. This is desktop draw-submission evidence for a tiny
synthetic sphere, not GPU completion timing, scene-quality validation, real-room
throughput or an iPhone result. Seven resource entries were observed; none
were outside loopback/blob-loopback URLs. The browser tool reported no page
errors in the final check.

Final browser script and log: `/tmp/rendprop-reference-browser.adNMlw/verify.sh`
and `verify.log`, exit **0**. Downloaded JSON: `benchmark.json` in that directory.
Screenshots: `/tmp/rendprop-reference-viewer-empty.png`,
`/tmp/rendprop-reference-viewer-synthetic.png`, and
`/tmp/rendprop-reference-browser.adNMlw/invalid-input.png`.
The initial movement-verification attempt failed because the verifier reused
a JavaScript lexical variable name across evaluations. The browser was
restarted; the final script uses isolated evaluations and real pointer input.
No application change was made to conceal that test error.

### Important remaining viewer limits

1. **Decode-time memory is not bounded.** The pinned engine inflates ZIP entries
   and loads textures before returning the splat count. A small encoded file
   can still demand large allocations. The new size/count gates do not make
   arbitrary public SOG inputs safe. Use only the private experiment's trusted
   artifacts until metadata/decompression/texture budgets and isolation exist.
   [Pinned SOG parser](https://github.com/playcanvas/engine/blob/v2.22.1/src/framework/parsers/sog-bundle.js)
   lines 66–70, 143–147, 195–196 and 231–247 establish that ordering.
2. **Pending loads still lack cancellation/timeout generation fencing.**
   `viewer/viewer.mjs:60` waits for engine callbacks. A stalled decoder can keep
   selection disabled; context loss during a pending load needs a stale-result
   guard before this becomes production UI. A timeout alone would not stop
   synchronous decoding or prove that its allocations were released.
3. **Completed benchmark records retain their original context.** Selecting a
   different scene does not erase an already completed result. Its exported
   asset snapshot remains the original one; inspect that identity rather than
   treating old displayed FPS as the new scene's measurement.

The revised `IPHONE-TESTFLIGHT-CHECKLIST.md` explicitly marks the build-17 field
failure and the unshipped fix. No iOS archive, installation, TestFlight upload,
App Store action, reconstruction service deployment or real GPU run occurred.
No complete-product readiness claim is made. The next physical gate is still
the owner's fresh-room capture with an authorized updated build.
