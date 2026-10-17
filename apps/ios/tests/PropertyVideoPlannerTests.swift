import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
@MainActor final class ClosedPlanner: PropertyVideoPlanningAPI {
    var calls: [[PropertyVideoPlanPhoto]] = [], keys: [String] = []
    var afterCall: (() -> Void)?
    var missing = false, duplicate = false, wrongAsset = false, wrongOrg = false, reversed = false, fail = false
    var callToFail: Int? = nil
    var scenes: [String: (PropertyVideoScene, Double, PropertyVideoMotion)] = [:]
    func propertyVideoPlan(listingID: UUID, orgID: UUID, photos: [PropertyVideoPlanPhoto], idempotencyKey: String) async throws -> PropertyVideoPlanReply {
        calls.append(photos); keys.append(idempotencyKey)
        afterCall?()
        if fail || callToFail == calls.count { throw NSError(domain: "closed unavailable", code: 503) }
        var rows = photos.map { p -> PropertyVideoSceneRow in
            let value = scenes[p.photoID] ?? (.living, 0.99, .sideGlide)
            return PropertyVideoSceneRow(photoID: p.photoID, assetID: wrongAsset ? UUID() : p.assetID,
                scene: value.0, confidence: value.1, motion: value.2, seconds: 5)
        }
        if missing { rows.removeLast() }
        if duplicate && rows.count > 1 { rows[1] = rows[0] }
        if reversed { rows.reverse() }
        return .init(schema: 1, listingID: listingID, orgID: wrongOrg ? UUID() : orgID, photos: rows, model: "closed-fixture")
    }
}
@MainActor final class Scope {
    var current = true
    func requireCurrent() throws { if !current { throw CancellationError() } }
}
@MainActor final class AuthStore { static let shared = AuthStore(); var userID: String? = UUID().uuidString; var syncSessionRevision: UInt64 = 1 }
@MainActor final class AIConsent { static let shared = AIConsent(); var isGranted = true; var revocationRevision = 0 }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
enum CloudSyncError: Error { case identityChanged }
@MainActor final class ClosedWire {
    enum Idempotency { case key(String) }
    var response = Data(); var requests: [URLRequest] = []; var afterSend: (() -> Void)?
    let aiSession = URLSession.shared
    func url(_ parts: [String]) -> URL { URL(string: "https://closed.invalid/functions/v1/" + parts.joined(separator: "/"))! }
    func makeRequest(url: URL, method: String, json: [String:Any], idempotency: Idempotency) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method
        request.httpBody = try! JSONSerialization.data(withJSONObject: json)
        if case let .key(value) = idempotency { request.setValue(value, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }
    func execute(_ request: URLRequest, session: URLSession? = nil, beforeSend: (() throws -> Void)? = nil) async throws -> Data {
        try beforeSend?(); requests.append(request); afterSend?(); return response
    }
__ACTUAL_PLAN_WIRE__
}

@main struct PropertyVideoPlannerTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("property-video-planner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PropertyVideoPlanner.Context(ownerID: UUID(), orgID: UUID(), listingID: UUID()), scope = Scope()
        func input(_ n: Int) -> PropertyVideoPlanner.Input {
            .init(photoID: "photo-version-\(n)", assetID: UUID(), jpegDigest: PropertyVideoPlanner.digest(Data("exact JPEG fixture \(n)".utf8)))
        }
        let inputs = (0..<100).map(input), api = ClosedPlanner()
        api.scenes = Dictionary(uniqueKeysWithValues: inputs.enumerated().map { index, input in
            (input.photoID, (index % 2 == 0 ? PropertyVideoScene.rearExterior : .frontExterior, 0.95, .pullBack))
        })
        let result = try await PropertyVideoPlanner.plan(inputs: inputs, context: context, api: api, automaticOrder: true,
            documents: root, requireCurrent: { try scope.requireCurrent() })
        check(api.calls.count == 5 && api.calls.allSatisfy { $0.count == 20 }, "one hundred sources are classified in five bounded batches")
        check(result.photos.count == 100 && Set(result.photos.map { $0.input.photoID }) == Set(inputs.map(\.photoID)), "automatic planning retains every source exactly once")
        check(result.photos.prefix(50).allSatisfy { $0.scene == .frontExterior } && result.photos.suffix(50).allSatisfy { $0.scene == .rearExterior }, "global front-to-back order spans all classifier batches")
        check(result.photos.prefix(50).map { $0.input.photoID } == inputs.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.photoID }, "equal-scene original order remains stable across batches")
        let preserved = try PropertyVideoPlanner.preservingInputOrder(result.photos, inputs: inputs)
        check(preserved.map(\.input) == inputs, "new video plan retains exact upload order across every classified batch")
        check(preserved.enumerated().allSatisfy { index, photo in
            photo.motion == "pull_back" && photo.scene == (index % 2 == 0 ? .rearExterior : .frontExterior)
        }, "upload order retains each photo's own scene and automatic camera motion")
        for invalid in [Array(result.photos.dropLast()), [result.photos[0]] + Array(result.photos.dropLast())] {
            do { _ = try PropertyVideoPlanner.preservingInputOrder(invalid, inputs: inputs)
                check(false, "partial or duplicate classification cannot replace the selected photo set")
            } catch {}
        }
        let foreign = inputs.map { PropertyVideoPlanner.Input(photoID: $0.photoID, assetID: UUID(), jpegDigest: $0.jpegDigest) }
        do { _ = try PropertyVideoPlanner.preservingInputOrder(result.photos, inputs: foreign)
            check(false, "same photo labels cannot substitute different owned input assets")
        } catch {}
        let rebound = inputs.map { PropertyVideoPlanner.Input(photoID: $0.photoID, assetID: UUID(), jpegDigest: $0.jpegDigest) }
        let cached = try await PropertyVideoPlanner.plan(inputs: rebound, context: context, api: api, automaticOrder: false,
            documents: root, requireCurrent: { try scope.requireCurrent() })
        check(api.calls.count == 5 && cached.classifiedBatches == 0 && cached.photos.map(\.input) == rebound, "identical version bytes reuse classification but retain new exact owned inputs")
        check(cached.photos.map { $0.input.photoID } == inputs.map(\.photoID), "explicit original-order option leaves every selected photo in place")
        let changed = PropertyVideoPlanner.Input(photoID: inputs[0].photoID, assetID: UUID(), jpegDigest: PropertyVideoPlanner.digest(Data("different source bytes".utf8)))
        _ = try await PropertyVideoPlanner.plan(inputs: [changed], context: context, api: api, automaticOrder: true,
            documents: root, requireCurrent: { try scope.requireCurrent() })
        check(api.calls.count == 6, "changed JPEG bytes cannot reuse cached visual decisions")
        let moved = PropertyVideoPlanner.Context(ownerID: UUID(), orgID: context.orgID, listingID: context.listingID)
        _ = try await PropertyVideoPlanner.plan(inputs: [inputs[0]], context: moved, api: api, automaticOrder: true,
            documents: root, requireCurrent: { try scope.requireCurrent() })
        check(api.calls.count == 7, "another actor cannot reuse private scene decisions")
        let small = (101..<105).map(input), uncertain = ClosedPlanner()
        uncertain.scenes = [small[0].photoID: (.rearExterior, 0.95, .pullBack),
            small[1].photoID: (.frontExterior, 0.5, .flyThrough), small[2].photoID: (.frontExterior, 0.99, .sideGlide),
            small[3].photoID: (.unknown, 0.99, .flyThrough)]
        let held = try await PropertyVideoPlanner.plan(inputs: small, context: context, api: uncertain, automaticOrder: true,
            documents: root, requireCurrent: { try scope.requireCurrent() })
        check(held.photos.map { $0.input.photoID } == [small[2].photoID, small[1].photoID, small[0].photoID, small[3].photoID], "uncertain scenes preserve their original absolute positions")
        check(held.photos[1].motion == "push_in" && held.photos[3].motion == "push_in" && held.photos[1].caption == nil,
            "uncertain scenes get restrained v1 motion and no invented room captions")
        check(Set(held.photos.filter(\.confident).map(\.motion)).count == 2, "automatic motion differs by the actual classified photo")
        for issue in ["missing", "duplicate", "asset", "org", "reverse", "failure"] {
            let bad = ClosedPlanner()
            bad.missing = issue == "missing"; bad.duplicate = issue == "duplicate"; bad.wrongAsset = issue == "asset"
            bad.wrongOrg = issue == "org"; bad.reversed = issue == "reverse"; bad.fail = issue == "failure"
            let otherRoot = root.appendingPathComponent(issue)
            let fallback = try await PropertyVideoPlanner.plan(inputs: small, context: context, api: bad, automaticOrder: true,
                documents: otherRoot, requireCurrent: { try scope.requireCurrent() })
            check(fallback.usedFallback && fallback.photos.map(\.input) == small && bad.calls.count == 1,
                "invalid or unavailable batch falls back exactly once to complete original order")
            check(fallback.photos.map(\.motion) == ["push_in", "side_glide", "pull_back", "push_in"],
                "fallback rotates push_in, side_glide, pull_back by index instead of freezing every shot as push_in")
        }
        let failedLater = ClosedPlanner(); failedLater.callToFail = 2
        let later = try await PropertyVideoPlanner.plan(inputs: inputs, context: context, api: failedLater, automaticOrder: true,
            documents: root.appendingPathComponent("later"), requireCurrent: { try scope.requireCurrent() })
        check(later.usedFallback && later.photos.map(\.input) == inputs && failedLater.calls.count == 2,
            "a later batch failure never partially reorders or repeats paid planning")
        let rotation = ["push_in", "side_glide", "pull_back"]
        check(later.photos.enumerated().allSatisfy { $0.element.motion == rotation[$0.offset % rotation.count] }
            && !later.photos.contains { $0.motion == "fly_through" } && later.photos.allSatisfy { !$0.confident },
            "a whole-selection fallback keeps the deterministic rotation across every batch and never fly_through")
        let switched = ClosedPlanner(); switched.afterCall = { scope.current = false }
        do {
            _ = try await PropertyVideoPlanner.plan(inputs: small, context: context, api: switched, automaticOrder: true,
                documents: root.appendingPathComponent("switched"), requireCurrent: { try scope.requireCurrent() })
            check(false, "account revocation must stop before applying a plan")
        } catch is CancellationError {}
        check(switched.calls.count == 1, "stale response never starts a second planning batch")
        let wire = ClosedWire(); WorkspaceContext.selectedOrgID = context.orgID
        let wireInput = small.map { PropertyVideoPlanPhoto(photoID: $0.photoID, assetID: $0.assetID) }
        let wireReply = PropertyVideoPlanReply(schema: 1, listingID: context.listingID, orgID: context.orgID,
            photos: wireInput.map { .init(photoID: $0.photoID, assetID: $0.assetID, scene: .living, confidence: 0.9, motion: .sideGlide, seconds: 5) }, model: "closed")
        wire.response = try JSONEncoder().encode(wireReply)
        _ = try await wire.propertyVideoPlan(listingID: context.listingID, orgID: context.orgID, photos: wireInput, idempotencyKey: "property-video-plan:fixture")
        let request = wire.requests[0]
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
        let sent = body["photos"] as! [[String:String]]
        check(Set(body.keys) == Set(["listing_id", "expected_org_id", "photos"]) && sent.map { $0["photo_id"]! } == wireInput.map(\.photoID) && sent.allSatisfy { Set($0.keys) == Set(["photo_id", "asset_id"]) },
              "actual wire sends every exact private source reference without street, room claims or raw images")
        check(request.value(forHTTPHeaderField: "x-rendprop-ai-consent") == "property-video-plan-v1" && request.value(forHTTPHeaderField: "Idempotency-Key") == "property-video-plan:fixture", "actual wire carries current consent and stable planning operation")
        let sentCount = wire.requests.count; AIConsent.shared.isGranted = false
        do { _ = try await wire.propertyVideoPlan(listingID: context.listingID, orgID: context.orgID, photos: wireInput, idempotencyKey: "consent"); check(false, "revoked consent must stop planning dispatch") } catch {}
        check(wire.requests.count == sentCount, "revoked consent never reaches the planning boundary")
        AIConsent.shared.isGranted = true
        wire.afterSend = { AuthStore.shared.syncSessionRevision += 1 }
        do { _ = try await wire.propertyVideoPlan(listingID: context.listingID, orgID: context.orgID, photos: wireInput, idempotencyKey: "switch"); check(false, "stale wire reply must reject before returning scenes") } catch {}
        wire.afterSend = nil
        let decoder = JSONDecoder()
        let malformed = "{\"photo_id\":\"p\",\"asset_id\":\"\(UUID())\",\"scene\":\"invented_sunroom\",\"confidence\":1,\"motion\":\"fly_through\",\"seconds\":5}"
        do { _ = try decoder.decode(PropertyVideoSceneRow.self, from: Data(malformed.utf8)); check(false, "unknown scene must be rejected") } catch {}
        print("PASSED automatic hundred-photo batching/order, per-photo motion, exact cache identity, all-or-nothing replies and stale-scope refusal; closed provider/files only")
    }
}
