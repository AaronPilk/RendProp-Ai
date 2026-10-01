#!/usr/bin/env bash
set -euo pipefail
subscription_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
subscription_test_dir="$(mktemp -d)"
trap 'rm -rf "$subscription_test_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$subscription_test_root/apps/ios/Rendprop/Purchases/SubscriptionOfferPolicy.swift" \
  "$subscription_test_root/apps/ios/Rendprop/Purchases/SubscriptionBillingContext.swift" \
  "$subscription_test_root/apps/ios/tests/SubscriptionPolicyTests.swift" \
  -o "$subscription_test_dir/subscription-policy-tests"
"$subscription_test_dir/subscription-policy-tests"
