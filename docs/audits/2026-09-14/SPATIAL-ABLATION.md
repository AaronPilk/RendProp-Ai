# Spatial quality ablation — 2026-09-14

Owner scope: improve actual reconstruction quality, then deploy for a phone room
test. The handoff at `docs/handoff/CODEX-SPATIAL-20260914.md` in the shared parent
workspace was read in full before inspection. No App Store Connect operations.
The branch `feat/spatial-quality-ablation-20260914` includes Claude's fetched
`8d32f8557061105384c22f919a5e0a5287d73311` tip. New migrations must be 0055+.

## Fixed comparison

- Exact September 11 prepared dataset: 153 images, 9,226 ARKit feature seeds.
- Pinned gsplat `937e29912570c372bed6747a5c9bf85fed877bae`; MCMC; NVIDIA L4;
  PyTorch 2.7.1+cu128; CUDA 12.8; seed 42; native 1920×1440; data factor 1.
- Original image and all three binary model checksums are unchanged. No world
  normalization, appearance change, new initialization, or image filtering.
- Evaluation is every eighth sorted image: 000001, 000009, …, 000153.jpg;
  133 training images and 20 **loss-held-out** images. Initialization includes
  1,092 held-out seed colors (470 seeds observed only in held-out images), as
  already documented in the September 11 diagnosis. This is not an entirely
  image-disjoint benchmark. Preserve the same initialization for A/B.
- Full resolved Python dependency versions are constrained to the original run
  and checked for exact equality before transferring private media. Public
  setup, source pins, fixed image digest and resource limits stay unchanged.
- Record aggregate PSNR/SSIM over all 20 views from the trainer's metric JSON. Compare
  fixed render pairs 0007 (interior edges/patterns), 0014 (cabinetry/door trim),
  and 0000 (backlit thin geometry). Text legibility and continuous-navigation
  ghosting still need a real-room acceptance capture; these frames cannot prove
  them.

| Run | Pose optimization | Steps | Frames | PSNR dB | SSIM | LPIPS | Training wrapper seconds | Metered USD |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Sept 11 baseline | Off | 3,000 | 153 | 19.65985680 | 0.81097144 | 0.55676222 | 209.441 | 0.57381695 |
| A01 setup failure | Not reached | Not reached | 0 transferred | Unavailable | Unavailable | Unavailable | Not reached | 0.21150668 |
| A02 | On | 3,000 | 153 | 19.15759087 | 0.80769598 | 0.56202793 | 252.094 | 0.64541049 |
| B01 | On | 30,000 | 153 | 21.47684288 | 0.80856246 | 0.38908443 | 2,425.635 | 2.07333106 |
| D01, real SfM | On | 30,000 | 153 | 19.96911621 | 0.78203511 | 0.40026075 | 2,564.228 | 2.22848905 |

A02 is a valid negative result: PSNR changed by −0.502266 dB, SSIM by
−0.003275, and LPIPS by +0.005266. An independent comparison confirmed the
single changed trainer argument, identical resolved dependencies and all 157
dataset files, all 26 collected artifact hashes, and pixel-identical original
image halves in all 20 held-out render pairs. The output has 29,733 Gaussians.
The fixed interior and cabinetry views still have blurred detail and ghosted
edges; A02 does not pass quality acceptance. Remote directory removal and
terminal provider poll 137 are explicitly confirmed.

B01 started at 20:48:50 UTC from a clean detached execution checkout of
`af6f127`. It keeps A02's images, initialization, pose settings, dependencies,
500,000-Gaussian ceiling and evaluator. The only model-profile change is
30,000 steps; the wall-clock watchdog is 4,200 seconds. Step-dependent trainer
schedules retain the pinned implementation's defaults. No intermediate
checkpoint or hidden tuning change is introduced.

B's dependency verification passed before media transfer. Training started at
21:00:34 UTC and the completed provider was explicitly terminated at 21:41:24.
Its 157 input hashes, 164 distributions, permitted command differences, all 26
output hashes and all 20 original evaluation canvases passed independent
verification. The model reached 500,000 Gaussians and its PLY is 118,001,477
bytes. The trainer wrapper took 2,425.635 seconds; the trainer's separately
reported `ellipse_time` is 2,371.514 seconds. Directory removal succeeded and
the exact sandbox was terminal with exit 137 and no active app sandboxes.

