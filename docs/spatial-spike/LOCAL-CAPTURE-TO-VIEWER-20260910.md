# Local Phase A: exported capture to a navigable reconstruction

## Current outcome and missing stage

Capture success is not reconstruction success. The TestFlight capture screen
saves native JPEGs, calibrated camera poses and ARKit tracking-feature estimates.
It does not train Gaussian splats or open a room viewer. This note is a manual,
private Phase A experiment handoff, not Phase B–E product integration.

The owner-cleared export processed on 2026-09-10 passed the existing adapter:
256 decoded JPEG frames, 57,894 feature observations and 14,654 distinct visible
initialization seeds. A posed binary dataset was prepared; the existing trainer
dataset-hash gate passed. All 513 original manifest/sidecar/JPEG hashes matched
the assembled private copy and its provenance. No original was renamed, moved,
edited or deleted. No room pixels, poses, session IDs or source hashes are stored
in this repository note. Detailed evidence stays with the private local dataset.

There is **no trained room PLY/SOG yet**, no real-room visual review, and no
physical-phone rendering measurement. A standalone supplied sidecar had passed
structural checks earlier, but it was not enough: the complete manifest, all
sidecars and all referenced JPEGs were needed to reach this dataset-ready stage.

| Stage | Existing implementation | Current evidence / missing requirement |
| --- | --- | --- |
| Capture | `capture-ios/Sources`, integrated TestFlight entry | Owner-supplied complete export; no source changes in this work |
| Assemble and validate | `training/capture_handoff.py`, unchanged `prepare_capture.py` | Actual export accepted; private copy and dataset completed |
| Train posed images | `training/run_training.py`, pinned gsplat | **Not executed**; requires an authorized Linux/NVIDIA CUDA host |
| Convert trained PLY to SOG | pinned SplatTransform 3.4.2, `-g cpu` | Local synthetic conversion passed; no trained-room artifact exists |
| Navigate and measure on phone | `viewer/server.mjs`, local file selection | Existing private browser viewer; real-room/phone test still unperformed |

## What this change adds

`capture_handoff.py` adds transport checks and provenance around the **actual,
unchanged** adapter. It does not create a second pose validator, normalize raw
matrices, relax minimum seeds, manufacture feature tracks, estimate surfaces,
spawn a process, load CUDA or contact a service.

Independent review of the initial handoff commit found two real boundary defects:
assembly allowed a destination under the source manifest's parent, and dataset
files inherited a permissive caller umask. Four focused synthetic regressions
failed before the repair (exit 1). Assembly now refuses descendants of the entire
manifest parent, including resolved aliases; it must not add even a new `copy/`
entry to the original capture. Dataset creation uses a scoped restrictive umask
**before** the unchanged adapter opens any image/model/report: directories are
0700 and files 0600, including partial outputs. The previous umask is restored on
success and exceptions. This process-wide setting belongs to this single-threaded
CLI, not a concurrently embedded library. Tests observe modes at the first actual
JPEG open under umask 022 and inject interruption. The actual owner run used an
outside-source 0700 private parent and umask 077, so these defects did not expose
or alter its originals; the first version was nevertheless unsafe in general.

Its `assemble` command accepts only three explicit input paths: a manifest, a
frames directory and an images directory. Before creating output it requires
20–400 contiguous native pairs, matching sidecar session IDs, schema/convention
values, feature-observation totals and encoded-image byte totals. A folder named
`images 2` is mapped to `images` **only in a new copy**; original JSON/JPEG bytes
are not rewritten. Images have no independent session ID: agreement of session
metadata, filenames, dimensions and byte totals cannot prove that someone has
not deliberately substituted visually different same-sized media. The local
hash record starts at handoff, not at camera acquisition.

It refuses symbolic-link roots/directories/files, extra entries (including
`.DS_Store`), missing files, nested directories, aliases in manifest paths,
duplicate JSON keys and nonfinite JSON constants. No cleanup is automatic.
Native limits are copied from `NativeRasterWriter` / `CaptureRasterLimits`:
256 KiB manifest, 16 MiB sidecar, 64 MiB encoded JPEG, 8,192 pixels per axis,
16,777,216 pixels total and 50,000 feature observations per frame. An additional
conservative 2 GiB total handoff cap and 2 GiB free-disk reserve bound this local
workflow. These are admission limits, **not** a memory-safety proof for hostile
decoders or a promise that every admitted capture is useful.

