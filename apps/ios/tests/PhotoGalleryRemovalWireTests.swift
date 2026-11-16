import Foundation
import CryptoKit
// __ACTUAL_ERROR__
// __ACTUAL_CONTEXT__
enum Config { static let enableAuth = true; static let supabaseAnonKey = "closed-public-key" }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    static let fixtureActor = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    var userID: String? = fixtureActor.uuidString
    var syncSessionRevision: UInt64 = 1
    var isSignedIn = true
    var isIdentified = true
    nonisolated static let currentAccessToken: String? = "closed-token"
    static var beforeToken: (() -> Void)?
    static func validAccessToken() async -> String? { await Task.yield(); beforeToken?(); return currentAccessToken }
    func forceRefresh() async -> Bool { false }
    func signOut(preservingAdoption: Bool = false) { isSignedIn = false }
}
enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
enum CloudSyncError: Error { case identityChanged }
enum AnonymousAdoptionRecovery {
    struct Identity { let id: UUID }
    static func identity(_ token: String) -> Identity? { .init(id: AuthStore.fixtureActor) }
}
enum DirectUploader { // __ACTUAL_DIGESTS__
}
@MainActor enum WireFixture {
    static var requests: [URLRequest] = []
    static var body: [String: Any] = [:]
    static var status = 200
    static var loseReply = false
    static var beforeReply: (() -> Void)?
    static func reset() { requests = []; beforeReply = nil; loseReply = false; status = 200 }
}
final class RemovalWireProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        precondition(request.url?.host == "closed.fixture.invalid", "No external network is allowed")
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); precondition(n >= 0); if n == 0 { break }; bytes.append(buffer, count: n) }
            captured.httpBody = bytes
        }
        let copied = captured
        Task { @MainActor in
            WireFixture.requests.append(copied)
            WireFixture.beforeReply?()
            if WireFixture.loseReply { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
            let bytes = try! JSONSerialization.data(withJSONObject: WireFixture.body)
            let response = HTTPURLResponse(url: copied.url!, statusCode: WireFixture.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
final class RemovalWireClient {
    let base = URL(string: "https://closed.fixture.invalid/functions/v1")!
    let session: URLSession
    init() { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RemovalWireProtocol.self]; session = URLSession(configuration: config) }
    // __ACTUAL_METHODS__
}
@main struct GalleryRemovalWireChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }; count += 1
        }
        let client = RemovalWireClient(), library = WorkspaceContext.selectedOrgID!, listing = UUID(), asset = UUID(), other = UUID()
        let op = PhotoGalleryRemovalOperation(operationID: UUID(), actorID: AuthStore.fixtureActor,
            libraryOrgID: library, localListingID: UUID(), serverListingID: listing, familyID: "capture",
            selectedVersionID: "capture-original", requestedAssetIDs: [asset], expectedGalleryAssetIDs: [asset, other], expectedMainPhotoKey: nil)
        func response(removal: Bool) -> [String: Any] {
            var value: [String: Any] = ["id": listing.uuidString, "org_id": library.uuidString,
                "library_org_id": library.uuidString, "gallery_asset_ids": (removal ? [other] : [asset, other]).map(\.uuidString),
                "main_photo_key": NSNull()]
            if removal {
                value["gallery_remove"] = ["operation_id": op.operationID.uuidString, "actor_id": op.actorID.uuidString,
                    "replayed": true, "requested_asset_ids": [asset.uuidString], "removed_asset_ids": [asset.uuidString]] as [String: Any]
            } else {
                value["gallery_assets"] = [["asset_id": asset.uuidString, "sha256": String(repeating: "a", count: 64), "bytes": 100],
                    ["asset_id": other.uuidString, "sha256": String(repeating: "b", count: 64), "bytes": 200]]
            }
            return value
        }
        WireFixture.body = response(removal: false)
        let selection = try await client.gallerySelection(serverID: listing, libraryOrgID: library)
        let get = WireFixture.requests[0]
        check(get.httpMethod == "GET" && URLComponents(url: get.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "gallery_selection", value: "1")], "Selection GET requests only the scoped exact gallery projection")
        check(get.value(forHTTPHeaderField: "X-Org-Id") == library.uuidString.lowercased() && selection.galleryAssets.count == 2,
              "Selection GET carries exact library and decodes bounded byte identities")
        check(get.value(forHTTPHeaderField: "Idempotency-Key") == nil, "Selection GET is read-only")
        WireFixture.reset(); WireFixture.body = response(removal: true); WireFixture.loseReply = true
        do { _ = try await client.removeGalleryAssets(op); check(false, "Synthetic transport reply must be lost") } catch {}
        check(WireFixture.requests.count == 1, "Unknown transport outcome does not automatically repeat PATCH")
        let first = WireFixture.requests[0]
        WireFixture.reset(); WireFixture.body = response(removal: true)
        let reply = try await client.removeGalleryAssets(op), patch = WireFixture.requests[0]
        check(patch.httpMethod == "PATCH" && patch.url?.path == "/functions/v1/listings/\(listing.uuidString)", "Removal uses exact listing PATCH")
        check(patch.value(forHTTPHeaderField: "X-Org-Id") == library.uuidString.lowercased(), "Removal PATCH carries exact library")
        check(patch.value(forHTTPHeaderField: "Idempotency-Key") == "gallery-remove:" + op.operationID.uuidString.lowercased()
            && patch.value(forHTTPHeaderField: "Idempotency-Key") == first.value(forHTTPHeaderField: "Idempotency-Key"),
            "Explicit recovery preserves stable operation header")
        check(patch.httpBody == first.httpBody, "Explicit recovery preserves identical wire body")
        let body = try JSONSerialization.jsonObject(with: patch.httpBody!) as! [String: Any]
        check(Set(body.keys) == ["gallery_remove_asset_ids", "gallery_remove_operation_id", "expected_gallery_asset_ids", "expected_main_photo_key"]
            && body["gallery_remove_asset_ids"] as? [String] == [asset.uuidString.lowercased()]
            && body["expected_gallery_asset_ids"] as? [String] == [asset, other].map { $0.uuidString.lowercased() }
            && body["expected_main_photo_key"] is NSNull, "Removal body keeps exact closed CAS snapshot including explicit null")
        check(reply.operationID == op.operationID && reply.removedAssetIDs == [asset], "Exact receipt reaches caller")
        for field in ["actor_id", "operation_id", "requested_asset_ids", "removed_asset_ids", "duplicate_removed", "listing", "library"] {
            WireFixture.reset(); var bad = response(removal: true)
            if field == "listing" { bad["id"] = UUID().uuidString }
            else if field == "library" { bad["library_org_id"] = UUID().uuidString }
            else {
                var receipt = bad["gallery_remove"] as! [String: Any]
                if field == "duplicate_removed" { receipt["removed_asset_ids"] = [asset.uuidString, asset.uuidString] }
                else { receipt[field] = field.hasSuffix("_ids") ? [UUID().uuidString] : UUID().uuidString }
                bad["gallery_remove"] = receipt
            }
            WireFixture.body = bad
            do { _ = try await client.removeGalleryAssets(op); check(false, "Mismatched wire receipt rejected: \(field)") } catch APIError.decoding {}
            check(WireFixture.requests.count == 1, "Mismatched receipt does not repeat mutation")
        }
        for kind in ["missing", "duplicate", "foreign", "bad-sha", "bad-bytes"] {
            WireFixture.reset(); var bad = response(removal: false)
            if kind == "missing" { bad.removeValue(forKey: "gallery_assets") }
            else {
                var assets = bad["gallery_assets"] as! [[String: Any]]
                if kind == "duplicate" { assets.append(assets[0]) }
                if kind == "foreign" { assets[0]["asset_id"] = UUID().uuidString }
                if kind == "bad-sha" { assets[0]["sha256"] = "not-a-digest" }
                if kind == "bad-bytes" { assets[0]["bytes"] = 0 }
                bad["gallery_assets"] = assets
            }
            WireFixture.body = bad
            do { _ = try await client.gallerySelection(serverID: listing, libraryOrgID: library); check(false, "Malformed descriptor projection rejected") } catch APIError.decoding {}
            check(WireFixture.requests[0].httpMethod == "GET", "Descriptor refusal stays read-only")
        }
        for stage in ["before", "after"] {
            for identity in ["actor", "library"] {
                WireFixture.reset(); WireFixture.body = response(removal: true)
                let change = { if identity == "actor" { AuthStore.shared.userID = UUID().uuidString } else { WorkspaceContext.selectedOrgID = UUID() } }
                if stage == "before" { AuthStore.beforeToken = change } else { WireFixture.beforeReply = change }
                do { _ = try await client.removeGalleryAssets(op); check(false, "Changed wire context must refuse") } catch CloudSyncError.identityChanged {}
                check(stage == "before" ? WireFixture.requests.isEmpty : WireFixture.requests.count == 1,
                      "Changed dispatch identity prevents PATCH; changed response identity cannot be adopted")
                AuthStore.beforeToken = nil; AuthStore.shared.userID = op.actorID.uuidString; WorkspaceContext.selectedOrgID = library
            }
        }
        print("PASS actual gallery removal wire: \(count) assertions; closed URLProtocol, no external network/UI")
    }
}
