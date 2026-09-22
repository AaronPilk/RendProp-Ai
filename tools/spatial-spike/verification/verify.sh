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
if ! rg -q 'Float\(1\).nextUp' "$spatial_verify_dir/main.swift"; then fail 'missing actual Float32 roundoff fixture'; fi
if ! rg -q 'rasterWriter.write' "$spatial_verify_dir/main.swift"; then fail 'missing actual JPEG writer call'; fi
if ! "$spatial_python" -c 'import sys; sys.exit(0 if __debug__ else "FAIL: Python optimization disables contract assertions")'; then fail 'Python assertions must be enabled'; fi
if ! "$spatial_python" -c 'from PIL import Image'; then fail 'Python requires the adapter Pillow environment'; fi
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi

spatial_work_dir="$(mktemp -d /tmp/rendprop-spatial-interop.XXXXXX)"
if [ ! -d "$spatial_work_dir" ]; then fail 'could not create artifact directory'; exit "$FAIL"; fi
spatial_positive="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-valid"
spatial_negative="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-transposed"
spatial_dataset="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-dataset"
spatial_roundoff="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-roundoff"
spatial_roundoff_dataset="$spatial_work_dir/SYNTHETIC-NOT-A-ROOM-roundoff-dataset"

if ! swiftc "$spatial_capture_sources/CaptureModel.swift" "$spatial_capture_sources/RasterWriter.swift" "$spatial_verify_dir/main.swift" -o "$spatial_work_dir/synthetic-capture"; then
    fail 'actual Swift capture model/raster sources did not compile'
fi
if [ "$FAIL" -eq 0 ]; then
    # Prove the known invalid data is rejected before trusting the valid case.
    if ! "$spatial_work_dir/synthetic-capture" "$spatial_negative" --transpose-first-pose; then fail 'negative fixture generation failed'; fi
    spatial_negative_status=0
    "$spatial_python" "$spatial_adapter" "$spatial_negative" >"$spatial_work_dir/negative.stdout" 2>"$spatial_work_dir/negative.stderr" || spatial_negative_status=$?
    if [ "$spatial_negative_status" -ne 1 ]; then
        fail 'Python must reject a transposed camera pose with exit 1'
    elif ! rg -q 'invalid homogeneous row' "$spatial_work_dir/negative.stderr"; then
        fail 'negative fixture failed for the wrong reason'
    fi
    if ! "$spatial_work_dir/synthetic-capture" "$spatial_positive"; then fail 'valid Swift fixture generation failed'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_positive" >"$spatial_work_dir/validation.json"; then fail 'Python rejected actual valid Swift output'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_positive" --output "$spatial_dataset" >"$spatial_work_dir/preparation.json"; then fail 'Python preparation failed'; fi
    if ! "$spatial_python" "$spatial_verify_dir/check_contract.py" "$spatial_positive" "$spatial_dataset"; then fail 'binary export contract assertions failed'; fi

    # Preserve the canonical golden fixture/checker, then test a separate real
    # Swift-serialized Float32 residual against the same binary expectations.
    if ! "$spatial_work_dir/synthetic-capture" "$spatial_roundoff" --pose-roundoff; then fail 'roundoff Swift fixture generation failed'; fi
    if ! spatial_roundoff_before="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_roundoff")"; then fail 'roundoff source fingerprint failed'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_roundoff" >"$spatial_work_dir/roundoff-validation.json"; then fail 'Python rejected actual Swift Float32 roundoff'; fi
    if ! "$spatial_python" "$spatial_adapter" "$spatial_roundoff" --output "$spatial_roundoff_dataset" >"$spatial_work_dir/roundoff-preparation.json"; then fail 'roundoff Python preparation failed'; fi
    if ! "$spatial_python" - "$spatial_adapter" "$spatial_roundoff" "$spatial_dataset" "$spatial_roundoff_dataset" <<'PY'
import json
from pathlib import Path
import struct
import sys

if not __debug__:
    raise SystemExit('FAIL: Python optimization disables roundoff contract assertions')

adapter_path, source, canonical_dataset, roundoff_dataset = map(Path, sys.argv[1:])
sys.path.insert(0, str(adapter_path.parent))
from prepare_capture import load_capture, validate_pose, world_to_cv

