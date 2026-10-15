#!/bin/bash
# Compile complete production Coach source; no API, database or customer files.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_DIR="${COACH_PRIVACY_ARTIFACT_DIR:-$(mktemp -d /tmp/rendprop-coach-privacy.XXXXXX)}"
mkdir -p "$ARTIFACT_DIR"
COACH_SOURCE="$REPO_DIR/apps/ios/Rendprop/Coach/CoachModel.swift"
COACH_API="$REPO_DIR/apps/ios/Rendprop/Coach/CoachAPI.swift"
xcrun swiftc -parse-as-library "$REPO_DIR/apps/ios/Rendprop/Support/LaunchFeatureAvailability.swift" "$COACH_API" "$COACH_SOURCE" "$SCRIPT_DIR/CoachPrivacyTests.swift" -o "$ARTIFACT_DIR/positive"
"$ARTIFACT_DIR/positive"
python3 - "$COACH_SOURCE" "$ARTIFACT_DIR" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
mutations = {
    'drop-history-redaction': ('Self.redactedTranscript($0.text, addresses: addressRedactions)', '$0.text'),
    'upload-local-bubbles': ('messages.filter { !$0.localOnly }.suffix(20)', 'messages.suffix(20)'),
    'include-foreign-cache': ('projects = model.realProjects.filter { ($0.serverLibraryOrgID ?? $0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }', 'projects = model.listings'),
    'drop-selected-inactive': ('return [selected] + projects', 'return projects'),
    'include-unselected-inactive': ('projects = model.realProjects.filter { ($0.serverLibraryOrgID ?? $0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }', 'projects = model.listings.filter { ($0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }'),
    'drop-active-logical-library': ('projects = model.realProjects.filter { ($0.serverLibraryOrgID ?? $0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }', 'projects = model.realProjects.filter { ($0.serverOrgID ?? $0.cloudDraftOrgID) == orgID }'),
    'drop-selected-visibility': ('selected.cloudUnavailable != true, model.isInSelectedWorkspace(selected)', 'true, true'),
    'include-selected-sample': ('selected.isInactive, !selected.isSample, selected.belongsToCurrentType,', 'selected.isInactive, true, selected.belongsToCurrentType,'),
    'include-selected-type': ('selected.isInactive, !selected.isSample, selected.belongsToCurrentType,', 'selected.isInactive, !selected.isSample, true,'),
    'drop-context-fences': ('guard currentContext else { invalidateContext(); return }', ''),
    'wrong-reel-project': ('first(where: { $0.listingID == selectedListingID })', 'first(where: { _ in true })'),
    'drop-reel-pause-state': ('if job.paused { phase = .paused }', 'if false { phase = .paused }'),
    'inflate-ai-edit-count': ('photos.filter { $0.savedVersion?.effects.isEmpty == false }.count', 'photos.count'),
    'misroute-photo-only-share': ('return .listingDetails(listingID: listingID)', 'return .project(listingID: listingID, feature: .tour)'),
    'trust-unaccepted-server-job': ('stillPhotoShots: 0, execution: .awaitingAcceptance)', 'stillPhotoShots: 0, execution: .serverAccepted)'),
    'drop-saved-server-actor-fence': ('saved.context.actorID == actor, saved.context.orgID == orgID,', 'saved.context.orgID == orgID,'),
    'drop-aerial-launch-fence': ('guard kind != .openAerial || LaunchFeatureAvailability.canGenerateAerial else { return nil }', ''),
}
for name, (before, after) in mutations.items():
    count = source.count(before)
    assert count > 0, f'{name}: production mutation anchor absent'
    if name != 'drop-context-fences':
        assert count == 1, f'{name}: ambiguous anchor'
    (out / f'{name}.swift').write_text(source.replace(before, after))
PY
for control in drop-history-redaction upload-local-bubbles include-foreign-cache drop-context-fences wrong-reel-project drop-reel-pause-state inflate-ai-edit-count drop-aerial-launch-fence misroute-photo-only-share trust-unaccepted-server-job drop-saved-server-actor-fence drop-selected-inactive include-unselected-inactive drop-selected-visibility include-selected-sample include-selected-type drop-active-logical-library; do
    xcrun swiftc -parse-as-library "$REPO_DIR/apps/ios/Rendprop/Support/LaunchFeatureAvailability.swift" "$COACH_API" "$ARTIFACT_DIR/$control.swift" "$SCRIPT_DIR/CoachPrivacyTests.swift" -o "$ARTIFACT_DIR/$control"
    status=0
    "$ARTIFACT_DIR/$control" > "$ARTIFACT_DIR/$control.log" 2>&1 || status=$?
    test "$status" -eq 1
    case "$control" in
        drop-history-redaction) reason='legacy assistant reply is redacted at the actual history boundary' ;;
        upload-local-bubbles) reason='offline-to-online transcript excludes local assistant bubbles' ;;
        include-foreign-cache) reason='live context excludes foreign and unbound cached projects' ;;
        drop-selected-inactive) reason='selected Sold home remains the current website support context' ;;
        include-unselected-inactive) reason='unselected inactive homes stay out of support context' ;;
        drop-selected-visibility) reason='inactive selected exception refuses unavailable' ;;
        include-selected-sample) reason='inactive selected exception refuses sample' ;;
        include-selected-type) reason='inactive selected exception refuses type' ;;
        drop-active-logical-library) reason='authorized active logical library is retained without changing physical org' ;;
        drop-context-fences) reason='context-change-during-consent cannot dispatch a paid request' ;;
        wrong-reel-project) reason="wrong listing job cannot become selected context" ;;
        drop-reel-pause-state) reason='reel state is refreshed at send rather than frozen at sheet open' ;;
        inflate-ai-edit-count) reason='ordinary enhancement and unknown history are not counted as AI edits' ;;
        misroute-photo-only-share) reason='photo-only published website opens listing details instead of capture' ;;
        trust-unaccepted-server-job) reason='saved request without reply cannot prove server acceptance' ;;
        drop-saved-server-actor-fence) reason='other actor saved job is private' ;;
        drop-aerial-launch-fence) reason='stale online aerial action is rejected by shipping availability' ;;
    esac
    rg -q "$reason" "$ARTIFACT_DIR/$control.log"
    echo "PASS: compiled $control negative control failed its intended runtime assertion"
done
echo "Coach privacy artifacts: $ARTIFACT_DIR"
