import Foundation
import Combine
__PAGE__
__ERROR__
__CONTEXT__
enum CloudListingMerge {
__VALIDATE__
__DATE__
__MEDIA_KEY__
}
__LOADER__
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String?
    var syncSessionRevision: UInt64 = 1
    var isIdentified = true
}
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? }
protocol WorkspaceSyncAPI {
    @MainActor func cloudMedia(listingID: UUID, orgID: UUID, offset: Int) async throws -> CloudMediaPage
}
struct Listing {
    var id = UUID()
    var isSample = false
    var cloudUnavailable: Bool?
    var serverID: UUID?
    var serverOrgID: UUID?
}
@MainActor final class ClosedAPI: WorkspaceSyncAPI {
    var requests: [(UUID, UUID, Int)] = []
    var reply: (Int) async throws -> CloudMediaPage = { _ in throw CloudSyncError.invalidResponse }
    func cloudMedia(listingID: UUID, orgID: UUID, offset: Int) async throws -> CloudMediaPage {
        requests.append((listingID, orgID, offset)); return try await reply(offset)
    }
}
@MainActor final class Model {
    var listings: [Listing]
    let api = ClosedAPI()
    var membership = true
    init(_ listing: Listing) { listings = [listing] }
    func isInSelectedWorkspace(_ listing: Listing) -> Bool { membership }
}
@MainActor final class PreviewHost {
    let listing: Listing
    let model: Model
    let auth = AuthStore.shared
    let loader = CloudPhotoPreviewLoader()
    init(_ listing: Listing) { self.listing = listing; model = Model(listing) }
__SCOPE__
__VISIBLE__
__LOAD__
__ACCESSIBILITY__
    var shown: [CloudMediaPage.Photo] { visiblePhotos }
    func spoken(_ photo: CloudMediaPage.Photo, ordinal: Int) -> String { photoAccessibilityLabel(photo, ordinal: ordinal) }
    func refresh(force: Bool = false) async { await load(force: force) }
}
@MainActor final class HeldBoundary {
    var arrivals = 0
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async { arrivals += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { let waiting = continuation; continuation = nil; waiting?.resume() }
}
struct Failure: Error { let message: String }
@main struct CloudPhotoPreviewChecks {
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        var checks = 0
        func check(_ good: Bool, _ label: String) throws { if !good { throw Failure(message: label) }; checks += 1 }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() { if Date() > deadline { throw Failure(message: "Closed async boundary did not arrive") }; await Task.yield() }
        }
        let actor = UUID(), org = UUID(), server = UUID()
        let listing = Listing(serverID: server, serverOrgID: org)
        func reset() { AuthStore.shared.userID = actor.uuidString; AuthStore.shared.syncSessionRevision = 1; AuthStore.shared.isIdentified = true; WorkspaceContext.selectedOrgID = org }
        func host() -> PreviewHost { reset(); return PreviewHost(listing) }
        func photo(id: UUID = UUID(), listingID: UUID? = nil, actorID: UUID? = nil) throws -> CloudMediaPage.Photo {
            let expires = Date().addingTimeInterval(500)
            let key = "renders/\(org.uuidString.lowercased())/\(server.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
            let payload: [String: Any] = ["v":1, "actor":(actorID ?? actor).uuidString.lowercased(), "org":org.uuidString.lowercased(), "listing":server.uuidString.lowercased(), "bucket":"renders", "key":key, "exp":Int(expires.timeIntervalSince1970)]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let url = URL(string: "https://rendprop.com/private-media/" + encoded + "." + String(repeating: "a", count: 64))!
            return .init(id: id, listing_id: listingID ?? server, url: url, expires_at: ISO8601DateFormatter().string(from: expires), caption: "Fictional cloud copy", is_staged: false, is_altered: true, original_url: nil)
        }
        func page(_ photos: [CloudMediaPage.Photo], next: Int? = nil) -> CloudMediaPage {
            .init(org_id: org, listing_id: server, photos: photos, videos: [], next_offset: next, unavailable_count: 0)
        }
        let copies = try [photo(), photo()]
        let accessibility = host()
        let firstLabel = accessibility.spoken(copies[0], ordinal: 1), secondLabel = accessibility.spoken(copies[1], ordinal: 2)
        try check(firstLabel != secondLabel && firstLabel.contains("Cloud photo 1") && secondLabel.contains("Cloud photo 2"), "Cloud previews have unique spoken ordinal labels")
        try check(firstLabel.contains("Altered image") && firstLabel.contains("Original and edit history unavailable"), "Spoken labels preserve altered-copy and unavailable-original states")
        let staged = CloudMediaPage.Photo(id: UUID(), listing_id: server, url: copies[0].url, expires_at: copies[0].expires_at, caption: nil, is_staged: true, is_altered: true, original_url: nil)
        try check(accessibility.spoken(staged, ordinal: 3).contains("Virtually staged"), "Spoken preview identifies virtual staging")
        let h = host(); h.model.api.reply = { _ in page(copies) }
        await h.refresh()
        try check(h.shown.count == 2 && h.loader.hasMore == false, "Two published copies appear without local originals")
        try check(h.shown.allSatisfy { $0.is_altered == true && $0.original_url == nil }, "Preview preserves missing-original provenance")
        try check(h.model.api.requests.count == 1 && h.model.api.requests[0].0 == server && h.model.api.requests[0].1 == org, "Metadata fetch uses exact listing and organization")
        await h.refresh()
        try check(h.model.api.requests.count == 1, "Completed same-scope preview does not refetch")
        await h.refresh(force: true)
        try check(h.model.api.requests.count == 2, "Explicit retry obtains fresh private metadata")
        AuthStore.shared.userID = UUID().uuidString
        try check(h.shown.isEmpty, "Account change immediately hides prior preview URLs")