manifest = json.loads((source / 'manifest.json').read_text())
assert 'SYNTHETIC-NOT-A-ROOM' in manifest['device_model']
before = {relative: (source / relative).read_bytes() for relative in manifest['frames']}
capture = load_capture(source)
assert len(capture['frames']) == 20 and len(capture['seeds']) == 120
next_up_one = struct.unpack('<f', struct.pack('<I', 0x3f800001))[0]
assert next_up_one == 1.00000011920928955078125
for relative, frame in zip(manifest['frames'], capture['frames']):
    raw = json.loads(before[relative])
    pose = raw['camera_to_world']
    assert pose[3] == [0, 0, 0, next_up_one]
    assert pose[3] != [0, 0, 0, 1], 'The noncanonical Swift fixture must actually be exercised'
    # Snapshot bytes BEFORE validation: chained equality can pass after a buggy
    # in-place normalizer mutates both the input and returned matrix together.
    pose_bytes = struct.pack('<16d', *(value for row in pose for value in row))
    assert struct.pack('<16d', *(value for row in frame['pose'] for value in row)) == pose_bytes, 'load_capture changed the raw pose'
    validated = validate_pose(pose)
    assert struct.pack('<16d', *(value for row in pose for value in row)) == pose_bytes, 'validate_pose mutated its input'
    assert struct.pack('<16d', *(value for row in validated for value in row)) == pose_bytes, 'validate_pose normalized its output'
    assert frame['intrinsics'] == raw['intrinsics'], 'Do not alter raw calibration'
    rotation, translation = world_to_cv(frame['pose'])
    assert rotation == [[1, 0, 0], [0, -1, 0], [0, 0, -1]]
    assert translation == [-pose[0][3], 0, 0], 'Do not divide translation by homogeneous w'
    assert (source / relative).read_bytes() == before[relative]
    assert (roundoff_dataset / raw['image']).read_bytes() == (source / raw['image']).read_bytes()
# The canonical dataset already passed the existing independent binary parser
# assertions above. Equality here extends every record/EOF check to roundoff.
for name in ('cameras.bin', 'images.bin', 'points3D.bin'):
    assert (roundoff_dataset / 'sparse/0' / name).read_bytes() == (canonical_dataset / 'sparse/0' / name).read_bytes(), name
report = json.loads((roundoff_dataset / 'adapter-report.json').read_text())
assert report['frames'] == 20 and report['initial_points'] == 120
assert report['gpu_training_performed'] is False and report['reprojection_error_measured'] is False
print('PASS: actual Swift Float(1).nextUp -> raw JSON preserved -> real Python validation -> identical calibrated binary world-to-CV dataset; SYNTHETIC ONLY')
PY
    then
        fail 'roundoff raw-preservation or binary contract assertions failed'
    fi
    if ! spatial_roundoff_after="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_roundoff")"; then fail 'roundoff final fingerprint failed'; fi
    if [ -z "$spatial_roundoff_before" ] || [ "$spatial_roundoff_before" != "$spatial_roundoff_after" ]; then fail 'Python validation/export changed raw Swift roundoff capture bytes'; fi

    spatial_before="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_positive")"
    if "$spatial_work_dir/synthetic-capture" "$spatial_positive" >"$spatial_work_dir/existing.stdout" 2>"$spatial_work_dir/existing.stderr"; then fail 'Swift overwrote an existing output directory'; fi
    if ! rg -q 'Output must not already exist' "$spatial_work_dir/existing.stderr"; then fail 'existing output refusal has wrong reason'; fi
    spatial_after="$("$spatial_python" "$spatial_verify_dir/check_contract.py" --fingerprint "$spatial_positive")"
    if [ -z "$spatial_before" ] || [ "$spatial_before" != "$spatial_after" ]; then fail 'existing output was changed'; fi
fi
echo "Synthetic interop artifacts preserved at $spatial_work_dir"
if [ "$FAIL" -eq 0 ]; then echo 'PASS: Swift-to-Python synthetic capture contract; no room or GPU training'; fi
exit "$FAIL"
