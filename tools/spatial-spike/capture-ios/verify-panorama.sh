#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
panorama_test_dir=$(mktemp -d /tmp/rendprop-panorama-tests.XXXXXX)
trap 'rm -rf "$panorama_test_dir"' EXIT
swiftc -O Sources/CaptureModel.swift Sources/RasterWriter.swift Sources/PanoramaProjection.swift Sources/PanoramaRenderer.swift Tests/PanoramaChecks.swift -o "$panorama_test_dir/checks"
if "$panorama_test_dir/checks" --intentional-failure >"$panorama_test_dir/intentional.log" 2>&1; then
    echo "FAIL: the intentionally failing assertion exited successfully"
    exit 1
fi
"$panorama_test_dir/checks" "$@"
