import Foundation

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
private func rejects(_ message: String, _ action: () throws -> Void) { do { try action(); preconditionFailure(message) } catch { checks += 1 } }
private func rejectsAsync(_ message: String, _ action: () async throws -> Void) async { do { try await action(); preconditionFailure(message) } catch { checks += 1 } }

@MainActor final class AuthStore {
    static let shared = AuthStore(); var isIdentified = true; var userID: String?; var syncSessionRevision: UInt64 = 1
    static func validAccessToken() async -> String? { "closed-fixture-session" }
    static func jwtSubject(_ token: String) -> String? { shared.userID }
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AIConsent { static let storageKey = "closed-fixture-ai-v3"; static let shared = AIConsent(); var isGranted = true; var revocationRevision: UInt64 = 1; func ensureGranted() async -> Bool { isGranted } }
@MainActor enum Config { static let apiBaseURL: URL? = URL(string: "https://closed.invalid/functions/v1"); static let supabaseAnonKey = "public-closed-fixture" }
enum APIError: Error { case server(Int, String?, String); case badResponse(Int) }
final class LiveAPIClient {
    init?() {}
    static func serverError(status: Int, data: Data) -> APIError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return .server(status, json?["code"] as? String, json?["error"] as? String ?? "Closed refusal")
    }
}
enum FileStore {
    static var documents = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("fixture-documents")
    static func url(fromRelativePath path: String) -> URL { documents.appendingPathComponent(path) }
    static func relativePath(for url: URL) -> String { "reels/" + url.lastPathComponent }
    static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}
struct AIFailure { let message: String; init(_ error: Error, title: String = "") { message = title + ": " + error.localizedDescription } }
@MainActor final class UIApplication { enum State { case active, inactive }; static let shared = UIApplication(); var applicationState: State = .inactive }
struct ClosedListing { let id: UUID; let serverID: UUID?; var cloudUnavailable: Bool? = nil; var isSample = false }
@MainActor final class AppModel { var listings: [ClosedListing] = [] }
@MainActor final class ReelWorkJob {
    struct Scope { let owner: String?; let workspace: UUID? }
    enum Phase { case setup, generating, failed, done }
    let id = UUID(); let scope: Scope
    var running = false; var phase = Phase.setup; var failure: AIFailure?; var statusText = ""
    var serverJob: PropertyVideoSavedJob?; var reelURL: URL?; var lastReel: URL?; var originalPhotoMotionShots = 0
    var isCheckingServerStatus = false; var serverStatusCheckNote: String?; var lastServerStatusCheck: Date?
    var totalClips = 0; var completedClips = 0
    init(_ context: PropertyVideoJobContext) { scope = Scope(owner: context.actorID.uuidString, workspace: context.orgID) }
    func adoptServerJob(_ saved: PropertyVideoSavedJob) { serverJob = saved; phase = .generating }
    func afterCurrentOperation(_ action: @escaping () -> Void) {}
}

/// Every URL is intercepted. No provider, credential or external host can be reached.
final class ClosedTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies: [(Int, Data)] = []
    private static var requests: [URLRequest] = []
    static func reset(_ values: [(Int, Data)]) { lock.lock(); defer { lock.unlock() }; replies = values; requests = [] }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0, bytes.count + count <= 524288 else { client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum)); return }
                if count == 0 { break }; bytes.append(buffer, count: count)
            }
            captured.httpBody = bytes
        }
        Self.lock.lock(); Self.requests.append(captured)
        let next = Self.replies.isEmpty ? nil : Self.replies.removeFirst(); Self.lock.unlock()
        guard let next else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ClosedRunnerAPI: PropertyVideoJobsAPI {
    var creates = 0; var reads = 0; var abandons = 0; var cancels = 0; var resumes = 0
    var lookups: [PropertyVideoOperationLookup] = []; var cancelled: PropertyVideoJobReply!
    func enqueuePropertyVideo(_ request: PropertyVideoJobRequest, context: PropertyVideoJobContext) async throws -> PropertyVideoJobReply { creates += 1; throw PropertyVideoProcessorFailure.operationPending }
    func propertyVideoOperation(_ saved: PropertyVideoSavedJob, abandon: Bool) async throws -> PropertyVideoOperationLookup {
        if abandon { abandons += 1 } else { reads += 1 }
        guard !lookups.isEmpty else { throw URLError(.networkConnectionLost) }
        return lookups.removeFirst()
    }
    func propertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply { reads += 1; return cancelled }
    func cancelPropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply { cancels += 1; return cancelled }
    func resumePropertyVideoJob(_ saved: PropertyVideoSavedJob) async throws -> PropertyVideoJobReply { resumes += 1; return cancelled }
}

