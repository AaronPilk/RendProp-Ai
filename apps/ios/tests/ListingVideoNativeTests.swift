import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum FileStore {
    static let documents = FileManager.default.temporaryDirectory.appendingPathComponent("listing-video-native-" + UUID().uuidString)
    static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}
@MainActor final class AuthStore { static let shared = AuthStore(); var userID: String? = UUID().uuidString; var syncSessionRevision: UInt64 = 1 }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
enum CloudSyncError: Error { case identityChanged, invalidResponse }
enum PublishError: Error { case listingMissing, inFlight, noShareURL }
enum AIImagePrep { static func error(_ message: String) -> Error { NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
enum SpaceType { case realEstate }
enum Status { case draft, ready }
struct Facts { var conflict: Bool?; var reviewRequired: Bool? }
struct Measurement { var pending: Bool? }
struct Listing {
    var id: UUID; var serverID: UUID?; var websiteVideo: ListingVideoRecord?
    var websiteVideoRelPath: String? { websiteVideo?.relativePath }
    var isSample = false; var cloudUnavailable: Bool?; var shareSlug: String?; var shareURL: String?
    var spaceType = SpaceType.realEstate; var needsServerSync: Bool?; var factsSync: Facts?; var measurementSync: Measurement?
    var lastError: String?; var unbrandedShareURL: String?; var publishedRenderID: UUID?; var lastRepublishedAt: Date?
    var status = Status.draft
}
@MainActor enum RealEstateRoleStore { static let current = Role(); struct Role { var isProducer = false } }
@MainActor enum PosterMaker {
    static var available = true
    static func makePoster(from: URL, listingID: UUID, identity: UUID? = nil) async -> URL? {
        guard available else { return nil }
        let file = FileStore.documents.appendingPathComponent("poster-\(listingID)-\(identity?.uuidString ?? "legacy").jpg")
        try? Data("Closed poster fixture".utf8).write(to: file); return file
    }
}
@MainActor final class UploadManager {
    struct State { var filePath: String }
    static let shared = UploadManager(); var state: State?
    var calls = 0; var posterCalls = 0; var afterUpload: (() -> Void)?; var metadata: UploadMetadata?
    func uploadPoster(fileURL: URL, listingID: UUID) async throws -> String { posterCalls += 1; return UUID().uuidString }
    func upload(fileURL: URL, listingID: UUID, listingLocalID: UUID?, role: String, metadata: UploadMetadata, cellularApproved: Bool) async throws -> String {
        check(role == "render", "publication uploads the chosen output as an owned render")
        calls += 1; self.metadata = metadata; state = State(filePath: "reels/" + fileURL.lastPathComponent)
        afterUpload?(); return UUID().uuidString
    }
}
@MainActor final class PushManager { static let shared = PushManager(); var notifications = 0; func noteTourPublished() { notifications += 1 } }
@MainActor final class ClosedAPI {
    var calls = 0; var records: [ListingVideoRecord] = []; var fail = false; var slug = "source-fixture"; var republishModes: [Bool] = []; var operationIDs: [UUID] = []; var posterIDs: [String?] = []; var assetIDs: [String] = []; var superseded = false
    func publishListingVideo(listingID: UUID, assetID: String, record: ListingVideoRecord, operationID: UUID, posterAssetID: String?, republish: Bool) async throws -> PublishedTour {
        calls += 1; records.append(record); republishModes.append(republish)
        operationIDs.append(operationID); posterIDs.append(posterAssetID); assetIDs.append(assetID)
        check(posterAssetID != nil, "a composition requires its own uploaded first-clip cover")
        if superseded { throw APIError.server(status: 409, code: "publication_superseded", message: "A newer selection is already published") }
        if fail { throw APIError.server(status: 503, code: "upstream", message: "Fixture connection stopped") }
        return PublishedTour(slug: slug, shareURL: "https://rendprop.com/f/" + slug, renderID: UUID())
    }
}
@MainActor final class PublisherFixture {
    var listings: [Listing]; var publishInFlight = Set<UUID>(); var pendingPublish: [UUID] = []
    struct UploadedRenderAsset { var relPath: String; var assetID: String }
    var uploadedRenderAssets: [UUID: UploadedRenderAsset] = [:]
    var gallerySyncInFlight = Set<UUID>(), gallerySyncPending = Set<UUID>()
    var api = ClosedAPI(); var syncs = 0; var currentLibraryAllowed = true
    init(_ listing: Listing) { listings = [listing] }
    func index(of id: UUID) -> Int? { listings.firstIndex { $0.id == id } }
    func isInSelectedWorkspace(_ listing: Listing) -> Bool { currentLibraryAllowed }
    static func userMessage(for error: Error) -> String { error.localizedDescription }
    func setLastError(_ message: String?, for id: UUID) { if let i = index(of: id) { listings[i].lastError = message } }
    func syncClientContactBeforePublish(_ id: UUID, requireClient: Bool) async throws {}
    func syncListing(_ id: UUID) async { syncs += 1 }
    func syncGalleryPhotos(listingLocalID: UUID, listingServerID: UUID) async { syncs += 1 }
__ACTUAL_MODEL_METHODS__
    func publish(_ id: UUID) async throws -> URL { try await publishSelectedWebsiteVideo(listingID: id) }
}

@main struct ListingVideoNativeTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default, root = FileStore.documents
        try fm.createDirectory(at: root.appendingPathComponent("reels"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let listingID = UUID(), serverID = UUID(), owner = AuthStore.shared.userID!, workspace = WorkspaceContext.selectedOrgID!
        func makeRecord(_ suffix: String = UUID().uuidString, purpose: VideoAspectChoice = .listing,
                        sources: [ListingVideoSource]? = nil) throws -> ListingVideoRecord {
            let output = root.appendingPathComponent("reels/\(listingID.uuidString)-\(suffix).mp4")
            let content = Data(("Synthetic file identity " + suffix).utf8); try content.write(to: output)
            let source = ListingVideoSource(photoVersionID: "version-one", photoAssetID: UUID().uuidString,
                generationRequestID: "generation-one", generationProvenanceID: UUID().uuidString, sourceBound: true)
            let record = ListingVideoRecord(id: UUID(), listingID: listingID, ownerID: owner, workspaceID: workspace,
                serverListingID: serverID, relativePath: "reels/" + output.lastPathComponent, purpose: purpose,
                width: purpose.width, height: purpose.height, durationS: 15, bytes: Int64(content.count),
                sha256: try ListingVideoStore.digest(output), sources: sources ?? [source], includesOpeningClip: false, createdAt: Date(), brandingPolicy: "unbranded")
            try ListingVideoStore.save(record, documents: root); return record
        }
        let record = try makeRecord()
        check(record.canSelectForWebsite, "verified landscape video is selectable")
        var unknownBranding = record; unknownBranding.brandingPolicy = nil
        check(!unknownBranding.canSelectForWebsite, "historical unknown-brand masters are not represented as MLS-safe")
        check(VideoBrandingPolicy.titleCard("Agent or Rendprop mark", aspect: "16:9") == nil &&
              VideoBrandingPolicy.titleCard("Social mark", aspect: "9:16") == "Social mark", "listing composition removes a recovered brand while social settings keep it")
        check(!(try makeRecord(purpose: .socialMedia)).canSelectForWebsite, "social portrait is not substituted for a website landscape video")
        check(!(try makeRecord(sources: [])).canSelectForWebsite, "legacy absent lineage is not silently classified as a verified composition")
        let local = ListingVideoSource(photoVersionID: "enhanced-version", photoAssetID: UUID().uuidString, motionKind: "original_photo")
        check(local.isComplete, "original photo motion requires no successful AI generation")
        var fallbackContext = local
        fallbackContext.generationRequestID = "rejected-job"; fallbackContext.generationProvenanceID = UUID().uuidString
        fallbackContext.sourceBound = false
        let sentFallback = ListingVideoComposition(sources: [fallbackContext]).sources[0]
        check(sentFallback.generationRequestID == nil && sentFallback.generationProvenanceID == nil &&
              fallbackContext.generationRequestID == "rejected-job", "unbound AI is retained locally but does not block an original-photo composition")
        check(!(try makeRecord(sources: [ListingVideoSource(photoVersionID: "missing-private-source", generationRequestID: "job", generationProvenanceID: UUID().uuidString)])).canSelectForWebsite,
              "local labels never authorize an unregistered source photo")
        let listing = Listing(id: listingID, serverID: serverID)
        var model = PublisherFixture(listing)
        try await model.selectWebsiteVideo(record, for: listingID, onlyIfUnselected: true)
        check(model.listings[0].websiteVideo == record && model.api.calls == 0 && UploadManager.shared.calls == 0,
              "selecting a reviewed output remains local and performs no publication or upload")
        check(ListingVideoStore.selected(listingID: listingID, documents: root) == record, "selected output pin survives a fresh read")
        check(try ListingVideoStore.validate(record, documents: root, listingID: listingID, ownerID: owner, workspaceID: workspace, serverListingID: serverID) == root.appendingPathComponent(record.relativePath), "exact output metadata and hash survive reload")
        do { _ = try ListingVideoStore.validate(record, documents: root, listingID: listingID, ownerID: UUID().uuidString, workspaceID: workspace, serverListingID: serverID); check(false, "foreign owner must refuse") } catch {}
        do { _ = try ListingVideoStore.validate(record, documents: root, listingID: listingID, ownerID: owner, workspaceID: UUID(), serverListingID: serverID); check(false, "foreign library must refuse") } catch {}
        let url = try ListingVideoStore.fileURL(record, documents: root)
        let original = try Data(contentsOf: url)
        try Data(repeating: 0, count: original.count).write(to: url)
        do { _ = try ListingVideoStore.validate(record, documents: root, listingID: listingID, ownerID: owner, workspaceID: workspace, serverListingID: serverID); check(false, "changed bytes must refuse before upload") } catch {}
        try original.write(to: url)
        model.api.fail = true
        do { _ = try await model.publish(listingID); check(false, "connection loss must preserve the publication") } catch {}
        check(try ListingVideoStore.pending(listingID: listingID, documents: root) == record && model.pendingPublish == [listingID], "failed publication retains exact source and retry intent")
        let other = try makeRecord()
        do { try await model.selectWebsiteVideo(other, for: listingID); check(false, "pending publication must keep its source") } catch {}
        let saved = try ListingVideoStore.publication(listingID: listingID, documents: root)!
        let uploads = UploadManager.shared.calls, posterUploads = UploadManager.shared.posterCalls
        let closedAPI = model.api
        model = PublisherFixture(model.listings[0]); model.api = closedAPI // Relaunch: memory caches and pending array are gone.
        model.api.fail = false
        _ = try await model.publish(listingID)
        check(model.api.operationIDs.suffix(2).allSatisfy { $0 == saved.operationID }, "lost reply and relaunch preserve one publication operation")
        check(UploadManager.shared.posterCalls == posterUploads && model.api.posterIDs.suffix(2).allSatisfy { $0 == saved.posterAssetID }, "lost reply reuses the immutable first-clip cover")
        check(UploadManager.shared.calls == uploads, "lost publication reply retries reuse the exact uploaded output")
        check(model.api.records.allSatisfy { $0.id == record.id } && model.listings[0].websiteVideo?.id == record.id, "retry cannot switch to a recorded walkthrough or another completed video")
        check(try ListingVideoStore.pending(listingID: listingID, documents: root) == nil && model.pendingPublish.isEmpty, "confirmed publication retires only its matching intent")
        try await model.selectWebsiteVideo(other, for: listingID, onlyIfUnselected: true)
        check(model.listings[0].websiteVideo?.id == record.id, "a later completed video never replaces the agent's chosen presentation")
        check(UploadManager.shared.metadata?.width == 1920 && UploadManager.shared.metadata?.height == 1080 && UploadManager.shared.metadata?.sha256 == record.sha256, "actual selected output identity reaches upload metadata")
        _ = try await model.publish(listingID)
        check(model.api.republishModes.last == true && model.listings[0].shareSlug == "source-fixture", "republish preserves the established public link")
        let firstExplicitOperation = model.api.operationIDs.last!
        try await model.selectWebsiteVideo(other, for: listingID)
        _ = try await model.publish(listingID)
        let secondExplicitOperation = model.api.operationIDs.last!
        try await model.selectWebsiteVideo(record, for: listingID)
        _ = try await model.publish(listingID)
        check(model.api.assetIDs.first == model.api.assetIDs.last && model.api.posterIDs.first! == model.api.posterIDs.last!, "reselecting an immutable output retains its original master and cover asset identities")
        check(Set([firstExplicitOperation, secondExplicitOperation, model.api.operationIDs.last!]).count == 3 && model.api.records.suffix(2).map(\.id) == [other.id, record.id], "explicit A to B to A reselection uses fresh operations and exact chosen outputs")
        model.api.superseded = true
        do { _ = try await model.publish(listingID); check(false, "superseded publication must not appear successful") } catch {}
        check(try ListingVideoStore.publication(listingID: listingID, documents: root) == nil && model.pendingPublish.isEmpty && model.listings[0].websiteVideo?.id == record.id,
              "superseded operation retires its retry without deleting the local video choice")
        model.api.superseded = false
        let coverMissingRecord = try makeRecord(); try await model.selectWebsiteVideo(coverMissingRecord, for: listingID)
        PosterMaker.available = false
        let posterFailureCalls = model.api.calls, posterFailureUploads = UploadManager.shared.calls
        do { _ = try await model.publish(listingID); check(false, "missing cover must refuse before uploading the output") } catch {}
        check(model.api.calls == posterFailureCalls && UploadManager.shared.calls == posterFailureUploads,
              "missing first-clip cover cannot dispatch a composition or upload its master")
        PosterMaker.available = true
        let pendingCover = try ListingVideoStore.publication(listingID: listingID, documents: root)!
        try ListingVideoStore.finishPublication(coverMissingRecord, operationID: pendingCover.operationID, documents: root)
        model.pendingPublish = []
        let fresh = try makeRecord(); try await model.selectWebsiteVideo(fresh, for: listingID)
        let afterCalls = model.api.calls
        UploadManager.shared.afterUpload = { AuthStore.shared.syncSessionRevision += 1 }
        do { _ = try await model.publish(listingID); check(false, "account switch after upload must stop publication") } catch {}
        check(model.api.calls == afterCalls, "late upload cannot publish after an account change")
        UploadManager.shared.afterUpload = nil
        print("PASSED actual source storage, choice, publication/retry and identity fences; no provider/UI/network")
    }
}
