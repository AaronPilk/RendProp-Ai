#!/bin/bash
# Offline only. Executes production SessionConnection and Coach source.
set -u -o pipefail
FAIL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)" || exit 1
TEST_DIR="$(mktemp -d /tmp/rendprop-phase1-unit.XXXXXX)" || exit 1
if ! rg -q 'struct CoachOfflineTests' "$SCRIPT_DIR/CoachOfflineTests.swift"; then FAIL=1; fi
if ! rg -q 'No account is required to record, edit, build or publish a tour' "$REPO_DIR/apps/ios/Rendprop/Coach/CoachModel.swift"; then FAIL=1; fi
if [ "$FAIL" -ne 0 ]; then echo 'FAIL: required production copy/test symbols missing' >&2; exit "$FAIL"; fi
if ! xcrun swiftc -parse-as-library \
    "$REPO_DIR/apps/ios/Rendprop/Auth/SessionConnection.swift" \
    "$SCRIPT_DIR/SessionConnectionTests.swift" -o "$TEST_DIR/session-tests"; then
    FAIL=1
elif ! "$TEST_DIR/session-tests"; then
    FAIL=1
fi
if ! xcrun swiftc -parse-as-library \
    "$REPO_DIR/apps/ios/Rendprop/Coach/CoachAPI.swift" \
    "$REPO_DIR/apps/ios/Rendprop/Coach/CoachModel.swift" \
    "$SCRIPT_DIR/CoachOfflineTests.swift" -o "$TEST_DIR/coach-tests"; then
    FAIL=1
else
    negative_status=0
    "$TEST_DIR/coach-tests" --force-failure || negative_status=$?
    if [ "$negative_status" -ne 1 ]; then
        echo 'FAIL: actual offline Coach negative control must exit 1' >&2
        FAIL=1
    fi
    if ! "$TEST_DIR/coach-tests"; then FAIL=1; fi
fi
# Retain the test binary for inspection; no recursive cleanup/destructive command.
echo "Phase 1 unit artifacts: $TEST_DIR"
echo "Phase 1 unit verification status: $FAIL"
exit "$FAIL"
