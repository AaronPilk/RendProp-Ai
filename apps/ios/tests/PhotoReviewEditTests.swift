import Foundation

enum SpaceType { case realEstate, hospitality; static let current = SpaceType.realEstate }
struct Listing { var id: UUID; var cloudUnavailable: Bool? = nil; var isSample = false; var spaceType = SpaceType.realEstate }
@MainActor final class AppModel { var listings: [Listing] = [] }
@MainActor final class AuthStore { static let shared = AuthStore(); var userID: String? = "owner"; var syncSessionRevision = 1 }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
@MainActor final class AIConsent {
    static let shared = AIConsent(); var isGranted = true; var revocationRevision: UInt64 = 0
    var waiting: CheckedContinuation<Bool, Never>?
    var suspend = false
    func ensureGranted() async -> Bool {
        if suspend { return await withCheckedContinuation { waiting = $0 } }
        return isGranted
    }
}
@MainActor final class FeatureSessionAction {
    var cancelled = false; var deferred: (() -> Void)?; var hold = false
    func run(_ action: @escaping @MainActor () -> Void) { if hold { deferred = action } else { action() } }
    func cancel() { cancelled = true; deferred = nil }
}
struct EnhancedPhoto {
    let id: String; let originalURL: URL; let enhancedURL: URL
}
struct DeclutterGenerationApproval { let sourceVersionID: String }
struct DeclutterCreditAuthorization { let tariffVersion: String; let environment: String }
struct StageCreditAuthorization { let tariffVersion: String; let environment: String }
@MainActor final class PhotoDeclutterReviewModel {
    let photos: [EnhancedPhoto]
    var cancelled = false
    init(model: AppModel, listing: Listing, photos: [EnhancedPhoto], space: SpaceType) { self.photos = photos }
    func cancel() { cancelled = true }
}
struct PendingBatchEdit { let edit: String; let style: String?; let title: String; let multiple: Bool }
struct PhotoStagingSetup { let pending: PendingBatchEdit; let targets: [EnhancedPhoto]; let references: [EnhancedPhoto] }
@MainActor final class PhotoWorkQueue {
    static let shared = PhotoWorkQueue()
    struct Failure { let error: Error }
    struct Job { var id = UUID(); var running = true; var failures: [Failure] = []; var done = 0 }
    var visibleJob: Job?
}
@MainActor final class PhotoEditService {
    struct Call {
        let listing: UUID; let photos: [EnhancedPhoto]; let edit: String; let style: String?
        let prompt: String?; let reference: String?; let approvalIDs: Set<String>
        let declutterCredit: DeclutterCreditAuthorization?; let stageCredit: StageCreditAuthorization?
    }
    static var calls: [Call] = []
    let listing: Listing
    init(model: AppModel, listing: Listing, space: SpaceType) { self.listing = listing }
    func start(title: String, photos: [EnhancedPhoto], edit: String, style: String?, prompt: String?, stagingReferenceID: String?,
               declutterApprovals: [String: DeclutterGenerationApproval]?,
               declutterCredit: DeclutterCreditAuthorization?, stageCredit: StageCreditAuthorization?) -> Bool {
        guard PhotoWorkQueue.shared.visibleJob?.running != true else { return false }
        guard declutterCredit == nil || (edit == "declutter" && declutterApprovals != nil) else { return false }
        guard stageCredit == nil || edit == "stage" else { return false }
        if edit == "declutter" {
            guard let declutterApprovals, Set(declutterApprovals.keys) == Set(photos.map(\.id)),
                  declutterApprovals.allSatisfy({ $0.key == $0.value.sourceVersionID }) else { return false }
        }
        Self.calls.append(.init(listing: listing.id, photos: photos, edit: edit, style: style,
                                prompt: prompt, reference: stagingReferenceID,
                                approvalIDs: Set(declutterApprovals?.keys.map { $0 } ?? []),
                                declutterCredit: declutterCredit, stageCredit: stageCredit))
        PhotoWorkQueue.shared.visibleJob = .init(); return true
    }
}
enum Haptics { static func selection() {} }
struct AIFailure {
    var fullMessage: String
    init(_ error: Error) { fullMessage = error.localizedDescription }
    static func requiresSavedPhotoCheck(_ error: Error) -> Bool { error is URLError }
}
__ENUM__
__CONTEXT__
@MainActor final class Harness {
    var photo: EnhancedPhoto; var viewed: EnhancedPhoto; var model: AppModel
    var imageContext: NativeMediaExportContext? = NativeMediaExportContext()
    var editContext: NativeMediaExportContext?
    var editOriginal: EnhancedPhoto?; var editConsentRevision: UInt64?
    var selectionWorkID: UUID?; var selectionError: String?; var showEditActions = false
    var pendingEdit: PhotoReviewEdit?; var singleStagingSetup: PhotoStagingSetup?; var singleCustomPhoto: EnhancedPhoto?
    var singleDeclutterReview: PhotoDeclutterReviewModel?
    var singleEditJobID: UUID?; var editConnection = FeatureSessionAction()
    var photoJobs = PhotoWorkQueue.shared; var chosen: EnhancedPhoto?
    init(_ photo: EnhancedPhoto, _ model: AppModel) { self.photo = photo; self.viewed = photo; self.model = model }
    func chooseVersion(_ photo: EnhancedPhoto) { chosen = photo }
__METHODS__
}

