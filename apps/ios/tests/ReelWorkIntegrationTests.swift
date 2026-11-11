import Foundation

struct ClosedServerJob {
 struct Reply { let jobID:UUID }
 struct Source { var motion:String }
 struct Request { var isPhotoMotion=false;var photoMotionProfile:PhotoMotionContract.Profile = .current;var sources:[Source]=[] }
 var reply:Reply?;var request=Request()
}
enum PhotoMotionContract {
 enum Profile {case current,opening}
 enum Direction:String {case pushIn="push_in"}
 static func isAutomaticSequence(_ sources:[ClosedServerJob.Source])->Bool{false}
}
@MainActor final class ReelWorkJob {
 enum Phase {case setup,done}
 var serverJob:ClosedServerJob?;var running=false;var isServerRendering=false;var paused=false;var isContextCurrent=true
 var configuration:String?;var phase=Phase.setup
 let id:UUID; let listingID:UUID; init(_ id:UUID,_ listingID:UUID){self.id=id;self.listingID=listingID}
}
struct Listing { let id:UUID; var isSample=false; var cloudUnavailable:Bool?; var workspaceID:UUID?; var serverID:UUID?; var serverOrgID:UUID?;var serverLibraryOrgID:UUID? }
struct ListingVideoSource { let isComplete:Bool }
struct PropertyVideoJobResult {
 let downloadURL:URL?;let width:Int;let height:Int;let durationS:Double;let bytes:Int64;let sha256:String
 let sources:[ListingVideoSource];let originalPhotoCount:Int;let sourceMode:String?;let compositionProfile:String?
}
struct PropertyVideoJobReply {
 let jobID:UUID;let listingID:UUID;let selectedLibraryOrgID:UUID;let orgID:UUID;let state:String
 let sourceCount:Int;let manifestSHA256:String;let result:PropertyVideoJobResult?;let sourceMode:String?;let compositionProfile:String?
}
struct PushAccountIdentity:Equatable {let owner:UUID;let revision:UInt64}
@MainActor final class UIApplication {enum State {case active,inactive,background};static let shared=UIApplication();var applicationState=State.background}
enum UNAuthorizationStatus {case notDetermined,denied,authorized,provisional,ephemeral}
struct UNNotificationSettings {let authorizationStatus:UNAuthorizationStatus}
struct UNNotificationSound {static let `default`=Self()}
final class UNMutableNotificationContent {var title="",body="";var sound:UNNotificationSound?;var userInfo:[AnyHashable:Any]=[:]}
struct UNNotificationRequest {let identifier:String;let content:UNMutableNotificationContent;let trigger:String?}
@MainActor final class UNUserNotificationCenter {
 static let center=UNUserNotificationCenter();static func current()->UNUserNotificationCenter{center}
 var callbacks:[(UNNotificationSettings)->Void]=[];var requests:[UNNotificationRequest]=[]
 func getNotificationSettings(completionHandler:@escaping(UNNotificationSettings)->Void){callbacks.append(completionHandler)}
 func answer(_ status:UNAuthorizationStatus){callbacks.removeFirst()(.init(authorizationStatus:status))}
 func add(_ request:UNNotificationRequest){requests.append(request)}
 func reset(){callbacks=[];requests=[]}
}
struct DeepLink:Equatable {let url:URL;static func parse(_ url:URL)->Self?{.init(url:url)}}
enum PushRoute:Equatable {case leads,tour(DeepLink)}

