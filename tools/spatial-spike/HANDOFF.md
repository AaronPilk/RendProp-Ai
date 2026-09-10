# Spatial Phase A — implemented tooling, physical proof still pending

Date: 2026-09-10. Branch: `spike/spatial-phase-a-20260910`.
Worktree: `/Users/pilksclaes/Rendprop AI/spatial-phase-a`.

**Decision: local tooling verified; Phase A is NOT accepted yet. Do not start
Phase B.** No real room has been captured, no CUDA training has run, and no
physical-phone browser performance has been measured. There is no evidence yet
for reconstruction quality, cents-per-room economics, or an advantage over a
competing product. The owner's instruction explicitly requires that experiment
before building the product.

## Scope and integration

Four agents worked on capture, training preparation, viewer/interop, and overall
verification. Everything added is under `tools/spatial-spike/`. No shipping app,
service, database, billing, production route, or public tour was changed.

Baseline verification happened at `4e28bb548304c0c7feadd21700724c2341141d59`.
During the work, upstream acquired two brand-only commits. They were fetched and
fast-forward integrated through `2c5903fff1436a7253cdcba2d211db0913c89896`.
`git diff --exit-code 4e28bb5 -- apps services` returned 0 afterward. The standing
brief and runtime sources did not change in that integration.

No deployment, App Store Connect action, GPU rental, provider spend, account
deletion, customer-media read/upload, or disabled-route enabling occurred.
Dependencies and public upstream source were downloaded for local verification;
that is not a GPU deployment. Generated media is explicitly synthetic and kept
outside version control. The existing shared checkout was not repurposed.

## What the code now does

### Standalone iPhone capture

See [capture instructions](capture-ios/README.md) and
`capture-ios/Sources/{App,CaptureModel,CaptureRecorder,RasterWriter}.swift`.

- Separate disposable app and bundle ID, without Rendprop credentials or network
  calls. It requires a real ARKit-capable iPhone; an unsigned build does not mean
  it was installed or can be installed without local development signing.
- Saves native camera JPEGs with explicit EXIF orientation 1, exact intrinsics,
  camera-to-world transform, monotonic timestamp, tracking state, and estimated
  feature points from the same ARFrame. UInt64 feature IDs remain decimal strings.
- One in-flight image write, normal-tracking admission, half-second cadence,
  one coordinate epoch, manifest committed after paired files. Interruptions and
  storage/limit failures preserve diagnostics and do not become successful input.
- Caps: 400 frames, 600 seconds, 50,000 feature points per frame. Stop normally
  before a cap; a limit-reached capture cannot be exported as complete.
- No RoomPlan integration, resuming, multi-room merge, redaction or public share.

### Pose-preserving adapter and bounded training runner

See [training instructions and exact provisional GPU recipe](training/README.md),
`training/prepare_capture.py`, and `training/run_training.py`.

- Checks actual JPEG bytes, calibration, rigid poses, normal tracking, one session,
  finite numeric values, unique paths/timestamps, contained paths, useful camera
  translation, and visible seed points. Existing output is refused.
- Converts ARKit camera axes to the trainer convention without changing the
  metre-scale world. Writes the COLMAP binary **format** only. No COLMAP/SfM
  executable, inferred pose, fabricated feature track, or measured reprojection
  error is introduced.
- ARKit sparse feature points initialize the Gaussians. They are estimated
  tracking features, not LiDAR or a dense measured surface. Poses alone were an
  insufficient specification of the selected trainer's initialization.
- Pins gsplat v1.5.3 source at `937e29912570c372bed6747a5c9bf85fed877bae`
  and its binary reader at `cc7ea4b7301720ac29287dbe450952511b32125e`.
  Real pinned reader and CLI-field compatibility were checked on CPU.
- Linux/CUDA runner validates source and input hashes, disables pose/world
  optimization and extra viewer/video generation, limits Gaussian count with
  MCMC `cap_max`, and records actual artifacts/hardware/time/dependencies.
