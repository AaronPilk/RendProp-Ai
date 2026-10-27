import Foundation
import Combine

// Only storage, image decoding, network and UIKit/notification boundaries are
// doubles. The runner compiles the complete actual service and queue plus the
// byte-for-byte consent class. No app preferences, files or provider are used.

// Compile-only boundaries for the new video withdrawal hooks. These fixtures
// continue to execute the exact base AIConsent class; scoped video side effects
// are exercised by run-property-video-processors.py, never by these inert stubs.
@MainActor final class PropertyVideoProcessorConsent {
    static let shared = PropertyVideoProcessorConsent()
    func revoke() {}
}
@MainActor final class PropertyVideoJobCancellation {
    static let shared = PropertyVideoJobCancellation()
    func consentWasRevoked() {}
}

enum UserDefaults {
    static let standard = Foundation.UserDefaults(suiteName: CommandLine.arguments[1])!
}
struct EnhancedPhoto {
    let id: String
    var originalURL: URL { directory(for: UUID()).appendingPathComponent(id + ".jpg") }
    var enhancedURL: URL { originalURL }
    static func directory(for listingID: UUID) -> URL { URL(fileURLWithPath: "/synthetic-photo-consent", isDirectory: true) }
    private func directory(for listingID: UUID) -> URL { Self.directory(for: listingID) }
}
struct Listing {
    let id: UUID
    var cloudUnavailable: Bool? = nil
    var mainPhotoRelPath: String? = nil
    var isSample = false
}
enum SpaceType: String { case realEstate = "real_estate" }
enum CloudSyncError: Error { case identityChanged }
struct AIPhotoEditRequest: Hashable {
    let imageBase64: String
    let mime: String
    let edit: String
    var style: String?; var prompt: String?; var spaceType: String?
    var stagingReferenceBase64: String?; var stagingReferenceMime: String?
    var listingServerID: UUID?; var label: String?; var originalAssetID: String?; var idempotencyKey: String?
}
struct AIPhotoEditResult {
    var imageBase64: String
    var disclosure = "Synthetic AI edit"
    var provenanceID: String? = "synthetic-provenance"
    var provenanceRecorded = true
}
@MainActor enum PhotoBoundary {
    static var pauseStage: String?
    static var pausePhoto: String?
    static var continuation: CheckedContinuation<Void, Never>?
    static var entered: [String] = []
    static var calls: [String] = []
    static var saved: [String] = []
    static var originals: [String: Data] = [:]
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
        entered = []; calls = []; saved = []
        originals = ["one.jpg": Data("original-one".utf8), "two.jpg": Data("original-two".utf8),
                     "three.jpg": Data("original-three".utf8)]
    }
}
@MainActor final class ConsentAPI {
    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult {
        let photo = String(data: Data(base64Encoded: request.imageBase64)!, encoding: .utf8)!
        PhotoBoundary.calls.append(photo)
        await PhotoBoundary.suspend("provider", photo)
        // Image decoding is doubled here; retain the real service's explicit
        // JPEG-header classification before its closed storage boundary.
        return .init(imageBase64: (Data([0xff, 0xd8, 0xff]) + Data((photo + ".edited").utf8)).base64EncodedString())
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
        await PhotoBoundary.suspend("original", fileURL.lastPathComponent)
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
    static func jpegBase64(at url: URL, maxDimension: Int, quality: Double, maxBytes: Int? = nil) async -> String? {
        precondition(maxBytes == nil || maxBytes! > 0 && maxBytes! <= 1_000_000)
        await PhotoBoundary.suspend("image", url.lastPathComponent)
        return Data(url.lastPathComponent.utf8).base64EncodedString()
    }
    nonisolated static func error(_ message: String) -> Error { NSError(domain: "synthetic-photo", code: 1) }
}
// Durable disk storage is outside this consent/queue fixture. The production
// journal has its own real-file/HTTP recovery controls; never replace the
// actual service's grant checks or asynchronous provider boundaries here.
@MainActor enum PhotoPendingEdit {
    struct Identity { let actor: String; let library: UUID; let listing: UUID; let sourceVersion: String }
    struct Saved {
        let request: AIPhotoEditRequest
        let identity: Identity
        let url: URL
        let parentVersion: String?
        let stagingReferenceID: String?
        var outputID: String { "saved-" + request.idempotencyKey!.lowercased() }
    }
    enum Failure: Error { case unavailable }
    static func begin(_ request: AIPhotoEditRequest, identity: Identity, directory: URL,
                      parentVersion: String? = nil, stagingReferenceID: String? = nil) throws -> Saved {
        var retained = request
        retained.idempotencyKey = request.idempotencyKey ?? UUID().uuidString
        return Saved(request: retained, identity: identity, url: directory.appendingPathComponent("synthetic-pending.json"),
                     parentVersion: parentVersion, stagingReferenceID: stagingReferenceID)
    }
    static func read(_ url: URL, directory: URL, expected: Identity) throws -> Saved { throw Failure.unavailable }
    static func finish(_ saved: Saved) throws {}
}
struct UIImage {
    private let data: Data
    init?(data: Data) { self.data = data }
    func jpegData(compressionQuality: Double) -> Data? { data }
}
@MainActor enum PhotoVersionHistory {
    enum Failure: Error { case missingImage, changedVersion, reviewRequired, invalidHistory }
    struct Version {
        var id: String; var imageFile: String; var originalFile: String?; var originalVerified = true
        var effects: [String] = []
        var familyID: String { id }
        var parentID: String? = nil
        var sourceID: String? = nil
        var stagingBaseID: String? = nil
        var edit: String? = nil; var style: String? = nil; var disclosure: String? = nil
        var provenanceID: String? = nil; var originalAssetID: String? = nil; var serverListingID: String? = nil
        var provenanceRecorded = false
__VERSION_SELECTION_MEMBERS__
    }
    // File/history reads remain closed; source/parent selection above them is
    // installed byte-for-byte from the production history implementation.
    struct Index {
        let versions: [String: Version]
        var current: [String: String] { Dictionary(uniqueKeysWithValues: versions.keys.map { ($0, $0) }) }
        let hiddenFamilies: Set<String> = []
        func isVisible(_ id: String) -> Bool { versions[id] != nil }
    }
    static func load(directory: URL) throws -> Index {
        Index(versions: Dictionary(uniqueKeysWithValues: PhotoBoundary.originals.keys.map { file in
            let id = String(file.dropLast(4))
            return (id, Version(id: id, imageFile: file, originalFile: file))
        }))
    }
    static func requireImage(_ name: String, directory: URL) throws {
        guard PhotoBoundary.originals[name] != nil else { throw Failure.missingImage }
    }
    static func trackExisting(id: String, imageFile: String, priorFile: String?, directory: URL) throws -> Version {
        .init(id: id, imageFile: imageFile, originalFile: priorFile ?? imageFile)
    }
__ACTUAL_EDIT_CONTEXT__
    static func stagingReference(id: String, directory: URL) throws -> Version {
        throw Failure.reviewRequired // These consent-only cases never opt in.
    }
    static func savedEditContext(sourceID: String, parentID: String?, directory: URL) throws -> (parent: Version, source: Version) {
        throw Failure.changedVersion // Recovery is outside this consent-only fixture.
    }
    static func saveEdit(jpeg: Data, id: String, parentID: String, sourceID: String, edit: String, style: String?,
                         disclosure: String, provenanceID: String?, provenanceRecorded: Bool, directory: URL,
                         originalAssetID: String?, serverListingID: String?,
                         stagingReferenceID: String? = nil, stagingBrief: String? = nil,
                         imageExtension: String = "jpg") throws -> Version {
        precondition(imageExtension == "jpg" && jpeg.starts(with: [0xff, 0xd8, 0xff]))
        PhotoBoundary.saved.append(String(data: jpeg.dropFirst(3), encoding: .utf8)!)
        return .init(id: id, imageFile: id + ".jpg", originalFile: parentID + ".jpg", effects: [edit])
    }
}
enum FileStore { static func relativePath(for url: URL) -> String { url.path } }
enum PhotoStudioView {
    static func provenanceLabel(edit: String, style: String?, space: SpaceType) -> String { edit }
}
enum Analytics {
    static func track(_ name: String, _ props: [String: String]) {}
    @MainActor static func trackAIFailure(_ tool: String, step: String, error: Error) {}
}
enum FirstProjectGuide { static func recordAIPhotoEditCompleted() {} }
struct AIFailure {
    init(_ error: Error) {}
    var isQuota: Bool { false }; var isUnauthorized: Bool { false }
    var isServiceUnavailable: Bool { false }; var isTrialCapacityUnavailable: Bool { false }
    static func requiresSavedPhotoCheck(_ error: Error) -> Bool { false }
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
final class UNMutableNotificationContent { var title = ""; var body = ""; var sound: UNNotificationSound?; var userInfo: [AnyHashable: Any] = [:] }
struct UNNotificationRequest { let identifier: String; let content: UNMutableNotificationContent; let trigger: String? }
@MainActor final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { Self() }
    func notificationSettings() async -> UNNotificationSettings { .init() }
    func add(_ request: UNNotificationRequest) async throws {}
}

@main struct PhotoConsentBatchTests {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2,
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
        let photos = [EnhancedPhoto(id: "one"), .init(id: "two"), .init(id: "three")]
        let consent = AIConsent.shared
        let queue = PhotoWorkQueue.shared
        func reset(stage: String? = nil, photo: String? = nil) -> PhotoEditService {
            queue.dismissResult(); PhotoBoundary.reset(stage: stage, photo: photo)
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
        print("PASS \(count) actual consent/photo batch assertions; platform/image/provider doubles, no camera or paid calls")
    }
}
