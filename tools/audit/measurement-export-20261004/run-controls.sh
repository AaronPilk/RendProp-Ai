#!/bin/bash
# All source mutations compile isolated copies; none edits the checkout.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
artifacts="$(mktemp -d /tmp/rendprop-measurement-export-controls.XXXXXX)"
python3 "$script_dir/run.py" | tee "$artifacts/positive.log"
for fault in ignore-geometry ignore-conflict ignore-facts-review phone-as-manual omit-room-records; do
    status=0
    python3 "$script_dir/run.py" --inject-fault "$fault" > "$artifacts/$fault.log" 2>&1 || status=$?
    case "$fault" in
        ignore-geometry) expected='FAIL: stale geometry cannot be exported' ;;
        ignore-conflict) expected='FAIL: shared edit conflict cannot export local snapshot' ;;
        ignore-facts-review) expected='FAIL: older listing facts review blocks export until acknowledged' ;;
        phone-as-manual) expected='FAIL: phone source is not relabeled as manual' ;;
        omit-room-records) expected='FAIL: actual PDF loop emits every floor worksheet, room record and outline wall page' ;;
    esac
    if [ "$status" -ne 1 ] || ! rg -F -q "$expected" "$artifacts/$fault.log"; then
        cat "$artifacts/$fault.log" >&2
        echo "FAIL: $fault must compile and fail its intended runtime assertion" >&2
        exit 1
    fi
    echo "PASS: compiled $fault negative control failed its intended runtime assertion"
done
echo "Export controls artifacts: $artifacts"
