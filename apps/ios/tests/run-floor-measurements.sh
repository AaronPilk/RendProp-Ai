#!/usr/bin/env bash
set -euo pipefail
floor_measurements_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
floor_measurements_dir="$(mktemp -d)"
trap 'rm -rf "$floor_measurements_dir"' EXIT
floor_measurements_source="$floor_measurements_root/apps/ios/Rendprop/Models/Listing.swift"
# Optional negative controls compile a private copy of the same production
# model; normal runs compile the original file without extraction or rewriting.
if [[ -n "${1:-}" ]]; then
  python3 - "$floor_measurements_source" "$floor_measurements_dir/Listing.swift" "$1" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if sys.argv[3] == '--inject-conversion-error':
    before = 'case .feet: meters = number * 0.3048 + inchNumber * 0.0254'
    after = 'case .feet: meters = number * 0.3 + inchNumber * 0.0254'
elif sys.argv[3] == '--inject-overlap-loss':
    before = 'if rooms[i].overlaps(rooms[j]) { return true }'
    after = 'if rooms[i].overlaps(rooms[j]) { return false }'
elif sys.argv[3] == '--inject-wire-resurrection':
    before = 'floorMeasurements = nil\n            }\n        } else {'
    after = 'floorMeasurements = FloorMeasurementPlan.decodeWireValue(details?[FloorMeasurementPlan.wireKey])\n            }\n        } else {'
else:
    raise SystemExit('Unknown test option')
assert source.count(before) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(before, after))
PY
  floor_measurements_source="$floor_measurements_dir/Listing.swift"
fi
xcrun swiftc -parse-as-library \
  "$floor_measurements_source" \
  "$floor_measurements_root/apps/ios/Rendprop/Models/ListingClientContact.swift" \
  "$floor_measurements_root/apps/ios/Rendprop/Models/Money.swift" \
  "$floor_measurements_root/apps/ios/tests/FloorMeasurementsTests.swift" \
  -o "$floor_measurements_dir/floor-measurements-tests"
"$floor_measurements_dir/floor-measurements-tests"
