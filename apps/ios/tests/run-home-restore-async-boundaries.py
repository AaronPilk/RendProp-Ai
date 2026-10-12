#!/usr/bin/env python3
"""Compile real Home/location/restore methods at closed async boundaries."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', '--out', dest='evidence_dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-home-restore-'))
out.mkdir(parents=True, exist_ok=True)
app_path = root / 'apps/ios/Rendprop/RendpropApp.swift'
listing_path = root / 'apps/ios/Rendprop/Screens/NewListingView.swift'
live_path = root / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
ui_path = root / 'apps/ios/RendpropUITests/HomeProjectCreationUITests.swift'
recent_path = root / 'apps/ios/Rendprop/Screens/RecentlyDeletedView.swift'
auth_path = root / 'apps/ios/Rendprop/Auth/AuthStore.swift'
workspace_path = root / 'apps/ios/Rendprop/Workspace/WorkspaceContext.swift'
fixture_path = root / 'apps/ios/tests/HomeRestoreAsyncBoundaryTests.swift'
consumed = [app_path, listing_path, live_path, ui_path, recent_path, auth_path, workspace_path, fixture_path, Path(__file__).resolve()]


def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed}


def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def replace_one(source, old, new):
    assert source.count(old) == 1, old
    return source.replace(old, new)


receipt = {'passed': False, 'start_source_sha256': hashes(), 'commands': [], 'runs': [],
           'limitations': ['Model/client restore, RecentlyDeletedView restore callback, restore DTO, form context predicates and current-location/cancel bodies execute unchanged.',
                          'Auth, workspace routing, token wait, HTTP response, cloud refresh, GPS and geocoder are closed controlled doubles.',
                          'The actual whole refresh/merge, full URLSession auth executor and SwiftUI lifecycle are outside this isolated gate.',
                          'UI lifecycle wiring is source checked; reference-backed fixture state mirrors SwiftUI State value access without app compilation.',
                          'The real Home UI is covered separately by XCUITest.',
                          'No customer files, real network, Apple account, Photos writes, simulator or app compilation.']}


def command(name, argv, timeout):
    start = time.monotonic()
    event = {'name': name, 'argv': argv, 'deadline_seconds': timeout}
    receipt['commands'].append(event)
    log_path = out / (name + '.log')
    try:
        with log_path.open('w') as log:
            result = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        event['exit_code'] = result.returncode
        return result, log_path.read_text()
    finally:
        event['elapsed_seconds'] = round(time.monotonic() - start, 3)
        event['log_path'] = str(log_path)
        event['log_sha256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()


try:
    app, listing, live, ui, recent = (p.read_text() for p in [app_path, listing_path, live_path, ui_path, recent_path])
    assert '@MainActor var syncSessionRevision: UInt64' in auth_path.read_text()
    assert '@MainActor\nfinal class AuthStore' not in auth_path.read_text()
    assert '@MainActor enum WorkspaceContext' not in workspace_path.read_text()
    home = block(app, 'struct StartProjectSheet: View {')
    new = block(listing, 'struct NewListingView: View {')
    actual_parts = {
        'MODEL_METHOD': block(app, '    func restoreListing(serverID: UUID) async throws -> RestoredListing {'),
        'LIVE_METHOD': block(live, '    func restoreListing(serverID: UUID) async throws -> RestoredListing {'),
        'RESTORE_DTO': block(live, '    private struct RestoreDTO: Decodable {'),
        'HOME_CONTEXT': block(home, '    private var creationContextIsCurrent: Bool {'),
        'HOME_LOCATION': block(home, '    private func useCurrentLocation() {'),
        'HOME_CANCEL': block(home, '    private func cancelCurrentLocation() {'),
        'LISTING_CONTEXT': block(new, '    private var formContextIsCurrent: Bool {'),
        'LISTING_LOCATION': block(new, '    private func useCurrentLocation() {'),
        'LISTING_CANCEL': block(new, '    private func cancelCurrentLocation() {'),
        'CALLER_RESTORE': block(recent, '    private func restore(_ row: TrashedListing) {'),
    }
    assert '.onDisappear { cancelCurrentLocation() }' in home
    assert '.onDisappear { cancelCurrentLocation() }' in new
    assert 'if locationRequestID != nil { cancelCurrentLocation() }' in home
    assert 'if locationRequestID != nil { cancelCurrentLocation() }' in new
    assert 'private func restore(_ row: TrashedListing)' in recent
    restore_caller = block(recent, '    private func restore(_ row: TrashedListing) {')
    assert restore_caller.count('workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch') == 2
    ui_case = block(ui, '    func testNewHomeAcceptsAddressSuggestionsAndDeterministicCurrentLocation() {')
    assert 'XCTSkip' not in ui_case
    assert 'home.startProject.currentLocation' in ui_case and '100 Synthetic Condo Way, Fixture City, NC 28000' in ui_case
    actual = fixture_path.read_text()
    for key, value in actual_parts.items():
        actual = replace_one(actual, '// __' + key + '__', value)
    receipt['extracted_method_sha256'] = {key: hashlib.sha256(value.encode()).hexdigest() for key, value in actual_parts.items()}
    receipt['source_wiring_assertions'] = 11

    model_post = '''        guard owner == AuthStore.shared.userID, revision == AuthStore.shared.syncSessionRevision,
              library == WorkspaceContext.selectedOrgID else { throw CloudSyncError.identityChanged }'''
    live_pre = '''            guard WorkspaceContext.selectedOrgID == workspace, AuthStore.shared.userID == actor,
                  AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }'''
    live_post = '        guard current else { throw CloudSyncError.identityChanged }'
    resume_guard = '''                guard owner == AuthStore.shared.userID, revision == AuthStore.shared.syncSessionRevision,
                      library == WorkspaceContext.selectedOrgID else { return }'''
    prior_read = block(actual, '            if let pending = self.cloudRefreshTask {')
    home_harness = block(actual, '@MainActor struct HomeLocationHarness {')
    caller_success = 'guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { restoring = nil; return }'
    caller_error = 'guard workspace.selected?.id == org, auth.userID == owner, auth.syncSessionRevision == epoch else { return }'
    variants = [
        ('actual', actual, None),
        ('negative-client-before-dispatch-fence', replace_one(actual, live_pre, ''), 'changed request context cannot dispatch restore'),
        ('negative-client-after-reply-fence', replace_one(actual, live_post, ''), 'late restore reply cannot escape into another library'),
        ('negative-model-after-reply-fence', replace_one(actual, model_post, ''), 'model rejects an account-context change before presenting success'),
        ('negative-model-wrong-restored-listing', replace_one(actual, 'guard restored.id == serverID else { throw CloudSyncError.invalidResponse }', ''), 'model refuses a different restored listing'),
        ('negative-prerestore-snapshot-joined', replace_one(actual, prior_read, ''), 'restore refresh must fetch after the pre-restore snapshot'),
        ('negative-resumed-restore-context-fence', replace_one(actual, resume_guard, ''), 'a stale pending restore cannot refresh another account'),
        ('negative-newer-refresh-erased', replace_one(actual, 'if self.cloudRefreshOperation == operation {', 'if true {'), 'older restore completion must preserve a newer refresh operation'),
        ('negative-home-new-input-overwritten', actual.replace('name == requestedName', 'true'), 'stale Home geocode cannot overwrite typed or switched context'),
        ('negative-listing-new-input-overwritten', actual.replace('form.address == requestedAddress', 'true'), 'stale Listings geocode cannot overwrite typed or switched context'),
        ('negative-home-cancelled-callback-applied', replace_one(actual, home_harness, home_harness.replace('locationRequestID = nil', '// request invalidation omitted')), 'stale Home geocode cannot overwrite typed or switched context'),
        ('negative-caller-late-confirmation', replace_one(replace_one(actual, caller_success, ''), caller_error, ''), 'stale restore caller cannot present success or error in another account'),
    ]
    for name, generated, expected_failure in variants:
        assert expected_failure is None or generated != actual, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(generated)
        built, diagnostics = command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], 120)
        assert built.returncode == 0, name + ' compile failed: ' + diagnostics
        ran, output = command(name, [str(binary)], 30)
        expected = ran.returncode == 0 if expected_failure is None else ran.returncode != 0 and ('Precondition failed: ' + expected_failure) in output
        receipt['runs'].append({'name': name, 'exit_code': ran.returncode, 'expected_result': expected,
                                'expected_failure': expected_failure, 'source_sha256': hashlib.sha256(generated.encode()).hexdigest(),
                                'output': output[:2500]})
        if expected_failure is None:
            receipt['assertions'] = int(re.search(r'PASSED: (\d+) actual-body', output)[1])
        assert expected, name + ': ' + output
        binary.unlink()
    # Match production's nonisolated client and actor-isolated revision getter.
    # These compile controls must reject the exact mistake that an actor-wide
    # client or Auth fixture annotation would otherwise hide.
    isolated_capture = 'await MainActor.run { (WorkspaceContext.selectedOrgID, AuthStore.shared.userID, AuthStore.shared.syncSessionRevision) }'
    isolated_reply = '''await MainActor.run {
            WorkspaceContext.selectedOrgID == workspace && AuthStore.shared.userID == actor
                && AuthStore.shared.syncSessionRevision == revision
        }'''
    receipt['isolation_compile_controls'] = []
    for name, anchor, unisolated in [
        ('negative-nonisolated-context-capture', isolated_capture, '(WorkspaceContext.selectedOrgID, AuthStore.shared.userID, AuthStore.shared.syncSessionRevision)'),
        ('negative-nonisolated-reply-validation', isolated_reply, 'WorkspaceContext.selectedOrgID == workspace && AuthStore.shared.userID == actor && AuthStore.shared.syncSessionRevision == revision'),
    ]:
        generated = replace_one(actual, anchor, unisolated)
        path, binary = out / (name + '.swift'), out / name
        path.write_text(generated)
        built, diagnostics = command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], 120)
        expected = built.returncode != 0 and "main actor-isolated property 'syncSessionRevision'" in diagnostics
        receipt['isolation_compile_controls'].append({'name': name, 'exit_code': built.returncode, 'expected_result': expected,
            'source_sha256': hashlib.sha256(generated.encode()).hexdigest(), 'diagnostics': diagnostics[:2500]})
        assert expected, name + ': ' + diagnostics
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == 12 and all(r['expected_result'] for r in receipt['runs']) and len(receipt.get('isolation_compile_controls', [])) == 2 and all(r['expected_result'] for r in receipt['isolation_compile_controls']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Sources changed during verification or a required control failed'
print(receipt['runs'][0]['output'].strip())
print('PASSED: eleven compiled negative controls failed at their expected invariant')
print('PASSED: two nonisolated revision controls were rejected by the compiler')
print(f'Evidence: {out}')
