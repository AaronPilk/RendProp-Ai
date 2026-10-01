#!/usr/bin/env bash
set -euo pipefail
adoption_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
adoption_test_dir="$(mktemp -d)"
trap 'rm -rf "$adoption_test_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$adoption_test_root/apps/ios/Rendprop/Models/Listing.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Models/Money.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Models/ProductionGuidance.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Networking/ProductionPlan.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Auth/AdoptionLocalBindings.swift" \
  "$adoption_test_root/apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift" \
  "$adoption_test_root/apps/ios/tests/AdoptionProductionLibraryTests.swift" \
  -o "$adoption_test_dir/adoption-production-tests"
"$adoption_test_dir/adoption-production-tests" "$adoption_test_dir"
