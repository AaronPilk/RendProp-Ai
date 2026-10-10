import Foundation

// Platform/network/image boundaries are deterministic doubles. The runner
// injects the actual service identity, start, cleanup and notification methods.
struct EnhancedPhoto { let id: String }
struct Listing { let id: UUID; var cloudUnavailable: Bool? = nil }
enum SpaceType { case realEstate }
enum CloudSyncError: Error { case identityChanged }
enum PhotoVersionHistory { enum Failure: Error { case missingImage } }
enum SyntheticFailure: Error { case quota, unauthorized, serviceUnavailable, trialCapacityUnavailable, recoverable }
enum Analytics { static func trackAIFailure(_ event: String, step: String, error: Error) {} }
struct AIFailure {
    let error: Error
    init(_ error: Error) { self.error = error }
    var isQuota: Bool { (error as? SyntheticFailure) == .quota }
    var isUnauthorized: Bool { (error as? SyntheticFailure) == .unauthorized }
    var isServiceUnavailable: Bool { (error as? SyntheticFailure) == .serviceUnavailable }
    var isTrialCapacityUnavailable: Bool { (error as? SyntheticFailure) == .trialCapacityUnavailable }
}
struct NotificationPrefs { var enabled = true; var renders = true }
protocol NotificationPrefsAPI { func notificationPrefs() async throws -> NotificationPrefs? }
protocol LifecycleBaseAPI {}
struct NoPreferencesAPI: LifecycleBaseAPI {}
@MainActor final class LifecycleAPI: LifecycleBaseAPI, NotificationPrefsAPI {
    var preferences: NotificationPrefs? = .init()
    var failPreferences = false; var preferencesRead = 0
    var pausePreferences = false; var preferencesGate: CheckedContinuation<Void, Never>?
    func notificationPrefs() async throws -> NotificationPrefs? {
        preferencesRead += 1
        if pausePreferences { await withCheckedContinuation { preferencesGate = $0 } }
        else { await Task.yield() }
        if failPreferences { throw SyntheticFailure.recoverable }
        return preferences
    }
    func reset() {
        preferences = .init(); failPreferences = false; preferencesRead = 0
        pausePreferences = false; preferencesGate = nil
    }
}
@MainActor final class AppModel {
    var listings: [Listing]; let testAPI = LifecycleAPI(); var api: any LifecycleBaseAPI
    init(_ listings: [Listing]) { self.listings = listings; api = testAPI }
}
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "synthetic-owner"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
// Consent is a boundary double in these cleanup/notification-only scenarios.
// The separate consent batch gate runs the actual consent and full edit body.
@MainActor final class AIConsent {
    static let shared = AIConsent()
    var isGranted = true
    var revocationRevision: UInt64 = 0
}
struct UIBackgroundTaskIdentifier: Hashable { let rawValue: Int; static let invalid = Self(rawValue: -1) }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var began = 0; var ended: [UIBackgroundTaskIdentifier] = []
    var expiration: (() -> Void)?; var refuseBackgroundTask = false
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        began += 1; expiration = expirationHandler
        return refuseBackgroundTask ? .invalid : .init(rawValue: began)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
    func reset() { began = 0; ended = []; expiration = nil; refuseBackgroundTask = false }
}
@MainActor enum IdleTimer {
    static var holds = 0; static var releases = 0
    static func hold() { holds += 1 }
    static func release() { releases += 1; precondition(releases <= holds, "An idle hold was released twice") }
    static func reset() { holds = 0; releases = 0 }
}
enum UNAuthorizationStatus { case authorized, provisional, denied }
struct UNNotificationSettings { var authorizationStatus: UNAuthorizationStatus }
struct UNNotificationSound { static let `default` = Self() }
final class UNMutableNotificationContent {
    var title = ""; var body = ""; var sound: UNNotificationSound?
    var userInfo: [AnyHashable: Any] = [:]
}
struct UNNotificationRequest {
    let identifier: String; let content: UNMutableNotificationContent; let trigger: String?
}
@MainActor final class UNUserNotificationCenter {
    static let shared = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { shared }
    var authorizationStatus = UNAuthorizationStatus.authorized
    var delivered: [UNNotificationRequest] = []; var settingsRead = 0
    var pauseSettings = false; var settingsGate: CheckedContinuation<Void, Never>?
    func notificationSettings() async -> UNNotificationSettings {
        settingsRead += 1
        if pauseSettings { await withCheckedContinuation { settingsGate = $0 } }
        else { await Task.yield() }
        return .init(authorizationStatus: authorizationStatus)
    }
    func add(_ request: UNNotificationRequest) async throws { delivered.append(request) }
    func reset() {
        delivered = []; settingsRead = 0; authorizationStatus = .authorized
        pauseSettings = false; settingsGate = nil
    }
}

