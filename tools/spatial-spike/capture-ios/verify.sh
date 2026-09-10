#!/bin/bash
set -uo pipefail
FAIL=0
mark_failure() { echo "FAIL: $*" >&2; FAIL=1; }
if ! cd "$(dirname "$0")"; then mark_failure 'cannot enter capture harness directory'; exit "$FAIL"; fi
# Check that edits landed before either compiling a test or building the app.
rg -q 'final class CaptureRecorder' Sources/CaptureRecorder.swift || mark_failure 'CaptureRecorder symbol missing'
rg -q 'final class NativeRasterWriter' Sources/RasterWriter.swift || mark_failure 'NativeRasterWriter symbol missing'
rg -q 'raw_feature_points' Sources/CaptureModel.swift || mark_failure 'feature point schema missing'
rg -q 'struct CaptureControls' Sources/CaptureControls.swift || mark_failure 'capture control interlocks missing'
rg -q 'final class SpatialCaptureViewController' Sources/SpatialCaptureViewController.swift || mark_failure 'reusable capture controller missing'
rg -q 'func endPresentation' Sources/SpatialCaptureViewController.swift || mark_failure 'capture dismissal teardown missing'
rg -q 'struct CaptureArchive' Sources/CaptureArchive.swift || mark_failure 'persistent capture recovery missing'
if rg -q '@main' Sources/SpatialCaptureViewController.swift; then mark_failure 'shared controller contains a standalone entry point'; fi
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi
if ! spike_verify_dir=$(mktemp -d /tmp/spatial-capture-verify.XXXXXX); then mark_failure 'cannot create isolated verification directory'; exit "$FAIL"; fi
if ! swiftc Sources/CaptureModel.swift Sources/RasterWriter.swift Sources/CaptureControls.swift Sources/CaptureArchive.swift Tests/main.swift -o "$spike_verify_dir/capture-tests"; then
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
ruby verify-ui-summary.rb --self-test || mark_failure 'UI summary negative-control checks failed'
if [ "$FAIL" -ne 0 ]; then exit "$FAIL"; fi
if [ "${1:-}" = "--build" ]; then
    if ! xcodegen generate; then mark_failure 'standalone project generation failed'; exit "$FAIL"; fi
    if ! xcodebuild build -quiet -configuration Release -project SpatialSpikeCapture.xcodeproj -scheme SpatialSpikeCapture \
        -destination 'generic/platform=iOS' -derivedDataPath "$spike_verify_dir/DerivedData" \
        CODE_SIGNING_ALLOWED=NO; then mark_failure 'standalone iPhone build failed'; exit "$FAIL"; fi
    spike_app="$spike_verify_dir/DerivedData/Build/Products/Release-iphoneos/SpatialSpikeCapture.app"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$spike_app/Info.plist")" = 'com.rendprop.spatialspike.capture' ] || mark_failure 'built bundle identifier is incorrect'
    [ "$(plutil -extract UIFileSharingEnabled raw -o - "$spike_app/Info.plist")" = 'true' ] || mark_failure 'built app does not enable file sharing'
    [ "$(plutil -extract LSSupportsOpeningDocumentsInPlace raw -o - "$spike_app/Info.plist")" = 'true' ] || mark_failure 'built app does not expose its local documents'
    [ "$(plutil -extract MinimumOSVersion raw -o - "$spike_app/Info.plist")" = '15.0' ] || mark_failure 'built minimum OS differs from declared iOS 15 support'
    [ "$(plutil -extract UIRequiredDeviceCapabilities.1 raw -o - "$spike_app/Info.plist")" = 'arkit' ] || mark_failure 'built app does not declare required ARKit hardware'
    [ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$spike_app/Info.plist")" = 'false' ] || mark_failure 'built encryption declaration missing'
    [ "$(plutil -extract NSPrivacyTracking raw -o - "$spike_app/PrivacyInfo.xcprivacy")" = 'false' ] || mark_failure 'privacy manifest missing or claims tracking'
    [ "$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$spike_app/PrivacyInfo.xcprivacy")" = '[]' ] || mark_failure 'privacy manifest misstates local-only capture'
    [ -f "$spike_app/Assets.car" ] || mark_failure 'app icon asset catalog missing'
    [ "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$spike_app/Info.plist")" = 'AppIcon' ] || mark_failure 'built app icon is not configured'
    if rg --files "$spike_app" | rg -q '\.(swift|md|sh|py)$'; then
        mark_failure 'development source bundled as an app resource'
    fi
    if [ "$FAIL" -eq 0 ]; then echo "PASS: standalone unsigned Release iPhone build and bundle assertions ($spike_verify_dir/DerivedData)"; fi
fi
exit "$FAIL"
