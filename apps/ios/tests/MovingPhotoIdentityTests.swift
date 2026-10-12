import Foundation

@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "synthetic-owner"
    var syncSessionRevision: UInt64 = 1
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor final class AIConsent {
    static let shared = AIConsent()
    var isGranted = true
    var revocationRevision: UInt64 = 1
}
@MainActor enum AIImagePrep {
    static var onPreparation: (() -> Void)?
    static func jpegBase64(at: URL, maxDimension: Int, quality: Double) async -> String? {
        await Task.yield()
        onPreparation?()
        return Data("synthetic source photo".utf8).base64EncodedString()
    }
    static func error(_ message: String) -> NSError { NSError(domain: "closed-moving-photo", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@MainActor enum ClipFrames {
    static var onExtraction: (() -> Void)?
    static var empty = false
    static var lastURL: URL?
    static func extract(from url: URL) async -> [(at: String, jpeg: Data)] {
        lastURL = url
        await Task.yield()
        onExtraction?()
        return empty ? [] : ["first", "middle", "last"].map { ($0, Data("closed frame".utf8)) }
    }
}
enum Haptics { static func selection() {}; static func success() {} }
enum Analytics { static func track(_ event: String, _ values: [String: String]) {} }
struct EnhancedPhoto { let id: String; let enhancedURL: URL }
struct AnimationListing { let id: UUID; var isSample = false; var cloudUnavailable: Bool? }
struct AnimationSpace { let rawValue = "real_estate" }
struct AnimatedClip { let url: URL }
struct SavedClip { static func loadAll(listingID: UUID) -> [SavedClip] { [] } }
struct AIFailure { let message: String; init(_ error: Error, title: String) { message = error.localizedDescription } }
struct AIVideoJob { let requestId = "closed-paid-job" }
enum AIVideoStatus { case processing, completed(URL), failed(String) }
struct DriftCheckRequest {
    let requestID: String, kind: String, sourceBase64: String
    let frames: [(at: String, jpeg: Data)]
    let seconds: Int?, spaceType: String?, listingServerID: UUID?
}
struct DriftVerdict {
    enum Status: String { case pass, fail, unavailable }
    let status: Status, publishable: Bool, action: String, message: String
    let reason: String?
    var mayUse: Bool { status == .pass && publishable }
    var refusal: String { message }
}
@MainActor final class AnimationAPI {
    let remote: URL
    var posts = 0, polls = 0, drifts = 0
    var onSubmit: (() -> Void)?, onPoll: (() -> Void)?, onDrift: (() -> Void)?
    init(remote: URL) { self.remote = remote }
    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         listingServerID: UUID?, label: String?, idempotencyKey: String?) async throws -> AIVideoJob {
        posts += 1
        await Task.yield(); onSubmit?()
        return AIVideoJob()
    }
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        polls += 1
        await Task.yield(); onPoll?()
        return .completed(remote)
    }
    func aiVideoDrift(_ request: DriftCheckRequest) async throws -> DriftVerdict {
        drifts += 1
        precondition(!request.frames.isEmpty, "moving photo never sends an empty quality request")
        await Task.yield(); onDrift?()
        return .init(status: .pass, publishable: true, action: "publish", message: "", reason: nil)
    }
}
@MainActor final class AnimationModel {
    let api: AnimationAPI
    var listings: [AnimationListing]
    var complianceCalls = 0
    var onCompliance: (() -> Void)?
    init(api: AnimationAPI, listing: AnimationListing) { self.api = api; listings = [listing] }
    func serverListingIDForCompliance(_ id: UUID) async -> UUID? {
        complianceCalls += 1
        await Task.yield(); onCompliance?()
        return id
    }
}
enum MovingPhotoClock {
    static var seconds: TimeInterval = 0
    static func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }
    static func pause(nanoseconds: UInt64) async throws { precondition(nanoseconds == 6_000_000_000); try Task.checkCancellation(); seconds += 6; await Task.yield() }
}

