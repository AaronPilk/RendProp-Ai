import Foundation
@main struct PurchaseFulfilmentTests {
 @MainActor static func main() async {
  let owner=UUID(uuidString:"bb100001-0000-4000-8000-000000000001")!,other=UUID(uuidString:"bb100001-0000-4000-8000-000000000002")!,org=UUID(uuidString:"bb200001-0000-4000-8000-000000000001")!,foreign=UUID(uuidString:"bb200001-0000-4000-8000-000000000002")!
  var count=0
  func check(_ ok:Bool,_ message:String){count+=1;if !ok{fatalError(message)}}
  func token(_ actor:UUID)->String {let data=try! JSONSerialization.data(withJSONObject:["sub":actor.uuidString.lowercased()]);return "fixture."+data.base64EncodedString().replacingOccurrences(of:"=",with:"")+".fixture"}
  func reset(){AuthStore.shared.userID=owner.uuidString.lowercased();AuthStore.shared.syncSessionRevision=1;AuthStore.shared.isSignedIn=true;AuthStore.token=token(owner);AuthStore.onToken=nil;AuthStore.shared.onRefresh=nil;WorkspaceContext.selectedOrgID=org;UserDefaults.standard.values=[:];URLSession.requests=[];URLSession.statuses=[200];URLSession.onResponse=nil}
  func fixture(_ id:UInt64=1)->(PurchaseManager,FulfilmentAPI,Transaction){reset();let m=PurchaseManager(),api=FulfilmentAPI(org:org),t=Transaction(id,owner:owner);m.api=api;try! PurchaseWorkspaceBindingStore.prepare(owner:owner,productID:t.productID,orgID:org);return(m,api,t)}
  for status in [400,401,402,403,404,409,413] {
   let(m,api,t)=fixture(UInt64(status));api.error=APIError.server(status:status,code:status==401 ? "unauthorized":nil,message:"synthetic refusal")
   check(!(await m.handle(.verified(t),event:"purchase")),"Permanent refusal accepted");check(t.finishes==0,"Permanent refusal discarded paid receipt");check(m.unsyncedCount==1,"Refused receipt lost");check(m.lastError?.contains("retained")==true,"Recovery message lost custody")
   await m.retryUnsynced(automatically:true);check(api.requests==1,"Permanent refusal automatically retried")
   let relaunched=PurchaseManager();relaunched.api=api
   check(!(await relaunched.handle(.verified(t),event:"entitlement")),"Relaunch ignored persisted refusal");check(api.requests==1,"Relaunch automatically retried refusal")
   api.error=nil;check(await relaunched.handle(.verified(t),event:"restore"),"Explicit Restore failed to recover");check(t.finishes==1,"Accepted Restore did not finish once");check(relaunched.unsyncedCount==0,"Accepted Restore retained queue")
  }
  for status in [408,429,500,503] {let(m,api,t)=fixture(UInt64(status));api.error=APIError.badResponse(status);check(!(await m.handle(.verified(t),event:"entitlement")),"Temporary refusal accepted");await m.retryUnsynced(automatically:true);check(api.requests==2,"Temporary failure was never retried");check(t.finishes==0,"Temporary failure finished receipt")}
  check(PurchaseFulfilmentRecovery.automaticallyRetry(URLError(.notConnectedToInternet)),"Offline transport classified permanent")
  check(!PurchaseFulfilmentRecovery.automaticallyRetry(URLError(.cancelled)),"Cancelled request retries automatically")
  check(!PurchaseFulfilmentRecovery.automaticallyRetry(CloudSyncError.identityChanged),"Changed identity retries automatically")
  let(m,api,t)=fixture(900);api.result=EntitlementSync(plan:"pro",source:"apple",expiresAt:t.expirationDate,productId:t.productID,originalTransactionId:"71",environment:"Production",servingActivation:.init(orgId:org,available:false,funded:false,authority:.unavailable))
  check(!(await m.handle(.verified(t),event:"purchase")),"Unavailable activation accepted");check(t.finishes==0,"Unavailable activation finished paid receipt");await m.retryUnsynced(automatically:true);check(api.requests==1,"Unavailable activation automatically loops");check(m.lastError?.contains("support")==true,"Unavailable activation lacks support route")
  for revoked in [false,true] {let(m,api,t)=fixture(revoked ? 901:902);if revoked{t.revocationDate=Date()}else{t.expirationDate=Date().addingTimeInterval(-10)};api.result=EntitlementSync(plan:"free",source:"apple",expiresAt:t.expirationDate,productId:t.productID,originalTransactionId:"71",environment:"Production",servingActivation:.init(orgId:org,available:false,funded:false,authority:.unavailable));check(await m.handle(.verified(t),event:"updates"),"Terminal server acknowledgement not finished");check(t.finishes==1,"Terminal receipt remains unfinished")}
  do {let(m,api,t)=fixture(905);api.result=EntitlementSync(plan:"pro",source:"apple",expiresAt:t.expirationDate,productId:t.productID,originalTransactionId:"another-chain",environment:"Production");check(!(await m.handle(.verified(t),event:"purchase")),"Foreign returned chain accepted");check(t.finishes==0,"Foreign returned chain finished paid receipt")}
  do {let(m,api,t)=fixture(906);WorkspaceContext.selectedOrgID=foreign;check(!(await m.handle(.verified(t),event:"entitlement")),"Foreign selected workspace accepted receipt");check(api.requests==0,"Foreign selected workspace dispatched receipt");check(m.lastError?.contains("saved workspace")==true,"Foreign workspace lacks actionable recovery")}
  for transition in ["actor","revision","workspace","ABA"] {let(m,api,t)=fixture(910);api.onSync={if transition=="actor"{AuthStore.shared.userID=other.uuidString.lowercased()}else if transition=="workspace"{WorkspaceContext.selectedOrgID=foreign}else{AuthStore.shared.syncSessionRevision+=1}};check(!(await m.handle(.verified(t),event:"purchase")),"Late response accepted");check(t.finishes==0,"Late response finished replacement account");check(m.unsyncedCount==1,"Late response wiped old queue")}
  do {let(m,api,t)=fixture(920);m.onRenewal={WorkspaceContext.selectedOrgID=foreign};check(!(await m.handle(.verified(t),event:"updates")),"Late renewal retargeted receipt");check(api.requests==0,"Late renewal dispatched under changed workspace");check(t.finishes==0,"Late renewal discarded receipt")}
  do {let(m,api,_)=fixture();let t=Transaction(930,product:"unknown.paid.product",owner:owner);check(!(await m.handle(.verified(t),event:"updates")),"Unknown product guessed");check(t.finishes==0,"Unknown product discarded");check(api.requests==0,"Unknown product submitted");check(m.lastError?.contains("support")==true,"Unknown product lacks support")}
  do {let(m,api,_)=fixture();check(!(await m.handle(.unverified,event:"updates")),"Unverified receipt accepted");check(api.requests==0,"Unverified receipt submitted")}
  do {let(m,api,t)=fixture();api.error=APIError.server(status:403,code:"sandbox_testing_required",message:"refused");_ = await m.handle(.verified(t),event:"updates");check(m.lastError?.contains("authorize this testing workspace")==true,"Sandbox recovery not actionable")}
  // Actual HTTP methods reject substituted JWTs and same-actor session/workspace
  // changes, including the force-refresh 401 boundary. No network is used.
  reset();AuthStore.token=token(other)
  do {_ = try await PurchasesRequest.post(path:["me","entitlement"],json:["expected_org_id":org.uuidString],requiredCurrentOrg:org);fatalError("Wrong JWT dispatched")}catch{};check(URLSession.requests.isEmpty,"Wrong JWT dispatched")
  reset();AuthStore.onToken={AuthStore.shared.syncSessionRevision+=1}
  do {_ = try await PurchasesRequest.post(path:["me","entitlement"],json:[:],requiredCurrentOrg:org);fatalError("Late token dispatched")}catch{};check(URLSession.requests.isEmpty,"Late token dispatched")
  reset();URLSession.statuses=[401,200];AuthStore.shared.onRefresh={AuthStore.token=token(other)}
  do {_ = try await PurchasesRequest.post(path:["me","entitlement"],json:[:],requiredCurrentOrg:org);fatalError("Foreign refreshed JWT dispatched")}catch{};check(URLSession.requests.count==1,"Foreign refreshed JWT dispatched")
  reset();URLSession.statuses=[401,200];var responses=0;URLSession.onResponse={responses+=1;if responses==2{WorkspaceContext.selectedOrgID=foreign}}
  do {_ = try await PurchasesRequest.post(path:["me","entitlement"],json:[:],requiredCurrentOrg:org);fatalError("Late second response accepted")}catch{};check(URLSession.requests.count==2,"Expected idempotent retry missing");check(URLSession.requests[0].value(forHTTPHeaderField:"Idempotency-Key")==URLSession.requests[1].value(forHTTPHeaderField:"Idempotency-Key"),"401 retry changed logical operation")
  reset();AuthStore.token=token(other)
  do {_ = try await PurchasesRequest.getBilling();fatalError("Foreign billing JWT dispatched")}catch{};check(URLSession.requests.isEmpty,"Foreign billing JWT dispatched")
  reset();print("Purchase fulfilment: \(count) checks passed; synthetic StoreKit/HTTP only")
 }
}
