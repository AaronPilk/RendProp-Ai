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
enum ClipFrames {static var lastURL:URL?;static var answerNoFrames=false;static func extract(from u:URL) async -> [(at:String,jpeg:Data)] { lastURL=u;if answerNoFrames{return []};return ["first","middle","last"].map { ($0, Data("frame".utf8)) } } }
struct EnhancedPhoto { let id:String;let originalURL:URL;let enhancedURL:URL;init(id:String="synthetic",originalURL:URL?=nil,enhancedURL:URL){self.id=id;self.originalURL=originalURL ?? enhancedURL;self.enhancedURL=enhancedURL};static func directory(for id:UUID)->URL{FileStore.documents.appendingPathComponent("synthetic-photo-history-"+id.uuidString)} }
// Closed persisted-review boundary: this gate proves the production preparation
// calls it before a paid dispatch. The history gate executes its real file rules.
enum PhotoVersionHistory {
 static var rejectReview=false
 static func requireReelReview(imageURL:URL)throws {if rejectReview{throw AIImagePrep.error("synthetic review required")}}
 static func requireReelReview(versionID:String,directory:URL)throws {if rejectReview{throw AIImagePrep.error("synthetic review required")}}
}
struct UIImage {
 static var onPreparation:(() -> Void)?;static var savedSize=CGSize(width:1280,height:720);static var rejectSavedJPEG=false
 let bytes:Data;var size:CGSize {Self.savedSize}
 init?(contentsOfFile:String){guard let d=try? Data(contentsOf:URL(fileURLWithPath:contentsOfFile)) else{return nil};bytes=d}
 init?(data:Data){guard !data.isEmpty && !Self.rejectSavedJPEG else{return nil};bytes=data}
 func jpegData(compressionQuality:Double)->Data?{Self.onPreparation?();return bytes}
}
// Closed rendering boundary only. The separate simulator gate executes the
// real AVFoundation renderer; this gate proves the production routing, exact
// saved JPEG/shape input, post-render fences and durable acknowledgement order.
enum OriginalPhotoMotion {
 static var sources:[Data]=[];static var sizes:[CGSize]=[];static var onRender:(()throws->Void)?
 static let bytes=Data("synthetic original photo motion".utf8)
 static func isClip(_ url:URL)->Bool {url.lastPathComponent.contains("photo-motion-")}
 static func render(jpeg:Data,renderSize:CGSize,output:URL) async throws {
  sources.append(jpeg);sizes.append(renderSize);await Task.yield();try onRender?();try bytes.write(to:output)
 }
 static func reset(){sources=[];sizes=[];onRender=nil;UIImage.savedSize=CGSize(width:1280,height:720);UIImage.rejectSavedJPEG=false}
}
final class QualityFence {var stale=false}
enum AIImagePrep {static func downscaled(_ i:UIImage,maxDimension:Int)->UIImage{i};static func reelSource(_ i:UIImage,aspect:String)->UIImage{i};static func error(_ m:String)->Error{NSError(domain:"synthetic",code:1,userInfo:[NSLocalizedDescriptionKey:m])} }
protocol APIClient {func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,aspect:String?,framing:String?,presetVersion:Int?,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob;func aiVideoStatus(_ j:AIVideoJob) async throws->AIVideoStatus;func aiVideoDrift(_ r:DriftCheckRequest) async throws->DriftVerdict}
extension APIClient {
 func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,aspect:String?,framing:String?,presetVersion:Int?,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?,sourceAssetID:String,sourceProvenanceID:String?) async throws->AIVideoJob {
  if let fake=self as? ClipAPI,let context=fake.expectedContext {
   let marker=PendingReelRequest.load(context)
   precondition(marker?.sourceAssetID==sourceAssetID && marker?.photoProvenanceID==sourceProvenanceID,"exact private source identity is durable before provider admission")
  }
  return try await aiVideoReelClip(imageBase64:imageBase64,mime:mime,prompt:prompt,seconds:seconds,aspect:aspect,framing:framing,presetVersion:presetVersion,motion:motion,room:room,shotIndex:shotIndex,shotCount:shotCount,listingServerID:listingServerID,label:label,idempotencyKey:idempotencyKey)
 }
}
final class ClipAPI:APIClient {
 struct Submission {let image:String;let motion:String?;let key:String?;let attempt:Int?;let source:String?;let jobID:String;let index:Int?;let count:Int?;let framing:String?;let outputAspect:String?}
 var expectedContext:PendingReelRequest.Context?;var lastKey:String?
 var beforeReply:(() throws -> Void)?;var onPoll:(()->Void)?;var onDrift:(()->Void)?;var pollOutcomes:[Result<AIVideoStatus,Error>]=[]
 var rejectsDrift=false;var unavailableDrift=false;var checksDrift=0;var posts=0,polls=0;var throwPolls=0;var throwSubmit=false;var refuseSubmit=false;var refusalStatus=400;var terminal=false;var url:URL
 var allowQualityRetry=false;var allowScenePlan=false;var submissions:[Submission]=[];var driftRequests:[DriftCheckRequest]=[];var driftOutcomes:[Result<DriftVerdict,Error>]=[]
 var job=AIVideoJob(requestId:UUID().uuidString,statusUrl:"synthetic-status",responseUrl:"synthetic-response",kind:"reel",provenanceID:"synthetic-provenance-0")
 init(_ u:URL){url=u}
 func aiVideoReelClip(imageBase64:String,mime:String,prompt:String?,seconds:Int,aspect:String?,framing:String?=nil,presetVersion:Int?,motion:String?,room:String?,shotIndex:Int?,shotCount:Int?,listingServerID:UUID?,label:String?,idempotencyKey:String?) async throws->AIVideoJob {
  let marker=expectedContext.flatMap(PendingReelRequest.load)
  if expectedContext != nil {precondition(marker?.submissionUnconfirmed==true && marker?.operationID==idempotencyKey && marker?.inputDigest?.count==64,"durable operation marker exists before POST")}
  if marker?.framing != nil || framing != nil {
   precondition(marker?.framing==framing && marker?.outputAspect==aspect,"new whole-source framing survives provider admission")
  }
  lastKey=idempotencyKey;posts+=1
  precondition(seconds==5&&mime=="image/jpeg"&&["9:16","16:9"].contains(aspect ?? "")&&presetVersion==1&&(motion=="fly_through" || (allowQualityRetry&&motion=="push_in") || (allowScenePlan && ["push_in","side_glide","pull_back"].contains(motion ?? "")))&&prompt==nil)
  if allowQualityRetry {job=AIVideoJob(requestId:UUID().uuidString,statusUrl:"synthetic-status",responseUrl:"synthetic-response",kind:"reel",provenanceID:"synthetic-provenance-\(posts-1)")}
  submissions.append(.init(image:imageBase64,motion:motion,key:idempotencyKey,attempt:marker?.qualityAttempt,source:marker?.sourceJPEGBase64,jobID:job.requestId,index:shotIndex,count:shotCount,framing:framing,outputAspect:marker?.outputAspect))
  if throwSubmit{throw URLError(.networkConnectionLost)}
  if refuseSubmit{throw APIError.server(status:refusalStatus,code:refusalStatus == 409 ? "conflict" : "validation",message:refusalStatus == 409 ? "Duplicate submission — this job was already started." : "Unsupported video accounting metadata")}
  try beforeReply?();return job
 }
 func aiVideoDrift(_ r:DriftCheckRequest) async throws->DriftVerdict {
  checksDrift+=1;driftRequests.append(r)
  precondition(!r.frames.isEmpty,"a clip this phone cannot read is held locally without a drift call")
  precondition(!r.sourceBase64.isEmpty && r.frames.count==3 && r.requestID==job.requestId)
  onDrift?();if unavailableDrift {throw URLError(.timedOut)}
  if !driftOutcomes.isEmpty {return try driftOutcomes.removeFirst().get()}
  return DriftVerdict(status:rejectsDrift ? .fail:.pass,publishable:!rejectsDrift,action:rejectsDrift ? "retry":"publish",message:"Property changed; held.",reason:nil)
 }
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
  if CommandLine.arguments.contains("--large-only") {let n=try await largeBatch(root:root);print("PASSED: \(n) actual large video recipe/recovery/order assertions; no provider");return}
  if CommandLine.arguments.contains("--choices-only") {let n=try await recoveryChoices(root:root,input:input);print("PASSED: \(n) actual explicit recovery choices and batch continuation assertions; no provider");return}
  if CommandLine.arguments.contains("--quality-only") {let n=try await qualityRouting(root:root,input:input);print("PASSED: \(n) actual quality retry/original-motion assertions; renderer boundary doubled, no provider");return}
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
  PhotoVersionHistory.rejectReview=true
  do{_ = try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:clip,listingServerID:ctx.serverListingID,into:root,index:0,recoveryContext:ctx,requireCurrent:dispatchGuard);preconditionFailure("unreviewed preparation must reject paid dispatch")}catch{check(error.localizedDescription=="synthetic review required","unreviewed preparation calls persisted review before paid dispatch")}
  PhotoVersionHistory.rejectReview=false
  check(clip.posts==0 && !PendingReelRequest.exists(ctx),"unreviewed preparation permits no paid POST or pending marker")
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
  old.clear()
  for photoNumber in [9,100] {
   let valid=PendingReelRequest(context:ctx,photoNumber:photoNumber,job:clip.job);try valid.save()
   check(PendingReelRequest.load(ctx)?.photoNumber==photoNumber,"valid photo receipt within100 preserves its exact position")
  }
  for photoNumber in [-1,0,101,Int.max] {
   let bad=PendingReelRequest(context:ctx,photoNumber:photoNumber,job:clip.job);try bad.save()
   check(PendingReelRequest.load(ctx)==nil,"invalid photo receipt cannot resume")
  }
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
  checks += try await qualityRouting(root:root,input:input)
  checks += try await recoveryChoices(root:root,input:input)
  print("PASSED: \(checks) actual receipt/makeClip/retrieveClip assertions; HTTP loopback only, image preparation and API boundary doubled")
 }
 @MainActor static func qualityRouting(root:URL,input:URL) async throws -> Int {
  var checks=0
  func check(_ condition:@autoclosure()->Bool,_ message:String){precondition(condition(),message);checks+=1}
  func verdict(_ status:DriftVerdict.Status,_ action:String,_ publishable:Bool=false)->DriftVerdict {.init(status:status,publishable:publishable,action:action,message:"Synthetic property verdict",reason:nil)}
  let jpeg=try Data(contentsOf:input)
  func setup()->(PendingReelRequest.Context,ClipAPI,URL) {
   OriginalPhotoMotion.reset();ReelPollClock.reset();ClipFrames.answerNoFrames=false
   let context=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:"synthetic-quality-owner",workspace:UUID())
   let api=ClipAPI(URL(string:CommandLine.arguments[1]+"/quality")!);api.expectedContext=context;api.allowQualityRetry=true
   let dir=root.appendingPathComponent("quality-"+UUID().uuidString);try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
   return (context,api,dir)
  }
  func generate(_ context:PendingReelRequest.Context,_ api:ClipAPI,_ dir:URL,guardCurrent:@escaping @MainActor @Sendable ()throws->Void={try Task.checkCancellation()}) async throws -> URL {
   try await ReelReceiptHarness.makeClip(photo:.init(enhancedURL:input),prompt:"",shot:nil,shotCount:1,motion:"fly_through",aspect:"9:16",spaceType:"real_estate",api:api,listingServerID:context.serverListingID,into:dir,index:0,recoveryContext:context,requireCurrent:guardCurrent)
  }
  let (retryContext,retryAPI,retryDir)=setup()
  retryAPI.driftOutcomes=[.success(verdict(.fail,"retry")),.success(verdict(.pass,"publish",true))]
  let safeRetry=try await generate(retryContext,retryAPI,retryDir)
  check(retryAPI.posts==2 && retryAPI.checksDrift==2,"confirmed drift requests exactly one paid retry")
  check(retryAPI.submissions.map(\.motion)==["fly_through","push_in"],"only the bounded retry uses the safer push-in preset")
  check(retryAPI.submissions.allSatisfy{$0.image==jpeg.base64EncodedString() && $0.source==$0.image},"retry uses the exact same prepared and saved JPEG")
  check(Set(retryAPI.submissions.compactMap(\.key)).count==2 && Set(retryAPI.submissions.map(\.jobID)).count==2,"quality retry has separate exact operation and accepted job identities")
  check(retryAPI.submissions.map(\.attempt)==[0,1] && retryAPI.driftRequests.map(\.attempt)==[0,1],"retry attempts persist and reach the real drift request")
  check(retryAPI.driftRequests.map(\.provenanceID)==["synthetic-provenance-0","synthetic-provenance-1"],"each drift judgement carries its exact accepted provenance")
  check(OriginalPhotoMotion.sources.isEmpty && !OriginalPhotoMotion.isClip(safeRetry),"accepted safer retry stays an AI clip")
  check(PendingReelRequest.load(retryContext)==nil && PendingReelClips.load(for:retryContext.listingID)?.clipURLs==[safeRetry],"successful retry acknowledges only its durably retained clip")
  let (boundContext,boundAPI,boundDir)=setup()
  boundAPI.driftOutcomes=Array(repeating:.success(verdict(.fail,"retry")),count:4)
  do{_ = try await generate(boundContext,boundAPI,boundDir);preconditionFailure("repeated retry judgement must stay stopped")}catch{checks+=1}
  check(boundAPI.posts==2 && boundAPI.checksDrift==2,"quality retry is bounded to two total provider generations")
  check(PendingReelRequest.load(boundContext)?.qualityAttempt==1 && PendingReelRequest.load(boundContext)?.job.requestId==boundAPI.job.requestId,"second refused receipt remains recoverable")
  check(OriginalPhotoMotion.sources.isEmpty && PendingReelClips.load(for:boundContext.listingID)==nil,"nonterminal retry never fabricates an original-photo fallback")
  PendingReelRequest.forget(boundContext)
  // A retained old receipt with an explicit terminal verdict uses the source
  // stored with that receipt, not the photo currently selected in the UI.
  let (terminalContext,terminalAPI,terminalDir)=setup()
  let savedJPEG=Data("exact accepted saved JPEG bytes".utf8)
  let terminal=PendingReelRequest(context:terminalContext,photoNumber:1,job:terminalAPI.job,sourceJPEGBase64:savedJPEG.base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:1)
  try terminal.save();terminalAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))];UIImage.savedSize=CGSize(width:720,height:1280)
  let local=try await ReelReceiptHarness.retrieveClip(job:terminal.job,pending:terminal,api:terminalAPI,into:terminalDir,index:0)
  check(terminalAPI.posts==0 && terminalAPI.polls==1,"terminal recovery never dispatches another generation")
  check(OriginalPhotoMotion.sources==[savedJPEG],"original motion renders only the exact accepted saved JPEG")
  check(OriginalPhotoMotion.sizes.count==1 && OriginalPhotoMotion.sizes[0].width==1080 && OriginalPhotoMotion.sizes[0].height==1920,"original portrait source selects the portrait renderer shape")
  check(OriginalPhotoMotion.isClip(local),"temporary original-motion clip preserves its identity")
  check(PendingReelRequest.load(terminalContext)?.job.requestId==terminal.job.requestId,"local fallback keeps receipt until durable retention")
  check(!FileManager.default.fileExists(atPath:terminalDir.appendingPathComponent("clip-0.mp4").path),"rejected AI bytes never become an accepted clip")
  let retained=try ReelReceiptHarness.retainRecoveredClip(local,for:terminalContext.listingID)
  let retainedBytes=try Data(contentsOf:retained)
  check(retainedBytes==OriginalPhotoMotion.bytes && OriginalPhotoMotion.isClip(retained),"durable retention preserves original-motion bytes and label")
  check(PendingReelClips.load(for:terminalContext.listingID)?.clipURLs==[retained],"original fallback is addressable through the durable manifest")
  check(PendingReelRequest.load(terminalContext) != nil,"retaining a local fallback never independently clears a receipt")
  terminal.clear();check(PendingReelRequest.load(terminalContext)==nil,"caller may acknowledge the durably retained original fallback")
  let rawLocal=terminalDir.appendingPathComponent("clip-photo-motion-next.mp4");try OriginalPhotoMotion.bytes.write(to:rawLocal)
  ReelReceiptHarness.parkClips([retained,rawLocal],for:terminalContext.listingID,tmpDir:terminalDir)
  let parked=PendingReelClips.load(for:terminalContext.listingID)!.clipURLs
  check(parked.count==2 && parked.allSatisfy(OriginalPhotoMotion.isClip),"batch parking preserves original-motion labels for every retained copy")
  let (ordinaryContext,ordinaryAPI,ordinaryDir)=setup();ordinaryAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))]
  let ordinary=try await generate(ordinaryContext,ordinaryAPI,ordinaryDir)
  check(ordinaryAPI.posts==1 && OriginalPhotoMotion.sources==[jpeg],"ordinary terminal refusal renders the same saved source with no paid retry")
  check(OriginalPhotoMotion.sizes.count==1 && OriginalPhotoMotion.sizes[0].width==1080 && OriginalPhotoMotion.sizes[0].height==1920,"new request keeps selected portrait delivery for a landscape source")
  check(OriginalPhotoMotion.isClip(ordinary) && PendingReelClips.load(for:ordinaryContext.listingID)?.clipURLs==[ordinary] && PendingReelRequest.load(ordinaryContext)==nil,"ordinary original fallback retires receipt after durable acceptance")
  // Reject every nonterminal/unavailable verdict even when its action string
  // says refuse. The server must explicitly report fail AND refuse.
  let(legacyLandscape,legacyLandscapeAPI,legacyLandscapeDir)=setup()
  let oldLandscape=PendingReelRequest(context:legacyLandscape,photoNumber:1,job:legacyLandscapeAPI.job,sourceJPEGBase64:savedJPEG.base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:1)
  try oldLandscape.save();legacyLandscapeAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))]
  _ = try await ReelReceiptHarness.retrieveClip(job:oldLandscape.job,pending:oldLandscape,api:legacyLandscapeAPI,into:legacyLandscapeDir,index:0)
  check(OriginalPhotoMotion.sizes[0].width==1920 && OriginalPhotoMotion.sizes[0].height==1080,"legacy landscape receipt preserves its saved source shape")
  PendingReelRequest.forget(legacyLandscape)
  for rejected in [verdict(.unavailable,"refuse"),verdict(.pass,"refuse"),verdict(.fail,"hold"),verdict(.fail,"reject")] {
   let (context,api,dir)=setup();api.driftOutcomes=[.success(rejected)]
   do{_ = try await generate(context,api,dir);preconditionFailure("ambiguous quality verdict must hold")}catch{checks+=1}
   check(api.posts==1 && OriginalPhotoMotion.sources.isEmpty,"only explicit fail/refuse can render original motion")
   check(PendingReelRequest.load(context)?.job.requestId==api.job.requestId && PendingReelClips.load(for:context.listingID)==nil,"ambiguous quality verdict keeps the accepted receipt and no clip")
   PendingReelRequest.forget(context)
  }
  for error:Error in [APIError.server(status:401,code:"auth",message:"Synthetic auth"),APIError.server(status:402,code:"quota",message:"Synthetic quota"),URLError(.networkConnectionLost),CancellationError()] {
   let (context,api,dir)=setup();api.driftOutcomes=[.failure(error)]
   do{_ = try await generate(context,api,dir);preconditionFailure("quality route failure must hold")}catch{checks+=1}
   check(api.posts==1 && OriginalPhotoMotion.sources.isEmpty,"auth quota transport cancellation never trigger a generation retry or fallback")
   check(PendingReelRequest.load(context)?.job.requestId==api.job.requestId,"quality route failure preserves the accepted receipt")
   PendingReelRequest.forget(context)
  }
  let (decodeContext,decodeAPI,decodeDir)=setup();ClipFrames.answerNoFrames=true
  do{_ = try await generate(decodeContext,decodeAPI,decodeDir);preconditionFailure("decoder failure must hold")}catch{checks+=1}
  check(decodeAPI.posts==1 && decodeAPI.checksDrift==0 && OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(decodeContext) != nil,"decoder failure holds receipt without QC fallback or another POST")
  ClipFrames.answerNoFrames=false;PendingReelRequest.forget(decodeContext)
  let (invalidContext,invalidAPI,invalidDir)=setup();invalidAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))];UIImage.rejectSavedJPEG=true
  do{_ = try await generate(invalidContext,invalidAPI,invalidDir);preconditionFailure("invalid saved image must hold")}catch{checks+=1}
  check(OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(invalidContext) != nil,"unreadable saved JPEG never reaches the local renderer")
  UIImage.rejectSavedJPEG=false;PendingReelRequest.forget(invalidContext)
  let (shapeContext,shapeAPI,shapeDir)=setup();shapeAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))];UIImage.savedSize = CGSize(width:0,height:0)
  do{_ = try await generate(shapeContext,shapeAPI,shapeDir);preconditionFailure("invalid saved image shape must hold")}catch{checks+=1}
  check(OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(shapeContext) != nil,"invalid source geometry never reaches local renderer")
  PendingReelRequest.forget(shapeContext)
  let (qcContext,qcAPI,qcDir)=setup();let qcFence=QualityFence();qcAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))];qcAPI.onDrift={qcFence.stale=true}
  do{_ = try await generate(qcContext,qcAPI,qcDir,guardCurrent:{if qcFence.stale{throw CancellationError()}});preconditionFailure("identity switch during QC must stop")}catch{checks+=1}
  check(OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(qcContext) != nil,"stale QC response never enters local fallback")
  PendingReelRequest.forget(qcContext)
  let (renderContext,renderAPI,renderDir)=setup();let renderFence=QualityFence();renderAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))];OriginalPhotoMotion.onRender={renderFence.stale=true}
  let renderPending=PendingReelRequest(context:renderContext,photoNumber:1,job:renderAPI.job,sourceJPEGBase64:jpeg.base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:1);try renderPending.save()
  do{_ = try await ReelReceiptHarness.retrieveClip(job:renderPending.job,pending:renderPending,api:renderAPI,into:renderDir,index:0,requireCurrent:{if renderFence.stale{throw CancellationError()}});preconditionFailure("post-render identity change must stop")}catch{checks+=1}
  check(OriginalPhotoMotion.sources.count==1 && PendingReelRequest.load(renderContext) != nil && PendingReelClips.load(for:renderContext.listingID)==nil,"stale local render keeps receipt and never durably accepts clip")
  PendingReelRequest.forget(renderContext)
  let (diskContext,diskAPI,diskDir)=setup();diskAPI.driftOutcomes=[.success(verdict(.fail,"refuse"))]
  let diskPark=PendingReelClips.directory(for:diskContext.listingID)
  diskAPI.beforeReply={try FileManager.default.createDirectory(at:diskPark.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("retention blocker".utf8).write(to:diskPark)}
  do{_ = try await generate(diskContext,diskAPI,diskDir);preconditionFailure("local fallback retention failure must surface")}catch{checks+=1}
  check(diskAPI.posts==1 && OriginalPhotoMotion.sources.count==1 && PendingReelRequest.load(diskContext)?.job.requestId==diskAPI.job.requestId,"local fallback disk failure preserves its accepted receipt")
  check(FileManager.default.fileExists(atPath:diskDir.appendingPathComponent("clip-photo-motion-0.mp4").path),"retention failure preserves the only local original-motion copy")
  try FileManager.default.removeItem(at:diskPark);PendingReelRequest.forget(diskContext)
  OriginalPhotoMotion.reset();ReelPollClock.reset();return checks
 }

 @MainActor static func recoveryChoices(root:URL,input:URL) async throws -> Int {
  var checks=0
  func check(_ condition:@autoclosure()->Bool,_ message:String){precondition(condition(),message);checks+=1}
  func verdict(_ status:DriftVerdict.Status,_ action:String,_ publishable:Bool=false)->DriftVerdict {.init(status:status,publishable:publishable,action:action,message:"Synthetic choice verdict",reason:nil)}
  let source=Data("saved first photo exact JPEG".utf8)
  func setup()->(PendingReelRequest,ClipAPI,URL) {
   OriginalPhotoMotion.reset();ReelPollClock.reset();ClipFrames.answerNoFrames=false;UIImage.savedSize=CGSize(width:720,height:1280)
   let context=PendingReelRequest.Context(listingID:UUID(),serverListingID:UUID(),owner:"synthetic-choice-owner",workspace:UUID())
   let api=ClipAPI(URL(string:CommandLine.arguments[1]+"/quality")!);api.expectedContext=context;api.allowQualityRetry=true
   let request=PendingReelRequest(context:context,photoNumber:1,job:api.job,sourceJPEGBase64:source.base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:0)
   try! request.save()
   let dir=root.appendingPathComponent("choice-"+UUID().uuidString);try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
   return(request,api,dir)
  }
  let (original,originalAPI,originalDir)=setup();originalAPI.driftOutcomes=[.success(verdict(.fail,"retry"))]
  let local=try await ReelReceiptHarness.resolveSavedQualityRetry(original,choice:.originalPhoto,api:originalAPI,into:originalDir,requireCurrent:{try Task.checkCancellation()})
  check(originalAPI.posts==0 && originalAPI.polls==1,"explicit original choice sends no generation POST")
  check(OriginalPhotoMotion.sources==[source],"explicit original choice renders exact saved JPEG")
  check(PendingReelRequest.load(original.context)==nil && PendingReelClips.load(for:original.context.listingID)?.clipURLs==[local],"explicit original choice retains before acknowledgement")
  let (retry,retryAPI,retryDir)=setup();retryAPI.driftOutcomes=[.success(verdict(.fail,"retry")),.success(verdict(.pass,"publish",true))]
  let ai=try await ReelReceiptHarness.resolveSavedQualityRetry(retry,choice:.saferRetry,api:retryAPI,into:retryDir,requireCurrent:{try Task.checkCancellation()})
  check(retryAPI.posts==1 && retryAPI.submissions[0].motion=="push_in" && retryAPI.submissions[0].index==0,"explicit retry sends one safer POST at original position")
  check(retryAPI.submissions[0].image==source.base64EncodedString() && retryAPI.submissions[0].source==source.base64EncodedString(),"explicit safer retry uses exact saved JPEG")
  check(retryAPI.submissions[0].attempt==1 && retryAPI.driftRequests.map(\.attempt)==[0,1],"explicit safer retry persists attempt one")
  check(PendingReelRequest.load(retry.context)==nil && PendingReelClips.load(for:retry.context.listingID)?.clipURLs==[ai],"explicit accepted retry retains before acknowledgement")
  for rejected in [verdict(.unavailable,"retry"),verdict(.fail,"hold"),verdict(.pass,"retry")] {
   let (request,api,dir)=setup();api.driftOutcomes=[.success(rejected)]
   do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(request,choice:.originalPhoto,api:api,into:dir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("unavailable recovery must remain held")}catch{checks+=1}
   check(api.posts==0 && OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(request.context) != nil,"unavailable recovery never opens either explicit choice")
  }
  for error:Error in [APIError.server(status:401,code:"auth",message:"Synthetic"),APIError.server(status:402,code:"quota",message:"Synthetic"),URLError(.networkConnectionLost),CancellationError()] {
   let(request,api,dir)=setup();api.driftOutcomes=[.failure(error)]
   do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(request,choice:.saferRetry,api:api,into:dir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("failed cached recovery cannot retry")}catch{checks+=1}
   check(api.posts==0 && OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(request.context) != nil,"auth quota network cancellation preserve choice receipt")
  }
  let(stale,staleAPI,staleDir)=setup();let staleFence=QualityFence();staleAPI.driftOutcomes=[.success(verdict(.fail,"retry"))];staleAPI.onDrift={staleFence.stale=true}
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(stale,choice:.saferRetry,api:staleAPI,into:staleDir,requireCurrent:{if staleFence.stale{throw CancellationError()}});preconditionFailure("stale cached verdict cannot dispatch")}catch{checks+=1}
  check(staleAPI.posts==0 && OriginalPhotoMotion.sources.isEmpty && PendingReelRequest.load(stale.context) != nil,"identity change during cached QC sends no new generation")
  let(disk,diskAPI,diskDir)=setup();diskAPI.driftOutcomes=[.success(verdict(.fail,"retry"))]
  let diskPark=PendingReelClips.directory(for:disk.context.listingID)
  OriginalPhotoMotion.onRender={try FileManager.default.createDirectory(at:diskPark.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("blocker".utf8).write(to:diskPark)}
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(disk,choice:.originalPhoto,api:diskAPI,into:diskDir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("explicit original retention failure must hold")}catch{checks+=1}
  check(PendingReelRequest.load(disk.context)?.job.requestId==disk.job.requestId && diskAPI.posts==0,"explicit original disk failure keeps its paid receipt")
  let(unknown,unknownAPI,unknownDir)=setup();unknownAPI.driftOutcomes=[.success(verdict(.fail,"retry"))];unknownAPI.throwSubmit=true
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(unknown,choice:.saferRetry,api:unknownAPI,into:unknownDir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("unknown safer dispatch stays held")}catch{checks+=1}
  check(unknownAPI.posts==1 && PendingReelRequest.load(unknown.context)?.submissionUnconfirmed==true && PendingReelRequest.load(unknown.context)?.qualityAttempt==1,"unknown safer dispatch preserves attempt-one marker")
  unknownAPI.throwSubmit=false
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(unknown,choice:.saferRetry,api:unknownAPI,into:unknownDir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("old receipt cannot duplicate new unknown retry")}catch{checks+=1}
  check(unknownAPI.posts==1,"stale original choice cannot submit twice")
  let(denied,deniedAPI,deniedDir)=setup();deniedAPI.driftOutcomes=[.success(verdict(.fail,"retry"))];deniedAPI.refuseSubmit=true
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(denied,choice:.saferRetry,api:deniedAPI,into:deniedDir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("definitive safer refusal surfaces")}catch{checks+=1}
  check(PendingReelRequest.load(denied.context)?.job.requestId==denied.job.requestId && PendingReelRequest.load(denied.context)?.qualityAttempt==0,"definitive safer refusal restores exact rejected receipt without gap")
  let(legacy,legacyAPI,legacyDir)=setup();let old=PendingReelRequest(context:legacy.context,photoNumber:1,job:legacy.job,sourceJPEGBase64:source.base64EncodedString(),sourceSpaceType:"real_estate")
  try old.save()
  do{_ = try await ReelReceiptHarness.resolveSavedQualityRetry(old,choice:.saferRetry,api:legacyAPI,into:legacyDir,requireCurrent:{try Task.checkCancellation()});preconditionFailure("legacy attempt cannot infer a first retry")}catch{checks+=1}
  check(legacyAPI.posts==0 && PendingReelBatch.exists(old.context)==false,"legacy recovery invents neither first attempt nor full batch")
  // New batch contains exact prepared source bytes and original shot order.
  let(first,batchAPI,batchDir)=setup()
  let second=Data("second saved source JPEG".utf8),third=Data("third saved source JPEG".utf8)
  let shot=AIShot(photoID:"one",order:1,motion:"fly_through",room:"Kitchen",onScreenText:"Bright original kitchen",seconds:4,voiceLine:nil)
  let batch=PendingReelBatch(context:first.context,id:UUID(),photos:[.init(id:"one",jpegBase64:source.base64EncodedString(),shot:.init(shot)),.init(id:"two",jpegBase64:second.base64EncodedString(),shot:nil),.init(id:"three",jpegBase64:third.base64EncodedString(),shot:nil)],motion:"fly_through",aspect:"9:16",spaceType:"real_estate",completedPaths:[])
  try batch.save()
  let loaded=try PendingReelBatch.load(first.context)!
  check(loaded.photos.map(\.id)==["one","two","three"] && loaded.photos[0].shot?.value==shot,"saved batch preserves order and real shot plan")
  let wrong=PendingReelRequest(context:first.context,photoNumber:1,job:first.job,sourceJPEGBase64:Data("wrong source".utf8).base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:0);try wrong.save()
  let wrongClip=batchDir.appendingPathComponent("wrong-clip.mp4");try Data("video".utf8).write(to:wrongClip)
  do{_ = try await ReelReceiptHarness.acknowledgeRecoveredClip(wrongClip,request:wrong,requireCurrent:{try Task.checkCancellation()});preconditionFailure("wrong source cannot advance progress")}catch{checks+=1}
  check((try! PendingReelBatch.load(first.context))?.completedPaths.isEmpty==true && FileManager.default.fileExists(atPath:wrongClip.path),"wrong recovered source cannot advance saved batch")
  try first.save();batchAPI.driftOutcomes=[.success(verdict(.fail,"retry"))]
  let firstClip=try await ReelReceiptHarness.resolveSavedQualityRetry(first,choice:.originalPhoto,api:batchAPI,into:batchDir,requireCurrent:{try Task.checkCancellation()})
  check((try! PendingReelBatch.load(first.context))?.completedPaths==[FileStore.relativePath(for:firstClip)] && PendingReelRequest.load(first.context)==nil,"batch progress is durable before receipt acknowledgement")
  batchAPI.driftOutcomes=[.success(verdict(.pass,"publish",true)),.success(verdict(.pass,"publish",true))]
  let finished:PendingReelBatch
  do{finished=try await ReelReceiptHarness.completeSavedBatch(batch,api:batchAPI,into:batchDir,requireCurrent:{try Task.checkCancellation()},progress:{_ in})}catch{preconditionFailure("batch continuation generates each remaining photo in order")}
  check(batchAPI.posts==2 && batchAPI.submissions.map(\.index)==[1,2] && batchAPI.submissions.map(\.image)==[second.base64EncodedString(),third.base64EncodedString()],"batch continuation generates each remaining photo in order")
  check(finished.completedPaths.count==3 && finished.completedPaths[0]==FileStore.relativePath(for:firstClip) && PendingReelRequest.load(first.context)==nil,"full batch keeps previously paid recovered clip")
  let again=try await ReelReceiptHarness.completeSavedBatch(batch,api:batchAPI,into:batchDir,requireCurrent:{try Task.checkCancellation()},progress:{_ in})
  check(again.completedPaths==finished.completedPaths && batchAPI.posts==2,"completed batch resumes without another generation")
  let(pending,pendingAPI,pendingDir)=setup();let heldBatch=PendingReelBatch(context:pending.context,id:UUID(),photos:[.init(id:"held",jpegBase64:source.base64EncodedString(),shot:nil)],motion:"fly_through",aspect:"9:16",spaceType:"real_estate",completedPaths:[]);try heldBatch.save()
  do{_ = try await ReelReceiptHarness.completeSavedBatch(heldBatch,api:pendingAPI,into:pendingDir,requireCurrent:{try Task.checkCancellation()},progress:{_ in});preconditionFailure("accepted pending receipt cannot resume dispatch")}catch{checks+=1}
  check(pendingAPI.posts==0 && PendingReelRequest.load(pending.context) != nil,"batch continuation cannot duplicate held generation")
  let badContext=PendingReelRequest.Context(listingID:first.context.listingID,serverListingID:first.context.serverListingID,owner:"foreign-owner",workspace:first.context.workspace)
  let foreignBatch=try PendingReelBatch.load(badContext)
  check(foreignBatch==nil,"batch progress cannot cross account ownership")
  finished.clear();check(!PendingReelBatch.exists(first.context),"finished batch retirement is scoped to exact batch")
  check(batchAPI.submissions.allSatisfy{$0.framing==nil},"legacy saved batch never invents preserve-photo provider routing")
  let(full,fullAPI,fullDir)=setup();full.clear()
  let fullBatch=PendingReelBatch(context:full.context,id:UUID(),photos:[.init(id:"full-1",jpegBase64:source.base64EncodedString(),shot:nil),.init(id:"full-2",jpegBase64:second.base64EncodedString(),shot:nil)],motion:"fly_through",aspect:"9:16",spaceType:"real_estate",completedPaths:[],framing:"preserve_photo")
  try fullBatch.save();fullAPI.expectedContext=full.context
  let fullFinished:PendingReelBatch
  do{fullFinished=try await ReelReceiptHarness.completeSavedBatch(fullBatch,api:fullAPI,into:fullDir,requireCurrent:{try Task.checkCancellation()},progress:{_ in})}catch{preconditionFailure("saved whole-scene batch resumes exact full sources and framing")}
  check(fullAPI.posts==2 && fullAPI.submissions.allSatisfy{$0.framing=="preserve_photo" && $0.outputAspect=="9:16"},"saved whole-scene batch resumes exact full sources and framing")
  check(fullAPI.submissions.map(\.image)==[source.base64EncodedString(),second.base64EncodedString()] && fullAPI.driftRequests.map(\.sourceBase64)==fullAPI.submissions.map(\.image),"raw QC uses the same complete source before any delivery matte")
  check(fullFinished.framing=="preserve_photo" && fullFinished.completedPaths.count==2,"whole-scene framing remains durable through completed batch progress")
  let badFraming=PendingReelRequest(context:full.context,photoNumber:1,job:full.job,sourceJPEGBase64:source.base64EncodedString(),sourceSpaceType:"real_estate",qualityAttempt:0,framing:"invent_room",outputAspect:"9:16");try badFraming.save()
  check(PendingReelRequest.load(full.context)==nil && PendingReelRequest.exists(full.context),"unsupported saved framing stays blocked for review instead of dispatching")
  PendingReelRequest.forget(full.context);fullFinished.clear()
  OriginalPhotoMotion.reset();ReelPollClock.reset();return checks
 }

 @MainActor static func largeBatch(root:URL) async throws -> Int {
  var checks=0
  func check(_ condition:@autoclosure()->Bool,_ message:String){precondition(condition(),message);checks+=1}
  func context()->PendingReelRequest.Context {.init(listingID:UUID(),serverListingID:UUID(),owner:"large-synthetic-owner",workspace:UUID())}
  let hundred=context()
  let photos=(0..<100).map{PendingReelBatch.Photo(id:"large-\($0)",jpegBase64:Data("exact photo \($0)".utf8).base64EncodedString(),shot:nil)}
  let full=PendingReelBatch(context:hundred,id:UUID(),photos:photos,motion:"fly_through",aspect:"16:9",spaceType:"real_estate",completedPaths:[],framing:"preserve_photo")
  try full.save()
  let loaded:PendingReelBatch
  do{guard let value=try PendingReelBatch.load(hundred) else{preconditionFailure("100-photo recipe reloads without an eight-photo cap")};loaded=value}
  catch{preconditionFailure("100-photo recipe reloads without an eight-photo cap")}
  check(loaded.photos.map(\.id)==photos.map(\.id) && loaded.photos.map(\.jpegBase64)==photos.map(\.jpegBase64),"100-photo recipe retains exact selected order and source bytes")
  let hundredRequest=PendingReelRequest(context:hundred,photoNumber:100,job:.init(requestId:"large-last",statusUrl:"synthetic-status",responseUrl:"synthetic-response",kind:"reel"),sourceJPEGBase64:photos[99].jpegBase64,framing:"preserve_photo",outputAspect:"16:9")
  try hundredRequest.save()
  check(PendingReelRequest.load(hundred)?.photoNumber==100,"photo 100 accepted receipt remains recoverable")
  PendingReelRequest.forget(hundred);full.clear()
  for aspect in ["9:16","16:9"] {
   OriginalPhotoMotion.reset();ReelPollClock.reset();ClipFrames.answerNoFrames=false
   let ctx=context(),selected=Array(photos.prefix(12)).enumerated().map { index, photo in
    let motion=["side_glide","pull_back","fly_through","push_in"][index % 4]
    let shot=AIShot(photoID:photo.id,order:index+1,motion:motion,room:nil,onScreenText:nil,seconds:5,voiceLine:nil)
    return PendingReelBatch.Photo(id:photo.id,jpegBase64:photo.jpegBase64,shot:.init(shot),sourceAssetID:UUID().uuidString,photoProvenanceID:UUID().uuidString)
   }
   let api=ClipAPI(URL(string:CommandLine.arguments[1]+"/quality")!);api.expectedContext=ctx;api.allowQualityRetry=true;api.allowScenePlan=true
   let batch=PendingReelBatch(context:ctx,id:UUID(),photos:selected,motion:"fly_through",aspect:aspect,spaceType:"real_estate",completedPaths:[],framing:"preserve_photo",scenePlanVersion:1,scenePlanningNotice:"Closed scene plan",automaticOrder:true,usedPlanningFallback:false)
   try batch.save()
   let dir=root.appendingPathComponent("large-"+UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
   let finished:PendingReelBatch
   do{finished=try await ReelReceiptHarness.completeSavedBatch(batch,api:api,into:dir,requireCurrent:{try Task.checkCancellation()},progress:{_ in})}
   catch{preconditionFailure("large batch continuation retains every selected photo in order")}
   check(api.posts==12 && api.submissions.map(\.index)==Array(0..<12).map{Optional($0)} && api.submissions.map(\.image)==selected.map(\.jpegBase64),"large batch continuation retains every selected photo in order")
   check(api.submissions.map(\.motion)==selected.map{$0.shot?.motion},"resumed scene plan sends each immutable per-photo camera motion")
   check(api.submissions.allSatisfy{$0.count==12 && $0.outputAspect==aspect && $0.framing=="preserve_photo"},"large batch sends selected canvas and full-source framing on every clip")
   check(finished.completedPaths.count==12 && finished.photos.map(\.id)==selected.map(\.id),"large saved recipe preserves all finished positions")
   check(finished.completedSources?.map(\.photoVersionID)==selected.map(\.id) && finished.completedSources?.map(\.photoAssetID)==selected.map(\.sourceAssetID) && api.driftRequests.map(\.sourceAssetID)==selected.map(\.sourceAssetID),"private photo versions and provider/QC identities survive exact ordered batch completion")
   let again=try await ReelReceiptHarness.completeSavedBatch(batch,api:api,into:dir,requireCurrent:{try Task.checkCancellation()},progress:{_ in})
   check(again.completedPaths==finished.completedPaths && api.posts==12,"reopening a completed large recipe submits no extra clips")
   finished.clear()
  }
  let oversized=context(),target=PendingReelBatch.file(oversized)
  try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
  FileManager.default.createFile(atPath:target.path,contents:nil)
  let handle=try FileHandle(forWritingTo:target);try handle.truncate(atOffset:UInt64(VideoSelectionCapacity.maximumRecipeBytes+1));try handle.close()
  do{_ = try PendingReelBatch.load(oversized);preconditionFailure("oversized recipe is rejected before reading the file")}
  catch{check(error.localizedDescription.contains("too large to open safely"),"oversized recipe is rejected before reading the file")}
  try FileManager.default.removeItem(at:target)
  return checks
 }
}
