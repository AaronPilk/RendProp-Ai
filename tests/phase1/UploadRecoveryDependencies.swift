import Foundation

// Only the application boundary is replaced. UploadTicket, UploadMetadata,
// PhotoTicket and APIError are extracted byte-for-byte from production by the
// runner; the complete UploadManager/DirectUploader implementations compile.
protocol APIClient {
    func requestUpload(filename: String, bytes: Int64, listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?, idempotencyKey: String?) async throws -> UploadTicket
    func renewUpload(assetID: String) async throws -> UploadTicket
    func restartUpload(assetID: String, operationID: UUID) async throws -> UploadTicket
    func completeUpload(assetID: String, parts: [(number: Int, etag: String)]?, metadata: UploadMetadata) async throws
    func abortUpload(assetID: String) async throws
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL]
}
enum Config {
    static let useLiveBackend = true
    static let enableAuth = true
    static let cellularWarnBytes: Int64 = 100_000_000
    static func makeAPIClient() -> APIClient { RecoveryAPI() }
}
enum FileStore {
    static var documents = URL(fileURLWithPath: "/unused-test-documents")
    static func relativePath(for url: URL) -> String { url.lastPathComponent }
    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
final class AuthStore {
    static let shared = AuthStore()
    static var currentAccessToken: String? = "offline-fixture-only"
    static var connections = 0
    static func jwtSubject(_ token: String) -> String? {
        token == "other-owner-fixture" ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111"
    }
    func ensureSession() async -> Bool {
        if Self.currentAccessToken == nil { Self.connections += 1; Self.currentAccessToken = "offline-fixture-only" }
        return true
    }
}
enum Haptics { static func success() {} }
final class BackgroundSessionBridge {
    static let shared = BackgroundSessionBridge()
    var completionHandler: (() -> Void)?
}

final class RecoveryAPI: APIClient {
    let oldID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let newID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    var log: [String] = []
    var keys: [String] = []
    var creates = 0
    var cancels = 0
    var renews = 0
    var transfers = 0
    var physicalWrites = 0
    var stored = false
    var completed = false
    var legacy = false
    var aborted = false
    var loseCompleteOnce = false
    var failTransferBeforeWriteOnce = false
    var loseTransferReplyOnce = false
    var uncertain = false
    var rollback = false
    var failAbortOnce = false
    var completionFailure: APIError?
    var restartKeys: [UUID] = []
    var replacements = 0
    var loseRestartReplyOnce = false
    var completionWinsRestart = false
    var switchOwnerOnRestart = false
    var restartGeneration = 0
    var holdTransfer = false
    var heldTransfer: CheckedContinuation<Void, Error>?

