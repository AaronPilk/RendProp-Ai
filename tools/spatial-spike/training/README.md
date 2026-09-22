# Phase A: local ARKit capture → pinned gsplat trainer

This prepares one manually captured room for a future, manually operated Linux
NVIDIA GPU. It does **not** provision a GPU, upload media, contact an AI provider,
run a production endpoint, or implement a reconstruction service. Preparation
and its tests work on a Mac; the chosen trainer requires CUDA. A passing adapter
test does not prove that an iPhone room has reconstructed successfully.

## What is implemented and verified

`prepare_capture.py` checks the standalone capture harness's `manifest.json` and
every sidecar/JPEG, then writes `images/` and the three COLMAP **binary format**
files under `sparse/0/`. COLMAP is only an interchange format here; no COLMAP
executable, SfM, triangulation, bundle adjustment, or camera estimation runs.
The binary geometry writer uses the Python standard library. Pillow is the only
adapter dependency, used to decode the actual JPEG bytes and sample seed color.

`verify_upstream.py` separately loads a synthetic export through the real pinned
`rmbrualla/pycolmap` reader and parses the run command using the real gsplat
dataclass fields and Tyro. It downloads only three public source files into
memory and does not load CUDA or send any capture data. This proves the file
format and CLI interface, **not trainer execution or reconstruction quality**.

Verified locally with Python 3.12.14, Pillow 12.1.1, NumPy 1.26.4 and Tyro 0.9.35.
Unit tests use synthetic JPEGs, camera trajectories and points. They assert
axis direction using four differently colored image quadrants, reproject a
point from a binary quaternion with asymmetric rotation/translation, read every
binary record through EOF, and deliberately make validation and CLI processes
fail. No test is allowed to skip itself because an import is missing.

## Why points are captured in addition to poses

The pinned gsplat `sfm` initialization consumes both `parser.points` and RGB
colors, and computes initial sizes from four nearest neighbors. Its `random`
initialization exists, but is not the selected Phase A path. Camera locations
and intrinsics alone do not provide a surface point cloud.

We seed from `ARFrame.rawFeaturePoints`, with each UInt64 identifier serialized
as a decimal **string**. These are ARKit's estimated tracking features, not
LiDAR measurements and not a dense reconstruction. Apple does not guarantee
their number or stability, even between successive frames. This is a practical
initialization experiment; textureless walls, glass, mirrors and moving objects
may give too few useful seeds. The adapter refuses fewer than 100 distinct,
visible seeds and never silently substitutes invented geometry. If real capture
quality fails, the next measured experiment is confidence-filtered scene-depth
unprojection on a supported LiDAR device, or matched-image triangulation with
fixed poses. Neither is implemented or claimed here.

For each point ID, the latest estimate that projects inside its own frame is
paired with color sampled from that same JPEG. Coincident locations are merged
at 1 μm rounding precision to avoid degenerate nearest-neighbor scales. Counts
before and after this reduction are reported. These projected samples are not
measured feature correspondences: `images.bin` has zero 2D observations,
`points3D.bin` has zero tracks, and its required error field is an unused zero
placeholder. **No reprojection accuracy has been measured.** The trainer's depth
loss stays disabled because these files contain no measured tracks.

## Pose and image contract

The manifest format is `rendprop-arkit-capture`, schema version 1. Only
`status: complete`, `units: metres` and `world_alignment: gravity` are accepted; `recording`, `failed`, `interrupted` and
`limit_reached` fail. There must be 20–400 frames from exactly one session UUID,
strictly increasing timestamps, normal tracking, a constant JPEG raster size,
and at least a 5 cm camera translation radius. Thresholds are input sanity
checks, not a guarantee of sufficient room coverage or photometric accuracy.
The manifest's `feature_point_observations` must equal the sidecar point count;
more than 50,000 points in one frame fails without truncation.

Each frame sidecar contains `camera_to_world` (nested 4×4, row-major),
`intrinsics` (nested 3×3, row-major), `image_resolution: {width,height}`,
`timestamp`, `tracking_state: {state: normal, reason: null}`, `image` relative to
the capture root, and `raw_feature_points: [{id,position:[x,y,z]}]`.

ARKit camera axes are right/up/back; COLMAP and the pinned gsplat parser use
right/down/forward. With column vectors:

```text
D = diag(1, -1, -1, 1)
T_cv_camera_to_world = T_arkit_camera_to_world × D
T_cv_world_to_camera = inverse(T_cv_camera_to_world)
```

