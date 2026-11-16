#!/bin/bash
set -euo pipefail
station_source_dir="$(cd "$(dirname "$0")" && pwd)"
station_test_dir="$(mktemp -d /tmp/rendprop-station-checks.XXXXXX)"
trap 'rm -rf "$station_test_dir"' EXIT
xcrun swiftc -swift-version 5 \
  "$station_source_dir/Sources/CaptureModel.swift" \
  "$station_source_dir/Sources/CaptureBlur.swift" \
  "$station_source_dir/Sources/RasterWriter.swift" \
  "$station_source_dir/Sources/StationCaptureModels.swift" \
  "$station_source_dir/Sources/StationCapturePolicy.swift" \
  "$station_source_dir/Sources/StationCaptureRecorder.swift" \
  "$station_source_dir/StationTests/main.swift" -o "$station_test_dir/station-checks"
if "$station_test_dir/station-checks" --force-failure > "$station_test_dir/intentional-failure.log" 2>&1; then
  echo 'FAIL: station test harness accepted its intentional failure'
  exit 1
fi
"$station_test_dir/station-checks"