    func ticket(_ id: String? = nil) -> UploadTicket {
        var result = UploadTicket(assetID: id ?? oldID, mode: .single,
                     putURL: URL(string: "https://upload.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1893456000&signature=" + String(repeating: "a", count: 64)),
                     transportVersion: rollback ? nil : (legacy ? 1 : 2), uploaded: completed, replayed: creates > 1)
        if completionFailure != nil, result.assetID == oldID {
            result.restartRequired = true; result.restartReason = "expired"; result.restartGeneration = restartGeneration
        }
        return result
    }
    func requestUpload(filename: String, bytes: Int64, listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?, idempotencyKey: String?) async throws -> UploadTicket {
        log.append("create"); creates += 1; keys.append(idempotencyKey ?? "missing")
        var result = ticket(aborted ? newID : oldID)
        result.replayed = legacy
        return result
    }
    func renewUpload(assetID: String) async throws -> UploadTicket {
        log.append("renew"); renews += 1
        if uncertain { throw APIError.server(status: 503, code: "UPSTREAM", message: "Receipt not yet provable") }
        return ticket(assetID)
    }
    func restartUpload(assetID: String, operationID: UUID) async throws -> UploadTicket {
        log.append("restart"); restartKeys.append(operationID)
        if completionWinsRestart { completed = true; return ticket(oldID) }
        guard assetID == oldID else { throw APIError.badResponse(409) }
        if replacements == 0 { replacements = 1; completed = false; stored = false; completionFailure = nil }
        if switchOwnerOnRestart { AuthStore.currentAccessToken = "other-owner-fixture" }
        if loseRestartReplyOnce { loseRestartReplyOnce = false; throw URLError(.networkConnectionLost) }
        var result = ticket(newID); result.restartGeneration = 1
        return result
    }
    func completeUpload(assetID: String, parts: [(number: Int, etag: String)]?, metadata: UploadMetadata) async throws {
        log.append("complete")
        if let completionFailure { throw completionFailure }
        if completed { return }
        if aborted && assetID == oldID {
            throw APIError.server(status: 409, code: "CONFLICT", message: "This upload was aborted — create a new ticket")
        }
        if legacy {
            throw APIError.server(status: 409, code: "CONFLICT", message: "Legacy upload must be reticketed after rollout cleanup")
        }
        if !stored {
            throw APIError.server(status: 409, code: "CONFLICT", message: "every transfer needs its durable stored receipt before completion")
        }
        completed = true
        if loseCompleteOnce { loseCompleteOnce = false; throw URLError(.networkConnectionLost) }
    }
    func abortUpload(assetID: String) async throws {
        log.append("cancel"); cancels += 1
        guard assetID == oldID && legacy else { throw APIError.badResponse(409) }
        aborted = true; legacy = false
        if failAbortOnce { failAbortOnce = false; throw URLError(.networkConnectionLost) }
    }
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL] { [:] }
    func transfer(_ request: URLRequest, _ file: URL) async throws -> URLResponse {
        log.append("put"); transfers += 1
        if holdTransfer { try await withCheckedThrowingContinuation { heldTransfer = $0 } }
        if failTransferBeforeWriteOnce {
            failTransferBeforeWriteOnce = false; throw URLError(.notConnectedToInternet)
        }
        if uncertain { throw URLError(.networkConnectionLost) }
        physicalWrites += 1; stored = true
        if loseTransferReplyOnce { loseTransferReplyOnce = false; throw URLError(.networkConnectionLost) }
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

/// Session boundary only: the real UploadManager performs selection, slicing,
/// scheduling, task identity, Pause and completion handling. No request leaves
/// the process; tests decide when a started transfer returns its receipt.
final class RecoveryTask: URLSessionUploadTask, @unchecked Sendable {
    let fixtureID: Int
    var fixtureState: URLSessionTask.State = .suspended
    var starts = 0
    var cancellations = 0
    var suspensions = 0
    var fixtureResponse: URLResponse?
    init(_ id: Int) { fixtureID = id; super.init() }
    override var taskIdentifier: Int { fixtureID }
    override var state: URLSessionTask.State { fixtureState }
    override var response: URLResponse? { fixtureResponse }
    override func resume() { starts += 1; fixtureState = .running }
    override func cancel() { cancellations += 1; fixtureState = .canceling }
    override func suspend() { suspensions += 1; fixtureState = .suspended }
}
final class RecoverySession: URLSession, @unchecked Sendable {
    var fixtureTasks: [RecoveryTask] = []
    var deferEnumeration = false
    var enumerations: [@Sendable ([URLSessionTask]) -> Void] = []
    override init() { super.init() }
    override func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        if deferEnumeration { enumerations.append(completionHandler); return }
        completionHandler(fixtureTasks.filter { $0.state == .running || $0.state == .suspended })
    }
    override func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        let task = RecoveryTask(fixtureTasks.count + 1)
        fixtureTasks.append(task)
        return task
    }
}
final class MultipartRecoveryAPI: APIClient {
    let assetID = UUID().uuidString
    var partRequests: [[Int]] = []
    var renews = 0
    var creates = 0
    var completes = 0
    var confirmed: [UploadTicket.ConfirmedPart] = []
    var acceptedParts: [(number: Int, etag: String)]?
    var delayedRenewal: CheckedContinuation<UploadTicket, Error>?
    var waitForRenewal = false
    func requestUpload(filename: String, bytes: Int64, listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?, idempotencyKey: String?) async throws -> UploadTicket {
        creates += 1; throw APIError.badResponse(500)
    }
    func renewUpload(assetID: String) async throws -> UploadTicket {
        renews += 1
        if waitForRenewal { return try await withCheckedThrowingContinuation { delayedRenewal = $0 } }
        return UploadTicket(assetID: self.assetID, mode: .multipart, uploadID: "fixture-session",
            partSize: 16, partCount: 4, transportVersion: 2, uploaded: false, confirmedParts: confirmed)
    }
    func completeUpload(assetID: String, parts: [(number: Int, etag: String)]?, metadata: UploadMetadata) async throws {
        completes += 1
        guard parts?.count == 4 else {
            throw APIError.server(status: 400, code: "BAD_REQUEST", message: "parts[] must contain each part 1…4 exactly once")
        }
        acceptedParts = parts
    }
    func abortUpload(assetID: String) async throws { throw APIError.badResponse(500) }
    func restartUpload(assetID: String, operationID: UUID) async throws -> UploadTicket { throw APIError.badResponse(500) }
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL] {
        partRequests.append(numbers)
        return Dictionary(uniqueKeysWithValues: numbers.map { ($0, URL(string:
            "https://upload.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1893456000&signature=" + String(repeating: "a", count: 64))!) })
    }
}