The world stays ARKit's metre-scale, right-handed, Y-up world. Do **not** flip
world point coordinates or transpose the row-major JSON. `images.bin` stores
world-to-camera Hamilton quaternions in `[qw,qx,qy,qz]` order and translation
`t = -R × camera_center`. The training command explicitly disables both world
normalization and pose optimization, retaining this relationship for the viewer.
The exported PLY must use the same world axes; any viewer camera convention
conversion belongs at its boundary.

JPEGs are the native `capturedImage` raster, with EXIF orientation 1, and no
rotation, crop, resize or display transform. Intrinsics are copied verbatim from
`ARCamera`, including its pixel-origin convention; no half-pixel shift is added.
The adapter checks decoded JPEG dimensions and EXIF and preserves the original
bytes. A separate PINHOLE camera per frame preserves the actual per-frame
intrinsics. An absent EXIF orientation tag is refused, as is a tag other than 1.
If capture ever resizes, crops or rotates the raster, it must also
transform K consistently; this adapter currently rejects that capture contract.
`--data-factor 1` prevents upstream resampling.

PINHOLE is an explicit approximation for this spike. K alone cannot establish
that the JPEG has zero residual lens distortion; neither a normal tracking state
nor successful file parsing proves the poses are photometrically accurate.
Avoid rapid movement/blur, keep the scene static, and inspect real held-out
renders for double edges and misalignment before declaring success. ARKit drift,
rolling shutter and residual distortion may defeat this fixed-pose run. The
pinned parser can undistort calibrated OPENCV models, but the harness does not
export distortion coefficients, so this adapter must not invent them.

## Offline adapter use

Use Python 3.10+ for preparation (Python 3.11/3.12 for the GPU environment).
Run these from this `training` directory; `/local/...` below are locations chosen
on your machine, not cloud destinations. Existing output is always refused.

```sh
python3 -m venv /local/spatial-adapter-venv
/local/spatial-adapter-venv/bin/python -m pip install -r requirements-adapter.txt
/local/spatial-adapter-venv/bin/python -m unittest discover -s . -v
/local/spatial-adapter-venv/bin/python prepare_capture.py /local/room-capture
/local/spatial-adapter-venv/bin/python prepare_capture.py /local/room-capture --output /local/room-dataset
```

An error exits 1. Validation is read-only; export writes only a new chosen output
directory. A partial export has no `adapter-report.json` completion marker.
The completed report records source JPEG hashes, binary hashes, seed counts and
the trainer pin. The runner checks those hashes before any training.

The additional upstream compatibility check needs small CPU dependencies and
public GitHub source access (the unit suite itself is offline):

```sh
python -m pip install -r requirements-verify.txt
python verify_upstream.py
```

## Provisional GPU setup and bounded run — not yet executed

Selected upstream: **gsplat v1.5.3**, commit
`937e29912570c372bed6747a5c9bf85fed877bae` (Apache-2.0).
Its parser dependency is `rmbrualla/pycolmap` commit
`cc7ea4b7301720ac29287dbe450952511b32125e` (MIT), which only reads models. The
example also depends on fused-ssim (MIT). Preserve dependency license notices.
Do not substitute the original graphdeco research implementation's license.

The command below assumes an already authorized Linux NVIDIA CUDA host with a
compatible driver, CUDA 12.8 toolkit (`nvcc`) and C++ build tools. The pinned
trainer uses `cuda:<rank>` and its CUDA rasterizer; a Mac CPU/Metal test cannot
verify it. VRAM and run time remain measurements to collect, not promises about
8 GB fitting this capture or a five-minute run.

These are manual setup commands, **not an executed deployment**. Installing
PyTorch/CUDA packages is intentionally not part of any local test or run script.
PyTorch 2.7.1 / torchvision 0.22.1 / CUDA 12.8 is an upstream-documented wheel
combination; the full gsplat build on that host still needs verification.

```sh
git clone --branch v1.5.3 https://github.com/nerfstudio-project/gsplat.git /local/gsplat-phase-a
git -C /local/gsplat-phase-a checkout --detach 937e29912570c372bed6747a5c9bf85fed877bae
python3.12 -m venv /local/spatial-gpu-venv
/local/spatial-gpu-venv/bin/python -m pip install torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cu128
/local/spatial-gpu-venv/bin/python -m pip install -r /local/gsplat-phase-a/examples/requirements.txt numpy==1.26.4 Pillow==12.1.1 tyro==0.9.35 ninja
/local/spatial-gpu-venv/bin/python -m pip install --no-build-isolation -e /local/gsplat-phase-a
```

