import Foundation

struct ClosedServerJob { struct Reply { let jobID:UUID };var reply:Reply? }
@MainActor final class ReelWorkJob { var serverJob:ClosedServerJob?; let id:UUID; let listingID:UUID; init(_ id:UUID,_ listingID:UUID){self.id=id;self.listingID=listingID} }
struct Listing { let id:UUID; var isSample=false; var cloudUnavailable:Bool? }
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
  check(ReelWorkReviewAdmission.listing(jobID:wrongID,visibleJobs:[job],listings:[listing])==nil,"unknown job cannot open another existing listing")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[],listings:[listing])==nil,"hidden old-context job cannot be reviewed")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[])==nil,"deleted listing cannot be reviewed")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:wrongID)])==nil,"job cannot route to a different listing")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:listingID,isSample:true)])==nil,"sample listing cannot receive real job result")
  check(ReelWorkReviewAdmission.listing(jobID:id,visibleJobs:[job],listings:[.init(id:listingID,cloudUnavailable:true)])==nil,"unavailable listing cannot be reopened by notification")
  let serverID=UUID()
  job.serverJob = .init(reply:.init(jobID:serverID))
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[listing])?.id==listingID,"accepted server job alias opens only its exact owned listing")
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[],listings:[listing])==nil,"hidden server job alias cannot reopen an old account listing")
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[.init(id:wrongID)])==nil,"server alias cannot substitute another existing listing")
  job.serverJob=nil
  check(ReelWorkReviewAdmission.listing(jobID:serverID,visibleJobs:[job],listings:[listing])==nil,"cleared server job receipt cannot reopen its former result")
  check(ReelWorkBannerCopy.title(running:true,paused:false,ready:false,stitching:false,completed:3,total:8)=="Making reel · 3 of 8 photos ready","banner counts actual selected photos")
  check(ReelWorkBannerCopy.title(running:true,paused:false,ready:false,stitching:true,completed:8,total:8).hasPrefix("Finishing reel"),"stitching is not advertised as completed")
  check(ReelWorkBannerCopy.title(running:false,paused:true,ready:false,stitching:false,completed:3,total:8)=="Reel paused","expired OS execution is not advertised as completed")
  check(ReelWorkBannerCopy.explanation(paused:true,running:false).contains("iOS paused local processing") && ReelWorkBannerCopy.explanation(paused:true,running:false).contains("saved requests"),"paused copy explains retained recoverable work")
  check(ReelWorkBannerCopy.explanation(paused:false,running:true).contains("may pause local processing"),"running copy does not promise killed-process completion")
  let owner=PushAccountIdentity(owner:UUID(),revision:1), other=PushAccountIdentity(owner:UUID(),revision:1)
  let push=PushManager(),center=UNUserNotificationCenter.current(),app=UIApplication.shared
  func reset(){center.reset();PushManager.currentIdentity=owner;app.applicationState = .background;push.pendingReelJobID=nil;push.pendingRoute=nil}
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
  check(push.pendingReelJobID==serverID && push.pendingRoute==nil,"server-ready notification routes through saved job review")
  push.clearPendingReelJob()
  var foreign=remote;foreign["recipient_user_id"]=other.owner.uuidString
  push.handle(payload:foreign)
  check(push.pendingReelJobID==nil && push.pendingRoute==nil,"foreign recipient cannot route a server property video")
  push.handle(payload:["recipient_user_id":owner.owner.uuidString,"category":"render_ready","data":["property_video_job_id":serverID.uuidString,"reel_job_id":"invalid"],"deep_link":"rendprop://f/ignored"])
  check(push.pendingReelJobID==nil && push.pendingRoute==nil,"malformed server-ready notice cannot fall through to unrelated tour")
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
  print("PASS: \(checks) actual reel banner, review admission and notification routing assertions; closed OS boundaries")
 }
}
