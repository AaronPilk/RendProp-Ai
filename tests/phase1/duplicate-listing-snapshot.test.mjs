import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../../', import.meta.url));
const appPath = root + 'apps/ios/Rendprop/RendpropApp.swift';
const app = readFileSync(appPath, 'utf8');

test('actual persisted duplicate listing IDs produce a recoverable sync error and retain media', () => {
  const out = mkdtempSync(join(tmpdir(), 'rendprop-duplicate-listing-swift-'));
  const start = app.indexOf('func refreshCloudWorkspace()');
  assert.ok(start >= 0);
  let position = app.indexOf('{', start), depth = 1;
  while (depth > 0 && ++position < app.length) {
    if (app[position] === '{') depth++;
    if (app[position] === '}') depth--;
  }
  assert.equal(depth, 0);
  const refresh = app.slice(start, position + 1);
  const guardText = 'guard Set(self.listings.map(\\.id)).count == self.listings.count else {\n                    throw CloudSyncError.invalidResponse\n                }';
  const mapText = 'let bindingsAtRead = Dictionary(uniqueKeysWithValues: self.listings.map { ($0.id, $0.serverID) })';
  assert.equal(refresh.split(guardText).length - 1, 1, 'exact guard registered inside actual refreshCloudWorkspace');
  assert.equal(refresh.split(mapText).length - 1, 1, 'exact snapshot binding map registered once');
  const snapshot = refresh.slice(refresh.indexOf(guardText), refresh.indexOf(mapText) + mapText.length);
  assert.ok(refresh.indexOf(mapText) < refresh.indexOf('cloud.cloudListings()'), 'guard fails before remote merge');
  assert.ok(refresh.includes('self.cloudSyncError = error is CloudSyncError'), 'actual refresh catches the recoverable sync error');
  const store = app.slice(app.indexOf('enum PersistentStore {'), app.indexOf('// MARK: - Entry'));
  assert.ok(store.includes('extension PersistentStore.PersistedState'), 'complete tolerant store included');
  const scaffold = `import Foundation
enum FileStore {
 static var documents=URL(fileURLWithPath:"/uninitialized-private-fixture")
 static func url(fromRelativePath rel:String)->URL { documents.appendingPathComponent(rel) }
 static func relativePath(for url:URL)->String { String(url.path.dropFirst(documents.path.count+1)) }
}
// Recovery journal is unused by these synthetic snapshots.
struct AdoptionLocalBindings:Codable { func validate() throws {} }
enum CloudSyncError:Error { case invalidResponse }
final class AppModel {
 struct RenderedTour { let url:URL;let durationS:Double;let speedFactor:Double }
 struct UploadedRenderAsset:Codable,Hashable { var relPath:String;var assetID:String }
 var listings:[Listing]=[]
 func snapshotBindings() throws -> [UUID:UUID?] {
 ${snapshot}
 return bindingsAtRead
 }
}
${store}
`;
  const files = ['Listing', 'ListingClientContact', 'Money', 'RoomTag', 'CaptureAsset', 'Render']
    .map(name => root + `apps/ios/Rendprop/Models/${name}.swift`);
  const harness = root + 'tests/phase1/DuplicateListingSnapshotTests.swift';
  const run = (name, source) => {
    const path = join(out, name + '.swift'), binary = join(out, name);
    writeFileSync(path, source, { flag: 'wx' });
    const compiled = spawnSync('/usr/bin/swiftc', ['-parse-as-library', ...files, path, harness, '-o', binary],
      { encoding: 'utf8', timeout: 60_000 });
    writeFileSync(join(out, name + '-compile.log'), compiled.stdout + compiled.stderr, { flag: 'wx' });
    assert.equal(compiled.status, 0, compiled.stderr);
    const result = spawnSync(binary, [join(out, name + '-library')], { encoding: 'utf8', timeout: 30_000 });
    writeFileSync(join(out, name + '-run.log'), result.stdout + result.stderr, { flag: 'wx' });
    return { binary, result };
  };
  const actual = run('actual', scaffold);
  assert.equal(actual.result.status, 0, actual.result.stdout + actual.result.stderr);
  assert.match(actual.result.stdout, /PASS: \d+ actual snapshot and sync binding assertions/);
  const negative = spawnSync(actual.binary, [out, '--force-failure'], { encoding: 'utf8', timeout: 30_000 });
  assert.equal(negative.status, 1);
  assert.match(negative.stdout, /deliberate negative control/);
  assert.equal(scaffold.split(guardText).length - 1, 1);
  const mutant = run('omit-sync-guard', scaffold.replace(guardText, '')).result;
  assert.equal(mutant.signal, 'SIGTRAP', 'removing only actual guard reproduces original duplicate-key trap');
  assert.match(mutant.stderr, /Duplicate values for key/);
  console.log(`Duplicate snapshot evidence: ${out}\n${actual.result.stdout.trim()}\nPASS: removing the actual sync guard reproduces SIGTRAP`);
  const checked = [appPath, ...files, harness, fileURLToPath(import.meta.url)];
  writeFileSync(join(out, 'receipt.json'), JSON.stringify({ accepted: true,
    scope: 'Complete production PersistentStore/tolerant decoding and model types; exact guard and dictionary block mechanically extracted from actual AppModel.refreshCloudWorkspace. Inert FileStore/error type and unused recovery dependency. Synthetic local bytes only; no app UI/camera/transport/Apple/provider calls.',
    actualExit: actual.result.status, negativeControlExit: negative.status, mutantSignal: mutant.signal,
    sourceHashes: Object.fromEntries(checked.map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
    extractedSourceSHA256: createHash('sha256').update(scaffold).digest('hex'),
  }, null, 2) + '\n', { flag: 'wx' });
});
