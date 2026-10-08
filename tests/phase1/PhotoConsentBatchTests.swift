import Foundation
import Combine

// Image preparation/decoding, network and UIKit/notification boundaries are
// closed doubles. Actual consent, complete service/queue, request contracts,
// history and capture storage execute against owned disposable files/preferences.
// No production account, customer file, camera or paid provider is used.
enum UserDefaults {
    static let standard = Foundation.UserDefaults(suiteName: CommandLine.arguments[1])!
}
struct EnhancedPhoto {
    let id: String
    var originalURL: URL { Self.directory(for: FileStore.listingID).appendingPathComponent("orig-" + id + ".jpg") }
    var enhancedURL: URL { Self.directory(for: FileStore.listingID).appendingPathComponent("enh-" + id + ".jpg") }
    static func directory(for listingID: UUID) -> URL { FileStore.documents.appendingPathComponent("Photos/\(listingID.uuidString)", isDirectory: true) }
}
struct Listing {
    let id: UUID
    var cloudUnavailable: Bool? = nil
    var mainPhotoRelPath: String? = nil
    var isSample = false
}
enum SpaceType: String { case realEstate = "real_estate" }
enum CloudSyncError: Error { case identityChanged }
@MainActor enum PhotoBoundary {
    static var pauseStage: String?
    static var pausePhoto: String?
    static var continuation: CheckedContinuation<Void, Never>?
    static var entered: [String] = []
    static var calls: [String] = []
    static var saved: [String] {
        let directory = EnhancedPhoto.directory(for: FileStore.listingID)
        guard let index = try? PhotoVersionHistory.load(directory: directory) else { return [] }
        return index.versions.values.filter { $0.edit == "declutter" }.sorted { $0.createdAt < $1.createdAt }
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0.imageFile), encoding: .utf8) }
    }
    static var originals: [String: Data] {
        let directory = EnhancedPhoto.directory(for: FileStore.listingID)
        return Dictionary(uniqueKeysWithValues: ["one", "two", "three"].compactMap { id in
            (try? Data(contentsOf: directory.appendingPathComponent("orig-" + id + ".jpg")))
                .map { (id + ".jpg", $0) }
        })
    }
    static func logicalPhoto(_ name: String) -> String {
        name.hasPrefix("orig-") ? String(name.dropFirst(5)) : name.hasPrefix("enh-") ? String(name.dropFirst(4)) : name
    }
    static func suspend(_ stage: String, _ photo: String) async {
        entered.append(stage + ":" + photo)
        if stage == pauseStage && photo == pausePhoto {
            await withCheckedContinuation { continuation = $0 }
        }
    }
    static func release() { let gate = continuation; continuation = nil; gate?.resume() }
    static func reset(stage: String? = nil, photo: String? = nil) {
        precondition(continuation == nil)
        pauseStage = stage; pausePhoto = photo
        entered = []; calls = []
        FileStore.documents = FileStore.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = EnhancedPhoto.directory(for: FileStore.listingID)
        for id in ["one", "two", "three"] {
            try! PhotoVersionHistory.saveCapture(original: Data(("original-" + id).utf8),
                enhanced: Data(("enhanced-" + id).utf8), id: id, directory: directory)
        }
    }
}
@MainActor final class ConsentAPI {
    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult {
        let photo = String(data: Data(base64Encoded: request.imageBase64)!, encoding: .utf8)!
        PhotoBoundary.calls.append(photo)
        await PhotoBoundary.suspend("provider", photo)
        return .init(imageBase64: Data((photo + ".edited").utf8).base64EncodedString(),
                     disclosure: "Synthetic AI edit", provenanceID: "synthetic-provenance", provenanceRecorded: true)
    }
}
struct NotificationPrefs { var enabled = true; var renders = true }
protocol NotificationPrefsAPI { func notificationPrefs() async throws -> NotificationPrefs? }
@MainActor final class AppModel {
    var listings: [Listing]
    let api = ConsentAPI()
    init(_ listing: Listing) { listings = [listing] }
    func serverListingIDForCompliance(_ id: UUID) async -> UUID? {
        let photo = PhotoBoundary.entered.last?.components(separatedBy: ":").last ?? "unknown"
        await PhotoBoundary.suspend("listing", photo)
        return id
    }
    func publishOriginalForDisclosure(listingServerID: UUID, fileURL: URL) async -> String? {
        await PhotoBoundary.suspend("original", PhotoBoundary.logicalPhoto(fileURL.lastPathComponent))
        return "synthetic-original-asset"
    }
    func attachAlteredPhotoForDisclosure(provenanceID: String, listingServerID: UUID, fileURL: URL) async {
        await Task.yield()
    }
    func setMainPhoto(_ path: String, for id: UUID) { listings[0].mainPhotoRelPath = path }
}
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "synthetic-owner"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor enum AIImagePrep {
    static func jpegBase64(at url: URL, maxDimension: Int, quality: Double) async -> String? {
        guard (try? Data(contentsOf: url)) != nil else { return nil }
        let logical = PhotoBoundary.logicalPhoto(url.lastPathComponent)
        await PhotoBoundary.suspend("image", logical)
        return Data(logical.utf8).base64EncodedString()
    }
    nonisolated static func error(_ message: String) -> Error { NSError(domain: "synthetic-photo", code: 1) }
}
struct UIImage {
    private let data: Data
    init?(data: Data) { self.data = data }
    func jpegData(compressionQuality: Double) -> Data? { data }
}
enum FileStore {
    static var listingID = UUID()
    static let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    static var documents = root
    static func relativePath(for url: URL) -> String { url.path }
    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
enum PhotoStudioView {
    static func provenanceLabel(edit: String, style: String?, space: SpaceType) -> String { edit }
}
enum Analytics { static func track(_ name: String, _ props: [String: String]) {} }
enum FirstProjectGuide { static func recordAIPhotoEditCompleted() {} }
struct AIFailure {
    init(_ error: Error) {}
    var isQuota: Bool { false }; var isUnauthorized: Bool { false }
}
struct UIBackgroundTaskIdentifier: Equatable {
    let value: Int
    static let invalid = Self(value: -1)
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        .init(value: 1)
    }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}
