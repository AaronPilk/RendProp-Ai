#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
panorama_store_test_dir=$(mktemp -d /tmp/rendprop-panorama-store-tests.XXXXXX)
trap 'rm -rf "$panorama_store_test_dir"' EXIT
swiftc -O -D SPATIAL_CAPTURE_LAB \
    tools/spatial-spike/capture-ios/Sources/CaptureModel.swift \
    tools/spatial-spike/capture-ios/Sources/RasterWriter.swift \
    tools/spatial-spike/capture-ios/Sources/StationCaptureModels.swift \
    tools/spatial-spike/capture-ios/Sources/StationCapturePolicy.swift \
    tools/spatial-spike/capture-ios/Sources/PanoramaProjection.swift \
    tools/spatial-spike/capture-ios/Sources/PanoramaRenderer.swift \
    apps/ios/Rendprop/Capture/GuidedPanoramaPreviewStore.swift \
    apps/ios/tests/GuidedPanoramaPreviewStoreTests.swift \
    -o "$panorama_store_test_dir/checks"
if "$panorama_store_test_dir/checks" --intentional-failure >"$panorama_store_test_dir/intentional.log" 2>&1; then
    echo "FAIL: intentionally failing cache assertion returned success"
    exit 1
fi
"$panorama_store_test_dir/checks"