@main struct ReelWorkIntegrationTests {
 @MainActor static func main() async {
  var checks=0
  func check(_ ok:Bool,_ why:String){precondition(ok,why);checks+=1}
  func tick()async{for _ in 0..<25{await Task.yield()}}
  let id=UUID(), listingID=UUID(), wrongID=UUID()
  let job=ReelWorkJob(id,listingID), listing=Listing(id:listingID)
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[listing])?.id==listingID,"existing current job opens its exact listing")
  check(ReelWorkReviewAdmission.job(jobID:id,visibleJobs:[job],listings:[listing]) === job,"review admission returns the existing work object")
  check(ReelWorkReviewAdmission.listing(jobID:wrongID,visibleJobs:[job],listings:[listing])==nil,"unknown job cannot open another existing listing")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[],listings:[listing])==nil,"hidden old-context job cannot be reviewed")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[])==nil,"deleted listing cannot be reviewed")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:wrongID)])==nil,"job cannot route to a different listing")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:listingID,isSample:true)])==nil,"sample listing cannot receive real job result")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:listingID,cloudUnavailable:true)])==nil,"unavailable listing cannot be reopened by notification")
  let serverID=UUID()
  job.serverJob = .init(reply:.init(jobID:serverID))
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[listing])?.id==listingID,"accepted server job alias opens only its exact owned listing")
  check(ReelWorkReviewAdmission.job(jobID:serverID,visibleJobs:[job],listings:[listing]) === job,"server notification alias resolves its exact retained work")
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[],listings:[listing])==nil,"hidden server job alias cannot reopen an old account listing")
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[.init(id:wrongID)])==nil,"server alias cannot substitute another existing listing")
  job.serverJob=nil
  // A global Review tap can race the dismissal of a feature sheet. It must
  // wait with its original job intent, never pick whatever finishes next.
  let banner=BannerReviewHarness(), otherJob=ReelWorkJob(UUID(),wrongID)
  otherJob.isServerRendering=true
  check(ReelWorkReviewAdmission.bannerJob(visibleJobs:[job,otherJob],listings:[listing]) === job,"a removed or unavailable home's job cannot expose a dead Review banner")
  check(ReelWorkReviewAdmission.bannerJob(visibleJobs:[job,otherJob],listings:[listing,.init(id:wrongID)]) === otherJob,"a current available server job retains priority over older ready work")
  check(ReelWorkReviewAdmission.bannerJob(visibleJobs:[job],listings:[])==nil,"a deleted home cannot leave an unusable ready banner")
  banner.jobs.visibleJobs=[job,otherJob];banner.model.listings=[listing,.init(id:wrongID)]
  NativePresentationAvailability.hasPresentedController=true
  banner.open(id)
  check(banner.pendingReviewJobID==id && banner.reviewJobID==nil,"a modal retains the exact manual Review job instead of dropping the tap")
  let deferred=Task {await banner.reviewPendingBanner()};await tick()
  check(banner.reviewJobID==nil,"Review does not interrupt the current modal")
  NativePresentationAvailability.hasPresentedController=false;await deferred.value
  check(banner.reviewJobID==id && banner.reviewListing?.id==listingID && banner.pendingReviewJobID==nil,"deferred Review opens its originally requested job, not another ready job")
  let hidden=BannerReviewHarness();hidden.jobs.visibleJobs=[job];hidden.model.listings=[listing]
  NativePresentationAvailability.hasPresentedController=true;hidden.open(id)
  hidden.jobs.visibleJobs=[];await hidden.reviewPendingBanner()
  check(hidden.reviewJobID==nil && hidden.pendingReviewJobID==nil,"account or listing removal retires a deferred Review without substitution")
  NativePresentationAvailability.hasPresentedController=false
  let queue=ReelWorkQueue.shared,prior=queue.requested
  let review=ReviewStudioHarness(listing:listing,photos:[],reviewingJob:job)
  check(review.work === job && queue.requested==prior,"explicit Review binds the exact retained work object")
  let retained=URL(fileURLWithPath:"/the-reviewed-job.mp4");review.lastReel=retained;review.parkedClips="exact-reviewed-run";review.appeared()
  check(review.lastReel==retained,"explicit Review cannot replace its retained result with the newest file")
  check(review.reloads==0 && review.purposeRestores==0 && review.serverRestores==0,"explicit Review cannot rebind a different saved request on appearance")
  check(review.parkedClips=="exact-reviewed-run","explicit Review cannot substitute listing-wide clips from another run")
  let ordinary=ReviewStudioHarness(listing:listing,photos:[]);ordinary.appeared()
  check(queue.requested==prior+1 && ordinary.reloads==1 && ordinary.purposeRestores==1 && ordinary.serverRestores==1,"ordinary Make video keeps its existing saved-work restoration")
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[listing])==nil,"cleared server job receipt cannot reopen its former result")
  check(ReelWorkBannerCopy.title(running:true,paused:false,ready:false,stitching:false,completed:3,total:8)=="Making video · 3 of 8 photos ready","banner counts actual selected photos")
  check(ReelWorkBannerCopy.title(running:true,paused:false,ready:false,stitching:true,completed:8,total:8).hasPrefix("Finishing video"),"stitching is not advertised as completed")
  check(ReelWorkBannerCopy.title(running:false,paused:true,ready:false,stitching:false,completed:3,total:8)=="Video paused","expired OS execution is not advertised as completed")
  check(ReelWorkBannerCopy.explanation(paused:true,running:false).contains("iOS paused local processing") && ReelWorkBannerCopy.explanation(paused:true,running:false).contains("saved requests"),"paused copy explains retained recoverable work")
  check(ReelWorkBannerCopy.explanation(paused:false,running:true).contains("may pause local processing"),"running copy does not promise killed-process completion")
  check(ReelWorkBannerCopy.title(running:false,paused:false,ready:false,stitching:false,completed:2,total:2)=="Video needs attention","interrupted server work is not a finished review")
  check(!ReelWorkBannerCopy.explanation(paused:false,running:false,ready:false).contains("watch"),"failed work cannot advertise a playable result")
  check(ReelWorkBannerCopy.explanation(paused:false,running:false,ready:true).contains("watch"),"only ready video offers playback")
  let launchPush=PushManager.shared
  let cold=BannerReviewHarness()
  launchPush.pendingReelJobID=id
  cold.jobs.restoredJobs=[job]
  let coldReview=Task {await cold.reviewPendingNotification()};await tick()
  check(launchPush.pendingReelJobID==id && cold.jobs.restoreCount==0 && cold.reviewJobID==nil,"cold tap keeps exact job intent while the saved library is still restoring")
  cold.model.listings=[listing];cold.model.hasRestoredLibrary=true
  await coldReview.value
  check(cold.reviewJobID==id && cold.reviewListing?.id==listingID && launchPush.pendingReelJobID==nil,"cold tap restores and opens the exact current job")
  let warm=BannerReviewHarness()
  warm.model.listings=[listing];warm.model.hasRestoredLibrary=true;warm.jobs.visibleJobs=[job]
  launchPush.pendingReelJobID=id;await warm.reviewPendingNotification()
  check(warm.reviewJobID==id && warm.reviewListing?.id==listingID && launchPush.pendingReelJobID==nil,"warm tap opens the exact existing job")
  let switched=BannerReviewHarness()
  launchPush.pendingReelJobID=id
  let retired=Task {await switched.reviewPendingNotification()};await tick()
  launchPush.clearPendingReelJob();switched.model.hasRestoredLibrary=true;switched.model.listings=[listing];switched.jobs.restoredJobs=[job]
  await retired.value
  check(switched.reviewJobID==nil && launchPush.pendingReelJobID==nil,"account replacement during cold restore retires the old tap")
  let foreignBanner=BannerReviewHarness(),foreignJob=ReelWorkJob(UUID(),listingID)
  foreignJob.isContextCurrent=false
  foreignBanner.model.listings=[listing];foreignBanner.model.hasRestoredLibrary=true;foreignBanner.jobs.visibleJobs=[foreignJob]
  launchPush.pendingReelJobID=foreignJob.id;await foreignBanner.reviewPendingNotification()
  check(foreignBanner.reviewJobID==nil && launchPush.pendingReelJobID==nil,"a former account or team job cannot open from notification")
  let changedLibrary=BannerReviewHarness()
  changedLibrary.model.listings=[.init(id:listingID,cloudUnavailable:true)];changedLibrary.model.hasRestoredLibrary=true
  changedLibrary.jobs.visibleJobs=[job];launchPush.pendingReelJobID=id;await changedLibrary.reviewPendingNotification()
  check(changedLibrary.reviewJobID==nil && launchPush.pendingReelJobID==nil,"a removed team listing cannot open from notification")
  let owner=PushAccountIdentity(owner:UUID(),revision:1), other=PushAccountIdentity(owner:UUID(),revision:1)
  let push=PushManager(),center=UNUserNotificationCenter.current(),app=UIApplication.shared
  func reset(){center.reset();PushManager.currentIdentity=owner;app.applicationState = .background;push.pendingReelJobID=nil;push.pendingServerVideoReview=nil;push.pendingRoute=nil;push.pendingContextNotice=nil}
  reset();ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id)
  center.answer(.authorized);await tick()
  check(center.requests.count==1,"authorized background completion posts exactly one notice")
  let payload=center.requests[0].content.userInfo
  check(payload["reel_job_id"]as?String==id.uuidString && payload["listing_id"]as?String==listingID.uuidString,"completion payload preserves exact job and listing identity")
  check(!center.requests[0].content.title.contains(listingID.uuidString) && !center.requests[0].content.body.contains(listingID.uuidString),"lock screen remains generic without listing identity text")
  push.handle(payload:payload);check(push.pendingReelJobID==id && push.pendingRoute==nil,"notification tap targets existing reel job rather than a tour")
  push.clearPendingReelJob();check(push.pendingReelJobID==nil,"consumed reel notification is retired")
  push.handle(payload:["recipient_user_id":other.owner.uuidString,"category":"reel_done","reel_job_id":id.uuidString])
  check(push.pendingReelJobID==nil,"foreign recipient cannot route a reel")
  push.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"reel_done","reel_job_id":"not-a-uuid","deep_link":"rendprop://f/ignored"])
  check(push.pendingReelJobID==nil && push.pendingRoute==nil,"malformed reel notification cannot fall through to unrelated tour")
  reset()
  let remote:[AnyHashable:Any] = ["recipient_user_id":owner.owner.uuidString,"category":"render_ready","data":["property_video_job_id":serverID.uuidString,"reel_job_id":serverID.uuidString,"listing_id":listingID.uuidString]]
  push.handle(payload:remote)
  check(push.pendingServerVideoReview?.jobID==serverID && push.pendingRoute==nil,"server-ready notification retains exact job for authenticated review")
  let library=UUID(),physical=UUID(),digest=String(repeating:"a",count:64)
  let remoteTarget=ServerVideoReviewTarget(owner:owner.owner,jobID:serverID,listingID:listingID)
  let remoteListing=Listing(id:listingID,workspaceID:library,serverID:listingID,serverOrgID:physical)
  let result=PropertyVideoJobResult(downloadURL:URL(string:"https://private.example.test/video"),width:1920,height:1080,
      durationS:30,bytes:1_000_000,sha256:digest,sources:[.init(isComplete:true)],originalPhotoCount:0,sourceMode:nil,compositionProfile:nil)
  let reply=PropertyVideoJobReply(jobID:serverID,listingID:listingID,selectedLibraryOrgID:library,orgID:physical,
      state:"ready",sourceCount:1,manifestSHA256:digest,result:result,sourceMode:nil,compositionProfile:nil)
  check(RemoteVideoNotificationReview.permits(reply:reply,target:remoteTarget,listing:remoteListing,selected:library),
        "read-only remote review admits one exact verified ready result")
  check(!RemoteVideoNotificationReview.permits(reply:reply,target:.init(owner:owner.owner,jobID:UUID(),listingID:listingID),listing:remoteListing,selected:library),
        "remote review refuses a different job")
  check(!RemoteVideoNotificationReview.permits(reply:reply,target:.init(owner:owner.owner,jobID:serverID,listingID:UUID()),listing:remoteListing,selected:library),
        "remote review refuses a different listing")
  check(!RemoteVideoNotificationReview.permits(reply:PropertyVideoJobReply(jobID:serverID,listingID:UUID(),
      selectedLibraryOrgID:library,orgID:physical,state:"ready",sourceCount:1,manifestSHA256:digest,
      result:result,sourceMode:nil,compositionProfile:nil),target:remoteTarget,listing:remoteListing,selected:library),
        "remote review refuses a server reply for a different listing")
  check(!RemoteVideoNotificationReview.permits(reply:reply,target:remoteTarget,listing:remoteListing,selected:UUID()),
        "remote review refuses another selected library")
  check(!RemoteVideoNotificationReview.permits(reply:reply,target:remoteTarget,
      listing:Listing(id:listingID,workspaceID:library,serverID:listingID,serverOrgID:UUID()),selected:library),
        "remote review refuses a wrong physical content organization")
  check(!RemoteVideoNotificationReview.permits(reply:PropertyVideoJobReply(jobID:serverID,listingID:listingID,
      selectedLibraryOrgID:library,orgID:physical,state:"generating",sourceCount:1,manifestSHA256:digest,
      result:result,sourceMode:nil,compositionProfile:nil),target:remoteTarget,listing:remoteListing,selected:library),
        "an unfinished job cannot display a ready preview")
  let badSource=PropertyVideoJobResult(downloadURL:result.downloadURL,width:1920,height:1080,durationS:30,bytes:1_000_000,
      sha256:digest,sources:[.init(isComplete:false)],originalPhotoCount:0,sourceMode:nil,compositionProfile:nil)
  check(!RemoteVideoNotificationReview.permits(reply:PropertyVideoJobReply(jobID:serverID,listingID:listingID,
      selectedLibraryOrgID:library,orgID:physical,state:"ready",sourceCount:1,manifestSHA256:digest,
      result:badSource,sourceMode:nil,compositionProfile:nil),target:remoteTarget,listing:remoteListing,selected:library),
        "an incomplete source cannot authorize a remote preview")
  let insecure=PropertyVideoJobResult(downloadURL:URL(string:"http://private.example.test/video"),width:1920,height:1080,
      durationS:30,bytes:1_000_000,sha256:digest,sources:[.init(isComplete:true)],originalPhotoCount:0,sourceMode:nil,compositionProfile:nil)
  check(!RemoteVideoNotificationReview.permits(reply:PropertyVideoJobReply(jobID:serverID,listingID:listingID,
      selectedLibraryOrgID:library,orgID:physical,state:"ready",sourceCount:1,manifestSHA256:digest,
      result:insecure,sourceMode:nil,compositionProfile:nil),target:remoteTarget,listing:remoteListing,selected:library),
        "remote review refuses an insecure media URL")
  push.clearPendingServerVideoReview()
  var foreign=remote;foreign["recipient_user_id"]=other.owner.uuidString
  push.handle(payload:foreign)
  check(push.pendingServerVideoReview==nil && push.pendingRoute==nil,"foreign recipient cannot route a server property video")
  push.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"render_ready","data":["property_video_job_id":serverID.uuidString,"reel_job_id":"invalid"],"deep_link":"rendprop://f/ignored"])
  check(push.pendingServerVideoReview==nil && push.pendingRoute==nil,"malformed server-ready notice cannot fall through to unrelated tour")
  push.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"render_ready","data":["slug":"recorded-tour"],"deep_link":"rendprop://f/recorded-tour"])
  check(push.pendingReelJobID==nil && push.pendingRoute != nil,"ordinary recorded render notification keeps its existing tour route")
  reset();ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id)
  PushManager.currentIdentity=other;center.answer(.authorized);await tick()
  check(center.requests.isEmpty,"account replacement during OS settings cannot enqueue old result")
  reset();ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id)
  PushManager.shared.localDataErasureRevision &+= 1;center.answer(.authorized);await tick()
  check(center.requests.isEmpty,"local erasure during OS settings suppresses the earlier reel notice")
  reset();ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id)
  app.applicationState = .active;center.answer(.authorized);await tick()
  check(center.requests.isEmpty,"foreground return during settings suppresses completion notification")
  for status in [UNAuthorizationStatus.denied,.notDetermined]{
   reset();ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id);center.answer(status);await tick()
   check(center.requests.isEmpty,"completion cannot bypass notification permission")
  }
  reset();app.applicationState = .active;ReelCompletionNotice.post(success:true,identity:owner,listingID:listingID,jobID:id)
  check(center.callbacks.isEmpty,"completion never asks notification permission or posts while active")
  let workspaceID=UUID(),otherWorkspace=UUID()
  let photoListing=Listing(id:listingID,workspaceID:workspaceID)
  let photoPayload:[AnyHashable:Any]=["recipient_user_id":owner.owner.uuidString,"category":"photo_done",
                                     "listing_id":listingID.uuidString,"workspace_id":workspaceID.uuidString]
  WorkspaceContext.selectedOrgID=workspaceID
  launchPush.handle(payload:["recipient_user_id":other.owner.uuidString,"category":"photo_done",
                             "listing_id":listingID.uuidString,"workspace_id":workspaceID.uuidString])
  check(launchPush.pendingPhotoReview==nil,"another account's photo completion cannot stage a review")
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"photo_done",
                             "listing_id":"invalid","workspace_id":workspaceID.uuidString])
  check(launchPush.pendingPhotoReview==nil,"malformed photo target cannot fall through to Home or another listing")
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString],notificationIdentifier:"photo-work.legacy")
  check(launchPush.pendingContextNotice == .olderPhoto && launchPush.pendingPhotoReview == nil,
        "already-delivered older photo notification shows a clear fallback instead of silent Home")
  check(launchPush.pendingContextNotice?.destination == .listings && launchPush.pendingContextNotice?.message.contains("Photos") == true,
        "older photo fallback points to Listings and saved Photos")
  launchPush.clearPendingContextNotice()
  launchPush.handle(payload:["recipient_user_id":other.owner.uuidString],notificationIdentifier:"photo-work.legacy")
  check(launchPush.pendingContextNotice == nil,"an old notification for another actor cannot show review context")
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"ops_alert"])
  check(launchPush.pendingContextNotice == .operations && launchPush.pendingContextNotice?.destination == nil,
        "an already-delivered ops alert explains its missing in-app destination without guessing a listing")
  launchPush.clearPendingContextNotice()
  let serverVideo:[AnyHashable:Any]=["recipient_user_id":owner.owner.uuidString,"category":"render_ready",
      "data":["listing_id":listingID.uuidString,"property_video_job_id":id.uuidString,"reel_job_id":id.uuidString]]
  launchPush.handle(payload:serverVideo)
  check(launchPush.pendingServerVideoReview == .init(owner:owner.owner,jobID:id,listingID:listingID) && launchPush.pendingReelJobID == nil,
        "server ready notice stages its exact actor, job and listing for authenticated review")
  launchPush.clearPendingServerVideoReview()
  launchPush.handle(payload:["recipient_user_id":other.owner.uuidString,"category":"render_ready",
      "data":["listing_id":listingID.uuidString,"property_video_job_id":id.uuidString,"reel_job_id":id.uuidString]])
  check(launchPush.pendingServerVideoReview == nil,"another actor's ready job cannot stage review")
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"render_ready",
      "data":["listing_id":listingID.uuidString,"property_video_job_id":id.uuidString,"reel_job_id":UUID().uuidString]])
  check(launchPush.pendingServerVideoReview == nil && launchPush.pendingContextNotice == .unavailableVideo,
        "mismatched server job aliases fail closed with visible review guidance")
  launchPush.clearPendingContextNotice()
  for category in ["free_week_ending","allowance_low"] {
      launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":category])
      check(launchPush.pendingContextNotice == .planUsage && launchPush.pendingContextNotice?.destination == .account,
            "\(category) opens meaningful plan/account context")
      launchPush.clearPendingContextNotice()
  }
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"upload_stuck"])
  check(launchPush.pendingContextNotice == .uploadStuck && launchPush.pendingContextNotice?.destination == .activity,
        "upload failure opens current activity with retry guidance")
  launchPush.clearPendingContextNotice()
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"first_tour_nudge"])
  check(launchPush.pendingContextNotice == .firstTour && launchPush.pendingContextNotice?.destination == .listings,
        "first-tour reminder opens the listings entry")
  launchPush.clearPendingContextNotice()
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"future_category",
      "aps":["alert":["title":"Saved update","body":"Your saved work changed."]]])
  check(launchPush.pendingContextNotice == .other(title:"Saved update",body:"Your saved work changed.") &&
        launchPush.pendingContextNotice?.destination == .activity &&
        launchPush.pendingContextNotice?.message.contains("Open Activity") == true,
        "unknown matched-recipient push shows bounded OS copy and an honest Activity fallback")
  launchPush.clearPendingContextNotice()
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"future_category",
      "aps":["alert":["title":"Hidden\nroute","body":String(repeating:"x",count:241)]]])
  check(launchPush.pendingContextNotice == .other(title:"Rendprop update",body:"") &&
        launchPush.pendingContextNotice?.destination == .activity,
        "control characters and oversized OS copy cannot become in-app notice text")
  launchPush.clearPendingContextNotice()
  let coldPhoto=PhotoReviewHarness()
  coldPhoto.workspace.allowed=[workspaceID]
  launchPush.handle(payload:photoPayload)
  check(launchPush.pendingPhotoReview?.listingID==listingID,"photo tap stages the exact listing and workspace")
  let coldPhotoReview=Task {await coldPhoto.reviewPendingNotification()};await tick()
  check(coldPhoto.reviewListing==nil && launchPush.pendingPhotoReview?.listingID==listingID,"cold photo tap waits for the saved library")
  coldPhoto.model.listings=[photoListing];coldPhoto.model.hasRestoredLibrary=true
  await coldPhotoReview.value
  check(coldPhoto.reviewListing?.id==listingID && launchPush.pendingPhotoReview==nil,"cold photo tap opens the exact saved listing's Photos screen")
  let warmPhoto=PhotoReviewHarness()
  warmPhoto.workspace.allowed=[workspaceID];warmPhoto.model.listings=[photoListing];warmPhoto.model.hasRestoredLibrary=true
  launchPush.handle(payload:photoPayload);await warmPhoto.reviewPendingNotification()
  check(warmPhoto.reviewListing?.id==listingID && launchPush.pendingPhotoReview==nil,"warm photo tap opens the exact listing")
  let teamPhoto=PhotoReviewHarness()
  teamPhoto.workspace.afterRefresh=[workspaceID];teamPhoto.model.listings=[photoListing];teamPhoto.model.hasRestoredLibrary=true
  launchPush.handle(payload:photoPayload);await teamPhoto.reviewPendingNotification()
  check(teamPhoto.workspace.refreshCount==1 && teamPhoto.reviewListing?.id==listingID,"current authorized team library can reopen its own edit after fresh membership")
  let revokedPhoto=PhotoReviewHarness()
  revokedPhoto.model.listings=[photoListing];revokedPhoto.model.hasRestoredLibrary=true
  launchPush.handle(payload:photoPayload);await revokedPhoto.reviewPendingNotification()
  check(revokedPhoto.workspace.refreshCount==1 && revokedPhoto.reviewListing==nil && launchPush.pendingPhotoReview==nil,"revoked team library cannot reopen an old edit")
  check(launchPush.pendingContextNotice == .unavailablePhoto,"revoked photo target gets visible recovery guidance")
  launchPush.clearPendingContextNotice()
  let wrongActorPhoto=PhotoReviewHarness()
  wrongActorPhoto.workspace.allowed=[workspaceID];wrongActorPhoto.model.listings=[photoListing];wrongActorPhoto.model.hasRestoredLibrary=true
  launchPush.handle(payload:photoPayload);PushManager.currentIdentity=other
  await wrongActorPhoto.reviewPendingNotification()
  check(wrongActorPhoto.reviewListing==nil && launchPush.pendingPhotoReview==nil,"a second actor in the same team cannot use the initiator's staged photo target")
  PushManager.currentIdentity=owner
  let switchedPhoto=PhotoReviewHarness()
  launchPush.handle(payload:photoPayload)
  let pendingPhoto=Task {await switchedPhoto.reviewPendingNotification()};await tick()
  PushManager.currentIdentity=other;launchPush.clearPendingPhotoReview()
  switchedPhoto.model.listings=[photoListing];switchedPhoto.model.hasRestoredLibrary=true
  await pendingPhoto.value
  check(switchedPhoto.reviewListing==nil,"account replacement during cold photo restore retires its target")
  PushManager.currentIdentity=owner
  let wrongLibrary=PhotoReviewHarness()
  wrongLibrary.workspace.afterRefresh=[workspaceID];wrongLibrary.model.listings=[photoListing];wrongLibrary.model.hasRestoredLibrary=true
  WorkspaceContext.selectedOrgID=otherWorkspace
  launchPush.handle(payload:photoPayload);await wrongLibrary.reviewPendingNotification()
  check(wrongLibrary.reviewListing==nil && launchPush.pendingPhotoReview?.listingID==listingID &&
        launchPush.pendingContextNotice == .switchPhotoLibrary("Test library"),
        "a different selected library explains the exact authorized photo target and keeps it pending")
  WorkspaceContext.selectedOrgID=workspaceID
  launchPush.clearPendingContextNotice()
  await wrongLibrary.reviewPendingNotification()
  check(wrongLibrary.reviewListing?.id==listingID && launchPush.pendingPhotoReview==nil,
        "the saved photo review continues after switching to the authorized library")
  let stalePhoto=PhotoReviewHarness()
  stalePhoto.workspace.allowed=[workspaceID];stalePhoto.model.hasRestoredLibrary=true
  stalePhoto.model.listings=[.init(id:listingID,cloudUnavailable:true,workspaceID:workspaceID)]
  stalePhoto.model.afterRefreshListings=[photoListing]
  launchPush.handle(payload:photoPayload);await stalePhoto.reviewPendingNotification()
  check(stalePhoto.model.refreshCount==1 && stalePhoto.reviewListing?.id==listingID && launchPush.pendingPhotoReview==nil,
        "photo review waits for the switched library to refresh a previously unavailable listing")

  let leadPayload:[AnyHashable:Any]=["recipient_user_id":owner.owner.uuidString,"category":"lead_received",
      "deep_link":"https://rendprop.com/f/unrelated-tour","data":["listing_id":listingID.uuidString,"lead_id":UUID().uuidString]]
  let leadListing=Listing(id:UUID(),workspaceID:workspaceID,serverID:listingID,serverOrgID:physical,serverLibraryOrgID:workspaceID)
  let coldLead=LeadReviewHarness();coldLead.workspace.afterRefresh=[workspaceID];coldLead.model.api.listings=[leadListing]
  launchPush.handle(payload:leadPayload)
  check(launchPush.pendingLeadReview == .init(owner:owner.owner,listingID:listingID) && launchPush.pendingRoute==nil,
        "emitted inquiry targets its exact listing instead of the tour or current account inbox")
  let coldLeadTask=Task{await coldLead.reviewPendingLeadNotification()};await tick()
  check(coldLead.reviewListing==nil && launchPush.pendingLeadReview != nil,"cold inquiry tap waits for library restoration")
  coldLead.model.hasRestoredLibrary=true;await coldLeadTask.value
  check(coldLead.reviewListing?.serverID==listingID && launchPush.pendingLeadReview==nil,
        "a fresh authorized listing read opens that exact listing's inbox")
  let crossLead=LeadReviewHarness();crossLead.model.hasRestoredLibrary=true;crossLead.workspace.afterRefresh=[workspaceID,otherWorkspace]
  crossLead.model.api.listings=[leadListing];WorkspaceContext.selectedOrgID=otherWorkspace
  launchPush.handle(payload:leadPayload);await crossLead.reviewPendingLeadNotification()
  check(crossLead.reviewListing==nil && launchPush.pendingLeadReview?.listingID==listingID &&
        launchPush.pendingContextNotice == .switchLeadLibrary("Test library"),
        "an inquiry in another authorized library names that library and retains its exact intent")
  WorkspaceContext.selectedOrgID=workspaceID;launchPush.clearPendingContextNotice()
  await crossLead.reviewPendingLeadNotification()
  check(crossLead.reviewListing?.serverID==listingID && launchPush.pendingLeadReview==nil,
        "switching to the verified library continues the exact listing inbox")
  let revokedLead=LeadReviewHarness();revokedLead.model.hasRestoredLibrary=true;revokedLead.model.api.listings=[leadListing]
  launchPush.handle(payload:leadPayload);await revokedLead.reviewPendingLeadNotification()
  check(revokedLead.reviewListing==nil && launchPush.pendingLeadReview==nil && launchPush.pendingContextNotice == .unavailableLead,
        "revoked membership cannot open a cached listing inbox")
  launchPush.clearPendingContextNotice()
  let missingLead=LeadReviewHarness();missingLead.model.hasRestoredLibrary=true;missingLead.workspace.afterRefresh=[workspaceID]
  missingLead.model.api.listings=[.init(id:UUID(),workspaceID:workspaceID,serverID:wrongID,serverOrgID:physical,serverLibraryOrgID:workspaceID)]
  launchPush.handle(payload:leadPayload);await missingLead.reviewPendingLeadNotification()
  check(missingLead.reviewListing==nil && launchPush.pendingLeadReview==nil,
        "a different accessible listing cannot substitute for the notified listing")
  launchPush.clearPendingContextNotice()
  let switchedLead=LeadReviewHarness();switchedLead.model.hasRestoredLibrary=true;switchedLead.workspace.afterRefresh=[workspaceID]
  switchedLead.model.api.listings=[leadListing];switchedLead.model.api.hold=true
  launchPush.handle(payload:leadPayload);let switchedLeadTask=Task{await switchedLead.reviewPendingLeadNotification()};await tick()
  PushManager.currentIdentity=other;launchPush.clearPendingLeadReview()
  switchedLead.model.api.continuation?.resume();await switchedLeadTask.value
  check(switchedLead.reviewListing==nil,"an account replacement during the inquiry read cannot open the earlier actor's inbox")
  PushManager.currentIdentity=owner
  launchPush.handle(payload:["recipient_user_id":other.owner.uuidString,"category":"lead_received","data":["listing_id":listingID.uuidString]])
  check(launchPush.pendingLeadReview==nil,"another recipient cannot stage a listing inbox")
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"lead_received","data":["listing_id":"invalid"]])
  check(launchPush.pendingLeadReview==nil && launchPush.pendingContextNotice == .unavailableLead && launchPush.pendingRoute==nil,
        "a malformed inquiry listing cannot fall through to a tour or unrelated inbox")
  let supersededPhoto=PhotoReviewHarness();supersededPhoto.workspace.allowed=[workspaceID];supersededPhoto.model.hasRestoredLibrary=true
  supersededPhoto.model.listings=[.init(id:listingID,cloudUnavailable:true,workspaceID:workspaceID)]
  supersededPhoto.model.afterRefreshListings=[photoListing];supersededPhoto.model.holdRefresh=true
  launchPush.handle(payload:photoPayload)
  let stalePhotoTask=Task{await supersededPhoto.reviewPendingNotification()};await tick()
  launchPush.handle(payload:leadPayload)
  supersededPhoto.model.refreshContinuation?.resume();await stalePhotoTask.value
  check(supersededPhoto.reviewListing==nil && launchPush.pendingLeadReview?.listingID==listingID && launchPush.pendingContextNotice==nil,
        "an earlier photo read cannot present after a newer accepted notification tap")
  let latestRevision=launchPush.notificationTapRevision
  launchPush.handle(payload:["recipient_user_id":other.owner.uuidString,"category":"upload_stuck"])
  check(launchPush.notificationTapRevision==latestRevision && launchPush.pendingLeadReview?.listingID==listingID,
        "a wrong-recipient tap cannot cancel the current actor's pending intent")
  launchPush.pendingRoute = .leads;launchPush.pendingReelJobID=id
  launchPush.pendingServerVideoReview = .init(owner:owner.owner,jobID:id,listingID:listingID)
  launchPush.pendingPhotoReview = .init(owner:owner.owner,workspace:workspaceID,listingID:listingID)
  launchPush.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"upload_stuck"])
  check(launchPush.pendingRoute==nil && launchPush.pendingReelJobID==nil && launchPush.pendingServerVideoReview==nil &&
        launchPush.pendingPhotoReview==nil && launchPush.pendingLeadReview==nil && launchPush.pendingContextNotice == .uploadStuck,
        "the newest accepted tap supersedes all earlier notification intents")
  print("PASS: \(checks) actual reel banner, review admission and notification routing assertions; closed OS boundaries")
 }
}