B improves PSNR by 1.816986 dB and LPIPS by 0.167678 relative to baseline, but
SSIM decreases by 0.002409. Views 0007 and 0014 recover substantial interior
detail. View 0000 still has severe stretched or duplicated geometry around the
telescope, plant, mirror rim and window. This prevents acceptance despite the
better average PSNR. Conversion with the unchanged pinned CPU SOG converter
was measured locally; it is not proof of Modal conversion performance.
At 21:53:20 UTC it was still running after 632 seconds, exceeding the current
600-second production conversion allowance. No real SfM ran concurrently
during those first 632 seconds. Local D preprocessing started afterward, so
the remaining conversion elapsed time may include CPU contention. Preserve
the private timing observation rather than treating the full local elapsed
time as an isolated Modal benchmark.
The CPU converter reached its explicit 3,600-second timeout at 22:42:48 UTC;
its process was confirmed absent. The original receipt is preserved, with a
separate corrected receipt documenting later concurrency with local SfM,
synthetic work and Metal conversion. No CPU SOG was produced.
Separately, the same pinned converter on the local Apple M4 Pro GPU produced
an 8,575,332-byte SOG in 13.578 seconds, with all three SH bands and ten
clustering iterations unchanged. This is a compression-backend validation,
not a training-profile change. The GPU/Metal result loads in the actual
production viewer, passes browser checks, and was navigated using the saved
UI sequence. Both its initial view and interior pan still have obvious geometry
smears; B remains rejected. The converter's CPU and GPU clustering are both
randomized, and GPU may use FP16; byte equality is not expected. Cloud
Vulkan/L4 compatibility is not established by this local result.
No suitable denser version of this capture has been identified, so C is
unavailable with the current inputs and real SfM is the next quality ablation.

The recorded baseline and A02 SOG previews both load with the
production decoder/viewer and no browser errors, using the same private
loopback harness, 1280×720 viewport, initial camera and saved UI movement
sequence. Both remain visibly blurred. Recorded desktop navigation is
supplemental evidence, not a physical-phone or app-queue acceptance result.

A replaces exactly one trainer argument, `--no-pose-opt` with `--pose-opt`.
Simply deleting the former is ineffective: the pinned trainer defaults false.
Keep the 900-second training watchdog and 500,000 Gaussian cap for A. The
explicit B profile admits 30,000 steps with a 4,200-second training watchdog;
neither changes A's actual command. B requires a completed, cleaned A with its
collected metric artifact verified before it can be planned.

If A is insufficient, B changes training to 30,000 steps; C uses more frames
only if a suitable same-room capture exists; D tests real SfM if needed. The
original capture contains exactly 153 frames. An unrelated older 256-frame
session has no overlapping image hashes and cannot substitute for C.

## Spending and lifecycle

The owner ceiling is **$25 total**, including historical runs and failed setup.
At 2026-09-14 19:59 UTC, provider billing for completed hourly intervals showed:

| Historical use | Metered USD |
|---|---:|
| Three earlier failed attempts, combined | 1.09974939 |
| Sept 11 successful baseline | 0.57381695 |
| Disabled worker deployments/invocations | 0.00645445 |
| Total | **1.68002079** |
| Remaining before A | **23.31997921** |

Individual old failed attempts cannot be separated by the provider's app/hour
billing report; don't invent a split. New attempts use unique app namespaces.
Credits cover this usage, but gross compute counts against the ceiling.

The existing conservative full-lifetime bound is $4.9110336000 per sandbox,
not its expected cost or invoice. The production 600-cent hold is likewise not
an actual charge. Until a new attempt's attributable completed-hour billing is
available, the manual harness retains its full bound against the $25 total.
No automatic retry, marker resets, duplicate allocation on a lost reply, secret
in the GPU, network after media, or changes to the 7,200-second sandbox TTL.

The configured sandbox rate is $2.4555168/hour: L4 plus four physical CPU
cores and 32 GiB, using Sandbox rates and the 1.15 US region multiplier. The
brief's approximately $1.24/hour combines the cheaper Function CPU/RAM rates
without that multiplier. The baseline's actual charge implies $2.44298/hour,
consistent with the sandbox profile. At that shape a 40-minute run is about
$1.64, not a full $6 hold. Sources: https://modal.com/pricing and
https://modal.com/docs/guide/region-selection.