- Defaults: 900 seconds, 3,000 iterations, 500,000 Gaussians. Absolute limits:
  1,800 seconds, 7,000 iterations, 500,000 Gaussians. Timeouts and catchable
  interruptions terminate the owned process group, including a tested child
  that ignores SIGTERM after its parent exits.
- Process limits do not terminate a rented host or guarantee a monetary cap.
  A separately enforced host/job TTL, shutdown plan, provider approval and budget
  are mandatory before any paid run. A SIGKILLed supervisor cannot clean up itself.
- The CUDA dependency environment is **provisional, not reproduced**. Upstream
  transitive requirements still need resolution and recording on the approved
  host. No CUDA build, convergence or room quality is claimed.

### Private browser viewer and conversion

See [viewer instructions](viewer/README.md), `viewer/viewer.mjs`,
`viewer/benchmark.mjs`, and `viewer/server.mjs`.

- PlayCanvas 2.22.1 and SplatTransform 3.4.2 are lockfile-pinned. SOG bytes chosen
  through the browser's file picker stay in that browser; no upload endpoint.
- Default loopback-only server serves allowlisted local assets, not the repo or
  room files. The synthetic route is explicit opt-in. No public hosting/tunnel.
- One scene, free-camera movement, resolution selection, invalid-file refusal,
  and JSON measurements with hardware/operator/context information.
- Five-second warmup followed by a thirty-second sample counts nonempty onscreen
  WebGL draw submissions. Empty RAF callbacks do not count. Reset, background,
  focus loss, resize, context loss and stalled drawing invalidate active runs.
- This is **draw-submission throughput**, not measured GPU completion/display
  presentation FPS. The phone checkbox is operator attestation, not hardware
  detection. Desktop viewport emulation cannot satisfy the phone requirement.
- PlayCanvas is a provisional implementation choice, not a measured winner over
  Spark. Public-viewer hardening and arbitrary untrusted-file resource limits
  remain outside this private spike.

## Verification actually executed

Commands below ran in this worktree unless stated otherwise. Paths under `/tmp`
are retained local evidence, not committed or permanent CI artifacts.

| Check | Command / result | Local evidence |
| --- | --- | --- |
| Clean server baseline | In `services/supabase/functions`: `deno test --allow-net --allow-read --no-check ai-copy/`; exit 0, **111 passed, 0 failed, no ignored** | `/tmp/rendprop-spatial-baseline-deno-20260910.log` |
| Permission negative control | Same command without `--allow-read`; exit 1, `NotCapable`, 78 passed / 1 failed | `/tmp/rendprop-spatial-negative-read-permission-20260910.log` |
| Clean shipping iOS baseline | `xcodegen generate`; `xcodebuild build-for-testing -project Rendprop.xcodeproj -scheme Rendprop -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E'`; exit 0, `TEST BUILD SUCCEEDED` | `/tmp/rendprop-spatial-baseline-ios-20260910.log` |
| Full local spike gate | `SPATIAL_PYTHON=/tmp/spatial-training-verify.rUYL0A/venv/bin/python bash tools/spatial-spike/verify-local.sh`; exit 0 | `/tmp/rendprop-spatial-verified-handoff.log` |
| Actual upstream compatibility | In `training`: `/tmp/spatial-training-verify.rUYL0A/venv/bin/python verify_upstream.py`; exit 0, `status: passed`, `gpu_training_performed: false` | `/tmp/rendprop-spatial-upstream-verification.json` (includes upstream reader warning before JSON) |
| Viewer dependency audit | In `viewer`: `npm audit --omit=dev --json`; exit 0, reported **0 vulnerabilities** at check time | `/tmp/rendprop-spatial-viewer-npm-audit.json` |
| Actual desktop browser | Pinned `npx --yes agent-browser@0.37.1 --session rendprop-spatial-phase-a` against the loopback viewer; loaded/rendered synthetic SOG, exercised movement and export, rejected invalid input | `/tmp/rendprop-spatial-viewer-synthetic.png`; `/tmp/rendprop-spatial-desktop-synthetic-benchmark.json` |