Upstream example requirements contain unpinned transitive packages. This is a
pinned **trainer source and interface**, not a fully reproducible CUDA image.
The first successful host build must record its resolved dependencies. The
example's LPIPS metric may download public pretrained weights when constructing
the runner; prepare that cache before an offline room run. Neither install nor
weight download requires customer media. No provider account is selected here.

The literal trainer command, parsed successfully by the pinned upstream Tyro
schema, is:

```sh
python /local/gsplat-phase-a/examples/simple_trainer.py mcmc \
  --data-dir /local/room-dataset --data-factor 1 --result-dir /local/room-result \
  --init-type sfm --no-normalize-world-space --no-pose-opt \
  --disable-viewer --disable-video --save-ply --packed \
  --max-steps 3000 --eval-steps 3000 --save-steps 3000 --ply-steps 3000 \
  --strategy.cap-max 500000
```

`sfm` is the upstream option name for consuming the supplied XYZ/RGB arrays; it
does not invoke SfM. MCMC is chosen because its `cap_max` actually bounds the
Gaussian count. DefaultStrategy has no equivalent cap. The command's fields
were tested; its convergence on the room has not been tested.

Use **the wrapper** for the real experiment so the process group is killed on a
wall-clock timeout, subprocess failure propagates, and results are recorded:

```sh
CUDA_VISIBLE_DEVICES=0 /local/spatial-gpu-venv/bin/python run_training.py \
  --gsplat-dir /local/gsplat-phase-a --dataset /local/room-dataset \
  --output /local/room-result --max-seconds 900 --max-steps 3000 --max-gaussians 500000
```

The wrapper refuses more than 1,800 seconds, 7,000 steps or 500,000 Gaussians,
more initial seeds than the cap, a changed dataset, an edited/different trainer,
a non-CUDA environment, or an existing output directory. These are local process
limits; they do **not** stop cloud billing for an allocated machine or constitute
Phase C's per-job financial controls.
SIGINT, SIGTERM, SIGHUP and Python exceptions also terminate the detached training
process group; injected-signal tests verify that behavior and restore the caller's
handlers. A killed supervisor (`SIGKILL`), lost host, or repeated interruption
during cleanup cannot be made safe by a Python watchdog. Before any paid run,
use an independently enforced provider/job TTL or host supervisor and an explicit
machine shutdown plan. No such provider control is configured by this spike.

Successful training must produce `ply/point_cloud_2999.ply`, final trainer stats,
and `run.json`. The latter records frames, GPU, elapsed minutes, PLY bytes,
PLY SHA-256, Gaussian count, total GPU VRAM, peak allocated VRAM and resolved
package versions. `phase_a_acceptance_complete` remains
false: conversion to SOG, visual reconstruction review and real-phone browser
FPS still have to be measured. Failure preserves partial output with status
`failed`, never a success claim. PLY conversion and viewer use are documented in
the sibling `viewer` directory.

## Primary sources checked for these choices

- [Pinned gsplat trainer Config, initialization, metrics and PLY export](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/examples/simple_trainer.py)
- [Pinned gsplat parser: K, pose inversion, normalization and distortion](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/examples/datasets/colmap.py)
- [MCMCStrategy and its cap_max](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/gsplat/strategy/mcmc.py)
- [Binary reader used by the trainer](https://github.com/rmbrualla/pycolmap/blob/cc7ea4b7301720ac29287dbe450952511b32125e/pycolmap/scene_manager.py) — its text reader still contains Python-2 map handling and stops on blank lines, so the adapter emits binary.
- [COLMAP format: little-endian, world-to-camera, Hamilton quaternion and camera axes](https://colmap.github.io/format.html)
- [Apple ARCamera transform](https://developer.apple.com/documentation/arkit/arcamera/transform), [intrinsics](https://developer.apple.com/documentation/arkit/arcamera/intrinsics), and [rawFeaturePoints limitations](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints)
- [Apple scene-depth point-cloud sample](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth)
- [gsplat CUDA installation](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/README.md), [Apache license](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/LICENSE), [parser MIT license](https://github.com/rmbrualla/pycolmap/blob/cc7ea4b7301720ac29287dbe450952511b32125e/LICENSE.txt), [fused-ssim MIT license](https://github.com/rahul-goel/fused-ssim/blob/328dc9836f513d00c4b5bc38fe30478b4435cbb5/LICENSE)
- [PyTorch previous-version installation matrix](https://pytorch.org/get-started/previous-versions/)
