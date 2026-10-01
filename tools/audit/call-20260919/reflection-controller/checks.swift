import Foundation
import Combine

struct TimeRange: Codable, Hashable { var startS: Double; var endS: Double }
struct ReflectionClip: Codable, Hashable, Identifiable {
    var id = UUID(); var startS: Double; var endS: Double
    var durationS: Double { endS - startS }
}
struct CaptureAsset: Codable, Hashable {
    var id = UUID(); var localURL: URL; var motionSidecarURL: URL?
    var durationS = 20.0; var fps = 30.0; var width = 320; var height = 240
    var bytes: Int64 = 16; var isDrone = false; var roomTags: [String] = []
    var personVisibleRanges: [TimeRange] = []
}
struct Listing { var id = UUID() }
struct AIVideoJob: Codable { let requestId: String }
enum AIVideoStatus { case completed(URL), failed(String), processing }
enum APIError: LocalizedError {
    case notConfigured, decoding, invalidURL, badResponse(Int)
    case server(status: Int, code: String?, message: String)
    var status: Int? {
        switch self { case .badResponse(let s), .server(let s, _, _): return s; default: return nil }
    }
    var errorDescription: String? {
        if case .server(_, _, let message) = self { return message }; return "Offline test error"
    }
}
struct UploadMetadata { var durationS: Double; var fps: Double; var width: Int; var height: Int; var bytes: Int64 }
enum FileStore {
    static var documents = URL(fileURLWithPath: "/unused")
    static func relativePath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(documents.standardizedFileURL.path.count + 1))
    }
    static func url(fromRelativePath path: String) -> URL { documents.appendingPathComponent(path) }
    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
    static func freeSpaceBytes() -> Int64 { 100_000_000_000 }
}
enum Config { static let useLiveBackend = true }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    @Published var userID: String? = "owner-a"
    func ensureSession() async -> Bool { userID != nil }
}
@MainActor final class AIConsent {
    static let shared = AIConsent()
    func ensureGranted() async -> Bool { true }
}
@MainActor final class Gate {
    var arrivals = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrivals += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } }
}
@MainActor enum Boundaries {
    static var extractGate: Gate?
    static var uploadGate: Gate?
    static var invalidOutput = false
    static var duration: [String: Double] = [:]
}
@MainActor enum ReflectionVideo {
    enum Failure: LocalizedError {
        case insufficientSpace, exportFailed, noVideo, changedDuration, changedFraming, invalidRange
        var errorDescription: String? { "Unusable generated video" }
    }
    static func extract(source: URL, clip: ReflectionClip, destination: URL) async throws {
        if let gate = Boundaries.extractGate { await gate.wait() }
        try Data(repeating: 1, count: 16).write(to: destination)
        Boundaries.duration[destination.path] = clip.durationS
    }
    static func splice(source: URL, replacements: [(ReflectionClip, URL)], destination: URL) async throws {
        try Data(repeating: 2, count: 16).write(to: destination)
        Boundaries.duration[destination.path] = 20
    }
}
@MainActor enum MediaImporter {
    struct Probe {
        var duration: Double; var hasVideoTrack = true; var isPlayable = true
        var fps = 30.0; var width = 320; var height = 240
    }
    static func probe(url: URL) async -> Probe {
        let output = url.lastPathComponent.hasPrefix("output-")
        return Probe(duration: output ? (Boundaries.invalidOutput ? 8 : 3) : (Boundaries.duration[url.path] ?? 20))
    }
    static func makeAsset(from url: URL, isDrone: Bool, deleteOnFailure: Bool) async throws -> CaptureAsset {
        CaptureAsset(localURL: url)
    }
}
@MainActor final class UploadManager {
    static let shared = UploadManager()
    var uploads: [URL] = []
    func upload(fileURL: URL, listingID: UUID, role: String, metadata: UploadMetadata) async throws -> String {
        uploads.append(fileURL)
        if let gate = Boundaries.uploadGate { await gate.wait() }
        return "asset-" + UUID().uuidString
    }
}
@MainActor final class URLSession {
    static let shared = URLSession()
    func download(from url: URL) async throws -> (URL, URLResponse) {
        let destination = FileStore.documents.appendingPathComponent("fake-download-" + UUID().uuidString)
        try Data(repeating: 3, count: 16).write(to: destination)
        return (destination, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor protocol APIClient {
    func reflectionQuote(listingID: UUID) async throws -> ReflectionQuote
    func removeReflections(assetID: String, listingID: UUID, batchID: UUID, idempotencyKey: UUID) async throws -> AIVideoJob
    func cancelReflectionBatch(_ batchID: UUID) async throws
    func applyReflectionBatch(_ batchID: UUID, originalAssetID: String, alteredAssetID: String) async throws -> ReflectionApplication
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus
}
// REAL_API
@MainActor final class FakeAPI: APIClient {
    var jobs: [UUID: AIVideoJob] = [:]
    var submissions: [UUID] = []
    var cancelled = Set<UUID>()
    var applied = Set<UUID>()
    var cancelCalls = 0
    var applyCalls = 0
    var loseSubmitResponseOnce = false
    var rejectedSubmission: Int?
    var submissionRejectionStatus = 402
    var applyGate: Gate?
    var failCancellation = false
    func reflectionQuote(listingID: UUID) async throws -> ReflectionQuote {
        ReflectionQuote(available: true, remainingClips: 20, maxClipSeconds: 4.8, maxBatchCents: 240, unitCostCents: 4)
    }
    func removeReflections(assetID: String, listingID: UUID, batchID: UUID, idempotencyKey: UUID) async throws -> AIVideoJob {
        if cancelled.contains(batchID) { throw APIError.badResponse(409) }
        submissions.append(idempotencyKey)
        if submissions.count == rejectedSubmission {
            throw APIError.server(status: submissionRejectionStatus, code: nil, message: "Synthetic definitive or retryable clip rejection")
        }
        let job = jobs[idempotencyKey] ?? AIVideoJob(requestId: idempotencyKey.uuidString)
        jobs[idempotencyKey] = job
        if loseSubmitResponseOnce { loseSubmitResponseOnce = false; throw URLError(.timedOut) }
        return job
    }
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        .completed(URL(string: "https://generated.invalid/offline-fixture.mp4")!)
    }
    func cancelReflectionBatch(_ batchID: UUID) async throws {
        cancelCalls += 1
        if failCancellation { throw URLError(.notConnectedToInternet) }
        if applied.contains(batchID) { throw APIError.badResponse(409) }
        cancelled.insert(batchID)
    }
    func applyReflectionBatch(_ batchID: UUID, originalAssetID: String, alteredAssetID: String) async throws -> ReflectionApplication {
        applyCalls += 1
        if cancelled.contains(batchID) { throw APIError.badResponse(409) }
        applied.insert(batchID)
        if applyCalls == 1, let gate = applyGate { await gate.wait() }
        return ReflectionApplication(disclosure: "People and reflections were removed using AI.", provenance: ReflectionProvenance(id: batchID.uuidString, recorded: true))
    }
}
@MainActor final class AppModel {
    let api: FakeAPI
    var assets: [UUID: CaptureAsset] = [:]
    var listings: [Listing] = []
    init() { self.api = FakeAPI() }
    func ensureServerListing(_ listing: Listing) async throws -> UUID { listing.id }
}
// REAL_CONTROLLER

@MainActor func waitUntil(_ predicate: @escaping () -> Bool) async throws {
    let until = Date().addingTimeInterval(8)
    while !predicate() && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
    precondition(predicate(), "Timed out awaiting controlled boundary")
}
@MainActor func fixture() throws -> (ReflectionRemoval, AppModel, Listing, CaptureAsset) {
    Boundaries.extractGate = nil; Boundaries.uploadGate = nil; Boundaries.invalidOutput = false
    AuthStore.shared.userID = "owner-a"
    let listing = Listing()
    let original = FileStore.documents.appendingPathComponent("original-" + UUID().uuidString + ".mov")
    try Data(repeating: 9, count: 16).write(to: original)
    let asset = CaptureAsset(localURL: original)
    let model = AppModel(); model.listings = [listing]; model.assets[listing.id] = asset
    return (ReflectionRemoval.controller(listingID: listing.id, asset: asset), model, listing, asset)
}

@main struct Checks {
    @MainActor static func main() async throws {
        FileStore.documents = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: FileStore.documents, withIntermediateDirectories: true)
        let baseline = CommandLine.arguments[2] == "baseline"
        var results: [String: Any] = [:]
        do {
            let (controller, model, listing, _) = try fixture()
            let oldGate = Gate(); Boundaries.extractGate = oldGate
            let clip = ReflectionClip(startS: 1, endS: 4)
            controller.start(clips: [clip], model: model, listing: listing)
            try await waitUntil { oldGate.arrivals == 1 }
            let oldBatch = controller.work!.id
            controller.cancel(model: model)
            try await waitUntil { controller.work?.cancellationConfirmed == true && !controller.isBusy }
            let newGate = Gate(); Boundaries.extractGate = newGate
            controller.start(clips: [ReflectionClip(startS: 5, endS: 8)], model: model, listing: listing)
            try await waitUntil { newGate.arrivals == 1 }
            let newBatch = controller.work!.id
            oldGate.release()
            try await Task.sleep(nanoseconds: 50_000_000)
            let poisoned = controller.work!.pieces[0].inputPath?.contains(oldBatch.uuidString) == true
            precondition(oldBatch != newBatch)
            precondition(poisoned == baseline, "Late cancelled extraction must not mutate a replacement batch")
            results["lateCancelledExtractPoisonsNewBatch"] = poisoned
            newGate.release()
            try await waitUntil { !controller.isBusy }
        }
        // FIXED_ONLY_START
        for status in [400, 402, 429] {
            let (controller, model, listing, original) = try fixture()
            model.api.rejectedSubmission = 2
            model.api.submissionRejectionStatus = status
            let clips = [ReflectionClip(startS: 1, endS: 4), ReflectionClip(startS: 5, endS: 8)]
            controller.start(clips: clips, model: model, listing: listing)
            try await waitUntil { !controller.isBusy }
            precondition(model.api.jobs.count == 1 && controller.work?.pieces[0].outputPath != nil)
            precondition(model.assets[listing.id]?.id == original.id)
            if status == 429 {
                precondition(model.api.cancelCalls == 0 && controller.work?.cancellationRequested == false)
                controller.start(clips: [], model: model, listing: listing)
                try await waitUntil { !controller.isBusy }
                precondition(controller.canPreview && model.api.jobs.count == 2 && model.api.cancelCalls == 0)
                results["rateLimitedSecondClipRemainsResumable"] = true
            } else {
                precondition(controller.work?.cancellationConfirmed == true && model.api.cancelCalls == 1)
                precondition(!controller.canPreview)
                results["definitiveSecondClip\(status)RefundsWholeBatch"] = true
            }
        }
        do {
            let (controller, model, listing, original) = try fixture()
            model.api.loseSubmitResponseOnce = true
            let clip = ReflectionClip(startS: 1, endS: 4)
            controller.start(clips: [clip], model: model, listing: listing)
            try await waitUntil { !controller.isBusy }
            precondition(controller.work?.pieces[0].job == nil && model.api.jobs.count == 1)
            let persistedID = controller.work!.id
            ReflectionRemoval.active.removeAll()
            let restored = ReflectionRemoval.controller(listingID: listing.id, asset: original)
            precondition(restored.work?.id == persistedID)
            restored.start(clips: [], model: model, listing: listing)
            try await waitUntil { !restored.isBusy }
            precondition(restored.canPreview && model.api.submissions == [clip.id, clip.id] && model.api.jobs.count == 1)
            precondition(restored.source.localURL != original.localURL && FileStore.fileSize(original.localURL) == 16)
            precondition(FileStore.fileSize(restored.source.localURL) == 16)
            let originalBytes = try Data(contentsOf: original.localURL)
            let preservedBytes = try Data(contentsOf: restored.source.localURL)
            precondition(preservedBytes == originalBytes)
            try Data(repeating: 7, count: 16).write(to: original.localURL)
            let preservedAfterExternalChange = try Data(contentsOf: restored.source.localURL)
            precondition(preservedAfterExternalChange == originalBytes,
                         "The preserved original must be an independent full copy")
            precondition(model.assets[listing.id]?.id == original.id)
            results["lostSubmitRelaunchUsesSameClipUUID"] = true
            results["fullOriginalCopiedAndNoAutomaticAcceptance"] = true
        }
        do {
            let (controller, model, listing, original) = try fixture()
            Boundaries.invalidOutput = true
            controller.start(clips: [ReflectionClip(startS: 1, endS: 4)], model: model, listing: listing)
            try await waitUntil { !controller.isBusy }
            precondition(controller.work?.cancellationConfirmed == true && model.api.cancelCalls == 1)
            precondition(model.assets[listing.id]?.id == original.id && !controller.canPreview)
            results["unusableProviderOutputAutomaticallyRequestsBatchRefund"] = true
        }
        do {
            let (controller, model, listing, _) = try fixture()
            Boundaries.invalidOutput = true; model.api.failCancellation = true
            controller.start(clips: [ReflectionClip(startS: 1, endS: 4)], model: model, listing: listing)
            try await waitUntil { !controller.isBusy }
            precondition(controller.work?.cancellationRequested == true && controller.work?.cancellationConfirmed == false)
            precondition(controller.error?.contains("not confirmed") == true)
            model.api.failCancellation = false
            controller.cancel(model: model)
            try await waitUntil { !controller.isBusy }
            precondition(controller.work?.cancellationConfirmed == true)
            results["offlineRefundRemainsPendingUntilAcknowledged"] = true
        }
        do {
            let (controller, model, listing, original) = try fixture()
            let gate = Gate(); Boundaries.uploadGate = gate
            controller.start(clips: [ReflectionClip(startS: 1, endS: 4)], model: model, listing: listing)
            try await waitUntil { gate.arrivals == 1 }
            AuthStore.shared.userID = "owner-b"
            let other = ReflectionRemoval.controller(listingID: listing.id, asset: original)
            precondition(other !== controller && other.work == nil)
            gate.release()
            try await waitUntil { !controller.isBusy }
            precondition(model.api.submissions.isEmpty && controller.work?.pieces[0].assetID == nil)
            precondition(!controller.accountMatches && !controller.canPreview && controller.resultURL == nil)
            results["accountSwitchRejectsLateUploadAndIsolatesController"] = true
        }
        do {
            let (controller, model, listing, _) = try fixture()
            let gate = Gate(); Boundaries.extractGate = gate
            controller.start(clips: [ReflectionClip(startS: 1, endS: 4)], model: model, listing: listing)
            try await waitUntil { gate.arrivals == 1 }
            // Only a synthetic journal: make its replacement impossible while
            // leaving the existing controller/batch identity in memory.
            let journal = controller.work!.directory.appendingPathComponent("work.json")
            try FileManager.default.removeItem(at: journal)
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            controller.cancel(model: model)
            try await waitUntil { !controller.isBusy }
            precondition(model.api.cancelCalls == 1 && controller.work?.cancellationConfirmed == true)
            gate.release()
            try await Task.sleep(nanoseconds: 30_000_000)
            precondition(model.api.submissions.isEmpty)
            results["journalWriteFailureStillCancelsOnServer"] = true
        }
        do {
            let (controller, model, listing, original) = try fixture()
            controller.start(clips: [ReflectionClip(startS: 1, endS: 4)], model: model, listing: listing)
            try await waitUntil { !controller.isBusy }
            precondition(controller.canPreview)
            let gate = Gate(); model.api.applyGate = gate
            var completions = 0
            controller.accept(model: model) { _ in completions += 1 }
            try await waitUntil { gate.arrivals == 1 }
            controller.cancel(model: model)
            try await waitUntil { !controller.isBusy }
            precondition(controller.work?.applied == true && controller.work?.cancellationConfirmed == false)
            precondition(model.api.applyCalls == 2 && model.assets[listing.id]?.id == original.id && completions == 0)
            gate.release()
            try await Task.sleep(nanoseconds: 30_000_000)
            precondition(model.assets[listing.id]?.id == original.id && completions == 0)
            controller.accept(model: model) { _ in completions += 1 }
            try await waitUntil { !controller.isBusy }
            precondition(completions == 1 && model.assets[listing.id]?.id == controller.work?.result?.id)
            results["cancelAfterApplyCommitRecoversReceiptWithoutSelectingEdit"] = true
            results["onlyExplicitSubsequentAcceptanceChangesModel"] = true
        }
        // FIXED_ONLY_END
        print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
