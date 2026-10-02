#!/usr/bin/env bash
set -euo pipefail
listing_unit_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
listing_unit_test_dir="$(mktemp -d)"
trap 'rm -rf "$listing_unit_test_dir"' EXIT
# Extract the exact production pure form boundaries without SwiftUI/MapKit.
python3 - "$listing_unit_test_root/apps/ios/Rendprop/Screens/NewListingView.swift" "$listing_unit_test_dir/ListingForm.swift" "${1:-}" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
unit=source[source.index('enum ListingUnitAddress {'):source.index('// MARK: - Form data')]
form=source[source.index('struct ListingFormData:'):source.index('// MARK: - The form itself')]
if sys.argv[3]=='--inject-metadata-loss':
    assert 'l.details = cleanedDetails' in form
    form=form.replace('l.details = cleanedDetails','l.details = isRealEstate ? nil : cleanedDetails')
elif sys.argv[3]:
    raise SystemExit('Unknown test option')
pathlib.Path(sys.argv[2]).write_text('import Foundation\n'+unit+'\n'+form)
PY
xcrun swiftc -parse-as-library \
  "$listing_unit_test_root/apps/ios/Rendprop/Models/Listing.swift" \
  "$listing_unit_test_root/apps/ios/Rendprop/Models/ListingClientContact.swift" \
  "$listing_unit_test_root/apps/ios/Rendprop/Models/Money.swift" \
  "$listing_unit_test_dir/ListingForm.swift" \
  "$listing_unit_test_root/apps/ios/tests/ListingUnitFormTests.swift" \
  -o "$listing_unit_test_dir/listing-unit-tests"
"$listing_unit_test_dir/listing-unit-tests"
