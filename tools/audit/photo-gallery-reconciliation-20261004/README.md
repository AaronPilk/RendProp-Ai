# Photo gallery reconciliation and publication review — 2026-10-04

This suite compiles the real `PhotoVersionHistory.swift`, `PhotoCaptureStorage.swift` and `PhotoVersionHistoryTests.swift` with Foundation and requires its exact 415-assertion success result. It uses synthetic non-empty byte files, not camera capture, paid AI, customer photos or a cloud mutation.

```sh
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault drop-legacy-reconciliation
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault bypass-stage-review
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault latest-as-cover
python3 tools/audit/photo-gallery-reconciliation-20261004/run.py --inject-fault blank-family-badges
```

The positive fixture has three pre-history `enh-*` siblings and independently performs the first new capture, first edit, and first removal. All untouched siblings remain selected; removing one family leaves the other two. All predecessor and source bytes remain unchanged. Legacy adoption retains `originalVerified: false` and `sourceHistoryKnown: false`; a filename never certifies an unaltered source. Unknown `edit-*`/`cloud-photo-*` outputs do not enter the legacy scanner. A corrupt index still stops publication rather than silently clearing or replacing a cloud gallery.

Further cases verify retained declutter/staging libraries, a hidden earlier cover resolved by family, fallback chosen from the actual approved selection instead of the latest staging workspace, individual family badges even when selected bytes are unavailable, staged imports with a retained source, explicit review at both selection APIs, and no resurrection after removal. Staged cloud import is a local preview until review; its retained earlier source remains explicitly unverified.

The positive command also extracts and executes the actual `AppModel.syncGalleryPhotos` body and actual `EnhancedPhoto.loadForListing`, with isolated asynchronous upload/API boundaries. Its 77 assertions include the real gallery API asset IDs and selected cover for a three-sibling initial visit, first capture, first edit and first removal; the existing held upload/API, identity, cancellation, stale selection, append, provenance and immutable-file checks remain. An unreviewed staged cover makes no upload or publication call; explicit review with a recorded provenance links the actual selected asset. Missing selected bytes preserve the earlier server gallery.

Each negative control mutates a temporary copy of the production implementation, successfully compiles, and must reach its named runtime assertion. Setup/compiler failures never count as fault detection. `--output-dir` can preserve receipts and compile/runtime logs; the default is a private temporary directory. Receipts bind the checked-in implementation and test hashes. The runner fails if positive assertions or expected runtime rejection differ.

Native coverage lives in `RendpropUITests/BetaPolishUITests`: `testLegacyGalleryKeepsSiblingsAndStagedCoverRequiresReview` and `testSavedDeclutterAndStagingLibrariesKeepDownloadsAndListingChoiceSeparate`. They drive actual SwiftUI on a dedicated simulator with three procedural legacy photo pairs, no pre-adoption fixture shortcut. They check first removal, legacy cover selection, staged cover review, fallback, and the exact Photos and listing file-grid badges. The native fixture uses MockAPIClient and cannot make a provider call or claim physical-camera quality.

Cloud media currently supplies staged/altered flags but no provenance identifier. An imported edited output is therefore kept as a truthful local preview; the publication service still requires a verified server provenance binding before republishing edited bytes. Selecting/exporting its earlier source does not invent that binding. This audit does not remove the publication disclosure gate.
