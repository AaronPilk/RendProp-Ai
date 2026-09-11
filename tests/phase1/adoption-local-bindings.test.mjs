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
  assert.ok(auth.includes('self?.onConfirmAdoption?(pending, orgID) == true'));
  assert.ok(auth.includes('guard onAdoptionStorageReady?() == true else { return }'));
  const core = readFileSync(root + 'apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift', 'utf8');
  assert.ok(core.indexOf('guard finishLocal(value, receipt.org_id)') < core.indexOf('guard remove()'));
  const compliance = declaration('func serverListingIDForCompliance(');
  assert.ok(compliance.indexOf('pendingAdoptionBlocksServerListing') < compliance.indexOf('if let existing'));
  assert.ok(declaration('func syncListing(').includes('guard !pendingAdoptionBlocksServerListing(id)'));
});
test('actual AppModel method bodies + complete PersistentStore execute durable local recovery', () => {
  const out = mkdtempSync(join(tmpdir(), 'rendprop-local-binding-swift-'));
  const methods = ['struct RenderedTour', 'struct UploadedRenderAsset', 'enum PublishError',
    'func forgetServerIdentities(', 'func prepareLocalAdoption(', 'func confirmLocalAdoption(',
    'func pendingAdoptionBlocksServerListing(', 'func ensureServerListing(', 'func load()',
    'func reconcileAfterRestore()', 'func reseedSamples()', 'func persist()'].map(declaration).join('\n');
  const store = app.slice(app.indexOf('enum PersistentStore {'), app.indexOf('// MARK: - Entry'));
  assert.ok(store.includes('extension PersistentStore.PersistedState'));
  // Mechanical extraction, no function-body edits. Only unavailable app/OS
  // dependencies are inert. Full Listing/CaptureAsset/Render/RoomTag are real.
  const scaffold = `import Foundation
enum FileStore {
 static var documents = URL(fileURLWithPath: "/nonexistent/fixture-not-initialized")
 static func url(fromRelativePath p:String)->URL { documents.appendingPathComponent(p) }
 static func relativePath(for url:URL)->String { String(url.path.dropFirst(documents.path.count+1)) }
}
@MainActor final class AuthStore {
 static let shared=AuthStore(); var userID:String?; var errors=0; var pendingExists=true; var pendingReadFails=false
 func retryPendingAdoptionIfNeeded() async {}
 func reportUnreadableAdoptionBindings() { errors += 1 }
 func hasPendingAdoption(operationID:UUID) throws -> Bool {
  if pendingReadFails { throw AdoptionLocalBindings.Failure.invalid }; return pendingExists
 }
}
@MainActor final class FixtureAPI {
 var calls=0; var onCreate:(() async -> Void)?
 func createListing(_ listing:Listing) async throws -> Listing {
  calls += 1; await onCreate?(); var created=listing; created.id=UUID(); return created
 }
}
@MainActor final class AppModel {
 var listings:[Listing]=[] { didSet { persist() } }
 var assets:[UUID:CaptureAsset]=[:]; var tours:[UUID:RenderedTour]=[:]; var renders:[UUID:Render]=[:]
 var uploadedRenderAssets:[UUID:UploadedRenderAsset]=[:]; var pendingPublish:[UUID]=[]
 var publishedOriginalAssets:[String:String]=[:]; var publishedGalleryAssets:[String:String]=[:]
 var hasLoaded=false; var isRestoring=false; var syncInFlight:Set<UUID>=[]; var publishInFlight:Set<UUID>=[]
 var serverCreationInFlight:Set<UUID>=[]; var identityOwnerUserID:UUID?
 var adoptionBindings:AdoptionLocalBindings?; var adoptionBindingsUnreadable=false; let api=FixtureAPI()
 func syncDirtyListings() async {}
 func resumePendingPublishes() async {}
${methods}
}
${store}
`;
  const generated = join(out, 'ActualAppModelMetadata.swift');
  writeFileSync(generated, scaffold, { flag: 'wx' });
  const files = ['Listing', 'Money', 'RoomTag', 'CaptureAsset', 'Render'].map(n => root + `apps/ios/Rendprop/Models/${n}.swift`);
  files.push(root + 'apps/ios/Rendprop/Auth/AnonymousAdoptionRecovery.swift', root + 'apps/ios/Rendprop/Auth/AdoptionLocalBindings.swift');
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
    ['omit-rebound-identities', 'listings = restored; adoptionBindings = confirmed; identityOwnerUserID = pending.destinationUserID',
      'adoptionBindings = confirmed; identityOwnerUserID = pending.destinationUserID', 1],
    ['ignore-persistence-failure', 'if persist() { return true }', 'if (persist() || true) { return true }', 2],
    ['evict-pending-binding', 'if let old = adoptionBindings, old.confirmedOrgID == nil, !old.matches(pending) { return false }', '', 1],
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
  console.log('PASS: 3 actual AppModel metadata mutants compiled then failed assertions/exit1');
  const checked = [...files, root + 'apps/ios/Rendprop/RendpropApp.swift', root + 'apps/ios/Rendprop/Auth/AuthStore.swift',
    root + 'tests/phase1/AdoptionLocalBindingsTests.swift', fileURLToPath(import.meta.url)];
  writeFileSync(join(out, 'receipt.json'), JSON.stringify({ accepted: true,
    runtimeScope: 'Mechanically extracted actual AppModel metadata methods and complete PersistentStore; inert Auth/transport/FileStore dependencies; full production model types',
    negativeControlExit: negative.status, actualExit: result.status, actualMutantsRejected: 3,
    sourceHashes: Object.fromEntries(checked.map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
    extractedSourceSHA256: createHash('sha256').update(scaffold).digest('hex'),
  }, null, 2) + '\n', { flag: 'wx' });
});
