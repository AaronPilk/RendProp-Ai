#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
room_guidance_test_dir=$(mktemp -d /tmp/rendprop-room-guidance.XXXXXX)
trap 'rm -rf "$room_guidance_test_dir"' EXIT
swiftc -O Sources/RoomScanPlanner.swift Sources/PanoramaNavigationPolicy.swift Tests/RoomGuidanceChecks.swift -o "$room_guidance_test_dir/checks"
if "$room_guidance_test_dir/checks" --intentional-failure >"$room_guidance_test_dir/intentional.log" 2>&1; then
    echo "FAIL: deliberately failing runner returned success"
    exit 1
fi
"$room_guidance_test_dir/checks"
