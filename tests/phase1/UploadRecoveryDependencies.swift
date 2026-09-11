import Foundation

// Only the application boundary is replaced. UploadTicket, UploadMetadata,
// PhotoTicket and APIError are extracted byte-for-byte from production by the
// runner; the complete UploadManager/DirectUploader implementations compile.
protocol APIClient {
    func requestUpload(filename: String, bytes: Int64, listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?, idempotencyKey: String?) async throws -> UploadTicket
    func renewUpload(assetID: String) async throws -> UploadTicket
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
    static var documents: URL { URL(fileURLWithPath: "/unused-test-documents") }
    static func relativePath(for url: URL) -> String { url.lastPathComponent }
    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
final class AuthStore {
    static let shared = AuthStore()
    static var currentAccessToken: String? = "offline-fixture-only"
    static var connections = 0
    static func jwtSubject(_ token: String) -> String? { "11111111-1111-4111-8111-111111111111" }
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

    func ticket(_ id: String? = nil) -> UploadTicket {
        UploadTicket(assetID: id ?? oldID, mode: .single,
                     putURL: URL(string: "https://upload.invalid/v2/11111111-1111-4111-8111-111111111111?expires=1893456000&signature=" + String(repeating: "a", count: 64)),
                     transportVersion: rollback ? nil : (legacy ? 1 : 2), uploaded: completed, replayed: creates > 1)
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
        if failTransferBeforeWriteOnce {
            failTransferBeforeWriteOnce = false; throw URLError(.notConnectedToInternet)
        }
        if uncertain { throw URLError(.networkConnectionLost) }
        physicalWrites += 1; stored = true
        if loseTransferReplyOnce { loseTransferReplyOnce = false; throw URLError(.networkConnectionLost) }
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
