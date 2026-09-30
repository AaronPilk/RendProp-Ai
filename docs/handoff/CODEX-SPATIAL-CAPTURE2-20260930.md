# Second phone capture: reconstruction remains NO-GO

September 30, 2026. This report concerns the owner's new “Spacial test 2”
capture. It supersedes any assumption that adding the motion-blur guard alone
would make the current reconstruction recipe shippable.

The new capture is intact and contains substantially sharper photographs, but
the resulting room still smears floors, furniture and kitchen details and
duplicates some edges. All 46 held-out comparisons were reviewed independently.
The same problems are visible in the original trainer renders and the private
browser viewer. There is **no winning configuration and no production quality
acceptance**. No production flag, database, worker or App Store Connect setting
was changed by this experiment.

## Scope and reproducibility

- Isolated branch: `experiment/spatial-capture2-20260930`; controller source
  `11ebf0a3f60fa74521ae656c2f5116a6b02e2e2a`, based on the original benchmark
  `6443b4cb0191d6be557decd2a6747ad342991c1a`. It deliberately preserves that
  trainer recipe rather than bringing unrelated application changes into the
  experiment. Do not merge this old-base branch wholesale into current main.
- Current capture adapter was inspected at
  `aedf861a6e4a35d2b552390b7e9ffc029fc39454`. Its camera/image/point binaries for
  this capture are byte-identical to the old adapter followed by its historical
  training-only seed extraction. No input image was removed or changed.
- 361 JPEGs, 361 metadata files and one manifest were frozen and hash-verified.
  All 723 original files match the local frozen copy. JPEGs are 1920 × 1440 in
  their sensor-native orientation.
- Fixed new split: **315 training images / 46 evaluation images**, holding out
  original zero-based indices 0, 8, …, 360. Initialization uses 9,551
  training-only seed points; training metadata contains 39,687 raw point
  observations. These are not independently measured 2D feature tracks.
- This is a **new evaluation cohort**, not a paired numerical ablation against
  the old capture's 50 evaluation images. Retain both cohorts and all losers.

## New run r01

The only experimental input change from s01 is the new capture and its supplied
poses/seeds. Recipe: gsplat 1.5.3 at
`937e29912570c372bed6747a5c9bf85fed877bae`, original pinned Python dependencies,
pose optimization on, 30,000 steps, 500,000 Gaussian cap, world normalization
off, default noise learning rate 500,000, seed 42, data factor 1 and evaluation
every eighth image. Training timeout is 4,200 seconds.

| Measurement | r01 |
| --- | ---: |
| PSNR | 21.206584930419922 |
| SSIM | 0.7564787864685059 |
| LPIPS | 0.481100469827652 |
| Training-wrapper duration | 2,270.827817366 seconds |
| Final Gaussians | 500,000 |
| PLY size | 118,001,477 bytes |
| Local SOG size | 8,707,587 bytes |
| Quality decision | **NO-GO** |

All 52 downloaded artifacts match their recorded hashes. All 46 left-side
reference panels match the frozen JPEG decodes exactly. Trainer/dependency
identity, split and clean termination were independently verified. Aggregate
metrics are from the hash-verified trainer evaluation; SSIM and LPIPS were not
independently recomputed by the local artifact checker.

The private SOG was produced locally with the existing SplatTransform 3.4.2
configuration, without filtering or pruning. Conversion took 11.82 seconds and
made no cloud compute call. The upstream converter is not byte-deterministic;
fixed settings/version do not imply reproducible output bytes. Navigation bounds
come from this capture. They are estimates, not measured collision geometry.
Desktop look, brief joystick movement, reset and top-down controls were checked.
This is not a phone performance or camera test.

## Previous capture: preserve every negative result

These seven runs used the prior 400-image capture. The g01 SfM attempt has its
own pose/evaluation caveats in the original evidence. No row was accepted.

| Run | Main change | PSNR | SSIM | LPIPS | Actual USD |
| --- | --- | ---: | ---: | ---: | ---: |
| f01 | 3,000 steps, pose optimization off | 18.785109 | 0.795699 | 0.573603 | 0.61029876 |
| p01 | Pose optimization on | 18.728519 | 0.795884 | 0.574817 | 0.62267687 |
| s01 | 30,000 steps | 20.845554 | 0.805977 | 0.501243 | 2.19026254 |
| g01 | Hybrid SfM attempt | 19.252468 | 0.775793 | 0.480868 | 2.30056359 |
| c01 | 1,000,000 Gaussian cap | 16.535042 | 0.779264 | 0.595373 | 2.38583029 |
| n01 | Noise learning rate 139,873 | 21.231655 | 0.807715 | 0.482407 | 2.39945690 |
| z01 | World normalization on | 20.880564 | 0.806243 | 0.493169 | 2.50371776 |

