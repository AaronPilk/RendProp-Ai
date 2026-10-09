#!/usr/bin/env python3
"""Actual directory/store/billing sources against closed synthetic boundaries."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path);args=p.parse_args()
out=args.out or Path(tempfile.mkdtemp(prefix='private-library-context-'));out.mkdir(parents=True,exist_ok=True)
paths=[ROOT/'apps/ios/Rendprop'/name for name in ['Workspace/WorkspaceContext.swift','Workspace/WorkspaceStore.swift','Purchases/SubscriptionBillingContext.swift','Models/Money.swift','Team/TeamAPI.swift']]
paths += [ROOT/'apps/ios/tests/PrivateLibraryContextTests.swift',Path(__file__).resolve()]
hashes=lambda:{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths};start=hashes()
context,store,billing,money,team=[p.read_text()for p in paths[:5]]
stub=r'''
import Foundation
final class UserDefaults { static let standard=UserDefaults();var values:[String:Any]=[:]
 func string(forKey key:String)->String?{values[key]as?String};func data(forKey key:String)->Data?{values[key]as?Data}
 func set(_ value:Any,forKey key:String){values[key]=value};func removeObject(forKey key:String){values.removeValue(forKey:key)};func synchronize()->Bool{true}}
enum Config {static let useLiveBackend=true;static let apiBaseURL:URL?=URL(string:"https://fixture.invalid/functions/v1");static let supabaseAnonKey="synthetic-public"}
enum CloudSyncError:Error{case identityChanged,invalidResponse}
enum APIError:Error{case notConfigured,badResponse(Int),decoding,server(status:Int,code:String?,message:String)}
enum LiveAPIClient{static func serverError(status:Int,data:Data)->Error{APIError.badResponse(status)}}
enum UserFacingError{static func message(_ error:Error,fallback:String)->String{fallback}}
extension Notification.Name{static let rendpropPlanChanged=Notification.Name("fixture.plan")}
@MainActor final class AuthStore{static let shared=AuthStore();var userID:String?;var syncSessionRevision:UInt64=1;var orgName=""
 static func validAccessToken()async->String?{"synthetic-bearer"};func workspaceDidChange(){syncSessionRevision+=1}}
@MainActor final class URLSession{static let shared=URLSession();static var fixture=Data();static var status=200;static var requests:[URLRequest]=[];static var onResponse:(()->Void)?
 func data(for request:URLRequest)async throws->(Data,URLResponse){Self.requests.append(request);Self.onResponse?();return(Self.fixture,HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!)}}
'''
faults=[('actual',None,None,None),('actor','actorID == actor,','true,','Foreign directory actor accepted'),('delegation','return canSwitchAgentLibraries && member.accessMode','return member.accessMode','Sibling access accepted without capability'),('cache-selection','$0.activeOrgID == value.selectedOrgID','true','Snapshot and active directory disagreement accepted'),('purchase-content','(value.contentOrgID ?? value.orgID) == selectedOrg','true','Foreign financial binding accepted'),('serving','(value.servingOrgID ?? value.orgID) == (servingOrg ?? billingOrg ?? selectedOrg)','true','Foreign financial binding accepted'),('purchase-snapshot','lhs.org == rhs.org','true','Changed purchase scope accepted'),('team-actor','result.actorId == actor','true','Foreign Team summary accepted'),('entry-capability','if canSwitch && choices > 1','if choices > 1','Ordinary recovery opened agent switcher'),('authority-refusal','if Self.isAuthorityFailure(error) { invalidateAuthority(owner: owner) }','if false { invalidateAuthority(owner: owner) }','Authority refusal retained delegation')]
results=[]
for name,old,new,expected in faults:
 body=stub+context+store+billing+money+team
 if old:
  if old not in body:raise RuntimeError('Missing negative-control anchor '+name)
  body=body.replace(old,new)
 folder=out/name;folder.mkdir(exist_ok=True);src=folder/'Actual.swift';src.write_text(body);binary=folder/'checks'
 c=subprocess.run(['xcrun','swiftc','-parse-as-library',str(src),str(paths[5]),'-o',str(binary)],capture_output=True,text=True,timeout=90);(folder/'compile.log').write_text(c.stdout+c.stderr)
 if c.returncode:raise RuntimeError('Compile failed '+str(folder/'compile.log'))
 r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=15);(folder/'runtime.log').write_text(r.stdout+r.stderr)
 passed=r.returncode==0 if expected is None else r.returncode!=0 and expected in r.stdout+r.stderr
 results.append({'case':name,'compileExit':c.returncode,'runtimeExit':r.returncode,'passed':passed})
 if not passed:raise RuntimeError('Oracle failed '+str(folder/'runtime.log'))
receipt={'passed':hashes()==start and all(x['passed']for x in results),'sourceHashes':start,'sourceUnchanged':hashes()==start,'results':results,'externalRequests':0,'limitations':'Actual pure models and store against synthetic session/HTTP/preferences; no SDK, camera, production or Apple transaction proof.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'receipt':str(out/'receipt.json'),'passed':receipt['passed'],'actual':(out/'actual/runtime.log').read_text(),'controls':len(results)-1}))
