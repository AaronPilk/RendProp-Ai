# Latest spatial capture intake — September 11, 2026

**Result: valid capture input; privately prepared dataset; not a reconstructed
room or a phone-viewer pass.** The original owner export is unchanged. No new
GPU rental, provider upload, billing-setting change, production deployment,
Apple operation, or media commit was performed.

Code used: `21ee722` (adapter/runner code unchanged from the preceding experiment
checkpoint). This intake documentation is on `audit/capture-intake-20260911`.
Python3.12.14 / Pillow12.1.1 reused the installed validation environment; no
dependency installation was needed. A preliminary `uv` interpreter-resolution
attempt selected Python3.9.6 and exited1 before capture validation. It was not
reported as a capture failure or a pass.

## Actual observations

| Property | New capture | Previous capture |
|---|---:|---:|
| JPEGs, each paired with a sidecar |153|256|
| Total files, including manifest |307|513|
| Total input bytes |84,479,326|151,650,870|
| JPEG bytes |80,705,752|146,328,766|
| Raw feature observations |41,718|57,894|
| Distinct usable initialization seeds |9,226|14,654|
| Camera radius about mean recorded position |3.976m|4.401m|

The new capture spans76.0065 seconds, with153 images at1920×1440 and saved-frame
intervals approximately0.50004 seconds. It is a different session: zero new
images have byte-identical hashes to the prior capture, and there are zero
byte-identical image duplicates within the new capture. That does not rule out
near-duplicate views.

Recorded camera motion between adjacent images: median0.1324m translation,
p95 0.2907m; median10.04° rotation, p95 26.79°, maximum56.92°. These are
diagnostics from reported poses, not externally measured ground truth or new
acceptance thresholds. Accumulated recorded travel is22.10m, not a property
dimension or reconstructed surface measurement.

All153 actual JPEGs decoded successfully and matched their declared native
raster/EXIF orientation. All153 sidecars passed the current session, time,
tracking, rigid-pose and calibration checks. In particular the earlier invalid
homogeneous-row error did not reproduce on this export.

## Execution evidence

Private evidence root:
`/Users/pilksclaes/LocalSpatialExperiments/capture-20260911.liWf0i/`.
The source folder is the latest owner-supplied iCloud export; its exact path is
retained in the private receipt rather than copying media identity into Git.

Executed operations, not an aggregate whole-app test claim:

1. Existing `capture_handoff.py inspect <owner export>`: **exit0**.
   `inspection.json` / empty `inspection.stderr`. It checks exact file sets,
   source before/after byte hashes, all actual JPEG decodes and all pose records.
2. Private copy made with `ditto <owner export> <evidence>/capture`: **exit0**.
   All307 copied file hashes matched the validated source, independently checked.
3. Native `shasum -a 256` over the private copy, six bounded parallel processes:
   **exit0**,307 digests. `private-copy-sha256.txt`.
4. Private read-only `compare_capture.py`: final **exit0**. It asserts exact
   file-set/hash agreement and computes the aggregates above against the prior
   stored capture report. `comparison.json` and the actual script are retained.
5. Existing `capture_handoff.py inspect <private copy> --dataset <new dataset>`:
   **exit0**. `dataset-report.json` / empty `dataset.stderr`.
6. Actual `run_training.validate_dataset(...,500000)` and `modal_room.inventory`
   imported and called **locally only**, with additional binary-header/mode
   assertions: **exit0**. `dataset-consumer-check.json`.

The final private dataset has153 copied JPEGs, three binary camera/point files,
an adapter report, and a local provenance report. The existing transfer inventory
admits157 files totaling81,211,658 bytes and excludes provenance/raw sidecars.
Binary headers contain153 cameras,153 image records and9,226 initial points.
Dataset directories are0700 and regular files0600. No coordinates, raw hashes,
session IDs or photographs are committed here.

An integrity check initially **failed**, and that failure was not bypassed:
the first parallel read directly from iCloud returned empty-content hashes for
four sidecars while files were still being materialized. The comparison exited1.
Its original `parallel-file-sha256.txt` is preserved. The fully decoded source
validator, the completed private copy and a fresh independent private-copy hash
pass then matched all307 actual files. No original capture JSON was rewritten,
normalized, removed or silently replaced to achieve this result.

## Quality caveats — important before interpreting a trained result

The root visually inspected image1, image78 and image153. The first is sharper;
the middle and last show conspicuous blur. This is a three-image visual sample,
not an all-image blur score or a failed-reconstruction verdict. Window glare,
reflective surfaces and large low-texture wall areas are visible reconstruction
challenges. Do not declare drift, pose accuracy, room coverage or model quality
from these checks.

The standalone images appear sideways because they intentionally preserve the
sensor-native raster. Do not rotate/EXIF-normalize the JPEGs independently of
their camera calibration and poses. File preview orientation alone is not an
adapter defect.

The current recorder selects normal tracking plus elapsed cadence; it has no
blur, baseline, overlap or room-coverage rejection (`capture-ios/Sources/
CaptureRecorder.swift:85–104`). This export supplies concrete blur examples for
that capture-guidance backlog. A valid export is not a claim that every saved
frame is suitable for high-quality training. The owner should not be asked to
recapture solely because the prior GPU provider stopped a job for billing.

ARKit feature seeds are tracking estimates, **not a dense LiDAR surface**.
The adapter uses all frames for seed initialization; later evaluation images
are withheld from training loss, not entirely unseen during initialization.
Any eventual held-out-render report must state that limitation.

## What did not happen / next boundary

No trainer, CUDA, PLY export, SOG conversion, phone-browser walkthrough, FPS,
decode-memory or first-meaningful-frame measurement ran on this capture. A
prepared dataset is not the missing 3D model.

The earlier256-frame dataset and all failed GPU receipts remain intact. This
new candidate was not silently substituted in a paid job or the existing
allocation marker. The last confirmed provider cause remains the account's
billing-cycle spend limit; resolving it and identifying the approved next
capture precede any further rental. TheUSD25 total experiment ceiling is not
relaxed by this intake. No new TestFlight binary was delivered.
