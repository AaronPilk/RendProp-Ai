# September 23 phone capture benchmark

Owner supplied a completed real-phone capture on September 23. The original
capture and derived geometry stay outside Git in private local experiment
storage. No simulator camera test is represented by this work.

## Intake

- 400 sensor-native 1920×1440 JPEGs, 400 sidecars, one manifest; all 801 files
  were copied with byte hashes verified. Original files were not changed.
- Completed at the 400-frame limit after about 205 seconds; all retained
  sidecars report normal ARKit tracking in one coordinate epoch.
- Manifest SHA-256:
  `c3b8818adb5c4fe54399b52ae51cf743a24cdda8c76cd663ecee9a081f33c124`.
- Preserve JPEG orientation, individual camera intrinsics and ARKit poses.
  Sensor-native sideways pixels must not be rotated without recalibration.
- Source photos include visible motion blur despite zero reported blur rejects.
  Input quality and reconstruction quality require separate examination.

## Frozen comparison

This is a **new scene/cohort**. Its scores cannot establish a causal improvement
over the September 11 scene. No old experiment is silently relabeled as this
capture's control.

Sorted frames 000001, 000009, …, 000393 form the same 50-view evaluation set in
every run. The other 350 frames train the model. Initialization uses only point
observations and sampled colors from those 350 training frames, preserving the
existing adapter's latest-visible-ID and first coincident-cell rules.

Shared ARKit VIO still supplies the validation poses; they are not independently
measured ground truth. Training-pose optimization does not optimize those
held-out poses. Metrics therefore measure rendering at the original validation
poses, with that limitation. Freeze PSNR, SSIM, LPIPS and all 50 comparison
renders, including unsuccessful quality results.

| Stage | Pose optimization | Steps | Training time cap |
|---|---|---:|---:|
| f01 | off | 3,000 | 900 s |
| p01 | on | 3,000 | 900 s |
| s01 | on | 30,000 | 4,200 s |

Each stage requires an explicit separate allocation. The next stage requires
the preceding stage's matching source/data hashes, complete metrics and renders,
and reconciled cleanup. No automatic rental retries. All other trainer settings,
image bytes, model initialization, random seed 42 and upstream dependency pins
stay fixed. The original trainer is gsplat commit
`937e29912570c372bed6747a5c9bf85fed877bae`, MCMC, native image scale,
500,000 Gaussian maximum, and no world normalization.

## Budget and isolation

The existing $25 total authorization is shared with all previous spatial work.
Fresh September 23 provider readback found $6.96837765 gross metered usage,
zero outstanding reservations, and all ten previously recorded sandboxes
terminal. No new experiment has a separate budget bucket. Each allocation
reserves the existing conservative $4.9110336000 full-lifetime bound until its
closed attributed provider bill is available. A reservation is not actual spend.

The reused runner permits dependency installation before private media transfer,
then denies outbound networking before any capture data is uploaded. It creates
one ephemeral sandbox, no public endpoint or persistent volume, downloads bounded
artifacts, explicitly deletes its remote working directory, and terminates the
sandbox. The new runner uses the original approval lock and marker glob.

## Acceptance

No new capture result has passed acceptance yet. Scores alone cannot justify
enabling production: inspect architectural edges and continuous navigation,
then validate viewer/device performance and the real phone queue path. Keep the
existing four gates and deployment flags until supported by those results.
