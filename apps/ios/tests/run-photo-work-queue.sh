#!/usr/bin/env bash
set -euo pipefail
photo_queue_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
photo_queue_test_dir="$(mktemp -d)"
trap 'rm -rf "$photo_queue_test_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$photo_queue_test_root/apps/ios/Rendprop/Photos/PhotoWorkQueue.swift" \
  "$photo_queue_test_root/apps/ios/tests/PhotoWorkQueueTests.swift" \
  -o "$photo_queue_test_dir/photo-queue-tests"
"$photo_queue_test_dir/photo-queue-tests"
