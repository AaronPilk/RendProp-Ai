# Photo gallery reconciliation and retained reference review — 2026-10-04

This suite compiles the real `PhotoVersionHistory.swift`, `PhotoCaptureStorage.swift` and `PhotoVersionHistoryTests.swift` with Foundation and requires at least 640 positive assertions plus named controls. It uses synthetic non-empty byte files, not camera capture, paid AI, customer photos or a cloud mutation. Staged listing selection is advisory; a staged furnishing reference still requires the exact saved version's recorded review.

```sh
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault drop-legacy-reconciliation
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault bypass-stage-reference-review
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault latest-as-cover
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault blank-family-badges
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault forget-reviewed-stage
```

The positive fixture has three pre-history `enh-*` siblings and independently performs the first new capture, first edit, and first removal. All untouched siblings remain selected; removing one family leaves the other two. All predecessor and source bytes remain unchanged. Legacy adoption retains `originalVerified: false` and `sourceHistoryKnown: false`; a filename never certifies an unaltered source. Unknown `edit-*`/`cloud-photo-*` outputs do not enter the legacy scanner. A corrupt index still stops publication rather than silently clearing or replacing a cloud gallery.

Further cases verify retained declutter/staging libraries, a hidden earlier cover resolved by family, fallback chosen from the saved listing selection instead of the latest staging workspace, individual family badges even when selected bytes are unavailable, staged imports with a retained source, explicit reviewed-marker persistence at both selection APIs, and no resurrection after removal. Staged cloud import is a local preview by default; its retained earlier source remains explicitly unverified.

On the current app source, the positive command takes `current_contract.run_current(..., "migration")`: it compiles the actual shared read sink and explicit preparation closure and checks local reader/history and original certification in 14 assertions, with no network or hosted writes. The older `AppModel.syncGalleryPhotos` / `EnhancedPhoto.loadForListing` extraction branch runs only when `publishedGalleryAssets` exists in the app source; it was not entered in this run. These closed Foundation checks do not establish a phone UI or whole publication run.

Each negative control mutates a temporary copy of the production implementation, successfully compiles, and must reach its named runtime assertion. Setup/compiler failures never count as fault detection. `--output-dir` can preserve receipts and compile/runtime logs; the default is a private temporary directory. Receipts bind the checked-in implementation and test hashes. The runner fails if positive assertions or expected runtime rejection differ.

Native coverage lives in `RendpropUITests/BetaPolishUITests`: `testLegacyGalleryKeepsSiblingsAndStagedCoverRequiresReview` and `testSavedDeclutterAndStagingLibrariesKeepDownloadsAndListingChoiceSeparate`. They drive actual SwiftUI on a dedicated simulator with three procedural legacy photo pairs, no pre-adoption fixture shortcut. They check first removal, legacy cover selection, advisory staged selection, fallback, and the exact Photos and listing file-grid badges. The native fixture uses MockAPIClient and cannot make a provider call or claim physical-camera quality.

Cloud media currently supplies staged/altered flags but no provenance identifier. An imported edited output is therefore kept as a truthful local preview; the publication service still requires a verified server provenance binding before republishing edited bytes. Selecting/exporting its earlier source does not invent that binding. This audit does not remove the publication disclosure gate.
