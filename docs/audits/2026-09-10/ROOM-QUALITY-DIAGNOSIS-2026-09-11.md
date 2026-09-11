# Private room reconstruction: independent quality diagnosis

Date: 2026-09-11. Scope: downloaded owner experiment `modal-room-20260911-01`, not a new training run. No GPU was allocated, no media changed, and no image/model is included in this commit. This is a quality diagnosis, not permission to run another experiment or a claim that the product is ready.

## Bottom line

The room reconstructed, but the rendered detail is not acceptable for a photoreal property tour. Blur is already present in the trainer's native, uncompressed evaluation PNGs: neither the SOG conversion nor the browser can be its original cause. The strongest evidenced contributor is a severely underdeveloped model under the selected short training schedule. Capture motion, uncertain sparse geometry and unoptimized pose/appearance are credible additional contributors, but this run does not isolate their causal shares.

Do not tell the owner to rescan before running the free diagnostics and planning a controlled, explicitly budgeted comparison on the existing capture. Do not promise that increasing a cap alone fixes quality.

## Evidence identity and what was actually checked

- Source examined: `tools/spatial-spike/training/{run_training.py,prepare_capture.py,estimate_growth.py}` in the isolated deletion-integration worktree. `git diff 88066a3887852d3d6e4c021ac901783cea05d133 --` those first two files returned no differences. The private `provider-receipt.json` records that exact `source.commit`.
- Pinned upstream checkout `/tmp/rendprop-gsplat-setup-proof-20260910`: HEAD `937e29912570c372bed6747a5c9bf85fed877bae`, no tracked changes. Read its actual `examples/simple_trainer.py`, `examples/datasets/colmap.py`, and `gsplat/strategy/mcmc.py`.
- Private capture and dataset: `/Users/pilksclaes/LocalSpatialExperiments/capture-20260911.liWf0i/{capture,dataset}`.
- Result: `/Users/pilksclaes/LocalSpatialExperiments/modal-room-20260911-01/download/result`.
- Read `run.json`, both final stats files, all twenty evaluation PNG pairs and the training growth log. Visually inspected pairs 0003 and 0007 without modifying them.
- Recomputed image-pair PSNR from downloaded quantized PNG bytes; asserted every left half is pixel-for-pixel equal to its corresponding original JPEG decoded into RGB. All twenty assertions passed. This independently establishes which side is original and which is rendered; it does not rely on interpreting a screenshot.
- Ran the production `run_training.validate_dataset()` offline: all 153 JPEG hashes, all three binary model hashes and exact directory membership passed; asserted 9,226 seeds. No trainer process or CUDA import was invoked.
- Independently checked all 153 pose conversions against `inverse(T_arkit @ diag(1,-1,-1,1))`; all passed at `atol=1e-5`, maximum absolute coefficient discrepancy `2.940120140237923e-6` (the recorded rotations are finite-precision).
- Re-ran the existing CPU-only growth tests: `PYTHONDONTWRITEBYTECODE=1 /Users/pilksclaes/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s tools/spatial-spike/training -p 'test_estimate_growth.py' -v`: **11 tests passed, exit 0**. These include invalid inputs, exact boundaries, CLI failure exits and optimized-Python behavior. They do not test GPU quality.

Result hashes freshly computed:

| File under result | SHA-256 |
|---|---|
| `run.json` | `dc9119b15c3699f1d98cd4acfa244467ceaa084a0f71e65c00dbfd2678f570a0` |
| `stats/val_step2999.json` | `67c55426102cd3e980e95c2df8da7f37280a92ff99bf58aee2db0571f07b96fd` |
| `training.log` | `dd14a8601d0fed072c381325f07cff139e3efb6f761d13af18da67a8b4680f1e` |
| `ply/point_cloud_2999.ply` | `6b73cc24f56ea5581bb6571e81a65420b600814f6cd419ad79181bf90cefda21` |

## Measured baseline

| Quantity | Result |
|---|---:|
| Input frames / input raster | 153 / 1920 × 1440 |
| Captured interval | 76.006 seconds |
| Training images / loss-held-out images | 133 / 20 |
| Initial / final Gaussians | 9,226 / 29,733 |
| Configured ceiling | 500,000, **not a target** |
| Training steps | 3,000 |
| Wrapper elapsed time | 209.441 seconds |
| Device | NVIDIA L4 |
| Trainer-recorded peak allocated VRAM | 0.428317 GiB; not total process/device allocation |
| Native PLY size | 7,018,464 bytes |
| Trainer PSNR / SSIM / LPIPS | 19.659857 dB / 0.810971 / 0.556762 |
| Fresh PNG-quantized PSNR, mean / min / max | 19.646573 / 15.700096 / 21.751492 dB |
| Original / rendered grayscale Laplacian variance, median | 75.907001 / 0.648927 |
| Paired rendered/original Laplacian variance ratio, median | 0.007719 |

