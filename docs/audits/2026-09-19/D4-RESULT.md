# Spatial D4 result and capture follow-up

**D4 is rejected. There is still no accepted reconstruction or winning runtime profile.** The single known-focal metadata change did not recover the seven unsupported training views and produced large camera disagreements. No GPU training, provider allocation, deployment, runtime mutation or App Store Connect operation followed it.

The run started September 20, 2026 at 00:13:11 UTC and ended at 00:23:26 UTC (September 19, 20:13–20:23 EDT). Frozen source: `c4750578e2307df180c6321a6370dc6855e25ff8`, branch `feat/spatial-calibrated-sfm-20260919`. The preregistration was committed before execution. There was exactly one local CPU attempt and no retry.

## Intervention and preservation

D4 changes `prior_focal_length` from `0` to `1` for the original 133 training cameras. It recomputes derived two-view geometry from the same cached raw matches, then uses the frozen registration, alignment, bundle adjustment and export functions. The flag also affects initial-pair registration; this is one metadata intervention throughout the pipeline, not a verification-only change or an essential-matrix-only constraint.

- Original 153 JPEGs, all numeric intrinsics and all 20 held-out camera records remain unchanged.
- All 8,778 raw pair rows, 584,883 raw correspondences, feature tables and other protected database tables remain unchanged.
- Original D3 cache/report/run bytes and frozen helper files remain unchanged.
- Positive verified pairs remain 2,066. Inlier incidences changed from 427,605 to 428,409.
- Geometry configurations changed from 2,038 uncalibrated + 28 planar/panoramic to 1,450 calibrated + 587 uncalibrated + 29 planar/panoramic. This classification change is not proof of correct geometry.

The worker retained network denial, an explicit environment without inherited credentials, four CPU threads, the 1,800-second process-group timeout, and private output outside Git. Eight synthetic tests passed before dispatch, including full reconstruction, protected-input failures, actual network denial, timeout cleanup and a completed rejection that could not promote its adapter. Independent source review found no blocker for this bounded CPU experiment.

A separate post-run audit completed at 00:27:59 UTC. It reread the source/output images, camera records and logical database tables, recomputed the exported pose/track diagnostics exactly, and confirmed the supervisor and worker had exited. The copied database's physical file hash changed between verification and registration, while its logical tables remained identical and its final hash matched the recorded registration receipt. The original D3 file stayed byte-identical. No preservation contract mismatch was found.

## Measured result

Worker/supervisor exit: **2, completed CPU rejection**. The measured worker was 613.173 seconds; the outer dispatch/supervisor interval was 615.205 seconds. Cached verification took 336.352 seconds and registration 185.094 seconds. Cloud spend: **$0**.

Supported training views: **126/133**. IDs `2, 3, 4, 86, 87, 88, 142` remain unsupported, as in D3. Diagnostic export retains their original camera records with zero observations; it does not count them as successfully reconstructed views.

| Stage | Unsupported views | Cameras >1 m from ARKit | Cameras ≥90° from ARKit | Maximum distance | Maximum rotation |
|---|---:|---:|---:|---:|---:|
| Registered, before alignment | 7 | Not comparable | Not comparable | Arbitrary gauge | Arbitrary gauge |
| Aligned to ARKit world | 7 | 46 | 46 | 11.253845 m | 179.977011° |
| After bundle adjustment | 7 | 100 | 80 | 8.650193 m | 170.792170° |
| After point filtering | 7 | 100 | 80 | 8.650193 m | 170.792170° |
| Exported diagnostics | 7 zero-observation fallbacks | 100 | 80 | 8.650193 m | 170.792170° |

After refinement, the median difference among registered cameras is **1.561537 m / 169.990804°**. These are disagreements with recorded ARKit VIO, not measurements against physical ground truth. The preregistered rejection uses every stage, so refinement cannot hide an earlier failure.

Final diagnostics contain **34,831 points**, **174,179 reciprocal observations** and **1.295864 px reprojection RMSE**. A low reprojection residual does not establish correct room geometry. The result failed both coverage and pose checks. `dataset/adapter-report.json` does not exist; only `adapter-report.pending.json` remains for diagnosis.

**PSNR, SSIM and LPIPS are unavailable for D4 because it was rejected before GPU training.** No rendered-quality improvement is claimed.

## Complete quality experiment status

The original fixed comparison and detailed cost ledger remain in `docs/audits/2026-09-14/SPATIAL-ABLATION.md`; historical results have not been rewritten.

| Run | PSNR dB | SSIM | LPIPS | Gross cloud USD | Decision |
|---|---:|---:|---:|---:|---|
| September 11 baseline, 3,000 steps | 19.65985680 | 0.81097144 | 0.55676222 | 0.57381695 | Blurry; rejected |
| A01 setup failure | Unavailable | Unavailable | Unavailable | 0.21150668 | Failed before media transfer |
| A02 pose optimization, 3,000 steps | 19.15759087 | 0.80769598 | 0.56202793 | 0.64541049 | Rejected |
| B01 pose optimization, 30,000 steps | 21.47684288 | 0.80856246 | 0.38908443 | 2.07333106 | Best measured PSNR; visible geometry artifacts; rejected |
| C, denser version of the same capture | Not run | Not run | Not run | 0 | Additional original frames unavailable |
| D01 real SfM, 30,000 steps | 19.96911621 | 0.78203511 | 0.40026075 | 2.22848905 | Rejected |
| D2 incremental SfM | Unavailable | Unavailable | Unavailable | 0 | CPU rejection, 80/133 selected cameras |
| D3 expanded pairs | Unavailable | Unavailable | Unavailable | 0 | CPU rejection, 126/133 supported cameras and pose disagreements |
| D4 known-focal metadata | Unavailable | Unavailable | Unavailable | 0 | CPU rejection described above |

