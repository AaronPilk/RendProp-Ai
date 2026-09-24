#!/usr/bin/env bash
set -euo pipefail

# Compile the real sequential writer unchanged. Identity and transport doubles
# live only in ProductionPlanWriterTests.swift; no credentials or device needed.
production_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
production_test_dir="$(mktemp -d)"
trap 'rm -rf "$production_test_dir"' EXIT

xcrun swiftc -parse-as-library \
  "$production_test_root/apps/ios/Rendprop/Models/ProductionGuidance.swift" \
  "$production_test_root/apps/ios/Rendprop/Networking/ProductionPlan.swift" \
  "$production_test_root/apps/ios/Rendprop/Networking/ProductionPlanSyncStore.swift" \
  "$production_test_root/apps/ios/tests/ProductionPlanWriterTests.swift" \
  -o "$production_test_dir/production-writer-tests"
"$production_test_dir/production-writer-tests"
