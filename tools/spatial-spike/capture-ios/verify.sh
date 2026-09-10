#!/bin/bash
set -uo pipefail
FAIL=0
mark_failure() { echo "FAIL: $*" >&2; FAIL=1; }
if ! cd "$(dirname "$0")"; then mark_failure 'cannot enter capture harness directory'; exit "$FAIL"; fi
# Check that edits landed before either compiling a test or building the app.
rg -q 'final class CaptureRecorder' Sources/CaptureRecorder.swift || mark_failure 'CaptureRecorder symbol missing'
rg -q 'final class NativeRasterWriter' Sources/RasterWriter.swift || mark_failure 'NativeRasterWriter symbol missing'
rg -q 'raw_feature_points' Sources/CaptureModel.swift || mark_failure 'feature point schema missing'
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi
if ! spike_verify_dir=$(mktemp -d /tmp/spatial-capture-verify.XXXXXX); then mark_failure 'cannot create isolated verification directory'; exit "$FAIL"; fi
if ! swiftc Sources/CaptureModel.swift Sources/RasterWriter.swift Tests/main.swift -o "$spike_verify_dir/capture-tests"; then
    mark_failure 'portable capture checks did not compile'; exit "$FAIL"
fi
if "$spike_verify_dir/capture-tests" --force-failure; then
    mark_failure 'the deliberate failure returned success'
else
    spike_negative_status=$?
    [ "$spike_negative_status" -eq 1 ] || mark_failure "the negative control exited unexpectedly ($spike_negative_status)"
fi
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi
"$spike_verify_dir/capture-tests" || mark_failure 'portable capture checks failed'
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi
if [ "${1:-}" = "--build" ]; then
    if ! xcodegen generate; then mark_failure 'standalone project generation failed'; exit "$FAIL"; fi
    if ! xcodebuild build -quiet -project SpatialSpikeCapture.xcodeproj -scheme SpatialSpikeCapture \
        -destination 'generic/platform=iOS' -derivedDataPath "$spike_verify_dir/DerivedData" \
        CODE_SIGNING_ALLOWED=NO; then mark_failure 'standalone iPhone build failed'; exit "$FAIL"; fi
    spike_app="$spike_verify_dir/DerivedData/Build/Products/Debug-iphoneos/SpatialSpikeCapture.app"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$spike_app/Info.plist")" = 'com.rendprop.spatialspike.capture' ] || mark_failure 'built bundle identifier is incorrect'
    [ "$(plutil -extract UIFileSharingEnabled raw -o - "$spike_app/Info.plist")" = 'true' ] || mark_failure 'built app does not enable file sharing'
    [ "$(plutil -extract LSSupportsOpeningDocumentsInPlace raw -o - "$spike_app/Info.plist")" = 'true' ] || mark_failure 'built app does not expose its local documents'
    if rg --files "$spike_app" | rg -q '\.(swift|md|sh|py)$'; then
        mark_failure 'development source bundled as an app resource'
    fi
    if [ "$FAIL" -eq 0 ]; then echo "PASS: standalone unsigned iPhone build and bundle assertions ($spike_verify_dir/DerivedData)"; fi
fi
exit "$FAIL"
