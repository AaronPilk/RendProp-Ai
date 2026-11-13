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
    var refreshCount = 0
    func forceRefresh() async -> Bool { refreshCount += 1; return true }
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
final class SelectionWireProtocol: URLProtocol {
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
final class SelectionWireClient {
    let base = URL(string: "https://closed.fixture.invalid/functions/v1")!
    let session: URLSession
    init() { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SelectionWireProtocol.self]; session = URLSession(configuration: config) }
    // __ACTUAL_METHODS__
}
@main struct SelectionWireChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool,_ message:String) {
            guard value else { fputs("FAIL: \(message)\n",stderr);exit(1) };count += 1
        }
        let client = SelectionWireClient(), library = WorkspaceContext.selectedOrgID!, listing = UUID(), physical = UUID(), asset = UUID()
        let identity = PhotoCloudSelectionIdentity(actorID: AuthStore.fixtureActor, libraryOrgID: library,localListingID:UUID(),serverListingID:listing)
        let intent = PhotoCloudSelectionRequest(familyAssetIDs:[asset],target:nil,
            expectedSelection:.init(galleryAssetIDs:[asset],mainPhotoKey:nil),followFamilyCover:false,reviewed:false)
        let operation = PhotoCloudSelectionOperation(operationID:UUID(),identity:identity,physicalOrgID:physical,
            familyID:"a",versionID:"a",imageFile:"enh-a.jpg",sha256:String(repeating:"a",count:64),bytes:100,request:intent)
        func response(receipt:Bool) throws -> [String:Any] {
            var body: [String:Any] = ["schema":1,"actor_id":identity.actorID.uuidString,"org_id":physical.uuidString,
                "library_org_id":library.uuidString,"listing_id":listing.uuidString,"gallery_asset_ids":[],
                "main_photo_key":NSNull(),"effective_asset_ids":[],"gallery_assets":[],"operation":NSNull(),"operation_status":NSNull(),"abandoned_operation":NSNull()]
            if receipt {
                let accepted = PhotoCloudSelectionSnapshot.Receipt(operationID:operation.operationID,request:intent,
                    result:.init(galleryAssetIDs:[],mainPhotoKey:nil))
                body["operation"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(accepted))
                body["ok"] = true;body["replayed"] = false;body["operation_status"] = "accepted"
            }
            return body
        }
        WireFixture.body = try response(receipt:false)
        _ = try await client.photoCloudSelection(identity:identity,physicalOrgID:physical,operationID:nil)
        var wire = WireFixture.requests[0]
        check(wire.httpMethod == "GET" && wire.url?.path == "/functions/v1/listings/\(listing.uuidString.lowercased())/photo-selection","Exact new read route")
        check(wire.value(forHTTPHeaderField:"X-Org-Id") == library.uuidString.lowercased(),"Logical library header is explicit")
        check(wire.value(forHTTPHeaderField:"Idempotency-Key") == nil,"Read has no write key")
        WireFixture.reset();WireFixture.body = try response(receipt:true)
        _ = try await client.changePhotoCloudSelection(operation)
        wire = WireFixture.requests[0]
        check(wire.httpMethod == "PATCH" && wire.url?.path.hasSuffix("/photo-selection") == true,"Explicit mutation has dedicated route")
        check(wire.value(forHTTPHeaderField:"Idempotency-Key") == "photo-selection:" + operation.operationID.uuidString.lowercased(),"Stable journal operation header")
        let body = try JSONSerialization.jsonObject(with:wire.httpBody!) as! [String:Any]
        check(Set(body.keys) == ["operation_id","family_asset_ids","target","expected_selection","follow_family_cover","reviewed"],"Closed five-key intent plus operation ID")
        check(body["target"] is NSNull && (body["expected_selection"] as? [String:Any])?["main_photo_key"] is NSNull,"Wire preserves explicit null removal and cover CAS")
        check(WireFixture.requests.count == 1,"Acknowledged mutation dispatched once")
        WireFixture.reset();WireFixture.status = 401;WireFixture.body = ["error":"expired","code":"unauthorized"]
        let beforeRefresh = AuthStore.shared.refreshCount
        do { _ = try await client.changePhotoCloudSelection(operation);check(false,"401 must be surfaced") } catch {}
        check(WireFixture.requests.count == 1 && AuthStore.shared.refreshCount == beforeRefresh,"Selection401 must not refresh and resend PATCH")
        WireFixture.reset();WireFixture.body = try response(receipt:true);WireFixture.loseReply = true
        do { _ = try await client.changePhotoCloudSelection(operation);check(false,"Lost reply must surface") } catch {}
        check(WireFixture.requests.count == 1,"Lost reply does not automatically repost")
        WireFixture.reset();WireFixture.body = try response(receipt:true)
        _ = try await client.photoCloudSelection(identity:identity,physicalOrgID:physical,operationID:operation.operationID)
        wire = WireFixture.requests[0]
        check(wire.httpMethod == "GET" && URLComponents(url:wire.url!,resolvingAgainstBaseURL:false)?.queryItems == [URLQueryItem(name:"operation_id",value:operation.operationID.uuidString.lowercased())],"Recovery reads exact operation UUID")
        for field in ["actor_id","org_id","library_org_id","listing_id","missing-gallery","missing-cover","missing-operation","missing-status","missing-abandoned"] {
            WireFixture.reset();var bad = try response(receipt:true)
            if field.hasPrefix("missing-") {
                bad.removeValue(forKey:field == "missing-gallery" ? "gallery_asset_ids" : field == "missing-cover" ? "main_photo_key" : field == "missing-status" ? "operation_status" : field == "missing-abandoned" ? "abandoned_operation" : "operation")
            } else { bad[field] = UUID().uuidString }
            WireFixture.body = bad
            do { _ = try await client.changePhotoCloudSelection(operation);check(false,"Reject wrong scope or missing explicit fields: \(field)") } catch {}
            check(WireFixture.requests.count == 1,"Malformed reply never replays mutation")
        }
        WireFixture.reset();WireFixture.body = try response(receipt:true)
        AuthStore.beforeToken = { WorkspaceContext.selectedOrgID = UUID() }
        do { _ = try await client.changePhotoCloudSelection(operation);check(false,"Workspace change must refuse") } catch {}
        AuthStore.beforeToken = nil;WorkspaceContext.selectedOrgID = library
        check(WireFixture.requests.isEmpty,"Workspace switch before dispatch sends zero PATCHes")
        WireFixture.reset();WireFixture.status = 401;WireFixture.body = ["error":"expired"]
        let oldReadRefresh = AuthStore.shared.refreshCount
        do { _ = try await client.photoCloudSelection(identity:identity,physicalOrgID:physical,operationID:nil) } catch {}
        check(WireFixture.requests.count == 2 && AuthStore.shared.refreshCount == oldReadRefresh + 1,"Unrelated GET retains existing one-auth-retry behavior")
        // Reset auth after the existing read-retry contract's terminal401.
        AuthStore.shared.isSignedIn = true;AuthStore.shared.isIdentified = true
        WireFixture.reset();WireFixture.body = try response(receipt:true);WireFixture.body["abandoned"] = false
        _ = try await client.abandonPhotoCloudSelection(operation)
        wire = WireFixture.requests[0]
        check(wire.httpMethod == "POST" && wire.url?.path == "/functions/v1/listings/\(listing.uuidString.lowercased())/photo-selection/abandon","Abandon has exact dedicated POST route")
        check(wire.value(forHTTPHeaderField:"Idempotency-Key") == "photo-selection:"+operation.operationID.uuidString.lowercased(),"Abandon retains exact saved operation key")
        let closedBody = try JSONSerialization.jsonObject(with:wire.httpBody!) as! NSDictionary
        check(closedBody == (try operation.request.body(operationID:operation.operationID)) as NSDictionary,"Abandon sends exact immutable request; no selection replay")
        check(WireFixture.requests.count == 1,"Abandon accepted-wins reply needs one POST")
        WireFixture.reset();WireFixture.status = 401;WireFixture.body = ["error":"expired"]
        let beforeAbandonAuth = AuthStore.shared.refreshCount
        do { _ = try await client.abandonPhotoCloudSelection(operation);check(false,"Abandon401 must surface") } catch {}
        check(WireFixture.requests.count == 1 && AuthStore.shared.refreshCount == beforeAbandonAuth,"Abandon401 cannot refresh and resend POST")
        WireFixture.reset();WireFixture.body = try response(receipt:true);WireFixture.body["abandoned"] = false;WireFixture.loseReply = true
        do { _ = try await client.abandonPhotoCloudSelection(operation);check(false,"Lost abandon reply must surface") } catch {}
        check(WireFixture.requests.count == 1,"Lost abandon reply never reposts")
        print("\(count) assertions PASS")
    }
}