@main struct Checks {
    @MainActor static func main() async throws {
        var n = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); n += 1 }
        func rejected(_ message: String, _ body: () throws -> Void) { do { try body(); preconditionFailure(message) } catch { n += 1 } }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func reset() { PhotoWorkQueue.shared.visibleJob = nil; PhotoEditService.calls = []; AIConsent.shared.isGranted = true; AIConsent.shared.suspend = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(uuidString: dir.lastPathComponent)!, original = Data("immutable original".utf8), enhanced = Data("local enhancement".utf8)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "room", directory: dir)
        try PhotoVersionHistory.saveCapture(original: Data("other original".utf8), enhanced: enhanced, id: "other", directory: dir)
        let originalIndex = try PhotoVersionHistory.ensureOriginalSources(directory: dir)
        let stage = try PhotoVersionHistory.saveEdit(jpeg: Data("saved furniture".utf8), id: "stage", parentID: "room", sourceID: "room", edit: "stage", style: "modern", disclosure: "Virtual staging", provenanceID: "real-receipt", provenanceRecorded: true, directory: dir)
        let stageURL = dir.appendingPathComponent(stage.imageFile)
        let photo = EnhancedPhoto(id: stage.id, originalURL: dir.appendingPathComponent("orig-room.jpg"), enhancedURL: stageURL)
        let approvedDeclutter = ["room-original": DeclutterGenerationApproval(sourceVersionID: "room-original")]
        let model = AppModel(); model.listings = [.init(id: id)]
        let beforeOpen = try PhotoVersionHistory.load(directory: dir)
        let subject = Harness(photo, model); subject.openSinglePhotoEdit()
        check(subject.showEditActions && subject.editOriginal?.id == "room-original", "staged review targets exactly its retained Original")
        check(subject.editOriginal?.enhancedURL == photo.originalURL && subject.editOriginal?.originalURL == photo.originalURL, "Original source URL is never staged output")
        check((try? Data(contentsOf: stageURL)) == Data("saved furniture".utf8), "opening edit preserves saved output bytes")
        check((try? Data(contentsOf: photo.originalURL)) == original, "opening edit preserves original bytes")
        let afterOpen = try PhotoVersionHistory.load(directory: dir)
        check(afterOpen.current == beforeOpen.current && afterOpen.listingSelections == beforeOpen.listingSelections, "opening single edit changes neither current result nor public selection")
        check(originalIndex.versions["room-original"]?.originalVerified == true, "retained capture registration remains explicit")
        for action in [PhotoReviewEdit.declutter, .twilight, .sky, .lawn] {
            reset(); let h = Harness(photo, model); h.openSinglePhotoEdit(); h.pendingEdit = action; h.continueSinglePhotoEdit(); await settle()
            if action == .declutter {
                check(PhotoEditService.calls.isEmpty && h.singleDeclutterReview?.photos.map(\.id) == ["room-original"],
                      "declutter opens an exact Original assessment before any paid image edit")
                h.singleDeclutterReview = nil
                h.startSinglePhotoWork(.declutter, prompt: nil, declutterApprovals: approvedDeclutter)
                check(PhotoEditService.calls.first?.approvalIDs == Set(["room-original"]), "confirmed declutter carries the exact Original approval")
            }
            check(PhotoEditService.calls.count == 1 && PhotoEditService.calls[0].photos.count == 1, "one action dispatches exactly one photo, never bulk")
            check(PhotoEditService.calls[0].photos[0].id == "room-original" && PhotoEditService.calls[0].edit == action.edit, "selected operation uses exact retained Original id")
            check(PhotoEditService.calls[0].listing == id && h.singleEditJobID == PhotoWorkQueue.shared.visibleJob?.id, "one-photo progress binds the actual started job")
        }
        for style in ["modern", "rustic", "minimalist", "contemporary"] {
            reset(); let h = Harness(photo, model); h.openSinglePhotoEdit(); h.pendingEdit = .stage(style); h.continueSinglePhotoEdit(); await settle()
            check(PhotoEditService.calls.isEmpty && h.singleStagingSetup?.pending.style == style, "stage opens existing setup before purchase")
            check(h.singleStagingSetup?.targets.map(\.id) == ["room-original"] && h.singleStagingSetup?.pending.multiple == false, "stage setup is one exact Original with no preselected siblings")
            h.startSinglePhotoWork(.stage(style), prompt: "oak furnishing brief")
            check(PhotoEditService.calls.count == 1 && PhotoEditService.calls[0].style == style && PhotoEditService.calls[0].prompt == "oak furnishing brief", "stage preserves chosen style and optional brief")
        }
        reset(); let creditedDeclutter = Harness(photo, model); creditedDeclutter.openSinglePhotoEdit()
        creditedDeclutter.editConsentRevision = AIConsent.shared.revocationRevision
        let declutterCredit = DeclutterCreditAuthorization(tariffVersion: "photo-declutter-v1", environment: "Sandbox")
        creditedDeclutter.startSinglePhotoWork(.declutter, prompt: nil,
                                               declutterApprovals: approvedDeclutter, declutterCredit: declutterCredit)
        check(PhotoEditService.calls.count == 1 &&
              PhotoEditService.calls[0].declutterCredit?.tariffVersion == "photo-declutter-v1" &&
              PhotoEditService.calls[0].declutterCredit?.environment == "Sandbox" &&
              PhotoEditService.calls[0].stageCredit == nil,
              "single-photo declutter forwards exact credit authorization")
        reset(); let creditedStage = Harness(photo, model); creditedStage.openSinglePhotoEdit()
        creditedStage.editConsentRevision = AIConsent.shared.revocationRevision
        let stageCredit = StageCreditAuthorization(tariffVersion: "photo-stage-v1", environment: "Production")
        creditedStage.startSinglePhotoWork(.stage("modern"), prompt: "oak furnishing brief", stageCredit: stageCredit)
        check(PhotoEditService.calls.count == 1 &&
              PhotoEditService.calls[0].stageCredit?.tariffVersion == "photo-stage-v1" &&
              PhotoEditService.calls[0].stageCredit?.environment == "Production" &&
              PhotoEditService.calls[0].declutterCredit == nil,
              "single-photo staging forwards exact credit authorization")
        reset(); let custom = Harness(photo, model); custom.openSinglePhotoEdit(); custom.pendingEdit = .custom; custom.continueSinglePhotoEdit(); await settle()
        check(custom.singleCustomPhoto?.id == "room-original" && PhotoEditService.calls.isEmpty, "custom prompt opens for exact Original without dispatch")
        custom.startSinglePhotoWork(.custom, prompt: "remove loose bags only")
        check(PhotoEditService.calls.count == 1 && PhotoEditService.calls[0].prompt == "remove loose bags only", "custom uses existing service with exact prompt")
        reset(); let cancelled = Harness(photo, model); cancelled.openSinglePhotoEdit(); cancelled.continueSinglePhotoEdit(); await settle()
        check(PhotoEditService.calls.isEmpty, "dismissing action choices makes no paid dispatch")
        check(cancelled.editContext == nil, "dismissing choices releases family navigation fence")
        reset(); AIConsent.shared.isGranted = false; let declined = Harness(photo, model); declined.openSinglePhotoEdit(); declined.pendingEdit = .declutter; declined.continueSinglePhotoEdit(); await settle()
        check(PhotoEditService.calls.isEmpty, "declined AI consent cannot dispatch")
        check(declined.editContext == nil, "declined consent releases family navigation fence")
        reset(); let abandoned = Harness(photo, model); abandoned.openSinglePhotoEdit(); abandoned.editConsentRevision = AIConsent.shared.revocationRevision
        abandoned.startSinglePhotoWork(.declutter, prompt: nil)
        let abandonedReview = abandoned.singleDeclutterReview!
        abandoned.clearSinglePhotoEdit()
        check(abandonedReview.cancelled && abandoned.singleDeclutterReview == nil && PhotoEditService.calls.isEmpty,
              "dismissing declutter review cancels unsent assessment without a paid edit")
        reset(); let stale = Harness(photo, model); stale.openSinglePhotoEdit(); stale.editConsentRevision = AIConsent.shared.revocationRevision
        AuthStore.shared.userID = "different-owner"; stale.imageContext = NativeMediaExportContext(); stale.startSinglePhotoWork(.declutter, prompt: nil)
        check(PhotoEditService.calls.isEmpty && stale.singleDeclutterReview == nil, "actor change cannot dispatch from retained sheet")
        AuthStore.shared.userID = "owner"
        reset(); let revoked = Harness(photo, model); revoked.openSinglePhotoEdit(); revoked.editConsentRevision = AIConsent.shared.revocationRevision
        AIConsent.shared.revocationRevision += 1; revoked.startSinglePhotoWork(.declutter, prompt: nil)
        check(PhotoEditService.calls.isEmpty && revoked.singleDeclutterReview == nil, "revoked and regranted consent cannot revive old action")
        reset(); let waiting = Harness(photo, model); waiting.openSinglePhotoEdit(); waiting.pendingEdit = .declutter; AIConsent.shared.suspend = true; waiting.continueSinglePhotoEdit(); await settle()
        AuthStore.shared.syncSessionRevision += 1; AIConsent.shared.waiting?.resume(returning: true); AIConsent.shared.waiting = nil; await settle()
        check(PhotoEditService.calls.isEmpty && waiting.singleDeclutterReview == nil, "session revision changed while awaiting consent cannot dispatch")
        reset(); let busy = Harness(photo, model); PhotoWorkQueue.shared.visibleJob = .init(); busy.openSinglePhotoEdit()
        check(!busy.showEditActions, "another active photo job blocks one-photo entry")
        reset(); let missingHome = Harness(photo, model); model.listings = []; missingHome.openSinglePhotoEdit()
        check(!missingHome.showEditActions, "removed home cannot open paid choices"); model.listings = [.init(id: id)]
        reset(); let ready = Harness(photo, model); ready.openSinglePhotoEdit(); ready.editConsentRevision = AIConsent.shared.revocationRevision; ready.startSinglePhotoWork(.declutter, prompt: nil, declutterApprovals: approvedDeclutter)
        let ownJob = ready.singleEditJobID!
        ready.receiveSinglePhotoWork(.init(running: false, done: 1))
        check(ready.chosen == nil && ready.singleEditJobID == ownJob, "another job cannot replace this photo review")
        let newOutput = try PhotoVersionHistory.saveEdit(jpeg: Data("new clean output".utf8), id: "new-clean", parentID: stage.id, sourceID: "room-original", edit: "declutter", style: nil, disclosure: "Declutter", provenanceID: "new-receipt", provenanceRecorded: true, directory: dir)
        ready.receiveSinglePhotoWork(.init(id: ownJob, running: false, done: 1))
        check(ready.chosen?.id == newOutput.id && ready.singleEditJobID == nil, "only matching successful job opens saved new family version")
        check(newOutput.effects == ["declutter"] && newOutput.sourceID == "room-original" && newOutput.parentID == stage.id, "new edit records Original input and separate saved concurrency parent")
        check((try? Data(contentsOf: photo.originalURL)) == original && (try? Data(contentsOf: stageURL)) == Data("saved furniture".utf8), "new edit never overwrites Original or earlier staged result")
        reset(); let failure = Harness(photo, model); failure.openSinglePhotoEdit(); failure.editConsentRevision = AIConsent.shared.revocationRevision; failure.startSinglePhotoWork(.declutter, prompt: nil, declutterApprovals: approvedDeclutter)
        let beforeFailure = PhotoEditService.calls.count
        failure.receiveSinglePhotoWork(.init(id: failure.singleEditJobID!, running: false, failures: [.init(error: PhotoVersionHistory.Failure.reviewRequired)]))
        check(failure.selectionError != nil && PhotoEditService.calls.count == beforeFailure && failure.chosen == nil, "failure is visible without retry or replacing review")
        check(failure.editContext == nil, "finished failed edit releases family navigation fence")
        failure.clearSinglePhotoEdit()
        check(failure.editContext == nil && failure.editOriginal == nil && failure.pendingEdit == nil && failure.singleEditJobID == nil && failure.editConnection.cancelled, "dismissal clears the deferred edit context")
        let unknownDir = dir.appendingPathComponent("unknown"); try FileManager.default.createDirectory(at: unknownDir, withIntermediateDirectories: true)
        try Data("unknown source".utf8).write(to: unknownDir.appendingPathComponent("orig-old.jpg"))
        try Data("unknown image".utf8).write(to: unknownDir.appendingPathComponent("enh-old.jpg"))
        var unverified = try PhotoVersionHistory.load(directory: unknownDir)
        let old = unverified.versions["old"]!
        unverified.versions["old-source"] = .init(id: "old-source", familyID: old.familyID, imageFile: old.originalFile!, originalFile: old.originalFile, originalVerified: false, parentID: nil, sourceID: nil, stagingBaseID: nil, edit: "legacy", style: nil, effects: [], sourceHistoryKnown: false, disclosure: nil, provenanceID: nil, originalAssetID: nil, serverListingID: nil, provenanceRecorded: false, createdAt: Date())
        try JSONEncoder().encode(unverified).write(to: unknownDir.appendingPathComponent(".photo-history.json"))
        rejected("unverified earlier source cannot become Original") { _ = try PhotoVersionHistory.originalForEditing(id: "old", directory: unknownDir) }
        var corrupt = try PhotoVersionHistory.load(directory: dir)
        corrupt.versions.removeValue(forKey: "room-original")
        // Remove the capture's verification so automatic original registration cannot repair this fault.
        for (key, v) in corrupt.versions where v.familyID == "room" {
            corrupt.versions[key] = .init(id: v.id, familyID: v.familyID, imageFile: v.imageFile, originalFile: "orig-other.jpg", originalVerified: false, parentID: v.parentID, sourceID: v.sourceID, stagingBaseID: v.stagingBaseID, edit: v.edit, style: v.style, effects: v.effects, sourceHistoryKnown: v.sourceHistoryKnown, disclosure: v.disclosure, provenanceID: v.provenanceID, originalAssetID: v.originalAssetID, serverListingID: v.serverListingID, provenanceRecorded: v.provenanceRecorded, createdAt: v.createdAt)
        }
        try JSONEncoder().encode(corrupt).write(to: dir.appendingPathComponent(".photo-history.json"))
        rejected("another family cannot impersonate this Original") { _ = try PhotoVersionHistory.originalForEditing(id: "new-clean", directory: dir) }
        print("PASS \(n) actual single-photo review checks")
    }
}
