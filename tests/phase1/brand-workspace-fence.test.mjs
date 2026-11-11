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

test('actual cloud brand preserves a newer business selection and rejects an old identity', () => {
  const app = readFileSync(new URL('../../apps/ios/Rendprop/RendpropApp.swift', import.meta.url), 'utf8');
  const settings = readFileSync(new URL('../../apps/ios/Rendprop/Screens/SettingsView.swift', import.meta.url), 'utf8');
  const onboarding = readFileSync(new URL('../../apps/ios/Rendprop/Screens/OnboardingView.swift', import.meta.url), 'utf8');
  assert.match(app, /let brandRead = CloudBrandReadContext\(/);
  assert.match(app, /self\.acceptCloudBrand\(brand, personalReadVersion: personalReadVersion, read: brandRead\)/);
  assert.match(block(app, '    func syncSpaceTypeIfNeeded()'), /spaceTypeSyncGeneration &\+= 1/);
  assert.match(block(app, '    private var businessTypeMenu:'), /BusinessTypeSelectionRevision\.recordChoice\(\)/);
  assert.match(settings, /BusinessTypeSelectionRevision\.recordChoice\(\)/);
  assert.match(onboarding, /BusinessTypeSelectionRevision\.recordChoice\(\)/);
  const revision = '@MainActor\n' + block(app, 'enum BusinessTypeSelectionRevision');
  const context = '@MainActor\n' + block(app, 'private struct CloudBrandReadContext');
  const apply = block(app, '    private func acceptCloudBrand(');
  const accept = block(settings, '    @MainActor static func acceptCloud(_ brand: CloudBrand,');
  const scaffold = String.raw`
import Foundation
struct PersonalCard { let userID: UUID }
struct CloudBrand { let userID: UUID; let orgID: UUID; let spaceType: String; let fields: [String: String]; let personalCard: PersonalCard? }
enum SpaceType: String {
 case realEstate = "real_estate", venue, restaurant, retail, fitness, other
 static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "space.type") ?? "") ?? .realEstate }
}
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext {
 static var selectedOrgID: UUID?
 static var storagePrefix: String { "workspace.\(AuthStore.shared.userID ?? "none").\(selectedOrgID?.uuidString ?? "none")." }
}
@MainActor enum ProfileLogoStore {
 static var accepted = 0
 static func acceptHostedURL(_ value: String?, prefix: String) { accepted += 1 }
}
@MainActor enum PersonalCardStore {
 static var accepted = 0
 static func accept(_ card: PersonalCard) throws { accepted += 1 }
}
extension Notification.Name { static let rendpropCloudBrandUpdated = Notification.Name("brand.updated") }
REVISION
CONTEXT
struct AgentCard {
 static var personalReadVersion = 0
 static func migrateLegacyIfNeeded(owner: UUID, org: UUID) {}
ACCEPT
}
@MainActor final class AppModel {
 var spaceTypeSyncOperation: UUID?
 var spaceTypeSyncGeneration: UInt64 = 0
 var syncCalls = 0
 func syncSpaceTypeIfNeeded() {
  if UserDefaults.standard.string(forKey: WorkspaceContext.storagePrefix + "space.type.synced") != SpaceType.current.rawValue { syncCalls += 1 }
 }
APPLY
 func read(_ brand: CloudBrand, after: () -> Void = {}) async {
  let read = CloudBrandReadContext(actorID: AuthStore.shared.userID,
                                   sessionRevision: AuthStore.shared.syncSessionRevision,
                                   syncOperation: spaceTypeSyncOperation,
                                   syncGeneration: spaceTypeSyncGeneration)
  await Task.yield()
  after()
  acceptCloudBrand(brand, personalReadVersion: AgentCard.personalReadVersion, read: read)
 }
}
@main @MainActor enum Main {
 static var checks = 0
 static func check(_ ok: Bool, _ why: String) throws { checks += 1; if !ok { throw NSError(domain: why, code: 1) } }
 static func main() async { do { try await tests(); print("PASS: \(checks) actual brand type/identity checks") } catch { print("FAIL: \(error)"); exit(1) } }
 static func tests() async throws {
  let owner = UUID(), other = UUID(), org = UUID(), anotherOrg = UUID()
  let auth = AuthStore.shared, defaults = UserDefaults.standard
  let brand = CloudBrand(userID: owner, orgID: org, spaceType: SpaceType.restaurant.rawValue,
                         fields: ["business_logo_url": "https://fixture.invalid/logo"], personalCard: PersonalCard(userID: owner))
  func reset(initialized: Bool = true, raw: String = SpaceType.realEstate.rawValue, marker: String? = SpaceType.realEstate.rawValue) -> AppModel {
   auth.userID = owner.uuidString; auth.syncSessionRevision += 1; WorkspaceContext.selectedOrgID = org
   defaults.set(raw, forKey: "space.type")
   let prefix = WorkspaceContext.storagePrefix
   defaults.set(initialized, forKey: prefix + "brand.initialized")
   if let marker { defaults.set(marker, forKey: prefix + "space.type.synced") }
   else { defaults.removeObject(forKey: prefix + "space.type.synced") }
   ProfileLogoStore.accepted = 0; PersonalCardStore.accepted = 0
   return AppModel()
  }
  var model = reset()
  await model.read(brand)
  try check(SpaceType.current == .restaurant && defaults.string(forKey: WorkspaceContext.storagePrefix + "space.type.synced") == SpaceType.restaurant.rawValue, "unchanged brand read hydrates selected type")
  try check(model.syncCalls == 0 && ProfileLogoStore.accepted == 1 && PersonalCardStore.accepted == 1, "unchanged read accepts personal brand without extra sync")

  model = reset()
  await model.read(brand) { defaults.set(SpaceType.venue.rawValue, forKey: "space.type") }
  try check(SpaceType.current == .venue && defaults.string(forKey: WorkspaceContext.storagePrefix + "space.type.synced") == SpaceType.realEstate.rawValue, "same-account newer selection cannot be overwritten or falsely acknowledged")
  try check(model.syncCalls == 1 && ProfileLogoStore.accepted == 1 && PersonalCardStore.accepted == 1, "stale type still accepts scoped logo/card and queues selected type sync")

  model = reset(raw: SpaceType.venue.rawValue)
  await model.read(brand)
  try check(SpaceType.current == .venue && model.syncCalls == 1, "an already pending local choice stays authoritative")

  model = reset()
  model.spaceTypeSyncOperation = UUID()
  await model.read(brand) { model.spaceTypeSyncOperation = nil }
  try check(SpaceType.current == .realEstate && model.syncCalls == 0, "overlapping type PATCH prevents older GET from rolling back its selection")

  model = reset()
  await model.read(brand) { defaults.set(SpaceType.venue.rawValue, forKey: WorkspaceContext.storagePrefix + "space.type.synced") }
  try check(SpaceType.current == .realEstate && model.syncCalls == 1, "changed acceptance marker blocks an out-of-order GET")

  model = reset()
  await model.read(brand) {
   BusinessTypeSelectionRevision.recordChoice()
   defaults.set(SpaceType.venue.rawValue, forKey: "space.type")
   BusinessTypeSelectionRevision.recordChoice()
   defaults.set(SpaceType.realEstate.rawValue, forKey: "space.type")
  }
  try check(SpaceType.current == .realEstate && model.syncCalls == 0, "A-to-B-to-A user choices remain visible even when SwiftUI coalesces change callbacks")

  model = reset()
  await model.read(brand) { model.spaceTypeSyncGeneration &+= 2 }
  try check(SpaceType.current == .realEstate && model.syncCalls == 0, "two completed PATCHes returning the original raw value still invalidate an older GET")

  model = reset()
  await model.read(brand) { auth.userID = other.uuidString; auth.syncSessionRevision += 1 }
  try check(SpaceType.current == .realEstate && ProfileLogoStore.accepted == 0 && PersonalCardStore.accepted == 0 && model.syncCalls == 0, "account change blocks all old brand fields")

  model = reset()
  await model.read(brand) { auth.syncSessionRevision += 1 }
  try check(SpaceType.current == .realEstate && ProfileLogoStore.accepted == 0 && model.syncCalls == 0, "same actor with a new session rejects old brand read")

  model = reset()
  await model.read(brand) { WorkspaceContext.selectedOrgID = anotherOrg }
  try check(SpaceType.current == .realEstate && ProfileLogoStore.accepted == 0 && model.syncCalls == 0, "workspace change rejects old brand read")

  model = reset(initialized: false, marker: nil)
  await model.read(brand)
  try check(SpaceType.current == .restaurant && model.syncCalls == 0, "first brand hydration can recover a server business type")
 }
}
`;
  const render = (r, c, a, x) => scaffold.replace('REVISION', r).replace('CONTEXT', c).replace('APPLY', a).replace('ACCEPT', x);
  const out = mkdtempSync(join(tmpdir(), 'rendprop-brand-type-race-'));
  run(out, 'actual-brand-type', render(revision, context, apply, accept), 0);
  run(out, 'missing-local-selection-fence', render(revision, context.replace('localType == SpaceType.current.rawValue &&', 'true &&'), apply, accept), 1);
  run(out, 'missing-choice-generation', render(revision, context.replace('selectionRevision == BusinessTypeSelectionRevision.current &&', 'true &&'), apply, accept), 1);
  run(out, 'missing-sync-generation', render(revision, context.replace('syncGeneration == currentSyncGeneration &&', 'true &&'), apply, accept), 1);
  run(out, 'missing-identity-fence', render(revision, context, apply.replace('guard read.matches(brand) else { return }', ''), accept), 1);
  run(out, 'forced-cloud-type-overwrite', render(revision, context, apply, accept.replace('if applySpaceType {', 'if true {')), 1);
  console.log('Brand type race evidence: ' + out);
});

test('actual portfolio selection and files cannot mix or overwrite another workspace export', () => {
  const source = readFileSync(new URL('../../apps/ios/Rendprop/Screens/SettingsView.swift', import.meta.url), 'utf8');
  const properties = ['private var workspaceListings:', 'private var shareable:', 'private var realCount:'].map(signature => block(source, signature).replace('private var', 'var')).join('\n');
  const eligible = block(source, '    static func eligible(');
  const selected = block(source, '    static func selected(');
  const phone = block(readFileSync(new URL('../../apps/ios/Rendprop/Models/ListingClientContact.swift', import.meta.url), 'utf8'), 'enum PhoneNumberPresentation');
  const build = block(source, '    static func build(listings: [Listing], agent: AgentCard, headshotBase64:');
  const scaffold = String.raw`
import Foundation
struct Price { var cents = 0; var formatted = "" }
struct Listing { var id = UUID(); let address: String; let org: UUID; var serverOrgID: UUID? { org }; var isSample = false; var isSold = false; var cloudUnavailable: Bool? = nil; var spaceType = SpaceType.current; var belongsToCurrentType = true; var serverShareURL: URL? = URL(string: "https://fixture.invalid/tour"); var mainPhotoURL: URL? = nil; var price = Price(); var subtitleLine = "Fixture" }
struct AgentCard { var isSet = true; var initials = "AA"; var name = "Selected agency"; var brokerage = "Agency"; var phone = "+44 20 7946 0958"; var email = "fixture@invalid"; var publicBusinessLogoURL: String? = nil }
struct SpaceType: Equatable { static let current = SpaceType(); let spaceNoun = "home"; let spaceNounCap = "Home" }
PHONE
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
SELECTED
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
  try check(PortfolioExporter.selected(profile.workspaceListings, ids: [team.id], type: .current)?.map(\.id) == [team.id], "explicit published choice excludes a foreign-workspace UUID")
  try check(PortfolioExporter.selected(profile.workspaceListings, ids: [personal.id], type: .current) == nil, "a stale foreign-workspace selection cannot be admitted")
  try check(PortfolioExporter.selected(profile.workspaceListings, ids: [], type: .current) == nil, "empty selection cannot implicitly share every house")
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
  const render = (props, builder) => scaffold.replace('PROPERTIES', props).replace('ELIGIBLE', eligible).replace('SELECTED', selected).replace('PHONE', phone).replace('BUILD', builder);
  const out = mkdtempSync(join(tmpdir(), 'rendprop-portfolio-workspace-'));
  run(out, 'actual-portfolio', render(properties, build), 0);
  run(out, 'missing-workspace-filter', render(properties.replace('model.listings.filter { model.isInSelectedWorkspace($0) }', 'model.listings'), build), 1);
  run(out, 'shared-export-file', render(properties, build.replace('rendprop-portfolio-\\(UUID().uuidString.lowercased()).html', 'rendprop-portfolio.html')), 1);
  console.log('Portfolio workspace evidence: ' + out);
});
