import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
@MainActor final class StagePlanAPI: PropertyVideoPlanningAPI {
    var received: [PropertyVideoPlanPhoto] = []
    func propertyVideoPlan(listingID: UUID, orgID: UUID, photos: [PropertyVideoPlanPhoto], idempotencyKey: String) async throws -> PropertyVideoPlanReply {
        received = photos
        return .init(schema: 1, listingID: listingID, orgID: orgID,
            photos: photos.map { .init(photoID: $0.photoID, assetID: $0.assetID, scene: .living, confidence: 0.95, motion: .pullBack, seconds: 5) }, model: "closed-stage-fixture")
    }
}
@main struct StagedVideoSourceTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("staged-video-source-" + UUID().uuidString)
        FileStore.documents = root
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = UUID(), server = UUID(), owner = UUID(), org = UUID(), provenance = UUID().uuidString
        let directory = EnhancedPhoto.directory(for: listing)
        let original = Data("EMPTY room with fixed original windows".utf8)
        let stageBytes = Data("REVIEWED stage: furniture in same original room".utf8)
        let laterBytes = Data("NEWER UNREVIEWED staging preview".utf8)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "base", directory: directory)
        let stage = try PhotoVersionHistory.saveEdit(jpeg: stageBytes, id: "reviewed-stage", parentID: "base", sourceID: "base",
            edit: "stage", style: "modern", disclosure: "Virtually staged", provenanceID: provenance,
            provenanceRecorded: true, directory: directory)
        let later = try PhotoVersionHistory.saveEdit(jpeg: laterBytes, id: "later-preview", parentID: stage.id, sourceID: "base",
            edit: "stage", style: "modern", disclosure: nil, provenanceID: UUID().uuidString,
            provenanceRecorded: true, directory: directory)
        try PhotoVersionHistory.selectForPublication(id: stage.id, directory: directory, reviewed: true)
        let index = try PhotoVersionHistory.load(directory: directory)
        check(index.current[stage.familyID] == later.id && index.publicationChoice(for: stage.id)?.id == stage.id,
            "editing preview and exact reviewed listing version remain separate")
        let chosen = try EnhancedPhoto.loadForListing(listingID: listing)
        check(chosen.count == 1 && chosen[0].id == stage.id && chosen[0].enhancedURL.lastPathComponent == stage.imageFile,
            "video collection resolves the reviewed staged file instead of a newer preview")
        let jpeg = try SourcePreparation.preparedReelJPEG(photo: chosen[0], aspect: "16:9")
        check(jpeg == stageBytes && jpeg != original && jpeg != laterBytes,
            "actual video preparation reads the saved staged pixels without reverting to original")
        check(chosen[0].savedVersion?.provenanceID == provenance && chosen[0].savedVersion?.effects.contains("stage") == true,
            "selected staged provenance and effects stay attached to the exact version")
        let sourceAsset = UUID(), api = StagePlanAPI()
        let plan = try await PropertyVideoPlanner.plan(inputs: [.init(photoID: stage.id, assetID: sourceAsset, jpegDigest: PropertyVideoPlanner.digest(jpeg))],
            context: .init(ownerID: owner, orgID: org, listingID: server), api: api, automaticOrder: true,
            documents: root, requireCurrent: { try Task.checkCancellation() })
        check(api.received == [.init(photoID: stage.id, assetID: sourceAsset)] && plan.photos[0].input.jpegDigest == PropertyVideoPlanner.digest(stageBytes),
            "classifier uses the exact saved stage input and its privately uploaded asset identity")
        let context = PendingReelRequest.Context(listingID: listing, serverListingID: server, owner: owner.uuidString, workspace: org)
        let batch = PendingReelBatch(context: context, id: UUID(), photos: [.init(id: stage.id, jpegBase64: jpeg.base64EncodedString(), shot: nil,
            sourceAssetID: sourceAsset.uuidString, photoProvenanceID: provenance)], motion: "pull_back", aspect: "16:9", spaceType: "real_estate", completedPaths: [], framing: "preserve_photo")
        try batch.save()
        let reloaded = try PendingReelBatch.load(context)!
        try SourcePreparation.requireSavedReelReview(reloaded)
        check(reloaded.photos[0].jpegBase64 == stageBytes.base64EncodedString() && reloaded.photos[0].photoProvenanceID == provenance && reloaded.photos[0].sourceAssetID == sourceAsset.uuidString,
            "saved video recovery retains staged bytes and provenance while current preview differs")
        let unreviewed = PendingReelBatch(context: context, id: UUID(), photos: [.init(id: later.id, jpegBase64: laterBytes.base64EncodedString(), shot: nil)],
            motion: "push_in", aspect: "16:9", spaceType: "real_estate", completedPaths: [])
        do { try SourcePreparation.requireSavedReelReview(unreviewed); check(false, "unreviewed newer stage stays held during recovery") } catch {}
        let fallback = ListingVideoSource(photoVersionID: reloaded.photos[0].id, photoAssetID: reloaded.photos[0].sourceAssetID,
            photoProvenanceID: reloaded.photos[0].photoProvenanceID, generationRequestID: "rejected-motion", motionKind: "original_photo", sourceBound: false)
        let wire = ListingVideoComposition(sources: [fallback]).sources[0]
        check(wire.isComplete && wire.photoVersionID == stage.id && wire.photoProvenanceID == provenance && wire.generationRequestID == nil,
            "original-photo motion fallback preserves virtual staging disclosure lineage on publication")
        check(try Data(contentsOf: directory.appendingPathComponent("orig-base.jpg")) == original &&
              Data(contentsOf: directory.appendingPathComponent(stage.imageFile)) == stageBytes,
            "staged video preparation never rewrites original or reviewed stage files")
        print("PASSED exact staged version → preparation → private classifier identity → durable recovery → fallback publication lineage; no user re-upload/UI/vendor")
    }
}
