#!/usr/bin/env python3
"""Run actual banner/notification admission bodies with closed Foundation OS doubles."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--evidence-dir',type=Path);args=a.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-work-integration-'));out.mkdir(parents=True,exist_ok=True)
paths=[root/'apps/ios/Rendprop/Render/ReelWorkBanner.swift',root/'apps/ios/Rendprop/Push/PushManager.swift',root/'apps/ios/Rendprop/RendpropApp.swift',root/'apps/ios/tests/ReelWorkIntegrationTests.swift',Path(__file__).resolve(),root/'apps/ios/Rendprop/Photos/PhotoWorkBanner.swift',root/'apps/ios/Rendprop/Photos/PhotoEditService.swift',root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',root/'apps/ios/Rendprop/Networking/PropertyVideoJobsAPI.swift']
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths}
before=hashes();banner,push,app=[p.read_text()for p in paths[:3]]
photo_banner,photo_edit=[p.read_text()for p in paths[5:7]]
video_api=paths[8].read_text()
def block(s,anchor):
 assert s.count(anchor)==1,anchor
 start=s.index(anchor);begin=s.index('{',start);depth=0;quoted=False;escaped=False
 for i in range(begin,len(s)):
  c=s[i]
  if quoted:
   if escaped:escaped=False
   elif c=='\\':escaped=True
   elif c=='"':quoted=False
   continue
  if c=='"':quoted=True;continue
  if c=='{':depth+=1
  if c=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise RuntimeError('Unclosed '+anchor)
# These consumer bindings accompany extracted-body execution. Actual SwiftUI
# rendering and the queue engine remain separate real build/engine proofs.
assert 'PhotoWorkBanner()\n            ReelWorkBanner()\n            tabs.id' in app
assert 'UNUserNotificationCenter.current().delegate = PushDelegate.shared' in block(app,'didFinishLaunchingWithOptions launchOptions:')
assert 'hasRestoredLibrary = true' in block(app,'    func load() async {')
assert 'push.pendingContextNotice?.message' in app and 'notice.actionTitle' in app
assert 'notificationIdentifier: response.notification.request.identifier' in push
assert 'content.userInfo = ["recipient_user_id": owner.uuidString, "category": "photo_done",' in photo_edit
assert '"workspace_id": workspace.uuidString, "listing_id": job.listingID.uuidString' in photo_edit
assert 'push.pendingPhotoReview?.listingID.uuidString' in photo_banner and 'WorkspaceContext.selectedOrgID?.uuidString' in photo_banner
assert 'model.isInSelectedWorkspace($0)' in block(photo_banner,'private func reviewPendingNotification()')
assert 'ReelWorkQueue.shared.resumeForeground()' in block(app,'.onChange(of: scenePhase)')
for anchor in ['.onChange(of: analyticsAuth.syncSessionRevision)','.onChange(of: reelConsent.isGranted)']:
 assert 'ReelWorkQueue.shared.reconcileIdentity()'in block(app,anchor)
app_reel_lifecycle=app[:app.index('            // Universal Links.')]
assert 'ReelWorkQueue.shared.reconcileIdentity()'in block(app_reel_lifecycle,'.onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged))')
assert '.sheet(item: Binding(get: { currentReviewListing }'in banner
assert 'ReelWorkReviewAdmission.presentedJob(jobID: id, jobs: jobs.jobs' in block(banner,'private var currentReviewListing:')
assert 'NativePresentationAvailability.hasPresentedController'in block(banner,'private func open(')
assert 'visibleJobs: jobs.reviewableJobs'in block(banner,'private func open(')
assert 'Task.sleep(nanoseconds: 500_000_000)'in block(banner,'private func reviewPendingNotification()')
assert 'while !model.hasRestoredLibrary && !Task.isCancelled' in block(banner,'private func reviewPendingNotification()')
assert '.task(id: pendingReviewJobID) { await reviewPendingBanner() }' in banner
assert 'var body: some View {\n        VStack(spacing: 0) {' in banner
assert 'if let job = ReelWorkReviewAdmission.bannerJob(visibleJobs: jobs.visibleJobs, listings: model.listings)' in banner
assert 'reviewingJob: job' in banner and 'Text(job.title)' in banner
assert 'Button("Notify me when ready") { Task { await push.requestAuthorization() } }'in banner
assert 'requestAuthorization'in banner and banner.count('requestAuthorization')==1
assert 'if value == nil { reviewJobID = nil }'in banner
assert 'pendingReelJobID = nil'in block(push,'func accountWillChange(')
remote_review=block(banner,'    private func reviewPendingServerVideo()')
assert 'await api.notifiedPropertyVideoJob(target.jobID, context: probe)' in remote_review
assert 'PushManager.currentIdentity?.owner == target.owner' in remote_review
assert 'WorkspaceContext.selectedOrgID == selected' in remote_review
assert 'RemoteVideoNotificationReview.permits(reply: reply, target: target, listing: listing, selected: selected)' in remote_review
assert 'showSwitchLibraryNotice(member.displayName)' in remote_review
assert 'showUnavailableVideoNotice()' in remote_review
assert 'try await PropertyVideoJobHTTP.perform("GET", context: context, jobID: jobID)' in block(video_api,'    @MainActor func notifiedPropertyVideoJob(')
assert 'PropertyVideoJobHTTP.download(result, requireCurrent:' in block(banner,'    private func load(refresh: Bool)')
body='import Foundation\n'+block(banner,'enum ReelWorkBannerCopy {')+'\n'+block(banner,'@MainActor enum ReelWorkReviewAdmission {')+'\n'+block(push,'struct PhotoReviewTarget: Hashable {')+'\n'+block(push,'enum NotificationContextNotice: Equatable {')+'\n'+block(push,'enum ReelCompletionNotice {')+'\n'
body+=block(push,'struct ServerVideoReviewTarget: Hashable {')+'\n'
body+='@MainActor enum RemoteVideoNotificationReview {\n'+block(banner,'    static func permits(reply:')+'\n}\n'
body+='''@MainActor final class PushManager {
 static let shared=PushManager()
 static var currentIdentity:PushAccountIdentity?
 static let isSuppressed=false
 var localDataErasureRevision:UInt64=0
 var pendingRoute:PushRoute?;var pendingReelJobID:UUID?;var pendingServerVideoReview:ServerVideoReviewTarget?;var pendingPhotoReview:PhotoReviewTarget?;var pendingContextNotice:NotificationContextNotice?
'''
for anchor in ['    static func accepts(payload:','    private static func safeNotificationCopy(','    func handle(payload:','    func clearPendingReelJob()','    func clearPendingServerVideoReview()','    func clearPendingPhotoReview()','    func clearPendingContextNotice()','    func showUnavailableVideoNotice()','    func showUnavailablePhotoNotice()','    func showSwitchPhotoLibraryNotice(']:
 body+=block(push,anchor)+'\n'
body+='}\n'
body+='''@MainActor final class ReviewJobs {
 var visibleJobs:[ReelWorkJob]=[];var restoredJobs:[ReelWorkJob]=[];var restoreCount=0
 var reviewableJobs:[ReelWorkJob]{visibleJobs.filter(\\.isContextCurrent)};var jobs:[ReelWorkJob]{visibleJobs}
 func restoreServerJobs(model:ReviewModel){restoreCount+=1;if model.hasRestoredLibrary{visibleJobs.append(contentsOf:restoredJobs)}}
}
@MainActor enum Config {static var useLiveBackend=true}
@MainActor enum WorkspaceContext {static var selectedOrgID:UUID?}
struct ReviewMembership {let id:UUID;let canRead:Bool;let displayName:String}
@MainActor final class ReviewWorkspace {
 var allowed:Set<UUID>=[];var afterRefresh:Set<UUID>=[];var refreshCount=0
 var selectionChoices:[ReviewMembership]{allowed.map{.init(id:$0,canRead:true,displayName:"Test library")}}
 func canViewLibrary(_ id:UUID)->Bool{allowed.contains(id)}
 func refresh()async{refreshCount+=1;allowed=afterRefresh}
}
@MainActor final class ReviewModel {
 var listings:[Listing]=[];var hasRestoredLibrary=false;var workspace:ReviewWorkspace?
 func isInSelectedWorkspace(_ listing:Listing)->Bool{
  guard let selected=WorkspaceContext.selectedOrgID else{return false}
  return listing.workspaceID==selected && workspace?.canViewLibrary(selected)==true
 }
}
@MainActor enum NativePresentationAvailability {static var hasPresentedController=false}
@MainActor final class BannerReviewHarness {
let jobs=ReviewJobs();let model=ReviewModel()
let push=PushManager.shared
var reviewListing:Listing?;var reviewJobID:UUID?;var pendingReviewJobID:UUID?
'''+block(banner,'    private func open(').replace('private func','func',1)+'\n'+block(banner,'    private func reviewPendingBanner()').replace('private func','func',1)+'\n'+block(banner,'    private func reviewPendingNotification()').replace('private func','func',1)+'\n}\n'
body+='''@MainActor final class PhotoReviewHarness {
 let workspace=ReviewWorkspace();let model=ReviewModel();let push=PushManager.shared
 var reviewListing:Listing?
 init(){model.workspace=workspace}
'''+block(photo_banner,'    private func reviewPendingNotification()').replace('private func','func',1)+'\n}\n'
screen=paths[7].read_text();reel=screen[screen.index('struct ReelStudioView:'):]
initializer=block(reel,'    init(listing: Listing, photos: [EnhancedPhoto], extraClipURLs: [URL] = [], reviewingJob: ReelWorkJob? = nil)')
last=block(reel,'if !reviewingExistingJob { lastReel = Self.newestReel(for: listing.id) }')
parked=block(reel,'if !reviewingExistingJob, !listing.isSample { parkedClips = PendingReelClips.load(for: listing.id) }')
restore=block(reel,'if !reviewingExistingJob {\n                reloadPendingRequest()')
body+='''struct EnhancedPhoto {}
@propertyWrapper struct State<Value> {var wrappedValue:Value;init(initialValue:Value){wrappedValue=initialValue}}
enum PendingReelClips {static func load(for id:UUID)->String?{"other-run-clips"}}
@MainActor final class ReelWorkQueue {
static let shared=ReelWorkQueue();var requested=0
func job(for listing:Listing)->ReelWorkJob{requested+=1;return ReelWorkJob(UUID(),listing.id)}
}
@MainActor final class ReviewStudioHarness {
let listing:Listing;let photos:[EnhancedPhoto];let extraClipURLs:[URL]
let work:ReelWorkJob;let reviewingExistingJob:Bool
@State var photoMotion=false;@State var photoMotionProfile=PhotoMotionContract.Profile.current;@State var photoMotionDirection=PhotoMotionContract.Direction.pushIn;@State var photoMotionAutomatic=true
var lastReel:URL?;var parkedClips:String?;var reloads=0;var purposeRestores=0;var serverRestores=0
'''+initializer+'''
static func newestReel(for id:UUID)->URL?{URL(fileURLWithPath:"/unrelated-newest-file.mp4")}
func reloadPendingRequest(){reloads+=1}
func restoreVideoPurposeForSavedWork(){purposeRestores+=1}
func restoreServerVideoJob(){serverRestores+=1}
func appeared(){
'''+last+'\n'+parked+'\n'+restore+'\n}\n}\n'
controls=[
 ('unknown-job', '$0.id == jobID', '$0.id == $0.id', 'unknown job cannot open another existing listing'),
 ('lost-server-alias', '$0.serverJob?.reply?.jobID == jobID', 'false', 'accepted server job alias opens only its exact owned listing'),
 ('lost-server-ready', 'if type == "render_ready", facts["property_video_job_id"] != nil {', 'if false {', 'server-ready notification retains exact job for authenticated review'),
 ('wrong-listing', '$0.id == job.listingID', '$0.id == $0.id', 'job cannot route to a different listing'),
 ('sample-review', '!listing.isSample, listing.cloudUnavailable != true', 'true, listing.cloudUnavailable != true', 'sample listing cannot receive real job result'),
 ('unavailable-review', 'listing.cloudUnavailable != true', 'true', 'unavailable listing cannot be reopened by notification'),
 ('false-paused-title', 'if paused { return "Video paused" }', 'if paused { return "Your video is ready" }', 'expired OS execution is not advertised as completed'),
 ('false-failed-playback', 'if ready { return "Open the video to watch it." }', 'if true { return "Open the video to watch it." }', 'failed work cannot advertise a playable result'),
 ('lost-job-payload', 'content.userInfo["reel_job_id"] = jobID.uuidString', 'content.userInfo["reel_job_id"] = "invalid"', 'completion payload preserves exact job and listing identity'),
 ('foreign-recipient', 'guard !Self.isSuppressed, Self.accepts(payload: payload, identity: Self.currentIdentity) else { return }', 'guard !Self.isSuppressed else { return }', 'foreign recipient cannot route a reel'),
 ('late-owner-switch', 'guard PushManager.currentIdentity == identity,', 'guard true,', 'account replacement during OS settings cannot enqueue old result'),
 ('late-local-erasure', 'PushManager.shared.localDataErasureRevision == erasureRevision,', 'true,', 'local erasure during OS settings suppresses the earlier reel notice'),
 ('late-foreground', 'UIApplication.shared.applicationState != .active else { return }\n                let content', 'true else { return }\n                let content', 'foreground return during settings suppresses completion notification'),
 ('lost-modal-review-intent', 'pendingReviewJobID = id', '// dropped manual review intent', 'a modal retains the exact manual Review job instead of dropping the tap'),
 ('wrong-pending-review-job', '                open(id)\n                return', '                open(jobs.visibleJobs.last!.id)\n                return', 'deferred Review opens its originally requested job, not another ready job'),
 ('wrong-review-studio-job', 'let restored = reviewingJob ?? ReelWorkQueue.shared.job(for: listing)', 'let restored = ReelWorkQueue.shared.job(for: listing)', 'explicit Review binds the exact retained work object'),
 ('review-newest-substitution', 'if !reviewingExistingJob { lastReel = Self.newestReel(for: listing.id) }', 'if true { lastReel = Self.newestReel(for: listing.id) }', 'explicit Review cannot replace its retained result with the newest file'),
 ('review-rebinds-server-job', 'if !reviewingExistingJob {\n                reloadPendingRequest()', 'if true {\n                reloadPendingRequest()', 'explicit Review cannot rebind a different saved request on appearance'),
 ('ghost-review-banner', 'visibleJobs.filter { listing(jobID: $0.id, visibleJobs: visibleJobs, listings: listings) != nil }', 'visibleJobs', "a removed or unavailable home's job cannot expose a dead Review banner"),
 ('review-rebinds-other-clips', 'if !reviewingExistingJob, !listing.isSample { parkedClips = PendingReelClips.load(for: listing.id) }', 'if !listing.isSample { parkedClips = PendingReelClips.load(for: listing.id) }', 'explicit Review cannot substitute listing-wide clips from another run'),
 ('cold-reel-restore-wait', 'while !model.hasRestoredLibrary && !Task.isCancelled', 'while false', 'cold tap keeps exact job intent while the saved library is still restoring'),
 ('missing-photo-route', 'if type == "photo_done" {', 'if type == "absent_photo_done" {', 'photo tap stages the exact listing and workspace'),
 ('missing-team-refresh', 'await workspace.refresh()', 'await Task.yield()', 'current authorized team library can reopen its own edit after fresh membership'),
 ('bypassed-team-authority', '&& model.isInSelectedWorkspace($0)', '&& true', 'revoked team library cannot reopen an old edit'),
 ('bypassed-photo-owner', 'guard PushManager.currentIdentity?.owner == target.owner else {', 'guard true else {', "a second actor in the same team cannot use the initiator's staged photo target"),
 ('missing-old-photo-fallback', 'if type.isEmpty, notificationIdentifier?.hasPrefix("photo-work.") == true {', 'if false {', 'already-delivered older photo notification shows a clear fallback instead of silent Home'),
 ('missing-old-ops-context', 'if type == "ops_alert" {', 'if false {', 'an already-delivered ops alert explains its missing in-app destination without guessing a listing'),
 ('remote-wrong-job', 'reply.jobID == target.jobID', 'true', 'remote review refuses a different job'),
 ('remote-wrong-listing', 'reply.listingID == target.listingID', 'true', 'remote review refuses a server reply for a different listing'),
 ('remote-wrong-library', 'reply.selectedLibraryOrgID == selected', 'true', 'remote review refuses another selected library'),
 ('remote-wrong-physical-org', 'listing.serverOrgID == reply.orgID', 'true', 'remote review refuses a wrong physical content organization'),
 ('remote-unfinished', 'reply.state == "ready"', 'true', 'an unfinished job cannot display a ready preview'),
 ('remote-incomplete-source', 'result.sources.allSatisfy(\\.isComplete)', 'true', 'an incomplete source cannot authorize a remote preview'),
 ('remote-insecure-url', 'url.scheme == "https"', 'true', 'remote review refuses an insecure media URL'),
 ('unsafe-unknown-copy', 'copy.utf8.count <= limit', 'true', 'control characters and oversized OS copy cannot become in-app notice text'),
]
def inject_control(name, old, new):
 # The exact-job adapter deliberately repeats the same identity predicate.
 # Corrupt the original listing admission being tested, not a now-redundant
 # lookup protected by that admission, preserving the existing named oracle.
 if name in ['unknown-job','lost-server-alias']:
  target=block(body,'    static func listing(')
  assert old in target
  return body.replace(target,target.replace(old,new,1),1)
 return body.replace(old,new,1)
variants=[('actual',body,None)]+[(n,inject_control(n,old,new),reason)for n,old,new,reason in controls]
receipt={'passed':False,'sourceHashes':before,'runs':[],'externalRequests':0,'limitations':['Actual copy/admission/notice/tap methods with closed OS and listing/job doubles. No live APNs, actual OS suspension, SwiftUI rendering or queue execution proof; those require separate app/engine/phone checks.']}
try:
 for name,source,expected in variants:
  assert expected is None or source!=body,name+' mutation anchor absent'
  folder=out/name;folder.mkdir(exist_ok=True);production=folder/'Production.swift';production.write_text(source);binary=folder/'gate'
  c=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(production),str(paths[3]),'-o',str(binary)],capture_output=True,text=True,timeout=180)
  (folder/'compile.log').write_text(c.stdout+c.stderr)
  assert c.returncode==0,name+' compile failed: '+c.stderr
  run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30);log=run.stdout+run.stderr;(folder/'runtime.log').write_text(log)
  ok=run.returncode==0 if expected is None else run.returncode!=0 and 'Precondition failed: '+expected in log
  receipt['runs'].append({'case':name,'compileExit':c.returncode,'runtimeExit':run.returncode,'passed':ok,'expected':expected})
  binary.unlink()
  assert ok,name+' oracle failed: '+log
except BaseException as e:
 receipt['failure']=str(e);raise
finally:
 receipt['finalSourceHashes']=hashes();receipt['sourceBindingMatches']=before==receipt['finalSourceHashes']
 receipt['passed']='failure'not in receipt and len(receipt['runs'])==len(variants)and all(r['passed']for r in receipt['runs'])and receipt['sourceBindingMatches']
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert receipt['passed'],'Source changed during integration checks'
print((out/'actual/runtime.log').read_text().strip())
print(f'PASS: {len(controls)} compiled controls; receipt: {out / "receipt.json"}')