The full gate includes **24 Python tests, 7 viewer tests, 36 Swift assertions,
an unsigned standalone iPhone build with built-bundle checks, and the actual
Swift-to-Python serialization test**. No tests were skipped. Intentional negative
controls print failure messages/stack traces in that passing gate: the wrapper
requires their nonzero status. They are not swallowed unexpected failures.

The interop test compiles the actual Swift model and JPEG writer, generates
20 synthetic JPEGs and sidecars, and passes them to the actual Python adapter.
An independent contract check reads the binary export and verifies 120 seed
points, calibration/pose conversion, unchanged world coordinates, byte-identical
JPEGs, and hashes. It also checks the original Swift JSON's exact high UInt64
string IDs; binary point IDs are deliberately renumbered 1–120, not retained
ARKit IDs. A deliberately transposed matrix is rejected before the valid
case; existing output is refused without mutation. Final root-run artifacts:
`/tmp/rendprop-spatial-interop.0NouRF`.

Latest unsigned harness build:
`/tmp/spatial-capture-verify.mn5rGh/DerivedData/Build/Products/Debug-iphoneos/SpatialSpikeCapture.app`.
This is not a signed device installation or a room capture.

Additional negatives exercised: nonexistent Python interpreter makes the top-level
gate exit 1; malformed/nonfinite metadata and escaped paths fail; modified dataset
hashes block training; child failure/timeout/interruption fail; empty rendering
cannot yield FPS; resetting a live browser measurement makes it invalid; malformed
SOG is rejected with measurement disabled. Actual browser diagnostics were also
checked to return a defensive copy rather than mutable internal state.

The synthetic browser sample contained **2,048 Gaussians, 22,717 SOG bytes** and
recorded approximately **60.00 submitted frames/second over 30.0144 seconds at
1280×633** in desktop headless Chrome. It was a static synthetic sphere; movement
was checked separately. `synthetic: true` and
`physicalPhoneOperatorConfirmed: false` are in the exported JSON. These numbers
must not be quoted as real-room size, moving-room performance, or iPhone FPS.

The Deno command used `--no-check`; it is not a TypeScript typecheck. The shipping
iOS command built test targets, not a test execution/reviewer walk/archive. Existing
RenderEngine Sendable warnings remain; this work does not supply release approval.
Browser-verification guidance prompted an actual rendered-scene check and failure
tests beyond counter unit tests; neither test layer substitutes for physical use.

## Required next run — owner involvement needed

1. Name the physical iPhone and an owner-approved private room. Build/sign only
   the standalone capture harness locally; walk the room and export its complete
   capture directory. Remove/cover sensitive items first: no privacy blur exists.
2. Run the adapter locally before transferring anything. Inspect its counts and
   validation output. Insufficient points/coverage or bad geometry are findings,
   not permission to invent data or quietly invoke SfM.
3. Owner approves the GPU destination, any new account/provider, dollar ceiling,
   and shutdown/TTL mechanism. Transfer only this authorized capture to it.
4. Verify the provisional CUDA environment on that host, then run the bounded
   wrapper. Preserve the command, resolved packages, logs, run JSON, PLY hash,
   actual GPU/VRAM, elapsed minutes and actual charge. Review held-out renders.
5. Convert the real PLY to SOG using the pinned CLI. Record size/hash/conversion
   time. Open the correct room in a physical phone browser and navigate through
   it while recording the sample. Record device/OS/browser/resolution, visual
   defects, invalid runs, navigation evidence and the measurement limitation.
6. Report to the owner and **stop for Phase A review**. If fixed ARKit poses do
   not produce a usable room, say so. No Phase B–E work is authorized by a green
   synthetic test suite.

Real frames, training minutes, GPU, actual cost, room PLY/SOG size, physical phone
performance and visual acceptability are all still **unmeasured**. Reconstruction
service, queues, plan controls, privacy review/region redaction/room exclusion,
product navigation, and flythrough chapter binding remain intentionally unbuilt.
