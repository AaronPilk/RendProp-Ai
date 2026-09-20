# D4: enable known-focal metadata for the original cached matches

Preregistered before any D4 room processing. This is one bounded CPU experiment,
not approval for GPU training, deployment, or acceptance of rendering quality.

## Hypothesis and single variable

All 133 D3 training cameras have `prior_focal_length=0`, although their numeric
PINHOLE intrinsics came from ARKit and are held fixed. D4 changes only that
database flag to `1`. On a new private copy of the D3 database, invalidate and
recompute the derived `two_view_geometries` table from the same raw matches.
Cache invalidation is necessary to exercise the changed flag; it is not a new
matching method. The frozen D1/D2/D3 helpers and historical data stay unchanged.

COLMAP 4.2.0 uses this flag to enter calibrated verification. That path still
compares essential, fundamental and homography models and can retain F/H
fallbacks. This does **not** force essential-matrix-only verification. The
hypothesis is that supplying the known-calibration metadata changes misleading
verified correspondences and reduces the five large D3 pose disagreements. It
may fail, especially for the poorly connected early views and image 88.

The changed flag remains `1` throughout registration. COLMAP's initial-pair
registration calls the same flag-sensitive two-view estimator again, so this
is a known-focal metadata intervention across verification and registration,
not a verification-only intervention. Initial-pair ranking also reads the flag;
all 133 cameras change uniformly. The frozen registration options already
disable focal estimation/refinement, and numeric calibration stays fixed.

## Frozen inputs and processing

- Original 153 JPEGs and all numeric camera intrinsics stay byte-identical.
- The original 20 `test_every=8` held-out camera records stay byte-identical and
  excluded from features, matching, registration, point colors and training tracks.
- D3's 8,778 unordered training pairs and 584,883 raw correspondences stay fixed.
  Every raw match row, descriptor, keypoint and non-derived database table must
  remain identical except the 133 focal-prior flags. The derived two-view rows
  are the intended regenerated result.
- The same four-thread CPU matching options and geometric-verification options
  are used, with RANSAC seed 0 and one RANSAC thread. No feature extraction or
  descriptor matching is permitted; cached raw rows are reused and verified.
- Reuse D2 registration, component selection, robust ARKit alignment and D1
  position-prior BA. Keep `ignore_two_view_tracks=true`, the 1 m position prior,
  all intrinsics fixed, filtering at 4 px/1.5 degrees, and all existing seeds.
- An explicit original-pose fallback may preserve missing camera records for
  diagnosis, but any such fallback fails the CPU admission check below.
- At most 1,800 seconds for the entire worker, including verification and
  geometry, under the existing process-group cancellation supervisor. Four CPU
  threads, no GPU, no network egress, and an allowlisted environment containing
  no inherited credentials. Private output only, outside Git.

## Preregistered rejection checks

Record coverage after registration, then pose differences after similarity
alignment, after BA, after point filtering, and after export. Before alignment,
the reconstructed world has an arbitrary similarity gauge and absolute ARKit
pose differences would be meaningless; only finite geometry and coverage are
checked at that stage.

Reject CPU admission if **any** recorded stage has:

1. A missing/unregistered training camera or a training camera with zero point
   observations (all 133 training cameras are required; the 20 held-out cameras
   are deliberately excluded from this requirement).
2. After alignment, a camera-center difference **greater than 1.0 m**, or a full
   SO(3) rotation difference **greater than or equal to 90 degrees**, relative to
   its recorded ARKit pose. These checks also apply independently after BA,
   filtering and export, so a later stage cannot conceal an earlier failure.
   The inclusive rotation boundary uses a conservative `1e-10` degree numerical
   tolerance, so floating-point roundoff at exactly 90 degrees cannot pass.
3. A nonfinite pose, residual or diagnostic, unusable solver result, point count
   outside 100–500,000, altered protected input, or timeout/cancellation.

The 1 m bound matches the already frozen alignment consensus bound; 90 degrees
rejects gross orientation disagreements such as D3's approximately 180-degree
flips. Neither treats ARKit VIO as physical ground truth. Passing these checks
is necessary for further manual review, **not sufficient for GPU allocation or
shipping**. No PSNR/SSIM/LPIPS or visual-quality result is inferred from CPU
registration counts or reprojection error. Rejected diagnostic outputs remain
private and cannot acquire a completed adapter report.

## Evidence and reporting

Bind the committed helper files, this document, original adapter and image/model
hashes, D3 run/report/database/pair-file hashes, before/after table hashes, exact
flag changes, raw-match totals, geometry-config counts and every stage's camera
coverage/pose differences. Preserve partial receipts on failure. No edits to
historical receipts and no automatic retry.

Primary source: [COLMAP 4.2 calibrated verification](https://github.com/colmap/colmap/blob/4.2.0/src/colmap/estimators/two_view_geometry.cc)
and [cached raw-match verification/writeback](https://github.com/colmap/colmap/blob/4.2.0/src/colmap/controllers/feature_matching_utils.cc#L430-L478).
The mapper also uses the flag during [initial-pair estimation](https://github.com/colmap/colmap/blob/4.2.0/src/colmap/sfm/incremental_mapper_impl.cc#L621-L629)
and [focal-estimation selection](https://github.com/colmap/colmap/blob/4.2.0/src/colmap/sfm/incremental_mapper.cc#L325-L367).
