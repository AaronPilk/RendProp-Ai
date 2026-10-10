import Foundation
@main struct PushAccountIsolationTests {
 @MainActor static func main() async throws {
  var checks=0
  func check(_ value:Bool,_ message:String){guard value else{fatalError(message)};checks+=1}
  func tick()async{for _ in 0..<100{await Task.yield()};try? await Task.sleep(nanoseconds:20_000_000)}
  let a=UUID(uuidString:"11000000-0000-4000-8000-000000000001")!
  let b=UUID(uuidString:"11000000-0000-4000-8000-000000000002")!
  func identity(_ owner:UUID,_ revision:UInt64){AuthStore.shared.userID=owner.uuidString;AuthStore.shared.isSignedIn=true;AuthStore.shared.syncSessionRevision=revision;AuthStore.access=owner==a ? "synthetic-A" : "synthetic-B"}
  func reset(){PushHTTP.reset();SecureStore.values=[:];SecureStore.failSet=false;SecureStore.failRead=false;UserDefaults.standard.values=[:];identity(a,1)}
  reset()
  let push=PushManager();PushHTTP.pausedOwner=a
  push.handleDeviceToken(Data([0xab,0xcd]));await tick()
  check(PushHTTP.requests.filter{$0.method=="POST"}.count==1,"Initial A registration missing")
  push.pendingRoute = .leads;push.showPrePrompt=true;PushHTTP.holdDelete=true
  push.accountWillChange();identity(b,2);push.accountDidChange();await tick()
  check(push.pendingRoute==nil && !push.showPrePrompt,"Old account presentation retained")
  check(PushHTTP.requests.filter{$0.method=="POST"}.count==1,"B POST crossed unacknowledged A cleanup")
  let deletion=PushHTTP.requests.first{$0.method=="DELETE"}!
  check(deletion.credential=="synthetic-A","Cleanup used replacement credential")
  check(deletion.body?["device_token"]as?String=="abcd" && deletion.body?["environment"]as?String=="sandbox","Cleanup token/environment changed")
  check(deletion.body?["user_id"]==nil && deletion.body?["session_id"]==nil,"Cleanup trusts client authority")
  check(try AuthStore.pendingPushUnregisters().count==1,"Cleanup was not retained before request")
  PushHTTP.deleteContinuation?.resume();PushHTTP.deleteContinuation=nil;await tick()
  check(push.acknowledgedOwner==b,"B binding missing after exact cleanup acknowledgment")
  check(try AuthStore.pendingPushUnregisters().isEmpty,"Acknowledged cleanup remained pending")
  PushHTTP.postContinuation?.resume();PushHTTP.postContinuation=nil;await tick()
  check(push.acknowledgedOwner==b,"Late A acknowledgment replaced B binding")
  push.handleDeviceToken(Data([0xab,0xcd]));await tick()
  check(PushHTTP.requests.filter{$0.method=="POST"}.count==2,"Same B token registered repeatedly")
  check(PushHTTP.requests.last{$0.method=="POST"}?.credential=="synthetic-B","B registration used A credential")
  reset();identity(b,3)
  let cleanup=PendingPushUnregister(owner:a,deviceToken:"abcd",environment:"sandbox",accessToken:"synthetic-A")
  check(AuthStore.retainPushUnregister(cleanup),"Could not persist synthetic pending cleanup")
  UserDefaults.standard.set("abcd",forKey:"push.deviceToken.v1");PushHTTP.deleteResponse=Data(#"{"ok":true}"#.utf8)
  let restarted=PushManager();restarted.accountDidChange();await tick()
  check(PushHTTP.requests.filter{$0.method=="POST"}.isEmpty,"Incomplete cleanup acknowledgment permitted B POST")
  check(try AuthStore.pendingPushUnregisters()==[cleanup],"Incomplete acknowledgment erased durable barrier")
  reset();identity(b,4);UserDefaults.standard.set("abcd",forKey:"push.deviceToken.v1")
  check(AuthStore.retainPushUnregister(cleanup),"Could not persist retry cleanup")
  PushHTTP.deleteFails=true;let expired=PushManager();expired.accountDidChange();await tick()
  check(PushHTTP.requests.filter{$0.method=="POST"}.isEmpty,"Expired cleanup credential permitted B POST")
  check(try AuthStore.pendingPushUnregisters()==[cleanup],"Expired credential erased old cleanup")
  reset();UserDefaults.standard.set("abcd",forKey:"push.deviceToken.v1");SecureStore.failSet=true
  let failedStorage=PushManager();failedStorage.accountWillChange();identity(b,5);failedStorage.accountDidChange();await tick()
  check(PushHTTP.requests.isEmpty,"Failed secure retention permitted registration")
  check(UserDefaults.standard.bool(forKey:"push.unregisterStorageBlocked.v1"),"Secure storage failure was not durable")
  reset();SecureStore.values[AuthStore.Keys.pendingPushUnregisters]="corrupt";identity(b,6);UserDefaults.standard.set("abcd",forKey:"push.deviceToken.v1")
  let corrupt=PushManager();corrupt.accountDidChange();await tick()
  check(PushHTTP.requests.isEmpty,"Corrupt cleanup queue permitted registration")
  let bid=PushAccountIdentity(owner:b,revision:6)
  check(!PushManager.accepts(payload:["recipient_user_id":a.uuidString,"rp":["type":"leads"]],identity:bid),"Other account notification accepted")
  check(!PushManager.accepts(payload:["rp":["type":"leads"]],identity:bid),"Legacy unbound notification accepted")
  check(!PushManager.accepts(payload:["recipient_user_id":b.uuidString],identity:nil),"Signed-out notification accepted")
  check(PushManager.accepts(payload:["recipient_user_id":b.uuidString],identity:bid),"Current account notification rejected")
  check(!PushManager.accepts(payload:["recipient_user_id":"malformed"],identity:bid),"Malformed recipient accepted")
  let actualPayload:[AnyHashable:Any] = ["recipient_user_id":b.uuidString,"category":"lead_received","deep_link":"https://rendprop.com/f/synthetic-listing","data":["slug":"synthetic-listing"]]
  let routes=PushManager();routes.handle(payload:actualPayload)
  check(routes.pendingRoute == .leads,"Actual emitted lead notification did not open inbox")
  routes.pendingRoute=nil
  routes.handle(payload:["recipient_user_id":a.uuidString,"category":"lead_received","deep_link":"https://rendprop.com/f/synthetic-listing"])
  check(routes.pendingRoute==nil,"Foreign emitted lead notification opened a route")
  routes.handle(payload:["recipient_user_id":b.uuidString,"category":"render_finished","deep_link":"https://foreign.invalid/f/foreign"])
  check(routes.pendingRoute==nil,"Untrusted emitted URL opened a route")
  routes.handle(payload:["recipient_user_id":b.uuidString,"category":"render_finished","deep_link":"https://rendprop.com/f/synthetic-listing"])
  check(routes.pendingRoute == .tour(.tour(slug:"synthetic-listing")),"Actual emitted render link did not open")
  let root=RootIncomingHarness();root.incomingAccountOwner=a.uuidString
  root.incomingQueue.enqueue(.leads);root.incomingQueue.enqueue(.link(.tour(slug:"A-private")))
  root.accountChanged(nextOwner:b.uuidString)
  check(!root.incomingQueue.hasPending,"A queued account route survived owner change")
  root.incomingQueue.enqueue(.leads);root.accountChanged(nextOwner:nil)
  check(!root.incomingQueue.hasPending,"Signed-out account route survived owner change")
  let cold=RootIncomingHarness();cold.incomingQueue.enqueue(.link(.tour(slug:"public-cold-link")))
  cold.accountChanged(nextOwner:b.uuidString)
  check(cold.incomingQueue.takeNext(canPresent:true) == .link(.tour(slug:"public-cold-link")),"Cold external public link was lost at first sign-in")
  print("PASS: \(checks) actual push account isolation assertions; closed synthetic HTTP/Keychain/OS")
 }
}
