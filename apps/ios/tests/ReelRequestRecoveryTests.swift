// Actual method fixture: synthetic image/API boundaries, loopback HTTP and isolated preferences.

import Foundation
// Isolated preference domain; no application or customer preferences are touched.
enum UserDefaults { static let name = "com.rendprop.offline-reel-recovery." + UUID().uuidString; static let standard = Foundation.UserDefaults(suiteName:name)! }
enum FileStore { static let documents=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-reel-retained-"+UUID().uuidString);static func relativePath(for u:URL)->String{String(u.path.dropFirst(documents.path.count+1))};static func url(fromRelativePath p:String)->URL{documents.appendingPathComponent(p)} }
// Only elapsed wall time and fixed polling pauses are closed boundaries. The
// production decision/body runs unchanged against this deterministic clock.
enum ReelPollClock {
 static var elapsed:TimeInterval=0;static var pauseAdvance:TimeInterval=5
 static func now()->Date {Date(timeIntervalSince1970:1_790_000_000+elapsed)}
 static func pause(nanoseconds:UInt64) async throws {precondition(nanoseconds==5_000_000_000);try Task.checkCancellation();elapsed+=pauseAdvance;await Task.yield()}
 static func reset(){elapsed=0;pauseAdvance=5}
}
struct DriftVerdict {let mayUse:Bool;let refusal:String}
struct DriftCheckRequest {let requestID:String;let kind:String;let sourceBase64:String;let frames:[(at:String,jpeg:Data)];let seconds:Int?;let spaceType:String;let listingServerID:UUID?}
enum ClipFrames {static var lastURL:URL?;static var answerNoFrames=false;static func extract(from u:URL) async -> [(at:String,jpeg:Data)] { lastURL=u;if answerNoFrames{return []};return ["first","middle","last"].map { ($0, Data("frame".utf8)) } } }
struct EnhancedPhoto { let enhancedURL:URL }
struct AIShot { let motion:String?;let room:String? }
struct UIImage { static var onPreparation:(() -> Void)?;let bytes:Data;init?(contentsOfFile:String){guard let d=try? Data(contentsOf:URL(fileURLWithPath:contentsOfFile)) else{return nil};bytes=d};func jpegData(compressionQuality:Double)->Data?{Self.onPreparation?();return bytes} }
enum AIImagePrep {static func downscaled(_ i:UIImage,maxDimension:Int)->UIImage{i};static func reelSource(_ i:UIImage,aspect:String)->UIImage{i};static func error(_ m:String)->Error{NSError(domain:"synthetic",code:1,userInfo:[NSLocalizedDescriptionKey:m])} }
protocol APIClient {func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,aspect:String?,presetVersion:Int?,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob;func aiVideoStatus(_ j:AIVideoJob) async throws->AIVideoStatus;func aiVideoDrift(_ r:DriftCheckRequest) async throws->DriftVerdict}
final class ClipAPI:APIClient {
 var expectedContext:PendingReelRequest.Context?;var lastKey:String?
 var beforeReply:(() throws -> Void)?;var onPoll:(()->Void)?;var pollOutcomes:[Result<AIVideoStatus,Error>]=[]
 var rejectsDrift=false;var unavailableDrift=false;var checksDrift=0;var posts=0,polls=0;var throwPolls=0;var throwSubmit=false;var refuseSubmit=false;var refusalStatus=400;var terminal=false;var url:URL
 let job=AIVideoJob(requestId:UUID().uuidString,statusUrl:"synthetic-status",responseUrl:"synthetic-response",kind:"reel")
 init(_ u:URL){url=u}
 func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,aspect:String?,presetVersion:Int?,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob{if let context=expectedContext {let marker=PendingReelRequest.load(context);precondition(marker?.submissionUnconfirmed==true && marker?.operationID==idempotencyKey && marker?.inputDigest?.count==64,"durable operation marker exists before POST")};lastKey=idempotencyKey;posts+=1;precondition(seconds==5&&mime=="image/jpeg"&&aspect=="9:16"&&presetVersion==1&&motion=="fly_through"&&prompt==nil);if throwSubmit{throw URLError(.networkConnectionLost)};if refuseSubmit{throw APIError.server(status:refusalStatus,code:refusalStatus == 409 ? "conflict" : "validation",message:refusalStatus == 409 ? "Duplicate submission — this job was already started." : "Unsupported video accounting metadata")};try beforeReply?();return job}
 func aiVideoDrift(_ r:DriftCheckRequest) async throws->DriftVerdict { checksDrift+=1;precondition(!r.frames.isEmpty,"a clip this phone cannot read is held locally without a drift call");precondition(!r.sourceBase64.isEmpty && r.frames.count==3 && r.requestID==job.requestId);if unavailableDrift { throw URLError(.timedOut) };return DriftVerdict(mayUse:!rejectsDrift,refusal:"Property changed; held.") }
 func aiVideoStatus(_ j:AIVideoJob) async throws->AIVideoStatus{polls+=1;precondition(j.requestId==job.requestId);onPoll?();if !pollOutcomes.isEmpty{return try pollOutcomes.removeFirst().get()};if throwPolls>0{throwPolls-=1;throw URLError(.networkConnectionLost)};return terminal ? .failed("synthetic definitive failure"):.completed(videoURL:url)}
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
   do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:historyAPI,listingServerID:historyContext.serverListingID,into:temp,index:0,recoveryContext:historyContext);preconditionFailure("unreadable history must block generation")}catch{checks+=1}
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
  let clip=ClipAPI(URL(string:CommandLine.arguments[1]+"/recover")!);clip.expectedContext=ctx;clip.throwPolls=99
  // Execute the actual captured Reel Studio guard after synthetic preparation.
  let auth=AuthStore.shared;WorkspaceContext.selectedOrgID=ctx.workspace
  let model=GuardModel(.init(id:ctx.listingID,serverID:ctx.serverListingID))
  let dispatchGuard=ReelReceiptHarness.generationGuard(auth:auth,model:model,listingID:ctx.listingID,targetServerID:ctx.serverListingID)
  UIImage.onPreparation={DispatchQueue.main.sync {MainActor.assumeIsolated {AIConsent.shared.revokeAndGrant()}}}
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx,requireCurrent:dispatchGuard);preconditionFailure("preparation revocation must reject paid dispatch")}catch{checks+=1}
  UIImage.onPreparation=nil
  check(clip.posts==0 && !PendingReelRequest.exists(ctx),"revocation during preparation permits no paid POST")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("poll failure must surface")}catch{checks+=1}
  let staysDownPolls=clip.polls
  check(clip.posts==1&&staysDownPolls>=1&&clip.throwPolls==99-staysDownPolls,"one accepted submit; every poll while the connection stayed down was a status poll")
  check(PendingReelRequest.load(ctx)?.job.requestId==clip.job.requestId,"pending receipt after poll failure")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:ctx.serverListingID,owner:"other-owner",workspace:ctx.workspace))==nil,"receipt hidden from other account")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:ctx.serverListingID,owner:ctx.owner,workspace:UUID()))==nil,"receipt hidden from other workspace")
  check(PendingReelRequest.load(.init(listingID:ctx.listingID,serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace))==nil,"receipt refuses changed server binding")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("existing receipt blocks second POST")}catch{checks+=1}
  check(clip.posts==1&&clip.polls==staysDownPolls,"existing receipt blocks second POST")
  clip.throwPolls=0
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0);preconditionFailure("HTTP500 surfaced")}catch{checks+=1}
  check(PendingReelRequest.load(ctx) != nil&&clip.posts==1,"HTTP500 preserves receipt without submitting")
  clip.rejectsDrift=true
  do { _ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0);preconditionFailure("changed property must not be retained") } catch {checks+=1}
  check(PendingReelRequest.load(ctx) != nil && clip.posts==1,"QC refusal keeps the paid receipt without a generation retry")
  check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("clip-0.mp4").path),"QC failure leaves no unchecked clip")
  clip.rejectsDrift=false;clip.unavailableDrift=true
  do { _ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0);preconditionFailure("unavailable check must hold") } catch {checks+=1}
  check(PendingReelRequest.load(ctx) != nil && clip.posts==1,"unavailable QC holds accepted receipt")
  clip.unavailableDrift=false
  // Readability is independently tested on the simulator. Here the closed
  // decoder deliberately returns no frames regardless of the media suffix.
  ClipFrames.answerNoFrames=true
  do { _ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0);preconditionFailure("an unreadable clip must be held") } catch {checks+=1;check(error.localizedDescription.contains("Couldn't read the finished clip on this phone"),"an unreadable clip is held with the local reason")}
  check(PendingReelRequest.load(ctx) != nil && clip.posts==1,"an unreadable clip keeps the paid receipt without a generation retry")
  check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("clip-0.mp4").path),"an unreadable clip is not retained")
  ClipFrames.answerNoFrames=false
  let driftCallsBeforeRead=clip.checksDrift
  // One dropped poll (the phone was locked mid-clip) must not fail a paid clip.
  clip.throwPolls=1
  let result:URL
  do { result=try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:PendingReelRequest.load(ctx),api:clip,into:root,index:0) } catch { preconditionFailure("one dropped poll must not fail a paid clip") }
  check(ClipFrames.lastURL?.pathExtension=="mp4","frames are read from an .mp4 path, never the .tmp download")
  check(clip.checksDrift==driftCallsBeforeRead+1,"a clip this phone cannot read is held locally without a drift call")
  let resultBytes=try Data(contentsOf:result)
  check(resultBytes==Data("synthetic nonempty retained clip".utf8),"recover saves exact downloaded clip bytes")
  check(clip.posts==1&&clip.polls==staysDownPolls+6&&clip.throwPolls==0,"recovery only polls the same accepted request and resumes after one dropped poll")
  check(staysDownPolls==6,"a connection that stays down surfaces after six polls")
  check(PendingReelRequest.load(ctx) != nil,"temporary successful download keeps request")
  let old=PendingReelRequest(context:ctx,photoNumber:1,job:clip.job,sourceJPEGBase64:Data("source photo".utf8).base64EncodedString(),sourceSpaceType:"real_estate");try old.save()
  let newer=PendingReelRequest(context:ctx,photoNumber:2,job:.init(requestId:"newer",statusUrl:"s",responseUrl:"r",kind:"reel"));try newer.save();old.clear()
  check(PendingReelRequest.load(ctx)?.job.requestId=="newer","late completion cannot clear new receipt")
  newer.clear();try old.save();clip.terminal=true
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0);preconditionFailure("terminal failure surfaced")}catch{checks+=1}
  check(PendingReelRequest.load(ctx)==nil,"definitive refusal retires receipt")
  try old.save();let polls=clip.polls
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0,requireCurrent:{throw CancellationError()});preconditionFailure("stale context refuses")}catch{checks+=1}
  check(clip.polls==polls&&clip.posts==1,"stale identity refuses before status/network dispatch")
  check(PendingReelRequest.load(ctx) != nil,"identity interruption keeps scoped recovery receipt")
  // A switch while the status response is in flight must not retire the old
  // account's paid receipt or proceed to a download.
  let pollGuard=ReelReceiptHarness.generationGuard(auth:auth,model:model,listingID:ctx.listingID,targetServerID:ctx.serverListingID)
  clip.onPoll={auth.syncSessionRevision+=1}
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0,requireCurrent:pollGuard);preconditionFailure("identity switch during status must reject")}catch{check(error is CancellationError,"identity switch during status cancels before terminal processing")}
  check(PendingReelRequest.load(ctx) != nil,"identity switch during status preserves the paid receipt")
  clip.onPoll=nil;clip.terminal=false
  // Sleeping past the deadline dispatches no new poll. Returning after the
  // deadline accepts no stale completed response and keeps the paid receipt.
  ReelPollClock.reset();ReelPollClock.pauseAdvance=301
  let beforeDeadlinePolls=clip.polls
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0);preconditionFailure("deadline during suspension must reject")}catch{checks+=1}
  check(clip.polls==beforeDeadlinePolls,"a polling pause past the deadline dispatches no status request")
  check(PendingReelRequest.load(ctx) != nil,"deadline during suspension preserves the paid receipt")
  ReelPollClock.reset();clip.onPoll={ReelPollClock.elapsed+=301}
  let beforeDeadlineDrift=clip.checksDrift
  do{_ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:0);preconditionFailure("late completed response must hold")}catch{checks+=1}
  check(clip.checksDrift==beforeDeadlineDrift,"a status response past the deadline does not enter the quality gate")
  check(PendingReelRequest.load(ctx) != nil,"late completed response preserves the paid receipt")
  clip.onPoll=nil;ReelPollClock.reset()
  for status in [408,429,500,503] {check(ReelReceiptHarness.isDroppedPoll(APIError.server(status:status,code:"synthetic",message:"synthetic")),"transient status poll permits a bounded retry")}
  for status in [400,401,403,409,422] {check(!ReelReceiptHarness.isDroppedPoll(APIError.server(status:status,code:"synthetic",message:"synthetic")),"definitive status error stops read-only polling")}
  check(!ReelReceiptHarness.isDroppedPoll(CancellationError()),"cancellation never retries polling")
  check(!ReelReceiptHarness.isDroppedPoll(URLError(.cancelled)),"cancelled URL task never retries polling")
  check(!ReelReceiptHarness.isDroppedPoll(CloudSyncError.identityChanged),"identity error never retries polling")
  // Five misses, one processing reply, then five misses and completion: the
  // limit is consecutive misses, so a real reply resets it.
  clip.pollOutcomes=Array(repeating:.failure(URLError(.networkConnectionLost)),count:5)+[.success(.processing(queuePosition:nil))]+Array(repeating:.failure(URLError(.networkConnectionLost)),count:5)+[.success(.completed(videoURL:clip.url))]
  let beforeResetPolls=clip.polls
  _ = try await ReelReceiptHarness.retrieveClip(job:clip.job,pending:old,api:clip,into:root,index:1)
  check(clip.polls==beforeResetPolls+12,"a successful processing reply resets the consecutive miss bound")
  let collision=root.appendingPathComponent("same-name.tmp");let collisionMP4=root.appendingPathComponent("same-name.mp4")
  try Data("download".utf8).write(to:collision);try Data("unrelated existing clip".utf8).write(to:collisionMP4)
  let normalized=ReelReceiptHarness.clipPath(forDownloaded:collision)
  check(normalized.pathExtension=="mp4"&&normalized != collisionMP4,"download normalization uses a unique media path")
  let existingBytes=try Data(contentsOf:collisionMP4),normalizedBytes=try Data(contentsOf:normalized)
  check(existingBytes==Data("unrelated existing clip".utf8),"download normalization preserves an existing sibling")
  check(normalizedBytes==Data("download".utf8),"download normalization preserves exact bytes")
  let alreadyMP4=root.appendingPathComponent("already.mp4");try Data("already media".utf8).write(to:alreadyMP4)
  check(ReelReceiptHarness.clipPath(forDownloaded:alreadyMP4)==alreadyMP4,"an existing mp4 needs no rename")
  old.clear();let bad=PendingReelRequest(context:ctx,photoNumber:9,job:clip.job);try bad.save()
  check(PendingReelRequest.load(ctx)==nil,"invalid photo receipt cannot resume")
  try Data("broken".utf8).write(to:PendingReelRequest.file(ctx),options:.atomic)
  check(PendingReelRequest.exists(ctx)&&PendingReelRequest.load(ctx)==nil,"corrupt receipt fails closed")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx);preconditionFailure("unreadable receipt blocks another POST")}catch{checks+=1}
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
  let normal=try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:recoveryDir,index:0,recoveryContext:ctx)
  check(normal.deletingLastPathComponent().standardizedFileURL == parkedDir.standardizedFileURL,"ordinary accepted clip returns durable storage rather than temporary file")
  check(PendingReelRequest.load(ctx)==nil && PendingReelClips.load(for:ctx.listingID)?.clipURLs.contains(normal)==true,"ordinary receipt retires only after verified metadata and bytes")
  // Lost POST response cannot be replayed by this server. Retain a durable
  // operation marker, prohibit both new submission and bogus GET recovery.
  let unknownContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let unknownAPI=ClipAPI(clip.url);unknownAPI.expectedContext=unknownContext;unknownAPI.throwSubmit=true
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"unknown outcome",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("unknown submission must surface")}catch{checks+=1}
  let marker=PendingReelRequest.load(unknownContext)!
  check(marker.submissionUnconfirmed==true&&marker.operationID==unknownAPI.lastKey&&marker.inputDigest?.count==64,"unknown response retains exact durable operation identity")
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"different input",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("unknown operation blocks fresh submission")}catch{checks+=1}
  check(unknownAPI.posts==1&&unknownAPI.polls==0,"unknown operation blocks fresh submission")
  do{_ = try await ReelReceiptHarness.retrieveClip(job:marker.job,pending:marker,api:unknownAPI,into:root,index:0);preconditionFailure("unknown operation has no recoverable receipt")}catch{checks+=1}
  check(unknownAPI.polls==0,"unconfirmed operation cannot poll a fabricated job")
  PendingReelRequest.forget(unknownContext)
  check(!PendingReelRequest.exists(unknownContext),"explicit forget retires unknown marker")
  // A definitive refusal — the server answered 4xx before admitting the job,
  // nothing was counted — retires the marker so the next attempt may POST.
  // TestFlight 59 refused every preset reel with 400 and the marker then kept
  // Generate dead behind "submission needs review".
  let refusedContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let refusedAPI=ClipAPI(clip.url);refusedAPI.expectedContext=refusedContext;refusedAPI.refuseSubmit=true
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:refusedAPI,listingServerID:refusedContext.serverListingID,into:root,index:0,recoveryContext:refusedContext);preconditionFailure("a refusal must surface")}catch{checks+=1}
  check(refusedAPI.posts==1 && !PendingReelRequest.exists(refusedContext),"a definitive refusal retires the unconfirmed marker")
  refusedAPI.refuseSubmit=false
  let afterRefusal=try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:refusedAPI,listingServerID:refusedContext.serverListingID,into:root,index:0,recoveryContext:refusedContext)
  check(refusedAPI.posts==2 && FileManager.default.fileExists(atPath:afterRefusal.path),"after a definitive refusal the next attempt may POST and completes")
  // A timeout, server failure or duplicate-operation refusal cannot prove
  // that no job was admitted. Keep the operation identity and block new POSTs.
  for status in [408,409,500,502] {
   let ambiguousContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
   let ambiguousAPI=ClipAPI(clip.url);ambiguousAPI.expectedContext=ambiguousContext;ambiguousAPI.refuseSubmit=true;ambiguousAPI.refusalStatus=status
   do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:ambiguousAPI,listingServerID:ambiguousContext.serverListingID,into:root,index:0,recoveryContext:ambiguousContext);preconditionFailure("ambiguous response must surface")}catch{checks+=1}
   check(PendingReelRequest.load(ambiguousContext)?.submissionUnconfirmed==true,status == 409 ? "duplicate refusal preserves the already-started operation marker" : "ambiguous HTTP response keeps its operation marker")
   let ambiguousKey=ambiguousAPI.lastKey
   do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:ambiguousAPI,listingServerID:ambiguousContext.serverListingID,into:root,index:0,recoveryContext:ambiguousContext);preconditionFailure("unknown outcome blocks a new operation")}catch{checks+=1}
   check(ambiguousAPI.posts==1 && ambiguousAPI.lastKey==ambiguousKey,"ambiguous outcome cannot submit with a fresh operation id")
   PendingReelRequest.forget(ambiguousContext)
  }
  for status in [401,402,403,422,429] {
   let deniedContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
   let deniedAPI=ClipAPI(clip.url);deniedAPI.expectedContext=deniedContext;deniedAPI.refuseSubmit=true;deniedAPI.refusalStatus=status
   do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:deniedAPI,listingServerID:deniedContext.serverListingID,into:root,index:0,recoveryContext:deniedContext);preconditionFailure("pre-admission denial must surface")}catch{checks+=1}
   check(deniedAPI.posts==1 && !PendingReelRequest.exists(deniedContext),"account quota and validation refusal retire unconfirmed markers")
  }
  // The transport-loss case keeps its marker exactly as before.
  let lostContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let lostAPI=ClipAPI(clip.url);lostAPI.expectedContext=lostContext;lostAPI.throwSubmit=true
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:lostAPI,listingServerID:lostContext.serverListingID,into:root,index:0,recoveryContext:lostContext);preconditionFailure("a lost response must surface")}catch{checks+=1}
  check(PendingReelRequest.load(lostContext)?.submissionUnconfirmed==true,"a lost response still keeps its unconfirmed marker")
  PendingReelRequest.forget(lostContext)
  // Actual filesystem blocker prevents a first POST, rather than hoping a
  // record can be persisted after accepting a charged job.
  let requestDirectory=PendingReelRequest.file(ctx).deletingLastPathComponent()
  let preserved=requestDirectory.deletingLastPathComponent().appendingPathComponent("requests-preserved")
  try FileManager.default.moveItem(at:requestDirectory,to:preserved)
  try Data("synthetic request-directory blocker".utf8).write(to:requestDirectory)
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:unknownAPI,listingServerID:unknownContext.serverListingID,into:root,index:0,recoveryContext:unknownContext);preconditionFailure("pre-dispatch storage must succeed")}catch{checks+=1}
  check(unknownAPI.posts==1,"pre-dispatch disk blocker permits no paid POST")
  try FileManager.default.removeItem(at:requestDirectory)
  try FileManager.default.moveItem(at:preserved,to:requestDirectory)
  let attachContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let attachAPI=ClipAPI(clip.url);attachAPI.expectedContext=attachContext
  attachAPI.beforeReply={try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:requestDirectory.path)}
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:attachAPI,listingServerID:attachContext.serverListingID,into:root,index:0,recoveryContext:attachContext);preconditionFailure("accepted attachment storage failure must surface")}catch{checks+=1}
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:requestDirectory.path)
  check(attachAPI.posts==1&&attachAPI.polls==0&&PendingReelRequest.load(attachContext)?.submissionUnconfirmed==true,"accepted receipt save failure retains unconfirmed durable marker")
  // Normal Generate obeys the same durable-retention rule as Recover.
  let blockedContext=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:ctx.owner,workspace:ctx.workspace)
  let blockedAPI=ClipAPI(clip.url);blockedAPI.expectedContext=blockedContext
  let blockedParked=PendingReelClips.directory(for:blockedContext.listingID)
  try Data("synthetic parked-directory blocker".utf8).write(to:blockedParked)
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:blockedAPI,listingServerID:blockedContext.serverListingID,into:root,index:0,recoveryContext:blockedContext);preconditionFailure("ordinary retention blocker must surface")}catch{checks+=1}
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
