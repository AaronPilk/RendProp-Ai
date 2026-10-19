#!/usr/bin/env python3
import pathlib,tempfile,subprocess,json,hashlib
repo=pathlib.Path(__file__).resolve().parents[3]
source=(repo/'apps/ios/Rendprop/Networking/APIClient.swift').read_text()
start=source.index('struct AIPhotoEditRequest:');opening=source.index('{',start);depth=0
for at in range(opening,len(source)):
 if source[at]=='{':depth+=1
 elif source[at]=='}':
  depth-=1
  if depth==0:end=at+1;break
with tempfile.TemporaryDirectory(prefix='rendprop-photo-pending-')as temp:
 p=pathlib.Path(temp);(p/'Request.swift').write_text('import Foundation\n'+source[start:end])
 helper=repo/'apps/ios/Rendprop/Photos/PhotoPendingEdit.swift';actual=helper.read_text()
 variants=[('actual',actual,0),('fresh-request-on-replay',actual.replace('return Saved(request: entry.request, url: url)','return Saved(request: proposed, url: url)'),1),('accept-mutated-saved-body',actual.replace('try fingerprint(entry.request, identity: identity) == digest,','true,'),1)]
 for name,text,negative in variants:
  (p/'Pending.swift').write_text(text)
  subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'Request.swift'),str(p/'Pending.swift'),str(repo/'apps/ios/tests/PhotoPendingEditTests.swift'),'-o',str(p/'tests')],check=True)
  result=subprocess.run([str(p/'tests')],capture_output=True,text=True)
  if negative:
   expected='A lost answer must retain the exact paid request' if name=='fresh-request-on-replay' else 'Changed saved bytes must fail closed'
   assert result.returncode!=0 and expected in result.stderr,name
  else:assert result.returncode==0,result.stderr;print(result.stdout.strip())
 service=(repo/'apps/ios/Rendprop/Photos/PhotoEditService.swift').read_text()
 assert service.index('PhotoPendingEdit.begin(request,')<service.index('api.aiPhotoEdit(request)')
 assert 'request = pending!.request' in service and 'originalAssetID: request.originalAssetID' in service
 assert 'PhotoPendingEdit.finish(pending)' in service and 'failure.code == "photo_quality_refused"' in service
 print(json.dumps({'actual_pending_filesystem':True,'compiled_negative_controls':2,'service_recovery_integration_source_gates':True,'source_sha256':hashlib.sha256(actual.encode()).hexdigest(),'limitation':'Foundation/filesystem execution with extracted actual request type; network and phone UI are separate acceptance.'}))
