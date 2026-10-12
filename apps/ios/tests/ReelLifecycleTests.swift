import Foundation

struct UIBackgroundTaskIdentifier: Equatable, Hashable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
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
@MainActor enum PushManager { static var currentIdentity: PushAccountIdentity? }
@MainActor final class ClosedConnection { var cancelled = false; func cancel() { cancelled = true } }
@MainActor final class ClosedPlayer { var paused = false; func pause() { paused = true } }
@MainActor final class ClosedRecorder { var isRecording = true; var cancellations = 0; func cancel() { isRecording = false; cancellations += 1 } }
@MainActor enum IdleTimer { static var releases = 0; static func release() { releases += 1 } }
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

@main struct ReelLifecycleTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func tick() async { for _ in 0..<20 { await Task.yield() } }
        let app = UIApplication.shared, center = UNUserNotificationCenter.current()
        let a = PushAccountIdentity(owner: UUID(), revision: 1)
        let b = PushAccountIdentity(owner: UUID(), revision: 2)
        func reset() { center.reset(); PushManager.currentIdentity = a; app.applicationState = .background }

        let holds = ReelBackgroundHarness()
        holds.beginBackgroundHold()
        let first = holds.backgroundHold
        holds.beginBackgroundHold()
        check(app.next == 1, "a generating-to-stitching transition keeps one background grant")
        app.handlers[first]?()
        check(app.ended == [first] && holds.backgroundHold == .invalid, "expiry ends the background grant synchronously")
        check(holds.backgroundHoldOperation == nil, "expiry retires the background operation token")
        holds.endBackgroundHold()
        check(app.ended == [first], "ending a retired background grant is idempotent")
        holds.beginBackgroundHold()
        let second = holds.backgroundHold
        app.handlers[first]?()
        check(holds.backgroundHold == second && app.ended == [first], "stale expiry cannot end a newer background grant")
        holds.endBackgroundHold()
        check(app.ended == [first, second] && holds.backgroundHold == .invalid, "normal completion ends exactly its own background grant")
        holds.beginBackgroundHold()
        let closing = holds.backgroundHold
        holds.idleHeld = true
        holds.workTask = Task { while !Task.isCancelled { await Task.yield() } }
        holds.onDisappearCleanup()
        check(holds.workTask?.isCancelled == true && holds.connection.cancelled, "dismissing the reel cancels work and its connection")
        check(holds.player?.paused == true && holds.voPlayer?.paused == true, "dismissing the reel pauses both players")
        check(!holds.recorder.isRecording && holds.recorder.cancellations == 1, "dismissing the reel releases a recording microphone")
        check(!holds.idleHeld && IdleTimer.releases == 1, "dismissing the reel releases its idle timer hold")
        check(holds.backgroundHold == .invalid && app.ended == [first, second, closing], "dismissing the reel ends its background grant")
        holds.onDisappearCleanup()
        check(IdleTimer.releases == 1 && holds.recorder.cancellations == 1 && app.ended.count == 3, "repeated dismissal does not release a grant twice")

        reset(); app.applicationState = .active
        ReelCompletionNotice.post(success: true, identity: a)
        check(center.settings.isEmpty && center.requests.isEmpty, "foreground completion does not create a local banner")
        reset(); PushManager.currentIdentity = b
        ReelCompletionNotice.post(success: true, identity: a)
        check(center.settings.isEmpty, "an already stale completion cannot request notification settings")
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
            check(center.requests.first?.content.title == "Your reel is ready", "successful completion carries the ready title")
            check(center.requests.first?.content.userInfo["recipient_user_id"] as? String == a.owner.uuidString, "local completion is scoped to its captured owner")
            check(center.requests.first?.content.userInfo["category"] as? String == "reel_done", "local completion has no cross-account listing route")
        }
        reset(); ReelCompletionNotice.post(success: false, identity: a)
        center.answer(.authorized); await tick()
        check(center.requests.first?.content.title == "Your reel couldn't be made", "failed completion has a distinct honest title")
        check(center.requests.first?.content.body.contains("Finished clips are kept") == true, "failure notice explains retained paid work")
        print("PASS: \(checks) actual reel expiry and notification enqueue assertions; closed OS boundaries")
    }
}
