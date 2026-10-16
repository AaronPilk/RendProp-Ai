#!/usr/bin/env python3
"""Compile actual typed selection core; closed fixture never contacts a server."""
from pathlib import Path
import argparse,datetime,hashlib,json,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args()
a.output_dir.mkdir(parents=True,exist_ok=False)
paths=['apps/ios/Rendprop/Photos/PhotoCloudSelection.swift','apps/ios/Rendprop/Photos/PhotoCloudSelectionCoordinator.swift','apps/ios/tests/PhotoCloudSelectionCoordinatorTests.swift','apps/ios/tests/run-photo-cloud-selection.py','apps/ios/tests/PhotoCloudSelectionWireTests.swift','apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/Rendprop/Networking/WorkspaceSync.swift','apps/ios/Rendprop/Upload/DirectUploader.swift']
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
source={x:h(ROOT/x) for x in paths}
assert shutil.disk_usage('/').free>=3*1024**3 and shutil.disk_usage(a.output_dir).free>=8*1024**3
cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library']+[str(ROOT/x) for x in paths[:3]]+['-o',str(a.output_dir/'checks')]
c=subprocess.run(cmd,capture_output=True,text=True,timeout=120);(a.output_dir/'compile.log').write_text(c.stdout+c.stderr)
assert c.returncode==0,'Compilation failed; this is not behavioral evidence'
fixtures=a.output_dir/'fixtures';fixtures.mkdir()
r=subprocess.run([str(a.output_dir/'checks'),str(fixtures)],capture_output=True,text=True,timeout=60)
(a.output_dir/'runtime.log').write_text(r.stdout+r.stderr)
assert r.returncode==0,r.stdout+r.stderr
def block(s,marker):
 assert s.count(marker)==1,marker
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
live=(ROOT/paths[5]).read_text();api=(ROOT/paths[6]).read_text();workspace=(ROOT/paths[7]).read_text();direct=(ROOT/paths[8]).read_text()
methods='\n'.join(block(live,m)for m in ['    private func url(','    private enum Idempotency {','    private func makeRequest(',
 '    private static func boundedIdempotencyKey(','    private static func derivedIdempotencyKey(','    @MainActor private func execute(',
 '    private struct ErrorEnvelope: Decodable {','    static func serverError(','    private func decodeExact<T: Decodable>',
 '    @MainActor func photoCloudSelection(','    @MainActor func changePhotoCloudSelection(','    @MainActor func abandonPhotoCloudSelection('])
wire=(ROOT/paths[4]).read_text().replace('// __ACTUAL_ERROR__',block(api,'enum APIError: Error, LocalizedError')).replace('// __ACTUAL_CONTEXT__',block(workspace,'struct CloudMediaAccessContext: Equatable'))
wire=wire.replace('// __ACTUAL_DIGESTS__','\n'.join(block(direct,m)for m in ['    static func sha256Hex(_ string:','    static func sha256Hex(_ data:'])).replace('// __ACTUAL_METHODS__',methods)
wirepath=a.output_dir/'Wire.swift';wirepath.write_text(wire)
cw=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/paths[0]),str(wirepath),'-o',str(a.output_dir/'wire')],capture_output=True,text=True,timeout=120)
(a.output_dir/'wire-compile.log').write_text(cw.stdout+cw.stderr);assert cw.returncode==0,'Wire compile failed, no behavioral proof'
rw=subprocess.run([str(a.output_dir/'wire')],capture_output=True,text=True,timeout=60)
(a.output_dir/'wire-runtime.log').write_text(rw.stdout+rw.stderr);assert rw.returncode==0,rw.stdout+rw.stderr
assert source=={x:h(ROOT/x) for x in paths},'Consumed source changed' 
receipt={'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':source,'passed':True,'output':r.stdout,'wireOutput':rw.stdout,'actualWireMethodsSHA256':hashlib.sha256(methods.encode()).hexdigest(),'networkCalls':0,'hostedWrites':0,'UIExecutions':0}
(a.output_dir/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(r.stdout+rw.stdout)