All four historical sandboxes had terminal provider polls and both spatial apps
had zero active tasks. The successful baseline explicitly deleted its remote
directory and terminated. The earlier billing-killed failed attempt's original
deletion receipt was unsuccessful; its terminal poll is not proof of that
separate deletion operation. Original receipts remain unchanged.

A01 allocated at 20:11:37 UTC. Its setup process returned 143 at 20:17:07,
before network closure or any media transfer. Independent provider readback
identified `GENERIC_STATUS_FAILURE` / `Worker disappeared.` despite numeric
exit code 0. No active sandbox remained. The original directory-removal call
failed; explicit termination/readback completed at 20:20:41. This is an
infrastructure failure with no PSNR/SSIM, not a failed pose-quality hypothesis.
An independent SHA-bound receipt establishes that private input transfer was
never reached. A02 is an explicitly reviewed fresh allocation with the same
training configuration; the original reservation and failed-cleanup receipt
remain intact. The provider's current billing limits were not the cause.

At 21:03 UTC, two unchanged provider readings for the closed 20:00–21:00 hour
attributed $0.21150668 to A01 and $0.64541049 to A02. Both exact providers were
terminal, with zero active sandboxes in their apps. Historical usage plus A is
**$2.53693796**; after retaining B's full $4.9110336 hold, **$17.55202844** remains
available. These are gross metered usage amounts, not a monthly final invoice.

At 22:00:48 and 22:02:56 UTC, unchanged closed-hour billing attributed
**$2.07333106** to B01. Its recorded provider lifetime was 3,153.965 seconds;
fresh checks again confirmed successful remote deletion, terminal 137 and zero
active B sandboxes. Historical usage plus A and B is **$4.61026902**. With D's
full **$4.9110336** hold retained, **$15.47869738** remains available. Local
SfM and local converter checks incur no provider charge.

At 23:00:52 and 23:02:15 UTC, identical closed-hour readings attributed
**$2.22848905** to D01 and **$0.02592446** to converter01's pre-media
preflight failure. All completed historical usage, training and export probes
now total **$6.86468253**, leaving **$18.13531747** before the next probe.
Converter02 was explicitly planned from clean source `7bde89c`, preserving
converter01's exact PLY and resource/compression profile with only the
driver-version parser correction. Its 1,800-second priced compute bound is
$1.2277584; the unchanged manual ledger conservatively holds $4.9110336.
Completed costs plus this outstanding hold are **$11.77571613**. No additional
GPU may be allocated until this provider's cleanup is reconciled.

## Release status

No winner yet. All production gates remain disabled. The candidate queue
provider explicitly passes `--pose-opt` and admits 30,000 steps / 4,200 seconds.
The worker now has a bounded, allowlisted numeric quality receipt in CPU logs
before conversion and temporary cleanup. It contains the job/provider identity,
fixed evaluator settings and validated PSNR/SSIM/LPIPS, never raw logs, media,
geometry or credentials. This remains undeployed until a quality winner exists.
Production setup now has the same 164 public Python version pins as A02 and
verifies the exact installed set after network denial and before media transfer.
The dependency file is included in both deployment and durable source inventories.
Migration `0055_spatial_training_quality_limits.sql` was scaffolded with the
CLI and numbered in the owner's next available sequence. It widens only the
two training check constraints, leaving existing row values and defaults intact.
It is **not applied**. An isolated local Postgres test accepted 30,000 / 4,200,
rejected out-of-range values, verified unchanged runtime settings, and confirmed
rollback; its temporary server was stopped. All 71 worker tests pass. The
integrated training harness has 130 passing tests and seven intentional skips
for the separate official SfM environment, where those seven pass.

An additional production SfM entrypoint is prepared in new, unreferenced files.
It composes the frozen D1 geometry functions for 20–400 frames, preserves the
every-eighth evaluation records, and provides child-process-group cancellation
and an environment constructed without inherited credentials. Its targeted
suite has 15 passing tests in official COLMAP, including a real synthetic
20-frame reconstruction and mixed successful/failed verification rows. In the
trainer environment, 13 pass and two geometry tests skip. The service suite
before the last metadata-only test addition had 83 passes and two skips. No
400-frame resource benchmark or production integration is claimed.

