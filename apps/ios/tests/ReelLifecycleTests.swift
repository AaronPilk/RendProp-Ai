import Foundation

struct UIBackgroundTaskIdentifier: Equatable, Hashable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    static let didBecomeActiveNotification = Notification.Name("fixture.application.active")
    static let willResignActiveNotification = Notification.Name("fixture.application.inactive")
    var applicationState = State.background
    var next = 0
    var handlers: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    var ended: [UIBackgroundTaskIdentifier] = []
    func beginBackgroundTask(withName: String?, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        next += 1
        let id = UIBackgroundTaskIdentifier(rawValue: next)
        handlers[id] = expirationHandler
        return id
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
}
struct PushAccountIdentity: Equatable { let owner: UUID; let revision: UInt64 }
@MainActor final class PushManager { static let shared=PushManager();static var currentIdentity: PushAccountIdentity?;var localDataErasureRevision:UInt64=0 }
@MainActor final class ClosedConnection { var cancelled = false; func cancel() { cancelled = true } }
@MainActor final class ClosedPlayer { var paused = false; func pause() { paused = true } }
@MainActor final class ClosedMusicPreview { var stopped = false; func stop() { stopped = true } }
@MainActor final class ClosedRecorder { var isRecording = true; var cancellations = 0; func cancel() { isRecording = false; cancellations += 1 } }
@MainActor enum IdleTimer {
    static var holds = 0, releases = 0
    static var activeHolds: Int { holds - releases }
    static func hold() { holds += 1 }
    static func release() { releases += 1; precondition(releases <= holds, "idle timer cannot release another feature's hold") }
}
enum UNAuthorizationStatus { case notDetermined, denied, authorized, provisional, ephemeral }
struct UNNotificationSettings { let authorizationStatus: UNAuthorizationStatus }
struct UNNotificationSound { static let `default` = Self() }
final class UNMutableNotificationContent {
    var title = "", body = ""
    var sound: UNNotificationSound?
    var userInfo: [AnyHashable: Any] = [:]
}
struct UNNotificationRequest {
    let identifier: String
    let content: UNMutableNotificationContent
    let trigger: String?
}
@MainActor final class UNUserNotificationCenter {
    static let center = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { center }
    var settings: [(UNNotificationSettings) -> Void] = []
    var requests: [UNNotificationRequest] = []
    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) { settings.append(completionHandler) }
    func add(_ request: UNNotificationRequest) { requests.append(request) }
    func answer(_ authorization: UNAuthorizationStatus) { settings.removeFirst()(.init(authorizationStatus: authorization)) }
    func reset() { settings = []; requests = [] }
}