@main struct PhotoEditLifecycleTests {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
            preconditionFailure("Synthetic lifecycle did not settle")
        }
        func reset() {
            PhotoWorkQueue.shared.dismissResult(); UIApplication.shared.reset(); IdleTimer.reset()
            UNUserNotificationCenter.shared.reset()
            AuthStore.shared.userID = "synthetic-owner"; AuthStore.shared.syncSessionRevision = 1
            WorkspaceContext.selectedOrgID = UUID()
        }

        reset()
        let listing = Listing(id: UUID())
        let model = AppModel([listing])
        var continuation: CheckedContinuation<Void, Never>?
        var calls: [String] = []
        var service: PhotoEditService? = PhotoEditService(model: model, listing: listing, process: { photo in
            calls.append(photo.id); await withCheckedContinuation { continuation = $0 }
        })
        check(service!.start(title: "Synthetic", photos: [.init(id: "one")], edit: "declutter", style: nil, prompt: nil), "Start navigation-independent work")
        check(IdleTimer.holds == 1 && UIApplication.shared.began == 1, "One owner acquires idle and background leases")
        check(!service!.start(title: "Blocked", photos: [.init(id: "other")], edit: "declutter", style: nil, prompt: nil), "A rejected start acquires no leases")
        check(IdleTimer.holds == 1 && UIApplication.shared.began == 1, "No duplicate leases after a rejected start")
        service = nil // The navigation destination drops its reference.
        await settle { continuation != nil }
        continuation!.resume(); continuation = nil
        await settle { IdleTimer.releases == 1 }
        await settle { UNUserNotificationCenter.shared.delivered.count == 1 }
        check(calls == ["one"] && PhotoWorkQueue.shared.job?.done == 1, "Leaving a screen does not cancel its edit")
        check(UIApplication.shared.ended.count == 1 && IdleTimer.releases == IdleTimer.holds, "Normal completion ends the exact leases once")
        check(UNUserNotificationCenter.shared.delivered[0].content.body.contains("1 of 1 photos changed"), "Notification uses completed output count")
        check(UNUserNotificationCenter.shared.delivered[0].content.userInfo["recipient_user_id"] as? String == AuthStore.shared.userID,
              "Completion notification is tagged to its actual account")

        let stoppingFailures: [any Error] = [SyntheticFailure.quota, SyntheticFailure.unauthorized,
            SyntheticFailure.serviceUnavailable, SyntheticFailure.trialCapacityUnavailable,
            APIError.server(status: 409, code: "photo_clarification_required", message: "Choose a specific edit."),
            APIError.server(status: 400, code: "unsupported_edit", message: "We can't repaint a listing photo.")]
        for failure in stoppingFailures {
            reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]; calls = []
            let refused = PhotoEditService(model: model, listing: listing, process: { photo in
                calls.append(photo.id); throw failure
            })
            check(refused.start(title: "Refused", photos: [.init(id: "one"), .init(id: "never-start")], edit: "declutter", style: nil, prompt: nil), "Start refusal scenario")
            await settle { IdleTimer.releases == 1 }
            check(calls == ["one"] && PhotoWorkQueue.shared.job?.failures.count == 1 && PhotoWorkQueue.shared.job?.done == 0,
                  "Allowance, session, provider and trial capacity refusals stop before uploading another photo")
            check(PhotoWorkQueue.shared.job?.interrupted == true && UIApplication.shared.ended.count == 1 && IdleTimer.holds == IdleTimer.releases,
                  "Refused batch preserves its failure and releases exact leases")
            check(UNUserNotificationCenter.shared.delivered.isEmpty && model.testAPI.preferencesRead == 0,
                  "A stopped batch cannot announce that the photos are ready")
        }

        for boundary in ["owner", "session", "workspace", "delete", "unavailable"] {
            reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]; calls = []
            let scoped = PhotoEditService(model: model, listing: listing, process: { photo in
                calls.append(photo.id); await withCheckedContinuation { continuation = $0 }
            })
            check(scoped.start(title: boundary, photos: [.init(id: "one"), .init(id: "never-start")], edit: "declutter", style: nil, prompt: nil), "Start \(boundary) scenario")
            await settle { continuation != nil }
            switch boundary {
            case "owner": AuthStore.shared.userID = "different-synthetic-owner"
            case "session": AuthStore.shared.syncSessionRevision += 1
            case "workspace": WorkspaceContext.selectedOrgID = UUID()
            case "delete": model.listings = []
            default: model.listings[0].cloudUnavailable = true
            }
            check(!scoped.identityIsCurrent && PhotoWorkQueue.shared.visibleJob == nil, "Fence/hide \(boundary) without waiting for a response")
            continuation!.resume(); continuation = nil
            await settle { IdleTimer.releases == 1 }
            check(calls == ["one"] && PhotoWorkQueue.shared.job == nil, "Stop before next photo after \(boundary)")
            check(UIApplication.shared.ended.count == 1 && IdleTimer.holds == IdleTimer.releases, "Release leases after \(boundary)")
            check(UNUserNotificationCenter.shared.delivered.isEmpty && UNUserNotificationCenter.shared.settingsRead == 0, "No old-context notification after \(boundary)")
        }

        reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]
        let expiring = PhotoEditService(model: model, listing: listing, process: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        check(expiring.start(title: "Expiration", photos: [.init(id: "one"), .init(id: "never-start")], edit: "declutter", style: nil, prompt: nil), "Start expiration scenario")
        await settle { continuation != nil }
        UIApplication.shared.expiration!()
        await settle { UIApplication.shared.ended.count == 1 }
        continuation!.resume(); continuation = nil
        await settle { IdleTimer.releases == 1 }
        check(UIApplication.shared.ended.count == 1, "Completion cannot end an expired background lease twice")
        check(PhotoWorkQueue.shared.job?.interrupted == true && PhotoWorkQueue.shared.job?.done == 0, "Expiration cancels without claiming late output")
        check(UNUserNotificationCenter.shared.delivered.isEmpty && IdleTimer.holds == IdleTimer.releases, "Expiration suppresses success notification and releases idle hold")

        reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]; UIApplication.shared.refuseBackgroundTask = true
        UNUserNotificationCenter.shared.authorizationStatus = .denied
        let denied = PhotoEditService(model: model, listing: listing, process: { _ in await Task.yield() })
        check(denied.start(title: "No system grant", photos: [.init(id: "one")], edit: "declutter", style: nil, prompt: nil), "Foreground work can run without a background grant")
        await settle { IdleTimer.releases == 1 }
        await settle { UNUserNotificationCenter.shared.settingsRead == 1 }
        for _ in 0..<10 { await Task.yield() }
        check(UIApplication.shared.ended.isEmpty && IdleTimer.holds == IdleTimer.releases, "Never end .invalid; still release the idle lease")
        check(UNUserNotificationCenter.shared.delivered.isEmpty, "No request for notification permission or unauthorized notification")

        for preference in ["muted", "renders-off", "missing", "unavailable", "unsupported"] {
            reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]
            switch preference {
            case "muted": model.testAPI.preferences?.enabled = false
            case "renders-off": model.testAPI.preferences?.renders = false
            case "missing": model.testAPI.preferences = nil
            case "unavailable": model.testAPI.failPreferences = true
            default: model.api = NoPreferencesAPI()
            }
            let preferenceScoped = PhotoEditService(model: model, listing: listing, process: { _ in await Task.yield() })
            check(preferenceScoped.start(title: preference, photos: [.init(id: "one")], edit: "declutter", style: nil, prompt: nil), "Start \(preference) scenario")
            await settle { model.testAPI.preferencesRead == (preference == "unsupported" ? 0 : 1) && IdleTimer.releases == 1 }
            for _ in 0..<20 { await Task.yield() }
            check(UNUserNotificationCenter.shared.delivered.isEmpty && UNUserNotificationCenter.shared.settingsRead == 0,
                  "Fail closed on \(preference) before system notification settings")
            check(PhotoWorkQueue.shared.job?.done == 1 && IdleTimer.holds == IdleTimer.releases,
                  "Notification preference cannot change completed output or lease cleanup")
        }

        for boundary in ["preferences-owner", "preferences-workspace", "system-session"] {
            reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]
            if boundary.hasPrefix("preferences") { model.testAPI.pausePreferences = true }
            else { UNUserNotificationCenter.shared.pauseSettings = true }
            let notificationScoped = PhotoEditService(model: model, listing: listing, process: { _ in await Task.yield() })
            check(notificationScoped.start(title: boundary, photos: [.init(id: "one")], edit: "declutter", style: nil, prompt: nil), "Start \(boundary) scenario")
            if boundary.hasPrefix("preferences") {
                await settle { model.testAPI.preferencesGate != nil }
                if boundary == "preferences-owner" { AuthStore.shared.userID = "new-synthetic-owner" }
                else { WorkspaceContext.selectedOrgID = UUID() }
                model.testAPI.preferencesGate!.resume(); model.testAPI.preferencesGate = nil
            } else {
                await settle { UNUserNotificationCenter.shared.settingsGate != nil }
                AuthStore.shared.syncSessionRevision += 1
                UNUserNotificationCenter.shared.settingsGate!.resume(); UNUserNotificationCenter.shared.settingsGate = nil
            }
            for _ in 0..<20 { await Task.yield() }
            check(UNUserNotificationCenter.shared.delivered.isEmpty, "Identity must remain current after \(boundary) await")
            check(UIApplication.shared.ended.count == 1 && IdleTimer.holds == IdleTimer.releases,
                  "Notification wait cannot retain an already completed background/idle lease")
        }

        reset(); model.testAPI.reset(); model.api = model.testAPI; model.listings = [listing]
        UNUserNotificationCenter.shared.authorizationStatus = .provisional
        let provisional = PhotoEditService(model: model, listing: listing, process: { _ in await Task.yield() })
        check(provisional.start(title: "Provisional", photos: [.init(id: "one")], edit: "declutter", style: nil, prompt: nil), "Start provisionally authorized scenario")
        await settle { UNUserNotificationCenter.shared.delivered.count == 1 }
        check(model.testAPI.preferencesRead == 1 && IdleTimer.holds == IdleTimer.releases,
              "Existing provisional system permission plus enabled render preference allows completion without prompting")
        print("PASSED: \(count) actual service lifecycle/identity/cleanup assertions with platform/provider/image boundary doubles")
    }
}