@MainActor @main struct PropertyVideoProcessorTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClosedTransport.self]
        PropertyVideoJobHTTP.session = URLSession(configuration: configuration)
        let docs = FileStore.documents
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs); PropertyVideoProcessorConsent.shared.revoke() }
        let context = PropertyVideoJobContext(localListingID: UUID(), listingID: UUID(), actorID: UUID(), orgID: UUID())
        AuthStore.shared.userID = context.actorID.uuidString; WorkspaceContext.selectedOrgID = context.orgID
        let source = PropertyVideoJobSource(photoID: "photo", photoAssetID: UUID(), photoVersionID: "photo", photoProvenanceID: nil, motion: "push_in")
        let recipe = PropertyVideoJobRequest(operationID: UUID(), listingID: context.listingID, expectedOrgID: context.orgID,
            purpose: "listing", aspect: "16:9", sources: [source], narrationResultID: nil, music: nil,
            allowOriginalPhotoFallback: true, presentation: .init(transition: "cut", shotCaptionStyle: "off", spokenCaptions: false, titleCard: nil, shotLabels: [nil]))
        let known = PropertyVideoProcessorContract.known
        let canonicalURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_DISCLOSURE"]!)
        let canonical = try JSONSerialization.jsonObject(with: Data(contentsOf: canonicalURL)) as! [String: Any]
        check(canonical["body"] as? String == PropertyVideoProcessorContract.body && canonical["title"] as? String == PropertyVideoProcessorContract.title && canonical["copy_sha256"] as? String == PropertyVideoProcessorContract.copySHA256, "compiled disclosure must match exact canonical copy")
        check(canonical["allow_label"] as? String == PropertyVideoProcessorContract.allowLabel && canonical["decline_label"] as? String == PropertyVideoProcessorContract.declineLabel, "compiled disclosure actions match canonical")
        let wire = try JSONEncoder().encode(known)
        check(try! PropertyVideoProcessorContract.decodePublished(wire) == known, "known exact disclosure is admitted")
        for changes: [String: Any] in [["processors": ["kie", "kie"]], ["processors": ["fal"]], ["profiles": ["future"]], ["disclosure_revision": "future"], ["extra": true]] {
            var value = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
            value.merge(changes) { _, new in new }
            rejects("unknown disclosure must fail closed") { _ = try PropertyVideoProcessorContract.decodePublished(JSONSerialization.data(withJSONObject: value)) }
        }
        let store = PropertyVideoProcessorConsent.shared
        store.revoke()
        check(store.grant(for: context) == nil, "base consent does not infer Kie permission")
        let denied = Task { try await store.ensure(known, context: context) }
        await Task.yield(); check(store.askingContext == context, "only known matching explicit prompt can ask")
        store.decline()
        await rejectsAsync("Not now cannot mint permission") { _ = try await denied.value }
        let allowed = Task { try await store.ensure(known, context: context) }
        await Task.yield(); store.allow()
        let permission = try await allowed.value
        check(store.permits(permission, context: context), "explicit Allow stores exact scoped permission")
        let foreign = PropertyVideoJobContext(localListingID: context.localListingID, listingID: context.listingID, actorID: UUID(), orgID: context.orgID)
        check(!permission.matches(foreign) && store.grant(for: foreign) == nil, "another actor cannot borrow permission")
        let headers = try PropertyVideoPaidAuthorization.processor(permission).headers(context: context)
        check(headers.count == 2 && headers["x-rendprop-ai-consent-disclosure"] == known.disclosureRevision && headers["x-rendprop-quality-test-grant"] == nil, "v2 attaches exact disclosure and no operator authority")
        let legacyHeaders = try PropertyVideoPaidAuthorization.legacy.headers(context: context)
        check(legacyHeaders == ["x-rendprop-ai-consent": "property-video-jobs-v1"], "legacy headers stay byte exact")
        var saved = PropertyVideoSavedJob(context: context, request: recipe, createdAt: Date(), processorPermission: permission)
        try PropertyVideoJobStore.start(saved, documents: docs)
        var tampered = saved; tampered.processorPermission = nil
        rejects("saved operation cannot lose or upgrade its permission snapshot") { try PropertyVideoJobStore.save(tampered, documents: docs) }
        let requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as! [String: Any]
        check(requestObject["processor_consent"] == nil && requestObject["consent_revision"] == nil, "permission stays outside closed wire manifest")
        let base = PropertyVideoJobReply(jobID: UUID(), operationID: recipe.operationID, listingID: recipe.listingID, orgID: UUID(), selectedLibraryOrgID: recipe.expectedOrgID, sourceCount: 1, manifestSHA256: String(repeating: "a", count: 64), state: "failed", resumeAvailable: true)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        object["consent_revision"] = "property-video-jobs-v1"; object["quality_profile"] = "fal-kling3-4k-v1"; object["processor_consent"] = NSNull()
        let v1Data = try JSONSerialization.data(withJSONObject: object)
        let v1 = try JSONDecoder().decode(PropertyVideoJobReply.self, from: v1Data)
        check(v1.resumeConsentToken == "property-video-jobs-v1", "recorded FAL v1 remains v1 independently of current Kie")
        let retainedV1 = try JSONDecoder().decode(PropertyVideoJobReply.self, from: JSONEncoder().encode(v1))
        check(retainedV1.resumeConsentToken == "property-video-jobs-v1", "explicit null v1 metadata survives durable roundtrip")
        var partialV1 = object; partialV1.removeValue(forKey: "processor_consent")
        let partial = try JSONDecoder().decode(PropertyVideoJobReply.self, from: JSONSerialization.data(withJSONObject: partialV1))
        check(partial.resumeConsentToken == nil, "partial own metadata keys never enable paid resume")
        let record: [String: Any] = ["token": known.token, "disclosure_revision": known.disclosureRevision, "processors": ["kie"], "recorded_at": "2026-10-16T20:00:00.000Z"]
        object["consent_revision"] = known.token; object["processor_consent"] = record
        let v2Data = try JSONSerialization.data(withJSONObject: object)
        let v2 = try JSONDecoder().decode(PropertyVideoJobReply.self, from: v2Data)
        check(v2.resumeConsentToken == known.token, "recorded v2 FAL never downgrades to v1")
        for change: [String: Any] in [["processorMetadataUnknown": true], ["consent_revision": NSNull(), "quality_profile": NSNull(), "processor_consent": NSNull()], ["consent_revision": "future"], ["processor_consent": "malformed"], ["quality_profile": "future"]] {
            var changed = object; changed.merge(change) { _, new in new }
            let reply = try JSONDecoder().decode(PropertyVideoJobReply.self, from: JSONSerialization.data(withJSONObject: changed))
            _ = try reply.checked(request: recipe)
            check(reply.mayResume && reply.resumeConsentToken == nil, "unknown metadata keeps status/cancel usable and disables paid resume")
            let roundtrip = try JSONDecoder().decode(PropertyVideoJobReply.self, from: JSONEncoder().encode(reply))
            check(roundtrip.resumeConsentToken == nil, "unknown authority remains unknown after durable roundtrip")
        }
        check(base.resumeConsentToken == nil, "unannotated metadata cannot guess prospective paid authority")
        let client = LiveAPIClient()!
        ClosedTransport.reset([(404, Data(#"{"error":"not published","code":"processor_disclosure_unpublished"}"#.utf8))])
        let unpublished = try await client.propertyVideoProcessorContract(context: context)
        check(unpublished == nil && ClosedTransport.captured().count == 1, "exact unpublished404 is the only legacy fallback")
        for (status, body) in [(404, Data(#"{"error":"missing","code":"not_found"}"#.utf8)), (500, Data()), (200, Data(#"{"token":"future"}"#.utf8))] {
            ClosedTransport.reset([(status, body)])
            await rejectsAsync("other disclosure failures cannot become v1") { _ = try await client.propertyVideoProcessorContract(context: context) }
        }
        ClosedTransport.reset([(200, wire), (202, v2Data)])
        _ = try await client.enqueuePropertyVideo(saved)
        let sent = ClosedTransport.captured()
        check(sent.count == 2 && sent[0].httpMethod == "GET" && sent[1].httpMethod == "POST" && sent[1].value(forHTTPHeaderField: "x-rendprop-ai-consent-disclosure") == known.disclosureRevision, "actual HTTP validates disclosure before the sole v2 create")
        check(sent[1].value(forHTTPHeaderField: "Idempotency-Key") == "property-video:" + recipe.operationID.uuidString.lowercased(), "actual create retains operation identity")
        check(sent[0].cachePolicy == .reloadIgnoringLocalCacheData, "actual HTTP bypasses disclosure cache")
        let sentRecipe = try JSONDecoder().decode(PropertyVideoJobRequest.self, from: sent[1].httpBody!)
        check(sentRecipe == recipe, "actual HTTP preserves the exact closed recipe values")
        var v1Saved = saved; v1Saved.reply = v1
        ClosedTransport.reset([(200, v1Data)])
        _ = try await client.resumePropertyVideoJob(v1Saved)
        check(ClosedTransport.captured().count == 1 && ClosedTransport.captured()[0].value(forHTTPHeaderField: "x-rendprop-ai-consent") == "property-video-jobs-v1", "actual old FAL resume does not query or upgrade current disclosure")
        var v2Saved = saved; v2Saved.reply = v2
        ClosedTransport.reset([(200, v2Data)])
        _ = try await client.resumePropertyVideoJob(v2Saved)
        check(ClosedTransport.captured().count == 1 && ClosedTransport.captured()[0].value(forHTTPHeaderField: "x-rendprop-ai-consent") == known.token, "actual saved-v2 FAL resume keeps frozen v2 independent of endpoint")
        let otherContext = PropertyVideoJobContext(localListingID: UUID(), listingID: context.listingID, actorID: context.actorID, orgID: context.orgID)
        let otherSaved = PropertyVideoSavedJob(context: otherContext, request: recipe, createdAt: Date(), reply: v1)
        try PropertyVideoJobStore.save(otherSaved, documents: docs)
        let preparationModel = AppModel(); preparationModel.listings = [.init(id: context.localListingID, serverID: context.listingID)]
        let preparation = ActualPreparationGate(listing: preparationModel.listings[0], model: preparationModel)
        try preparation.requireProcessorPreparation(permission, context: context, baseEpoch: AIConsent.shared.revocationRevision, processorEpoch: store.revision, sessionEpoch: AuthStore.shared.syncSessionRevision)
        let sessionEpoch = AuthStore.shared.syncSessionRevision
        AuthStore.shared.syncSessionRevision += 1
        rejects("pending paid preparation cannot borrow a later session") {
            try preparation.requireProcessorPreparation(permission, context: context, baseEpoch: AIConsent.shared.revocationRevision, processorEpoch: store.revision, sessionEpoch: sessionEpoch)
        }
        AuthStore.shared.syncSessionRevision = sessionEpoch
        let oldProcessorEpoch = store.revision
        // Revocation synchronously journals only v2. Pending cancellation then
        // loses its first response; the same stop remains for a fresh recovery.
        ClosedTransport.reset([])
        store.revoke()
        rejects("revoked permission cannot sign prospective requests") { _ = try PropertyVideoPaidAuthorization.processor(permission).headers(context: context) }
        let stopped = try PropertyVideoJobStore.load(context: context, documents: docs)!
        check(stopped.stopRequested == true && store.grant(for: context) == nil, "Kie revoke clears grant and persists exact stop before async cancellation")
        let otherAfter = try PropertyVideoJobStore.load(context: otherContext, documents: docs)!
        check(otherAfter.stopRequested != true && otherAfter.reply == v1, "Kie revoke preserves unrelated FAL v1 work")
        rejects("pending paid preparation cannot survive supplemental revoke") {
            try preparation.requireProcessorPreparation(permission, context: context, baseEpoch: AIConsent.shared.revocationRevision, processorEpoch: oldProcessorEpoch, sessionEpoch: AuthStore.shared.syncSessionRevision)
        }
        await rejectsAsync("revocation blocks paid resume without inferred regrant") { _ = try await client.resumePropertyVideoJob(v2Saved) }
        check(ClosedTransport.captured().allSatisfy { !$0.url!.path.hasSuffix("resume") }, "revoked grant cannot advance new dispatch")
        await PropertyVideoJobCancellation.shared.acknowledgeSavedStops(actorID: context.actorID)
        let retainedStop = try PropertyVideoJobStore.load(context: context, documents: docs)!
        check(retainedStop.stopRequested == true && retainedStop.reply == nil, "lost cancellation read keeps durable stop for next session")
        let operationAccepted: [String: Any] = ["operation_id": recipe.operationID.uuidString.lowercased(), "listing_id": recipe.listingID.uuidString.lowercased(), "selected_library_org_id": recipe.expectedOrgID.uuidString.lowercased(), "operation_closed": false, "closed_reason": NSNull(), "job": object]
        var operationCancelled = object; operationCancelled["state"] = "cancelled"; operationCancelled["resume_available"] = false
        ClosedTransport.reset([(200, try JSONSerialization.data(withJSONObject: operationAccepted)), (200, try JSONSerialization.data(withJSONObject: operationCancelled))])
        await PropertyVideoJobCancellation.shared.acknowledgeSavedStops(actorID: context.actorID)
        let recoveredStop = try PropertyVideoJobStore.load(context: context, documents: docs)!
        FileHandle.standardError.write(Data(("stop-recovery " + (recoveredStop.reply?.state ?? "none") + " " + String(recoveredStop.stopRequested == true) + " " + ClosedTransport.captured().map { ($0.httpMethod ?? "") + " " + $0.url!.path }.joined(separator: ";") + "\n").utf8))
        check(recoveredStop.reply?.state == "cancelled" && recoveredStop.stopRequested == true && ClosedTransport.captured().count == 2, "saved Kie stop recovers with GET then cancel after lost reply")
        AIConsent.shared.isGranted = false
        ClosedTransport.reset([(200, v2Data), (200, v2Data)])
        _ = try await client.propertyVideoJob(v2Saved); _ = try await client.cancelPropertyVideoJob(v2Saved)
        check(ClosedTransport.captured().count == 2 && ClosedTransport.captured().allSatisfy { $0.value(forHTTPHeaderField: "x-rendprop-ai-consent") == nil }, "status and cancel have no processor or base consent gate")
        AIConsent.shared.isGranted = true
        // Exercise actual Runner restore/cancel/reconcile, with provider/AV
        // retainReady closed. No create method is allowed by these controls.
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        saved.processorPermission = nil; saved.stopRequested = nil
        try PropertyVideoJobStore.save(saved, documents: docs)
        let model = AppModel(); model.listings = [.init(id: context.localListingID, serverID: context.listingID)]
        let api = ClosedRunnerAPI(); let work = ReelWorkJob(context)
        let missing = PropertyVideoOperationLookup(operationID: recipe.operationID, listingID: recipe.listingID, selectedLibraryOrgID: recipe.expectedOrgID, operationClosed: false, job: nil)
        let abandoned = PropertyVideoOperationLookup(operationID: recipe.operationID, listingID: recipe.listingID, selectedLibraryOrgID: recipe.expectedOrgID, operationClosed: true, job: nil, closedReason: "abandoned")
        api.lookups = [missing, abandoned]
        let runner = PropertyVideoJobRunner()
        runner.restore(work: work, model: model, api: api, context: context)
        await runner.cancel(work)
        check(api.reads == 1 && api.abandons == 1 && api.creates == 0 && api.cancels == 0, "uncertain cancel is GET then abandon with zero create")
        let wrongClosure = PropertyVideoOperationClosure(operationID: UUID(), listingID: recipe.listingID, selectedLibraryOrgID: recipe.expectedOrgID, closedReason: "abandoned")
        check(!wrongClosure.matches(recipe), "another operation cannot supply this abandonment")
        let closed = try PropertyVideoJobStore.load(context: context, documents: docs)!
        check(closed.abandoned?.matches(recipe) == true && closed.mayReplaceAfterResolution, "only exact abandon receipt unlocks replacement")
        var reopen = closed; reopen.abandoned = nil
        rejects("abandoned journal cannot reopen") { try PropertyVideoJobStore.save(reopen, documents: docs) }
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        try PropertyVideoJobStore.save(saved, documents: docs)
        let accepted = PropertyVideoOperationLookup(operationID: recipe.operationID, listingID: recipe.listingID, selectedLibraryOrgID: recipe.expectedOrgID, operationClosed: false, job: v1)
        var cancelled = v1; cancelled = .init(jobID: v1.jobID, operationID: v1.operationID, listingID: v1.listingID, orgID: v1.orgID, selectedLibraryOrgID: v1.selectedLibraryOrgID, sourceCount: 1, manifestSHA256: v1.manifestSHA256, state: "cancelled", consentRevision: v1.consentRevision, qualityProfile: v1.qualityProfile)
        api.lookups = [missing, accepted]; api.cancelled = cancelled
        runner.restore(work: work, model: model, api: api, context: context)
        await runner.cancel(work)
        check(api.creates == 0 && api.abandons == 2 && api.cancels == 1 && work.serverJob?.reply?.state == "cancelled", "accepted abandon winner is cancelled, never replaced or recreated")
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        try PropertyVideoJobStore.save(saved, documents: docs)
        api.lookups = [missing]
        runner.restore(work: work, model: model, api: api, context: context)
        await runner.cancel(work)
        let unresolved = try PropertyVideoJobStore.load(context: context, documents: docs)!
        check(unresolved.stopRequested == true && !unresolved.mayReplaceAfterResolution && api.creates == 0, "lost abandon response retains stop and blocks replacement")
        // A displayed watch survives withdrawal for reads/cancel only. Its
        // previous in-flight epoch still cannot authorize a paid continuation.
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        var displayed = saved; displayed.reply = v1
        try PropertyVideoJobStore.save(displayed, documents: docs)
        let displayedAPI = ClosedRunnerAPI(); displayedAPI.cancelled = cancelled
        let displayedWork = ReelWorkJob(context); let displayedRunner = PropertyVideoJobRunner()
        displayedRunner.restore(work: displayedWork, model: model, api: displayedAPI, context: context)
        AIConsent.shared.revocationRevision += 1; AIConsent.shared.isGranted = false
        UIApplication.shared.applicationState = .active
        displayedRunner.checkNow(displayedWork)
        for _ in 0..<10000 { if displayedWork.lastServerStatusCheck != nil { break }; await Task.yield() }
        check(displayedWork.lastServerStatusCheck != nil && displayedAPI.reads == 1 && displayedAPI.creates == 0, "displayed status watch reattaches after revoke without new paid work")
        UIApplication.shared.applicationState = .inactive
        displayedRunner.suspendForeground()
        // Restore a nonterminal request, then withdraw after its watch exists.
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        try PropertyVideoJobStore.save(displayed, documents: docs)
        let cancelAPI = ClosedRunnerAPI(); cancelAPI.cancelled = cancelled
        let cancelWork = ReelWorkJob(context); let cancelRunner = PropertyVideoJobRunner()
        cancelRunner.restore(work: cancelWork, model: model, api: cancelAPI, context: context)
        AIConsent.shared.revocationRevision += 1
        await cancelRunner.cancel(cancelWork)
        check(cancelAPI.cancels == 1 && cancelAPI.creates == 0 && cancelWork.serverJob?.reply?.state == "cancelled", "displayed cancel watch reattaches after revoke without consent")
        AIConsent.shared.isGranted = true
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        try PropertyVideoJobStore.save(displayed, documents: docs)
        let resumeAPI = ClosedRunnerAPI(); resumeAPI.cancelled = cancelled
        let resumeWork = ReelWorkJob(context); let resumeRunner = PropertyVideoJobRunner()
        resumeRunner.restore(work: resumeWork, model: model, api: resumeAPI, context: context)
        try PropertyVideoJobStore.requestStop(actorID: context.actorID, documents: docs)
        check(resumeWork.serverJob?.stopRequested != true, "fixture retains stale in-memory pre-withdrawal work")
        await resumeRunner.resume(resumeWork)
        check(resumeAPI.resumes == 0, "explicit resume reloads durable stop instead of borrowing stale in-memory authority")
        // Execute the real base-consent revoke body, not a synthetic equivalent.
        try FileManager.default.removeItem(at: PropertyVideoJobStore.url(context: context, documents: docs))
        let reallow = Task { try await store.ensure(known, context: context) }
        await Task.yield(); store.allow()
        let secondPermission = try await reallow.value
        var freshPending = saved; freshPending.processorPermission = secondPermission
        try PropertyVideoJobStore.save(freshPending, documents: docs)
        ClosedTransport.reset([])
        AIConsent.shared.revoke()
        let baseStopped = try PropertyVideoJobStore.load(context: context, documents: docs)!
        check(!AIConsent.shared.isGranted && store.grant(for: context) == nil && baseStopped.stopRequested == true, "actual base revoke synchronously clears supplemental grant and journals stop")
        check(try! PropertyVideoJobCancellation.pending(actorID: context.actorID) != nil, "actual base revoke persists global stop before async network")
        AIConsent.shared.isGranted = true
        check(store.grant(for: context) == nil, "base regrant cannot resurrect supplemental permission")
        while let intent = try PropertyVideoJobCancellation.pending(actorID: context.actorID) { try PropertyVideoJobCancellation.retire(intent) }
        print("PASS \(checks) actual processor/client assertions")
    }
}