## Budget and cleanup

Before r01, provider-reconciled cumulative spend was **$19.98118436**, including
earlier experiments. The $25 ceiling was not raised. The one r01 allocation
reserved its full **$4.9110336000 maximum**, bringing actual plus reserved to
$24.89221796. **A reservation is not the actual charge.**

r01 used one L4, four CPU cores and 32 GiB with matching requests and hard
limits, a 7,200-second sandbox TTL, and no automatic rental retry, persistent
volume or exposed port. Outbound access was denied after dependency setup and
before uploading the room data. The temporary remote room directory was deleted
successfully and the sandbox was terminated at **20:04:34.926123 UTC**, with exit
code 137. An independent provider read confirmed termination and zero active
sandboxes/tasks.

Final r01 billing is pending the provider's closed-hour readback at or after
**21:02 UTC**. Until the final readback exists, the full reservation stays in the
ledger. No further paid experiment is authorized by this report. The current
sandbox compute ceiling is approximately $2.4555/hour; the older $1.24/hour
estimate used a different compute product's rates and is not the safe bound for
this allocation.

## What the new capture establishes

The rotational-motion estimate has median 2.55 px and maximum 4.00 px, with no
missing motion estimates and no accepted frame above 5 px. This passes the new
guard. It does not measure all defocus or translation-induced blur. The first
two images are visibly soft; both remain in the frozen experiment.

The camera traveled approximately 25.79 m across a 2.59 × 6.79 m footprint. This
was not a stationary spin. Most optical-axis directions were somewhat downward;
the lens still includes upper walls in many images. Two large turns occurred
between saved images, so a slow revisit cue could help fill gaps. Those facts
do not establish that coverage caused the failed output.

The strongest conclusion is that sharper accepted photos and the current blur
guard are **insufficient with this recipe**. Do not tell the owner to repeat the
scan without a more specific diagnosis. The earlier claim that blur was the
sole cause is not established by this test.

## Independent image-only SfM diagnosis

Free local CPU SfM registered **all 361 images** in one component, with 222,971
points and 1,412,952 observations. It used fixed per-image intrinsics and no
ARKit pose priors or initialized reconstruction. One similarity transform aligned
its camera centers and points into the ARKit world. On the exact same observed
image features, the reprojection comparison was:

| Camera poses | Mean error, px | Median, px | 90th percentile, px |
| --- | ---: | ---: | ---: |
| Image-derived SfM | 1.048930 | 0.906011 | 2.016331 |
| Original ARKit | 41.420906 | 32.048231 | 83.542599 |

There were no nonfinite or behind-camera exclusions. An independent scalar
pycolmap implementation checked every observation and agreed within 4.18e-11 px.
Every image's ARKit median error exceeded 5 px; 354 exceeded 10 px. Average
camera-center disagreement of 3.05 cm and average rotation disagreement of
1.72 degrees are therefore not evidence of pixel-accurate alignment.

SfM fitted these observations and used all images for this geometry diagnosis.
It is **not ground truth or held-out quality evidence**, and this model must not
initialize a held-out training experiment. Nevertheless, the size and consistency
of the discrepancy support a controlled, coherent SfM pipeline trial. The older
g01 hybrid/evaluation comparison does not rule that path out. Blur alone is not
an adequate explanation of the new failure.

The bounded CPU diagnostic took approximately 13.6 minutes total and peaked
around 3.50 GB RSS. Local API/setup/reporting failures were retained; no cloud
allocation was made. A recorded snapshot-pruning operation removed only redundant
intermediate snapshots to stay inside the 2 GiB output bound. Final models,
failure evidence, inputs and cache remain available.

A separate **315-training-image-only** SfM candidate failed admission before any
paid run. One bounded local mapper invocation produced components of 279, 53 and
3 registered images. The largest misses 36 training views from the late
320–360 image-ID range. No components were merged, no view was dropped or filled
with an ARKit fallback, and no held-out localization or candidate dataset export
ran. Mapping took 297.69 seconds; total preparation took 310.69 seconds with
1.35 GiB peak RSS. This failure is preserved under `sfm-training-candidate/`.

