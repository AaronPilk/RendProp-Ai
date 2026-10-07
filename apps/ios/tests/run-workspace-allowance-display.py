#!/usr/bin/env python3
"""Compile actual native decode and display bodies; no network, Apple or camera.

Presentation interfaces record LabeledContent values rather than rendering SwiftUI.
The parent release compile separately verifies those bodies against real SwiftUI.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / 'apps/ios/Rendprop'
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path)
args = parser.parse_args()
out = (args.out or Path(tempfile.mkdtemp(prefix='rendprop-testing-allowance-'))).resolve()
out.mkdir(parents=True, exist_ok=True)

def block(source, needle):
    start = source.index(needle)
    opening = source.index('{', start)
    depth, cursor = 1, opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

paths = [IOS / name for name in ['Team/TeamAPI.swift', 'Team/TeamView.swift',
    'Screens/SettingsView.swift', 'Networking/APIClient.swift',
    'Networking/LiveAPIClient.swift', 'Models/Money.swift', 'RendpropApp.swift', 'Screens/HomeListingsView.swift',
    'Networking/WorkspaceSync.swift', 'Purchases/SubscriptionBillingContext.swift']]
paths += [Path(__file__).resolve(), ROOT / 'apps/ios/tests/WorkspaceAllowanceDisplayTests.swift']
hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
team, teamview, settings, api, live, money, app, homes, workspace, billing, runner, test = [path.read_text() for path in paths]
settingsRows = block(settings, 'private func usageRows(')
calls = re.findall(r'^\s*(usageRow\([^\n]+\))$', settingsRows, re.M)
assert len(calls) == 5 and all('plan: e.plan, source: e.planSource' in call for call in calls)
teamRow = re.findall(r'^\s*(LabeledContent\("Seats used", value: [^\n]+\))$', teamview, re.M)
assert len(teamRow) == 1 and teamRow[0] == 'LabeledContent("Seats used", value: s.seatUsageLabel)'
accessRow = re.findall(r'^\s*(LabeledContent\("Workspace access", value: [^\n]+\))$', teamview, re.M)
assert len(accessRow) == 1
joinText = re.findall(r'^\s*(Text\(joinedDetails\?\.confirmationMessage[^\n]+\))$', teamview, re.M)
removalText = re.findall(r'^\s*(Text\(pendingRemoval\?\.removalExplanation[^\n]+\))$', teamview, re.M)
assert len(joinText) == len(removalText) == 1 and 'joinedDetails = joined' in block(teamview, 'private func join()')
inviteSource = block(teamview, 'private struct NewInviteView:')
assert 'NewInviteView(privateTesting: s.isPrivateTesting)' in teamview
assert 'if showsRolePicker {\n                        Picker("Role"' in inviteSource
inviteLabel = re.findall(r'^\s*(LabeledContent\("Access", value: [^\n]+\))$', inviteSource, re.M)
inviteSend = re.findall(r'^\s*(await send\([^\n]+\))$', inviteSource, re.M)
assert len(inviteLabel) == len(inviteSend) == 1
assert '.disabled(needsWorkspaceSelection)' in homes and 'if needsWorkspaceSelection {\n                workspaceSelectionPrompt' in homes

interfaces = '''
import Foundation
protocol View {}
struct Text: View { let value: String; init(_ value: String) { self.value = value } }
struct WorkspacePickerView: View {}
struct NavigationLink<Destination: View>: View {
    let title: String; let destination: Destination; var identifier: String = ""
    init(_ title: String, destination: () -> Destination) { self.title = title; self.destination = destination() }
    func accessibilityIdentifier(_ value: String) -> Self { var copy = self; copy.identifier = value; return copy }
}
struct LabeledContent: View {
    let title: String; let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    func foregroundStyle(_ ignored: String) -> Self { self }
}
enum Theme { static let ink = "ink"; static let inkDim = "dim" }
enum APIError: Error { case decoding }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "synthetic-owner"
    var syncSessionRevision: UInt64 = 1
    func applyServerIdentity(userName: String?, orgName: String?) {}
}
'''
policy = block(team, 'enum WorkspaceAllowanceDisplay {')
teamSummary = block(team, 'struct TeamSummary:')
common = interfaces + '\n' + money + '\n' + block(workspace, 'enum CloudSyncError:')
common += '\n' + billing
common += '\n' + policy + '\n' + teamSummary
common += '\n' + block(team, 'struct TeamJoined:')
common += '\nenum TeamAPI {\n' + block(team, 'struct Failure:') + '\n' + block(team, 'static func parseTimestamp(')
common += '\n' + block(team, 'private static func decode<T:')
common += '\nstatic func fixtureDecode<T: Decodable>(_ type: T.Type, data: Data) throws -> T { try decode(data) }\n}\n'
common += '\n' + block(api, 'struct Entitlements:') + '\n' + block(api, 'struct HostingRetentionSummary:')
common += '\n' + block(api, 'struct UsageSummary:')
usageRow = block(settings, 'private func usageRow(')
common += '\nstruct SettingsPolicyFixture {\n' + usageRow
common += '\nfunc rows(_ e: Entitlements) -> [LabeledContent] { return [\n' + ',\n'.join(call + ' as! LabeledContent' for call in calls) + '\n] }\n}\n'
common += '\nstruct TeamPolicyFixture {\n' + block(teamview, 'private func seatsFooter(')
common += '\nfunc row(_ s: TeamSummary) -> LabeledContent { ' + teamRow[0] + ' }\n'
common += 'func access(_ s: TeamSummary) -> LabeledContent { ' + accessRow[0] + ' }\n'
common += 'func join(_ joinedDetails: TeamJoined?) -> String { (' + joinText[0] + ').value }\n'
common += 'func removal(_ pendingRemoval: TeamSummary.Member?) -> String { (' + removalText[0] + ').value }\n'
common += 'func footer(_ s: TeamSummary) -> String { seatsFooter(s) }\n}\n'
common += '\nstruct InvitePolicyFixture {\nvar privateTesting: Bool; let send: (String?, String) async -> Void; var email: String; var role: String\n'
for needle in ['private var showsRolePicker:', 'private var invitationRole:', 'private var invitationExplanation:']:
    common += block(inviteSource, needle) + '\n'
common += 'var showsRoles: Bool { showsRolePicker }\nvar explanation: String { invitationExplanation }\n'
common += 'var accessRow: LabeledContent { ' + inviteLabel[0] + ' }\nfunc dispatch() async { ' + inviteSend[0] + ' }\n}\n'
common += '''
enum Config { static var useLiveBackend = true }
enum WorkspaceContext { static var selectedOrgID: UUID? }
struct WorkspaceStore { var selected: UUID? { WorkspaceContext.selectedOrgID } }
struct Listing {
    let id: UUID; var address: String = "Synthetic house"; var isSample = false
    var belongsToCurrentType = true; var isSold = false
    var isInactive: Bool { isSold }
    var serverOrgID: UUID? = nil; var cloudDraftOrgID: UUID? = nil; var cloudUnavailable = false
}
final class InventoryPolicyFixture {
    var listings: [Listing] = []
'''
common += block(app, 'func isInSelectedWorkspace(') + '\n}\n'
common += '\nstruct HomePolicyFixture {\n let model: InventoryPolicyFixture; var search = ""; let workspaceStore = WorkspaceStore()\n'
common += block(homes, 'private var filtered:') + '\n' + block(homes, 'private var needsWorkspaceSelection:')
common += '\n' + block(homes, 'private var workspaceSelectionPrompt:')
common += '\nvar visibleIDs: [UUID] { filtered.map(\\.id) }\nvar needsSelection: Bool { needsWorkspaceSelection }\n'
common += 'var prompt: NavigationLink<WorkspacePickerView> { workspaceSelectionPrompt as! NavigationLink<WorkspacePickerView> }\n}\n'
common += '''
@MainActor final class LivePolicyFixture {
    let data: Data; var requestCount = 0
    init(data: Data) { self.data = data }
    private func url(_ parts: [String]) -> URL { URL(string: "https://fixture.invalid/" + parts.joined(separator: "/"))! }
    private func makeRequest(url: URL) -> URL { url }
    private func execute(_ url: URL) async throws -> Data {
        precondition(url.absoluteString == "https://fixture.invalid/me")
        requestCount += 1; return data
    }
'''
for needle in ['struct LenientInt:', 'private struct MeDTO:', 'private func decode<T:',
               'private static func parseDate(', '@MainActor func me(']:
    common += '\n' + block(live, needle)
common += '\n}\n'

controls = [
    ('ordinary-large-cap', 'cap == ownerTestingUnlimitedCap', 'cap >= ownerTestingUnlimitedCap - 1', 'only exact marker is testing Unlimited'),
    ('missing-team-guard', 'plan?.lowercased() == "team"', 'true', 'nonTeam cap cannot claim testing Unlimited'),
    ('missing-manual-guard', '(source == nil || source?.lowercased() == "manual")', 'true', 'nonmanual source cannot claim testing Unlimited'),
    ('dropped-me-source', 'planSource: dto.planSource', 'planSource: nil', 'actual me forwards authoritative manual source'),
    ('ignored-settings-source', 'let value = WorkspaceAllowanceDisplay.value(used: used, cap: cap, plan: plan, source: source)',
        'let value = WorkspaceAllowanceDisplay.value(used: used, cap: cap, plan: plan, source: nil)', 'nonmanual source cannot claim testing Unlimited'),
    ('ignored-team-source', 'cap: seats.allowed, plan: plan, source: planSource)', 'cap: seats.allowed, plan: plan, source: nil)', 'team nonmanual source stays finite'),
    ('private-mode-treated-shared', 'var isPrivateTesting: Bool { accessMode == "private_testing" }', 'var isPrivateTesting: Bool { false }', 'actual Team access row identifies private testing'),
    ('private-join-treated-shared', 'if accessMode == "private_testing" {', 'if false {', 'actual join confirmation does not promise shared houses'),
    ('nil-workspace-shows-cache', 'guard let selected = WorkspaceContext.selectedOrgID else { return false }',
        'guard let selected = WorkspaceContext.selectedOrgID else { return true }', 'nil live workspace cannot expose cached host houses'),
    ('missing-workspace-prompt', 'Config.useLiveBackend && workspaceStore.selected == nil', 'false', 'nil live workspace offers explicit selection'),
    ('home-ignores-workspace', '&& model.isInSelectedWorkspace($0)', '', 'actual Home hides old host inventory after private selection'),
    ('private-invite-role-picker', 'private var showsRolePicker: Bool { !privateTesting }',
        'private var showsRolePicker: Bool { true }', 'private invites hide shared-team role selection'),
    ('private-invite-role-dispatch', 'await send(email.isEmpty ? nil : email, invitationRole)',
        'await send(email.isEmpty ? nil : email, role)', 'actual private invite dispatch always requests agent allocation'),
]
results = []
for name, source, expected in [('actual', common, None)] + [
        (name, common.replace(old, new), failure) for name, old, new, failure in controls]:
    if expected is not None:
        assert source != common, name + ' must mutate a compiled actual body'
    directory = out / name; directory.mkdir(exist_ok=True)
    compiled = directory / 'Actual.swift'; compiled.write_text(source)
    executable = directory / 'testing-allowance'
    build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(compiled), str(paths[-1]), '-o', str(executable)], capture_output=True, text=True)
    (directory / 'compile.log').write_text(build.stdout + build.stderr)
    if build.returncode:
        raise SystemExit('Compilation is not runtime proof: ' + str(directory / 'compile.log'))
    run = subprocess.run([str(executable)], capture_output=True, text=True)
    output = run.stdout + run.stderr
    (directory / 'runtime.log').write_text(output)
    passed = run.returncode == 0 and 'Workspace testing allowance display:' in output if expected is None else run.returncode != 0 and expected in output and 'Fatal error:' in output
    results.append({'case': name, 'passed': passed, 'compileExit': build.returncode,
        'runtimeExit': run.returncode, 'expectedFailure': expected,
        'compiledSourceSHA256': hashlib.sha256(source.encode()).hexdigest()})
    if not passed: raise SystemExit('Actual policy check failed: ' + str(directory / 'runtime.log'))
bound = all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
receipt = {'passed': bound and all(result['passed'] for result in results), 'sourceBoundAtEnd': bound,
    'sourceSHA256': hashes, 'actual': results[0], 'controls': results[1:],
    'actualRuntimeOutput': (out / 'actual/runtime.log').read_text().strip(),
    'limits': 'Actual me mapping/DTO decode, five Settings usage calls/row, Team DTO/access/seat/join/removal/footer and NewInvite dispatch/access consumers, AppModel workspace predicate and Home filter/selection prompt compiled with held network and presentation interfaces. Listing/presentation/storage boundaries are synthetic; no files are erased. No real SwiftUI rendering, provider, purchase, camera, account or production request.'}
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'passed': receipt['passed'], 'sourceBoundAtEnd': bound,
    'output': receipt['actualRuntimeOutput'], 'compiledControls': len(results) - 1, 'receipt': str(out / 'receipt.json')}))
raise SystemExit(0 if receipt['passed'] else 1)
