#!/bin/bash
# Actual iOS screens; loopback providers only; a NEW disposable simulator.
set -u -o pipefail
FAIL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)" || exit 1
TEST_DIR="$(mktemp -d /tmp/rendprop-phase1-network.XXXXXX)" || exit 1
SERVER_PID=""
SIMULATOR_ID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    if [ -n "$SIMULATOR_ID" ]; then xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

if ! ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
    -i 'testsrc2=s=640x480:r=30:d=5' -c:v libx264 -profile:v baseline \
    -level:v 3.0 -bf 0 -pix_fmt yuv420p -tag:v avc1 -brand mp42 \
    -movflags +faststart "$TEST_DIR/clip.mp4"; then FAIL=1; fi

if [ "$FAIL" -eq 0 ]; then
    node "$SCRIPT_DIR/fixture-server.mjs" 18765 "$TEST_DIR/clip.mp4" > "$TEST_DIR/server.log" 2>&1 &
    SERVER_PID=$!
    # Assert readiness and ownership. A server already occupying this port must
    # not be mistaken for the process this script started.
    sleep 1
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then FAIL=1; fi
    if ! node --input-type=module -e '
        const r = await fetch("http://127.0.0.1:18765/__control/state");
        const d = await r.json();
        if (!r.ok || d.blocked !== true || d.accepted !== 0) process.exit(1);
    '; then FAIL=1; fi
fi

if [ "$FAIL" -eq 0 ]; then
    SIMULATOR_ID="$(xcrun simctl create 'Rendprop Session Regression' \
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
        com.apple.CoreSimulator.SimRuntime.iOS-26-4)" || FAIL=1
fi
if [ "$FAIL" -eq 0 ]; then
    if ! xcodebuild -project "$REPO_DIR/apps/ios/Rendprop.xcodeproj" -scheme Rendprop \
        -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
        -derivedDataPath "$TEST_DIR/DerivedData" \
        -only-testing:RendpropUITests/SessionNetworkFlow -parallel-testing-enabled NO \
        CODE_SIGNING_ALLOWED=NO -resultBundlePath "$TEST_DIR/results.xcresult" \
        test > "$TEST_DIR/tests.log" 2>&1; then FAIL=1; fi
fi

echo "Phase 1 network verification status: $FAIL"
echo "Retained evidence: $TEST_DIR"
echo "Retained, shut-down test simulator: $SIMULATOR_ID"
exit "$FAIL"
