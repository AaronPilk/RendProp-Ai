#!/usr/bin/env python3
"""Compile actual receipt custody, recovery, JWT request and context fences.
StoreKit, URLSession, persistence and Auth refresh are closed synthetic interfaces.
No Apple, provider, funding or external network calls.
"""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path);args=ap.parse_args()
OUT=(args.out or Path(tempfile.mkdtemp(prefix='rendprop-fulfilment-'))).resolve();OUT.mkdir(parents=True,exist_ok=True)
paths=[ROOT/p for p in ['apps/ios/Rendprop/Purchases/PurchaseManager.swift','apps/ios/Rendprop/Purchases/PurchasesAPI.swift','apps/ios/Rendprop/Purchases/SubscriptionBillingContext.swift','apps/ios/Rendprop/Networking/APIClient.swift','apps/ios/Rendprop/Auth/AuthStore.swift','apps/ios/Rendprop/Purchases/Products.swift','apps/ios/tests/PurchaseFulfilmentTests.swift','apps/ios/tests/run-purchase-fulfilment.py']]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
start=hashes();m,a,b,api,auth,products=[p.read_text()for p in paths[:6]]
def block(s,n):
 start=s.index(n);i=s.index('{',start);depth=1;j=i+1
 while depth:depth+=(s[j]=='{')-(s[j]=='}');j+=1
 return s[start:j]
interfaces=r"""
import Foundation
import CryptoKit
enum Config { static var useLiveBackend=true;static var isUITesting=false;static var enableAuth=true
 static let apiBaseURL:URL?=URL(string:"https://synthetic.invalid/functions/v1");static let supabaseAnonKey="fixture" }
enum CloudSyncError:Error {case identityChanged,invalidResponse}
enum WorkspaceContext {static var selectedOrgID:UUID?}
final class UserDefaults {static let standard=UserDefaults();var values:[String:Any]=[:]
 func data(forKey k:String)->Data?{values[k]as?Data};func string(forKey k:String)->String?{values[k]as?String}
 func set(_ value:Any,forKey k:String){values[k]=value};func removeObject(forKey k:String){values.removeValue(forKey:k)};func synchronize()->Bool{true} }
enum DirectUploader {static func sha256Hex(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()};static func sha256Hex(_ s:String)->String{sha256Hex(Data(s.utf8))}}
extension Notification.Name {static let rendpropPlanChanged=Notification.Name("fixture.plan")}
struct TrialUsageSummary {enum Status {case active,exhausted,expired};let status:Status}
struct SubscriptionBillingContext {enum TrialPresentationError:Error {case invalidResponse};let orgID:UUID;var originalTransactionIDs:[String]?}
enum RendpropPlan:String,CaseIterable {case starter,pro,team;var monthlyProductID:String{"com.rendprop.app."+rawValue+".monthly"};var annualProductID:String{"com.rendprop.app."+rawValue+".annual"}}
@MainActor final class Transaction {let id:UInt64;let originalID:UInt64=71;let productID:String;let appAccountToken:UUID?;var expirationDate:Date?=Date().addingTimeInterval(86400);var revocationDate:Date?;var finishes=0;var onFinish:(()->Void)?
 init(_ id:UInt64=1,product:String="com.rendprop.app.pro.monthly",owner:UUID?){self.id=id;productID=product;appAccountToken=owner}
 func finish()async{finishes+=1;onFinish?()} }
enum VerificationResult<T> {case verified(T),unverified;var jwsRepresentation:String{"synthetic-receipt"}}
@MainActor final class FulfilmentAPI {var requests=0;var error:Error?;var result:EntitlementSync;var onSync:(()->Void)?;var billing:SubscriptionBillingContext
 init(org:UUID){result=EntitlementSync(plan:"pro",source:"apple",expiresAt:Date().addingTimeInterval(86400),productId:nil,originalTransactionId:"71",environment:"Production");billing=SubscriptionBillingContext(orgID:org,originalTransactionIDs:["71"])}
 func syncEntitlement(signedTransaction:String,signedRenewalInfo:String?,expectedOrgID:UUID?)async throws->EntitlementSync{requests+=1;onSync?();if let error{throw error};return result}
 func billingContext()async throws->SubscriptionBillingContext{billing} }
@MainActor final class URLSession {static let shared=URLSession();static var statuses=[200];static var requests:[URLRequest]=[];static var onResponse:(()->Void)?
 init(){};init(configuration:URLSessionConfiguration,delegate:Any?,delegateQueue:OperationQueue?){}
 func data(for request:URLRequest)async throws->(Data,URLResponse){Self.requests.append(request);Self.onResponse?();let s=Self.statuses.count>1 ? Self.statuses.removeFirst():Self.statuses[0];return(Data(),HTTPURLResponse(url:request.url!,statusCode:s,httpVersion:nil,headerFields:nil)!)} }
struct LiveAPIClient {static func serverError(status:Int,data:Data)->APIError{.server(status:status,code:nil,message:"synthetic refusal")}}
@MainActor final class AuthStore {static let shared=AuthStore();var userID:String?;var syncSessionRevision:UInt64=1;var isSignedIn=true;static var token:String?;static var onToken:(()->Void)?;var onRefresh:(()->Void)?
 static func validAccessToken()async->String?{onToken?();return token};static func storedAccessToken()->String?{token};func forceRefresh()async->Bool{onRefresh?();return true}
"""
interfaces+=block(auth,'static func jwtSubject(')+'\n}\n'
base=interfaces+block(api,'enum APIError:')+'\n'+block(b,'struct ServingActivationSummary:')+'\n'+block(a,'struct EntitlementSync:')+'\n'+block(a,'private final class TrialPurchaseRedirectPolicy:').replace('private ','',1)+'\n'+block(a,'@MainActor private enum PurchasesRequest').replace('private enum','enum')+'\n'+block(b,'enum PurchaseWorkspaceBindingStore')+'\n'
base+='enum RendpropProducts {\n'+block(products,'static func plan(for')+'\n'+block(products,'static func planName(for')+'\n}\n'
def program(source):
 result=base+block(source,'enum PurchaseFulfilmentRecovery')+'\n'+block(source,'enum PurchaseFulfilmentRefusals')+'\n'
 result+='@MainActor final class PurchaseManager {var api:FulfilmentAPI?;var lastError:String?;var notice:String?;var activePlan:String?;var activeProductID:String?;var activeExpiresAt:Date?;var unsynced:[UInt64:PendingSync]=[:];var unsyncedCount=0;var syncedThisSession:Set<String>=[];var onRenewal:(()->Void)?;func renewalInfoJWS(forProductID:String)async->String?{onRenewal?();return nil}\n'
 result+=block(source,'private struct PendingSync').replace('private ','',1)+'\n'
 for n in ['private func handle(','private func hasCurrentFulfilmentContext(','private func sync(','private func applyServerPlan(','private func remember(','private func forget(','func retryUnsynced(']:result+=block(source,n).replace('private ','',1)+'\n'
 return result+'}\n'
