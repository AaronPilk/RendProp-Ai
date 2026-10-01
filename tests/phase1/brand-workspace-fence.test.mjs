import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

function block(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, signature);
  let end = source.indexOf('{', start), depth = 1;
  while (depth && ++end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end + 1);
}

function run(out, name, source, expected) {
  const path = join(out, name + '.swift'), binary = join(out, name);
  writeFileSync(path, source);
  const compiled = spawnSync('/usr/bin/swiftc', ['-parse-as-library', path, '-o', binary], { encoding: 'utf8', timeout: 60000 });
  assert.equal(compiled.status, 0, compiled.stderr);
  const files = join(out, name + '-files'); mkdirSync(files);
  const result = spawnSync(binary, [files], { encoding: 'utf8', timeout: 10000 });
  writeFileSync(join(out, name + '.log'), result.stdout + result.stderr);
  assert.equal(result.status, expected, result.stdout + result.stderr);
  console.log(name + ': ' + result.stdout.trim());
}

test('actual delayed Apple-name seed stays bound to the original account and workspace', () => {
  const source = readFileSync(new URL('../../apps/ios/Rendprop/Auth/AuthStore.swift', import.meta.url), 'utf8');
  const body = block(source, '    @MainActor private static func seedBrandNameIfUnset(');
  const scaffold = String.raw`
import Foundation
struct CloudBrand { let userID: UUID; let orgID: UUID; let fields: [String: String] }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor enum AgentCard { struct Card { var isSet = false }; static var current = Card() }
@MainActor final class LiveAPIClient {
 var brand: CloudBrand!; var onRead: (() -> Void)?; var reads = 0; var patches: [(UUID, String)] = []
 func cloudBrand() async throws -> CloudBrand { reads += 1; onRead?(); return brand }
 func updateBrand(_ fields: [String: String], orgID: UUID) async throws { patches.append((orgID, fields["name"] ?? "")) }
}
@MainActor enum Config { static var api = LiveAPIClient(); static func makeAPIClient() -> Any { api } }
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1; var isSignedIn = true
 static func invoke(_ owner: UUID, _ org: UUID, revision: UInt64 = 1) async { await seedBrandNameIfUnset("Original agent", owner: owner.uuidString, orgID: org, revision: revision) }
BODY
}
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ ok: Bool, _ why: String) throws { checks += 1; if !ok { throw NSError(domain: why, code: 1) } }
 static func main() async { do { try await tests(); print("PASS: \(checks) actual brand seed checks") } catch { print("FAIL: \(error)"); exit(1) } }
 static func tests() async throws {
  let a = UUID(), b = UUID(), personal = UUID(), team = UUID(), auth = AuthStore.shared
  func reset() { auth.userID = a.uuidString; auth.syncSessionRevision = 1; auth.isSignedIn = true; WorkspaceContext.selectedOrgID = personal; AgentCard.current.isSet = false; Config.api = LiveAPIClient(); Config.api.brand = CloudBrand(userID: a, orgID: personal, fields: [:]) }
  reset(); await AuthStore.invoke(a, personal)
  try check(Config.api.patches.count == 1 && Config.api.patches.first?.0 == personal && Config.api.patches.first?.1 == "Original agent", "unchanged empty original workspace seeds once")
  reset(); auth.userID = b.uuidString; auth.syncSessionRevision = 2; await AuthStore.invoke(a, personal)
  try check(Config.api.reads == 0 && Config.api.patches.isEmpty, "queued old-account seed sends nothing")
  reset(); Config.api.onRead = { auth.userID = b.uuidString; auth.syncSessionRevision = 2 }; await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "account change during read cannot patch")
  reset(); Config.api.onRead = { WorkspaceContext.selectedOrgID = team; auth.syncSessionRevision = 2 }; await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "workspace change during read cannot patch")
  reset(); Config.api.onRead = { auth.syncSessionRevision = 3 }; await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "A-to-B-to-A still rejects old seed")
  reset(); Config.api.brand = CloudBrand(userID: a, orgID: team, fields: [:]); await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "mismatched server workspace cannot patch")
  reset(); Config.api.brand = CloudBrand(userID: b, orgID: personal, fields: [:]); await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "mismatched server account cannot patch")
  reset(); Config.api.onRead = { AgentCard.current.isSet = true }; await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "an agent card edited while reading is preserved")
  reset(); Config.api.brand = CloudBrand(userID: a, orgID: personal, fields: ["name": "Existing team"]); await AuthStore.invoke(a, personal)
  try check(Config.api.patches.isEmpty, "existing hosted name is preserved")
  reset(); auth.isSignedIn = false; await AuthStore.invoke(a, personal)
  try check(Config.api.reads == 0, "signed-out seed sends nothing")
 }
}
`;
  const out = mkdtempSync(join(tmpdir(), 'rendprop-brand-workspace-'));
  run(out, 'actual-seed', scaffold.replace('BODY', body), 0);
  const unfenced = body.replaceAll('shared.userID == owner', 'true').replaceAll('shared.syncSessionRevision == revision', 'true').replaceAll('WorkspaceContext.selectedOrgID == orgID', 'true');
  run(out, 'missing-seed-fences', scaffold.replace('BODY', unfenced), 1);
  console.log('Brand workspace evidence: ' + out);
});

