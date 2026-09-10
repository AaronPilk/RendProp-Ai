# Local capture hardening — 2026-09-10

Scope: isolated `fix/spatial-capture-hardening-20260910`, based on delivered
`afa6923`. No Apple/App Store Connect/TestFlight actions, network/live-account
calls, simulator/device builds, deployment, real capture, or data deletion.

## Reproduced before fixing

The unchanged portable gate passed 99 assertions and its negative controls.
`Tests/AdversarialChecks.swift` was then added without changing implementation.
Compiling it against the original `CaptureModel.swift` + `RasterWriter.swift` and
running it returned **exit 1: 1 passed, 6 failed, 0 skipped**. A normal 20-frame
synthetic fixture passed; the validator wrongly accepted:

- An expected sidecar symlink outside its capture directory.
- An expected JPEG symlink outside its capture directory.
- A symlink replacing the entire frames directory.
- An extra unreferenced symlink that whole-folder export could also copy.
- A valid JSON sidecar padded beyond 16 MiB.
- A valid JSON manifest padded beyond 256 KiB.

All targets were newly generated temporary synthetic files, not user data.

## Narrow fixes

`NativeRasterWriter` now checks regular files and exact directory contents before
full export validation, bounds JSON reads before decoding, and enforces the
existing 400-frame cap on its direct validation entry point. `CaptureArchive`
shares the bounded manifest reader. Files are refused/preserved, never deleted.
Directory enumeration uses traversal depth to handle Foundation's differing
`/var` and `/private/var` aliases without resolving and hiding child symlinks.

The geometry, native raster encoder, capture schema, AR recorder and lifecycle UI
are unchanged. Recording/interrupted crash manifests already fail export; closing
during an explicit pending save intentionally lets that save drain, so no
speculative crash-status rewrite or new resume behavior was added.

## Verification

Run from repository root:

```sh
bash tools/spatial-spike/capture-ios/verify.sh
```

The gate checks landed symbols, requires its deliberate failure to return exit 1,
runs **101 portable assertions**, rejects ten invalid UI-summary controls, then
runs **7 adversarial cases with 0 failures and 0 skips**. The two added positive
assertions encode/decode the maximum 50,000-point cloud under the 16 MiB bound.
The complete gate must exit 0. Shell syntax and scoped `git diff --check` are also
required; this run does not use `--build`.

Physical iPhone capture, actual interruption scheduling, thermal/memory behavior,
GPU training and phone-browser rendering remain unproven by these tests. File
checks are not an atomic snapshot or an active-adversary TOCTOU guarantee. Any
future integrated build/release remains separately coordinated and unperformed
here; this hardening is not installed in the delivered TestFlight build.
ImageIO's existing JPEG decode path has no new encoded-byte or pixel-count bound
in this patch; do not describe the JSON limits as bounding every image resource.
