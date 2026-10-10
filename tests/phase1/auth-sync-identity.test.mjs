import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const authPath = root + 'apps/ios/Rendprop/Auth/AuthStore.swift';
const auth = readFileSync(authPath, 'utf8');

function declaration(source, needle) {
  assert.equal(source.split(needle).length - 1, 1, `unique production declaration: ${needle}`);
  const begin = source.indexOf(needle);
  let end = source.indexOf('{', begin), depth = 1;
  while (depth && ++end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(begin, end + 1);
}

const scaffold = String.raw`
import Foundation
import CoreFoundation

// Only credential persistence, scheduling and transport are inert. These
// doubles never read the host's preferences, Keychain or network.
final class UserDefaults {
 static let standard = UserDefaults()
 private var values: [String: Any] = [:]
 func string(forKey key: String) -> String? { values[key] as? String }
 func data(forKey key: String) -> Data? { values[key] as? Data }
 func set(_ value: Any?, forKey key: String) { values[key] = value }
 func removeObject(forKey key: String) { values[key] = nil }
 func dictionaryRepresentation() -> [String: Any] { values }
 func synchronize() -> Bool { true }
}
enum Config {
 static let enableAuth = true
 static let supabaseURL: URL? = URL(string: "https://invalid.fixture")
 static let supabaseAnonKey = "synthetic-no-credential"
}
@MainActor final class URLSession {
 static let shared = URLSession()
 var bytes = Data(); var status = 200; var requests = 0
 var holdNext = false
 var waiter: CheckedContinuation<Void, Never>?
 func data(for request: URLRequest) async throws -> (Data, URLResponse) {
  precondition(request.url?.host == "invalid.fixture" && request.httpMethod == "POST")
  precondition(request.url?.query == "grant_type=refresh_token")
  requests += 1
  let result = (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  if holdNext { holdNext = false; await withCheckedContinuation { waiter = $0 } }
  return result
 }
 func release() { waiter?.resume(); waiter = nil }
}
// Push cleanup and purchase presentation have a separate executable account-switch harness.
@MainActor final class PushManager { static let shared = PushManager(); func accountWillChange(retainCleanup: Bool = true) {}; func accountDidChange() {} }
@MainActor final class PurchaseManager { static let shared = PurchaseManager(); func clearAccountPresentation() {} }
@MainActor enum AccountLocalPreferences { static func activate(previous: UUID?, next: UUID) {} }
@MainActor final class AuthStore {
 static let shared = AuthStore()
 var isSignedIn = false; var isIdentified = false; var userID: String?
 var displayName = ""; var userName = ""; var orgName = ""
 var onAccountChanged: ((UUID) -> Void)?
 var sessionEpoch: UInt64 = 0
 var syncIdentityEpoch: UInt64 = 0
 var anonymousBootstrap: Task<Void, Never>?
 var refreshInFlight: Task<Bool, Never>?
 var autoRefreshTask: Task<Void, Never>?
 struct Connection { func cancelAll() {} }
 let connection = Connection()
 enum Keys { static let userID = "id", userName = "name", orgName = "org" }
 static var access: String?; static var refresh: String?
 static func storedRefreshToken() -> String? { refresh }
 static func persistTokens(access: String, refresh: String?, expiresAt: Date?) { Self.access = access; Self.refresh = refresh }
 static func clearTokens() { access = nil; refresh = nil }
 func discardPendingAdoption() {}
 func scheduleAutoRefresh() {}
 AUTH_METHODS
}

@MainActor final class TestWire: ProductionSyncAPI {
 let listingID: UUID
 var writes = 0
 var document: CloudProductionDocument?
 init(_ listingID: UUID) { self.listingID = listingID }
 func productionPlan(listingID: UUID, orgID: UUID) async throws -> CloudProductionDocument? { document }
 func saveProductionPlan(_ plan: ProductionPlan, listingID: UUID, orgID: UUID, revision: Int) async throws -> CloudProductionDocument {
  writes += 1
  guard await AuthStore.shared.performRefresh() else { throw Failure.assertion("Fixture refresh failed") }
  let accepted = CloudProductionDocument(listing_id: listingID, revision: revision + 1, payload: plan)
  document = accepted
  return accepted
 }
}
enum Failure: Error { case assertion(String) }
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ ok: Bool, _ message: String) {
  checks += 1
  guard ok else { print("FAIL: " + message); exit(1) }
 }
 static func jwt(_ owner: String, anonymous: Bool = false) -> String {
  let bytes = try! JSONSerialization.data(withJSONObject: ["sub": owner, "is_anonymous": anonymous, "exp": Int(Date().timeIntervalSince1970) + 3600])
  return "synthetic." + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
 }
 static func reply(_ owner: String, anonymous: Bool = false) {
  URLSession.shared.status = 200
  URLSession.shared.bytes = try! JSONSerialization.data(withJSONObject: ["access_token": jwt(owner, anonymous: anonymous), "refresh_token": "rotated-synthetic", "expires_in": 3600])
 }
 static func main() async throws {
  let auth = AuthStore.shared
  let owner = UUID().uuidString.lowercased(), listingID = UUID(), orgID = UUID()
  auth.applySession(accessToken: jwt(owner), refreshToken: "synthetic", expiresAt: Date())
  let firstRevision = auth.syncSessionRevision, firstEpoch = auth.sessionEpoch
  let context = ProductionPlanSyncStore.Context(owner: owner, listingID: listingID)
  let identity = "\(owner):\(firstRevision)"
  let store = ProductionPlanSyncStore(), wire = TestWire(listingID)
  try store.load(context, serverID: listingID)
  var draft = store.drafts[context.key]!
  draft.plan.notes = "Phone instructions that must reach Studio"; draft.dirty = true
  try store.replace(draft, context: context)
  reply(owner)
  let saved = await store.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
  check(saved, "A same-account token refresh discarded the successful Studio plan receipt")
  check(auth.syncSessionRevision == firstRevision, "JWT rotation changed the cloud work identity")
  check(auth.sessionEpoch > firstEpoch, "JWT rotation must still advance the auth commit generation")
  check(store.drafts[context.key]?.revision == 1 && store.drafts[context.key]?.dirty == false && store.drafts[context.key]?.pendingWrite == nil, "Accepted plan must become clean at its exact cloud revision")
  check(wire.writes == 1 && URLSession.shared.requests == 1, "One save should need one write and one synthetic refresh")
  check(AuthStore.refresh == "rotated-synthetic", "The rotated credential must still commit")
  check(await auth.performRefresh(), "Repeated same-account refresh must succeed")
  check(auth.syncSessionRevision == firstRevision, "Repeated refresh stopped the remaining clip queue identity")

  auth.applySession(accessToken: jwt(owner), refreshToken: "synthetic", expiresAt: Date())
  check(auth.syncSessionRevision != firstRevision, "Explicit sign-in must invalidate outstanding work even for the same account")
  let denied = await store.save(context, serverID: listingID, orgID: orgID, api: wire, identity: identity)
  check(!denied && wire.writes == 1, "Stale-session writers must never dispatch")
  let beforeSignOut = auth.syncSessionRevision
  auth.signOut()
  check(auth.syncSessionRevision != beforeSignOut && !auth.isSignedIn, "Sign-out must invalidate cloud work immediately")
  auth.applySession(accessToken: jwt(owner), refreshToken: "synthetic", expiresAt: Date())
  let restored = auth.syncSessionRevision
  check(restored != firstRevision, "Sign-out and back into the same account must not revive old work")

  let nextOwner = UUID().uuidString.lowercased()
  var notified: UUID?
  auth.onAccountChanged = { notified = $0 }
  reply(nextOwner)
  check(!(await auth.performRefresh()), "A refresh carrying another account must refuse")
  check(auth.syncSessionRevision == restored && auth.userID == owner && notified == nil, "A foreign refresh must preserve the active account and local state")
  let identifiedRevision = auth.syncSessionRevision
  reply(nextOwner, anonymous: true)
  check(!(await auth.performRefresh()), "A refresh changing identity kind must refuse")
  check(auth.syncSessionRevision == identifiedRevision && auth.isIdentified, "An anonymous refresh cannot replace an identified session")

  auth.applySession(accessToken: jwt(owner), refreshToken: "synthetic", expiresAt: Date())
  reply(owner)
  URLSession.shared.holdNext = true
  let delayed = Task { await auth.performRefresh() }
  for _ in 0..<100 where URLSession.shared.waiter == nil { try await Task.sleep(nanoseconds: 1_000_000) }
  check(URLSession.shared.waiter != nil, "Delayed refresh must reach the fake transport")
  auth.signOut()
  let signedOutRevision = auth.syncSessionRevision
  URLSession.shared.release()
  check(!(await delayed.value), "A refresh from before sign-out must be rejected")
  check(AuthStore.access == nil && !auth.isSignedIn && auth.syncSessionRevision == signedOutRevision, "Late refresh must not restore a signed-out session")
  print("PASS: \(checks) production auth refresh and Studio writer assertions")
 }
}
`;

test('ordinary JWT rotation preserves cloud work while real session boundaries invalidate it', () => {
  const output = mkdtempSync(join(tmpdir(), 'rendprop-auth-sync-'));
  const names = ['var syncSessionRevision:', 'func applySession(', 'func signOut(', 'func performRefresh()',
    'static func jwtSubject(', 'static func tokenIsIdentified(', 'static func tokenPayload(',
    'static func tokenIdentityClaimIsValid(', 'static func jwtExpiry(', 'struct SupabaseSession:'];
  const methods = names.map(name => declaration(auth, name)).join('\n');
  const generated = scaffold.replace('AUTH_METHODS', methods);
  const files = ['Models/ProductionGuidance.swift', 'Networking/ProductionPlan.swift', 'Networking/ProductionPlanSyncStore.swift']
    .map(path => root + 'apps/ios/Rendprop/' + path);
  const results = [];
  for (const [name, source] of [
    ['actual', generated],
    ['token-generation-negative-control', generated.replace('var syncSessionRevision: UInt64 { syncIdentityEpoch }', 'var syncSessionRevision: UInt64 { sessionEpoch }')],
  ]) {
    if (name !== 'actual') assert.notEqual(source, generated, 'negative control must change the real sync revision getter');
    const swift = join(output, name + '.swift'), binary = join(output, name);
    writeFileSync(swift, source, { flag: 'wx' });
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', ...files, swift, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
    writeFileSync(join(output, name + '-compile.log'), compile.stdout + compile.stderr);
    assert.equal(compile.status, 0, compile.stderr);
    const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 15_000 });
    writeFileSync(join(output, name + '-run.log'), run.stdout + run.stderr);
    assert.equal(run.status, name === 'actual' ? 0 : 1, run.stdout + run.stderr);
    assert.match(run.stdout, name === 'actual' ? /PASS: 19 production auth refresh and Studio writer assertions/ : /same-account token refresh discarded the successful Studio plan receipt/);
    results.push({ name, exit: run.status, output: run.stdout.trim() });
  }
  writeFileSync(join(output, 'receipt.json'), JSON.stringify({ accepted: true, results,
    runtimeScope: 'Mechanically extracted production AuthStore methods plus complete production plan model and writer; inert credential storage, preferences, scheduling and transport',
    networkCalls: 0, sourceHashes: Object.fromEntries([authPath, ...files].map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
  }, null, 2) + '\n');
  console.log(`Auth/Studio synchronization evidence: ${output}`);
});
