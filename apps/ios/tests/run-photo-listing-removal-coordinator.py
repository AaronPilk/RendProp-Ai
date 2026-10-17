#!/usr/bin/env python3
"""Actual coordinator/journal/history and Live gallery wire, closed dependencies."""
from pathlib import Path
import argparse,datetime,hashlib,json,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path);a=p.parse_args()
out=a.output_dir or Path(tempfile.mkdtemp(prefix='rendprop-removal-coordinator-'));out.mkdir(parents=True,exist_ok=True)
paths=['apps/ios/Rendprop/Photos/PhotoListingRemovalCoordinator.swift','apps/ios/Rendprop/Photos/PhotoListingRemoval.swift',
 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift','apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift',
 'apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Networking/APIClient.swift',
 'apps/ios/Rendprop/Networking/WorkspaceSync.swift','apps/ios/Rendprop/Upload/DirectUploader.swift',
 'apps/ios/tests/PhotoListingRemovalCoordinatorTests.swift','apps/ios/tests/PhotoGalleryRemovalWireTests.swift',
 'apps/ios/tests/run-photo-listing-removal-coordinator.py']
sha=lambda b:hashlib.sha256(b).hexdigest();before={p:sha((ROOT/p).read_bytes())for p in paths}
def block(s,marker):
 assert s.count(marker)==1,marker
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
live=(ROOT/paths[4]).read_text();api=(ROOT/paths[5]).read_text();workspace=(ROOT/paths[6]).read_text();direct=(ROOT/paths[7]).read_text()
error=block(api,'enum APIError: Error, LocalizedError')
coordinator=(ROOT/paths[0]).read_text()
fixture=(ROOT/paths[8]).read_text().replace('// __ACTUAL_ERROR__',error).replace('// __ACTUAL_FILE_SHA__',block(direct,'    static func sha256(of url:'))
methods='\n'.join(block(live,m)for m in ['    private func url(','    private enum Idempotency {','    private func makeRequest(',
 '    private static func boundedIdempotencyKey(','    private static func derivedIdempotencyKey(','    @MainActor private func execute(',
 '    private struct ErrorEnvelope: Decodable {','    static func serverError(','    private func decodeExact<T: Decodable>',
 '    private struct GallerySelectionWire: Decodable {','    @MainActor func gallerySelection(','    @MainActor func removeGalleryAssets('])
wire=(ROOT/paths[9]).read_text().replace('// __ACTUAL_ERROR__',error).replace('// __ACTUAL_CONTEXT__',block(workspace,'struct CloudMediaAccessContext: Equatable'))
wire=wire.replace('// __ACTUAL_DIGESTS__','\n'.join(block(direct,m)for m in ['    static func sha256Hex(_ string:','    static func sha256Hex(_ data:'])).replace('// __ACTUAL_METHODS__',methods)
variants=[('coordinator',coordinator,fixture,None),
 ('lost-reply-no-fence',coordinator.replace('if try store.load(scope: scope) != nil { return true }','if try store.load(scope: scope) != nil { return false }'),fixture,'Lost reply durably fences later sync in its exact account/library/listing'),
 ('no-sha-save-binding',coordinator.replace('expectedSHA256: match.sha256, expectedBytes: match.bytes','expectedSHA256: nil, expectedBytes: nil'),fixture,'Changed matched bytes must refuse'),
 ('all-409-definitive',coordinator.replace('error.status == 409 && error.code == "gallery_selection_changed"','error.status == 409'),fixture,'Only exact definitive CAS409 retires the pending operation'),
 ('stale-readd-confirmation',coordinator.replace('Set(current).isDisjoint(with: Set(operation.requestedAssetIDs))','true'),fixture,'Re-added selection must refuse stale confirmation'),
 ('wire',None,wire,None),
 ('foreign-actor-receipt',None,wire.replace('receipt.actor_id == operation.actorID','true'),'Mismatched wire receipt rejected: actor_id'),
 ('unstable-operation-header',None,wire.replace('idempotency: .key("gallery-remove:" + operation.operationID.uuidString.lowercased())','idempotency: .perAttempt'),'Explicit recovery preserves stable operation header')]
r={'checkedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHashes':before,'networkCalls':0,'hostedMutations':0,'UIExecutions':0,
 'actualWireMethodsSHA256':sha(methods.encode()),'actualCoordinatorSHA256':sha(coordinator.encode()),'results':[]}
for name,source,test,oracle in variants:
 folder=out/name;folder.mkdir(exist_ok=True);main=folder/'Main.swift';main.write_text(test);binary=folder/'checks';owned=folder/'owned-fixtures';owned.mkdir(exist_ok=True)
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library',str(ROOT/paths[1])]
 if source is not None:
  if name!='coordinator':assert source!=coordinator,name
  projected=folder/'Coordinator.swift';projected.write_text(source)
  command += [str(ROOT/paths[2]),str(ROOT/paths[3]),str(projected)]
 else:
  if name!='wire':assert test!=wire,name
 command += [str(main),'-o',str(binary)]
 c=subprocess.run(command,capture_output=True,text=True,timeout=90);(folder/'compile.log').write_text(c.stdout+c.stderr)
 assert c.returncode==0,f'{name}: compile failure is not proof; see {folder}'
 e=subprocess.run([str(binary),str(owned)],capture_output=True,text=True,timeout=90);log=e.stdout+e.stderr;(folder/'runtime.log').write_text(log)
 if oracle is None:
  assert e.returncode==0,f'{name}: positive failed; see {folder}'
  count=re.search(r'(\d+) assertions',log);assert count
  result={'name':name,'assertions':int(count[1]),'passed':True}
 else:
  assert e.returncode!=0 and oracle in log,f'{name}: named runtime failure missing; see {folder}'
  result={'name':name,'compiled':True,'oracle':oracle,'runtimeRejected':True}
 r['results'].append(result);print(name,'PASS',flush=True)
assert before=={p:sha((ROOT/p).read_bytes())for p in paths},'Consumed source changed during proof'
r['passed']=True;(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':True,'receipt':str(out/'receipt.json')}))
