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
- Read all 20 PSNR/SSIM values via the trainer's aggregate metric JSON. Compare
  fixed render pairs 0007 (interior edges/patterns), 0014 (cabinetry/door trim),
  and 0000 (backlit thin geometry). Text legibility and continuous-navigation
  ghosting still need a real-room acceptance capture; these frames cannot prove
  them.

| Run | Pose optimization | Steps | Frames | PSNR dB | SSIM | LPIPS | Trainer seconds | Metered USD |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Sept 11 baseline | Off | 3,000 | 153 | 19.65985680 | 0.81097144 | 0.55676222 | 209.441 | 0.57381695 |
| A | On | 3,000 | 153 | Pending | Pending | Pending | Pending | Pending |

A replaces exactly one trainer argument, `--no-pose-opt` with `--pose-opt`.
Simply deleting the former is ineffective: the pinned trainer defaults false.
Keep the 900-second training watchdog and 500,000 Gaussian cap for A.

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

All four historical sandboxes had terminal provider polls and both spatial apps
had zero active tasks. The successful baseline explicitly deleted its remote
directory and terminated. The earlier billing-killed failed attempt's original
deletion receipt was unsuccessful; its terminal poll is not proof of that
separate deletion operation. Original receipts remain unchanged.

## Release status

No winner yet. All production gates remain disabled. A source toggle alone is
insufficient: the queue provider must explicitly pass `--pose-opt` if it wins.
The queue currently discards evaluation statistics during temporary cleanup;
preserve a bounded quality receipt before the app-queue acceptance run.

Current capture UI has a saved-photo counter, not green coverage targets or
8/16 completion. Automatic stopping at 400 frames/600 seconds records an
unexportable `limit_reached` session. For a denser capture, use 300–350 saved
photos and Stop manually; preserve the cadence/quality thresholds during A/B.
Coverage copy should encourage walking with overlap, revisiting doorways and
corners from different positions, upper/lower coverage and slow motion. Do not
label a frame count as room completeness.
