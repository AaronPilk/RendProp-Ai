#!/usr/bin/env python3
"""Compile actual nullable package metadata and /me adapter with closed network."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(); parser.add_argument('--out', type=Path); args = parser.parse_args()
out = args.out or Path(tempfile.mkdtemp(prefix='rendprop-native-photo-package-'))
out.mkdir(parents=True, exist_ok=True)
paths = [root/'apps/ios/Rendprop'/p for p in ['Purchases/SubscriptionBillingContext.swift', 'Networking/APIClient.swift',
    'Networking/LiveAPIClient.swift', 'Networking/WorkspaceSync.swift', 'Models/Money.swift', 'Screens/SettingsView.swift']]
paths += [Path(__file__).resolve(), root/'apps/ios/tests/ServingPhotoPackageTests.swift']
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start = hashes(); billing, api, live, workspace, money, settings = [p.read_text() for p in paths[:6]]
def block(source, anchor):
    begin = source.index(anchor); opening = source.index('{', begin); depth = 1; end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[begin:end]

# The real SwiftUI branch must select the package ahead of legacy nominal rows.
rows = block(settings, 'private func usageRows(')
package_branch = rows.index('} else if let package = usage.servingPhotoPackage {')
legacy_branch = rows.index('} else if let e = usage.entitlements {')
assert package_branch < legacy_branch
assert 'photoPackageRows(package)' in rows[package_branch:legacy_branch]
assert 'usageRow(' not in rows[package_branch:legacy_branch]
assert rows.count('if let package = usage.servingPhotoPackage { photoPackageRows(package) }') == 2
assert 'ForEach(package.rows, id: \\.title)' in block(settings, 'private func photoPackageRows(')
assert 'usage?.servingPhotoPackage != nil ? ServingPhotoPackageSummary.explanation' in settings
assert 'usageLoadGeneration == generation' in block(settings, 'private func loadUsage(')
revision_change = block(settings, '.onChange(of: auth.syncSessionRevision)')
assert 'usage = nil; usageError = nil' in revision_change and 'await loadUsage()' in revision_change

interfaces = '''
import Foundation
enum APIError: Error { case decoding }
enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1
 var identityWrites = 0
 func applyServerIdentity(userName: String?, orgName: String?) { identityWrites += 1 }
}
@MainActor final class LivePhotoPackageFixture {
 let data: Data; var onRead: (() -> Void)?
 init(data: Data) { self.data = data }
 private func url(_ parts: [String]) -> URL { URL(string: "https://synthetic.invalid/" + parts.joined(separator: "/"))! }
 private func makeRequest(url: URL) -> URL { url }
 private func execute(_ url: URL) async throws -> Data { precondition(url.path == "/me"); onRead?(); return data }
'''
base = 'import Foundation\n' + billing + '\n' + money + '\n'
for anchor in ['struct Entitlements:', 'struct HostingRetentionSummary:', 'struct UsageSummary:']:
    base += block(api, anchor) + '\n'
base += block(workspace, 'enum CloudSyncError:') + '\n' + interfaces
for anchor in ['struct LenientInt:', 'private struct MeDTO:', 'private func decode<T:', 'private static func parseDate(', '@MainActor func me(']:
    base += block(live, anchor) + '\n'
base += '}\n'
faults = [
 ('actual', None, None, None),
 ('package-org', 'guard orgId == org,', 'guard true,', 'Foreign package workspace accepted'),
 ('package-policy', 'policy == "one-gemini-1k-4096-plus-one-kontext-20261007",', 'true,', 'Unknown package policy accepted'),
 ('package-interval', 'start <= now, end > now, end > start,', 'end > start,', 'Future package interval accepted'),
 ('photo-algebra', 'remaining == cap - used', 'remaining >= 0', 'Photo count algebra bypassed'),
 ('other-ai-algebra', 'remainingCents == capCents - usedCents', 'remainingCents >= 0', 'Other AI algebra bypassed'),
 ('protected-total', 'protectedPhotoCents == Int(ceil(Double(photoAdmissions.cap) * 35.1296))', 'protectedPhotoCents >= 0', 'Incorrect protected photo total accepted'),
 ('response-actor', 'dto.user?.id.flatMap(UUID.init(uuidString:)) == owner,', 'true,', 'Foreign package actor accepted'),
 ('response-context', 'AuthStore.shared.syncSessionRevision == revision', 'true', 'Late package context accepted'),
 ('dropped-package', 'servingPhotoPackage: dto.servingPhotoPackage', 'servingPhotoPackage: nil', 'Actual me forwards configured package'),
]
results = []
for name, old, new, expected in faults:
    source = base if old is None else base.replace(old, new)
    if old is not None and source == base: raise RuntimeError('Unapplied fault: ' + name)
    swift = out/(name+'.swift'); swift.write_text(source); binary = out/name
    compiled = subprocess.run(['xcrun','swiftc','-parse-as-library',str(swift),str(paths[-1]),'-o',str(binary)], capture_output=True,text=True,timeout=90)
    (out/(name+'-compile.log')).write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode: raise RuntimeError('Compile failure is not runtime proof: '+str(out/(name+'-compile.log')))
    run = subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
    output = run.stdout+run.stderr; (out/(name+'.log')).write_text(output)
    passed = (run.returncode == 0 and 'Native photo package:' in output) if expected is None else (run.returncode != 0 and 'FAILED: '+expected in output)
    results.append({'case':name,'passed':passed,'compileExit':compiled.returncode,'runtimeExit':run.returncode,'expectedFailure':expected,'compiledSourceSHA256':hashlib.sha256(source.encode()).hexdigest()})
    if not passed: raise RuntimeError('Runtime oracle failed: '+str(out/(name+'.log')))
bound = hashes() == start
receipt = {'passed':bound and all(r['passed'] for r in results),'sourceUnchanged':bound,'sourceHashes':start,'results':results,
 'externalNetworkRequests':0,'appleCalls':0,'providerCalls':0,
 'limitations':['Actual Foundation package models, /me DTO and adapter execute with closed Auth/HTTP interfaces.',
   'Settings package-before-legacy branch, trial coexistence, rows and explanation are source checked; SwiftUI rendering and full SDK compile are separate.',
   'No package, funding, allowance, billing offer or price is activated by this test.']}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':receipt['passed'],'actualOutput':(out/'actual.log').read_text().strip(),'compiledNegativeControls':len(results)-1,'receipt':str(out/'receipt.json')}))
raise SystemExit(0 if receipt['passed'] else 1)