@MainActor enum IdleTimer { static func hold() {}; static func release() {} }
enum UNAuthorizationStatus { case authorized, provisional, denied }
struct UNNotificationSettings { var authorizationStatus = UNAuthorizationStatus.denied }
struct UNNotificationSound { static let `default` = Self() }
final class UNMutableNotificationContent { var title = ""; var body = ""; var sound: UNNotificationSound? }
struct UNNotificationRequest { let identifier: String; let content: UNMutableNotificationContent; let trigger: String? }
@MainActor final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { Self() }
    func notificationSettings() async -> UNNotificationSettings { .init() }
    func add(_ request: UNNotificationRequest) async throws {}
}

@main struct PhotoConsentBatchTests {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1].hasPrefix("com.rendprop.offline-photo-consent.") else { exit(2) }
        defer { Foundation.UserDefaults.standard.removePersistentDomain(forName: CommandLine.arguments[1]) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !condition() { print("FAIL: " + message); exit(1) }
        }
        func settle(_ predicate: @MainActor () -> Bool) async {
            for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
            print("FAIL: offline photo consent scenario did not settle"); exit(1)
        }
        let listing = Listing(id: UUID())
        let model = AppModel(listing)
        FileStore.listingID = listing.id
        let photos = [EnhancedPhoto(id: "one"), .init(id: "two"), .init(id: "three")]
        let consent = AIConsent.shared
        let queue = PhotoWorkQueue.shared
        func reset(stage: String? = nil, photo: String? = nil) -> PhotoEditService {
            queue.dismissResult(); PhotoBoundary.reset(stage: stage, photo: photo)
            AuthStore.shared.userID = "synthetic-owner"
            AuthStore.shared.syncSessionRevision += 1
            WorkspaceContext.selectedOrgID = UUID()
            consent.grant()
            return PhotoEditService(model: model, listing: listing, space: .realEstate)
        }
        func start(_ service: PhotoEditService) {
            check(service.start(title: "Synthetic consent batch", photos: photos, edit: "declutter", style: nil, prompt: nil),
                  "Consented batch starts")
        }

        // Reproduce the reported sequence first, so the former behavior fails
        // on a second provider dispatch rather than an unrelated source check.
        let inFlight = reset(stage: "provider", photo: "one.jpg")
        let originalSnapshot = PhotoBoundary.originals
        start(inFlight)
        await settle { PhotoBoundary.continuation != nil }
        consent.revoke()
        PhotoBoundary.release()
        await settle { queue.job?.running == false }
        check(PhotoBoundary.calls == ["one.jpg"], "Revocation after dispatch must prevent the second provider request")
        check(PhotoBoundary.saved == ["one.jpg.edited"], "An already-dispatched response remains saved after consent revocation")
        check(PhotoBoundary.originals == originalSnapshot, "Consent revocation never deletes or rewrites originals")
        check(queue.job?.done == 1 && queue.job?.interrupted == true && queue.job?.failures.isEmpty == true,
              "Interrupted batch counts its saved response and does not label unsent photos as failed provider jobs")
        check(queue.job?.remaining == 2, "Unsent photos remain unattempted")

        let stale = reset(stage: "provider", photo: "one.jpg")
        start(stale); await settle { PhotoBoundary.continuation != nil }
        consent.revoke(); consent.grant(); PhotoBoundary.release()
        await settle { queue.job?.running == false }
        check(PhotoBoundary.calls == ["one.jpg"], "A later grant must not revive a batch authorized by the revoked grant")
        check(PhotoBoundary.saved == ["one.jpg.edited"], "Regrant does not discard an already-dispatched result")
        check(!stale.start(title: "Stale grant", photos: photos, edit: "declutter", style: nil, prompt: nil),
              "The old service cannot start a new queue with its revoked grant")

        for stage in ["image", "listing", "original"] {
            for regrant in [false, true] {
                let preparing = reset(stage: stage, photo: "two.jpg")
                let originals = PhotoBoundary.originals
                start(preparing); await settle { PhotoBoundary.continuation != nil }
                check(PhotoBoundary.calls == ["one.jpg"] && PhotoBoundary.saved == ["one.jpg.edited"],
                      "Second-photo \(stage) pause happens after the first completed edit")
                consent.revoke(); if regrant { consent.grant() }
                PhotoBoundary.release(); await settle { queue.job?.running == false }
                check(PhotoBoundary.calls == ["one.jpg"], "Revocation across \(stage) await fences the unsent second request (regrant=\(regrant))")
                check(PhotoBoundary.saved == ["one.jpg.edited"] && PhotoBoundary.originals == originals,
                      "Preparation revocation retains completed edit and originals")
                check(queue.job?.done == 1 && queue.job?.interrupted == true && queue.job?.failures.isEmpty == true,
                      "Consent stops a preparing photo without a false provider failure")
            }
        }

        let beforeFirst = reset()
        start(beforeFirst)
        consent.revoke() // The queued task has not had its first actor turn.
        await settle { queue.job?.running == false }
        check(PhotoBoundary.entered.isEmpty && PhotoBoundary.calls.isEmpty && PhotoBoundary.saved.isEmpty,
              "Revocation after queue admission stops even the first unsent photo")
        check(queue.job?.done == 0 && queue.job?.attempted == 0 && queue.job?.interrupted == true,
              "Admission-time revocation reports unattempted work rather than a provider failure")

        queue.dismissResult(); PhotoBoundary.reset(); consent.revoke()
        let ungranted = PhotoEditService(model: model, listing: listing, space: .realEstate)
        check(!ungranted.start(title: "No grant", photos: photos, edit: "declutter", style: nil, prompt: nil),
              "An ungranted new batch cannot enter the work queue")
        do {
            try await ungranted.edit(photos[0], edit: "declutter", style: nil, prompt: nil, batch: false)
            check(false, "Direct edit call must require current consent")
        } catch is CancellationError {} catch { check(false, "Direct ungranted call must stop before preparation") }
        check(PhotoBoundary.entered.isEmpty && PhotoBoundary.calls.isEmpty, "Direct call without consent does not prepare or dispatch media")

        let fresh = reset()
        start(fresh); await settle { queue.job?.running == false }
        check(PhotoBoundary.calls == ["one.jpg", "two.jpg", "three.jpg"], "A fresh service after renewed consent can complete a new batch")
        check(PhotoBoundary.saved.count == 3 && queue.job?.done == 3 && queue.job?.interrupted == false,
              "Unrevoked consent preserves normal sequential edit completion")
        // A paid response remains owned by the actor/workspace that submitted
        // it. Real local journals/history let this verify file custody too.
        for change in ["actor", "revision", "workspace"] {
            let response = reset(stage: "provider", photo: "one.jpg")
            let context = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!,
                workspace: WorkspaceContext.selectedOrgID, listingID: listing.id)
            let originals = PhotoBoundary.originals
            start(response); await settle { PhotoBoundary.continuation != nil }
            check(PendingPhotoEdit.exists(context), "Durable request exists before provider response")
            if change == "actor" { AuthStore.shared.userID = "replacement-owner" }
            if change == "revision" { AuthStore.shared.syncSessionRevision += 1 }
            if change == "workspace" { WorkspaceContext.selectedOrgID = UUID() }
            PhotoBoundary.release(); await settle { queue.job == nil }
            check(PhotoBoundary.saved.isEmpty, "Late account/workspace response must not save into replacement context")
            check(PhotoBoundary.calls == ["one.jpg"], "Identity transition fences every unsent second request")
            check(PhotoBoundary.originals == originals && originals.count == 3,
                  "Identity transition preserves real original files")
            check(PendingPhotoEdit.exists(context), "Unconfirmed old-context request is retained for recovery")
            check(queue.visibleJob == nil, "Replacement context cannot see another owner's batch")
        }
        print("PASS \(count) actual consent/photo batch assertions; actual owned files/history, platform/image/provider doubles, no camera or paid calls")
    }
}
