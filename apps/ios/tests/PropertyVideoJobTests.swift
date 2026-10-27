import Foundation

private var assertions = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1; precondition(value(), message)
}
private func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure(message) } catch { assertions += 1 }
}

final class AuthStore {
    static let shared=AuthStore(); var isIdentified=true;var userID:String?;var syncSessionRevision:UInt64=1
}
enum WorkspaceContext {static var selectedOrgID:UUID?}
final class AIConsent {static let shared=AIConsent();var isGranted=true;var revocationRevision:UInt64=1}
struct ClosedListing {let id:UUID;let serverID:UUID?;var cloudUnavailable:Bool?=nil}
final class AppModel {var listings:[ClosedListing]=[]}
final class ReelWorkJob {
 struct Scope {var isCurrent=true;var owner=AuthStore.shared.userID;var workspace=WorkspaceContext.selectedOrgID};var scope=Scope();let id=UUID();var running=false
 var serverJob:PropertyVideoSavedJob?;var followUp:(()->Void)?
 func afterCurrentOperation(_ action:@escaping()->Void){followUp=action}
 func finishFirstEnqueue(){running=false;let next=followUp;followUp=nil;next?()}
}
@MainActor final class UIApplication {enum State {case active,inactive};static let shared=UIApplication();var applicationState=State.active}
protocol PropertyVideoJobsAPI {}
struct ClosedJobsAPI:PropertyVideoJobsAPI {}
enum FileStore {static let documents=FileManager.default.temporaryDirectory.appendingPathComponent("closed-property-jobs-fixture")}
@MainActor final class LiveAPIClient {
 init?() {}
 func propertyVideoOperation(_ saved:PropertyVideoSavedJob,abandon:Bool)async throws->PropertyVideoOperationLookup{throw PropertyVideoProcessorFailure.operationPending}
 func cancelPropertyVideoJob(_ saved:PropertyVideoSavedJob)async throws->PropertyVideoJobReply{throw PropertyVideoProcessorFailure.operationPending}
}
@MainActor enum PropertyVideoJobHTTP {static func stopOwnedJobs(_ intent:PropertyVideoCancellationIntent)async throws{}}

