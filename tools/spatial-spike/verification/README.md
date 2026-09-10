# Swift → Python serialization integration check

This macOS CLI compiles the **actual** `capture-ios/Sources/CaptureModel.swift`
and `RasterWriter.swift`, writes twenty JPEGs through `NativeRasterWriter`,
serializes twenty `FrameRecord` sidecars and a `CaptureManifest` with Swift's
`JSONEncoder`, and passes those files to the actual Python `prepare_capture.py`.
It does not substitute Python-generated metadata for the Swift output.

Every fixture and dataset is explicitly **SYNTHETIC — NOT A ROOM**. No phone,
ARSession, reconstruction, GPU, cloud service, customer data, or benchmark is
involved. macOS is required because the actual raster writer uses Apple CoreImage
and ImageIO. Xcode Command Line Tools provide `swiftc`; the Python environment
needs the training adapter's pinned Pillow dependency.

```sh
# First prove the harness itself exits nonzero on a known failure:
bash verify.sh /path/to/adapter-venv/bin/python --force-failure
# That must fail. Then run the real interop checks:
bash verify.sh /path/to/adapter-venv/bin/python
```

The harness checks source symbols before compiling, accumulates `FAIL=1`, and
finishes with `exit "$FAIL"`. It first generates a separate fixture with a
transposed first camera matrix, which both Swift and Python must reject. It then
generates the valid capture, runs Python validation and preparation, and asserts:

- Twenty real JPEGs with explicit EXIF orientation 1 and 160×120 calibration.
- Normal tracking; twenty translated camera poses with about 9.5 cm radius.
- 120 distinct visible synthetic 3D points, observed 2,400 times.
- Canonical string IDs near `UInt64.max`, with every digit retained.
- Exported camera intrinsics and camera-to-world conversion have the expected
  mathematical values in the actual binary dataset.
- The 3D world is unchanged, JPEG bytes are unchanged, hashes agree, and no
  invented feature tracks or measured reprojection error appear.
- An existing output directory is refused without modifying its contents.

Artifacts and logs remain in the printed temporary directory. The negative and
positive captures are separate and never rewritten. To run only the fixture CLI,
compile as the harness does and pass a **new** output-directory path whose parent
already exists. Directory creation fails atomically if that path already exists.

Passing this check proves compatibility of serialization, raster writing, and
dataset preparation. It does not prove ARKit pose accuracy, real-room coverage,
Gaussian training quality, SOG visual quality, or physical-phone performance.
