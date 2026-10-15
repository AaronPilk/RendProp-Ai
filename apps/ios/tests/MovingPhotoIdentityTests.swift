import Foundation

enum CloudSyncError: Error { case identityChanged }
enum APIError: Error {
    case decoding; case server(status: Int, code: String, message: String)
    var status: Int? { if case let .server(value, _, _) = self { return value }; return nil }
}

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
struct DriftCheckRequest {
    let requestID: String, kind: String, sourceBase64: String
    let frames: [(at: String, jpeg: Data)]
    let seconds: Int?, spaceType: String?, listingServerID: UUID?
    var provenanceID: String? = nil
}
struct DriftVerdict {
    enum Status: String { case pass, fail, unavailable }
    let status: Status, publishable: Bool, action: String, message: String
    let reason: String?
    var mayUse: Bool { status == .pass && publishable }
    var refusal: String { message }
}
@MainActor final class AnimationAPI {
    var remote: URL
    var posts = 0, polls = 0, drifts = 0, lookups = 0
    var lookupPending = true, lookupOmitsMetadata = false
    var refusalStatus: Int?, paidRequests = 0, submittedKeys: [String] = []
    var expectedProvenance: String? = "closed-paid-provenance"
    var onSubmit: (() -> Void)?, onPoll: (() -> Void)?, onDrift: (() -> Void)?
    var loseSubmit = false, losePoll = false, loseDrift = false, processing = false, holdQuality = false
    init(remote: URL) { self.remote = remote }
    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         listingServerID: UUID?, label: String?, idempotencyKey: String?) async throws -> AIVideoJob {
        posts += 1; submittedKeys.append(idempotencyKey ?? "")
        if let refusalStatus { throw APIError.server(status: refusalStatus, code: "closed_refusal", message: "Closed pre-dispatch refusal") }
        paidRequests += 1
        await Task.yield(); onSubmit?()
        if loseSubmit { throw URLError(.timedOut) }
        return AIVideoJob(requestId: "closed-paid-job", statusUrl: "https://example.test/status", responseUrl: "https://example.test/result", kind: "reel", provenanceID: "closed-paid-provenance")
    }
    func aiVideoOperation(operationID: UUID, listingServerID: UUID) async throws -> AIVideoJob? {
        lookups += 1
        guard !lookupPending else { return nil }
        return AIVideoJob(requestId: "closed-paid-job", statusUrl: "https://example.test/status", responseUrl: "https://example.test/result", kind: "reel", provenanceID: lookupOmitsMetadata ? nil : "closed-paid-provenance")
    }
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        polls += 1
        await Task.yield(); onPoll?()
        if losePoll { throw URLError(.networkConnectionLost) }
        return processing ? .processing(queuePosition: nil) : .completed(videoURL: remote)
    }
    func aiVideoDrift(_ request: DriftCheckRequest) async throws -> DriftVerdict {
        drifts += 1
        precondition(!request.frames.isEmpty, "moving photo never sends an empty quality request")
        precondition(request.provenanceID == expectedProvenance, "moving photo quality check forwards its exact provenance receipt")
        await Task.yield(); onDrift?()
        if loseDrift { throw URLError(.networkConnectionLost) }
        return .init(status: holdQuality ? .fail : .pass, publishable: !holdQuality, action: holdQuality ? "hold" : "publish", message: "", reason: nil)
    }
}
@MainActor final class AnimationModel {
    let api: AnimationAPI
    var listings: [AnimationListing]
    var complianceCalls = 0
    var provideServer = true
    var onCompliance: (() -> Void)?
    init(api: AnimationAPI, listing: AnimationListing) { self.api = api; listings = [listing] }
    func isInSelectedWorkspace(_ listing: AnimationListing) -> Bool { true }
    func serverListingIDForCompliance(_ id: UUID) async -> UUID? {
        complianceCalls += 1
        await Task.yield(); onCompliance?()
        return provideServer ? id : nil
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
        try Data("synthetic full source photo".utf8).write(to: root.appendingPathComponent("synthetic.jpg"))
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

        let sameFinished = normal.animatedClip!.url
        normal.animatedClip = nil
        await execute(normal)
        check(normal.model.api.posts == 1 && normal.model.api.drifts == 1 && normal.animatedClip?.url == sameFinished, "completed moving photo reopens exact saved clip without another charge")
        let relaunched = MovingPhotoHarness(model: normal.model, listing: normal.listing, dir: normal.dir)
        await execute(relaunched)
        check(relaunched.animatedClip?.url == sameFinished && normal.model.api.posts == 1, "relaunch reopens its exact completed result")
        check(PhotoAnimationRecovery.pending(directory: normal.dir, actor: AuthStore.shared.userID!, library: WorkspaceContext.selectedOrgID, listing: normal.listing.id).isEmpty, "completed result retires its pending card while retaining its receipt")

        let left = try fixture()
        left.model.api.onSubmit = { left.animateTask?.cancel() }
        await execute(left)
        left.model.api.onSubmit = nil
        left.model.api.lookupPending = false; left.model.api.lookupOmitsMetadata = true
        let leftReopened = MovingPhotoHarness(model: left.model, listing: left.listing, dir: left.dir)
        await execute(leftReopened)
        check(left.model.api.posts == 1 && left.model.api.polls == 1 && leftReopened.animatedClip != nil, "leaving after acceptance resumes the exact receipt without another generation")
        check(left.model.api.lookups == 0 && left.model.api.drifts == 1, "known receipt keeps its provenance without consulting metadata-incomplete lookup")

        for status in [402, 403] {
            let refused = try fixture(); refused.model.api.refusalStatus = status
            await execute(refused)
            check(refused.model.api.posts == 1 && refused.model.api.paidRequests == 0, "definitive refusal does not auto-retry or dispatch paid work")
            let row = PhotoAnimationRecovery.pending(directory: refused.dir, actor: AuthStore.shared.userID!, library: WorkspaceContext.selectedOrgID, listing: refused.listing.id).first!
            let refusedEntry = try PhotoAnimationRecovery.load(row.context, directory: refused.dir)!
            check(refusedEntry.refusedBeforeAcceptance == true && !refusedEntry.dispatched && refusedEntry.refusedStatus == status, "definitive refusal is retained as verified unaccepted evidence")
            refused.model.api.refusalStatus = nil; await execute(refused)
            check(refused.animatedClip != nil && refused.model.api.paidRequests == 1 && refused.model.api.posts == 2, "explicit check after definite refusal may start its first paid video")
            check(refused.model.api.submittedKeys[0] != refused.model.api.submittedKeys[1], "explicit retry retires the refused key instead of reusing its tombstone")
            let completedEntry = try PhotoAnimationRecovery.load(row.context, directory: refused.dir)!
            check(completedEntry.refusedOperations?.first?.operationID == refusedEntry.operationID && completedEntry.refusedOperations?.first?.status == status, "retry preserves rejected operation evidence without resetting server costs")
        }
        for status in [408, 409, 500, 503] {
            let uncertain = try fixture(); uncertain.model.api.refusalStatus = status
            await execute(uncertain); uncertain.model.api.refusalStatus = nil; await execute(uncertain)
            check(uncertain.model.api.posts == 1 && uncertain.animatedClip == nil, "ambiguous or duplicate submission never rotates its operation or POSTs again")
        }
        let lost = try fixture(); lost.model.api.loseSubmit = true
        await execute(lost)
        lost.model.api.loseSubmit = false; await execute(lost)
        check(lost.model.api.posts == 1 && lost.model.api.polls == 0 && lost.animatedClip == nil, "lost submission reply cannot dispatch a second paid request")
        check(lost.aiFailure?.message.contains("reply was not received") == true, "unconfirmed submission is shown honestly and retained")

        lost.model.api.lookupPending = false; await execute(lost)
        check(lost.model.api.posts == 1 && lost.model.api.lookups == 2 && lost.animatedClip != nil, "authorized operation lookup recovers lost202 without another paid request")
        let lookupWithoutMetadata = try fixture(); lookupWithoutMetadata.model.api.loseSubmit = true; await execute(lookupWithoutMetadata)
        lookupWithoutMetadata.model.api.lookupPending = false; lookupWithoutMetadata.model.api.lookupOmitsMetadata = true
        lookupWithoutMetadata.model.api.expectedProvenance = nil; lookupWithoutMetadata.model.api.loseSubmit = false
        await execute(lookupWithoutMetadata)
        check(lookupWithoutMetadata.animatedClip != nil && lookupWithoutMetadata.model.api.posts == 1 && lookupWithoutMetadata.model.api.drifts == 1, "unknown202 lookup can recover without inventing omitted provenance")
        let pending = try fixture(); pending.model.api.loseSubmit = true; await execute(pending)
        let rows = PhotoAnimationRecovery.pending(directory: pending.dir, actor: AuthStore.shared.userID!, library: WorkspaceContext.selectedOrgID, listing: pending.listing.id)
        check(rows.count == 1 && rows[0].dispatched && rows[0].job == nil, "lost202 retains its exact operation and frozen source")
        check(PhotoAnimationRecovery.pending(directory: pending.dir, actor: "foreign-owner", library: WorkspaceContext.selectedOrgID, listing: pending.listing.id).isEmpty, "foreign account cannot discover retained animation metadata")
        check(PhotoAnimationRecovery.pending(directory: pending.dir, actor: AuthStore.shared.userID!, library: UUID(), listing: pending.listing.id).isEmpty, "foreign library cannot discover retained animation metadata")
        check(PhotoAnimationRecovery.pending(directory: pending.dir, actor: AuthStore.shared.userID!, library: WorkspaceContext.selectedOrgID, listing: UUID()).isEmpty, "another listing cannot adopt retained animation metadata")
        try Data("corrupt journal".utf8).write(to: PhotoAnimationRecovery.file(rows[0].context, directory: pending.dir)); pending.model.api.loseSubmit = false; await execute(pending)
        check(pending.model.api.posts == 1 && pending.animatedClip == nil, "unreadable journal fails closed without a new paid request")

        let downloadFailure = try fixture(); downloadFailure.model.api.remote = URL(string: CommandLine.arguments[1] + "/gone")!; await execute(downloadFailure)
        downloadFailure.model.api.remote = URL(string: CommandLine.arguments[1])!; await execute(downloadFailure)
        check(downloadFailure.model.api.posts == 1 && downloadFailure.model.api.drifts == 1 && downloadFailure.animatedClip != nil, "failed download retries existing receipt without generation or earlier QC")

        let dropped = try fixture(); dropped.model.api.losePoll = true; await execute(dropped)
        dropped.model.api.losePoll = false; await execute(dropped)
        check(dropped.model.api.posts == 1 && dropped.model.api.polls == 2 && dropped.animatedClip != nil, "dropped status recovers existing receipt without generation")

        let timed = try fixture(); timed.model.api.processing = true; await execute(timed)
        check(timed.model.api.posts == 1 && timed.model.api.polls == 100 && timed.animatedClip == nil, "bounded polling timeout keeps the accepted receipt")
        timed.model.api.processing = false; await execute(timed)
        check(timed.model.api.posts == 1 && timed.animatedClip != nil, "timeout retry checks saved receipt rather than generating again")

        let checkedThenLeft = try fixture()
        checkedThenLeft.model.api.onDrift = { checkedThenLeft.animateTask?.cancel() }
        await execute(checkedThenLeft)
        let checkedCandidate = ClipFrames.lastURL!
        check(FileManager.default.fileExists(atPath: checkedCandidate.path), "stale quality reply cannot save media into the earlier listing")
        try FileManager.default.removeItem(at: checkedCandidate)
        checkedThenLeft.model.api.onDrift = nil
        checkedThenLeft.model.api.remote = URL(string: CommandLine.arguments[1] + "/different")!
        let checkedReopen = MovingPhotoHarness(model: checkedThenLeft.model, listing: checkedThenLeft.listing, dir: checkedThenLeft.dir)
        await execute(checkedReopen)
        check(checkedReopen.animatedClip == nil && checkedThenLeft.model.api.posts == 1 && checkedThenLeft.model.api.drifts == 1, "quality-bound clip cannot adopt changed redownload bytes")
        checkedThenLeft.model.api.remote = URL(string: CommandLine.arguments[1])!; await execute(checkedReopen)
        check(checkedReopen.animatedClip != nil && checkedThenLeft.model.api.posts == 1 && checkedThenLeft.model.api.drifts == 1, "identical redownload recovers saved quality pass without another judge")

        let unknownQuality = try fixture(); unknownQuality.model.api.loseDrift = true; await execute(unknownQuality)
        unknownQuality.model.api.loseDrift = false; await execute(unknownQuality)
        check(unknownQuality.model.api.posts == 1 && unknownQuality.model.api.drifts == 1 && unknownQuality.animatedClip == nil, "lost quality reply cannot purchase another quality check")
        let held = try fixture(); held.model.api.holdQuality = true; await execute(held); await execute(held)
        check(held.model.api.posts == 1 && held.model.api.drifts == 1 && held.animatedClip == nil, "quality-held motion clip cannot become a usable saved result")

        let changed = try fixture(); await execute(changed); changed.animatedClip = nil
        try Data("changed source photo bytes".utf8).write(to: root.appendingPathComponent("synthetic.jpg")); await execute(changed)
        check(changed.model.api.posts == 1 && changed.animatedClip == nil, "changed source bytes cannot adopt an earlier video receipt")
        try Data("synthetic full source photo".utf8).write(to: root.appendingPathComponent("synthetic.jpg"))

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
        let unanchored = try fixture(); unanchored.model.provideServer = false; await execute(unanchored)
        check(unanchored.model.api.posts == 0 && unanchored.animatedClip == nil, "normal standalone video requires a recoverable server listing before payment")
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
        let extracted = try fixture(); let initialExtractionLibrary = WorkspaceContext.selectedOrgID
        ClipFrames.onExtraction = { WorkspaceContext.selectedOrgID = UUID() }
        await execute(extracted)
        check(extracted.model.api.drifts == 0 && extracted.animatedClip == nil, "library change during frame extraction cannot dispatch a quality request")
        if let temporary = ClipFrames.lastURL { check(FileManager.default.fileExists(atPath: temporary.path) && temporary.lastPathComponent.hasPrefix(".animation-"), "cancelled frame extraction retains only its private paid candidate") }
        ClipFrames.onExtraction = nil
        WorkspaceContext.selectedOrgID = initialExtractionLibrary
        await execute(extracted)
        check(extracted.model.api.posts == 1 && extracted.model.api.drifts == 1 && extracted.animatedClip != nil, "leaving during local frame extraction can resume its never-dispatched quality check")
        let changedDuringJudge = try fixture()
        changedDuringJudge.model.api.onDrift = { try! Data("replacement bytes during review".utf8).write(to: root.appendingPathComponent("synthetic.jpg")) }
        await execute(changedDuringJudge)
        let changedOutput = try FileManager.default.contentsOfDirectory(at: changedDuringJudge.dir, includingPropertiesForKeys: nil)
        check(changedDuringJudge.animatedClip == nil && !changedOutput.contains { $0.lastPathComponent.hasPrefix("clip-") }, "source change during quality cannot promote a usable clip")
        try Data("synthetic full source photo".utf8).write(to: root.appendingPathComponent("synthetic.jpg"))

        let judged = try fixture()
        judged.model.api.onDrift = { AuthStore.shared.userID = "other-owner" }
        await execute(judged)
        check(judged.animatedClip == nil, "stale quality reply cannot display a moving photo")
        let saved = try FileManager.default.contentsOfDirectory(at: judged.dir, includingPropertiesForKeys: nil)
        check(!saved.contains { $0.lastPathComponent.hasPrefix("clip-") }, "stale quality reply cannot save media into the earlier listing")
        check(judged.aiFailure == nil, "account interruption does not present an old account's error")
        let empty = try fixture(); ClipFrames.empty = true; await execute(empty)
        check(empty.model.api.posts == 1 && empty.model.api.drifts == 0 && empty.animatedClip == nil, "moving photo with no readable frames is held locally")
        let wire = OperationWireHarness(), operation = UUID(uuidString: "ABCDEF12-3456-4789-ABCD-ABCDEF123456")!, serverListing = UUID(), library = UUID()
        AuthStore.shared.userID = "wire-owner"; AuthStore.shared.syncSessionRevision = 1
        AIConsent.shared.isGranted = true; AIConsent.shared.revocationRevision = 1; WorkspaceContext.selectedOrgID = library
        let common: [String: Any] = ["operation_id": operation.uuidString, "listing_id": serverListing.uuidString,
            "selected_library_org_id": library.uuidString, "org_id": UUID().uuidString]
        func response(_ fields: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: common.merging(fields) { _, b in b }) }
        wire.reply = try response(["status": "pending"])
        check(try await wire.aiVideoOperation(operationID: operation, listingServerID: serverListing) == nil, "explicit scoped pending lookup does not fabricate a receipt")
        let query = URLComponents(url: wire.captured!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(wire.captured?.httpMethod == "GET" && wire.captured?.httpBody == nil && wire.captured?.url?.path == "/functions/v1/ai-video/operation", "recovery uses only the known read-only operation endpoint")
        check(query.first { $0.name == "operation_id" }?.value == operation.uuidString && query.first { $0.name == "listing_id" }?.value == serverListing.uuidString, "lookup preserves exact saved UUID key case and listing")
        check(wire.captured?.value(forHTTPHeaderField: "X-Org-Id") == library.uuidString.lowercased(), "lookup binds selected library header")
        let accepted: [String: Any] = ["status": "accepted", "kind": "reel", "request_id": "paid-result", "status_url": "https://example.test/status", "response_url": "https://example.test/result", "provenance": ["id": "paid-provenance"]]
        wire.reply = try response(accepted)
        let acceptedJob = try await wire.aiVideoOperation(operationID: operation, listingServerID: serverListing)
        check(acceptedJob?.requestId == "paid-result" && acceptedJob?.provenanceID == "paid-provenance", "accepted operation maps the exact receipt and provenance")
        var noMetadata = accepted; noMetadata.removeValue(forKey: "provenance")
        wire.reply = try response(noMetadata)
        let noMetadataJob = try await wire.aiVideoOperation(operationID: operation, listingServerID: serverListing)
        check(noMetadataJob?.requestId == "paid-result" && noMetadataJob?.provenanceID == nil, "operation decoder preserves absent provenance as absent")
        func refused(_ fields: [String: Any], _ reason: String) async throws {
            wire.reply = try response(accepted.merging(fields) { _, b in b })
            var didThrow = false
            do { _ = try await wire.aiVideoOperation(operationID: operation, listingServerID: serverListing) } catch { didThrow = true }
            check(didThrow, reason)
        }
        try await refused(["operation_id": UUID().uuidString], "operation lookup rejects a different saved key")
        try await refused(["operation_id": operation.uuidString.lowercased()], "operation lookup does not normalize a distinct saved key")
        try await refused(["listing_id": UUID().uuidString], "operation lookup rejects another listing")
        try await refused(["selected_library_org_id": UUID().uuidString], "operation lookup rejects another library")
        try await refused(["status": "pending"], "pending cannot smuggle an accepted receipt")
        try await refused(["status": "unknown"], "unrecognized operation state is not pending or accepted")
        try await refused(["status_url": "http://example.test/status"], "operation lookup refuses insecure receipt URLs")
        wire.reply = try response(accepted); wire.onReply = { AuthStore.shared.userID = "foreign-owner" }
        var staleReplyRefused = false
        do { _ = try await wire.aiVideoOperation(operationID: operation, listingServerID: serverListing) } catch { staleReplyRefused = true }
        check(staleReplyRefused, "operation lookup cannot expose a reply after account replacement")
        print("PASS: \(checks) actual moving-photo recovery/identity and operation-wire assertions; closed provider and loopback bytes")
    }
}
