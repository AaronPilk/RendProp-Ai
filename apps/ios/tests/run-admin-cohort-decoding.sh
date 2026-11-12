#!/usr/bin/env bash
set -euo pipefail
cohort_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cohort_test_dir="$(mktemp -d)"
trap 'rm -rf "$cohort_test_dir"' EXIT

if [[ "${1:-}" == '--negative-controls' ]]; then
  bash "$0"
  for cohort_fault in bucket-24h bucket-7d summary-24h summary-7d; do
    cohort_log="$cohort_test_dir/$cohort_fault.log"
    if bash "$0" "--inject-$cohort_fault" >"$cohort_log" 2>&1; then
      printf 'FAILED: cohort control was not caught: %s\n' "$cohort_fault" >&2
      exit 1
    fi
    # A compile failure must not masquerade as a caught behavioral regression.
    if ! grep -Fq "FAILED: ${cohort_fault/-/ actual } count" "$cohort_log"; then
      cat "$cohort_log" >&2
      exit 1
    fi
  done
  printf 'PASSED: four independent cohort numeric-key regression controls\n'
  exit 0
fi

python3 - "$cohort_test_root/apps/ios/Rendprop/Screens/AdminCohortsView.swift" \
  "$cohort_test_dir/ActualCohort.swift" "${1:-}" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = 'struct AdminCohortBucket:'
end = '/// The one call this screen needs.'
assert source.count(start) == 1 and source.count(end) == 1
models = source[source.index(start):source.index(end)]
request = source[source.index('enum AdminReportRequest {'):source.index('/// The five states')]
decoder = re.search(r'        let decoder = JSONDecoder\(\)\n[\s\S]*?        \}\n(?=    \}\n\})', request)
assert decoder, 'Actual request decoder could not be extracted'
fault = sys.argv[3]
if fault:
    match = re.fullmatch(r'--inject-(bucket|summary)-(24h|7d)', fault)
    if not match:
        raise SystemExit('Unknown test option')
    scope, unit = match.groups()
    marker = 'extension AdminCohort' + ('Bucket' if scope == 'bucket' else 'Summary') + ': Decodable'
    boundary = models.index(marker)
    before = 'case activatedWithin' + unit + ' = "activatedWithin' + unit[:-1] + unit[-1].upper() + '"'
    after = 'case activatedWithin' + unit
    tail = models[boundary:]
    assert before in tail
    models = models[:boundary] + tail.replace(before, after, 1)
pathlib.Path(sys.argv[2]).write_text(
    'import Foundation\n' + models + '\nenum AdminCohortTestDecoder {\n'
    '    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {\n'
    + decoder.group() + '\n    }\n}\n'
)
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  "$cohort_test_dir/ActualCohort.swift" \
  "$cohort_test_root/apps/ios/tests/AdminCohortDecodingTests.swift" \
  -o "$cohort_test_dir/cohort-decoding-tests"
"$cohort_test_dir/cohort-decoding-tests"
