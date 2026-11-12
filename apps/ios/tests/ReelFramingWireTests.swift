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
enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "10000000-0000-4000-8000-000000000005") }
enum CloudSyncError: Error { case identityChanged, invalidResponse }
enum AnonymousAdoptionRecovery {
    struct Identity { let id: UUID }
    static func identity(_ value: String) -> Identity? {
        value == "closed-fixture-token" ? Identity(id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!) : nil
    }
}
enum DirectUploader {
    // __ACTUAL_DIGESTS__
}

@MainActor final class AIConsent {
    static let shared = AIConsent()
    var isGranted = true
    var revocationRevision: UInt64 = 1
}

final class ReelWireProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool {
        precondition(request.url?.host == "closed.fixture.invalid", "fixture must never contact an external host")
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0, "actual request body remains readable")
                if count == 0 { break }
                bytes.append(buffer, count: count)
            }
            copy.httpBody = bytes
        }
        Self.lock.lock(); Self.captured.append(copy); Self.lock.unlock()
        let data = Data(#"{"request_id":"accepted","status_url":"owned-status","response_url":"owned-response","kind":"reel","synthetic":true,"provenance":{"id":"owned-provenance"}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class ReelWireClient {
    let base = URL(string: "https://closed.fixture.invalid/functions/v1")!
    let session: URLSession
    let aiSession: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReelWireProtocol.self]
        let transport = URLSession(configuration: config); session = transport; aiSession = transport
    }
    // __ACTUAL_CLIENT_METHODS__
}
@main struct ReelFramingWireTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1; precondition(condition(), message)
        }
        let client = ReelWireClient()
        let source = Data("same full selected JPEG".utf8).base64EncodedString()
        let listing = UUID(uuidString:"10000000-0000-4000-8000-000000000001")!
        func submit(_ framing: String?) async throws -> AIVideoJob {
            try await client.aiVideoReelClip(imageBase64: source, mime:"image/jpeg", prompt:nil, seconds:5,
                aspect:"9:16", framing:framing, presetVersion:1, motion:"fly_through", room:"living",
                shotIndex:0, shotCount:8, listingServerID:listing, label:"living", idempotencyKey:"same-durable-key")
        }
        for framing in [nil, "preserve_photo"] as [String?] {
            ReelWireProtocol.reset()
            let job = try await submit(framing)
            let sent = ReelWireProtocol.requests()
            check(sent.count == 1, "one provider admission request per explicit submission")
            let wire = sent[0]
            let body = try JSONSerialization.jsonObject(with: wire.httpBody!) as! [String:Any]
            check(wire.httpMethod == "POST" && wire.url?.path == "/functions/v1/ai-video/reel-clip", "actual reel wire retains its admission route")
            check(body["image_b64"] as? String == source, "full selected source bytes remain unchanged on wire")
            check(body["framing"] as? String == framing, framing == nil ? "legacy nil framing is absent on wire" : "explicit whole-photo framing survives actual wire serialization")
            check(body["aspect"] as? String == "9:16", "requested final delivery aspect remains separate from full-source framing")
            check(body["motion"] as? String == "fly_through" && body["shot_count"] as? Int == 8, "framing preserves shot intent")
            check(body["listing_id"] as? String == listing.uuidString, "framing preserves the exact listing binding")
            check(wire.value(forHTTPHeaderField:"Idempotency-Key") == "same-durable-key", "framing preserves the durable paid operation key")
            check(wire.value(forHTTPHeaderField:"X-Org-Id") == WorkspaceContext.selectedOrgID!.uuidString.lowercased(), "actual dispatch preserves private workspace scope")
            check(job.requestId == "accepted" && job.provenanceID == "owned-provenance", "actual accepted job decoder preserves request and provenance")
        }
        ReelWireProtocol.reset()
        _ = try await client.aiVideoReelClip(imageBase64:source,mime:"image/jpeg",prompt:nil,seconds:5,
            aspect:"9:16",presetVersion:1,motion:"fly_through",room:nil,shotIndex:0,shotCount:8,
            listingServerID:listing,label:nil,idempotencyKey:"legacy-key")
        let oldBody = try JSONSerialization.jsonObject(with:ReelWireProtocol.requests()[0].httpBody!) as! [String:Any]
        check(oldBody["framing"] == nil, "actual legacy overload forwards absent framing")
        ReelWireProtocol.reset()
        let sourceAsset=UUID().uuidString,sourceProvenance=UUID().uuidString
        _ = try await client.aiVideoReelClip(imageBase64:source,mime:"image/jpeg",prompt:nil,seconds:5,
            aspect:"16:9",framing:"preserve_photo",presetVersion:1,motion:"side_glide",room:nil,shotIndex:99,shotCount:100,
            listingServerID:listing,label:nil,idempotencyKey:"exact-selected-source",sourceAssetID:sourceAsset,sourceProvenanceID:sourceProvenance)
        let boundBody=try JSONSerialization.jsonObject(with:ReelWireProtocol.requests()[0].httpBody!) as! [String:Any]
        check(boundBody["source_asset_id"] as? String == sourceAsset && boundBody["source_provenance_id"] as? String == sourceProvenance,
            "actual exact-source overload retains prepared selected asset and provenance")
        check(boundBody["aspect"] as? String == "16:9" && boundBody["shot_index"] as? Int == 99 && boundBody["shot_count"] as? Int == 100,
            "actual listing wire retains widescreen destination and all hundred shot positions")
        check(oldBody["image_b64"] as? String == source, "actual legacy overload keeps its saved source bytes")
        ReelWireProtocol.reset()
        do { _ = try await submit("crop_and_invent"); preconditionFailure("unsupported framing must refuse") }
        catch CloudSyncError.invalidResponse {}
        check(ReelWireProtocol.requests().isEmpty, "unsupported framing refuses before dispatch")
        for cause in ["account", "workspace", "consent"] {
            ReelWireProtocol.reset()
            let workspace = WorkspaceContext.selectedOrgID
            AIConsent.shared.isGranted = true
            AuthStore.beforeToken = {
                if cause == "account" { AuthStore.shared.syncSessionRevision += 1 }
                if cause == "workspace" { WorkspaceContext.selectedOrgID = UUID() }
                if cause == "consent" { AIConsent.shared.isGranted = false; AIConsent.shared.revocationRevision += 1 }
            }
            do { _ = try await submit("preserve_photo"); preconditionFailure("changed dispatch context must refuse") }
            catch CloudSyncError.identityChanged {} catch APIError.server(_, let code, _) { check(code == "consent_required", "late revoked consent uses the refusal classification") }
            AuthStore.beforeToken = nil; WorkspaceContext.selectedOrgID = workspace; AIConsent.shared.isGranted = true
            check(ReelWireProtocol.requests().isEmpty, "changed dispatch context prevents the actual POST")
        }
        print("PASSED: \(assertions) actual reel framing HTTP assertions")
    }
}