// Closed observable/OS/model boundaries. Production queue/task/identity and
// phase decisions execute unchanged; this does not emulate OS grant duration.
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
final class AnyCancellable {}
final class ClosedChange {
    static let shared = ClosedChange()
    func send() {}
    func sink(_ receive: @escaping (()) -> Void) -> AnyCancellable { AnyCancellable() }
}
protocol ObservableObject { var objectWillChange: ClosedChange { get } }
extension ObservableObject { var objectWillChange: ClosedChange { .shared } }
struct Listing { let id: UUID; let address: String; var isSample=false;var cloudUnavailable:Bool?=nil;var serverID:UUID?=nil }
protocol PropertyVideoJobsAPI {}
@MainActor final class AppModel {var listings:[Listing]=[];var api:Any?=nil}
struct PropertyVideoJobContext {let localListingID:UUID;let listingID:UUID;let actorID:UUID;let orgID:UUID}
struct PropertyVideoSavedJob {struct Request {var sources:[Int]=[];var isPhotoMotion=false};struct Reply {var isTerminal=false};var request=Request();var reply:Reply?=nil}
enum PhotoMotionContract {static let mode = "photo_motion"}
enum ListingVideoStore {static func digest(_ url:URL)throws->String {"closed-file-digest"}}
enum FileStore {static let documents=URL(fileURLWithPath:"/closed-no-server-jobs")}
enum PropertyVideoJobStore {static func url(context:PropertyVideoJobContext,documents:URL)->URL{documents.appendingPathComponent("closed")}}
@MainActor final class PropertyVideoJobRunner {
 static let shared=PropertyVideoJobRunner()
 static func status(_ reply:PropertyVideoSavedJob.Reply)->String{"Closed server adapter"}
 func suspendForeground(){};func resumeForeground(){}
 func restore(work:ReelWorkJob,model:AppModel,api:PropertyVideoJobsAPI,context:PropertyVideoJobContext){}
}
@MainActor final class PropertyVideoJobCancellation {
 static let shared=PropertyVideoJobCancellation()
 var delayRequest=false,requestBegan=false
 var pendingRequest:CheckedContinuation<Void,Never>?
 func request(reason:String)async throws {
  requestBegan=true
  if delayRequest {await withCheckedContinuation {pendingRequest=$0}}
 }
 func releaseRequest(){let pending=pendingRequest;pendingRequest=nil;delayRequest=false;pending?.resume()}
 func consentWasRevoked(){};func retryPending(){}
}
struct ReelTitleCard {}
struct Voiceover {}
struct CaptionStyle {}
enum ReelComposer { enum ShotCaptionStyle { case off }; enum Transition { case cut } }
typealias AVPlayer = ClosedPlayer
struct AIFailure {}
struct ReelClipIssue { let photoNumber: Int }
struct PendingReelClips {}
struct PendingReelRequest { struct Context {} }
struct PendingReelBatch {}
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = UUID().uuidString
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor final class AIConsent {
    static let shared = AIConsent()
    var isGranted = true; var revocationRevision: UInt64 = 0
}
@MainActor final class ClosedGate { var released = false }
final class ClosedLifetime { let id = UUID() }