Current capture UI has a saved-photo counter, not green coverage targets or
8/16 completion. Automatic stopping at 400 frames/600 seconds records an
unexportable `limit_reached` session. For a denser capture, use 300–350 saved
photos and Stop manually; preserve the cadence/quality thresholds during A/B.
Coverage copy should encourage walking with overlap, revisiting doorways and
corners from different positions, upper/lower coverage and slow motion. Do not
label a frame count as room completeness.

The D1 helper started processing the real room locally at about 21:53 UTC,
from the frozen clean `84f4c10` checkout, under its 1,800-second supervisor.
This stage allocates no cloud GPU and incurs no provider charge.
It completed successfully in 118.150 seconds: 1,480 candidate pairs were
tested, with positive geometric inliers in 824 pairs and zero in 656. The
frozen helper's `verified_pairs` field counts stored verification rows, not
positive-inlier pairs; its original hash-bound report remains unchanged.
27,235 points were triangulated, and 26,522 points with
92,696 observations survived filtering. Reprojection RMSE changed from
1.643584 pixels before pose-prior adjustment to 0.847237 afterward and
0.834482 after filtering. The solver reached its 101-iteration limit and
reported `NO_CONVERGENCE` with a usable solution; do not call this convergence.
Training images 2, 3, 4 and 88 have no triangulated observations. Median camera
position/rotation changes were 0.013144 metres / 0.415431 degrees; maxima were
0.429339 metres / 6.770736 degrees. These are optimizer adjustments, not
independently measured ARKit errors.

The exact D dataset, training-only feature database, pair list, original
evaluation records and committed helper hashes passed the manual allocation
guard. D01 then allocated once from frozen `84f4c10`, retaining B's settings
and dependency baseline. Its exact 164 dependency versions were verified
after network denial, all 157 dataset files were transferred, and training
started at 22:08:51 UTC. All previous sandbox lifetimes were reconciled before
this allocation.
It uses official COLMAP/pycolmap 4.2.0 in a separate CPU environment: SIFT,
deterministic temporal/nearby pairs, triangulation, then camera-position-prior
bundle adjustment with fixed intrinsics. The 133 training images alone supply
features, matches, tracks and point colors. The original 20 evaluation image
and camera records stay unchanged. The explicit isotropic 1-metre position
prior is an assumption, not measured ARKit uncertainty. D changes both seed
initialization and training poses, so it is a pipeline ablation. Synthetic
checks establish feasibility only; quality requires the completed training
and viewer evidence below.

D01 completed and explicitly terminated at 22:52:03 UTC. The wrapper took
2,564.228 seconds; its training-loop receipt reports 2,504.630 seconds. All
157 uploaded inputs, 164 dependency versions, unchanged B training arguments,
26 collected artifact hashes and all 20 original evaluation canvases passed
independent verification. Directory deletion succeeded; fresh exact-provider
checks confirmed terminal 137 and zero active D sandboxes. Its 500,000-point
PLY is 118,001,477 bytes, SHA-256
`78c1ab7ba15ffbcf882ab4b867f9a1c7efd60afc2d5019822ff8439b932e625f`.

D is worse than B on all three aggregate metrics: PSNR −1.507727 dB,
SSIM −0.026527, LPIPS +0.011176. Relative to the original baseline, PSNR is
only +0.309259 dB while SSIM falls by 0.028936. The fixed backlit view still
has severe duplicated mirror, telescope and plant geometry. The pinned local
Metal converter produced an 8,613,998-byte, three-SH SOG in 13.146 seconds.
It loads in the production viewer without browser errors; the same saved
desktop movement sequence was recorded. The initial view and interior pan
show conspicuous smears and duplicated surfaces. D01 is rejected. Neither
the screenshots nor the recorded sequence imply phone/app-queue acceptance.

The first bounded L4 export probe, converter01, failed during public device
preflight before any private PLY transfer. Vulkan found the NVIDIA L4, but the
checker rejected its valid packed decimal/hex driver-version representation.
Remote directory deletion and terminal 137 were confirmed. A narrowly tested
parser correction accepts matching uint32/hex pairs; all converter profile,
dependency, allocation, network and cleanup settings remain unchanged. Any
subsequent probe requires its own explicit plan and allocation; there is no
automatic retry.

