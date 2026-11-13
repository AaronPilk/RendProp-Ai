# Retained Original gallery disclosure regression

Run `python3 tools/audit/gallery-original-disclosure-20261015/run.py --output-dir /tmp/gallery-original-proof`.

This compiles the actual `syncGalleryPhotos` and `EnhancedPhoto` readers with the real photo history, capture storage and disclosure helper. Upload/API boundaries and all files are isolated synthetic fixtures; no phone, hosted write or paid AI is used.

The retained `capture-original` must reach the gallery update without an AI provenance record. Its canonical family identity, verified capture ancestry, actual file paths, regular-file status, byte ceiling and streamed SHA are checked. The source must remain identical after upload and before the selection request. Edited descendants and another selected edit with missing provenance remain blocked.

Four temporary source mutations must compile and fail their named runtime assertion: restore the old Original guard, omit effects validation, omit parent validation, or omit SHA equality. Existing sync identity, cancellation, stale-selection, append, provenance failure and immutable-file checks execute in the same fixture. The receipt binds source hashes and the extracted sync body.

The SHA certifies the selected retained file during this synchronization. Existing history records do not contain a historical capture SHA; this does not invent one or certify an arbitrary old filename as an untouched capture.
