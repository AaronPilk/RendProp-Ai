import Foundation
import CryptoKit

// Actual APIError and streaming SHA are inserted by the source-bound runner.
// __ACTUAL_ERROR__
enum DirectUploader { // __ACTUAL_FILE_SHA__
}
enum CloudSyncError: Error { case identityChanged }
enum FileStore {
    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
actor CloudPhotoReferences {
    enum Failure: Error { case changedBytes }
    static let shared = CloudPhotoReferences()
    private var known: [String: UUID] = [:]
    private var changeOnSave = false
    func mutateBeforeSaving() { changeOnSave = true }
    func galleryAssetID(fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID,
                        physicalOrgID: UUID? = nil) -> UUID? { known[fileURL.path] }
    func saveGalleryAssetID(assetID: UUID, fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID,
                            physicalOrgID: UUID? = nil,
                            expectedSHA256: String? = nil, expectedBytes: Int64? = nil) throws {
        if changeOnSave {
            var bytes = try Data(contentsOf: fileURL); bytes[0] ^= 1; try bytes.write(to: fileURL)
            changeOnSave = false
        }
        // Closed persistence boundary mirrors the real setter's expected-byte
        // comparison. Actual CloudPhotoReferences has its own separate proof.
        guard let expectedSHA256, let expectedBytes else { return }
        guard DirectUploader.sha256(of: fileURL) == expectedSHA256,
              FileStore.fileSize(fileURL) == expectedBytes else { throw Failure.changedBytes }
        known[fileURL.path] = assetID
    }
}
@MainActor final class CoordinatorAPI: ListingGalleryRemovalAPI {
    enum Lost: Error { case reply }
    var snapshot: PhotoGallerySelection
    var snapshots = 0
    var operations: [PhotoGalleryRemovalOperation] = []
    var afterSnapshot: (() -> Void)?
    var afterRemoval: (() -> Void)?
    var failure: Error?
    var alter: ((PhotoGalleryRemovalReply) -> PhotoGalleryRemovalReply)?
    init(_ snapshot: PhotoGallerySelection) { self.snapshot = snapshot }
    func gallerySelection(serverID: UUID, libraryOrgID: UUID) async throws -> PhotoGallerySelection {
        snapshots += 1; afterSnapshot?(); return snapshot
    }
    func removeGalleryAssets(_ operation: PhotoGalleryRemovalOperation) async throws -> PhotoGalleryRemovalReply {
        operations.append(operation); afterRemoval?()
        if let failure { throw failure }
        let result = PhotoGalleryRemovalReply(selection: .init(listingID: snapshot.listingID,
            orgID: snapshot.orgID, libraryOrgID: snapshot.libraryOrgID,
            galleryAssetIDs: (snapshot.galleryAssetIDs ?? []).filter { !operation.requestedAssetIDs.contains($0) }, mainPhotoKey: nil),
            operationID: operation.operationID, replayed: operations.count > 1,
            requestedAssetIDs: operation.requestedAssetIDs, removedAssetIDs: operation.requestedAssetIDs)
        return alter?(result) ?? result
    }
}
@main struct RemovalCoordinatorChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ result: Bool, _ reason: String) {
            guard result else { fputs("FAIL: \(reason)\n", stderr); exit(1) }; count += 1
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Fixture {
            let directory: URL; let local: UUID; let server: UUID; let actor: UUID; let library: UUID; let asset: UUID
            let store: PhotoListingRemovalJournal; let references: CloudPhotoReferences; let api: CoordinatorAPI
            var scope: PhotoListingRemovalJournal.Scope { .init(actorID: actor, libraryOrgID: library,
                localListingID: local, serverListingID: server, familyID: "capture") }
        }
        func fixture() throws -> Fixture {
            let directory = root.appendingPathComponent(UUID().uuidString), local = UUID(), server = UUID(), actor = UUID(), library = UUID(), asset = UUID()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PhotoVersionHistory.saveCapture(original: Data("actual-retained-original".utf8), enhanced: Data("polished-capture".utf8), id: "capture", directory: directory)
            _ = try PhotoVersionHistory.ensureOriginalSources(directory: directory)
            try PhotoVersionHistory.selectForPublication(id: "capture-original", directory: directory)
            let file = directory.appendingPathComponent("orig-capture.jpg")
            let api = CoordinatorAPI(.init(listingID: server, orgID: library, libraryOrgID: library,
                galleryAssetIDs: [asset], mainPhotoKey: "renders/org/listing/gallery.jpg",
                galleryAssets: [.init(assetID: asset, sha256: DirectUploader.sha256(of: file)!, bytes: FileStore.fileSize(file))]))
            return .init(directory: directory, local: local, server: server, actor: actor, library: library, asset: asset,
                store: PhotoListingRemovalJournal(directory: directory), references: CloudPhotoReferences(), api: api)
        }
        func remove(_ f: Fixture, identity: @escaping () throws -> Void = {}) async throws -> PhotoListingRemovalCoordinator.Confirmed {
            try await PhotoListingRemovalCoordinator.remove(versionID: "capture-original", directory: f.directory,
                localListingID: f.local, serverListingID: f.server, actorID: f.actor, libraryOrgID: f.library,
                api: f.api, requireIdentity: identity, store: f.store, references: f.references)
        }
        func history(_ f: Fixture) throws -> Data { try Data(contentsOf: f.directory.appendingPathComponent(".photo-history.json")) }
        do {
            let f = try fixture(), before = try history(f)
            f.api.failure = CoordinatorAPI.Lost.reply
            do { _ = try await remove(f); check(false, "First synthetic response is lost") } catch {}
            let pending = try f.store.load(scope: f.scope)!
            check(try PhotoListingRemovalCoordinator.hasPending(directory: f.directory, localListingID: f.local,
                serverListingID: f.server, actorID: f.actor, libraryOrgID: f.library, store: f.store),
                "Lost reply durably fences later sync in its exact account/library/listing")
            check(try !PhotoListingRemovalCoordinator.hasPending(directory: f.directory, localListingID: f.local,
                serverListingID: f.server, actorID: UUID(), libraryOrgID: f.library, store: f.store),
                "Another account cannot inherit a pending removal fence")
            check(try !PhotoListingRemovalCoordinator.hasPending(directory: f.directory, localListingID: f.local,
                serverListingID: f.server, actorID: f.actor, libraryOrgID: UUID(), store: f.store),
                "Another library cannot inherit a pending removal fence")
            check(f.api.operations.count == 1 && pending == f.api.operations[0], "Lost response persists exact dispatched operation")
            check(try history(f) == before, "Lost response cannot alter local selection/history")
            f.api.failure = nil
            let reopened = PhotoListingRemovalJournal(directory: f.directory)
            let confirmed = try await PhotoListingRemovalCoordinator.remove(versionID: "capture-original", directory: f.directory,
                localListingID: f.local, serverListingID: f.server, actorID: f.actor, libraryOrgID: f.library,
                api: f.api, requireIdentity: {}, store: reopened, references: f.references)
            check(f.api.snapshots == 1 && f.api.operations == [pending, pending], "Reopened removal sends same exact operation without a new snapshot/UUID")
            check(try history(f) == before, "Confirmed coordinator result still leaves local selection to its caller")
            try PhotoListingRemovalCoordinator.finish(confirmed, store: reopened)
            check(try reopened.load(scope: f.scope) == nil, "Explicit confirmed completion retires only its journal")
            check(try !PhotoListingRemovalCoordinator.hasPending(directory: f.directory, localListingID: f.local,
                serverListingID: f.server, actorID: f.actor, libraryOrgID: f.library, store: reopened),
                "Confirmed retirement releases the durable sync fence")
        }
        for phase in ["actor-before", "library-before", "actor-after", "library-after"] {
            let f = try fixture(), before = try history(f)
            var currentActor = f.actor, currentLibrary = f.library
            let change = { if phase.hasPrefix("actor") { currentActor = UUID() } else { currentLibrary = UUID() } }
            if phase.hasSuffix("before") { f.api.afterSnapshot = change } else { f.api.afterRemoval = change }
            do { _ = try await remove(f, identity: { guard currentActor == f.actor, currentLibrary == f.library else { throw CloudSyncError.identityChanged } }); check(false, "Identity change must refuse") }
            catch CloudSyncError.identityChanged {}
            check(phase.hasSuffix("after") ? f.api.operations.count == 1 : f.api.operations.isEmpty,
                  "Actor/library change before dispatch sends no PATCH")
            check(try history(f) == before, "Actor/library change cannot mutate local selection")
            if phase.hasSuffix("after") { check(try f.store.load(scope: f.scope) != nil, "Identity loss after dispatch retains uncertain operation") }
        }
        do {
            let f = try fixture(), before = try history(f), descriptor = f.api.snapshot.galleryAssets[0]
            f.api.snapshot = .init(listingID: f.server, orgID: f.library, libraryOrgID: f.library,
                galleryAssetIDs: [f.asset, UUID()], mainPhotoKey: nil,
                galleryAssets: [descriptor, .init(assetID: UUID(), sha256: descriptor.sha256, bytes: descriptor.bytes)])
            do { _ = try await remove(f); check(false, "Ambiguous bytes must refuse") } catch PhotoListingRemovalCoordinator.Failure.ambiguousIdentity {}
            let pending = try f.store.load(scope: f.scope)
            check(f.api.operations.isEmpty && pending == nil, "Ambiguous SHA match cannot create or dispatch removal")
            check(try history(f) == before, "Ambiguous match preserves local history")
        }
        do {
            let f = try fixture(), before = try history(f)
            await f.references.mutateBeforeSaving()
            do { _ = try await remove(f); check(false, "Changed matched bytes must refuse") } catch CloudPhotoReferences.Failure.changedBytes {}
            check(f.api.operations.isEmpty, "Changed bytes between fresh SHA match and saved receipt cannot PATCH")
            check(try history(f) == before, "SHA race cannot alter local selection/history")
        }
        for error in [APIError.server(status: 409, code: "gallery_selection_changed", message: "Changed"),
                      APIError.server(status: 409, code: "conflict", message: "Other"),
                      APIError.server(status: 503, code: "gallery_selection_changed", message: "Unknown")] {
            let f = try fixture(), before = try history(f); f.api.failure = error
            do { _ = try await remove(f); check(false, "Injected server refusal must refuse") } catch {}
            let closed = error.status == 409 && error.code == "gallery_selection_changed"
            check((try f.store.load(scope: f.scope) == nil) == closed, "Only exact definitive CAS409 retires the pending operation")
            check(try history(f) == before, "Every server refusal preserves local selection")
        }
        do {
            let f = try fixture(), before = try history(f)
            f.api.alter = { r in .init(selection: .init(listingID: f.server, orgID: f.library, libraryOrgID: f.library,
                galleryAssetIDs: [f.asset], mainPhotoKey: nil), operationID: r.operationID, replayed: true,
                requestedAssetIDs: r.requestedAssetIDs, removedAssetIDs: r.removedAssetIDs) }
            do { _ = try await remove(f); check(false, "Re-added selection must refuse stale confirmation") } catch PhotoListingRemovalCoordinator.Failure.selectionChanged {}
            check(try history(f) == before, "Replayed old removal cannot remove a newly re-added local choice")
            check(try f.store.load(scope: f.scope) == nil, "Definitive stale replay retires old operation without automatic new PATCH")
            check(f.api.operations.count == 1, "Stale replay does not dispatch a replacement removal")
        }
        for mismatch in ["operation", "listing", "library", "requested", "removed"] {
            let f = try fixture(), before = try history(f)
            f.api.alter = { r in .init(selection: .init(listingID: mismatch == "listing" ? UUID() : f.server,
                orgID: f.library, libraryOrgID: mismatch == "library" ? UUID() : f.library, galleryAssetIDs: [], mainPhotoKey: nil),
                operationID: mismatch == "operation" ? UUID() : r.operationID, replayed: false,
                requestedAssetIDs: mismatch == "requested" ? [UUID()] : r.requestedAssetIDs,
                removedAssetIDs: mismatch == "removed" ? [UUID()] : r.removedAssetIDs) }
            do { _ = try await remove(f); check(false, "Mismatched coordinator reply must refuse") } catch PhotoListingRemovalJournal.Failure.mismatchedOperation {}
            check(try f.store.load(scope: f.scope) != nil, "Mismatched reply retains pending request")
            check(try history(f) == before, "Mismatched reply never alters local selection")
        }
        print("PASS actual removal coordinator: \(count) assertions; real journal/history, closed API/reference boundaries")
    }
}