test('actual portfolio selection and files cannot mix or overwrite another workspace export', () => {
  const source = readFileSync(new URL('../../apps/ios/Rendprop/Screens/SettingsView.swift', import.meta.url), 'utf8');
  const properties = ['private var workspaceListings:', 'private var shareable:', 'private var realCount:'].map(signature => block(source, signature).replace('private var', 'var')).join('\n');
  const eligible = block(source, '    static func eligible(');
  const build = block(source, '    static func build(listings: [Listing], agent: AgentCard, headshotBase64:');
  const scaffold = String.raw`
import Foundation
struct Price { var cents = 0; var formatted = "" }
struct Listing { let address: String; let org: UUID; var isSample = false; var isSold = false; var belongsToCurrentType = true; var serverShareURL: URL? = URL(string: "https://fixture.invalid/tour"); var mainPhotoURL: URL? = nil; var price = Price(); var subtitleLine = "Fixture" }
struct AgentCard { var isSet = true; var initials = "AA"; var name = "Selected agency"; var brokerageLine = "Agency"; var email = "fixture@invalid" }
struct SpaceType { static let current = SpaceType(); let spaceNoun = "home"; let spaceNounCap = "Home" }
enum Config { static let useLiveBackend = true }
enum WorkspaceContext { static var selectedOrgID: UUID? }
enum FileStore { static var documents: URL { URL(fileURLWithPath: CommandLine.arguments[1]) } }
struct Model { var listings: [Listing]; let selected: UUID; func isInSelectedWorkspace(_ listing: Listing) -> Bool { listing.org == selected } }
struct Profile { let model: Model
PROPERTIES
}
enum PortfolioExporter {
 static func esc(_ value: String) -> String { value }
 static func photoBase64(_ url: URL) -> String? { nil }
ELIGIBLE
BUILD
}
@main enum Main {
 static var checks = 0
 static func check(_ ok: Bool, _ why: String) throws { checks += 1; if !ok { throw NSError(domain: why, code: 1) } }
 static func main() { do { try tests(); print("PASS: \(checks) actual portfolio workspace checks") } catch { print("FAIL: \(error)"); exit(1) } }
 static func tests() throws {
  let a = UUID(), b = UUID(); let personal = Listing(address: "Personal listing", org: a), team = Listing(address: "Team listing", org: b)
  WorkspaceContext.selectedOrgID = b
  let profile = Profile(model: Model(listings: [personal, team], selected: b))
  try check(profile.realCount == 1 && profile.shareable.map(\.address) == ["Team listing"], "selected portfolio count and contents exclude personal workspace")
  let first = PortfolioExporter.build(listings: profile.workspaceListings, agent: AgentCard(), headshotBase64: "TEAM-HEADSHOT")!
  let firstBytes = try String(contentsOf: first, encoding: .utf8)
  try check(firstBytes.contains("Team listing") && !firstBytes.contains("Personal listing") && firstBytes.contains("TEAM-HEADSHOT"), "real HTML contains only selected listings and captured headshot")
  let second = PortfolioExporter.build(listings: [personal], agent: AgentCard(), headshotBase64: "PERSONAL-HEADSHOT")!
  try check(first != second, "concurrent workspace exports have independent files")
  try check(try String(contentsOf: first, encoding: .utf8) == firstBytes, "later export leaves earlier share file unchanged")
  WorkspaceContext.selectedOrgID = nil
  try check(profile.workspaceListings.isEmpty && profile.shareable.isEmpty, "unconfirmed workspace cannot export all stored workspaces")
 }
}
`;
  const render = (props, builder) => scaffold.replace('PROPERTIES', props).replace('ELIGIBLE', eligible).replace('BUILD', builder);
  const out = mkdtempSync(join(tmpdir(), 'rendprop-portfolio-workspace-'));
  run(out, 'actual-portfolio', render(properties, build), 0);
  run(out, 'missing-workspace-filter', render(properties.replace('model.listings.filter { model.isInSelectedWorkspace($0) }', 'model.listings'), build), 1);
  run(out, 'shared-export-file', render(properties, build.replace('rendprop-portfolio-\\(UUID().uuidString.lowercased()).html', 'rendprop-portfolio.html')), 1);
  console.log('Portfolio workspace evidence: ' + out);
});
