#!/bin/bash
# Compile complete production Coach source; no API, database or customer files.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_DIR="$(mktemp -d /tmp/rendprop-coach-privacy.XXXXXX)"
COACH_SOURCE="$REPO_DIR/apps/ios/Rendprop/Coach/CoachModel.swift"
COACH_API="$REPO_DIR/apps/ios/Rendprop/Coach/CoachAPI.swift"
xcrun swiftc -parse-as-library "$COACH_API" "$COACH_SOURCE" "$SCRIPT_DIR/CoachPrivacyTests.swift" -o "$ARTIFACT_DIR/positive"
"$ARTIFACT_DIR/positive"
python3 - "$COACH_SOURCE" "$ARTIFACT_DIR" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
mutations = {
    'drop-history-redaction': ('Self.redactedTranscript($0.text, addresses: addressRedactions)', '$0.text'),
    'upload-local-bubbles': ('messages.filter { !$0.localOnly }.suffix(20)', 'messages.suffix(20)'),
    'include-foreign-cache': ('return model.realProjects.filter { ($0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }', 'return model.realProjects'),
    'drop-context-fences': ('guard currentContext else { invalidateContext(); return }', ''),
}
for name, (before, after) in mutations.items():
    count = source.count(before)
    assert count > 0, f'{name}: production mutation anchor absent'
    if name != 'drop-context-fences':
        assert count == 1, f'{name}: ambiguous anchor'
    (out / f'{name}.swift').write_text(source.replace(before, after))
PY
for control in drop-history-redaction upload-local-bubbles include-foreign-cache drop-context-fences; do
    xcrun swiftc -parse-as-library "$COACH_API" "$ARTIFACT_DIR/$control.swift" "$SCRIPT_DIR/CoachPrivacyTests.swift" -o "$ARTIFACT_DIR/$control"
    status=0
    "$ARTIFACT_DIR/$control" > "$ARTIFACT_DIR/$control.log" 2>&1 || status=$?
    test "$status" -eq 1
    case "$control" in
        drop-history-redaction) reason='legacy assistant reply is redacted at the actual history boundary' ;;
        upload-local-bubbles) reason='offline-to-online transcript excludes local assistant bubbles' ;;
        include-foreign-cache) reason='live context excludes foreign and unbound cached projects' ;;
        drop-context-fences) reason='context-change-during-consent cannot dispatch a paid request' ;;
    esac
    rg -q "$reason" "$ARTIFACT_DIR/$control.log"
    echo "PASS: compiled $control negative control failed its intended runtime assertion"
done
echo "Coach privacy artifacts: $ARTIFACT_DIR"
