#!/bin/bash
# Offline only. Executes production SessionConnection source, not a reimplementation.
set -u -o pipefail
FAIL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)" || exit 1
TEST_DIR="$(mktemp -d /tmp/rendprop-phase1-unit.XXXXXX)" || exit 1
if ! xcrun swiftc -parse-as-library \
    "$REPO_DIR/apps/ios/Rendprop/Auth/SessionConnection.swift" \
    "$SCRIPT_DIR/SessionConnectionTests.swift" -o "$TEST_DIR/session-tests"; then
    FAIL=1
elif ! "$TEST_DIR/session-tests"; then
    FAIL=1
fi
# Retain the test binary for inspection; no recursive cleanup/destructive command.
echo "Phase 1 unit verification status: $FAIL"
exit "$FAIL"
