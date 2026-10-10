import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../../', import.meta.url));
const app = readFileSync(root + 'apps/ios/Rendprop/RendpropApp.swift', 'utf8');
const auth = readFileSync(root + 'apps/ios/Rendprop/Auth/AuthStore.swift', 'utf8');
const modelSource = app.slice(app.indexOf('final class AppModel:'), app.indexOf('// MARK: - First-frame poster'));
function declaration(needle) {
  assert.equal(modelSource.split(needle).length - 1, 1, `unique production declaration ${needle}`);
  const begin = modelSource.lastIndexOf('\n', modelSource.indexOf(needle)) + 1;
  let position = modelSource.indexOf('{', modelSource.indexOf(needle)), depth = 1;
  while (depth > 0 && ++position < modelSource.length) {
    if (modelSource[position] === '{') depth++;
    if (modelSource[position] === '}') depth--;
  }
  assert.equal(depth, 0);
  return modelSource.slice(begin, position + 1);
}
test('source bindings are fail-closed, synchronous and source-before-session / receipt-before-clear', () => {
  const init = app.slice(app.indexOf('    init()'), app.indexOf('    /// Clear every per-account'));
  const clear = init.slice(init.indexOf('AuthStore.shared.onAccountChanged'), init.indexOf('AuthStore.shared.onPrepareAdoption'));
  assert.ok(!clear.includes('Task'));
  assert.ok(clear.includes('forgetServerIdentities(for: userID)'));
  assert.ok(init.includes('onPrepareAdoption') && init.includes('onConfirmAdoption') && init.includes('onAdoptionStorageReady'));
  assert.ok(auth.includes('self?.onPrepareAdoption?(pending) == true'));
  assert.ok(auth.includes('self?.onConfirmAdoption?(pending, orgID, cardData) == true'));
  assert.ok(auth.includes('guard onAdoptionStorageReady?() == true else { return }'));
  const session = auth.slice(auth.indexOf('private func applySession('), auth.indexOf('    /// Sign out:'));
  assert.ok(session.indexOf('onAccountChanged?(id)') < session.indexOf('userID = sub'), 'outgoing custody callback runs before the active subject changes');
  // The session-kind record is written from the token beside the remembered
  // subject, after the outgoing callback has read the previous one.
  assert.ok(session.indexOf('onAccountChanged?(id)') < session.indexOf('forKey: Keys.sessionIdentified'), 'session kind is recorded after the outgoing custody callback');
  assert.ok(auth.includes('(UserDefaults.standard.object(forKey: Keys.sessionIdentified) as? Bool) == false'), 'an absent session-kind record keeps the custody fence');
  const forget = declaration('func forgetServerIdentities(');
  assert.ok(forget.includes('&& AuthStore.rememberedSessionWasAnonymous') && forget.includes("&& (adoptionBindings == nil || adoptionBindings?.confirmedOrgID != nil)"), 'dead-guest release requires a remembered anonymous source and no pending handoff');
  assert.ok(forget.indexOf('let releasingAnonymousSource') < forget.indexOf('identityOwnerUserID = userID'), 'release decision reads the outgoing identity before it is replaced');
  const core = readFileSync(root + 'apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift', 'utf8');
  assert.ok(core.indexOf('finishLocal(verifiedValue, receipt.org_id, cardData)') < core.indexOf('guard remove()'));
  assert.ok(core.indexOf('let (cardData, cardResponse) = try await send(cardRequest)') < core.indexOf('finishLocal(verifiedValue, receipt.org_id, cardData)'));
  assert.ok(declaration('func confirmLocalAdoption(').includes('JSONDecoder().decode(PersonalCardReceipt.self, from: $0).checked(owner: pending.destinationUserID)'));
  // A cancelled handoff releases only the journal's own source-custody rows; a confirmed journal is never discarded.
  const discard = declaration('func discardLocalAdoption(');
  assert.ok(discard.includes('journal.confirmedOrgID == nil else { return }'));
  assert.ok(discard.includes('listings[i].cloudSyncOwnerID == journal.sourceUserID'), 'cancelled custody release is scoped to the dead source');
  const compliance = declaration('func serverListingIDForCompliance(');
  assert.ok(compliance.indexOf('pendingAdoptionBlocksServerListing') < compliance.indexOf('if let existing'));
  assert.ok(declaration('func syncListing(').includes('guard !pendingAdoptionBlocksServerListing(id)'));
});
test('actual AppModel method bodies + complete PersistentStore execute durable local recovery', () => {
  const out = mkdtempSync(join(tmpdir(), 'rendprop-local-binding-swift-'));
  const initializer = app.slice(app.indexOf('    init()'), app.indexOf('    /// Clear every per-account'));
  const accountChanged = initializer.slice(initializer.indexOf('        AuthStore.shared.onAccountChanged'), initializer.indexOf('        AuthStore.shared.onPrepareAdoption'));
  const methods = ['struct RenderedTour', 'struct UploadedRenderAsset', 'enum PublishError',
    'func forgetServerIdentities(', 'func prepareLocalAdoption(', 'func confirmLocalAdoption(',
    'func restoreAdoptedProductionLibrary(', 'func pendingAdoptionBlocksServerListing(', 'func discardLocalAdoption(', 'var workspaceSwitchIsBusy:', 'func prepareWorkspaceSwitch(', 'func isInSelectedWorkspace(', 'func ensureServerListing(', 'func index(of ', 'func load()',
    'func reconcileAfterRestore()', 'func reseedSamples()', 'func persist()'].map(declaration).join('\n');
  const store = app.slice(app.indexOf('enum PersistentStore {'), app.indexOf('// MARK: - Entry'));
  assert.ok(store.includes('extension PersistentStore.PersistedState'));
  // Mechanical extraction, no function-body edits. Only unavailable app/OS
  // dependencies are inert. Full model types and the current CloudDraftCreation
  // implementation are real; do not replace its identity/fingerprint/save logic.
  const scaffold = `import Foundation
enum Config { static var useLiveBackend = false }
enum WorkspaceContext {
 struct Snapshot { var selectedOrgID: UUID? }
 static var selectedOrgID: UUID? = nil
 static var ownerSelections: [UUID: UUID] = [:]
 static func read(owner: UUID) -> Snapshot? { ownerSelections[owner].map { Snapshot(selectedOrgID: $0) } }
}
enum AccountExportFiles { static func purge() {} }
@MainActor final class WorkspaceStore { static let shared = WorkspaceStore(); func refresh() async {}; func canViewLibrary(_ org: UUID) -> Bool { org == WorkspaceContext.selectedOrgID } }
enum FileStore {
 static var documents = URL(fileURLWithPath: "/nonexistent/fixture-not-initialized")
 static func url(fromRelativePath p:String)->URL { documents.appendingPathComponent(p) }
 static func relativePath(for url:URL)->String { String(url.path.dropFirst(documents.path.count+1)) }
}
@MainActor final class AuthStore {
 static let shared=AuthStore()
 var userID:String? { didSet { if userID != oldValue { syncSessionRevision &+= 1 } } }
 var syncSessionRevision:UInt64=0; var isIdentified:Bool { userID != nil }
 static var rememberedSessionWasAnonymous=false
 var errors=0; var pendingExists=true; var pendingReadFails=false
 var onAccountChanged: ((UUID) -> Void)?
 static func validAccessToken() async -> String? { nil }
 func retryPendingAdoptionIfNeeded() async {}
 func reportUnreadableAdoptionBindings() { errors += 1 }
 func reportProductionRecoveryProblem() { errors += 1 }
 func hasPendingAdoption(operationID:UUID) throws -> Bool {
  if pendingReadFails { throw AdoptionLocalBindings.Failure.invalid }; return pendingExists
 }
}
@MainActor final class ProductionVideoLibrary {
 static let shared=ProductionVideoLibrary(); var busy=false
 func isBusy(owner:String)->Bool { busy }
 func reloadAdopted(owner:String, listingIDs:Set<UUID>) {}
}
@MainActor final class ProductionPlanSyncStore {
 static let shared=ProductionPlanSyncStore()
 func remove(_ id:UUID) {}
}
@MainActor final class FixtureAPI {
 var calls=0; var deleted:[UUID]=[]; var onCreate:(() async -> Void)?
 func createListing(_ listing:Listing) async throws -> Listing {
  calls += 1; await onCreate?(); var created=listing; created.id=UUID(); created.serverOrgID = listing.cloudDraftOrgID ?? listing.serverOrgID; return created
 }
 func deleteListing(serverID:UUID) async throws { deleted.append(serverID) }
}
@MainActor final class AppModel {
 var listings:[Listing]=[] { didSet { persist() } }
 var assets:[UUID:CaptureAsset]=[:]; var tours:[UUID:RenderedTour]=[:]; var renders:[UUID:Render]=[:]
 var uploadedRenderAssets:[UUID:UploadedRenderAsset]=[:]; var pendingPublish:[UUID]=[]
 var publishedOriginalAssets:[String:String]=[:]; var publishedGalleryAssets:[String:String]=[:]
 var hasLoaded=false; var isRestoring=false; var syncInFlight:Set<UUID>=[]; var publishInFlight:Set<UUID>=[]
 var clientContactSyncInFlight:Set<UUID>=[]
 var cloudRefreshTask:Task<Void,Never>?; var cloudRefreshOperation:UUID?
 var cloudSyncError:String?; var lastCloudSyncAt:Date?
 var serverCreationInFlight:Set<UUID>=[]; var identityOwnerUserID:UUID?
 var adoptionBindings:AdoptionLocalBindings?; var adoptionBindingsUnreadable=false; let api=FixtureAPI()
 init() {
${accountChanged}
 }
 // Business-type preferences/notifications are outside metadata adoption.
 // Keep this dependency inert instead of touching the host's preferences.
 static func markSpaceTypeOutOfSync() {}
 func syncDirtyListings() async {}
 func refreshCloudWorkspace() async {}
 func resumePendingPublishes() async {}
${methods}
}
${store}
`;
  const generated = join(out, 'ActualAppModelMetadata.swift');
  writeFileSync(generated, scaffold, { flag: 'wx' });
  const files = ['Listing', 'ListingClientContact', 'Money', 'RoomTag', 'CaptureAsset', 'Render'].map(n => root + `apps/ios/Rendprop/Models/${n}.swift`);
  files.push(root + 'apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift', root + 'apps/ios/Rendprop/Auth/AdoptionLocalBindings.swift',
    root + 'apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift',
    root + 'apps/ios/Rendprop/Models/ProductionGuidance.swift', root + 'apps/ios/Rendprop/Networking/ProductionPlan.swift',
    root + 'apps/ios/Rendprop/Networking/WorkspaceSync.swift', root + 'apps/ios/Rendprop/Networking/NativeReelDraft.swift');
  const binary = join(out, 'local-binding-tests');
  const compiled = spawnSync('/usr/bin/swiftc', ['-parse-as-library', ...files, generated,
    root + 'tests/phase1/AdoptionLocalBindingsTests.swift', '-o', binary], { encoding: 'utf8', timeout: 60_000 });
  writeFileSync(join(out, 'compile.log'), compiled.stdout + compiled.stderr, { flag: 'wx' });
  console.log(`Local binding evidence: ${out}`);
  assert.equal(compiled.status, 0, compiled.stderr);
  const negative = spawnSync(binary, [out, '--force-failure'], { encoding: 'utf8', timeout: 30_000 });
  writeFileSync(join(out, 'negative.log'), negative.stdout + negative.stderr, { flag: 'wx' });
  assert.equal(negative.status, 1);
  assert.ok(negative.stdout.includes('deliberate negative control'));
  const result = spawnSync(binary, [out], { encoding: 'utf8', timeout: 30_000 });
  writeFileSync(join(out, 'actual.log'), result.stdout + result.stderr, { flag: 'wx' });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /PASS: \d+ local binding assertions/);
  console.log(result.stdout.trim());
  for (const [name, needle, replacement, count] of [
    ['leave-unstamped-draft-custody', 'listings[i].cloudSyncOwnerID = listings[i].cloudSyncOwnerID ?? previousOwner',
      '// missing outgoing draft custody', 2],
    ['show-other-actor-draft', 'if !listing.isSample, let owner = listing.cloudSyncOwnerID,\n           owner != AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) { return false }', '', 1],
    ['omit-rebound-identities', 'listings = restored; adoptionBindings = confirmed; identityOwnerUserID = pending.destinationUserID',
      'adoptionBindings = confirmed; identityOwnerUserID = pending.destinationUserID', 1],
    ['ignore-persistence-failure', 'if persist() { return true }', 'if (persist() || true) { return true }', 2],
    ['evict-pending-binding', 'if let old = adoptionBindings, old.confirmedOrgID == nil, !old.matches(pending) { return false }', '', 1],
    ['skip-offline-custody-rebind', 'for i in restored.indices where !restored[i].isSample && adoptedIDs.contains(restored[i].id)',
      'for i in restored.indices where restored[i].serverID != nil', 1],
    ['skip-completed-draft-repair', 'for i in repairedListings.indices where !repairedListings[i].isSample && ids.contains(repairedListings[i].id) && repairedListings[i].cloudSyncOwnerID != journal.destinationUserID',
      'for i in repairedListings.indices where repairedListings[i].serverID != nil', 1],
    ['use-current-owner-library', 'let previousOrg = previousOwner.flatMap { WorkspaceContext.read(owner: $0)?.selectedOrgID }\n            ?? (previousOwner == AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) ? WorkspaceContext.selectedOrgID : nil)',
      'let previousOrg = WorkspaceContext.selectedOrgID', 1],
    ['adopt-unjournaled-drafts', 'for i in restored.indices where !restored[i].isSample && adoptedIDs.contains(restored[i].id)',
      'for i in restored.indices where !restored[i].isSample', 1],
    ['keep-cancelled-guest-custody', '            listings[i].cloudSyncOwnerID = nil\n            listings[i].cloudDraftOrgID = nil',
      '            _ = i // cancelled guest rows stay fenced to a dead source', 1],
    ['release-foreign-custody-on-cancel', '&& listings[i].cloudSyncOwnerID == journal.sourceUserID {',
      '{', 1],
    ['fence-dead-guest-custody', '            && AuthStore.rememberedSessionWasAnonymous\n',
      '            && false // a dead guest keeps its fence\n', 1],
    ['release-journaled-guest-custody', '&& (adoptionBindings == nil || adoptionBindings?.confirmedOrgID != nil)',
      '&& true', 1],
  ]) {
    assert.equal(scaffold.split(needle).length - 1, count, `actual mutation target ${name}`);
    const path = join(out, name + '.swift'), mutant = join(out, name);
    writeFileSync(path, scaffold.replaceAll(needle, replacement), { flag: 'wx' });
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', ...files, path,
      root + 'tests/phase1/AdoptionLocalBindingsTests.swift', '-o', mutant], { encoding: 'utf8', timeout: 60_000 });
    writeFileSync(join(out, name + '-compile.log'), compile.stdout + compile.stderr, { flag: 'wx' });
    assert.equal(compile.status, 0, `mutant must compile: ${name}`);
    const rejected = spawnSync(mutant, [out], { encoding: 'utf8', timeout: 30_000 });
    writeFileSync(join(out, name + '-run.log'), rejected.stdout + rejected.stderr, { flag: 'wx' });
    assert.equal(rejected.status, 1, `actual mutation must fail: ${name}`);
    assert.match(rejected.stdout, /FAIL: [1-9]\d*\/\d+ local binding assertions/);
  }
  console.log('PASS: 13 actual AppModel metadata mutants compiled then failed assertions/exit1');
  const checked = [...files, root + 'apps/ios/Rendprop/RendpropApp.swift', root + 'apps/ios/Rendprop/Auth/AuthStore.swift',
    root + 'tests/phase1/AdoptionLocalBindingsTests.swift', fileURLToPath(import.meta.url)];
  writeFileSync(join(out, 'receipt.json'), JSON.stringify({ accepted: true,
    runtimeScope: 'Mechanically extracted actual AppModel metadata methods and complete PersistentStore; complete production WorkspaceSync/NativeReelDraft and model types; inert Auth/transport/FileStore/background refresh dependencies',
    negativeControlExit: negative.status, actualExit: result.status, actualMutantsRejected: 11,
    sourceHashes: Object.fromEntries(checked.map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
    extractedSourceSHA256: createHash('sha256').update(scaffold).digest('hex'),
  }, null, 2) + '\n', { flag: 'wx' });
});