@MainActor @main struct PropertyVideoJobTests {
    static func main() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let context = PropertyVideoJobContext(localListingID: UUID(), listingID: UUID(), actorID: UUID(), orgID: UUID())
        AuthStore.shared.userID=context.actorID.uuidString;WorkspaceContext.selectedOrgID=context.orgID
        let model=AppModel();model.listings=[ClosedListing(id:context.localListingID,serverID:context.listingID)]
        let work=ReelWorkJob();let scope=ActualRunnerScopeGuard().frozen(context:context,work:work,model:model)
        try scope();check(context.isCurrent,"current actor and listing library pass the actual foreground guard")
        AuthStore.shared.userID=UUID().uuidString
        rejects("account switch must stop the actual job status/download guard"){try scope()}
        AuthStore.shared.userID=context.actorID.uuidString;WorkspaceContext.selectedOrgID=UUID()
        rejects("workspace switch must stop the actual job status/download guard"){try scope()}
        WorkspaceContext.selectedOrgID=context.orgID;AuthStore.shared.syncSessionRevision+=1
        rejects("an old session revision must stop the actual job status/download guard"){try scope()}
        AuthStore.shared.syncSessionRevision-=1;AIConsent.shared.revocationRevision+=1
        rejects("revoked AI consent revision must stop the actual job status/download guard"){try scope()}
        AIConsent.shared.revocationRevision-=1;model.listings=[ClosedListing(id:context.localListingID,serverID:UUID())]
        rejects("a replacement server listing must stop the actual job status/download guard"){try scope()}
        model.listings=[ClosedListing(id:context.localListingID,serverID:context.listingID,cloudUnavailable:true)]
        rejects("a revoked cloud listing must stop the actual job status/download guard"){try scope()}
        model.listings=[ClosedListing(id:context.localListingID,serverID:context.listingID)]
        let replacement=ActualRunnerScopeGuard()
        let oldOperation=replacement.frozen(context:context,work:work,model:model)
        let newOperation=replacement.frozen(context:context,work:work,model:model)
        rejects("a replaced operation must stop the old status/download guard"){try oldOperation()}
        try newOperation()
        let suite="property-video-cancellation-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        let firstStop=try PropertyVideoJobCancellation.record(actorID:context.actorID,reason:"ai_consent_revoked",defaults:defaults)
        let secondStop=try PropertyVideoJobCancellation.record(actorID:context.actorID,reason:"local_data_erasure",defaults:defaults)
        let pendingStop=try PropertyVideoJobCancellation.pending(actorID:context.actorID,defaults:defaults)
        check(firstStop.operationID != secondStop.operationID && pendingStop==firstStop,"explicit stop actions preserve their separate durable operation IDs in order")
        try PropertyVideoJobCancellation.retire(firstStop,defaults:defaults)
        try PropertyVideoJobCancellation.retire(firstStop,defaults:defaults)
        let nextStop=try PropertyVideoJobCancellation.pending(actorID:context.actorID,defaults:defaults)
        check(nextStop==secondStop,"a lost old cancellation reply cannot retire a newer stop action")
        let unknownStop=PropertyVideoCancellationIntent(actorID:context.actorID,operationID:UUID(),reason:"local_data_erasure",createdAt:Date())
        try PropertyVideoJobCancellation.retire(unknownStop,defaults:defaults)
        let heldStop=try PropertyVideoJobCancellation.pending(actorID:context.actorID,defaults:defaults)
        check(heldStop==secondStop,"unknown cancellation receipt cannot erase a pending stop")
        let unrelatedStop=try PropertyVideoJobCancellation.pending(actorID:UUID(),defaults:defaults)
        check(unrelatedStop==nil,"a different account cannot inherit a cancellation intent")
        rejects("unknown cancellation reasons never enter the durable queue"){_ = try PropertyVideoJobCancellation.record(actorID:context.actorID,reason:"delete_everyone",defaults:defaults)}
        let sources = (0..<100).map { PropertyVideoJobSource(photoID: "staged-selected-\($0)", photoAssetID: UUID(),
            photoVersionID: "staged-selected-\($0)", photoProvenanceID: UUID(), motion: $0 % 2 == 0 ? "fly_through" : "push_in") }
        let presentation = PropertyVideoPresentation(transition: "cut", shotCaptionStyle: "off", spokenCaptions: false, titleCard: nil, shotLabels: Array(repeating: nil, count: sources.count))
        let request = PropertyVideoJobRequest(operationID: UUID(), listingID: context.listingID, expectedOrgID: context.orgID,
            purpose: "listing", aspect: "16:9", sources: sources, narrationResultID: nil, music: nil,
            allowOriginalPhotoFallback: true, presentation: presentation)
        check(request.isValid, "all hundred staged selected versions form a valid complete recipe")
        let saved = PropertyVideoSavedJob(context: context, request: request, createdAt: Date())
        try PropertyVideoJobStore.start(saved, documents: documents)
        let unresolved = try PropertyVideoJobStore.load(context: context, documents: documents)!
        check(unresolved.request == request && unresolved.reply == nil, "uncertain enqueue retains the exact frozen operation and recipe")
        rejects("uncertain enqueue must block a fresh paid operation") { try PropertyVideoJobStore.start(saved, documents: documents) }
        var reply = PropertyVideoJobReply(jobID: UUID(), operationID: request.operationID, listingID: context.listingID,
            orgID: UUID(), selectedLibraryOrgID: context.orgID, sourceCount: sources.count, manifestSHA256: String(repeating: "a", count: 64), state: "queued", completedSources: 0)
        _ = try reply.checked(request: request)
        let partialPaused = PropertyVideoJobReply(jobID:reply.jobID,operationID:reply.operationID,listingID:reply.listingID,
            orgID:reply.orgID,selectedLibraryOrgID:reply.selectedLibraryOrgID,sourceCount:reply.sourceCount,manifestSHA256:reply.manifestSHA256,
            state:"failed",completedSources:12,resumeAvailable:true)
        let pausedWire=try JSONEncoder().encode(partialPaused)
        let decodedPaused=try JSONDecoder().decode(PropertyVideoJobReply.self,from:pausedWire)
        check(decodedPaused.mayResume && decodedPaused.completedSources==12,"a proven partial capacity pause retains finished clip count and explicit resume availability")
        _ = try decodedPaused.checked(request:request,previous:reply)
        check(!reply.mayResume,"an accepted active job never exposes a new resume dispatch")
        let invalidResume = PropertyVideoJobReply(jobID:reply.jobID,operationID:reply.operationID,listingID:reply.listingID,
            orgID:reply.orgID,selectedLibraryOrgID:reply.selectedLibraryOrgID,sourceCount:reply.sourceCount,manifestSHA256:reply.manifestSHA256,
            state:"queued",resumeAvailable:true)
        rejects("only a failed saved job may advertise capacity resume"){_ = try invalidResume.checked(request:request)}
        let ordinaryFailure = PropertyVideoJobReply(jobID:reply.jobID,operationID:reply.operationID,listingID:reply.listingID,
            orgID:reply.orgID,selectedLibraryOrgID:reply.selectedLibraryOrgID,sourceCount:reply.sourceCount,manifestSHA256:reply.manifestSHA256,state:"failed")
        check(!ordinaryFailure.mayResume,"an ordinary or uncertain failure never enables paid resume")
        let plainMissing = PropertyVideoOperationLookup(operationID:request.operationID,listingID:request.listingID,selectedLibraryOrgID:request.expectedOrgID,operationClosed:false,job:nil)
        check(try! PropertyVideoAdmissionResolution.resolve(status:402,code:"capacity_refused",message:"Choose fewer photos",request:request,lookup:plainMissing)==nil,"plain unknown operation cannot unlock a new paid recipe")
        let closedMissing = PropertyVideoOperationLookup(operationID:request.operationID,listingID:request.listingID,selectedLibraryOrgID:request.expectedOrgID,operationClosed:true,job:nil)
        for status in [403,409,500] {
            check(try! PropertyVideoAdmissionResolution.resolve(status:status,code:"capacity_refused",message:"closed",request:request,lookup:closedMissing)==nil,"403/409/unknown replies never unlock new paid work")
        }
        let wrongOp = PropertyVideoOperationLookup(operationID:UUID(),listingID:request.listingID,selectedLibraryOrgID:request.expectedOrgID,operationClosed:true,job:nil)
        rejects("a different operation's refusal cannot unlock this recipe"){_ = try PropertyVideoAdmissionResolution.resolve(status:402,code:"capacity_refused",message:"closed",request:request,lookup:wrongOp)}
        let existingLookup = PropertyVideoOperationLookup(operationID:request.operationID,listingID:request.listingID,selectedLibraryOrgID:request.expectedOrgID,operationClosed:false,job:reply)
        if case .accepted(let recovered)? = try PropertyVideoAdmissionResolution.resolve(status:402,code:"capacity_refused",message:"race",request:request,lookup:existingLookup) {
            check(recovered.jobID==reply.jobID,"an accepted same operation is recovered instead of replaced")
        } else {preconditionFailure("accepted operation must be preserved")}
        let refusal:PropertyVideoCapacityRefusal
        if case .refused(let proven)? = try PropertyVideoAdmissionResolution.resolve(status:402,code:"capacity_refused",message:"Choose fewer photos",request:request,lookup:closedMissing) {refusal=proven}
        else {preconditionFailure("explicit operation-locked refusal must resolve")}
        let rejectionContext=PropertyVideoJobContext(localListingID:UUID(),listingID:context.listingID,actorID:context.actorID,orgID:context.orgID)
        var rejected=PropertyVideoSavedJob(context:rejectionContext,request:request,createdAt:Date());rejected.capacityRefusal=refusal
        try PropertyVideoJobStore.start(rejected,documents:documents)
        let retainedRefusal=try PropertyVideoJobStore.load(context:rejectionContext,documents:documents)!
        check(retainedRefusal.wasRefusedBeforeAdmission && retainedRefusal.request.sources==sources,"closed refusal retains exact selected sources and its proof across relaunch")
        var lateAccepted=rejected;lateAccepted.reply=reply;lateAccepted.capacityRefusal=nil
        rejects("a closed refusal cannot be reopened by a late accepted writer"){try PropertyVideoJobStore.save(lateAccepted,documents:documents)}
        let smaller=PropertyVideoJobRequest(operationID:UUID(),listingID:request.listingID,expectedOrgID:request.expectedOrgID,purpose:"listing",aspect:"16:9",sources:Array(sources.prefix(30)),narrationResultID:nil,music:nil,allowOriginalPhotoFallback:true,presentation:PropertyVideoPresentation(transition:"cut",shotCaptionStyle:"off",spokenCaptions:false,titleCard:nil,shotLabels:Array(repeating:nil,count:30)))
        try PropertyVideoJobStore.start(.init(context:rejectionContext,request:smaller,createdAt:Date()),documents:documents)
        let edited=try PropertyVideoJobStore.load(context:rejectionContext,documents:documents)!
        check(edited.request.operationID != request.operationID && edited.request.sources.count==30,"editing a closed refused recipe gets one new operation without truncating the original evidence")
        let rejectedArchive=PropertyVideoJobStore.url(context:rejectionContext,documents:documents).deletingPathExtension().appendingPathExtension("\(request.operationID.uuidString).history.json")
        check(try! JSONDecoder().decode(PropertyVideoSavedJob.self,from:Data(contentsOf:rejectedArchive)).request.sources==sources,"the full rejected recipe stays in durable history")
        let malformed=Data("{\"operation_id\":\"\(request.operationID.uuidString)\",\"listing_id\":\"\(request.listingID.uuidString)\",\"selected_library_org_id\":\"\(request.expectedOrgID.uuidString)\",\"operation_closed\":true}".utf8)
        rejects("missing job field is not explicit job null"){_ = try JSONDecoder().decode(PropertyVideoOperationLookup.self,from:malformed)}
        let pendingWork=ReelWorkJob();pendingWork.serverJob=saved;pendingWork.running=true
        let serial=ActualFirstEnqueueSerialization();serial.schedule(work:pendingWork,model:model)
        serial.schedule(work:pendingWork,model:model)
        check(serial.requests==0,"reopen cannot race the still-running first enqueue with another POST")
        pendingWork.finishFirstEnqueue()
        check(serial.requests==1,"recovery waits for the first writer before checking that same operation")
        let refusedWork=ReelWorkJob();refusedWork.serverJob=rejected
        serial.schedule(work:refusedWork,model:model)
        check(serial.requests==1,"a proven closed refusal is never re-enqueued by status recovery")
        var accepted = saved; accepted.reply = reply
        try PropertyVideoJobStore.save(accepted, documents: documents)
        let reloaded = try PropertyVideoJobStore.load(context: context, documents: documents)!
        check(reloaded.request.operationID == request.operationID && reloaded.reply?.jobID == reply.jobID, "process relaunch keeps one accepted server job")
        rejects("an accepted job cannot be erased by a late pre-acknowledgment writer"){try PropertyVideoJobStore.save(saved,documents:documents)}
        var lateRefused=saved;lateRefused.capacityRefusal=refusal
        rejects("an accepted job cannot be replaced by a delayed capacity refusal"){try PropertyVideoJobStore.save(lateRefused,documents:documents)}
        let foreign = PropertyVideoJobReply(jobID: reply.jobID, operationID: reply.operationID, listingID: reply.listingID,
            orgID: reply.orgID, selectedLibraryOrgID: UUID(), sourceCount: reply.sourceCount, manifestSHA256: reply.manifestSHA256, state: "queued")
        rejects("foreign logical library must refuse even when physical storage org differs legitimately") { _ = try foreign.checked(request: request) }
        let changedManifest = PropertyVideoJobReply(jobID: reply.jobID, operationID: reply.operationID, listingID: reply.listingID,
            orgID: reply.orgID, selectedLibraryOrgID: context.orgID, sourceCount: reply.sourceCount, manifestSHA256: String(repeating: "b", count: 64), state: "generating")
        rejects("same operation cannot switch its normalized manifest") { _ = try changedManifest.checked(request: request, previous: reply) }
        let foreignContext = PropertyVideoJobContext(localListingID: context.localListingID, listingID: context.listingID, actorID: UUID(), orgID: context.orgID)
        let foreignSaved = try PropertyVideoJobStore.load(context: foreignContext, documents: documents)
        check(foreignSaved == nil, "another account cannot discover this persisted job through its path")
        let finished = sources.enumerated().map { index, photo in ListingVideoSource(photoVersionID: photo.photoVersionID,
            photoAssetID: photo.photoAssetID.uuidString, photoProvenanceID: photo.photoProvenanceID?.uuidString,
            generationRequestID: index == 3 ? nil : "accepted-\(index)", generationProvenanceID: index == 3 ? nil : UUID().uuidString,
            motionKind: index == 3 ? "original_photo" : "ai", sourceBound: index != 3) }
        let result = PropertyVideoJobResult(assetID: UUID(), posterAssetID: UUID(), downloadURL: URL(string: "https://private.example/master.mp4?secret=short-lived"),
            width: 1920, height: 1080, durationS: 500, bytes: 12_345, sha256: String(repeating: "c", count: 64), brandingPolicy: "unbranded",
            sources: finished, originalPhotoCount: 1, music: nil)
        try result.check(request: request)
        check(finished[3].isComplete, "legitimate still fallback retains the selected staged source without requiring successful AI")
        for (index, source) in finished.enumerated() {
            check(source.photoVersionID == sources[index].photoVersionID && source.photoProvenanceID == sources[index].photoProvenanceID?.uuidString,
                "ready manifest retains every selected version and provenance in order")
        }
        var wrongSources = finished
        wrongSources.swapAt(0, 1)
        let swapped = PropertyVideoJobResult(assetID: result.assetID, posterAssetID: result.posterAssetID, downloadURL: result.downloadURL,
            width: 1920, height: 1080, durationS: 500, bytes: 12_345, sha256: result.sha256, brandingPolicy: "unbranded",
            sources: wrongSources, originalPhotoCount: 1, music: nil)
        rejects("ready output cannot silently substitute or reorder the frozen photo source") { try swapped.check(request: request) }
        let small = PropertyVideoJobResult(assetID: result.assetID, posterAssetID: result.posterAssetID, downloadURL: result.downloadURL,
            width: 1280, height: 720, durationS: 500, bytes: 12_345, sha256: result.sha256, brandingPolicy: "unbranded",
            sources: finished, originalPhotoCount: 1, music: nil)
        rejects("720p result cannot satisfy listing master 1080p minimum") { try small.check(request: request) }
        reply = PropertyVideoJobReply(jobID: reply.jobID, operationID: reply.operationID, listingID: reply.listingID,
            orgID: reply.orgID, selectedLibraryOrgID: context.orgID, sourceCount: sources.count, manifestSHA256: reply.manifestSHA256,
            state: "ready", completedSources: 100, result: result)
        accepted.reply = reply
        try PropertyVideoJobStore.save(accepted, documents: documents)
        let disk = try Data(contentsOf: PropertyVideoJobStore.url(context: context, documents: documents))
        check(!String(decoding: disk, as: UTF8.self).contains("short-lived"), "durable receipt never retains a signed download capability")
        let ready = try PropertyVideoJobStore.load(context: context, documents: documents)!
        check(ready.reply?.result?.downloadURL == nil && ready.reply?.result?.assetID == result.assetID, "reopen renews private download while keeping immutable output identity")
        rejects("disk receipt without renewed capability cannot download") { try ready.reply!.result!.check(request: request) }
        _ = try ready.reply!.checked(request: request, requireDownload: false)
        let track = VideoMusicCatalog.tracks[0]
        let selection = VideoMusicSelection(trackID: track.id, assetSHA256: track.assetSHA256, licenseID: track.licenseID, licenseEvidenceSHA256: track.licenseEvidenceSHA256)
        check(selection.checked(catalog: VideoMusicCatalog.tracks) == track, "music restores only the frozen reviewed catalog asset and license evidence")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as! [String: Any]
        check(json["track_id"] as? String == "calm" && json["duck_gain"] as? Double == 0.07, "music wire freezes actual server track and duck gain fields")
        let changedTrack = VideoMusicSelection(trackID: track.id, assetSHA256: String(repeating: "d", count: 64), licenseID: track.licenseID, licenseEvidenceSHA256: track.licenseEvidenceSHA256)
        check(changedTrack.checked(catalog: VideoMusicCatalog.tracks) == nil, "stale music bytes are never replaced silently")
        print("property-video jobs: \(assertions) assertions passed")
    }
}