Converter02 succeeded on the NVIDIA L4 with that parser correction. The
converter process took **18.081663 seconds**; the complete remote helper took
19.105372 seconds, and the controller stage took 19.384346 seconds. It retained
500,000 Gaussians, three SH bands and ten clustering iterations, producing an
8,610,236-byte SOG, SHA-256
`417febc7c3f703a580c2950b53abb8da6fe3926f0961ab31c23686cfada45e22`.
The helper verified exact L4/Vulkan identity before private transfer, positive
engine-tracked GPU use (112.9 MB), no CPU fallback, input/output hashes, archive
integrity and the 32 MiB output cap. Independent verification passed. The
provider was explicitly terminated at 23:07:54 UTC after directory cleanup;
a fresh 23:10:40 SDK check confirmed terminal 137 and zero active app sandboxes.
Its 157.675-second provider lifetime is not an invoice. Keep the full hold
until closed-hour billing is stable after September 15 00:00 UTC.
The actual cloud-exported SOG also loaded in the production decoder with no
browser errors; controls rendered and Top-down navigation worked. Its private
viewer was closed afterward. The D01 geometry defects remain visible.

D2's local CPU preparation was explicitly started from clean `40e1413`, with
helper SHA-256 `c9a3f826c60d86943d58c6458662860fcdb80e80249526d63c2dc594b1d300d0`.
It copies the same D1 training-only feature/match database, estimates unknown
camera poses through incremental registration, aligns using training camera
centers, then reuses the unchanged D1 position-prior bundle adjustment. Fixed
intrinsics, all 153 JPEGs, 133 training entries, 20 original evaluation camera
records and trainer settings remain fixed. This is a pipeline ablation:
incremental mapping includes its internal bundle adjustment, triangulation,
filtering and component selection. The original-pose fallback is explicitly
enabled before execution, because image 88 has no positive-inlier connections;
every fallback camera must retain its exact original record and zero tracks.
The largest selected component and all missing/fallback IDs must be reviewed
before another paid training allocation. This preparation is local CPU only,
bounded to 1,800 seconds, with no cloud charge or quality acceptance implied.

D2 CPU preparation completed in **18.351 seconds**. Registration took
13.655 seconds and produced four components with 80, 15, 15 and 15 cameras
(one camera overlaps two secondary components). Only the largest 80-camera
component was selected. The other 53 training records fell back to their exact
original poses; nine cameras were never registered in any component. Cameras
2, 3, 4 and 88 still have zero observations. The selected reconstruction has
23,984 points and 120,723 observations, with 1.227112-pixel reprojection RMSE.
Root rejected this candidate before GPU allocation: it does not recover the
problematic early cameras and would discard useful reconstruction coverage.
**D2 PSNR/SSIM/LPIPS are unavailable because no trainer ran; cloud cost is $0.**
This CPU rejection is preserved rather than presented as a quality win.

D3 was frozen as `ec2a66e` before execution. It expands only candidate matching
to all 8,778 pairs of the same 133 training images, retaining the extracted
features, calibration, matching options, D2 registration pipeline and evaluation
cohort. The helper SHA-256 is
`5995dd585c338b3869a3a9cf2d860f37826bebe9c5f4d16213f68a9eabd43b1c`.
Six synthetic tests passed, including actual matching, preservation of an old
zero-result pair, the complete 153-frame cohort and original-pose fallback.
Independent rejection checks and a one-second supervisor timeout also passed.
The real-room run used a new private directory and the unchanged 1,800-second
CPU bound, with original-pose fallback explicitly enabled before execution.

D3 CPU preparation completed in **178.381 seconds**, of which matching took
143.537 seconds. Expanding 1,480 to 8,778 candidate pairs added 1,242 positive
pairs: 2,066 pairs now have inliers. The selected single reconstruction contains
126 training cameras, 34,903 points and 167,982 observations. Its remaining seven
original-pose fallback IDs are **2, 3, 4, 86, 87, 88 and 142**; all have zero
tracks. The final reprojection RMSE is 1.273660 pixels. Camera alignment has a
5.465-metre maximum residual; after bundle adjustment, maximum position and
rotation changes from the original poses are 5.380 metres and 179.935 degrees.
Independent verification reproduced the outliers: frame 140 moved 5.379573 m
and 179.935063 degrees; frames 56, 58, 59 and 60 moved 1.505–1.879 m and
179.476–179.786 degrees. The next largest position change is only 0.117982 m.
These are differences from ARKit, not independent ground-truth errors. The
source frames include both visible blur and fairly sharp, repetitive furnishings
or blinds, so blur alone does not explain the reversed camera estimates.
Expanded matching found no new positive-inlier pair for frames 2, 3, 4 or 88.

