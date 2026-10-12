import Foundation
import CryptoKit

// __ACTUAL_TYPES__

enum Config {
    static let enableAuth = true
    static let supabaseAnonKey = "closed-fixture-public-key"
}
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
enum WorkspaceContext { static let selectedOrgID: UUID? = UUID(uuidString: "10000000-0000-4000-8000-000000000005") }
enum CloudSyncError: Error { case identityChanged }
enum AnonymousAdoptionRecovery {
    struct Identity { let id: UUID }
    static func identity(_ value: String) -> Identity? {
        value == "closed-fixture-token" ? Identity(id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!) : nil
    }
}
enum DirectUploader {
    // __ACTUAL_DIGESTS__
}

final class DriftWireProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool {
        precondition(request.url?.host == "closed.fixture.invalid", "wire fixture must never contact an external host")
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0, "body stream must remain readable")
                if count == 0 { break }
                bytes.append(buffer, count: count)
            }
            capturedRequest.httpBody = bytes
        }
        Self.lock.lock(); Self.captured.append(capturedRequest); Self.lock.unlock()
        let body = try! JSONSerialization.jsonObject(with: capturedRequest.httpBody!) as! [String: Any]
        let first = (body["attempt"] as? Int) == 0
        let data = try! JSONSerialization.data(withJSONObject: ["drift": [
            "status": "fail", "publishable": false, "action": first ? "retry" : "refuse",
            "message": "Closed property-QC response"
        ]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DriftWireClient {
    let base = URL(string: "https://closed.fixture.invalid/functions/v1")!
    let session: URLSession
    let aiSession: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DriftWireProtocol.self]
        let transport = URLSession(configuration: config)
        session = transport; aiSession = transport
    }
    // __ACTUAL_CLIENT_METHODS__
}

@main struct DriftWireTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1; precondition(condition(), message)
        }
        let client = DriftWireClient()
        let source = Data("exact selected source JPEG".utf8).base64EncodedString()
        let frames = ["first", "middle", "last"].map { (at: $0, jpeg: Data("decoded-\($0)-JPEG".utf8)) }
        let listingID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let provenance = "10000000-0000-4000-8000-000000000002"
        var request = DriftCheckRequest(requestID: "accepted-owned-job", kind: "reel", sourceBase64: source,
            frames: frames, seconds: 5, motion: "push_in", room: "living", spaceType: "real_estate",
            listingServerID: listingID, provenanceID: provenance)
        check(request.attempt == 1, "legacy/default drift request remains conservative attempt one")
        let cases: [(Int, Int, String)] = [(0, 0, "first"), (1, 1, "retry"), (-7, 0, "negative"), (99, 3, "oversized"), (request.attempt, 1, "legacy")]
        for (attempt, expected, label) in cases {
            DriftWireProtocol.reset(); request.attempt = attempt
            let verdict = try await client.aiVideoDrift(request)
            let captured = DriftWireProtocol.requests()
            check(captured.count == 1, "one actual HTTP dispatch per QC request")
            let wire = captured[0]
            check(wire.httpMethod == "POST", "actual QC dispatch uses POST")
            check(wire.url?.path == "/functions/v1/ai-video/drift", "actual QC dispatch uses drift route")
            check(wire.value(forHTTPHeaderField: "Authorization") == "Bearer closed-fixture-token", "actual executor attaches current account bearer")
            check(wire.value(forHTTPHeaderField: "Idempotency-Key") == "drift:accepted-owned-job:\(attempt)", "actual request builder preserves QC operation key")
            check(wire.value(forHTTPHeaderField: "Content-Type") == "application/json", "actual request builder emits JSON content type")
            let body = try JSONSerialization.jsonObject(with: wire.httpBody!) as! [String: Any]
            check(body["attempt"] as? Int == expected, "\(label) attempt is serialized as \(expected)")
            check(body["source_b64"] as? String == source, "serialized QC retains exact selected source bytes")
            check(body["source_mime"] as? String == "image/jpeg", "serialized QC retains source MIME")
            check(body["request_id"] as? String == "accepted-owned-job", "serialized QC retains accepted request identity")
            check(body["provenance_id"] as? String == provenance, "serialized QC forwards accepted provenance identity")
            check(body["listing_id"] as? String == listingID.uuidString, "serialized QC retains listing identity")
            let sentFrames = body["frames"] as! [[String: Any]]
            check(sentFrames.count == 3, "actual wire body contains three decoded frames")
            for index in frames.indices {
                check(sentFrames[index]["at"] as? String == frames[index].at, "actual wire retains frame positions")
                check(sentFrames[index]["b64"] as? String == frames[index].jpeg.base64EncodedString(), "actual wire retains frame JPEG bytes")
            }
            check(!verdict.mayUse, "failed property check never becomes publishable")
            check(verdict.action == (expected == 0 ? "retry" : "refuse"), "actual decoder preserves bounded QC action")
        }
        DriftWireProtocol.reset()
        AuthStore.beforeToken = { AuthStore.shared.syncSessionRevision += 1 }
        do { _ = try await client.aiVideoDrift(request); preconditionFailure("identity change before dispatch must refuse") }
        catch CloudSyncError.identityChanged {}
        AuthStore.beforeToken = nil
        check(DriftWireProtocol.requests().isEmpty, "actual executor prevents dispatch after account revision change")
        print("PASSED: \(assertions) actual QC wire assertions")
    }
}
