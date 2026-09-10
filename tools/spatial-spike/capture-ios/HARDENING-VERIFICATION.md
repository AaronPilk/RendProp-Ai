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

The geometry, native raster encoding operations, capture schema, AR recorder and
lifecycle policy are unchanged. Recording/interrupted crash manifests already
fail export; closing during an explicit pending save intentionally lets that save drain, so no
speculative crash-status rewrite or new resume behavior was added.

## JPEG boundary follow-up

The original JPEG validator's metadata checks were extracted, unchanged, into
`validatedJPEGSource` before adding resource limits. Running the new
`Tests/JPEGResourceChecks.swift` against that pre-fix boundary returned **exit 1:
1 passed, 3 failed, 0 skipped**: it accepted a valid native JPEG padded to one byte
beyond 64 MiB, an 8193×1 header, and an 8192×8192 header. The fixtures were small
synthetic native JPEGs with sparse padding or edited start-of-frame metadata;
**no excessive raster was decoded**, including in the known-failure run.

The follow-up adds these explicit Phase A limits:

- 8192 per axis; 16,777,216 total pixels, checked without multiplication overflow.
- 64 MiB encoded JPEG, read in at-most-1-MiB chunks and rejected at cap + 1 before
  creating an ImageIO source. Read-limit overflow/negative limits fail closed.
- Non-decoding metadata preflight (`kCGImageSourceShouldCache: false`) requires
  one JPEG, 8-bit depth, orientation 1 and exact calibrated dimensions. Metadata
  dimensions have their own resource check even if the sidecar claims a small
  size. Only then does full decode run; decoded dimensions/depth are rechecked.

The 1920-wide/30-fps preference is unchanged. The selected ARKit video format is
now guarded before `session.run`; the shared dimension policy also runs before
encoding and during frame validation. Policy positives cover 1920×1080,
1920×1440, 3840×2160, 4032×3024 and exact-cap dimensions without allocating those
rasters. The SDK does not promise a numeric maximum for device-specific default
formats; a default exceeding the explicit limits fails visibly rather than
recording an unexportable/resized capture. Universal future-format compatibility
is not claimed. 64 MiB is a generous four-encoded-bytes-per-permitted-pixel bound
for the existing quality-0.92 encoder, not a promise about process memory.

## Verification

Run from repository root:

```sh
bash tools/spatial-spike/capture-ios/verify.sh
```

The gate checks landed symbols, requires its deliberate failure to return exit 1,
runs **115 portable assertions**, rejects ten invalid UI-summary controls, then
runs **7 adversarial cases and 8 JPEG resource cases, each with 0 failures and
0 skips**. The JPEG runner also requires an unknown-case control to exit 1.
The assertions include the maximum 50,000-point cloud under the 16 MiB bound,
native format/pixel boundaries, and malformed/overflowing integer limits. JPEG
cases include the exact byte boundary, over-bound encoded data, declared and
metadata-only excessive axes/pixels, and a metadata/calibration size mismatch.
The complete gate must exit 0. Shell syntax and scoped `git diff --check` are also
required; this run does not use `--build`.
The final full run exited 0; its output is
`/tmp/spatial-jpeg-final.tz0kyQ/verify.log` and compiled binaries are in
`/tmp/spatial-capture-verify.MZGzc1/` (`capture-tests`, `adversarial-checks`,
`jpeg-resource-checks`). These temporary evidence paths may expire.

An independent reviewer reran the actual final binaries: 115 assertions,
7 adversarial cases and 8 JPEG cases passed; all three deliberate failure
controls returned exit 1. No blocking finding remained in that narrow review.

The parent task also completed this targeted local SDK check with **exit 0 and
empty diagnostics** for all seven capture sources:

```sh
xcrun swiftc -typecheck -parse-as-library -target arm64-apple-ios16.0-simulator \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.4.sdk \
  -module-cache-path /tmp/rendprop-spatial-integration.sLQDuM/DerivedData/ModuleCache.noindex \
  tools/spatial-spike/capture-ios/Sources/App.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureArchive.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureControls.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureModel.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureRecorder.swift \
  tools/spatial-spike/capture-ios/Sources/RasterWriter.swift \
  tools/spatial-spike/capture-ios/Sources/SpatialCaptureViewController.swift
```

The empty typecheck log is
`/tmp/rendprop-market-verification.GnutHA/capture-ios-sdk-typecheck.log`.
This is **not** an app link, Xcode build, simulator launch, device run or archive.

Physical iPhone capture, actual interruption scheduling, thermal/memory behavior,
GPU training and phone-browser rendering remain unproven by these tests. File
checks are not an atomic snapshot or an active-adversary TOCTOU guarantee. Any
future integrated build/release remains separately coordinated and unperformed
here; this hardening is not installed in the delivered TestFlight build.
The JPEG limits bound encoded input and permitted raster dimensions, not every
internal decoder allocation or total process memory. Local SDK typechecking does
not prove physical validation or an integrated app build; neither was run here.