The sharpness statistic is a descriptive same-raster diagnostic, not a standardized perceptual score or an acceptance threshold. Its calculation used grayscale `0.299R + 0.587G + 0.114B` and the four-neighbor discrete Laplacian, excluding the image border. It supports the visual observation of major detail loss. It does not prove a particular cause. PNG quantization explains why independently recomputed PSNR is close to, not numerically identical to, the float-tensor trainer metric.

## Ranked diagnosis

### 1. Confirmed schedule/cap mismatch; likely a major quality limiter

`run_training.py:17–28` chooses MCMC, `--max-steps 3000`, and only the Gaussian **ceiling**. It does not set a faster refinement schedule. The existing planner documents the inherited schedule at `estimate_growth.py:17–19,36–38,58–70`.

Pinned upstream `gsplat/strategy/mcmc.py:49–54,122–138,175–177` refines after step 500, every 100 steps, increasing population by `int(1.05 * count)` up to the cap. There are only 24 growth events (steps 600 through 2900). Fresh log parsing asserted exactly 24 and the final count 29,733. Independent repeated-integer arithmetic gives exactly the observed result. Thus the cap was never approached: the output uses 5.95% of it. See the [pinned upstream MCMC implementation](https://github.com/nerfstudio-project/gsplat/blob/937e29912570c372bed6747a5c9bf85fed877bae/gsplat/strategy/mcmc.py#L122-L177).

This is not proof that 500k splats are required or sufficient. It is proof that “cap 500k” never trained a 500k model. With the same assumptions, 5,000 steps yields at most 78,872 and 7,000 yields 209,254; these are arithmetic, **not runtime/cost/quality forecasts**.

The MCMC preset is important: pinned `simple_trainer.py:1213–1220` uses `init_scale=0.1`, `init_opa=0.5`, and opacity/scale regularizers of `0.01`. Do not diagnose this run using the generic default initialization scale of 1.0. Fresh binary PLY analysis shows the learned largest-axis Gaussian sigma has median 5.45 cm, 95th percentile 23.45 cm, maximum 1.76 m; 23.77% exceed 10 cm. Median opacity is 0.0736. Those broad, often low-opacity primitives are consistent with smeared output, but neither sigma nor opacity alone measures image-space blur or proves its cause. This run's scene-scaled means learning rate is also not unscaled merely because world normalization is disabled (`simple_trainer.py:259,347`).

Related schedule facts: the training set has 133 images and batch size 1, so 3,000 updates give roughly 22.6 passes. Final-step training uses SH degree 2; the default interval is 1,000 and steps are zero-based. The means learning rate decays by 100× across the shortened run while densification still follows its original long-run schedule. New splats are added at step 2900 with fewer than 100 later updates before the final artifact. These follow pinned `simple_trainer.py:60–77,99–101,559–563,589–602,636`, not a timer failure. The run finished naturally before the 900-second cap.

**Next engineering work:** define and record a complete bounded training profile (refinement start/stop/frequency, SH ramp, learning-rate schedule, evaluation checkpoints, final refinement-free settling interval). Compare profiles on identical inputs with the same hold-out protocol. Do not just increase `strategy.cap_max`, turn off spending limits, or infer that a larger GPU is needed.

### 2. Confirmed sparse/unstable initialization; causal impact not isolated

The adapter deliberately uses ARKit raw feature estimates, not a dense surface or SfM bundle adjustment (`prepare_capture.py:209–241,287–298`). For each feature ID it retains the **latest visible estimate and same-frame projected RGB**, not the first sample (`:225–229`). No measured 2D correspondence track or reprojection residual is exported. `points3D.bin` has an unused error placeholder and zero track lengths, not measured zero error.

Fresh capture analysis found:

- 41,718 raw observations, 19,410 distinct raw IDs, 9,226 final visible seed IDs.
- Five saved frames had no raw feature point projected inside their image; median visible points per frame was 91, maximum 447.
- 4,628 of the final 9,226 seed IDs had only one in-frame observation.
- For raw IDs observed repeatedly, first-to-last estimated world-position change had median 2.63 cm, 95th percentile 19.63 cm, and maximum 3.26 m.
- World mapping status was `extending` for 88 frames, `mapped` for 59, `limited` for 4, and `notAvailable` for 2. All saved tracking states still satisfied the adapter's normal-tracking check.

These are properties of estimated feature records, **not measured camera-pose error**. Feature refinement, occlusion, ID behavior or world-map corrections can contribute. They justify inspecting geometry consistency and seed coverage before blaming the renderer. The adapter's 5 cm camera-radius minimum (`:244–247`) proves some translation, not room coverage or correct geometry.

**Next engineering work:** report per-frame feature visibility, repeated-ID estimate dispersion and multi-view image correspondence residuals. Reject no capture merely because a heuristic fires; surface actionable warnings. Evaluate confidence-filtered seeds or measured depth where available as a separately named profile. Preserve original poses and images as immutable source, and do not call sparse features a measured room surface.

### 3. Motion and photometric inconsistency are plausible contributors

Adjacent saved frames were approximately 0.5 s apart. Median camera rotation was 10.04 degrees per interval; maximum 56.92 degrees. Median exposure was 1/60 s. The rough angular-smear proxy `fx * adjacent_angle_radians / delta_time * exposure_duration` had median 6.70 pixels, 95th percentile 19.59 pixels, maximum 30.44 pixels.

That proxy assumes constant angular velocity over an interval much longer than the exposure. It is **not a measured blur kernel**, excludes translational smear/rolling shutter, and cannot prove how much a particular image blurred. The original held-out images retain far more detail than the renders, so input blur alone does not explain away the quality gap.

Exposure offsets ranged from -1.237 to +0.648 EV. Varying offset metadata is not itself a calibrated brightness-change measurement because viewpoint and metering change. The saved capture manifest has no `quality_policy` or rejected-blur/baseline counters. Current source's new quality selector therefore must not be claimed to have filtered these 153 frames.

**Next engineering work:** replay the actual quality selector on a derived diagnostic view of this immutable capture, record retained coverage as well as rejected frames, and measure matched-region brightness consistency. Calibrate thresholds on real rooms before shipping them. Do not solve blur with aggressive sharpening of the splat preview.

### 4. Pose/calibration accuracy remains unproved, but no gross conversion fault was found

`prepare_capture.py:87–109` validates rigid poses then computes the correct ARKit-to-CV inverse; the fresh independent numerical check passed every pose. `:199–208,274–280` preserves per-frame pinhole intrinsics and checks actual sensor-native JPEG dimensions/orientation. Focal length ranged approximately 1329.12–1348.97 pixels and was not flattened to one constant. The original and rendered image halves share the same rotation; sensor-native landscape pixels from a portrait-held phone are not evidence that someone should rotate only the JPEGs.

The wrapper explicitly disables pose optimization and world normalization (`run_training.py:24,139`). The adapter does not estimate distortion or verify measured 2D feature residuals. Consequently real-world calibration, time synchronization, tracking drift and lens-model adequacy remain unknown despite mathematically consistent serialization. No synthetic test can establish those from the schema alone.

**Next engineering work:** measure feature-track reprojection residuals and alignments first. If testing small regularized pose corrections, treat them as derived rendering parameters; preserve and disclose the original metric frame for RoomPlan anchors/measurements. Never casually change world scale, rotate images alone, or label optimized render geometry as measured LiDAR.

### 5. Held-out scores need a more precise claim

Pinned `examples/datasets/colmap.py:365–369` withholds every eighth image from training loss, yielding 20 validation views. But the adapter builds seed geometry and colors from **all 153 frames before that split** (`prepare_capture.py:176–241`). Fresh counting found 1,092 final seed RGB samples came from withheld frames; 470 final seeds had no visible observation in a loss-training frame.

Thus these are **loss-held-out view metrics**, not a completely image-disjoint reconstruction benchmark. This leakage would not explain the poor score by making the reconstruction unfairly worse; it limits what a good score could claim. A clean comparison must fix both the split and initialization provenance. It also needs novel-navigation views between captured poses, not just these twenty images.

## What this review rules out—and does not

- The trainer did not merely return an empty placeholder: a hash-bound 29,733-vertex PLY and twenty corresponding rasterized views exist.
- This run did not hit its 500k Gaussian cap, 900-second trainer deadline or recorded allocated-VRAM ceiling. A shortage of GPU capacity is not established as the cause.
- Blur predates browser/SOG delivery. A viewer change can introduce additional defects but cannot restore geometry/detail the native trained model lacks.
- There is no current measured-geometry accuracy result, collision-navigation proof, real-phone FPS result, room coverage acceptance or owner visual acceptance in this diagnosis.
- No paid rerun, parameter change, production route enablement or billing claim occurred in this review.

## Bounded next acceptance experiment, after explicit scheduling/budget approval

1. Keep this exact result as baseline; preserve source hashes and a stable evaluation split. Add a profile receipt recording every upstream-default setting that affects the result, not just the four caps.
2. Run CPU diagnostics first: capture-quality replay, track/reprojection consistency, seed coverage, dynamic/reflective regions and photometric consistency. Do not drop images or change calibration invisibly.
3. Compare one deliberate refinement/settling profile against baseline under the same input set, finite wall-clock/iteration/population limits and full provider lifecycle budget. Record intermediate quality so insufficient convergence and worsening geometry can be distinguished. Density is a controlled variable, not the acceptance criterion.
4. If that does not resolve the gap, investigate derived pose/appearance corrections or improved seed geometry in separate experiments. Changing all of them together makes the outcome hard to interpret.
5. Accept only after native held-out and novel-path render review, then SOG/native parity, then private iPhone navigation and actual FPS/memory testing. Keep public sharing disabled until the independent privacy-processing/review gates are satisfied.

The first app milestone remains: the owner opens their own reconstructed room on their phone and finds it useful. A successful training exit or a sharp unrelated demo does not substitute for that result.