Root rejected D3 before GPU allocation: the problematic early views remain
unsupported, and the newly registered cameras include implausible reversals.
**D3 PSNR/SSIM/LPIPS are unavailable because no trainer ran; cloud cost is $0.**
Independent verification passed all five committed source hashes, frozen D2
geometry options, exact dry plan, 153 original JPEGs/intrinsics, 20 held-out
camera records, the 133-camera partition and reciprocal tracks. All 1,480
original rows in each pair table, all ten fixed database tables and cached
features remain unchanged; the expanded database contains exactly 8,778 pairs.
A successful data-integrity check is not a successful reconstruction.

The disabled worker candidate now uses the cloud-validated GPU export helper,
with exact-source verification, device checks before media transfer, unchanged
dependency/network gates, receipt-bound PLY input and bounded SOG validation.
All existing provider cost, lease, journal and cleanup semantics remain intact.
The 80 relevant offline tests pass, and the real converter02 receipts and SOG
also pass the production validation functions. No worker deployment, Secret,
runtime update or migration has been applied.


At 23:45–23:46 UTC, read-only production checks confirmed the runtime remains:

```json
{
  "enabled": false,
  "daily_budget_cents": 0,
  "org_monthly_budget_cents": 0,
  "job_cap_cents": 600,
  "max_seconds": 7200,
  "max_training_seconds": 900,
  "max_iterations": 3000,
  "max_gaussians": 500000
}
```

There are zero `spatial_jobs`. No winning runtime values are prescribed because
no run passes quality acceptance. B's 30,000 steps / 4,200-second watchdog are
measured experiment settings, not a release recommendation. The worker source
switch is still false, and no new Secret, schedule, deployment or migration was
activated. Claude's fetched tip at 23:44 UTC remains `8d32f855`, already included.


## Capture guidance supported by this scan

The original sidecars contain 153 saved frames over 76.0065 seconds, with every
adjacent gap approximately 0.500043 seconds. Median adjacent translation is
13.24 cm (95th percentile 28.81 cm, maximum 42.22 cm); median rotation is
10.04 degrees (95th percentile 26.33, maximum 56.92). Twenty-four of 152
intervals turn more than 20 degrees. All saved frames report normal tracking;
that state does not establish usable photographic overlap or sharpness.

Frames 2–5 have short 0.84–1.12 ms exposures, so long exposure is not a supported
explanation for their registration failure. Frames 86–90 have 16.67 ms
exposures and several 27–36-degree turns between successive half-second frames.
These are recorded adjacent averages, not shutter-motion measurements or proof
of the current blur filter's behavior. The scan predates that filter.

For the next private capture, use one well-lit room, remove moving subjects,
and include a printed label near a door frame so text and edge quality can be
judged. Walk slowly with gentle turns, keeping recognizable details visible
across successive viewpoints. Revisit the first wall, doorways and corners from
several positions; include upper and lower surfaces. Do not stand in place and
spin. Aim for 300–350 **saved photos** and press Stop and save before the current
400-photo or ten-minute cap. More photos alone do not guarantee coverage.
A new recording is a new benchmark, not the missing same-capture C ablation:
freeze its evaluation cohort before training and compare variants on that cohort.

Recommended capture UI work, separate from the frozen experiments:

1. Replace the 150–250-frame advice with a guided slower scan and a visible
   reminder to stop before the hard limit; say "photos" rather than "frames".
2. Show where the user should move next and distinguish translation/overlap
   from merely turning. The present saved-photo count is not a completeness
   score; green targets and an "8 of 16" indicator are not implemented.
3. Keep existing blur and low-texture feedback, and add practical overlap/revisit
   guidance. Do not claim normal ARKit tracking means a usable reconstruction.
4. Review the cap-stop behavior: currently reaching a cap preserves the files
   but marks the scan unexportable. A future change should safely finalize and
   validate complete saved data rather than make the user repeat the whole room.
   This behavior was not changed during the ablation.

ARKit-only reconstruction did not pass on this scan. The SfM branch adds measured
feature tracks and camera refinement, but none of the tested SfM profiles has
passed acceptance either. Better coverage and reliable pose validation are
needed before further paid training or enabling the feature. No result establishes
Matterport-level quality, text legibility or an end-to-end phone queue success.