The proposed comparison protocol keeps 46 evaluation images out of training
geometry, colors, bundle adjustment and seeds. All 315 training views and all 46
localized evaluation views must pass admission. Original ARKit evaluation stays
primary. A separately labeled localized-view comparison must rerender both r01
and a new model from the same secondary camera poses. A PLY round-trip validation
first compares all 46 original baseline views against official metrics and saved
render images, retaining the three worst comparison canvases. This is prepared
instrumentation, **not an executed r02 experiment or quality pass**.

A separate offline replay of the exact cached trainer loader checked all 361
images: each frame retains its own calibration, all rasters remain 1920 × 1440,
and the split, seeds and colors match. Independent synthetic projection checks
differ by at most 0.001246 px after float/quaternion conversion. No data-contract
error capable of explaining the smearing was found in these checks. This does
not prove the camera calibration or measured poses are physically accurate.

Training adjusts only training-image poses; held-out evaluation uses the
original ARKit poses. Pose adjustments were not retained among the downloaded
artifacts, so their magnitude cannot be recovered from this run. A future run
should retain the optimized camera state and training-view diagnostics as well
as every unchanged held-out evaluation image. That instrumentation does not
make this result a pass.

Native capture source inspection also found that image, pose, calibration and
timestamp are captured from the same AR frame before asynchronous disk writing.
The writer does not fetch a later current frame. This source review is not a
physical-device synchronization test.

There are no accepted `spatial_runtime` values to deploy. Preserve the existing
quality gate and do not activate global generation just to expose a finished
screen. The current ARKit-based recipe is not viable at shipping quality on this
capture. Whether a coherent SfM pipeline supplies sufficient improvement remains
unresolved until the controlled reconstruction and visual comparison finish.

## Capture UX and Blender

For this reconstruction approach, guide a slow walk through overlapping
viewpoints, with gentle turns and revisits from another position. Clockwise or
counterclockwise is fine. A turn from one fixed optical position is primarily a
panorama capture and lacks the translation needed for robust multiview depth.
This matches [COLMAP's capture guidance](https://colmap.github.io/tutorial.html).
For novices, a guided “stand here, sweep slowly, move to the next spot” sequence
is a useful UX candidate, provided multiple overlapping viewpoints are captured;
it is not yet a validated capture protocol.

The existing app already has slow-turn and upper-corner instructions. Its
minimum-viewpoint rule accepts **translation OR rotation**, so a photo counter
can still advance during a stationary spin. Useful bounded improvements are:

1. An explicit walking instruction and a contextual “take a few steps” cue.
2. A brief camera-settling state before the first saved image, keeping Stop
   available and avoiding unsupported promises of focus lock.
3. A persistent “pause and slowly revisit that corner” cue after a substantial
   unsaved turn.
4. An upper-corner reminder when accepted views remain predominantly downward.

These are recommendations, not changes made in this experiment. Do not turn a
photo count or heading circle into a misleading room-completeness percentage.
Their camera and human-behavior effects require the owner's physical phone.

**Blender is not required** for the existing capture → reconstruction → viewer
path. It can be an optional later authoring/export tool. Adding it cannot repair
the current reconstruction by itself.

## Evidence retained privately

Raw photographs, metadata, geometry, source/render comparisons, provider
receipts and local diagnostic scripts remain outside Git under
`~/LocalSpatialExperiments/capture2-20260930/`. Key records:

- `admission-receipt.json`, `r01-plan.json`, `r01-launch-review.json`
- `independent/binary-equivalence.json`, `independent/integrity-coverage.json`
- `r01/provider-receipt.json`, `r01/download/result/run.json`
- `independent/r01-output-review/verification.json` and `visual-review.json`
- `independent/calibration-audit/findings.md` and
  `loader-calibration-verification.json`
- `independent/root-capture-contract-audit.json`
- `independent-sfm/results.json`, `reprojection-comparison.json` and
  `completion-audit.json`
- `independent/sfm-comparison-review.json`
- `sfm-training-candidate/plan.json` and `independent/sfm-candidate-review/`
- `r01/root-visual-review.json`, `r01/conversion-local-metal.json`
- `r01/billing-completion-inputs.json` and pending `billing-readback.json`

Plan SHA-256: `d9141d4d065afa42ffe6a927b5cf01990d63a3f6d3f51a3e69f6348e30b6152a`.
Provider receipt SHA-256: `72e711af9f04fc67652e5aca95e5a58fd0d572eb73e3558459bba878599cfcab`.
PLY SHA-256: `8c8e276b18f620728058dfd48e24b1dac7b32cfb05bafc900a19ce5247c0867c`.
SOG SHA-256: `3720a303b4f2f212b26c37645adf6a2b109c1ead2f706bf709e3b4d059850a9f`.
