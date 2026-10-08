import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

test('actual request executor never sends or retries a former account request as another account', () => {
  const file = new URL('../../apps/ios/Rendprop/Networking/LiveAPIClient.swift', import.meta.url);
  const source = readFileSync(file, 'utf8');
  const start = source.indexOf('    @MainActor private func execute(');
  assert.ok(start >= 0);
  let end = source.indexOf('{', start), depth = 1;
  while (depth && ++end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  const body = source.slice(start, end + 1);
  const scaffold = String.raw`
import Foundation
enum Config { static let enableAuth = true }
enum APIError: Error { case badResponse(Int) }
enum CloudSyncError: Error { case identityChanged }
@MainActor final class AuthStore {
 static let shared = AuthStore()
 var userID: String?; var syncSessionRevision: UInt64 = 1; var isSignedIn = true
 var token = ""; var signOuts = 0; var refreshes = 0; var usableToken = true; var adoptionDiscards = 0
 var onToken: (() async -> Void)?; var onRefresh: (() async -> Void)?
 static func validAccessToken() async -> String? { await shared.onToken?(); return shared.usableToken ? shared.token : nil }
 static func storedAccessToken() -> String? { shared.token }
 func forceRefresh() async -> Bool { refreshes += 1; await onRefresh?(); return true }
 func signOut(preservingAdoption: Bool = false) { signOuts += 1; isSignedIn = false; syncSessionRevision += 1; if !preservingAdoption { adoptionDiscards += 1 } }
 func reset(_ id: UUID) { userID = id.uuidString.lowercased(); token = jwt(id); syncSessionRevision = 1; isSignedIn = true; usableToken = true; adoptionDiscards = 0; signOuts = 0; refreshes = 0; onToken = nil; onRefresh = nil }
 func change(_ id: UUID) { userID = id.uuidString.lowercased(); token = jwt(id); syncSessionRevision += 1 }
 func jwt(_ id: UUID) -> String {
  let data = try! JSONSerialization.data(withJSONObject: ["sub": id.uuidString.lowercased(), "is_anonymous": false])
  return "e30." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".synthetic"
 }
}
@MainActor final class URLSession {
 var requests: [URLRequest] = []; var codes: [Int] = [200]
 var onSend: ((Int) async -> Void)?
 func data(for request: URLRequest) async throws -> (Data, URLResponse) {
  let index = requests.count; requests.append(request); await onSend?(index)
  return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: codes[min(index, codes.count - 1)], httpVersion: nil, headerFields: nil)!)
 }
}
@MainActor final class LiveAPIClient {
 let session = URLSession()
 let base = URL(string: "https://fixture.invalid")!
 func call(_ request: URLRequest) async throws -> Data { try await execute(request) }
 static func serverError(status: Int, data: Data) -> APIError { .badResponse(status) }
EXECUTOR
}
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ ok: Bool, _ message: String) throws { checks += 1; if !ok { throw NSError(domain: message, code: 1) } }
 static func main() async {
  do { try await run(); print("PASS: \(checks) actual request account-fence checks") }
  catch { print("FAIL: \(error)"); exit(1) }
 }
 static func run() async throws {
  let a = UUID(), b = UUID(), auth = AuthStore.shared
  func request() -> URLRequest {
   var value = URLRequest(url: URL(string: "https://fixture.invalid/listings")!)
   value.httpMethod = "POST"; value.httpBody = Data("private-A-listing".utf8)
   value.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization"); value.setValue("synthetic-public", forHTTPHeaderField: "apikey"); return value
  }
  func denied(_ client: LiveAPIClient, _ value: URLRequest) async throws {
   do { _ = try await client.call(value); throw NSError(domain: "Cross-account request was accepted", code: 1) }
   catch CloudSyncError.identityChanged { checks += 1 }
  }
  auth.reset(a)
  let normal = LiveAPIClient(); normal.session.codes = [401, 200]
  _ = try await normal.call(request())
  try check(normal.session.requests.count == 2 && auth.refreshes == 1, "Same-account refresh still retries exactly once")

  auth.reset(a); let expired = LiveAPIClient(); let expiredRequest = request(); auth.usableToken = false
  _ = try await expired.call(expiredRequest)
  try check(expired.session.requests.count == 1 && expired.session.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "Failed offline refresh removes inherited expired bearer before dispatch")
  try check(expired.session.requests[0].value(forHTTPHeaderField: "apikey") == "synthetic-public", "Missing JWT preserves the public API key header")

  auth.reset(a); let revoked = LiveAPIClient(); revoked.session.codes = [401, 401]
  do { _ = try await revoked.call(request()) } catch APIError.badResponse(401) {}
  try check(revoked.session.requests.count == 2 && auth.signOuts == 1 && auth.adoptionDiscards == 0, "Second rejected bearer preserves pending guest adoption evidence")

  auth.reset(a); let queued = LiveAPIClient(); let oldRequest = request(); auth.change(b)
  try await denied(queued, oldRequest)
  try check(queued.session.requests.isEmpty, "Already-assembled A request cannot be rebound to B on actor hop")

  auth.reset(a); let initial = LiveAPIClient(); let initialRequest = request()
  auth.onToken = { auth.change(b) }
  try await denied(initial, initialRequest)
  try check(initial.session.requests.isEmpty, "Account change during initial token acquisition sends nothing")

  auth.reset(a); let stale401 = LiveAPIClient(); stale401.session.codes = [401]
  stale401.session.onSend = { _ in auth.change(b) }
  try await denied(stale401, request())
  try check(stale401.session.requests.count == 1 && auth.refreshes == 0 && auth.signOuts == 0, "Old 401 neither refreshes nor signs out replacement account")

  auth.reset(a); let refresh = LiveAPIClient(); refresh.session.codes = [401, 200]
  auth.onRefresh = { auth.change(b) }
  try await denied(refresh, request())
  try check(refresh.session.requests.count == 1, "Account change during forced refresh cannot retry A body with B bearer")

  auth.reset(a); let second401 = LiveAPIClient(); second401.session.codes = [401, 401]
  second401.session.onSend = { index in if index == 1 { auth.change(b) } }
  try await denied(second401, request())
  try check(auth.signOuts == 0 && auth.isSignedIn && auth.userID == b.uuidString.lowercased(), "Late second 401 cannot sign out B")

  auth.reset(a); let success = LiveAPIClient(); success.session.onSend = { _ in auth.change(b); auth.change(a) }
  try await denied(success, request())
  try check(auth.syncSessionRevision == 3, "A to B to A rejects old success despite same final user")
 }
}
`;
  const out = mkdtempSync(join(tmpdir(), 'rendprop-request-fence-'));
  for (const [name, implementation] of [
    ['actual', body],
    ['missing-epoch-fences', body.replaceAll('guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }', '')],
    ['keep-stale-bearer', body.replace('request.setValue(token.map { "Bearer \\($0)" }, forHTTPHeaderField: "Authorization")', 'if let token { request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization") }')],
    ['drop-forced-adoption-recovery', body.replace('signOut(preservingAdoption: true)', 'signOut()')],
  ]) {
    const path = join(out, `${name}.swift`), binary = join(out, name);
    writeFileSync(path, scaffold.replace('EXECUTOR', implementation));
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', fileURLToPath(new URL('../../apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift', import.meta.url)), path, '-o', binary], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
    writeFileSync(join(out, name + '.log'), result.stdout + result.stderr);
    assert.equal(result.status, name === 'actual' ? 0 : 1, result.stdout + result.stderr);
    if (name === 'keep-stale-bearer') assert.match(result.stdout, /Failed offline refresh removes inherited expired bearer before dispatch/);
    if (name === 'drop-forced-adoption-recovery') assert.match(result.stdout, /Second rejected bearer preserves pending guest adoption evidence/);
    console.log(name + ': ' + result.stdout.trim());
  }
  console.log('Request-fence evidence: ' + out);
});

test('actual team transport fences invite and join identity and retains selected workspace headers', () => {
  const source = readFileSync(new URL('../../apps/ios/Rendprop/Team/TeamAPI.swift', import.meta.url), 'utf8');
  const scaffold = String.raw`
import Foundation
enum Config { static let apiBaseURL: URL? = URL(string: "https://fixture.invalid/functions/v1"); static let supabaseAnonKey = "fixture" }
enum CloudSyncError: Error { case identityChanged }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1
 var onToken: (() async -> Void)?
 static func validAccessToken() async -> String? { await shared.onToken?(); return shared.userID }
 func reset(_ id: UUID) { userID = id.uuidString; syncSessionRevision = 1; onToken = nil; URLSession.shared.requests = []; URLSession.shared.onSend = nil }
 func change(_ id: UUID) { userID = id.uuidString; syncSessionRevision += 1 }
}
@MainActor final class URLSession {
 static let shared = URLSession(); var requests: [URLRequest] = []; var onSend: (() async -> Void)?
 func data(for request: URLRequest) async throws -> (Data, URLResponse) {
  requests.append(request); await onSend?()
  let json = "{\"id\":\"invite-A\",\"role\":\"agent\",\"code\":\"private-A-code\",\"email_queued\":true}"
  return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
 }
}
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ condition: Bool, _ message: String) throws { checks += 1; if !condition { throw NSError(domain: message, code: 1) } }
 static func denied() async throws {
  do { _ = try await TeamAPI.invite(email: nil); throw NSError(domain: "Old invite was delivered to replacement account", code: 1) }
  catch CloudSyncError.identityChanged { checks += 1 }
 }
 static func main() async {
  do {
   let a = UUID(), b = UUID(), org = UUID(), auth = AuthStore.shared
   auth.reset(a); WorkspaceContext.selectedOrgID = org
   let invite = try await TeamAPI.invite(email: nil)
   try check(invite.emailQueued == true, "Queued delivery decodes without claiming delivered")
   try check(URLSession.shared.requests.first?.value(forHTTPHeaderField: "X-Org-Id") == org.uuidString.lowercased(), "Team write pins selected workspace")
   auth.reset(a); auth.onToken = { auth.change(b) }; try await denied()
   try check(URLSession.shared.requests.isEmpty, "Initial refresh switch sends nothing")
   auth.reset(a); URLSession.shared.onSend = { auth.change(b) }; try await denied()
   try check(URLSession.shared.requests.count == 1, "Stale success never returns private invite code")
   auth.reset(a); URLSession.shared.onSend = { auth.change(b); auth.change(a) }; try await denied()
   try check(auth.syncSessionRevision == 3, "Same final account cannot accept old session invite")
   print("PASS: \(checks) actual team account/workspace checks")
  } catch { print("FAIL: \(error)"); exit(1) }
 }
}
`;
  const out = mkdtempSync(join(tmpdir(), 'rendprop-team-fence-'));
  for (const [name, implementation] of [['actual', source], ['missing-fences', source.replaceAll('guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }', '')]]) {
    const path = join(out, `${name}.swift`), fixture = join(out, 'fixture.swift'), binary = join(out, name);
    writeFileSync(path, implementation); writeFileSync(fixture, scaffold);
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', path, fixture, '-o', binary], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 10000 });
    writeFileSync(join(out, name + '.log'), result.stdout + result.stderr);
    assert.equal(result.status, name === 'actual' ? 0 : 1, result.stdout + result.stderr);
    console.log(name + ': ' + result.stdout.trim());
  }
  console.log('Team-fence evidence: ' + out);
});
