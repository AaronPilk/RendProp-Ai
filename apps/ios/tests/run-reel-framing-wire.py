#!/usr/bin/env python3
"""Capture the actual full-photo reel serializer/admission body without provider calls."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(); p.add_argument('--evidence-dir',type=Path); args=p.parse_args()
out=(args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-framing-wire-'))).resolve(); out.mkdir(parents=True,exist_ok=True)
paths=[root/s for s in ['apps/ios/Rendprop/Networking/LiveAPIClient.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/Rendprop/Upload/DirectUploader.swift','apps/ios/tests/ReelFramingWireTests.swift','apps/ios/tests/run-reel-framing-wire.py']]
def hashes():return {str(s.relative_to(root)):hashlib.sha256(s.read_bytes()).hexdigest() for s in paths}
def block(s,anchor):
 assert s.count(anchor)==1,anchor
 start=s.index(anchor); end=s.index('{',start)+1; depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}'); end+=1
 return s[start:end]
r={'passed':False,'start_source_sha256':hashes(),'runs':[],'limitations':['Actual reel serializer, submitAIVideo, execute, request helpers and accepted job decoder execute unchanged.','Foundation URLProtocol captures serialized HTTP requests. Auth, consent and responses are closed fixtures; no provider, Apple account, physical phone or Simulator UI.','This proves framing/legacy/context contracts, not supplier crop behavior or generated visual quality.']}
try:
 live,api,digest,fixture=[s.read_text() for s in paths[:4]]
 methods='\n'.join(block(live,a) for a in ['    private func url(','    private enum Idempotency {','    private func makeRequest(','    private static func boundedIdempotencyKey(','    private static func derivedIdempotencyKey(','    private static func aiIdempotency(','    @MainActor private func execute(','    private struct ErrorEnvelope: Decodable {','    static func serverError(','    private func decode<T: Decodable>','    func aiVideoReelClip(','    @MainActor private func submitAIVideo(','    private struct AIVideoJobDTO: Decodable','    private struct ProvenanceEnvelopeDTO: Decodable'])
 methods+='\n'+block(api,'    /// Existing saved requests omit framing and retain their original contract.')
 types='\n'.join(block(api,a) for a in ['enum APIError: Error, LocalizedError','struct AIVideoJob: Codable, Sendable'])
 digests='\n'.join(block(digest,a) for a in ['    static func sha256Hex(_ string:','    static func sha256Hex(_ data:'])
 actual=fixture.replace('// __ACTUAL_TYPES__',types).replace('// __ACTUAL_CLIENT_METHODS__',methods).replace('// __ACTUAL_DIGESTS__',digests)
 forward='            body["framing"] = framing'; validate='            guard framing == "preserve_photo" else { throw CloudSyncError.invalidResponse }'
 assert actual.count(forward)==1 and actual.count(validate)==1
 variants=[('actual',actual,None),('negative-lost-framing',actual.replace(forward,'            // dropped framing'),'explicit whole-photo framing survives actual wire serialization'),('negative-invented-legacy-framing',actual.replace('        if let framing {','        let framing = framing ?? "preserve_photo"\n        if true {'),'legacy nil framing is absent on wire'),('negative-unsupported-framing',actual.replace(validate,'            // omitted validation'),'unsupported framing must refuse')]
 r['actual_method_sha256']=hashlib.sha256(methods.encode()).hexdigest()
 for name,code,reason in variants:
  assert reason is None or code!=actual
  swift=out/(name+'.swift'); binary=out/name; swift.write_text(code)
  compiled=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(binary)],capture_output=True,text=True,timeout=120)
  (out/(name+'-compile.log')).write_text(compiled.stdout+compiled.stderr); assert compiled.returncode==0,name+' compile failed: '+compiled.stderr
  ran=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30); log=ran.stdout+ran.stderr; (out/(name+'.log')).write_text(log)
  expected=ran.returncode==0 if reason is None else ran.returncode!=0 and ('Precondition failed: '+reason in log or 'Fatal error: '+reason in log)
  r['runs'].append({'name':name,'exit_code':ran.returncode,'expected_failure':reason,'expected_result':expected,'output':log[:2000]}); assert expected,name+': '+log
  binary.unlink()
except BaseException as e:r['failure']=str(e); raise
finally:
 r['end_source_sha256']=hashes(); r['source_binding_matches']=r['start_source_sha256']==r['end_source_sha256']; r['passed']='failure' not in r and len(r['runs'])==4 and all(s['expected_result'] for s in r['runs']) and r['source_binding_matches']; (out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
assert r['passed'],'Source changed during framing wire gate'
print(r['runs'][0]['output'].strip()); print('PASS: three compiled framing controls; receipt:',out/'receipt.json')
