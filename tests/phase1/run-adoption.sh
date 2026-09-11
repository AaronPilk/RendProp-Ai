#!/bin/bash
# Offline production-core execution. Does not build/install an iOS app.
set -u -o pipefail
FAIL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)" || exit 1
OUT="$(mktemp -d /tmp/rendprop-adoption-swift.XXXXXX)" || exit 1
SOURCE="$REPO_DIR/apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift"
TEST="$SCRIPT_DIR/AnonymousAdoptionRecoveryTests.swift"
if ! rg -q 'final class AnonymousAdoptionRecovery' "$SOURCE"; then FAIL=1; fi
if ! rg -q 'recovery.prepare\(' "$REPO_DIR/apps/ios/Rendprop/Auth/AuthStore.swift"; then FAIL=1; fi
if [ "$FAIL" -ne 0 ]; then echo 'FAIL: source symbols missing'; exit "$FAIL"; fi
if ! xcrun swiftc -parse-as-library "$SOURCE" "$TEST" -o "$OUT/adoption-tests" > "$OUT/compile.log" 2>&1; then
    FAIL=1
else
    negative=0
    "$OUT/adoption-tests" --force-failure > "$OUT/negative.log" 2>&1 || negative=$?
    if [ "$negative" -ne 1 ]; then FAIL=1; fi
    if ! "$OUT/adoption-tests" > "$OUT/swift.log" 2>&1; then FAIL=1; fi
fi
if ! node --test "$SCRIPT_DIR/adoption-source.test.mjs" > "$OUT/source.log" 2>&1; then FAIL=1; fi
if ! node --test "$SCRIPT_DIR/adoption-negative.test.mjs" > "$OUT/mutants.log" 2>&1; then FAIL=1; fi
if ! node --test "$SCRIPT_DIR/adoption-local-bindings.test.mjs" > "$OUT/local-bindings.log" 2>&1; then FAIL=1; fi
echo "Adoption evidence: $OUT"
echo "Adoption portable gate exit: $FAIL"
exit "$FAIL"
