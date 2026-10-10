#!/bin/bash
# All source mutations compile isolated copies; none edits the checkout.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
artifacts="$(mktemp -d /tmp/rendprop-measurement-export-controls.XXXXXX)"
python3 "$script_dir/run.py" | tee "$artifacts/positive.log"
for fault in ignore-geometry ignore-conflict ignore-facts-review phone-as-manual omit-room-records nonstandard-paper omit-page-transform omit-phone-limitation ignore-media-actor ignore-media-revision ignore-media-workspace; do
    status=0
    python3 "$script_dir/run.py" --inject-fault "$fault" > "$artifacts/$fault.log" 2>&1 || status=$?
    case "$fault" in
        ignore-geometry) expected='FAIL: stale geometry cannot be exported' ;;
        ignore-conflict) expected='FAIL: shared edit conflict cannot export local snapshot' ;;
        ignore-facts-review) expected='FAIL: older listing facts review blocks export until acknowledged' ;;
        phone-as-manual) expected='FAIL: phone source is not relabeled as manual' ;;
        nonstandard-paper) expected='FAIL: actual renderer uses standard US Letter landscape paper' ;;
        omit-page-transform) expected='FAIL: every actual PDF drawing rectangle fits inside physical paper margins' ;;
        omit-phone-limitation) expected='FAIL: phone ruler note discloses straight 3D distance and same-height tape verification' ;;
        omit-room-records) expected='FAIL: actual PDF loop emits every floor worksheet, room record and outline wall page' ;;
        ignore-media-actor) expected='FAIL: changed actor invalidates actual media context' ;;
        ignore-media-revision) expected='FAIL: changed session revision invalidates actual media context' ;;
        ignore-media-workspace) expected='FAIL: changed workspace invalidates actual media context' ;;
    esac
    if [ "$status" -ne 1 ] || ! grep -F -q "$expected" "$artifacts/$fault.log"; then
        cat "$artifacts/$fault.log" >&2
        echo "FAIL: $fault must compile and fail its intended runtime assertion" >&2
        exit 1
    fi
    echo "PASS: compiled $fault negative control failed its intended runtime assertion"
done
echo "Export controls artifacts: $artifacts"