@main struct ReelLifecycleTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func tick() async { for _ in 0..<30 { await Task.yield() } }
        let app = UIApplication.shared, center = UNUserNotificationCenter.current()
        let a = PushAccountIdentity(owner: UUID(), revision: 1)
        let b = PushAccountIdentity(owner: UUID(), revision: 2)
        func reset() { center.reset(); PushManager.currentIdentity = a; app.applicationState = .background; ReelWorkQueue.shared.updateScreenAwakeHold(isActive: false) }
        reset()
        let queue = ReelWorkQueue.shared
        let listing = Listing(id: UUID(), address: "Closed synthetic listing")
        let job = queue.job(for: listing)
        check(queue.job(for: listing) === job, "reopening a sheet returns the same app-owned job")
        let release = ClosedGate(); var starts = 0
        job.phase = .generating; job.totalClips = 8
        check(job.start(identityIsCurrent: { true }, resume: {}, operation: {
            starts += 1
            while !release.released && !Task.isCancelled { await Task.yield() }
            if !Task.isCancelled { job.reelURL = URL(fileURLWithPath: "/synthetic-ready.mp4"); job.phase = .done }
        }), "the captured context admits one app task")
        await tick()
        check(!job.start(identityIsCurrent: { true }, resume: {}, operation: { starts += 1 }), "an already-running job admits no duplicate task")
        let presentation = ReelPresentationHarness(job: job)
        let presentedPlayer = presentation.player
        presentation.onDisappearCleanup()
        check(job.task?.isCancelled == false && job.running && starts == 1, "dismissing the sheet leaves the paid app-owned job running")
        check(presentation.connection.cancelled, "dismissal cancels only the unsent connection waiter")
        check(presentedPlayer?.paused == true && presentation.voPlayer?.paused == true, "dismissing the reel pauses both players")
        check(presentation.musicPreview.stopped, "dismissing the reel stops music preview playback")
        check(job.player == nil && !job.isPresented, "a dismissed studio releases its decoded playback session")
        job.setPlaybackPlayer(ClosedPlayer())
        check(job.player == nil, "completion while the studio is closed cannot retain a decoded player")
        check(!presentation.recorder.isRecording && presentation.recorder.cancellations == 1, "dismissing the reel releases a recording microphone")
        check(queue.currentJob === job, "another tab still sees the active job")
        job.completedClips = 6; job.clipIssues = [ReelClipIssue(photoNumber: 6)]
        check(job.fraction == 5.0/8.0 && job.percent == 62, "progress counts retained shots rather than failed attempts")
        job.completedClips = 8; job.clipIssues = []; job.phase = .stitching
        check(job.percent == 99, "clip completion never claims the composed video is finished")
        release.released = true; await job.task?.value
        check(!job.running && job.task == nil && job.phase == .done && job.percent == 100 && job.reelURL != nil, "only a saved ready result reports 100 percent")
        check(app.ended.count == 1, "normal completion ends exactly one app-owned background grant")
        check(center.settings.count == 1, "ready result notifies centrally once after a sheet is gone")
        center.answer(.authorized); await tick()
        check(center.requests.count == 1, "one app result enqueues exactly one notification")
        check(center.requests.first?.content.userInfo["listing_id"] as? String == job.listingID.uuidString &&
              center.requests.first?.content.userInfo["reel_job_id"] as? String == job.id.uuidString, "notification points to the same owned job and listing")
        job.dismissResult(); check(queue.visibleJobs.isEmpty, "dismissal hides only a completed banner, not its saved result")
        check(job.reelURL != nil && queue.job(for: listing) === job, "dismissing result retains its app-owned video")

        // Terminal jobs keep durable URLs, not the dismissed view's resume
        // callback. Paused jobs retain the callback until resumed or cancelled.
        for terminal in [ReelWorkJob.Phase.done, .failed, .setup] {
            let finished = queue.job(for: Listing(id: UUID(), address: "Callback lifetime"))
            var probe: ClosedLifetime? = ClosedLifetime()
            weak var weakProbe = probe
            _ = finished.start(identityIsCurrent: { true }, resume: { [held = probe!] in _ = held.id }, operation: { finished.phase = terminal })
            probe = nil; await finished.task?.value
            check(weakProbe == nil, "terminal work releases the captured resume callback")
        }
        let retainedResume = queue.job(for: Listing(id: UUID(), address: "Paused callback lifetime"))
        var retainedProbe: ClosedLifetime? = ClosedLifetime()
        weak var weakRetainedProbe = retainedProbe
        retainedResume.phase = .generating
        _ = retainedResume.start(identityIsCurrent: { true }, resume: { [held = retainedProbe!] in _ = held.id }, operation: {
            while !Task.isCancelled { await Task.yield() }
        })
        retainedProbe = nil; await tick()
        app.handlers[retainedResume.backgroundHold]?()
        check(retainedResume.task?.isCancelled == true, "expiry pauses and cancels only local execution")
        await retainedResume.task?.value
        check(weakRetainedProbe != nil, "paused work preserves its exact continuation callback")
        retainedResume.cancel()
        check(weakRetainedProbe == nil, "explicit cancel releases the paused continuation callback")

        // Expiration ends exactly its grant synchronously, stops local work and
        // waits for paid-file cleanup before an owned foreground continuation.
        reset(); let paused = queue.job(for: Listing(id: UUID(), address: "Paused synthetic listing"))
        paused.phase = .generating
        let cleanup = ClosedGate(); var continuations = 0
        let paid = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-paid-\(UUID()).bin")
        let paidBytes = Data("synthetic retained paid receipt/clip".utf8)
        try! paidBytes.write(to: paid)
        defer { try? FileManager.default.removeItem(at: paid) }
        check(paused.start(identityIsCurrent: { true }, resume: { continuations += 1 }, operation: {
            while !Task.isCancelled { await Task.yield() }
            while !cleanup.released { await Task.yield() }
        }), "expiration test starts one owned operation")
        await tick(); let grant = paused.backgroundHold
        app.handlers[grant]?()
        check(app.ended.last == grant && paused.backgroundHold == .invalid, "expiry ends the background grant synchronously")
        check(paused.backgroundHoldOperation == nil, "expiry retires the background operation token")
        check(paused.paused && paused.phase == .paused && paused.task?.isCancelled == true, "expiry pauses and cancels only local execution")
        check(try! Data(contentsOf: paid) == paidBytes, "expiry leaves the paid receipt and clip bytes untouched")
        paused.resumeForeground(); await tick()
        check(continuations == 0, "background expiry cannot dispatch a foreground continuation")
        app.applicationState = .active
        paused.resumeForeground(); paused.resumeForeground(); await tick()
        check(continuations == 0, "foreground continuation waits for the interrupted task to retain paid files")
        cleanup.released = true; await paused.task?.value; await tick()
        check(continuations == 1 && !paused.paused && !paused.running, "foreground resumes the same saved operation exactly once")
        paused.resumeForeground(); await tick()
        check(continuations == 1, "repeated foreground events cannot restart a resumed operation")
        check(center.settings.isEmpty && center.requests.isEmpty, "OS-expiration pause sends no failed or done notification")

        // A stale expiration callback cannot cancel a replacement operation.
        let replacement = ClosedGate()
        paused.phase = .generating
        check(paused.start(identityIsCurrent: { true }, resume: {}, operation: {
            while !replacement.released && !Task.isCancelled { await Task.yield() }
        }), "finished cleanup permits a replacement owned operation")
        await tick(); let nextGrant = paused.backgroundHold
        app.handlers[grant]?()
        check(paused.backgroundHold == nextGrant && !paused.paused && paused.task?.isCancelled == false, "stale expiry cannot end a newer background grant")
        paused.cancel(); await paused.task?.value
        check(paused.task == nil && !paused.running && !paused.paused, "explicit cancel completes local cleanup without automatic restart")
        check(try! Data(contentsOf: paid) == paidBytes, "explicit cancel does not delete paid recovery bytes")

        reset(); let backgroundOnly = queue.job(for: Listing(id: UUID(), address: "Background resume boundary"))
        var backgroundStarts = 0; backgroundOnly.phase = .generating
        _ = backgroundOnly.start(identityIsCurrent: { true }, resume: { backgroundStarts += 1 }, operation: {
            while !Task.isCancelled { await Task.yield() }
        })
        await tick(); app.handlers[backgroundOnly.backgroundHold]?(); await backgroundOnly.task?.value
        backgroundOnly.resumeForeground(); await tick()
        check(backgroundStarts == 0 && backgroundOnly.paused, "background expiry cannot dispatch a foreground continuation")
        backgroundOnly.cancel()

        // Scope changes stop local tasks, hide their result and never revive an
        // old consent grant, including when the same owner signs back in.
        for change in 0..<5 {
            reset(); let owned = queue.job(for: Listing(id: UUID(), address: "Context synthetic listing"))
            owned.phase = .generating; let valid = ClosedGate(); valid.released = true
            check(owned.start(identityIsCurrent: { valid.released }, resume: {}, operation: {
                while !Task.isCancelled { await Task.yield() }
            }), "owned identity test starts")
            await tick()
            let owner = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
            let workspace = WorkspaceContext.selectedOrgID, consent = AIConsent.shared.revocationRevision
            if change == 0 { AuthStore.shared.userID = UUID().uuidString }
            if change == 1 { AuthStore.shared.syncSessionRevision += 1 }
            if change == 2 { WorkspaceContext.selectedOrgID = UUID() }
            if change == 3 { AIConsent.shared.revocationRevision += 1 }
            if change == 4 { valid.released = false }
            queue.reconcileIdentity()
            let reason = ["owner switch cancels its captured job", "session replacement cancels its captured job", "workspace switch cancels its captured job", "revoked then granted consent cancels its captured job", "listing removal cancels its captured job"][change]
            check(owned.task?.isCancelled == true && !owned.isContextCurrent, reason)
            await owned.task?.value
            check(!queue.visibleJobs.contains(where: { $0.id == owned.id }), "stale work never appears under another context")
            check(center.settings.isEmpty, "stale task never notifies a replacement account")
            AuthStore.shared.userID = owner; AuthStore.shared.syncSessionRevision = revision
            WorkspaceContext.selectedOrgID = workspace; AIConsent.shared.revocationRevision = consent
        }
        // Context can change while cancellation/retention is finishing.
        reset(); let raced = queue.job(for: Listing(id: UUID(), address: "Resume race")); let finish = ClosedGate()
        var resumedOldOwner = 0
        raced.phase = .generating
        _ = raced.start(identityIsCurrent: { true }, resume: { resumedOldOwner += 1 }, operation: {
            while !Task.isCancelled { await Task.yield() }
            while !finish.released { await Task.yield() }
        })
        await tick(); app.handlers[raced.backgroundHold]?(); app.applicationState = .active
        raced.resumeForeground(); await tick()
        let savedOwner = AuthStore.shared.userID; AuthStore.shared.userID = UUID().uuidString
        finish.released = true; await raced.task?.value; await tick()
        check(resumedOldOwner == 0, "an account switch while cleanup awaits cannot resume the old operation")
        AuthStore.shared.userID = savedOwner

        reset(); app.applicationState = .active
        ReelCompletionNotice.post(success: true, identity: a)
        check(center.settings.isEmpty && center.requests.isEmpty, "foreground completion does not create a local banner")
        reset(); PushManager.currentIdentity = b
        ReelCompletionNotice.post(success: true, identity: a)
        check(center.settings.isEmpty, "an already stale completion cannot request notification settings")
        reset(); ReelCompletionNotice.post(success: true, identity: a)
        PushManager.shared.localDataErasureRevision &+= 1; center.answer(.authorized); await tick()
        check(center.requests.isEmpty, "Clear data during notification settings suppresses the earlier completion")
        reset(); ReelCompletionNotice.post(success: true, identity: a)
        PushManager.currentIdentity = b; center.answer(.authorized); await tick()
        check(center.requests.isEmpty, "owner switch during notification settings cannot enqueue the old owner's banner")
        reset(); ReelCompletionNotice.post(success: true, identity: a)
        PushManager.currentIdentity = .init(owner: a.owner, revision: 9); center.answer(.authorized); await tick()
        check(center.requests.isEmpty, "same-owner session replacement cannot enqueue an earlier session's banner")
        reset(); ReelCompletionNotice.post(success: true, identity: a)
        center.answer(.authorized); PushManager.currentIdentity = nil; await tick()
        check(center.requests.isEmpty, "sign-out before the main-actor enqueue suppresses the banner")
        reset(); ReelCompletionNotice.post(success: true, identity: a)
        app.applicationState = .active; center.answer(.authorized); await tick()
        check(center.requests.isEmpty, "returning to the foreground while settings load suppresses the banner")
        for status in [UNAuthorizationStatus.denied, .notDetermined] {
            reset(); ReelCompletionNotice.post(success: true, identity: a)
            center.answer(status); await tick()
            check(center.requests.isEmpty, "notification permission is never bypassed")
        }
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            reset(); ReelCompletionNotice.post(success: true, identity: a)
            center.answer(status); await tick()
            check(center.requests.count == 1, "an authorized background completion enqueues exactly one local banner")
            check(center.requests.first?.content.title == "Your video is ready", "successful completion carries the ready title")
            check(center.requests.first?.content.userInfo["recipient_user_id"] as? String == a.owner.uuidString, "local completion is scoped to its captured owner")
            check(center.requests.first?.content.userInfo["category"] as? String == "reel_done", "local completion has no cross-account listing route")
        }
        reset(); ReelCompletionNotice.post(success: false, identity: a)
        center.answer(.authorized); await tick()
        check(center.requests.first?.content.title == "Your video couldn't be made", "failed completion has a distinct honest title")
        check(center.requests.first?.content.body.contains("Finished clips are kept") == true, "failure notice explains retained paid work")

        // Actual global screen-awake policy covers other tabs/editor dismissal,
        // balances concurrent jobs and never releases another feature's hold.
        reset(); app.applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil); await tick()
        IdleTimer.hold() // A separate capture/render feature owns this hold.
        let active = queue.job(for: Listing(id: UUID(), address: "Foreground idle guard"))
        let second = queue.job(for: Listing(id: UUID(), address: "Second foreground job"))
        let activeFinish = ClosedGate(), secondFinish = ClosedGate()
        active.phase = .generating; second.phase = .generating
        _ = active.start(identityIsCurrent: { true }, resume: {}, operation: {
            while !activeFinish.released && !Task.isCancelled { await Task.yield() }
            active.phase = .done
        })
        await tick()
        check(IdleTimer.activeHolds == 2, "active app-wide reel work keeps the screen awake")
        _ = second.start(identityIsCurrent: { true }, resume: {}, operation: {
            while !secondFinish.released && !Task.isCancelled { await Task.yield() }
            second.phase = .done
        })
        await tick()
        queue.updateScreenAwakeHold(); queue.updateScreenAwakeHold()
        check(IdleTimer.activeHolds == 2, "concurrent jobs share one balanced reel idle hold")
        let closedEditor = ReelPresentationHarness(job: active); closedEditor.onDisappearCleanup()
        check(IdleTimer.activeHolds == 2, "closing Reel Studio keeps active work's idle hold")
        app.applicationState = .inactive
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil); await tick()
        check(IdleTimer.activeHolds == 1, "inactive scene releases only the reel idle hold")
        app.applicationState = .active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil); await tick()
        check(IdleTimer.activeHolds == 2, "returning active reclaims the existing job's idle hold")
        activeFinish.released = true; await active.task?.value
        check(IdleTimer.activeHolds == 2, "one terminal job cannot release a concurrent reel hold")
        second.cancel(); await second.task?.value
        check(IdleTimer.activeHolds == 1, "terminal and cancelled reels balance the idle hold")
        IdleTimer.release()
        check(IdleTimer.activeHolds == 0, "reel cleanup preserves and balances unrelated idle holds")

        // A cancelled paid POST can still write an ambiguous receipt as it
        // unwinds. Erasure must wait for that writer and clear only its jobs.
        reset(); let erasing = queue.job(for: Listing(id: UUID(), address: "Erase delayed writer"))
        let eraseCleanup = ClosedGate(); var writerFinished = false
        erasing.phase = .generating
        _ = erasing.start(identityIsCurrent: { true }, resume: {}, operation: {
            while !Task.isCancelled { await Task.yield() }
            while !eraseCleanup.released { await Task.yield() }
            writerFinished = true
        })
        await tick(); var erased = false
        let eraseTask = Task { await queue.cancelForLocalDataErasure(); erased = true }
        await tick()
        check(!erased && !writerFinished && erasing.task?.isCancelled == true, "local erasure waits for cancelled reel receipt writers")
        let replacementJob = queue.job(for: Listing(id: UUID(), address: "New context while waiting"))
        erasing.configuration = .init(extras: [], captions: nil, voice: nil, captionStyle: .init(), shotStyle: .off, transition: .cut)
        erasing.reelURL = URL(fileURLWithPath: "/erased-reel.mp4")
        erasing.pendingRequest = PendingReelRequest(); erasing.pendingBatch = PendingReelBatch(); erasing.parkedClips = PendingReelClips()
        eraseCleanup.released = true; await eraseTask.value
        check(erased && writerFinished, "local erasure completes after the paid writer terminates")
        check(!queue.jobs.contains(where: { $0.id == erasing.id }) && queue.jobs.contains(where: { $0.id == replacementJob.id }), "erasure removes only captured jobs, preserving replacement work")
        check(erasing.reelURL == nil && erasing.pendingRequest == nil && erasing.pendingBatch == nil && erasing.parkedClips == nil && erasing.configuration == nil, "erasure drops embedded source and playback presentation references")
        // A server cancellation acknowledgment may be delayed while a new
        // account opens a job. Erasure must retain its pre-await snapshot.
        reset()
        let stopBoundary=PropertyVideoJobCancellation.shared
        stopBoundary.delayRequest=true;stopBoundary.requestBegan=false
        let oldContextJob=queue.job(for:Listing(id:UUID(),address:"Outgoing before server acknowledgment"))
        let delayedErase=Task {await queue.cancelForLocalDataErasure()}
        await tick()
        check(stopBoundary.requestBegan && stopBoundary.pendingRequest != nil,"erasure waits at the captured server cancellation boundary")
        let arrivedDuringStop=queue.job(for:Listing(id:UUID(),address:"Replacement during server acknowledgment"))
        stopBoundary.releaseRequest();await delayedErase.value
        check(!queue.jobs.contains(where:{$0.id==oldContextJob.id}) && queue.jobs.contains(where:{$0.id==arrivedDuringStop.id}),"server cancellation wait cannot erase later account work")
        print("PASS: \(checks) actual app-owned reel task/expiry/identity and notification enqueue assertions; closed OS boundaries")
    }
}
