#!/bin/bash
# This harness accumulates failures and exits with that status. Every artifact is
# synthetic; no source, existing capture, network service, or GPU is modified.
set -u -o pipefail
FAIL=0
spatial_verify_dir="$(cd "$(dirname "$0")" && pwd)"
spatial_python="${1:-python3}"
spatial_capture_sources="$spatial_verify_dir/../capture-ios/Sources"
spatial_adapter="$spatial_verify_dir/../training/prepare_capture.py"
fail() { echo "FAIL: $1" >&2; FAIL=1; }

if [ "${2:-}" = '--force-failure' ]; then
    fail 'intentional harness negative control'
    exit "$FAIL"
fi

# Inspect source symbols before compiling so a green build cannot cover missing
# implementation. No grep-count/default fallback can swallow a zero here.
if ! rg -q 'struct FrameRecord: Codable' "$spatial_capture_sources/CaptureModel.swift"; then fail 'missing actual FrameRecord'; fi
if ! rg -q 'final class NativeRasterWriter' "$spatial_capture_sources/RasterWriter.swift"; then fail 'missing actual NativeRasterWriter'; fi
if ! rg -q 'CaptureGeometry.rows\(c2w\)' "$spatial_verify_dir/main.swift"; then fail 'missing actual pose serializer call'; fi
if ! rg -q 'rasterWriter.write' "$spatial_verify_dir/main.swift"; then fail 'missing actual JPEG writer call'; fi
if ! "$spatial_python" -c 'from PIL import Image'; then fail 'Python requires the adapter Pillow environment'; fi
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi

spatial_work_dir="$(mktemp -d /tmp/rendprop-spatial-interop.XXXXXX)"
if [ ! -d "$spatial_work_dir" ]; then fail 'could not create artifact directory'; exit "$FAIL"; fi
spatial_positive="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-valid"
spatial_negative="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-transposed"
spatial_dataset="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-dataset"

if ! swiftc "$spatial_capture_sources/CaptureModel.swift" "$spatial_capture_sources/RasterWriter.swift" "$spatial_verify_dir/main.swift" -o "$spatial_work_dir/synthetic-capture"; then
    fail 'actual Swift capture model/raster sources did not compile'
fi
if [ "$FAIL" -eq 0 ]; then
    # Prove the known invalid data is rejected before trusting the valid case.
    if ! "$spatial_work_dir/synthetic-capture" "$spatial_negative" --transpose-first-pose; then fail 'negative fixture generation failed'; fi
    if "$spatial_python" "$spatial_adapter" "$spatial_negative" >"$spatial_work_dir/negative.stdout" 2>"$spatial_work_dir/negative.stderr"; then
        fail 'Python accepted a transposed camera pose'
    elif ! rg -q 'invalid homogeneous row' "$spatial_work_dir/negative.stderr"; then
        fail 'negative fixture failed for the wrong reason'
    fi
    if ! "$spatial_work_dir/synthetic-capture" "$spatial_positive"; then fail 'valid Swift fixture generation failed'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_positive" >"$spatial_work_dir/validation.json"; then fail 'Python rejected actual valid Swift output'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_positive" --output "$spatial_dataset" >"$spatial_work_dir/preparation.json"; then fail 'Python preparation failed'; fi
    if ! "$spatial_python" "$spatial_verify_dir/check_contract.py" "$spatial_positive" "$spatial_dataset"; then fail 'binary export contract assertions failed'; fi

    spatial_before="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_positive")"
    if "$spatial_work_dir/synthetic-capture" "$spatial_positive" >"$spatial_work_dir/existing.stdout" 2>"$spatial_work_dir/existing.stderr"; then fail 'Swift overwrote an existing output directory'; fi
    if ! rg -q 'Output must not already exist' "$spatial_work_dir/existing.stderr"; then fail 'existing output refusal has wrong reason'; fi
    spatial_after="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_positive")"
    if [ -z "$spatial_before" ] || [ "$spatial_before" != "$spatial_after" ]; then fail 'existing output was changed'; fi
fi
echo "Synthetic interop artifacts preserved at $spatial_work_dir"
if [ "$FAIL" -eq 0 ]; then echo 'PASS: Swift-to-Python synthetic capture contract; no room or GPU training'; fi
exit "$FAIL"