faults=[('actual',None,None,None),('finish-refused','if result.servingActivation?.available == false, pending.transaction.revocationDate == nil,','if false, pending.transaction.revocationDate == nil,','Unavailable activation accepted'),('auto-permanent','if automatically, PurchaseFulfilmentRefusals.blocked','if false, PurchaseFulfilmentRefusals.blocked','Permanent refusal automatically retried'),('response-context','guard hasCurrentFulfilmentContext(pending) else { return false }','guard true else { return false }','Late response finished replacement account'),('renewal-workspace','WorkspaceContext.selectedOrgID == selectedOrgID else { return false }','true else { return false }','Late response accepted'),('returned-chain','result.originalTransactionId.map({ $0 == String(pending.transaction.originalID) }) ?? true','true','Foreign returned chain accepted'),('unsupported-finish','lastError = "This build cannot fulfill','await transaction.finish()\n            lastError = "This build cannot fulfill','Unknown product discarded')]
results=[]
for name,old,new,expected in faults:
 s=m
 if old:
  if old not in s:raise RuntimeError('unapplied fault '+name)
  if name=='response-context':
   # Only the post-request boundary; the initial context guard remains intact.
   mark='let result = try await api.syncEntitlement';i=s.index(mark);s=s[:i]+s[i:].replace(old,new,1)
  else:s=s.replace(old,new)
  if name=='renewal-workspace':s=s.replace('WorkspaceContext.selectedOrgID == pending.selectedOrgID &&','true &&')
 folder=OUT/name;folder.mkdir();swift=folder/'Actual.swift';swift.write_text(program(s));binary=folder/'checks'
 c=subprocess.run(['xcrun','swiftc','-parse-as-library',str(swift),str(paths[-2]),'-o',str(binary)],capture_output=True,text=True,timeout=90);(folder/'compile.log').write_text(c.stdout+c.stderr)
 if c.returncode:raise RuntimeError('compile failure '+str(folder/'compile.log'))
 r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20);(folder/'runtime.log').write_text(r.stdout+r.stderr)
 passed=r.returncode==0 if expected is None else r.returncode!=0 and expected in r.stdout+r.stderr
 results.append({'case':name,'compileExit':c.returncode,'runtimeExit':r.returncode,'passed':passed,'expected':expected})
 if not passed:raise RuntimeError('oracle failed '+str(folder/'runtime.log'))
receipt={'passed':hashes()==start and all(x['passed']for x in results),'sourceHashes':start,'sourceUnchanged':hashes()==start,'results':results,'externalRequests':0,'AppleCalls':0,'limitations':'Actual custody/retry/request/identity bodies compiled against synthetic StoreKit, HTTP, persistence and Auth boundaries; no device or Apple outage proof.'}
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'receipt':str(OUT/'receipt.json'),'passed':receipt['passed'],'actual':(OUT/'actual/runtime.log').read_text(),'controls':len(results)-1}))
