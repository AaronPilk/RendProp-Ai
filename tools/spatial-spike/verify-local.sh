#!/bin/bash
# This gate proves local tooling, never a physical capture or CUDA training run.
set -u -o pipefail
FAIL=0
SPATIAL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SPATIAL_PYTHON="${SPATIAL_PYTHON:-python3}"
SPATIAL_BUILD=1
if [ "$#" -gt 1 ]; then echo 'FAIL: expected only optional --no-build.' >&2; exit 1; fi
case "${1:-}" in
    '') ;;
    --no-build) SPATIAL_BUILD=0 ;;
    *) echo 'FAIL: unknown argument; only --no-build is supported.' >&2; exit 1 ;;
esac

if ! command -v "$SPATIAL_PYTHON" >/dev/null 2>&1; then
    echo 'FAIL: SPATIAL_PYTHON must point to an interpreter with requirements-adapter.txt installed.' >&2
    FAIL=1
fi
# Missing code must fail before any compiler can produce a misleading green.
if ! rg -q 'final class CaptureRecorder' "$SPATIAL_ROOT/capture-ios/Sources/CaptureRecorder.swift"; then FAIL=1; fi
if ! rg -q 'def world_to_cv' "$SPATIAL_ROOT/training/prepare_capture.py"; then FAIL=1; fi
if ! rg -q 'def bounded_process' "$SPATIAL_ROOT/training/run_training.py"; then FAIL=1; fi
if ! rg -q 'def inspect_capture' "$SPATIAL_ROOT/training/capture_handoff.py"; then FAIL=1; fi
if ! rg -q 'export class RenderBenchmark' "$SPATIAL_ROOT/viewer/benchmark.mjs"; then FAIL=1; fi
if ! rg -q 'CaptureGeometry.rows\(c2w\)' "$SPATIAL_ROOT/verification/main.swift"; then FAIL=1; fi

if [ "$FAIL" -eq 0 ]; then
    if ! "$SPATIAL_PYTHON" -m unittest discover -s "$SPATIAL_ROOT/training" -p 'test_*.py' -v; then FAIL=1; fi
    negative_status=0
    node "$SPATIAL_ROOT/viewer/benchmark.test.mjs" --negative-control || negative_status=$?
    if [ "$negative_status" -ne 1 ]; then
        echo 'FAIL: an empty renderer must fail the deliberate success claim with exit 1.' >&2
        FAIL=1
    fi
    if ! node --test "$SPATIAL_ROOT/viewer/benchmark.test.mjs" "$SPATIAL_ROOT/viewer/viewer-input.test.mjs" "$SPATIAL_ROOT/viewer/input-policy.test.mjs"; then FAIL=1; fi
    if [ "$SPATIAL_BUILD" -eq 1 ]; then
        if ! bash "$SPATIAL_ROOT/capture-ios/verify.sh" --build; then FAIL=1; fi
    else
        if ! bash "$SPATIAL_ROOT/capture-ios/verify.sh"; then FAIL=1; fi
    fi
    if ! bash "$SPATIAL_ROOT/verification/verify.sh" "$SPATIAL_PYTHON"; then FAIL=1; fi
fi

if [ "$FAIL" -eq 0 ]; then
    if [ "$SPATIAL_BUILD" -eq 1 ]; then
        echo 'PASS: local tests and unsigned capture build only. Real-room Phase A is still unverified.'
    else
        echo 'PASS: portable local tests only; no Xcode/app build. Real-room Phase A is still unverified.'
    fi
else
    echo 'FAIL: local verification did not pass.' >&2
fi
exit "$FAIL"
