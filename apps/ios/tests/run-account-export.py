#!/usr/bin/env python3
"""Compile actual account-export helpers/consumer methods and semantic faults."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
root = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-account-export-'))
out.mkdir(parents=True, exist_ok=True)
paths = [root/'apps/ios/Rendprop'/n for n in ['Screens/AccountDataExport.swift','Screens/SettingsView.swift','Networking/APIClient.swift','Networking/LiveAPIClient.swift','RendpropApp.swift']]
paths += [Path(__file__).resolve(),root/'apps/ios/tests/AccountExportTests.swift',root/'apps/ios/Rendprop.xcodeproj/project.pbxproj',root/'apps/ios/RendpropSpatialTestFlight.xcodeproj/project.pbxproj']
hashes = lambda: {str(x.relative_to(root)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
start = hashes(); src = paths[0].read_text(); test = (root/'apps/ios/tests/AccountExportTests.swift').read_text()
def block(source, anchor):
    begin = source.index(anchor); opening = source.index('{',begin); depth=1; end=opening+1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end+=1
    return source[begin:end]
settings,api,live,app = [x.read_text() for x in paths[1:5]]
assert 'NavigationLink { AccountDataExportView() }' in settings
assert 'func exportAccountData() async throws -> Data' in api
assert 'if let hosting = usage.hostingRetention {' in settings
assert 'org == WorkspaceContext.selectedOrgID, let checked = receipt.checked(org: org)' in live
assert 'execute(makeRequest(url: url(["me", "export"])))' in live
assert app.count('AccountExportFiles.purge()') == 2
for project in paths[-2:]: assert project.read_text().count('AccountDataExport.swift') == 6
assert '.onChange(of: auth.userID) { _ in clear() }' in src
assert '.onChange(of: auth.syncSessionRevision) { _ in clear() }' in src
assert 'if current, let file, let generation {' in src
assert 'AccountExportShare(file: file).onDisappear { finishShare(generation) }' in src
boundary = '''
@MainActor final class FakeAuth { var userID: String?; var syncSessionRevision: UInt64 = 0; var isIdentified = false }
actor Gate {
 var calls: [CheckedContinuation<Data,Error>] = []
 func fetch() async throws -> Data { try await withCheckedThrowingContinuation { calls.append($0) } }
 func waitFor(_ number:Int) async { while calls.count < number { await Task.yield() } }
 func finish(_ index:Int,_ data:Data) { calls[index].resume(returning:data) }
}
struct FakeAPI { let gate: Gate; func exportAccountData() async throws -> Data { try await gate.fetch() } }
@MainActor final class FakeModel { let api:FakeAPI; init(gate:Gate) { api=FakeAPI(gate:gate) } }
@MainActor final class ExportFixture {
 let auth:FakeAuth; let model:FakeModel
 var task:Task<Void,Never>?; var context:AccountExportContext?; var generation:UUID?; var receipt:AccountExportReceipt?; var file:URL?; var sharing=false; var error:String?; var loading=false
 init(auth:FakeAuth,gate:Gate) { self.auth=auth;model=FakeModel(gate:gate) }
'''
def generated(source):
    helpers=source[:source.index('struct AccountDataExportView:')].replace('import SwiftUI','').replace('import UIKit','')
    helpers+='\n'+block(api,'struct HostingRetentionSummary:')+'\n'
    methods='\n'.join(block(source,a).replace('private ','',1) for a in ['private var current:','@MainActor private func clear()','@MainActor private func finishShare(','@MainActor private func download()'])
    return helpers+boundary+methods+'\n}\n'+test
faults=[('actual',None,None),('actor-context','owner.flatMap(UUID.init(uuidString:)) == actor','true'),('session-context','revision == self.revision','true'),('receipt-actor','decoded.manifest.actor_id == context.actor','true'),('receipt-count','items.count == collection.count','true'),('private-file','.posixPermissions] = 0o600','.posixPermissions] = 0o644'),('generation-cleanup','removeItem(at: directory.appendingPathComponent(generation.uuidString, isDirectory: true))','removeItem(at: directory)'),('stale-retry','if generation == action, context == captured { clear();','if context == captured { clear();'),('share-dismissal','guard generation == action else { return }','')]
runs=[]
for name,old,new in faults:
    changed=src if old is None else src.replace(old,new)
    assert old is None or changed!=src
    file=out/(name+'.swift'); file.write_text(generated(changed)); binary=out/name
    built=subprocess.run(['swiftc','-parse-as-library',str(file),'-o',str(binary)],capture_output=True,text=True)
    (out/(name+'-compile.log')).write_text(built.stdout+built.stderr)
    if built.returncode: raise RuntimeError('Compile failure: '+name+' '+built.stderr[-3000:])
    result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20)
    (out/(name+'-run.log')).write_text(result.stdout+result.stderr)
    if (name=='actual') != (result.returncode==0): raise RuntimeError('Semantic result failed: '+name+' '+result.stdout+result.stderr[-2000:])
    runs.append({'name':name,'exit':result.returncode,'expectedFailure':name!='actual'})
end=hashes(); receipt={'sourceBoundAtEnd':start==end,'sourceSHA256':start,'runs':runs,'scope':'Actual Foundation helpers and native download/clear bodies; closed Auth/API/UI boundaries. Files share/device acceptance separate.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)); assert start==end
print(json.dumps({'sourceBoundAtEnd':True,'runs':len(runs),'evidence':str(out)},indent=2))
