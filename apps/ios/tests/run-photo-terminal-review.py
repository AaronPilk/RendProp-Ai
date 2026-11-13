#!/usr/bin/env python3
"""Compile actual native terminal-error policy and filesystem journal; no phone/network."""
import pathlib,tempfile,subprocess,json,hashlib
repo=pathlib.Path(__file__).resolve().parents[3]
service=(repo/'apps/ios/Rendprop/Photos/PhotoEditService.swift').read_text()
api=(repo/'apps/ios/Rendprop/Networking/APIClient.swift').read_text()
start=api.index('struct AIPhotoEditRequest:');opening=api.index('{',start);depth=0
for at in range(opening,len(api)):
 if api[at]=='{':depth+=1
 elif api[at]=='}':
  depth-=1
  if depth==0:end=at+1;break
request=api[start:end]
error=api[api.index('enum APIError:'):api.index('// MARK: - Admin console models')]
start=service.index('            if let failure = error as? APIError,');end=service.index(' }',start)+2
policy=service[start:end]
assert 'failure.status == 422 && failure.code == "photo_quality_closed"'in policy
main='''
func release(_ error:Error,_ pending:PhotoPendingEdit.Saved?) {
POLICY
}
@main struct TerminalPhotoReview {
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  var assertions=0
  let cases:[(any Error,Bool)]=[
   (APIError.server(status:422,code:"photo_quality_closed",message:"Closed. New edit may use allowance."),true),
   (APIError.server(status:409,code:"photo_quality_hold",message:"Unresolved"),false),
   (APIError.server(status:409,code:"photo_quality_pending",message:"Pending"),false),
   (APIError.server(status:409,code:"photo_quality_closed",message:"Wrong status"),false),
   (APIError.server(status:422,code:"photo_quality_hold",message:"Not closed"),false),
   (APIError.server(status:422,code:nil,message:"Missing code"),false),
   (APIError.badResponse(422),false),
   (APIError.server(status:503,code:"upstream",message:"Unknown"),false),
   (URLError(.networkConnectionLost),false),
   (APIError.server(status:422,code:"photo_quality_refused",message:"Rejected"),true)
  ]
  for (index,pair) in cases.enumerated() {
   let directory=root.appendingPathComponent(String(index)),identity=PhotoPendingEdit.Identity(actor:"synthetic-owner",library:UUID(),listing:UUID(),sourceVersion:"owned-original")
   var request=AIPhotoEditRequest(imageBase64:"aW1tdXRhYmxlLXBob3Rv",edit:"stage");request.style="modern"
   let saved=try PhotoPendingEdit.begin(request,identity:identity,directory:directory)
   let original=try Data(contentsOf:saved.url)
   release(pair.0,saved)
   precondition(FileManager.default.fileExists(atPath:saved.url.path) != pair.1,"Only authoritative closed422 can release a held operation");assertions+=1
   if !pair.1 {
    let unchanged=try Data(contentsOf:saved.url);precondition(unchanged==original,"Unknown/active journal changed");assertions+=1
    let replay=try PhotoPendingEdit.begin(request,identity:identity,directory:directory);precondition(replay.request==saved.request,"Unknown reply created a new paid key");assertions+=1
   } else {
    let folder=saved.url.deletingLastPathComponent();let remaining=try FileManager.default.contentsOfDirectory(atPath:folder.path);precondition(remaining.isEmpty,"Clearing terminal review auto-created an operation");assertions+=1
    let explicit=try PhotoPendingEdit.begin(request,identity:identity,directory:directory);precondition(explicit.request.idempotencyKey != saved.request.idempotencyKey,"Next explicit action needs a new key");assertions+=1
   }
  }
  print("Terminal photo review: \\(assertions) actual policy/filesystem assertions passed")
 }
}
'''.replace('POLICY',policy)
with tempfile.TemporaryDirectory(prefix='rendprop-photo-closed-')as temp:
 p=pathlib.Path(temp);(p/'ActualTypes.swift').write_text('import Foundation\n'+request+'\n'+error);(p/'Tests.swift').write_text('import Foundation\n'+main)
 helper=repo/'apps/ios/Rendprop/Photos/PhotoPendingEdit.swift'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'ActualTypes.swift'),str(helper),str(p/'Tests.swift'),'-o',str(p/'tests')],check=True)
 result=subprocess.run([str(p/'tests')],capture_output=True,text=True);assert result.returncode==0,result.stderr;print(result.stdout.strip())
 print(json.dumps({'passed':True,'actual_error_policy_sha256':hashlib.sha256(policy.encode()).hexdigest(),'actual_pending_sha256':hashlib.sha256(helper.read_bytes()).hexdigest(),'phone_ui':False,'network_calls':0}))
