#!/usr/bin/env python3
"""Execute actual URL preflight, API adapters and import callbacks with closed network/file boundaries."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile
root=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path);args=parser.parse_args()
out=args.out or Path(tempfile.mkdtemp(prefix='rendprop-native-private-media-'));out.mkdir(parents=True,exist_ok=True)
paths=[root/'apps/ios/Rendprop/Networking/WorkspaceSync.swift',root/'apps/ios/Rendprop/Networking/LiveAPIClient.swift',root/'apps/ios/Rendprop/Screens/CloudMediaView.swift',Path(__file__).resolve(),root/'apps/ios/tests/PrivateMediaGatewayTests.swift']
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths};start=hashes();wire,api,view=[p.read_text()for p in paths[:3]]
def block(s,a):
 b=s.index(a);o=s.index('{',b);depth=1;e=o+1
 while depth:depth+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[b:e]
interfaces=r'''
import Foundation
@MainActor final class AuthStore {static let shared=AuthStore();var userID:String?;var syncSessionRevision:UInt64=1;var isIdentified=true}
enum WorkspaceContext {static var selectedOrgID:UUID?}
struct Listing {var id:UUID;var serverID:UUID?;var serverOrgID:UUID?;var cloudUnavailable:Bool?;var mainPhotoURL:URL?;var mainPhotoRelPath:String?}
struct RoomTag {let name:String;let tMs:Int}
struct Asset {var roomTags:[RoomTag]=[]}
struct Chapter {let asset_id:UUID;let sort:Int;let label:String;let t_ms:Int}
@MainActor final class Model {var listings:[Listing]=[];var assets:[UUID:Asset]=[:];func modify(_ id:UUID,sync:Bool,_ change:(inout Listing)->Void){if let i=listings.firstIndex(where:{$0.id==id}){change(&listings[i])}}}
@MainActor enum FileStore {static var importsDir=FileManager.default.temporaryDirectory.appendingPathComponent("rendprop-private-fixture-"+UUID().uuidString);static func relativePath(for u:URL)->String{u.path}}
@MainActor enum EnhancedPhoto {static func directory(for id:UUID)->URL{FileStore.importsDir.appendingPathComponent(id.uuidString)}}
@MainActor enum PhotoVersionHistory {struct Cover {let imageFile:String};static var saves=0;static func registerImport(id:String,imageFile:String,originalFile:String,staged:Bool,altered:Bool,directory:URL)throws{saves+=1};static func availableCoverVersion(directory:URL)throws->Cover?{nil}}
@MainActor final class CloudPhotoReferences {static let shared=CloudPhotoReferences();var onSave:(()async->Void)?;func save(sourceID:UUID,fileURL:URL,ownerID:UUID,orgID:UUID,listingID:UUID)async throws{await onSave?()}}
@MainActor enum MediaImporter {static var onMake:(()async->Void)?;static func makeAsset(from:URL,isDrone:Bool?)async throws->Asset{await onMake?();return Asset()}}
@MainActor enum CloudVoiceStore {static var saves=0;static func saveVoice(_ v:CloudCreative.Result,file:URL,ext:String,listingID:UUID)throws{saves+=1}}
@MainActor enum CloudFileDownload {enum Kind {case photo,video,audio};struct File {let url:URL;let ext:String};static var requests:[URL]=[];static var onFetch:(()async->Void)?
 static func fetch(_ url:URL,kind:Kind)async throws->File{requests.append(url);await onFetch?();let p=FileStore.importsDir.appendingPathComponent(UUID().uuidString+".tmp");try Data("synthetic".utf8).write(to:p);return File(url:p,ext:kind == .audio ? "mp3":"jpg")}}
final class LiveFixture {var responses:[Data]=[];var requests:[URLRequest]=[];var beforeDispatch:(()->Void)?;var afterResponse:(()->Void)?
 func url(_ p:[String],query:[URLQueryItem]=[])->URL{var c=URLComponents(string:"https://synthetic.invalid/"+p.joined(separator:"/"))!;c.queryItems=query.isEmpty ? nil:query;return c.url!}
 func makeRequest(url:URL)->URLRequest{URLRequest(url:url)}
 __EXECUTE_ACTOR__ func execute(_ req:URLRequest,beforeSend:__BEFORE_SEND_TYPE__=nil)async throws->Data{beforeDispatch?();try beforeSend?();requests.append(req);let d=responses.removeFirst();afterResponse?();return d}
 func decodeExact<T:Decodable>(_ data:Data)throws->T{try JSONDecoder().decode(T.self,from:data)}
'''
# Keep actual nonisolated async callers and the production transport callback's
# actor contract. A globally isolated fixture previously hid an SDK compile
# error when these request fences were inferred as nonisolated closures.
execute_declaration=api[api.index('    @MainActor private func execute('):].split('{',1)[0]
execute_actor=execute_declaration.split(' private func execute(',1)[0].strip()
before_send_type=execute_declaration.split('beforeSend: ',1)[1].split(' = nil',1)[0]
base=interfaces.replace('__EXECUTE_ACTOR__',execute_actor).replace('__BEFORE_SEND_TYPE__',before_send_type)
base+=block(api,'    func cloudMedia(listingID:')+'\n'+block(api,'    func cloudCreative(listingID:')+'\n}\n'
base+=block(wire,'struct CloudMediaAccessContext:')+'\n'+block(wire,'struct CloudCreative {')+'\n'+block(wire,'struct CloudMediaPage:')+'\n'+block(wire,'enum CloudSyncError:')+'\n'
base+='enum CloudListingMerge {\n'+block(wire,'static func date(')+'\n'+block(wire,'static func validateMedia(')+'\n}\n'
base+='@MainActor final class ImportFixture {let auth=AuthStore.shared;let model=Model();var current:Listing;var mediaContext:String?;var importGeneration=UUID();var importing:UUID?;var error:String?;var notice:String?;var importTask:Task<Void,Never>?;var imported=Set<UUID>();var chapters:[Chapter]=[];init(_ l:Listing){current=l;model.listings=[l]}\n'
for a in ['private func context(','@MainActor private func hasCurrentMediaContext(','@MainActor private func importPhoto(','@MainActor private func importVideo(','@MainActor private func importVoice(']:base+=block(view,a).replace('private ','',1)+'\n'
base+='}\n'
faults=[('actual',None,None,None),('url-actor','actorID == nil || actorID == actor','true','Foreign gateway actor accepted'),('url-org','UUID(uuidString: orgRaw) == orgID, orgRaw == orgID.uuidString.lowercased()','UUID(uuidString: orgRaw) != nil','Foreign gateway org accepted'),('url-listing','UUID(uuidString: listing) == listingID, listing == listingID.uuidString.lowercased()','UUID(uuidString: listing) != nil','Foreign gateway listing accepted'),('review-revision','revision.doubleValue > 0','revision.doubleValue >= 0','Zero review revision accepted'),('api-actor','actorID: context.actorID','actorID: nil','API accepted foreign actor'),('context-org','WorkspaceContext.selectedOrgID == orgID else','true else','Changed media context accepted'),('context-revision','AuthStore.shared.syncSessionRevision == revision','true','Changed media context accepted'),('callback-fence','(try? captured.check()) != nil && mediaContext == context(org: captured.orgID, listingID: listingID) &&','true &&','Stale import workspace committed')]
results=[]
for name,old,new,expected in faults:
 s=base if old is None else base.replace(old,new)
 if old is not None and s==base:raise RuntimeError('Missing source fault '+name)
 f=out/(name+'.swift');f.write_text(s);binary=out/name
 c=subprocess.run(['xcrun','swiftc','-parse-as-library',str(f),str(paths[-1]),'-o',str(binary)],capture_output=True,text=True,timeout=90);(out/(name+'-compile.log')).write_text(c.stdout+c.stderr)
 if c.returncode:raise RuntimeError(name+' did not compile: '+c.stderr[-3000:])
 run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=20);log=run.stdout+run.stderr;(out/(name+'.log')).write_text(log)
 if expected is None:
  if run.returncode:raise RuntimeError(log[-4000:])
 elif run.returncode==0 or 'FAILED: '+expected not in log:raise RuntimeError(name+' missed exact runtime oracle: '+log[-4000:])
 results.append({'case':name,'compileExit':c.returncode,'runtimeExit':run.returncode,'expectedFailure':expected,'compiledSourceSHA256':hashlib.sha256(s.encode()).hexdigest()})
end=hashes()
if start!=end:raise RuntimeError('Source changed during run')
receipt={'passed':True,'sourceHashes':start,'sourceUnchanged':True,'results':results,'externalNetworkRequests':0,'gatewayHMACVerifiedClientside':False,'limitations':['Actual production parsing/API adapter/import callbacks execute against closed Auth, HTTP and media boundaries.','No real gateway, R2, camera, provider, device or Photos writes; full iOS SDK compile and hosted gateway acceptance are separate.']}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'passed':True,'runs':len(results),'receipt':str(out/'receipt.json')}))