After assembly, `inspect` calls `prepare_capture.load_capture` with its unchanged
defaults: normal tracking, increasing timestamps, exact JPEG/calibration pairing,
explicit EXIF orientation 1, rigid poses, at least 100 distinct visible seeds,
and at least 5 cm translation radius. Optional `--dataset` delegates to the
existing binary writer, additionally refuses seeds beyond the runner's cap, and
writes `capture-provenance.json` last. That report binds all raw file hashes to
the SHA-256 of `adapter-report.json`; the latter already binds images and binary
models. Reports contain no raw positions, but hashes and session identity are
still private metadata. Keep the report outside the source capture directory.

Before/after hashes detect ordinary concurrent source changes; this is not an
atomic filesystem snapshot, an authenticated capture signature or a defense
against hostile concurrent replacement of directory ancestors. Use a quiescent,
owner-cleared local export. A failed copy/preparation remains for diagnosis and
must not be treated as approved. The original adapter's completion report may
exist if a later provenance check fails: only a successful wrapper exit **and**
its `capture-provenance.json` indicate a completed handoff. The GPU wrapper
currently checks `adapter-report.json`, not this additional provenance document;
the operator must retain and compare the chain. Nothing sets real-room/phone
verification flags true.

`verify-local.sh --no-build` now runs portable Swift capture checks, Swift→JSON→
Python interop, all Python tests and all three viewer test files. It does not run
Xcode/app builds. Omitting the flag preserves the existing unsigned-build gate.
Unknown arguments fail with exit 1 before any tests/builds run.

## Owner input and safe local commands

In TestFlight: Settings → Spatial capture (TestFlight) → Saved captures → the
completed attempt → export the **whole capture folder**. Preserve `manifest.json`,
`frames/000001.json` onward and `images/000001.jpg` onward. A single sidecar,
screenshots, an MP4, or only the JPEGs is insufficient. No new capture is required
merely to rename a transferred `images 2` directory. Use a private Mac directory
outside Git and outside a synced/public folder; do not upload it to a provider.

Run from the repository root. `PY` below denotes an **already installed** Python
3.10+ interpreter with the pinned adapter Pillow dependency; this workflow does
not install anything. Every output directory must be new and its parent must
already exist. Quote paths containing spaces. Redirect full JSON to a private
report, never commit it.

```sh
"$PY" tools/spatial-spike/training/capture_handoff.py assemble \
  --manifest /private/input/manifest.json \
  --frames /private/input/frames \
  --images '/private/input/images 2' \
  --output /private/experiment/capture > /private/experiment/assembly-report.json

"$PY" tools/spatial-spike/training/capture_handoff.py inspect \
  /private/experiment/capture --dataset /private/experiment/dataset \
  > /private/experiment/dataset-report.json

# Read-only revalidation; omit --dataset to avoid preparing a second copy.
"$PY" tools/spatial-spike/training/capture_handoff.py inspect /private/experiment/capture

# Actual accepted seed count from this cleared export; arithmetic only.
"$PY" tools/spatial-spike/training/estimate_growth.py --initial-seeds 14654
SPATIAL_PYTHON="$PY" bash tools/spatial-spike/verify-local.sh --no-build
```

The default 3,000-step pinned MCMC schedule has 24 relevant growth events and an
ideal saved-artifact upper bound of 47,239 Gaussians for these 14,654 seeds. This
is an **upper bound under ideal growth, not a prediction of converged
quality/VRAM/cost**. A 500,000 cap is not a promise to reach 500,000. Do not change
capture guards or fabricate seeds to meet an imagined room count.

## Reconstruction requirement: cannot be replaced by a format conversion

Read-only hardware inspection found Darwin arm64 / Apple M4 Pro / Metal 4. The
selected trainer uses Linux/NVIDIA CUDA; this machine has no local CUDA route.
CPU checks, dataset preparation and CPU SOG conversion are possible here. These
do not substitute for photometric optimization of the captured images.

