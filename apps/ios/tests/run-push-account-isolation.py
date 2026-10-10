#!/usr/bin/env python3
"""Execute actual push identity/cleanup methods against closed synthetic boundaries."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--out',type=Path);args=a.parse_args()
out=args.out or Path(tempfile.mkdtemp(prefix='rendprop-push-isolation-'));out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/'apps/ios/Rendprop/Push/PushManager.swift',ROOT/'apps/ios/Rendprop/Auth/AuthStore.swift',ROOT/'apps/ios/Rendprop/RendpropApp.swift',Path(__file__).resolve(),ROOT/'apps/ios/tests/PushAccountIsolationTests.swift',ROOT/'apps/ios/Rendprop/DeepLink/DeepLink.swift']
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths};before=hashes();push,auth,app=[p.read_text()for p in paths[:3]]
def block(s,anchor):
 start=s.index(anchor);begin=s.index('{',start);depth=0;quote=False;escape=False
 for i in range(begin,len(s)):
  c=s[i]
  if quote:
   if escape:escape=False
   elif c=='\\':escape=True
   elif c=='"':quote=False
   continue
  if c=='"':quote=True;continue
  if c=='{':depth+=1
  if c=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise RuntimeError('Unclosed '+anchor)
identity=block(push,'struct PushAccountIdentity');pending=block(push,'struct PendingPushUnregister')
methods='\n'.join(block(push,x)for x in ['    static var currentIdentity','    func handleDeviceToken','    private func registerDeviceToken','    func accountWillChange','    func accountDidChange','    private func finishPendingUnregisters','    static func accepts','    func handle(payload:'])
authmethods='\n'.join(block(auth,x)for x in ['    @MainActor static func pendingPushUnregisters','    @MainActor static func retainPushUnregister','    @MainActor static func removePushUnregister'])
http=block(push,'    @MainActor static func send(path:')
route=block(app,'            .onChange(of: analyticsAuth.userID)')
routebody=route[route.index('{ nextOwner in')+len('{ nextOwner in'):-1]
assert 'incomingQueue = NativeIncomingQueue()'in route,'Account-change queue retains old push route'
# Exact source ordering is a separate binding oracle; all mutation assertions below execute copied methods.
apply=block(auth,'    private func applySession')
assert apply.index('PushManager.shared.accountWillChange()')<apply.index('userID = sub')
assert apply.index('onAccountChanged?(id)')<apply.index('userID = sub')
assert apply.index('persistTokens(')<apply.index('PushManager.shared.accountDidChange()')
stub=r'''
import Foundation
final class UserDefaults {static let standard=UserDefaults();var values:[String:Any]=[:]
 func bool(forKey key:String)->Bool{values[key]as?Bool ?? false};func string(forKey key:String)->String?{values[key]as?String}
 func set(_ value:Any,forKey key:String){values[key]=value};func removeObject(forKey key:String){values.removeValue(forKey:key)}}
enum APIError:Error {case decoding,badResponse(Int),notConfigured;var isNotFound:Bool{if case .badResponse(404)=self{return true};return false}}
enum CloudSyncError:Error{case identityChanged}
enum Config{static let enablePush=true;static let isUITesting=false;static let isSessionNetworkTesting=false;static let useLiveBackend=true}
enum Analytics{static let appVersion="synthetic"}
@MainActor final class UNUserNotificationCenter {static let center=UNUserNotificationCenter();var removed=0;static func current()->UNUserNotificationCenter{center};func removeAllDeliveredNotifications(){removed+=1};func removeAllPendingNotificationRequests(){removed+=1}}
@MainActor enum SecureStore {static var values:[String:String]=[:];static var failSet=false;static var failRead=false
 static func getChecked(_ key:String)throws->String?{if failRead{throw APIError.decoding};return values[key]}
 static func set(_ key:String,_ value:String)->Bool{if failSet{return false};values[key]=value;return true}
 static func remove(_ key:String)->Bool{values.removeValue(forKey:key);return true}}
@MainActor final class AuthStore {static let shared=AuthStore();var userID:String?;var isSignedIn=true;var syncSessionRevision:UInt64=1;static var access="synthetic-A"
 enum Keys{static let pendingPushUnregisters="auth.pendingPushUnregisters.v1"}
 static func storedAccessToken()->String?{access};static func validAccessToken()async->String?{access}
__AUTH__
}
@MainActor enum PushHTTP {
 struct Request {let method:String;let owner:UUID?;let credential:String;let body:[String:Any]?}
 static var requests:[Request]=[];static var pausedOwner:UUID?;static var postContinuation:CheckedContinuation<Void,Never>?
 static var holdDelete=false;static var deleteContinuation:CheckedContinuation<Void,Never>?
 static var deleteResponse=Data(#"{"ok":true,"unregistered":true}"#.utf8);static var deleteFails=false
__HTTP__
 static func sendCaptured(path:[String],method:String,body:[String:Any]?,accessToken:String)async throws->Data{
  let owner=PushManager.currentIdentity?.owner
  requests.append(Request(method:method,owner:owner,credential:accessToken,body:body))
  if method=="DELETE"{if holdDelete{await withCheckedContinuation{deleteContinuation=$0}};if deleteFails{throw APIError.badResponse(401)};return deleteResponse}
  if method=="POST",owner==pausedOwner{await withCheckedContinuation{postContinuation=$0}}
  return Data(#"{"ok":true}"#.utf8)
 }
 static func reset(){requests=[];pausedOwner=nil;postContinuation=nil;holdDelete=false;deleteContinuation=nil;deleteResponse=Data(#"{"ok":true,"unregistered":true}"#.utf8);deleteFails=false}
}
enum PushRoute:Equatable {case leads,tour(DeepLink)}
@MainActor final class PushManager {static let shared=PushManager()
 var pendingRoute:PushRoute?;var showPrePrompt=false;var isAllowed=false
 private var registeredToken:String?;private var registeredIdentity:PushAccountIdentity?
 private var registrationTask:Task<Void,Never>?;private var registrationOperation:UUID?
 private var unregisterTask:Task<Bool,Never>?;private var unregisterBlockedInMemory=false;private var deviceRouteMissing=false
 private var lastDeviceToken:String?{get{UserDefaults.standard.string(forKey:"push.deviceToken.v1")} set{UserDefaults.standard.set(newValue as Any,forKey:"push.deviceToken.v1")}}
 private static var isSuppressed:Bool{!Config.enablePush || Config.isUITesting || Config.isSessionNetworkTesting}
 static let apnsEnvironment="sandbox";func registerWithAPNs(){}
 var acknowledgedOwner:UUID?{registeredIdentity?.owner};var acknowledgedToken:String?{registeredToken}
__METHODS__
}
'''
body='import Foundation\n'+paths[5].read_text()+'\n'+identity+'\n'+pending+'\n'+stub.replace('__AUTH__',authmethods).replace('__HTTP__',http).replace('__METHODS__',methods)
body+='\n@MainActor final class IncomingModel {func syncSpaceTypeIfNeeded(){};func refreshCloudWorkspace()async{}}\n@MainActor final class PaywallRouter {static let shared=PaywallRouter();func dismiss(){}}\n@MainActor final class RootIncomingHarness {var incomingLink:DeepLink?;var rootSheet:String?;var incomingLinkError=false;var incomingQueue=NativeIncomingQueue();var incomingAccountOwner:String?;let model=IncomingModel()\nfunc accountChanged(nextOwner:String?) {\n'+routebody+'\n}\n}\n'
faults=[('actual',None,None,None),('retain-root-queue','incomingQueue = NativeIncomingQueue()','_ = incomingQueue','A queued account route survived owner change'),('skip-cleanup-barrier','guard await finishPendingUnregisters(), !Task.isCancelled,','guard true, !Task.isCancelled,','B POST crossed unacknowledged A cleanup'),('accept-incomplete-ack','object["unregistered"] as? Bool == true,','true,','Incomplete cleanup acknowledgment permitted B POST'),('drop-server-category',' || type == "lead_received"','', 'Actual emitted lead notification did not open inbox'),('accept-foreign-payload','UUID(uuidString: raw) == identity.owner','!raw.isEmpty','Other account notification accepted'),('late-acknowledgment',None,None,'Late A acknowledgment replaced B binding')]
results=[]
for name,old,new,expected in faults:
 current=body
 if old:
  assert old in current,name;current=current.replace(old,new)
 if name=='late-acknowledgment':
  old1='guard PushManager.currentIdentity == identity else { throw CloudSyncError.identityChanged }';assert old1 in current;current=current.replace(old1,'guard true else { throw CloudSyncError.identityChanged }')
  old2='guard !Task.isCancelled, Self.currentIdentity == identity,\n                      registrationOperation == operation else { return }';assert old2 in current;current=current.replace(old2,'guard true else { return }')
 folder=out/name;folder.mkdir(exist_ok=True);src=folder/'ActualPush.swift';src.write_text(current);binary=folder/'checks'
 c=subprocess.run(['xcrun','swiftc','-parse-as-library',str(src),str(paths[4]),'-o',str(binary)],capture_output=True,text=True,timeout=90);(folder/'compile.log').write_text(c.stdout+c.stderr)
 if c.returncode:raise RuntimeError('Compile failed '+str(folder/'compile.log'))
 r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=25);(folder/'runtime.log').write_text(r.stdout+r.stderr)
 passed=r.returncode==0 if expected is None else r.returncode!=0 and expected in r.stdout+r.stderr
 results.append({'case':name,'compileExit':c.returncode,'runtimeExit':r.returncode,'passed':passed,'expected':expected})
 if not passed:raise RuntimeError('Oracle failed '+str(folder/'runtime.log'))
receipt={'passed':before==hashes()and all(x['passed']for x in results),'sourceHashes':before,'sourceUnchanged':before==hashes(),'results':results,'externalRequests':0,'limitations':'Actual native state/queue methods with synthetic Keychain, OS and HTTP; no live APNs, real credential, camera or provider proof. Expired outgoing JWT or unreadable cleanup queue deliberately blocks new account registration; previously delivered OS notifications cannot be recalled offline.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':receipt['passed'],'receipt':str(out/'receipt.json'),'actual':(out/'actual/runtime.log').read_text(),'controls':len(results)-1}))
