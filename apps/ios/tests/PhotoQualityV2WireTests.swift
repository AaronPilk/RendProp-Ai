import Foundation
import CryptoKit
// __ACTUAL_TYPES__
enum Config { static let enableAuth = true; static let supabaseAnonKey = "closed-public-key" }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "10000000-0000-4000-8000-000000000003"
    var syncSessionRevision: UInt64 = 1
    var isSignedIn = true
    nonisolated static let currentAccessToken: String? = "closed-fixture-token"
    static var beforeToken: (() -> Void)?
    static func validAccessToken() async -> String? { await Task.yield(); beforeToken?(); return currentAccessToken }
    func forceRefresh() async -> Bool { true }
    func signOut(preservingAdoption: Bool = false) { isSignedIn = false }
}
enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "10000000-0000-4000-8000-000000000005") }
enum CloudSyncError: Error { case identityChanged, invalidResponse }
enum SpaceType { case realEstate; static let current = SpaceType.realEstate; var rawValue: String { "real_estate" } }
enum AnonymousAdoptionRecovery {
    struct Identity { let id: UUID }
    static func identity(_ value: String) -> Identity? { value == "closed-fixture-token" ? Identity(id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!) : nil }
}
enum DirectUploader { // __ACTUAL_DIGESTS__
}
@MainActor final class AIConsent { static let shared = AIConsent(); var isGranted = true; var revocationRevision: UInt64 = 1 }
final class PhotoWireProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static var pending = false
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { precondition(request.url?.host == "closed.fixture.invalid"); return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); precondition(n >= 0); if n == 0 { break }; bytes.append(buffer, count: n) }; copy.httpBody = bytes
        }
        Self.lock.lock(); Self.captured.append(copy); Self.lock.unlock()
        let body = Self.pending ? #"{"error":"Saved photo quality is pending; check the same edit.","code":"photo_quality_pending"}"# : #"{"image_b64":"c2F2ZWQtcGFpZC1waG90bw==","mime":"image/png","provenance":{"id":"retained-provenance","recorded":true}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.pending ? 409 : 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class PhotoWireClient {
    let base = URL(string: "https://closed.fixture.invalid/functions/v1")!
    let session: URLSession; let aiSession: URLSession
    init() { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PhotoWireProtocol.self]; let transport = URLSession(configuration: config); session = transport; aiSession = transport }
    // __ACTUAL_CLIENT_METHODS__
}
// __ACTUAL_PENDING__
@main struct PhotoQualityV2WireTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
        let client = PhotoWireClient(), listing = UUID(), library = WorkspaceContext.selectedOrgID!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposed = AIPhotoEditRequest(imageBase64: "c2VsZWN0ZWQtc291cmNl", edit: "stage")
        proposed.style = "contemporary"; proposed.prompt = "Keep every door and window"; proposed.listingServerID = listing; proposed.originalAssetID = UUID().uuidString
        let identity = PhotoPendingEdit.Identity(actor: AuthStore.shared.userID!, library: library, listing: listing, sourceVersion: "retained-original")
        let saved = try PhotoPendingEdit.begin(proposed, identity: identity, directory: directory)
        PhotoWireProtocol.pending = true; PhotoWireProtocol.reset()
        do { _ = try await client.aiPhotoEdit(saved.request); preconditionFailure("pending must remain a typed non-success") }
        catch APIError.server(_, let code, _) { check(code == "photo_quality_pending", "pending code reaches the caller without invented success") }
        let first = PhotoWireProtocol.requests()[0]
        let recovered = try PhotoPendingEdit.begin(proposed, identity: identity, directory: directory)
        check(recovered.request == saved.request && recovered.url == saved.url, "pending replay retains the exact paid request")
        PhotoWireProtocol.pending = false; PhotoWireProtocol.reset()
        let result = try await client.aiPhotoEdit(recovered.request), wire = PhotoWireProtocol.requests()[0]
        check(wire.url?.path == "/functions/v1/ai-photo-v2" && wire.httpMethod == "POST", "photo v2 uses only the new versioned admission route")
        check(wire.value(forHTTPHeaderField: "x-rendprop-photo-quality-protocol") == "retained-operation-v1", "photo v2 declares the retained-operation protocol")
        check(wire.value(forHTTPHeaderField: "X-Org-Id") == library.uuidString.lowercased(), "photo v2 carries the exact selected library")
        check(wire.value(forHTTPHeaderField: "Idempotency-Key") == saved.request.idempotencyKey && wire.value(forHTTPHeaderField: "Idempotency-Key") == first.value(forHTTPHeaderField: "Idempotency-Key"), "pending replay sends the same paid operation key")
        check(wire.httpBody == first.httpBody, "pending replay sends the identical dispatched body")
        let body = try JSONSerialization.jsonObject(with: wire.httpBody!) as! [String: Any]
        check(body["image_b64"] as? String == proposed.imageBase64 && body["style"] as? String == "contemporary", "photo v2 preserves selected source and style")
        check(body["original_asset_id"] as? String == proposed.originalAssetID && body["listing_id"] as? String == listing.uuidString, "photo v2 preserves original and property lineage")
        check(result.mime == "image/png" && result.provenanceID == "retained-provenance", "photo v2 keeps exact supplier MIME and provenance")
        for invalid in [nil, "new-random-key"] as [String?] {
            PhotoWireProtocol.reset(); var bad = saved.request; bad.idempotencyKey = invalid
            do { _ = try await client.aiPhotoEdit(bad); preconditionFailure("photo v2 cannot claim recovery without a stable saved UUID") } catch CloudSyncError.identityChanged {}
            check(PhotoWireProtocol.requests().isEmpty, "missing saved key refuses before actual POST")
        }
        for cause in ["account", "workspace", "consent", "regrant"] {
            PhotoWireProtocol.reset(); AIConsent.shared.isGranted = true
            AuthStore.beforeToken = {
                if cause == "account" { AuthStore.shared.syncSessionRevision += 1 }
                if cause == "workspace" { WorkspaceContext.selectedOrgID = UUID() }
                if cause == "consent" { AIConsent.shared.isGranted = false; AIConsent.shared.revocationRevision += 1 }
                if cause == "regrant" { AIConsent.shared.revocationRevision += 1 }
            }
            do { _ = try await client.aiPhotoEdit(saved.request); preconditionFailure("changed photo dispatch context must refuse") }
            catch CloudSyncError.identityChanged {} catch APIError.server(_, let code, _) { check(code == "consent_required", "revoked or regranted consent refuses unsent photo") }
            AuthStore.beforeToken = nil; WorkspaceContext.selectedOrgID = library; AIConsent.shared.isGranted = true
            check(PhotoWireProtocol.requests().isEmpty, "changed photo context prevents actual POST")
        }
        check(FileManager.default.fileExists(atPath: saved.url.path), "pending source operation remains until local image save")
        print("PASS \(checks) actual photo-v2 HTTP and retained-request assertions")
    }
}