@main struct MovingPhotoIdentityTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("closed-moving-photo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sequence = 0
        func fixture() throws -> MovingPhotoHarness {
            AIImagePrep.onPreparation = nil; ClipFrames.onExtraction = nil; ClipFrames.empty = false; ClipFrames.lastURL = nil
            AuthStore.shared.userID = "synthetic-owner"; AuthStore.shared.syncSessionRevision = 1
            AIConsent.shared.isGranted = true; AIConsent.shared.revocationRevision = 1
            WorkspaceContext.selectedOrgID = UUID(); MovingPhotoClock.seconds = 0
            sequence += 1
            let directory = root.appendingPathComponent("run-\(sequence)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let listing = AnimationListing(id: UUID(), cloudUnavailable: false)
            let api = AnimationAPI(remote: URL(string: CommandLine.arguments[1])!)
            return MovingPhotoHarness(model: AnimationModel(api: api, listing: listing), listing: listing, dir: directory)
        }
        func execute(_ fixture: MovingPhotoHarness) async {
            fixture.animateWithSession(EnhancedPhoto(id: "closed-photo", enhancedURL: root.appendingPathComponent("synthetic.jpg")))
            await fixture.animateTask?.value
        }
        let normal = try fixture(); await execute(normal)
        check(normal.model.api.posts == 1 && normal.model.api.polls == 1 && normal.model.api.drifts == 1, "normal moving photo performs one paid request, one poll and one quality check")
        check(normal.animatedClip != nil && normal.aiFailure == nil, "current moving photo displays its checked result")
        let normalBytes = try Data(contentsOf: normal.animatedClip!.url)
        check(normalBytes == Data("synthetic moving clip bytes".utf8), "moving photo preserves exact downloaded bytes")
        check(normal.busyPhotoIDs.isEmpty && !normal.localProcessing, "moving photo completes its local progress state")

        let preparedOwner = try fixture()
        AIImagePrep.onPreparation = { AuthStore.shared.userID = "other-owner" }
        await execute(preparedOwner)
        check(preparedOwner.model.api.posts == 0, "prepared photo cannot submit under a replacement owner")
        check(preparedOwner.model.complianceCalls == 0, "stale prepared photo cannot enter listing sync")
        check(preparedOwner.animatedClip == nil && preparedOwner.aiFailure == nil, "stale prepared photo is never displayed")

        let preparedRevision = try fixture()
        AIImagePrep.onPreparation = { AuthStore.shared.syncSessionRevision += 1 }
        await execute(preparedRevision)
        check(preparedRevision.model.api.posts == 0, "same-owner session replacement cannot animate earlier prepared media")
        let preparedConsent = try fixture()
        AIImagePrep.onPreparation = { AIConsent.shared.isGranted = false; AIConsent.shared.revocationRevision += 1; AIConsent.shared.isGranted = true }
        await execute(preparedConsent)
        check(preparedConsent.model.api.posts == 0, "revoked and regranted consent cannot animate earlier prepared media")
        let preparedLibrary = try fixture()
        AIImagePrep.onPreparation = { WorkspaceContext.selectedOrgID = UUID() }
        await execute(preparedLibrary)
        check(preparedLibrary.model.api.posts == 0, "library switch cannot animate earlier prepared media")
        let missingListing = try fixture()
        AIImagePrep.onPreparation = { missingListing.model.listings = [] }
        await execute(missingListing)
        check(missingListing.model.api.posts == 0, "removed listing cannot dispatch moving-photo generation")
        let blockedListing = try fixture()
        AIImagePrep.onPreparation = { blockedListing.model.listings[0].cloudUnavailable = true }
        await execute(blockedListing)
        check(blockedListing.model.api.posts == 0, "unavailable listing cannot dispatch moving-photo generation")
        let cancelled = try fixture()
        AIImagePrep.onPreparation = { cancelled.animateTask?.cancel() }
        await execute(cancelled)
        check(cancelled.model.api.posts == 0, "cancelled preparation cannot dispatch a paid moving photo")
        let compliance = try fixture()
        compliance.model.onCompliance = { WorkspaceContext.selectedOrgID = UUID() }
        await execute(compliance)
        check(compliance.model.api.posts == 0, "library change during compliance sync cannot dispatch a paid moving photo")
        let submitted = try fixture()
        submitted.model.api.onSubmit = { AuthStore.shared.userID = "other-owner" }
        await execute(submitted)
        check(submitted.model.api.posts == 1 && submitted.model.api.polls == 0, "accepted moving-photo reply cannot poll under a replacement owner")
        let polled = try fixture()
        polled.model.api.onPoll = { AuthStore.shared.syncSessionRevision += 1 }
        await execute(polled)
        check(polled.model.api.drifts == 0 && polled.animatedClip == nil, "stale status reply cannot enter the moving-photo quality gate")
        let extracted = try fixture()
        ClipFrames.onExtraction = { WorkspaceContext.selectedOrgID = UUID() }
        await execute(extracted)
        check(extracted.model.api.drifts == 0 && extracted.animatedClip == nil, "library change during frame extraction cannot dispatch a quality request")
        if let temporary = ClipFrames.lastURL { check(!FileManager.default.fileExists(atPath: temporary.path), "cancelled frame extraction cleans its downloaded temporary file") }
        let judged = try fixture()
        judged.model.api.onDrift = { AuthStore.shared.userID = "other-owner" }
        await execute(judged)
        check(judged.animatedClip == nil, "stale quality reply cannot display a moving photo")
        let saved = try FileManager.default.contentsOfDirectory(at: judged.dir, includingPropertiesForKeys: nil)
        check(saved.isEmpty, "stale quality reply cannot save media into the earlier listing")
        check(judged.aiFailure == nil, "account interruption does not present an old account's error")
        let empty = try fixture(); ClipFrames.empty = true; await execute(empty)
        check(empty.model.api.posts == 1 && empty.model.api.drifts == 0 && empty.animatedClip == nil, "moving photo with no readable frames is held locally")
        print("PASS: \(checks) actual animateWithSession identity/consent/library assertions; closed prep/API/decoder and loopback bytes")
    }
}
