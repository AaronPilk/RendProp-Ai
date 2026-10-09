import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

test('actual workspace state preserves per-account choices, validates membership and fences late replies', () => {
 const base = new URL('../../apps/ios/Rendprop/Workspace/', import.meta.url);
 const out = mkdtempSync(join(tmpdir(), 'rendprop-workspace-'));
 const fixture = String.raw`
import Foundation
// Actual Foundation preferences in an isolated temporary suite; never host app data.
final class UserDefaults {
 static let suite = "RendpropWorkspaceTests." + UUID().uuidString
 static let standard = UserDefaults(); private let storage = Foundation.UserDefaults(suiteName: suite)!
 func string(forKey key: String) -> String? { storage.string(forKey: key) }
 func data(forKey key: String) -> Data? { storage.data(forKey: key) }
 func set(_ value: Any?, forKey key: String) { storage.set(value, forKey: key) }
 func synchronize() -> Bool { storage.synchronize() }
 static func clear() { Foundation.UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
}
enum Config { static let useLiveBackend = true; static let apiBaseURL: URL? = URL(string: "https://fixture.invalid/functions/v1"); static let supabaseAnonKey = "fixture" }
enum CloudSyncError: Error { case identityChanged, invalidResponse }
enum APIError: Error { case notConfigured, badResponse(Int), decoding, server(status: Int, code: String?, message: String) }
enum UserFacingError { static func message(_ error: Error, fallback: String) -> String { fallback } }
enum LiveAPIClient { static func serverError(status: Int, data: Data) -> APIError { .badResponse(status) } }
extension Notification.Name { static let rendpropPlanChanged = Notification.Name("fixture.planChanged") }
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1; var orgName = ""
 var onToken: (() async -> Void)?
 static func validAccessToken() async -> String? { await shared.onToken?(); return shared.userID }
 func change(_ owner: UUID) { userID = owner.uuidString.lowercased(); UserDefaults.standard.set(userID, forKey: "auth.supabase.userID"); syncSessionRevision += 1 }
 func workspaceDidChange() { syncSessionRevision += 1 }
}
@MainActor final class URLSession {
 static let shared = URLSession(); var requests: [URLRequest] = []; var response: Data = Data(); var status = 200; var onSend: (() async -> Void)?; var transportFailure = false
 func data(for request: URLRequest) async throws -> (Data, URLResponse) {
  if transportFailure { throw URLError(.notConnectedToInternet) }
  requests.append(request); let result = response; let code = status; await onSend?()
  return (result, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
 }
 func answer(_ value: [String: Any]) throws { response = try JSONSerialization.data(withJSONObject: value); status = 200; onSend = nil; transportFailure = false }
}
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ condition: Bool, _ name: String) throws { checks += 1; if !condition { throw NSError(domain: name, code: 1) } }
 static func main() async {
  defer { UserDefaults.clear() }
  do {
   let owner = UUID(), other = UUID(), a = UUID(), b = UUID(), auth = AuthStore.shared, transport = URLSession.shared
   auth.change(owner)
   let personal = WorkspaceMembership(id: a, name: "My studio", role: "owner", accessMode: "own", libraryOwnerUserID: owner, billingOrgID: a, canRead: true, canWrite: true, canManageSubscription: true)
   let team = WorkspaceMembership(id: b, name: "Agent's listings", role: "team_owner", accessMode: "team_owner", libraryOwnerUserID: other, billingOrgID: a, canRead: true, canWrite: true, canManageSubscription: false)
   let all: [[String: Any]] = [["id": a.uuidString, "name": "My studio", "role": "owner", "access_mode": "own", "library_owner_user_id": owner.uuidString, "billing_org_id": a.uuidString, "can_read": true, "can_write": true, "can_manage_subscription": true], ["id": b.uuidString, "name": "Agent's listings", "role": "team_owner", "access_mode": "team_owner", "library_owner_user_id": other.uuidString, "billing_org_id": a.uuidString, "can_read": true, "can_write": true, "can_manage_subscription": false]]
   func directory(active: UUID, rows: [[String: Any]] = all, canSwitch: Bool = true, actor: UUID = owner) -> [String: Any] {
    ["actor_id": actor.uuidString, "own_org_id": a.uuidString, "billing_org_id": a.uuidString, "can_switch_agent_libraries": canSwitch, "active_org_id": active.uuidString, "workspaces": rows]
   }
   try transport.answer(directory(active: a))
   let store = WorkspaceStore(); await store.refresh()
   try check(store.selected?.id == a && WorkspaceContext.selectedOrgID == a, "First bootstrap chooses validated server active membership")
   let revision = auth.syncSessionRevision
   try transport.answer(["org_id": b.uuidString]); try check(await store.select(team), "Explicit team selection succeeds")
   try check(auth.syncSessionRevision == revision + 1 && WorkspaceContext.selectedOrgID == b, "Selection advances shared response epoch")
   let body = try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as! [String: String]
   try check(body["org_id"] == b.uuidString.lowercased(), "Server selection writes only requested workspace")
   let reopened = WorkspaceStore()
   try check(reopened.snapshot?.selectedOrgID == b && reopened.selected == nil, "Relaunch retains choice but cached delegation cannot reopen another agent's cards")
   try transport.answer(directory(active: a)); await reopened.refresh()
   try check(reopened.selected?.id == b, "Another device's active selection cannot retarget this device")
   auth.change(other); try check(WorkspaceContext.selectedOrgID == nil, "Other account cannot inherit saved org")
   try check(WorkspaceContext.storagePrefix.contains("unselected"), "Unselected account cannot read legacy branding keys")
   auth.change(owner)
   try transport.answer(directory(active: a, rows: [all[0]], canSwitch: false)); await reopened.refresh()
   try check(reopened.selected == personal && reopened.workspaces == [personal] && !reopened.canSwitchAgentLibraries, "Fresh own-only directory recovers old Team selection into actor's private library")
   try check(!(await reopened.select(team)), "Removed team cannot be selected from stale row")
   try check(!WorkspaceContext.save(.init(selectedOrgID: b, workspaces: [personal]), owner: owner), "Invalid selection fails closed")
   try check(!WorkspaceContext.save(.init(selectedOrgID: a, workspaces: [personal, personal]), owner: owner), "Duplicate membership snapshot is rejected")
   try transport.answer(directory(active: b)); await reopened.refresh()
   try transport.answer(["org_id": b.uuidString]); try check(await reopened.select(team), "Restore fresh delegated authority for asynchronous selection controls")
   try transport.answer(["org_id": a.uuidString]); transport.onSend = { auth.change(other) }
   try check(!(await reopened.select(personal)), "Late selection after account switch is rejected")
   try check(WorkspaceContext.read(owner: owner)?.selectedOrgID == b, "Stale reply does not overwrite source cache")
   auth.change(owner); try transport.answer(directory(active: b)); await reopened.refresh()
   transport.requests = []; auth.onToken = { auth.change(other) }
   try check(!(await reopened.select(personal)) && transport.requests.isEmpty, "Identity change during token acquisition sends nothing")
   auth.onToken = nil; auth.change(owner); try transport.answer(directory(active: b)); await reopened.refresh()
   try transport.answer(["org_id": a.uuidString]); transport.onSend = { auth.workspaceDidChange() }
   try check(!(await reopened.select(personal)), "Same-user workspace epoch invalidates old switch result")
   try check(WorkspaceContext.read(owner: owner)?.selectedOrgID == b, "Same-user stale switch cannot retarget persisted content")
   try transport.answer(directory(active: b)); await reopened.refresh()
   try check(reopened.canViewLibrary(b), "Fresh actual Team owner can view exact linked agent library")
   transport.status = 403; await reopened.refresh()
   try check(reopened.selected == nil && !reopened.canSwitchAgentLibraries && !reopened.canViewLibrary(b), "Permission refusal clears delegated authority immediately")
   try check(WorkspaceContext.read(owner: owner)?.workspaces == [personal], "Revocation keeps own account metadata without sibling rows")
   try transport.answer(directory(active: a, rows: [all[0]], canSwitch: false)); await reopened.refresh()
   transport.transportFailure = true; await reopened.refresh()
   try check(reopened.selected == personal, "Ordinary transport outage preserves own offline library")
   try check(WorkspaceEntryPresentation.mode(canSwitch: reopened.canSwitchAgentLibraries, choices: reopened.selectionChoices.count, selected: true, showsRecovery: true) == .hidden, "Ordinary own account has no agent switcher")
   try check(WorkspaceEntryPresentation.mode(canSwitch: false, choices: 0, selected: false, showsRecovery: true) == .reconnect, "Ordinary disconnected account offers reconnect instead of agent picker")
   try transport.answer(directory(active: b, canSwitch: false)); await reopened.refresh()
   try check(reopened.selected == nil && !reopened.canViewLibrary(b), "Private owner role cannot infer cross-agent authority from directory rows")
   try transport.answer(directory(active: a, rows: [all[0]], canSwitch: false, actor: other)); await reopened.refresh()
   try check(reopened.selected == nil && reopened.workspaces.isEmpty, "Foreign actor directory cannot establish own library or choices")
   print("PASS: \(checks) actual workspace selection checks")
  } catch { print("FAIL: \(error)"); exit(1) }
 }
}
`;
 const path = join(out, 'fixture.swift'); writeFileSync(path, fixture);
 const files = ['WorkspaceContext.swift', 'WorkspaceStore.swift'].map(name => fileURLToPath(new URL(name, base)));
 const context = readFileSync(files[0], 'utf8'), store = readFileSync(files[1], 'utf8');
 const revocationGuard = 'if Self.isAuthorityFailure(error) { invalidateAuthority(owner: owner) }';
 assert.equal(store.split(revocationGuard).length - 1, 2, 'Both refresh and switch authority refusals must remain guarded');
 assert.ok(context.includes('actorID == actor'), 'Directory actor validation must remain present');
 const variants = [
  ['actual', context, store, null],
  ['keep-revoked-delegation', context, store.replaceAll(revocationGuard, ''), /Permission refusal clears delegated authority immediately/],
  ['accept-foreign-directory', context.replace('actorID == actor', 'true'), store, /Foreign actor directory cannot establish own library or choices/],
 ];
 for (const [name, contextSource, storeSource, failure] of variants) {
  const contextPath = join(out, name + '-context.swift'), storePath = join(out, name + '-store.swift'), binary = join(out, name);
  writeFileSync(contextPath, contextSource); writeFileSync(storePath, storeSource);
  const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', contextPath, storePath, path, '-o', binary], { encoding: 'utf8', timeout: 60000 });
  writeFileSync(join(out, name + '-compile.log'), compile.stdout + compile.stderr);
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
  writeFileSync(join(out, name + '.log'), run.stdout + run.stderr);
  assert.equal(run.status, failure ? 1 : 0, run.stdout + run.stderr);
  if (failure) assert.match(run.stdout, failure);
  console.log(name + ': ' + run.stdout.trim());
 }
 console.log('Workspace evidence: ' + out);
});
