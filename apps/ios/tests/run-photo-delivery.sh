#!/usr/bin/env bash
set -euo pipefail
photo_delivery_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
photo_delivery_dir="$(mktemp -d)"
trap 'rm -rf "$photo_delivery_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$photo_delivery_root/apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift" \
  "$photo_delivery_root/apps/ios/Rendprop/Photos/PhotoVersionHistory.swift" \
  "$photo_delivery_root/apps/ios/tests/PhotoVersionHistoryTests.swift" \
  -o "$photo_delivery_dir/photo-delivery-tests"
"$photo_delivery_dir/photo-delivery-tests"
