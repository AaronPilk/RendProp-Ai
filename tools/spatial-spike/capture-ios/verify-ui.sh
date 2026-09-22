#!/bin/bash
set -uo pipefail
FAIL=0
mark_failure() { echo "FAIL: $*" >&2; FAIL=1; }
if ! cd "$(dirname "$0")"; then mark_failure 'cannot enter capture harness directory'; exit "$FAIL"; fi
if [ "$#" -ne 1 ]; then mark_failure 'supply the UUID of a dedicated disposable simulator'; exit "$FAIL"; fi
spike_simulator="$1"
if ! rg -q 'testUnsupportedStartDoesNotRequestCameraOrClaimCapture' UITests/SpatialCaptureUITests.swift; then
    mark_failure 'asserting unsupported-device test did not land'; exit "$FAIL"
fi
if ! rg -q 'private var arView: ARView\?' Sources/SpatialCaptureViewController.swift; then
    mark_failure 'lazy AR preview implementation did not land'; exit "$FAIL"
fi
if ! ruby verify-ui-summary.rb --self-test; then mark_failure 'UI summary negative-control checks failed'; exit "$FAIL"; fi
if ! spike_ui_dir=$(mktemp -d /tmp/spatial-capture-ui.XXXXXX); then mark_failure 'cannot create test output directory'; exit "$FAIL"; fi
if ! xcodegen generate; then mark_failure 'project generation failed'; exit "$FAIL"; fi
if ! xcodebuild test -quiet -configuration Release -project SpatialSpikeCapture.xcodeproj -scheme SpatialSpikeCapture \
    -destination "platform=iOS Simulator,id=$spike_simulator" \
    -only-testing:SpatialSpikeCaptureUITests/SpatialCaptureUITests \
    -parallel-testing-enabled NO -derivedDataPath "$spike_ui_dir/DerivedData" \
    -resultBundlePath "$spike_ui_dir/results.xcresult" CODE_SIGNING_ALLOWED=NO; then
    mark_failure 'asserting capture UI tests failed'; exit "$FAIL"
fi
if ! xcrun xcresulttool get test-results summary --path "$spike_ui_dir/results.xcresult" | ruby verify-ui-summary.rb; then
    mark_failure 'UI result summary did not prove the complete expected test set'
fi
if [ "$FAIL" -eq 0 ]; then echo "UI evidence: $spike_ui_dir/results.xcresult"; fi
exit "$FAIL"
