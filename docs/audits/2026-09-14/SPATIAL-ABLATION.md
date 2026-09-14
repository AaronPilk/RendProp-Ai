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

| Run | Pose optimization | Steps | Frames | PSNR dB | SSIM | LPIPS | Trainer seconds | Metered USD |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Sept 11 baseline | Off | 3,000 | 153 | 19.65985680 | 0.81097144 | 0.55676222 | 209.441 | 0.57381695 |
| A01 setup failure | Not reached | Not reached | 0 transferred | Unavailable | Unavailable | Unavailable | Not reached | 0.21150668 |
| A02 | On | 3,000 | 153 | 19.15759087 | 0.80769598 | 0.56202793 | 252.094 | 0.64541049 |
| B01 | On | 30,000 | 153 | 21.47684288 | 0.80856246 | 0.38908443 | 2,425.635 | Pending closed-hour billing; full lifetime hold retained |

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
is being measured locally; it is not proof of Modal conversion performance.
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

Current capture UI has a saved-photo counter, not green coverage targets or
8/16 completion. Automatic stopping at 400 frames/600 seconds records an
unexportable `limit_reached` session. For a denser capture, use 300–350 saved
photos and Stop manually; preserve the cadence/quality thresholds during A/B.
Coverage copy should encourage walking with overlap, revisiting doorways and
corners from different positions, upper/lower coverage and slow motion. Do not
label a frame count as room completeness.

The optional D1 helper is prepared but has not processed real room images.
It uses official COLMAP/pycolmap 4.2.0 in a separate CPU environment: SIFT,
deterministic temporal/nearby pairs, triangulation, then camera-position-prior
bundle adjustment with fixed intrinsics. The 133 training images alone supply
features, matches, tracks and point colors. The original 20 evaluation image
and camera records stay unchanged. The explicit isotropic 1-metre position
prior is an assumption, not measured ARKit uncertainty. D changes both seed
initialization and training poses, so it is a pipeline ablation. Synthetic
checks establish feasibility only; D is not a quality result or deployment
decision.
