import Foundation
import AVFoundation

enum CloudSyncError: Error { case identityChanged }
enum SyntheticFailure: Error { case lostResponse, transport }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "11111111-1111-4111-8111-111111111111"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor final class AIConsent {
    static let shared = AIConsent()
    var isGranted = true
    var revocationRevision: UInt64 = 1
}
enum FileStore {
    static var documents = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static var aerialsDir: URL {
        let dir = documents.appendingPathComponent("Aerials", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func relativePath(for url: URL) -> String { String(url.path.dropFirst(documents.path.count + 1)) }
    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
struct Listing: Codable {
    let id: UUID
    var isSample = false
    var cloudUnavailable: Bool? = false
    var mainPhotoRelPath: String? = nil
    var aerialRelPath: String? = nil
    var aerialGeneratedAt: Date? = nil
    var aerialURL: URL? { aerialRelPath.map { FileStore.documents.appendingPathComponent($0) } }
}
enum SpaceType: String { case realEstate = "real_estate" }
struct EnhancedPhoto {
    let id: String
    let originalURL: URL
    let enhancedURL: URL
    static func directory(for id: UUID) -> URL { FileStore.documents.appendingPathComponent("Photos/\(id)", isDirectory: true) }
}
// Image encoding is a closed boundary. These tests certify request custody and
// filesystem/history behavior, not photographic quality or UIKit rendering.
struct UIImage: Sendable {
    let bytes: Data
    init?(data: Data) { guard !data.isEmpty else { return nil }; bytes = data }
    func jpegData(compressionQuality: Double) -> Data? { bytes }
}
enum AIImagePrep {
    static func jpegBase64(at url: URL, maxDimension: Int, quality: Double) async -> String? {
        (try? Data(contentsOf: url))?.base64EncodedString()
    }
    static func error(_ text: String) -> Error { NSError(domain: "ClosedRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
enum PhotoStudioView { static func provenanceLabel(edit: String, style: String?, space: SpaceType) -> String { "Closed \(edit)" } }
enum Analytics { static func track(_ name: String, _ attributes: [String: String]) {} }
enum FirstProjectGuide { static func recordAIPhotoEditCompleted() {} }
enum Haptics { static func success() {} }
@MainActor final class APIClient {
    var requests: [AIPhotoEditRequest] = []
    var results: [String: AIPhotoEditResult] = [:]
    var providers = 0
    var loseResponse = true
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var changed: (() -> Void)?
    var statuses: [AIVideoStatus] = []
    var polled: [String] = []
    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult {
        let context = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: listingID)
        Test.check(PendingPhotoEdit.exists(context), "durable photo intent exists before dispatch")
        let key = request.idempotencyKey!
        if let first = requests.first(where: { $0.idempotencyKey == key }) {
            Test.check(first == request, "recovery reuses the exact request body")
        }
        requests.append(request)
        if results[key] == nil { providers += 1; results[key] = AIPhotoEditResult(imageBase64: Data("edited-image".utf8).base64EncodedString(), provenanceID: "owned-provenance", provenanceRecorded: true) }
        if hold { await withCheckedContinuation { pending = $0 } }
        changed?()
        if loseResponse { loseResponse = false; throw SyntheticFailure.lostResponse }
        return results[key]!
    }
    var listingID = UUID()
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        polled.append(job.requestId)
        changed?()
        return statuses.isEmpty ? .processing(queuePosition: nil) : statuses.removeFirst()
    }
}
@MainActor final class AppModel {
    var listings: [Listing]
    let api: APIClient
    var persistFails = false
    var persisted: Data?
    var complianceCalls = 0
    init(_ listing: Listing, api: APIClient) { listings = [listing]; self.api = api }
    func index(of id: UUID) -> Int? { listings.firstIndex { $0.id == id } }
    func persist() -> Bool {
        guard !persistFails else { return false }
        do { let data = try JSONEncoder().encode(listings); try data.write(to: FileStore.documents.appendingPathComponent("fixture-state.json"), options: .atomic); persisted = data; return true } catch { return false }
    }
    func serverListingIDForCompliance(_ id: UUID) async -> UUID? { complianceCalls += 1; return id }
    func publishOriginalForDisclosure(listingServerID: UUID, fileURL: URL) async -> String? { "owned-original" }
    func attachAlteredPhotoForDisclosure(provenanceID: String, listingServerID: UUID, fileURL: URL) async {}
    func setMainPhoto(_ path: String?, for id: UUID) { listings[0].mainPhotoRelPath = path }
    // ACTUAL_SET_AERIAL
}
@MainActor enum RecoveryClock {
    static var now = Date()
    static func sleep() async throws { try Task.checkCancellation(); now = now.addingTimeInterval(1000) }
}
@MainActor enum DownloadBoundary {
    static var mode = "video"
    static var changed: (() -> Void)?
    static var calls = 0
    static func download(from url: URL) async throws -> (URL, URLResponse) {
        calls += 1
        changed?()
        if mode == "throw" { throw SyntheticFailure.transport }
        let temp = FileStore.documents.appendingPathComponent("download-\(UUID()).mp4")
        let data: Data
        switch mode {
        case "empty": data = Data()
        case "html": data = Data("<html>not video</html>".utf8)
        default: data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        try data.write(to: temp)
        return (temp, HTTPURLResponse(url: url, statusCode: mode == "http" ? 502 : 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class AerialHarness {
    let model: AppModel
    enum Phase { case form, generating, result }
    var statusText = ""
    var player: AVPlayer?
    var clipURL: URL?
    var grounded: Bool?
    var disclosureText: String?
    var resultPortrait = false
    var measuredAspect: Double?
    var savedToPhotos = false
    var saveError: String?
    var failure: String?
    var phase = Phase.generating
    init(_ model: AppModel) { self.model = model }
    // ACTUAL_POLL_AND_STORE
}
struct AIFailure {
    init(_ error: Error) {}
    // ACTUAL_HUMAN_READABLE
}
@MainActor final class ForgetHarness {
    let listing: Listing
    let auth = AuthStore.shared
    var photoForgetRevision: UInt64?
    var isProcessing = false
    var photoRequestToForget: PendingPhotoEdit?
    var aiFailure: AIFailure?
    init(_ listing: Listing) { self.listing = listing }
    // ACTUAL_PHOTO_REQUEST_CONTEXT
    func confirm(_ pending: PendingPhotoEdit) {
        // ACTUAL_FORGET_ACTION
    }
}
@MainActor enum Test {
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        guard ok else { fatalError(message) }; checks += 1
    }
    static func refuse(_ message: String, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError(message) } catch { checks += 1 }
    }
    static func setup() throws -> (Listing, EnhancedPhoto, APIClient, AppModel) {
        AuthStore.shared.userID = "11111111-1111-4111-8111-111111111111"
        AuthStore.shared.syncSessionRevision += 1; WorkspaceContext.selectedOrgID = UUID()
        AIConsent.shared.isGranted = true
        let listing = Listing(id: UUID())
        let directory = EnhancedPhoto.directory(for: listing.id)
        try PhotoVersionHistory.saveCapture(original: Data("immutable-original".utf8), enhanced: Data("enhanced-source".utf8), id: "source", directory: directory)
        let photo = EnhancedPhoto(id: "source", originalURL: directory.appendingPathComponent("orig-source.jpg"), enhancedURL: directory.appendingPathComponent("enh-source.jpg"))
        let api = APIClient(); api.listingID = listing.id
        return (listing, photo, api, AppModel(listing, api: api))
    }
    static func edit(_ service: PhotoEditService, _ photo: EnhancedPhoto, prompt: String? = nil) async throws {
        try await service.edit(photo, edit: "declutter", style: nil, prompt: prompt, batch: false)
    }
    static func photoTests() async throws {
        let (listing, photo, api, model) = try setup()
        let context = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: listing.id)
        await refuse("lost response must remain unresolved") { try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), photo) }
        let pending = try PendingPhotoEdit.load(context)!
        check(api.providers == 1, "one provider operation was admitted")
        await refuse("different intent must not dispatch") { try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), photo, prompt: "different") }
        check(api.requests.count == 1, "different intent permits no extra request")
        try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), photo)
        check(api.providers == 1 && api.requests.count == 2, "lost response recovery uses one provider operation")
        check(api.requests[0].idempotencyKey == api.requests[1].idempotencyKey, "recovery uses original request key")
        check(try PendingPhotoEdit.load(context) == nil, "saved photo retires only its pending metadata")
        let history = try PhotoVersionHistory.load(directory: photo.enhancedURL.deletingLastPathComponent())
        check(history.versions[pending.versionID] != nil && history.versions.count == 2, "one preallocated immutable version is saved")
        check(try Data(contentsOf: photo.originalURL) == Data("immutable-original".utf8), "recovery preserves original bytes")
        // A saved local commit plus an uncleared receipt does not repeat the POST.
        try pending.saveBeforeDispatch()
        try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), photo)
        check(api.requests.count == 2, "completed local save needs no replay POST")
        let current = history.versions[pending.versionID]!
        let next = EnhancedPhoto(id: current.id, originalURL: photo.originalURL, enhancedURL: photo.enhancedURL.deletingLastPathComponent().appendingPathComponent(current.imageFile))
        try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), next)
        check(api.providers == 2, "explicit reroll after save gets a separate operation")
        // Background cancellation after the server completes leaves durable custody.
        let (l2, p2, a2, m2) = try setup(); a2.hold = true; a2.loseResponse = false
        let c2 = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: l2.id)
        let work = Task { try await edit(PhotoEditService(model: m2, listing: l2, space: .realEstate), p2) }
        while a2.pending == nil { await Task.yield() }
        work.cancel(); a2.pending?.resume(); a2.pending = nil
        do { try await work.value; fatalError("cancelled background work must not save") } catch { checks += 1 }
        check(PendingPhotoEdit.exists(c2), "background interruption retains request")
        a2.hold = false
        try await edit(PhotoEditService(model: m2, listing: l2, space: .realEstate), p2)
        check(a2.providers == 1, "background recovery does not create second provider operation")
        for transition in ["actor", "revision", "workspace", "consent"] {
            let (l, p, a, m) = try setup(); a.loseResponse = false
            let c = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: l.id)
            a.changed = { if transition == "actor" { AuthStore.shared.userID = "replacement" }; if transition == "revision" { AuthStore.shared.syncSessionRevision += 1 }; if transition == "workspace" { WorkspaceContext.selectedOrgID = UUID() }; if transition == "consent" { AIConsent.shared.isGranted = false } }
            if transition == "consent" {
                try await edit(PhotoEditService(model: m, listing: l, space: .realEstate), p)
                check(!PendingPhotoEdit.exists(c), "already submitted result survives consent revocation")
            } else {
                await refuse("late photo context cannot save") { try await edit(PhotoEditService(model: m, listing: l, space: .realEstate), p) }
                check(PendingPhotoEdit.exists(c), "late photo response retains original context receipt")
                check(try PhotoVersionHistory.load(directory: p.enhancedURL.deletingLastPathComponent()).versions.count == 1, "late photo result cannot attach to replacement context")
            }
        }
        let (l3, p3, a3, m3) = try setup()
        let c3 = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: l3.id)
        await refuse("lost response") { try await edit(PhotoEditService(model: m3, listing: l3, space: .realEstate), p3) }
        try Data("changed-source".utf8).write(to: p3.enhancedURL)
        await refuse("source mutation refuses replay") { try await edit(PhotoEditService(model: m3, listing: l3, space: .realEstate), p3) }
        check(a3.requests.count == 1 && PendingPhotoEdit.exists(c3), "changed source permits no second paid request")
        let retained = try PendingPhotoEdit.load(c3)!
        try retained.clear()
        check(FileStore.fileSize(p3.originalURL) > 0 && FileStore.fileSize(p3.enhancedURL) > 0, "explicit forget preserves all photo files")
        let target = PendingPhotoEdit.file(c3)
        try Data("broken-journal".utf8).write(to: target)
        await refuse("unreadable receipt refuses new edit") { try await edit(PhotoEditService(model: m3, listing: l3, space: .realEstate), p3) }
        check(try a3.requests.count == 1 && Data(contentsOf: target) == Data("broken-journal".utf8), "unreadable receipt stays intact without dispatch")
    }
    static func aerialTests() async throws {
        for mode in ["deadline", "throw", "http", "empty", "html", "persist", "actor", "revision", "workspace", "terminal", "success"] {
            let (listing, _, api, model) = try setup()
            let old = FileStore.aerialsDir.appendingPathComponent("previous-\(UUID()).mp4")
            try Data("previous-clip".utf8).write(to: old)
            model.listings[0].aerialRelPath = FileStore.relativePath(for: old)
            _ = model.persist(); let oldState = model.persisted
            try AerialMeta(grounded: false, aspect: "old", disclosure: "previous disclosure").save(for: listing.id)
            let job = AIVideoJob(requestId: "owned-\(UUID())", statusUrl: "closed-status", responseUrl: "closed-response", kind: "aerial", grounded: true)
            let receipt = PendingAerialJob(job: job, listingID: listing.id, submittedAt: RecoveryClock.now.addingTimeInterval(-10000), grounded: true, aspect: "16:9", owner: AuthStore.shared.userID, workspace: WorkspaceContext.selectedOrgID)
            try receipt.save()
            DownloadBoundary.mode = ["throw", "http", "empty", "html"].contains(mode) ? mode : "video"
            DownloadBoundary.calls = 0; DownloadBoundary.changed = nil
            api.statuses = mode == "deadline" ? [] : mode == "terminal" ? [.failed("confirmed failure")] : [.completed(videoURL: URL(string: "https://closed.invalid/owned.mp4")!)]
            let revision = AuthStore.shared.syncSessionRevision
            if mode == "persist" { model.persistFails = true }
            if ["actor", "revision", "workspace"].contains(mode) {
                DownloadBoundary.changed = { if mode == "actor" { AuthStore.shared.userID = "replacement" }; if mode == "revision" { AuthStore.shared.syncSessionRevision += 1 }; if mode == "workspace" { WorkspaceContext.selectedOrgID = UUID() } }
            }
            let harness = AerialHarness(model)
            if mode == "success" {
                try await harness.pollAndStore(receipt, api: api, revision: revision)
                check(!PendingAerialJob.exists(for: listing.id), "successful durable aerial retires receipt")
                check(!FileManager.default.fileExists(atPath: old.path), "previous clip removed only after durable replacement")
                check(harness.phase == .result && FileStore.fileSize(harness.clipURL!) > 0, "usable video attached and presented")
                check(model.persisted != oldState && AerialMeta.load(for: listing.id)?.aspect == "16:9", "listing attachment and metadata persisted")
            } else {
                await refuse("unconfirmed or failed aerial must not be presented as saved") { try await harness.pollAndStore(receipt, api: api, revision: revision) }
                check(PendingAerialJob.exists(for: listing.id) == (mode != "terminal"), "local aerial failure retains receipt except confirmed terminal failure")
                check(FileStore.fileSize(old) > 0, "aerial failure preserves previous clip")
                check(model.listings[0].aerialURL == old && model.persisted == oldState && harness.phase != .result, "failed or stale aerial cannot replace stored listing")
                check(AerialMeta.load(for: listing.id)?.aspect == "old", "failed attachment preserves previous metadata")
            }
            if mode == "deadline" { check(DownloadBoundary.calls == 0 && api.polled.count == 1, "deadline stops polling without another submission") }
            try? receipt.clear()
        }
        let (listing, _, _, _) = try setup()
        let legacy = PendingAerialJob(job: AIVideoJob(requestId: "legacy", statusUrl: "s", responseUrl: "r", kind: "aerial"), listingID: listing.id, submittedAt: Date().addingTimeInterval(-86400), grounded: false, aspect: "16:9", owner: nil, workspace: nil)
        try legacy.save()
        check(PendingAerialJob.load(for: listing.id) != nil, "old receipt is retained beyond former two hour expiry")
        let (_, _, api, model) = try setup()
        let harness = AerialHarness(model)
        await refuse("unbound legacy receipt cannot poll") { try await harness.pollAndStore(legacy, api: api, revision: AuthStore.shared.syncSessionRevision) }
        check(api.polled.isEmpty && PendingAerialJob.exists(for: listing.id), "legacy receipt stays support recoverable without new account poll")
        try legacy.clear()
    }
    static func confirmationTests() async throws {
        for change in ["actor", "revision", "workspace", "replacement", "same"] {
            let (listing, photo, api, model) = try setup()
            await refuse("lost response") { try await edit(PhotoEditService(model: model, listing: listing, space: .realEstate), photo) }
            let context = PendingPhotoEdit.Context(owner: AuthStore.shared.userID!, workspace: WorkspaceContext.selectedOrgID, listingID: listing.id)
            let captured = try PendingPhotoEdit.load(context)!
            let dialog = ForgetHarness(listing); dialog.photoForgetRevision = AuthStore.shared.syncSessionRevision
            dialog.photoRequestToForget = captured
            if change == "actor" { AuthStore.shared.userID = "replacement" }
            if change == "revision" { AuthStore.shared.syncSessionRevision += 2 } // Includes A -> B -> A.
            if change == "workspace" { WorkspaceContext.selectedOrgID = UUID() }
            if change == "replacement" {
                try captured.clear()
                let replacement = try PendingPhotoEdit(context: context, source: captured.source, request: captured.request.value)
                try replacement.saveBeforeDispatch(); dialog.photoRequestToForget = replacement
            }
            // Confirmation receives the immutable originally presented receipt.
            dialog.confirm(captured)
            check(PendingPhotoEdit.exists(context) == (change != "same"), "stale or replaced confirmation cannot forget another request")
            check(FileStore.fileSize(photo.originalURL) > 0 && FileStore.fileSize(photo.enhancedURL) > 0, "forget confirmation leaves source images untouched")
            check(api.requests.count == 1, "forget confirmation never submits another edit")
        }
        let text = AIFailure.humanReadable("HTTP 502: {\"detail\":\"unknown\"}")
        check(text.contains("billing outcome could not be confirmed") && !text.contains("Nothing"), "machine errors never infer nothing was charged")
        check(AIFailure.humanReadable("Choose a source photo") == "Choose a source photo", "specific actionable service text is preserved")
    }
}
@main struct Main {
    static func main() async throws {
        try FileManager.default.createDirectory(at: FileStore.documents, withIntermediateDirectories: true)
        try await Test.photoTests(); try await Test.aerialTests(); try await Test.confirmationTests()
        print("PASS AI output recovery: \(await Test.checks) checks; no provider, network or camera calls")
    }
}
