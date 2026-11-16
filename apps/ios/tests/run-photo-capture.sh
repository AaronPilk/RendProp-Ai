#!/usr/bin/env bash
set -euo pipefail
photo_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
photo_test_dir="$(mktemp -d)"
trap 'rm -rf "$photo_test_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$photo_test_root/apps/ios/Rendprop/Capture/PhotoCapturePolicy.swift" \
  "$photo_test_root/apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift" \
  "$photo_test_root/apps/ios/tests/PhotoCaptureTests.swift" \
  -o "$photo_test_dir/photo-capture-tests"
"$photo_test_dir/photo-capture-tests"