The source pin is gsplat `937e29912570c372bed6747a5c9bf85fed877bae` (v1.5.3);
the binary reader pin is `cc7ea4b7301720ac29287dbe450952511b32125e`. The existing
training README records upstream interface checks, dependencies and licenses.
No network/upstream download was rerun in this local handoff. A suitable host
still needs its installed CUDA toolchain, resolved dependencies and metric-weight
cache verified. No provider/account/machine has been selected or provisioned.

On an **already authorized, prepared** Linux CUDA host, the existing wrapper's
literal manual command remains:

```sh
CUDA_VISIBLE_DEVICES=0 /local/spatial-gpu-venv/bin/python \
  tools/spatial-spike/training/run_training.py \
  --gsplat-dir /local/gsplat-phase-a --dataset /local/room-dataset \
  --output /local/room-result --max-seconds 900 \
  --max-steps 3000 --max-gaussians 500000
```

This command is documented, **not run**. Before any off-machine copy or paid
allocation, obtain separate approval for the actual destination, media/privacy
terms, budget and independently enforced job TTL/shutdown. The Python timeout
does not stop machine billing or survive a killed supervisor. An existing owned
CUDA machine is a possible no-new-spend route only after its availability and
access are established; none was assumed here.

The run disables pose optimization and world normalization, preserves ARKit's
world axes, and expects final `ply/point_cloud_2999.ply`, stats and `run.json`.
Retain the trainer/source pin, dataset/provenance reports, PLY hash, Gaussian
count, GPU/VRAM, elapsed time and failures. A successful exit/file is not itself
adequate visual geometry: inspect held-out views and the room's full camera path.

## After a real trained artifact exists

Use the already pinned converter, never rename the initialization points as a
reconstructed PLY. From the prepared viewer dependency environment:

```sh
npm run convert -- -g cpu /private/room-result/ply/point_cloud_2999.ply /private/room.sog
node server.mjs --host 0.0.0.0
```

No server was started in this handoff. Current viewer dependencies are not
installed in every worktree; the existing local cache has PlayCanvas 2.22.1 and
SplatTransform 3.4.2 and can be reused after its path/version/integrity checks.
Do not respond to missing dependencies by downloading packages without approval.
The private LAN server serves only the viewer's fixed allowlist, not room files.
On a trusted Wi-Fi network, open `http://<Mac-LAN-address>:8093/` on the phone,
select the private SOG from Files, visually verify the correct room, drag to
look and hold movement buttons. Stop the server afterwards; do not use a public
tunnel. Default loopback-only binding cannot be reached from the phone.

This is free-camera spike navigation, not an in-app joystick, collision/floor
lock, hosted tour or publication flow. Admission is 64 MiB encoded SOG and
1–500,000 decoded splats, not demonstrated phone capacity. Real-artifact visual
review and the viewer's five-second warmup + thirty-second draw-submission
measurement must be performed on a physical phone. Retain the original device
label, artifact hash and renderer settings. `realRoomVerified` intentionally
remains false for a local filename; evidence is the retained manual chain, not
a filename or checkbox.

## Verification and limitations

Fresh portable gate after boundary repair: 63 Python tests (19 handoff), 21 viewer tests, 115 native
capture assertions, 7 adversarial cases, 8 JPEG-resource cases and 3,076 pose
precision assertions, no skipped tests. UI-summary controls and actual synthetic
Swift native-JPEG/JSON→Python binary interop also pass. Invalid inspector/gate
CLI invocations exit 1. Capture, JPEG, pose and empty-renderer intentional
failures are expected negative controls, not swallowed test failures. The gate
exits 0 only after all positive checks pass.

Local SplatTransform 3.4.2 converted the existing deterministic 2,048-splat
**SYNTHETIC-NOT-A-ROOM** fixture to a roughly 22 KiB SOG on CPU, exit 0. This
checks conversion only; the sphere was not made from the owner capture and is
not a demo of its reconstruction. No browser/physical-phone claim follows.

ARKit raw feature points are estimated tracking hints, not measured LiDAR or a
dense surface. Normal tracking, plausible matrices and matching intrinsics do
not measure pose drift, residual lens distortion, rolling shutter, blur or
geometric accuracy. PINHOLE is still an explicit approximation. Mirrors/glass,
textureless walls and moving objects can defeat reconstruction. These inputs
carry private room imagery and estimated positions; local validation is not
rights clearance, redaction or permission to publish. No spatial B–E work,
provider call, customer-media upload, Apple action or GPU job was performed.