Neither ARKit-only training nor the tested SfM alternatives has met acceptance on this capture. This does not prove that ARKit is universally unsuitable or that SfM is universally necessary. D4 does rule out treating this metadata correction alone as a quality fix for the current scan.

A/B retain the original initialization, including held-out seed colors; those are loss-held-out comparisons, not fully image-disjoint evaluation. D preserves the same evaluation images and camera records while excluding them from reconstruction features, tracks and point colors. Do not silently weaken or change the evaluation setup to improve a score.

## Spending, deployment and next input

Fresh provider/billing checks completed September 19 at 23:49 UTC. All ten recorded sandboxes were terminal; seven GPU app inventories were empty. Gross task spend was **$6.96837765**, pending holds **$0**, leaving **$18.03162235** under the unchanged **$25 ceiling**. Closed billing hours through 23:00 UTC showed no new attributed charges; the then-current hour was unfinalized. This continuation allocated no cloud resources, so D4 adds no charge.

The total also includes $1.09974939 for three inseparable historical failed attempts, $0.00645445 for historical disabled-worker use, and $0.02592446 / $0.10369512 for the two converter probes. These costs remain counted; credits do not erase gross spend.

There are **no winner `spatial_runtime` values** to deploy. No live gate was changed here. The last recorded database runtime read remains September 14 (`enabled=false`, daily/monthly budgets `0`, `job_cap_cents=600`, `max_seconds=7200`, `max_training_seconds=900`, `max_iterations=3000`, `max_gaussians=500000`); this is not a September 20 live read. Recheck all four gates before any future accepted release. B's 30,000 steps and 4,200-second watchdog remain experimental settings.

A bounded search found no newer exported native capture in the relevant project/private experiment locations and Desktop/Downloads exports. Three matching manifests represented only the known September 11 153-photo scan and the unrelated September 10 256-photo scan. The Downloads manifest was an exact copy of the latter. No room images were opened or archives unpacked for that search.

The next useful input is a new, slow, overlapping room capture, approximately **300–350 saved photos**, including revisits, door frames, upper/lower surfaces and a readable label. Avoid standing still and spinning. Stop once coverage is sufficient, before the existing 400-photo/ten-minute ceiling. A new scan requires a new frozen benchmark and within-benchmark comparisons; it cannot be labelled a controlled denser version of the old scan.

## Capture usability work completed separately

Branch `fix/spatial-capture-limits-20260919`, commit **`ddd636788da4db90a286ca9ffeb4e7f6ccb94975`**, repairs the normal ceiling behavior without raising limits or relaxing validation. Pending writes drain, stop reasons are recorded, and a fully validated capped scan waits for explicit **Use this scan**. Failed, interrupted, corrupt and historical `limit_reached` attempts remain blocked. A separate fix prevents delayed inspection of an older scan from offering it for upload after another capture or account change.

- Draft PR: https://github.com/AaronPilk/RendProp-Ai/pull/2
- CI: https://github.com/AaronPilk/RendProp-Ai/actions/runs/35478018351 — all 11 jobs passed on that exact commit. The separate Supabase Preview check was skipped.
- Native regression: 55 baseline / 86 repaired recorder and controller checks; 19 real importer cases, including a valid 400-image posed dataset; 31 delayed-inspection checks with four rejected behavioral mutants.
- Existing capture integrity and quality checks passed, including 115 core, 7 adversarial, 8 JPEG and 3,076 pose assertions.
- Full unsigned Release iPhone app build passed in 260.03 seconds with all recorded product source hashes unchanged. Nothing was installed on a phone and no physical runtime result is claimed.
- Detailed capture report: `docs/audit/SPATIAL-CAPTURE-LIMITS-20260919.md` in that capture worktree. Durable copied receipts: `/Users/pilksclaes/LocalRendpropAudits/spatial-capture-limits-20260919/evidence-index.json`.

This prepares the capture path for better input; it does not make the rejected 3D output shippable. The capture branch is based on the audited September 19 candidate, while this experiment branch preserves the frozen spatial baseline. Do not merge the older spatial migration 0055 over the candidate's 0055/0056; verify inventory and use the next free 0057+ sequence if integration later needs a migration.

## Local evidence

- Plan and dispatch: `/Users/pilksclaes/LocalSpatialExperiments/spatial-sfm-20260919-d04.plan.json` and adjacent launch/check/completion receipts.
- Full result: `/Users/pilksclaes/LocalSpatialExperiments/spatial-sfm-20260919-d04/{sfm-report.json,sfm-run.json,sfm.log}`.
- Numeric and preservation verification: `/Users/pilksclaes/LocalSpatialExperiments/spatial-sfm-20260919-d04.verification.json`.
- Independent audit: `/Users/pilksclaes/LocalSpatialExperiments/spatial-resume-20260919/d04-independent-verification.json` (SHA-256 `6fe06c8301922e02b53cfabadfa5348cb973f2cc49b8d72c6a8e9ee9e0f4f674`).
- Frozen eight-test run: `/Users/pilksclaes/LocalSpatialExperiments/d4-synthetic-tests-20260919-final/{unittest.log,receipt.json}` (8 passed, 0 skipped).
- Provider/billing audit: `/Users/pilksclaes/LocalSpatialExperiments/spatial-resume-20260919/provider-billing-audit-20260919.json`.

Private room media and raw geometry remain outside Git and outside Fable/Mythos. No historical receipt, capture, migration or shared branch was overwritten.
