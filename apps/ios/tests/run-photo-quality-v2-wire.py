#!/usr/bin/env python3
"""Compile actual photo-v2 transport and pending journal against a closed URLProtocol."""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args();out=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='photo-v2-wire-'))).resolve();out.mkdir(parents=True,exist_ok=True)
paths=[root/f for f in ['apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/Rendprop/Upload/DirectUploader.swift','apps/ios/Rendprop/Photos/PhotoPendingEdit.swift','apps/ios/tests/PhotoQualityV2WireTests.swift','apps/ios/tests/run-photo-quality-v2-wire.py']]
def hashes():return{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
def block(s,a):
 assert s.count(a)==1,a
 start=s.index(a);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
before=hashes();live,api,digest,pending,fixture=[p.read_text()for p in paths[:5]]
methods='\n'.join(block(live,a)for a in ['    private func url(','    private enum Idempotency {','    private func makeRequest(','    private static func boundedIdempotencyKey(','    private static func derivedIdempotencyKey(','    @MainActor private func execute(','    private struct ErrorEnvelope: Decodable {','    static func serverError(','    private func decode<T: Decodable>','    @MainActor func aiPhotoEdit(','    private struct AIPhotoEditDTO: Decodable','    private struct ProvenanceEnvelopeDTO: Decodable'])
types='\n'.join(block(api,a)for a in ['enum APIError: Error, LocalizedError','struct AIPhotoEditRequest:','struct AIPhotoEditResult:'])
digests='\n'.join(block(digest,a)for a in ['    static func sha256Hex(_ string:','    static func sha256Hex(_ data:'])
actual=fixture.replace('// __ACTUAL_TYPES__',types).replace('// __ACTUAL_DIGESTS__',digests).replace('// __ACTUAL_CLIENT_METHODS__',methods).replace('// __ACTUAL_PENDING__',pending.replace('import Foundation','').replace('import CryptoKit',''))
variants=[('actual',actual,None)]
for name,anchor,replacement,reason in [
 ('legacy-route','url(["ai-photo-v2"])','url(["ai-photo"])','photo v2 uses only the new versioned admission route'),
 ('missing-protocol','prepared.setValue("retained-operation-v1", forHTTPHeaderField: "x-rendprop-photo-quality-protocol")','// dropped protocol','photo v2 declares the retained-operation protocol'),
 ('missing-library','prepared.setValue(workspace.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id")','// dropped library','photo v2 carries the exact selected library'),
 ('fresh-retry-key','idempotency: .key(key))','idempotency: .perAttempt)','pending replay sends the same paid operation key'),
 ('missing-dispatch-fence','beforeSend: { try requireUnsentPermission() }','beforeSend: nil','changed photo context prevents actual POST'),
 ('lost-consent-revision','AIConsent.shared.revocationRevision == consent','true','changed photo dispatch context must refuse')]:
 assert actual.count(anchor)==1,(name,actual.count(anchor));variants.append((name,actual.replace(anchor,replacement),reason))
results=[]
for name,code,reason in variants:
 swift=out/(name+'.swift');binary=out/name;swift.write_text(code)
 c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(binary)],capture_output=True,text=True,timeout=120);(out/(name+'-compile.log')).write_text(c.stdout+c.stderr);assert c.returncode==0,name+': '+c.stderr
 ran=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30);log=ran.stdout+ran.stderr;(out/(name+'.log')).write_text(log)
 okay=ran.returncode==0 if reason is None else ran.returncode!=0 and reason in log
 assert okay,name+': '+log
 results.append({'name':name,'exit':ran.returncode,'expectedFailure':reason,'passed':okay});binary.unlink();print(name+': PASS')
assert hashes()==before
receipt={'passed':True,'sourceHashes':before,'actualExtractionSHA256':hashlib.sha256(methods.encode()).hexdigest(),'compiledControls':len(variants)-1,'results':results,'scope':'Actual photo-v2 serializer/request builder/execute/decoder and filesystem pending journal. URLProtocol/Auth/consent are closed; no provider, live account, Simulator or phone UI.'};(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('Receipt:',out/'receipt.json')
