// Actual method fixture: synthetic image/API boundaries, loopback HTTP and isolated preferences.

import Foundation
// Isolated preference domain; no application or customer preferences are touched.
enum UserDefaults { static let name = "com.rendprop.offline-reel-recovery." + UUID().uuidString; static let standard = Foundation.UserDefaults(suiteName:name)! }
enum FileStore { static let documents=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-reel-retained-"+UUID().uuidString);static func relativePath(for u:URL)->String{String(u.path.dropFirst(documents.path.count+1))};static func url(fromRelativePath p:String)->URL{documents.appendingPathComponent(p)} }
struct EnhancedPhoto { let enhancedURL:URL }
struct AIShot { let motion:String?;let room:String? }
struct UIImage { static var onPreparation:(() -> Void)?;let bytes:Data;init?(contentsOfFile:String){guard let d=try? Data(contentsOf:URL(fileURLWithPath:contentsOfFile)) else{return nil};bytes=d};func jpegData(compressionQuality:Double)->Data?{Self.onPreparation?();return bytes} }
enum AIImagePrep {static func downscaled(_ i:UIImage,maxDimension:Int)->UIImage{i};static func error(_ m:String)->Error{NSError(domain:"synthetic",code:1,userInfo:[NSLocalizedDescriptionKey:m])} }
protocol APIClient {func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob;func aiVideoStatus(_ j:AIVideoJob) async throws->AIVideoStatus}
final class ClipAPI:APIClient {
 var expectedContext:PendingReelRequest.Context?;var lastKey:String?
 var beforeReply:(() throws -> Void)?
 var posts=0,polls=0;var throwPoll=false;var throwSubmit=false;var terminal=false;var url:URL
 let job=AIVideoJob(requestId:UUID().uuidString,statusUrl:"synthetic-status",responseUrl:"synthetic-response",kind:"reel")
 init(_ u:URL){url=u}
 func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob{if let context=expectedContext {let marker=PendingReelRequest.load(context);precondition(marker?.submissionUnconfirmed==true && marker?.operationID==idempotencyKey && marker?.inputDigest?.count==64,"durable operation marker exists before POST")};lastKey=idempotencyKey;posts+=1;precondition(seconds==5&&mime=="image/jpeg");if throwSubmit{throw URLError(.networkConnectionLost)};try beforeReply?();return job}
 func aiVideoStatus(_ j:AIVideoJob) async throws->AIVideoStatus{polls+=1;precondition(j.requestId==job.requestId);if throwPoll{throw URLError(.networkConnectionLost)};return terminal ? .failed("synthetic definitive failure"):.completed(videoURL:url)}
}
@MainActor final class AIConsent {
 static let shared=AIConsent();var isGranted=true;var revocationRevision:UInt64=0
 func revokeAndGrant(){isGranted=false;revocationRevision+=1;isGranted=true}
}
@MainActor enum WorkspaceContext {static var selectedOrgID:UUID?=UUID()}
@MainActor final class AuthStore {
 static let shared=AuthStore();var userID:String?="synthetic-owner";var syncSessionRevision:UInt64=1;var isSignedIn=true
 static var tokenHook:(() -> Void)?;static var refreshHook:(() -> Void)?
 static func validAccessToken() async -> String? {await Task.yield();tokenHook?();return "closed-token"}
 func forceRefresh() async -> Bool {await Task.yield();Self.refreshHook?();return true}
 static func storedAccessToken()->String?{"closed-refreshed-token"}
 func signOut(preservingAdoption:Bool=false) async {isSignedIn=false}
}
enum Config {static let enableAuth=true}
enum AnonymousAdoptionRecovery {struct Identity {let id:UUID};static func identity(_ s:String)->Identity?{nil}}
enum CloudSyncError:Error {case identityChanged}
struct GuardListing {let id:UUID;let serverID:UUID?;var cloudUnavailable:Bool?=nil}
@MainActor final class GuardModel {var listings:[GuardListing];init(_ listing:GuardListing){listings=[listing]}}
final class ClosedVideoProtocol:URLProtocol {
 static let lock=NSLock();static var requests:[URLRequest]=[];static var statuses:[Int]=[202]
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading(){
  Self.lock.lock();Self.requests.append(request);let status=Self.statuses.removeFirst();Self.lock.unlock()
  let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
  let data=Data(#"{"request_id":"accepted","status_url":"synthetic-status","response_url":"synthetic-response","kind":"reel"}"#.utf8)
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
 static func reset(_ statuses:[Int]=[202]) {lock.lock();requests=[];Self.statuses=statuses;lock.unlock()}
}
@main struct ReceiptTests {
 @MainActor static func main() async throws {
  defer { UserDefaults.standard.removePersistentDomain(forName:UserDefaults.name) }
  var checks=0
  func check(_ v:@autoclosure()->Bool,_ m:String){precondition(v(),m);checks+=1}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("reel-receipt-\(UUID())")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  defer{try? FileManager.default.removeItem(at:FileStore.documents)}
  let input=root.appendingPathComponent("synthetic.jpg");try Data([0xff,0xd8,0xff,0xd9]).write(to:input)
  let ctx=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:"synthetic-owner",workspace:UUID())
  defer{UserDefaults.standard.removeObject(forKey:PendingReelRequest.key(ctx))}
  if !CommandLine.arguments.contains("--dispatch-only") {
   let historyID=UUID(),historyDir=PendingReelClips.directory(for:UUID())
   // Use the actual listing directory; historyDir above is an unrelated path
   // to keep accidental broad directory deletion observable.
   try FileManager.default.createDirectory(at:historyDir,withIntermediateDirectories:true)
   let dir=PendingReelClips.directory(for:historyID)
   try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
   let paid=dir.appendingPathComponent("paid.mp4")
   try Data("previous paid bytes".utf8).write(to:paid)
   PendingReelClips(listingID:historyID,savedAt:Date(),relPaths:[FileStore.relativePath(for:paid)]).save()
   let manifest=dir.appendingPathComponent("manifest.json"),originalManifest=try Data(contentsOf:dir.appendingPathComponent("manifest.json"))
   let stale=PendingReelClips(listingID:historyID,savedAt:Date(),relPaths:["missing-old-paid.mp4"])
   UserDefaults.standard.set(try JSONEncoder().encode(stale),forKey:PendingReelClips.key(historyID))
   let temp=root.appendingPathComponent("unretained",isDirectory:true)
   try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
   let incoming=temp.appendingPathComponent("new.mp4");try Data("new paid bytes".utf8).write(to:incoming)
   try FileManager.default.setAttributes([.posixPermissions:0o000],ofItemAtPath:manifest.path)
   check((try? Data(contentsOf:manifest))==nil,"fixture creates unreadable authoritative clip manifest")
   check(PendingReelClips.load(for:historyID)==nil,"unreadable clip manifest stays unavailable")
   check(FileManager.default.fileExists(atPath:paid.path),"unreadable manifest preserves previously paid clip bytes")
   do{_ = try PendingReelClips.readRecord(for:historyID);preconditionFailure("authoritative manifest failure never admits stale legacy record")}catch{checks+=1}
   do{_ = try ReelReceiptHarness.retainRecoveredClip(incoming,for:historyID);preconditionFailure("unreadable manifest must stop retention")}catch{checks+=1}
   check(FileManager.default.fileExists(atPath:incoming.path),"unreadable manifest retains the only new temporary bytes")
   ReelReceiptHarness.parkClips([incoming],for:historyID,tmpDir:temp)
   check((try? Data(contentsOf:manifest))==nil&&FileManager.default.fileExists(atPath:incoming.path),"parking preserves unreadable manifest and unretained temporary bytes")
   let historyContext=PendingReelRequest.Context(listingID:historyID,serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
   let historyAPI=ClipAPI(URL(string:CommandLine.arguments[1]+"/history")!);historyAPI.expectedContext=historyContext
   do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:historyAPI,listingServerID:historyContext.serverListingID,into:temp,index:0,recoveryContext:historyContext);preconditionFailure("unreadable history must block generation")}catch{checks+=1}
   check(historyAPI.posts==0 && !PendingReelRequest.exists(historyContext),"unreadable history prevents any new paid POST")
   try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
   let restoredManifest=try Data(contentsOf:manifest)
   check(restoredManifest==originalManifest,"unreadable history is never overwritten")
   try Data("corrupt-manifest".utf8).write(to:manifest,options:.atomic)
   do{_ = try ReelReceiptHarness.retainRecoveredClip(incoming,for:historyID);preconditionFailure("corrupt manifest must stop retention")}catch{checks+=1}
   ReelReceiptHarness.parkClips([incoming],for:historyID,tmpDir:temp)
   let corruptManifest=try Data(contentsOf:manifest)
   check(corruptManifest==Data("corrupt-manifest".utf8)&&FileManager.default.fileExists(atPath:incoming.path),"corrupt manifest and unretained bytes remain untouched")
   let preservedPaid=try Data(contentsOf:paid)
   check(preservedPaid==Data("previous paid bytes".utf8),"corrupt manifest never erases previous paid file")
   try originalManifest.write(to:manifest,options:.atomic)
   let resumed=try ReelReceiptHarness.retainRecoveredClip(incoming,for:historyID)
   check(PendingReelClips.load(for:historyID)?.clipURLs==[paid,resumed],"restored manifest resumes retention without losing prior order")
   check(FileManager.default.fileExists(atPath:historyDir.path),"history recovery never deletes an unrelated directory")
  }
  if CommandLine.arguments.contains("--manifest-only") {print("PASSED: \(checks) actual authoritative manifest assertions; synthetic filesystem only");return}
  // The actual live execute body refreshes tokens and retries a 401 once.
  // A URLProtocol intercept consumes every request before any network access.
  let live=VideoDispatchHarness()
  func resetDispatch(_ statuses:[Int]=[202]){ClosedVideoProtocol.reset(statuses);AIConsent.shared.isGranted=true;AuthStore.tokenHook=nil;AuthStore.refreshHook=nil;WorkspaceContext.selectedOrgID=ctx.workspace}
  resetDispatch();AIConsent.shared.isGranted=false
  do{_ = try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable");preconditionFailure("consent admission must reject")}catch{checks+=1}
  check(ClosedVideoProtocol.requests.isEmpty,"no permission prevents first network send")
  resetDispatch();AuthStore.tokenHook={AIConsent.shared.revokeAndGrant()}
  do{_ = try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable");preconditionFailure("token refresh revocation must reject")}catch{checks+=1}
  check(ClosedVideoProtocol.requests.isEmpty,"token refresh revocation prevents first video send")
  resetDispatch();AuthStore.tokenHook={WorkspaceContext.selectedOrgID=UUID()}
  do{_ = try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable");preconditionFailure("token refresh workspace switch must reject")}catch{checks+=1}
  check(ClosedVideoProtocol.requests.isEmpty,"token refresh workspace switch prevents first video send")
  resetDispatch([401,202]);AuthStore.refreshHook={AIConsent.shared.revokeAndGrant()}
  do{_ = try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable");preconditionFailure("401 revocation must reject retry")}catch{checks+=1}
  check(ClosedVideoProtocol.requests.count==1,"401 refresh revocation prevents a second video send")
  resetDispatch([401,202]);AuthStore.refreshHook={WorkspaceContext.selectedOrgID=nil}
  do{_ = try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable");preconditionFailure("401 workspace switch must reject retry")}catch{checks+=1}
  check(ClosedVideoProtocol.requests.count==1,"401 refresh workspace switch prevents a second video send")
  resetDispatch([401,202])
  let receipt=try await live.submitAIVideo(path:"reel-clip",body:[:],fallbackKind:"reel",idempotencyKey:"stable")
  check(receipt.requestId=="accepted"&&ClosedVideoProtocol.requests.count==2,"unchanged context decodes accepted receipt after one authorized 401 retry")
  check(ClosedVideoProtocol.requests.allSatisfy{$0.value(forHTTPHeaderField:"X-Org-Id")==ctx.workspace!.uuidString.lowercased()},"both authorized sends carry exact captured workspace")
  check(ClosedVideoProtocol.requests.allSatisfy{$0.value(forHTTPHeaderField:"Idempotency-Key")=="stable"},"authorized 401 retry keeps original operation identity")
  resetDispatch();_ = try await live.submitAIVideo(path:"declutter",body:[:],fallbackKind:"declutter",idempotencyKey:"bria-stable")
#if SPATIAL_CAPTURE_LAB
  check(ClosedVideoProtocol.requests.first?.value(forHTTPHeaderField:"x-rendprop-ai-consent")=="bria-video-v1","internal lab submission keeps explicit Bria consent header")
#else
  check(ClosedVideoProtocol.requests.first?.value(forHTTPHeaderField:"x-rendprop-ai-consent")==nil,"normal release never invents lab consent header")
#endif
  if CommandLine.arguments.contains("--dispatch-only") { print("PASSED: \(checks) actual live video dispatch assertions; closed URLProtocol, no network"); return }
  let clip=ClipAPI(URL(string:CommandLine.arguments[1]+"/recover")!);clip.expectedContext=ctx;clip.throwPoll=true
  // Execute the actual captured Reel Studio guard after synthetic preparation.
  let auth=AuthStore.shared;WorkspaceContext.selectedOrgID=ctx.workspace
  let model=GuardModel(.init(id:ctx.listingID,serverID:ctx.serverListingID))
  let dispatchGuard=ReelReceiptHarness.generationGuard(auth:auth,model:model,listingID:ctx.listingID,targetServerID:ctx.serverListingID)
  UIImage.onPreparation={DispatchQueue.main.sync {MainActor.assumeIsolated {AIConsent.shared.revokeAndGrant()}}}
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx,requireCurrent:dispatchGuard);preconditionFailure("preparation revocation must reject paid dispatch")}catch{checks+=1}
  UIImage.onPreparation=nil
  check(clip.posts==0 && !PendingReelRequest.exists(ctx),"revocation during preparation permits no paid POST")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("poll failure must surface")}catch{checks+=1}
  check(clip.posts==1&&clip.polls==1,"one accepted submit and one failed poll")
  check(PendingReelRequest.load(ctx)?.job.requestId==clip.job.requestId,"pending receipt after poll failure")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:ctx.serverListingID,owner:"other-owner",workspace:ctx.workspace))==nil,"receipt hidden from other account")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:ctx.serverListingID,owner:ctx.owner,workspace:UUID()))==nil,"receipt hidden from other workspace")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace))==nil,"receipt refuses changed server binding")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("existing receipt blocks second POST")}catch{checks+=1}
  check(clip.posts==1&&clip.polls==1,"existing receipt blocks second POST")
  clip.throwPoll=false
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0);preconditionFailure("HTTP500 surfaced")}catch{checks+=1}
  check(PendingReelRequest.load(ctx) != nil&&clip.posts==1,"HTTP500 preserves receipt without submitting")
  let result=try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0)
  let resultBytes=try Data(contentsOf:result)
  check(resultBytes==Data("synthetic nonempty retained clip".utf8),"recover saves exact downloaded clip bytes")
  check(clip.posts==1&&clip.polls==3,"recovery only polls same accepted request")
  check(PendingReelRequest.load(ctx) != nil,"temporary successful download keeps request")
  let old=PendingReelRequest(context:ctx,photoNumber:1,job:clip.job);try old.save()
  let newer=PendingReelRequest(context:ctx,photoNumber:2,job:.init(requestId:"newer",statusUrl:"s",responseUrl:"r",kind:"reel"));try newer.save();old.clear()
  check(PendingReelRequest.load(ctx)?.job.requestId=="newer","late completion cannot clear new receipt")
  newer.clear();try old.save();clip.terminal=true
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0);preconditionFailure("terminal failure surfaced")}catch{checks+=1}
  check(PendingReelRequest.load(ctx)==nil,"definitive refusal retires receipt")
  try old.save();let polls=clip.polls
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0,requireCurrent:{throw CancellationError()});preconditionFailure("stale context refuses")}catch{checks+=1}
  check(clip.polls==polls&&clip.posts==1,"stale identity refuses before status/network dispatch")
  check(PendingReelRequest.load(ctx) != nil,"identity interruption keeps scoped recovery receipt")
  old.clear();let bad=PendingReelRequest(context:ctx,photoNumber:9,job:clip.job);try bad.save()
  check(PendingReelRequest.load(ctx)==nil,"invalid photo receipt cannot resume")
  try Data("broken".utf8).write(to:PendingReelRequest.file(ctx),options:.atomic)
  check(PendingReelRequest.exists(ctx)&&PendingReelRequest.load(ctx)==nil,"corrupt receipt fails closed")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("unreadable receipt blocks another POST")}catch{checks+=1}
  check(clip.posts==1,"unreadable receipt blocks another POST")
  // A finished download is still temporary. Keep the receipt until durable
  // retention succeeds, and retry only this accepted job after a disk failure.
  try old.save();clip.terminal=false
  let recoveryDir=root.appendingPathComponent("recovery",isDirectory:true)
  try FileManager.default.createDirectory(at:recoveryDir,withIntermediateDirectories:true)
  let downloaded=try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:recoveryDir,index:0,clearReceiptOnDownload:false)
  check(PendingReelRequest.load(ctx) != nil,"successful temporary download keeps recovery receipt")
  let parkedDir=PendingReelClips.directory(for:ctx.listingID)
  try FileManager.default.createDirectory(at:parkedDir.deletingLastPathComponent(),withIntermediateDirectories:true)
  let blocker=URL(fileURLWithPath:parkedDir.path)
  try Data("synthetic filesystem blocker".utf8).write(to:blocker)
  do{_ = try ReelReceiptHarness.retainRecoveredClip(downloaded,for:ctx.listingID);preconditionFailure("retention blocker must surface")}catch{checks+=1}
  check(PendingReelRequest.load(ctx) != nil&&clip.posts==1,"retention failure keeps accepted receipt without another POST")
  check(FileManager.default.fileExists(atPath:downloaded.path),"throwing retention does not silently erase temporary paid clip")
  try FileManager.default.removeItem(at:blocker)
  try FileManager.default.createDirectory(at:parkedDir,withIntermediateDirectories:true)
  let earlier1=parkedDir.appendingPathComponent("earlier1.mp4"),earlier2=parkedDir.appendingPathComponent("earlier2.mp4")
  try Data("old-one".utf8).write(to:earlier1);try Data("old-two".utf8).write(to:earlier2)
  PendingReelClips(listingID:ctx.listingID,savedAt:Date(),relPaths:[FileStore.relativePath(for:earlier1),FileStore.relativePath(for:earlier2)]).save()
  try FileManager.default.removeItem(at:recoveryDir)
  try FileManager.default.createDirectory(at:recoveryDir,withIntermediateDirectories:true)
  let redownload=try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:recoveryDir,index:0,clearReceiptOnDownload:false)
  let retained=try ReelReceiptHarness.retainRecoveredClip(redownload,for:ctx.listingID)
  check(PendingReelClips.load(for:ctx.listingID)?.clipURLs == [earlier1,earlier2,retained],"recovered clip appended without changing earlier paid order")
  let priorBytes1=try Data(contentsOf:earlier1),priorBytes2=try Data(contentsOf:earlier2),retainedBytes=try Data(contentsOf:retained)
  check(priorBytes1==Data("old-one".utf8)&&priorBytes2==Data("old-two".utf8),"recovery never replaces earlier paid bytes")
  check(retainedBytes==resultBytes,"durably retained recovery bytes match the downloaded result")
  check(clip.posts==1,"storage recovery uses no second generation")
  check(PendingReelRequest.load(ctx) != nil,"retention helper does not acknowledge another actor's request")
  old.clear()
  check(PendingReelRequest.load(ctx)==nil,"receipt retires after durable recovery acceptance")
  // Existing legacy records can migrate, but an unreadable authoritative file
  // must never resurrect an older accepted job or erase an unknown operation.
  UserDefaults.standard.set(try JSONEncoder().encode(old),forKey:PendingReelRequest.key(ctx))
  check(PendingReelRequest.load(ctx)?.job.requestId==old.job.requestId,"legacy receipt remains readable before file migration")
  let unconfirmed=PendingReelRequest(context:ctx,photoNumber:1,job:.init(requestId:"new-unknown",statusUrl:"",responseUrl:"",kind:"reel"),operationID:"new-unknown",inputDigest:String(repeating:"a",count:64),submissionUnconfirmed:true)
  try unconfirmed.save()
  check(UserDefaults.standard.data(forKey:PendingReelRequest.key(ctx))==nil,"verified file migration removes obsolete legacy receipt")
  UserDefaults.standard.set(try JSONEncoder().encode(old),forKey:PendingReelRequest.key(ctx))
  let authoritative=PendingReelRequest.file(ctx)
  try FileManager.default.setAttributes([.posixPermissions:0o000],ofItemAtPath:authoritative.path)
  check((try? Data(contentsOf:authoritative))==nil,"fixture creates a genuinely unreadable authoritative marker")
  check(PendingReelRequest.exists(ctx)&&PendingReelRequest.load(ctx)==nil,"unreadable authoritative marker never falls back to stale legacy receipt")
  old.clear()
  check(PendingReelRequest.exists(ctx),"old receipt cannot clear unreadable newer operation marker")
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:authoritative.path)
  check(PendingReelRequest.load(ctx)?.submissionUnconfirmed==true,"restored access retains newer unconfirmed operation")
  PendingReelRequest.forget(ctx)
  PendingReelClips.retire([retained],for:ctx.listingID)
  check(PendingReelClips.load(for:ctx.listingID)?.clipURLs == [earlier1,earlier2],"finished run retires only its copies and preserves earlier order")
  let normal=try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:clip,listingServerID:ctx.serverListingID,into:recoveryDir,index:0,recoveryContext:ctx)
  check(normal.deletingLastPathComponent().standardizedFileURL == parkedDir.standardizedFileURL,"ordinary accepted clip returns durable storage rather than temporary file")
  check(PendingReelRequest.load(ctx)==nil && PendingReelClips.load(for:ctx.listingID)?.clipURLs.contains(normal)==true,"ordinary receipt retires only after verified metadata and bytes")
  // Lost POST response cannot be replayed by this server. Retain a durable
  // operation marker, prohibit both new submission and bogus GET recovery.
  let unknownContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let unknownAPI=ClipAPI(clip.url);unknownAPI.expectedContext=unknownContext;unknownAPI.throwSubmit=true
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"unknown outcome",shot:nil,shotCount:1,api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("unknown submission must surface")}catch{checks+=1}
  let marker=PendingReelRequest.load(unknownContext)!
  check(marker.submissionUnconfirmed==true&&marker.operationID==unknownAPI.lastKey&&marker.inputDigest?.count==64,"unknown response retains exact durable operation identity")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"different input",shot:nil,shotCount:1,api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("unknown operation blocks fresh submission")}catch{checks+=1}
  check(unknownAPI.posts==1&&unknownAPI.polls==0,"unknown operation blocks fresh submission")
  do{_ = try await ReelReceiptHarness.retrieveClip(job:marker.job,pending:marker,api:unknownAPI,into:root,index:0);preconditionFailure("unknown operation has no recoverable receipt")}catch{checks+=1}
  check(unknownAPI.polls==0,"unconfirmed operation cannot poll a fabricated job")
  PendingReelRequest.forget(unknownContext)
  check(!PendingReelRequest.exists(unknownContext),"explicit forget retires unknown marker")
  // Actual filesystem blocker prevents a first POST, rather than hoping a
  // record can be persisted after accepting a charged job.
  let requestDirectory=PendingReelRequest.file(ctx).deletingLastPathComponent()
  let preserved=requestDirectory.deletingLastPathComponent().appendingPathComponent("requests-preserved")
  try FileManager.default.moveItem(at:requestDirectory,to:preserved)
  try Data("synthetic request-directory blocker".utf8).write(to:requestDirectory)
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("pre-dispatch storage must succeed")}catch{checks+=1}
  check(unknownAPI.posts==1,"pre-dispatch disk blocker permits no paid POST")
  try FileManager.default.removeItem(at:requestDirectory)
  try FileManager.default.moveItem(at:preserved,to:requestDirectory)
  let attachContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let attachAPI=ClipAPI(clip.url);attachAPI.expectedContext=attachContext
  attachAPI.beforeReply={try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:requestDirectory.path)}
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:attachAPI,listingServerID:attachContext.serverListingID,into:root,index:0,recoveryContext:attachContext);preconditionFailure("accepted attachment storage failure must surface")}catch{checks+=1}
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:requestDirectory.path)
  check(attachAPI.posts==1&&attachAPI.polls==0&&PendingReelRequest.load(attachContext)?.submissionUnconfirmed==true,"accepted receipt save failure retains unconfirmed durable marker")
  // Normal Generate obeys the same durable-retention rule as Recover.
  let blockedContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let blockedAPI=ClipAPI(clip.url);blockedAPI.expectedContext=blockedContext
  let blockedParked=PendingReelClips.directory(for:blockedContext.listingID)
  try Data("synthetic parked-directory blocker".utf8).write(to:blockedParked)
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,api:blockedAPI,listingServerID:blockedContext.serverListingID,into:root,index:0,recoveryContext:blockedContext);preconditionFailure("ordinary retention blocker must surface")}catch{checks+=1}
  check(blockedAPI.posts==1&&PendingReelRequest.load(blockedContext)?.job.requestId==blockedAPI.job.requestId,"ordinary retention failure keeps accepted receipt")
  try FileManager.default.removeItem(at:blockedParked)
  let accepted=PendingReelRequest.load(blockedContext)!
  let blockedRetry=try await ReelReceiptHarness.retrieveClip(job:accepted.job,pending:accepted,api:blockedAPI,into:root,index:0)
  let durablyRecovered=try ReelReceiptHarness.retainRecoveredClip(blockedRetry,for:blockedContext.listingID)
  accepted.clear()
  check(blockedAPI.posts==1&&PendingReelRequest.load(blockedContext)==nil,"ordinary disk retry recovers same accepted job with no second POST")
  check(FileManager.default.fileExists(atPath:durablyRecovered.path)&&FileManager.default.fileExists(atPath:blockedParked.appendingPathComponent("manifest.json").path),"acknowledged clip has retained bytes and atomic manifest")
  let recorded=PendingReelClips.load(for:blockedContext.listingID)!.relPaths
  ReelReceiptHarness.parkClips([durablyRecovered],for:blockedContext.listingID,tmpDir:recoveryDir)
  check(PendingReelClips.load(for:blockedContext.listingID)?.relPaths==recorded&&FileManager.default.fileExists(atPath:durablyRecovered.path),"normal batch parking does not move or duplicate durably retained clips")
  print("PASSED: \(checks) actual receipt/makeClip/retrieveClip assertions; HTTP loopback only, image preparation and API boundary doubled")
 }
}
