#!/usr/bin/env python3
"""Execute actual push identity/cleanup methods against closed synthetic boundaries."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--out',type=Path);args=a.parse_args()
out=args.out or Path(tempfile.mkdtemp(prefix='rendprop-push-isolation-'));out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/'apps/ios/Rendprop/Push/PushManager.swift',ROOT/'apps/ios/Rendprop/Auth/AuthStore.swift',ROOT/'apps/ios/Rendprop/RendpropApp.swift',Path(__file__).resolve(),ROOT/'apps/ios/tests/PushAccountIsolationTests.swift',ROOT/'apps/ios/Rendprop/DeepLink/DeepLink.swift',ROOT/'apps/ios/Rendprop/Screens/SettingsView.swift']
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
methods='\n'.join(block(push,x)for x in ['    static var currentIdentity','    func start','    func retryPendingCleanup','    func prepareForLocalDataErasure','    func handleDeviceToken','    private func registerDeviceToken','    func accountWillChange','    func accountDidChange','    private func finishPendingUnregisters','    static func accepts','    func handle(payload:'])
authmethods='\n'.join(block(auth,x)for x in ['    @MainActor static func pendingPushUnregisters','    @MainActor static func recoverPushUnregisterStorage','    @MainActor static func retainPushUnregister','    @MainActor static func removePushUnregister','    @MainActor static func discardPendingPushUnregisters'])
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
enum APIError:Error {case decoding,badResponse(Int),notConfigured,server(Int,String)
 var status:Int?{switch self{case .badResponse(let s),.server(let s,_):return s;default:return nil}}
 var code:String?{if case .server(_,let c)=self{return c};return nil}
 var isNotFound:Bool{status==404};var isUnauthorized:Bool{status==401};var isForbidden:Bool{status==403}}
enum StorageFailure:Error{case locked}
enum CloudSyncError:Error{case identityChanged}
enum Config{static let enablePush=true;static let isUITesting=false;static let isSessionNetworkTesting=false;static let useLiveBackend=true}
enum Analytics{static let appVersion="synthetic"}
@MainActor final class UNUserNotificationCenter {static let center=UNUserNotificationCenter();var removed=0;var delegate:Any?;static func current()->UNUserNotificationCenter{center};func removeAllDeliveredNotifications(){removed+=1};func removeAllPendingNotificationRequests(){removed+=1}}
@MainActor final class UIApplication {static let shared=UIApplication();var unregisterCalls=0;func unregisterForRemoteNotifications(){unregisterCalls+=1}}
@MainActor final class PushDelegate{static let shared=PushDelegate()}
@MainActor enum SecureStore {static var values:[String:String]=[:];static var failSet=false;static var failRead=false;static var failRemove=false
 static func getChecked(_ key:String)throws->String?{if failRead{throw StorageFailure.locked};return values[key]}
 static func set(_ key:String,_ value:String)->Bool{if failSet{return false};values[key]=value;return true}
 static func remove(_ key:String)->Bool{if failRemove{return false};values.removeValue(forKey:key);return true}}
@MainActor final class AuthStore {static let shared=AuthStore();var userID:String?;var isSignedIn=true;var isIdentified=true;var syncSessionRevision:UInt64=1;static var access="synthetic-A"
 enum Keys{static let pendingPushUnregisters="auth.pendingPushUnregisters.v1"}
 func signOut(){PushManager.shared.accountWillChange();isSignedIn=false;isIdentified=false;syncSessionRevision+=1;userID=nil}
 func discardPendingAdoption(){}
 static func storedAccessToken()->String?{access};static func validAccessToken()async->String?{access}
__AUTH__
}
@MainActor enum PushHTTP {
 struct Request {let method:String;let owner:UUID?;let credential:String;let body:[String:Any]?}
 static var requests:[Request]=[];static var pausedOwner:UUID?;static var postContinuation:CheckedContinuation<Void,Never>?
 static var holdDelete=false;static var deleteContinuation:CheckedContinuation<Void,Never>?
 static var deleteResponse=Data(#"{"ok":true,"unregistered":true}"#.utf8);static var deleteError:Error?
__HTTP__
 static func sendCaptured(path:[String],method:String,body:[String:Any]?,accessToken:String)async throws->Data{
  let owner=PushManager.currentIdentity?.owner
  requests.append(Request(method:method,owner:owner,credential:accessToken,body:body))
  if method=="DELETE"{if holdDelete{await withCheckedContinuation{deleteContinuation=$0}};if let deleteError{throw deleteError};return deleteResponse}
  if method=="POST",owner==pausedOwner{await withCheckedContinuation{postContinuation=$0}}
  return Data(#"{"ok":true}"#.utf8)
 }
 static func reset(){requests=[];pausedOwner=nil;postContinuation=nil;holdDelete=false;deleteContinuation=nil;deleteResponse=Data(#"{"ok":true,"unregistered":true}"#.utf8);deleteError=nil}
}
enum PushRoute:Equatable {case leads,tour(DeepLink)}
@MainActor final class PushManager {static let shared=PushManager()
 var localDataErasureRevision:UInt64=0
 var pendingRoute:PushRoute?;var pendingReelJobID:UUID?;var showPrePrompt=false;var isAllowed=false
 private var registeredToken:String?;private var registeredIdentity:PushAccountIdentity?
 private var registrationTask:Task<Void,Never>?;private var registrationOperation:UUID?
 private var unregisterTask:Task<Bool,Never>?;private var unretainedCleanups:[PendingPushUnregister]=[];private var deviceRouteMissing=false
 private var lastDeviceToken:String?{get{UserDefaults.standard.string(forKey:"push.deviceToken.v1")} set{UserDefaults.standard.set(newValue as Any,forKey:"push.deviceToken.v1")}}
 private static var isSuppressed:Bool{!Config.enablePush || Config.isUITesting || Config.isSessionNetworkTesting}
 static let apnsEnvironment="sandbox";func registerWithAPNs(){};func refreshAuthorization(registerIfAllowed:Bool=false) async{}
 var acknowledgedOwner:UUID?{registeredIdentity?.owner};var acknowledgedToken:String?{registeredToken}
__METHODS__
}
'''
body='import Foundation\n'+paths[5].read_text()+'\n'+identity+'\n'+pending+'\n'+stub.replace('__AUTH__',authmethods).replace('__HTTP__',http).replace('__METHODS__',methods)
body+='\n@MainActor final class IncomingModel {func syncSpaceTypeIfNeeded(){};func refreshCloudWorkspace()async{}}\n@MainActor final class PaywallRouter {static let shared=PaywallRouter();func dismiss(){}}\n@MainActor final class RootIncomingHarness {var incomingLink:DeepLink?;var rootSheet:String?;var incomingLinkError=false;var incomingQueue=NativeIncomingQueue();var incomingAccountOwner:String?;let model=IncomingModel()\nfunc accountChanged(nextOwner:String?) {\n'+routebody+'\n}\n}\n'
faults=[('actual',None,None,None),('retain-root-queue','incomingQueue = NativeIncomingQueue()','_ = incomingQueue','A queued account route survived owner change'),('skip-cleanup-barrier','guard await finishPendingUnregisters(), !Task.isCancelled,','guard true, !Task.isCancelled,','B POST crossed unacknowledged A cleanup'),('accept-incomplete-ack','object?["unregistered"] as? Bool == true,','true,','Incomplete cleanup acknowledgment permitted B POST'),('drop-server-category',' || type == "lead_received"','', 'Actual emitted lead notification did not open inbox'),('accept-foreign-payload','UUID(uuidString: raw) == identity.owner','!raw.isEmpty','Other account notification accepted'),('late-acknowledgment',None,None,'Late A acknowledgment replaced B binding')]
assert 'retryPendingCleanup()' in block(push,'    func refreshAuthorization')
settings=paths[6].read_text()
assert 'auth.signOut(serverAccountDeleted: serverAccountsEnabled)' in block(settings,'    private func deleteAccount(')
assert 'discardPendingCleanup' not in settings
assert 'PushManager.shared.prepareForLocalDataErasure()' in block(settings,'    private func wipeLocalData(')
assert 'Button("Clear", role: .destructive) { Task { await clearLocalDataTapped() } }' in settings
clear=block(settings,'    private func clearLocalDataTapped(').replace('private ', '')
body+='''
@MainActor enum WorkspaceContext {static var selectedOrgID:UUID?=UUID()}
@MainActor final class ReelWorkQueue {static let shared=ReelWorkQueue();var pending:CheckedContinuation<Void,Never>?;var hold=false;var cancellations=0
func cancelForLocalDataErasure()async{cancellations+=1;if hold{await withCheckedContinuation{pending=$0}}}}
@MainActor final class ClosedUploads {var state:Int?=1;var cancellations=0;func cancel(){state=nil;cancellations+=1}}
enum Haptics {static func success(){}}
@MainActor final class ClearDataHarness {let auth=AuthStore.shared;let uploads=ClosedUploads();var isClearingLocalData=false,isDeletingAccount=false,showDataCleared=false;var wipes=0
func wipeLocalData(){PushManager.shared.prepareForLocalDataErasure();wipes+=1}
'''+clear+'\n}\n'
faults += [('erase-unregister-before-delete', body.replace('func wipeLocalData(){PushManager.shared.prepareForLocalDataErasure();wipes+=1}', 'func wipeLocalData(){_ = AuthStore.discardPendingPushUnregisters();PushManager.shared.prepareForLocalDataErasure();wipes+=1}'), None, 'Clear data retains failed outgoing DELETE until acknowledgment'),
('erase-keeps-local-apns',body.replace('        UIApplication.shared.unregisterForRemoteNotifications()', '        // omitted local APNs stop'),None,'Clear data stops local APNs delivery during offline server cleanup'),
('erase-keeps-notice-callback',body.replace('        localDataErasureRevision &+= 1', '        // omitted queued notice invalidation'),None,'Clear data invalidates already queued local completion callbacks'),
('erase-without-writer-wait',body.replace('        await ReelWorkQueue.shared.cancelForLocalDataErasure()', '        // omitted interrupted writer wait'),None,'Clear data waits for interrupted reel writers before erasure'),
('erase-replacement-account',body.replace('guard auth.userID == owner, auth.syncSessionRevision == revision,\n              WorkspaceContext.selectedOrgID == workspace else { return }','guard true else { return }'),None,'Clear data cannot erase a replacement session')]

assert 'accountWillChange(retainCleanup: !serverAccountDeleted)' in block(auth,'    func signOut(')
faults += [('ignore-new-retention-barrier','guard unretainedCleanups.isEmpty,\n                      !UserDefaults.standard.bool(forKey: "push.unregisterStorageBlocked.v1") else { return false }','guard true else { return false }','Cleanup admitted replacement across new failed retention'),('retain-terminal-cleanup','where api.isUnauthorized || api.isForbidden || api.code == "RP401"','where false','Terminal cleanup prevented replacement registration'),('discard-transient-cleanup','where api.isUnauthorized || api.isForbidden || api.code == "RP401"','where true','Transient cleanup allowed replacement registration'),('skip-corrupt-recovery','catch APIError.decoding {','catch APIError.notConfigured {','Readable corrupt queue stranded replacement')]
results=[]
for name,old,new,expected in faults:
 current=body
 if name.startswith("erase-"):
  assert old != body,name;current=old
 elif old:
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
receipt={'passed':before==hashes()and all(x['passed']for x in results),'sourceHashes':before,'sourceUnchanged':before==hashes(),'results':results,'externalRequests':0,'limitations':'Actual native state/queue methods with synthetic Keychain, OS and HTTP; no live APNs, real credential, camera or provider proof. Expired/forbidden outgoing credentials and readable corruption recover; transient network/5xx and locked Keychain remain retryable barriers. Token takeover safety also requires the separately tested server session-retirement RPC. Previously delivered OS notifications cannot be recalled offline.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':receipt['passed'],'receipt':str(out/'receipt.json'),'actual':(out/'actual/runtime.log').read_text(),'controls':len(results)-1}))