        for mutation in 0..<6 {
            let v = host(), boundary = HeldBoundary()
            v.model.api.reply = { _ in await boundary.hold(); return page(copies) }
            let task = Task { await v.refresh() }
            try await wait { boundary.arrivals == 1 }
            switch mutation {
            case 0: AuthStore.shared.userID = UUID().uuidString
            case 1: AuthStore.shared.syncSessionRevision += 1
            case 2: WorkspaceContext.selectedOrgID = UUID()
            case 3: v.model.listings[0].serverID = UUID()
            case 4: v.model.listings[0].cloudUnavailable = true
            default: v.model.membership = false
            }
            boundary.release(); await task.value
            try check(v.loader.photos.isEmpty && v.shown.isEmpty, "Changed context cannot retain late private previews")
        }
        let inflight = host(), boundary = HeldBoundary()
        inflight.model.api.reply = { _ in if boundary.arrivals == 0 { await boundary.hold() }; return page(copies) }
        let pending = Task { await inflight.refresh() }
        try await wait { boundary.arrivals == 1 }
        await inflight.refresh(force: true)
        try check(inflight.model.api.requests.count == 1, "Same-scope in-flight metadata fetch is coalesced")
        boundary.release(); await pending.value
        try check(inflight.shown.count == 2, "Coalesced fetch still publishes the available previews")

        let six = host(); let many = try (0..<6).map { _ in try photo() }
        six.model.api.reply = { offset in offset == 0 ? page(many, next: 50) : page([]) }
        await six.refresh()
        try check(six.model.api.requests.count == 1 && six.loader.hasMore && six.shown.count == 6, "Six previews stop further automatic metadata reads")
        let progressive = host(), second = HeldBoundary()
        progressive.model.api.reply = { offset in if offset == 0 { return page([copies[0]], next: 50) }; await second.hold(); return page([copies[1]]) }
        let painting = Task { await progressive.refresh() }
        try await wait { second.arrivals == 1 }
        try check(progressive.shown.count == 1 && progressive.loader.loading && progressive.loader.hasMore, "First validated page is visible before a later page finishes")
        second.release(); await painting.value
        try check(progressive.shown.count == 2 && !progressive.loader.hasMore, "Completed metadata yields an exact available photo count")

        let superseded = host(), oldReply = HeldBoundary()
        superseded.model.api.reply = { _ in await oldReply.hold(); return page(copies) }
        let oldTask = Task { await superseded.refresh() }
        try await wait { oldReply.arrivals == 1 }
        let newActor = UUID(); AuthStore.shared.userID = newActor.uuidString
        let newCopy = try photo(actorID: newActor)
        superseded.model.api.reply = { _ in page([newCopy]) }
        await superseded.refresh()
        oldReply.release(); await oldTask.value
        try check(superseded.shown.map(\.id) == [newCopy.id] && superseded.loader.error == nil, "Late old generation cannot erase the current account preview")

        let bounded = host(); bounded.model.api.reply = { offset in page([], next: offset + 50) }
        await bounded.refresh()
        try check(bounded.model.api.requests.count == 4 && bounded.loader.hasMore && bounded.shown.isEmpty, "Metadata pagination stops at four pages")
        let foreign = host(); let foreignPhoto = try photo(listingID: UUID())
        foreign.model.api.reply = { _ in page([foreignPhoto]) }
        await foreign.refresh()
        try check(foreign.shown.isEmpty && foreign.loader.error != nil, "Foreign listing response is not previewed")
        let wrongActor = host(); let foreignActorPhoto = try photo(actorID: UUID())
        wrongActor.model.api.reply = { _ in page([foreignActorPhoto]) }
        await wrongActor.refresh()
        try check(wrongActor.shown.isEmpty && wrongActor.loader.error != nil, "Foreign actor private link is not previewed")
        let duplicate = host(); duplicate.model.api.reply = { offset in page([copies[0]], next: offset == 0 ? 50 : nil) }
        await duplicate.refresh()
        try check(duplicate.shown.count == 1 && duplicate.loader.error != nil && duplicate.loader.hasMore, "Duplicate later page keeps only previously validated previews")
        let offline = host(); offline.model.api.reply = { _ in throw URLError(.notConnectedToInternet) }
        await offline.refresh()
        try check(offline.shown.isEmpty && offline.loader.error != nil, "Offline metadata failure offers recovery without local writes")
        offline.model.api.reply = { _ in page(copies) }; await offline.refresh(force: true)
        try check(offline.shown.count == 2, "Explicit retry recovers from metadata failure")
        let cancelled = host(), cancelBoundary = HeldBoundary()
        cancelled.model.api.reply = { _ in await cancelBoundary.hold(); return page(copies) }
        let cancellation = Task { await cancelled.refresh() }
        try await wait { cancelBoundary.arrivals == 1 }; cancellation.cancel(); cancelBoundary.release(); await cancellation.value
        try check(cancelled.shown.isEmpty && !cancelled.loader.loading && cancelled.loader.error == nil, "Cancelled preview does not publish a late result or warning")
        reset()
        print("PASS \(checks) assertions")
    }
}
