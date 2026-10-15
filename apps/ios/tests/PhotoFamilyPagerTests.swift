import Foundation
struct EnhancedPhoto: Equatable { let id: String; let originalURL: URL; let enhancedURL: URL }
struct Listing { let id: UUID; var cloudUnavailable: Bool? = nil }
@MainActor final class AppModel { var listings: [Listing] = [] }
@MainActor final class AuthStore { static let shared = AuthStore(); var userID: String? = "owner"; var syncSessionRevision = 1 }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor final class FeatureSessionAction { var isWaiting = false; func cancel() { isWaiting = false } }
@MainActor final class PhotoWorkQueue {
    static let shared = PhotoWorkQueue(); struct Job { var running = true }; var visibleJob: Job?
}
__HELPER__
__CONTEXT__
@MainActor final class Harness {
    let photo: EnhancedPhoto; let galleryPhotos: [EnhancedPhoto]; let model: AppModel
    var selectedVersion: EnhancedPhoto?; var viewed: EnhancedPhoto { selectedVersion ?? photo }
    var rememberedFamilyVersions: [String: EnhancedPhoto] = [:]
    var imageContext: NativeMediaExportContext? = NativeMediaExportContext()
    var selectionWorkID: UUID?; var editContext: NativeMediaExportContext?; var singleEditJobID: UUID?
    var showEditActions = false; var pendingEdit: String?; var singleStagingSetup: String?; var singleCustomPhoto: String?
    var editConnection = FeatureSessionAction(); var photoJobs = PhotoWorkQueue.shared
    var requestedCover = true; var showFullComparison = false; var exporting: Bool?
    var selectionError: String?; var selectedForListing = true
    var enhanced: Data? = Data([1]); var original: Data? = Data([2]); var imageLoadComplete = true; var showOriginal = false
    var editOriginal: EnhancedPhoto?; var editConsentRevision: UInt64?
    init(_ photo: EnhancedPhoto, _ gallery: [EnhancedPhoto], _ model: AppModel) { self.photo = photo; galleryPhotos = gallery; self.model = model }
__METHODS__
}
@main struct Checks {
    @MainActor static func main() throws {
        var n = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); n += 1 }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = base.appendingPathComponent(UUID().uuidString), foreign = base.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let listing = UUID(uuidString: directory.lastPathComponent)!
        let model = AppModel(); model.listings = [.init(id: listing)]
        for i in 1...36 { try PhotoVersionHistory.saveCapture(original: Data("original \(i)".utf8), enhanced: Data("enhanced \(i)".utf8), id: "room-\(i)", directory: directory) }
        var index = try PhotoVersionHistory.ensureOriginalSources(directory: directory)
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("orig-room-2.jpg"))
        func photo(_ version: PhotoVersionHistory.Version) -> EnhancedPhoto { .init(id: version.id, originalURL: directory.appendingPathComponent(version.reviewSourceFile(in: index)), enhancedURL: directory.appendingPathComponent(version.imageFile)) }
        let originals = index.libraryVersions(.original).map(photo)
        let stage = try PhotoVersionHistory.saveEdit(jpeg: Data("stage two".utf8), id: "room-2-stage", parentID: "room-2", sourceID: "room-2-original", edit: "stage", style: "modern", disclosure: "Virtual staging", provenanceID: "receipt", provenanceRecorded: true, directory: directory)
        index = try PhotoVersionHistory.load(directory: directory)
        let staged = photo(stage)
        let all = originals + [staged, originals[0]]
        check(PhotoFamilyPager.photos(all, index: index, directory: directory).count == 36, "count source families once, never saved variants")
        check(PhotoFamilyPager.photos(all.reversed(), index: index, directory: directory).map { index.versions[$0.id]!.familyID } == index.orderedFamilyIDs, "family pages retain uploaded library order")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignPhoto = EnhancedPhoto(id: originals[0].id, originalURL: foreign.appendingPathComponent(originals[0].originalURL.lastPathComponent), enhancedURL: foreign.appendingPathComponent(originals[0].enhancedURL.lastPathComponent))
        try Data([1]).write(to: foreignPhoto.enhancedURL)
        check(PhotoFamilyPager.family(of: foreignPhoto, index: index, directory: directory) == nil, "another listing directory cannot enter the viewer")
        let spoof = EnhancedPhoto(id: originals[0].id, originalURL: originals[1].originalURL, enhancedURL: originals[1].enhancedURL)
        check(PhotoFamilyPager.family(of: spoof, index: index, directory: directory) == nil, "version ID cannot impersonate another retained file")
        var hidden = index; hidden.hiddenFamilies.insert("room-3")
        check(PhotoFamilyPager.photos(all, index: hidden, directory: directory).count == 35, "hidden families cannot reappear through paging")
        let missing = originals[35]; try FileManager.default.removeItem(at: missing.enhancedURL)
        check(PhotoFamilyPager.photos(all, index: index, directory: directory).count == 35, "missing image cannot inflate available family count")
        try Data("original 36".utf8).write(to: missing.enhancedURL)
        let historyBefore = try Data(contentsOf: directory.appendingPathComponent(".photo-history.json"))
        let h = Harness(originals[0], all, model)
        check(h.familyPosition == 0 && h.familyPhotos.count == 36, "first photo reports actual 1 of 36")
        check(h.requestedCoverForViewed, "initial family keeps its explicit cover intent")
        h.movePhotoFamily(-1); check(h.viewed.id == originals[0].id, "first page cannot wrap into last")
        h.movePhotoFamily(1)
        check(h.viewed.id == originals[1].id && h.familyPosition == 1, "next opens exactly second whole family")
        check(h.enhanced == nil && h.original == nil && h.imageContext == nil && !h.selectedForListing, "family switch clears stale pixels and selection display before decode")
        check(!h.requestedCoverForViewed, "cover intent never follows navigation into another family")
        h.imageContext = NativeMediaExportContext(); h.openSinglePhotoEdit()
        check(h.editOriginal?.id == "room-2-original", "edit action after navigation targets only displayed family Original")
        let inFlight = h.viewed.id; h.movePhotoFamily(1)
        check(h.viewed.id == inFlight, "pending edit context fences family navigation")
        h.clearSinglePhotoEdit(); h.chooseVersion(staged); h.imageContext = NativeMediaExportContext(); h.movePhotoFamily(1)
        check(index.versions[h.viewed.id]?.familyID == "room-3", "next skips saved variants within one family")
        h.imageContext = NativeMediaExportContext(); h.movePhotoFamily(-1)
        check(h.viewed.id == staged.id, "return preserves the exact saved version previously viewed")
        h.imageContext = NativeMediaExportContext(); h.movePhotoFamily(-1)
        check(h.viewed.id == originals[0].id && h.requestedCoverForViewed, "return restores first family and only its cover intent")
        for blocker in ["selection", "setup", "custom", "job", "waiting", "comparison", "export"] {
            let b = Harness(originals[0], all, model)
            switch blocker { case "selection": b.selectionWorkID = UUID(); case "setup": b.singleStagingSetup = "pending"; case "custom": b.singleCustomPhoto = "pending"; case "job": b.singleEditJobID = UUID(); case "waiting": b.editConnection.isWaiting = true; case "comparison": b.showFullComparison = true; default: b.exporting = true }
            b.movePhotoFamily(1); check(b.viewed.id == originals[0].id, "in-flight \(blocker) cannot retarget navigation")
        }
        let actor = Harness(originals[0], all, model); AuthStore.shared.userID = "other"; actor.movePhotoFamily(1)
        check(actor.viewed.id == originals[0].id, "changed actor cannot navigate retained photo snapshot"); AuthStore.shared.userID = "owner"
        let workspace = Harness(originals[0], all, model); WorkspaceContext.selectedOrgID = UUID(); workspace.movePhotoFamily(1)
        check(workspace.viewed.id == originals[0].id, "changed library cannot navigate retained photo snapshot")
        let removed = Harness(originals[0], all, model); model.listings = []; removed.movePhotoFamily(1)
        check(removed.viewed.id == originals[0].id, "deleted listing cannot navigate retained photo snapshot"); model.listings = [.init(id: listing)]
        let standalone = Harness(originals[0], [], model)
        check(standalone.familyPhotos.isEmpty, "standalone AI Photo Studio does not gain family paging")
        let corruptedMemory = PhotoFamilyPager.destination(from: originals[0], offset: 1, candidates: all, remembered: ["room-2": foreignPhoto], index: index, directory: directory)
        check(corruptedMemory?.id == originals[1].id, "foreign remembered version cannot replace target family")
        check(PhotoFamilyPager.destination(from: originals[0], offset: 36, candidates: all, remembered: [:], index: index, directory: directory) == nil, "arbitrary jumps are refused")
        check(PhotoFamilyPager.destination(from: originals[35], offset: 1, candidates: all, remembered: [:], index: index, directory: directory) == nil, "last page cannot wrap into first")
        check(PhotoFamilyPager.swipeOffset(horizontal: -100, vertical: 10) == 1 && PhotoFamilyPager.swipeOffset(horizontal: 100, vertical: 10) == -1, "left and right swipes follow next and previous")
        for (x, y) in [(20.0, 0.0), (100, 100), (10, 150), (Double.infinity, 0), (100, Double.nan)] {
            check(PhotoFamilyPager.swipeOffset(horizontal: x, vertical: y) == nil, "vertical, short and invalid gestures do not navigate")
        }
        check((try? Data(contentsOf: directory.appendingPathComponent(".photo-history.json"))) == historyBefore, "browsing never changes saved versions or publication selections")
        check((try? Data(contentsOf: directory.appendingPathComponent("orig-room-2.jpg"))) == originalBytes, "browsing and edit entry preserve immutable original bytes")
        print("PASS \(n) actual family-navigation checks")
    }
}
