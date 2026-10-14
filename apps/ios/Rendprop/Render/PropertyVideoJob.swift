import Foundation

/// All inputs are already-owned private assets before the durable job starts.
/// This receipt never contains a bearer token or a provider URL.
struct PropertyVideoJobContext: Codable, Equatable, Sendable {
    let localListingID: UUID
    let listingID: UUID
    let actorID: UUID
    let orgID: UUID
}

struct PropertyVideoJobSource: Codable, Equatable, Sendable {
    let photoID: String
    let photoAssetID: UUID
    let photoVersionID: String
    let photoProvenanceID: UUID?
    let motion: String
    enum CodingKeys: String, CodingKey {
        case photoID = "photo_id", photoAssetID = "photo_asset_id", photoVersionID = "photo_version_id"
        case photoProvenanceID = "photo_provenance_id", motion
    }
}

struct PropertyVideoPresentation: Codable, Equatable, Sendable {
    struct Title: Codable, Equatable, Sendable { let title: String; let subtitle: String; let watermark: String }
    let transition: String
    let shotCaptionStyle: String
    let spokenCaptions: Bool
    let titleCard: Title?
    let shotLabels: [String?]
    enum CodingKeys: String, CodingKey {
        case transition, shotCaptionStyle = "shot_caption_style", spokenCaptions = "spoken_captions"
        case titleCard = "title_card", shotLabels = "shot_labels"
    }
}

struct PropertyVideoJobRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    let listingID: UUID
    let expectedOrgID: UUID
    let purpose: String
    let aspect: String
    let sources: [PropertyVideoJobSource]
    let narrationResultID: UUID?
    var narrationAssetID: UUID? = nil
    var narrationWords: [PropertyVideoNarrationWord]? = nil
    let music: VideoMusicSelection?
    let allowOriginalPhotoFallback: Bool
    let presentation: PropertyVideoPresentation
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", listingID = "listing_id", expectedOrgID = "expected_org_id"
        case purpose, aspect, sources, music, presentation
        case narrationResultID = "narration_result_id", narrationAssetID = "narration_asset_id", narrationWords = "narration_words"
        case allowOriginalPhotoFallback = "allow_original_photo_fallback"
    }
    var isValid: Bool {
        ["listing", "social"].contains(purpose) && aspect == (purpose == "listing" ? "16:9" : "9:16") &&
        (1...100).contains(sources.count) && Set(sources.map(\.photoID)).count == sources.count &&
        sources.allSatisfy { !$0.photoID.isEmpty && $0.photoID.utf8.count <= 200 && !$0.photoVersionID.isEmpty && $0.photoVersionID.utf8.count <= 200 && ["fly_through", "push_in", "side_glide", "pull_back"].contains($0.motion) } &&
        ["cut", "dissolve", "whip"].contains(presentation.transition) &&
        ["off", "lowerThird", "punchCard", "highlightBox"].contains(presentation.shotCaptionStyle) &&
        presentation.shotLabels.count == sources.count && presentation.shotLabels.allSatisfy { ($0?.utf8.count ?? 0) <= 200 } &&
        (purpose == "social" || presentation.titleCard == nil) &&
        (narrationResultID == nil || narrationAssetID == nil) &&
        (narrationWords == nil || ((narrationWords?.count ?? 0) <= 3000 && narrationWords!.allSatisfy(\.isValid)))
    }
}

struct PropertyVideoNarrationWord: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
    var isValid: Bool { !text.isEmpty && text.utf8.count <= 200 && start.isFinite && end.isFinite && start >= 0 && end >= start && end <= 600 }
}

struct PropertyVideoJobReply: Codable, Equatable, Sendable {
    let jobID: UUID
    let operationID: UUID
    let listingID: UUID
    let orgID: UUID
    let selectedLibraryOrgID: UUID
    let sourceCount: Int
    let manifestSHA256: String
    let state: String
    var completedSources: Int? = nil
    var resumeAvailable: Bool? = nil
    var message: String? = nil
    var result: PropertyVideoJobResult? = nil
    enum CodingKeys: String, CodingKey {
        case jobID = "job_id", operationID = "operation_id", listingID = "listing_id", orgID = "org_id"
        case selectedLibraryOrgID = "selected_library_org_id", sourceCount = "source_count", manifestSHA256 = "manifest_sha256"
        case state, completedSources = "completed_sources", resumeAvailable = "resume_available", message, result
    }
    func checked(request: PropertyVideoJobRequest, previous: PropertyVideoJobReply? = nil, requireDownload: Bool = true) throws -> Self {
        guard request.isValid, operationID == request.operationID, listingID == request.listingID,
              selectedLibraryOrgID == request.expectedOrgID, sourceCount == request.sources.count,
              manifestSHA256.count == 64, manifestSHA256.allSatisfy(\.isHexDigit),
              ["queued", "generating", "quality_review", "composing", "ready", "cancelled", "failed", "needs_reconciliation"].contains(state),
              (0...sourceCount).contains(completedSources ?? 0),
              resumeAvailable != true || state == "failed",
              previous == nil || (previous!.jobID == jobID && previous!.manifestSHA256 == manifestSHA256 && previous!.orgID == orgID),
              state != "ready" || result != nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if let result { try result.check(request: request, requireDownload: requireDownload) }
        return self
    }
    var isTerminal: Bool { ["ready", "cancelled", "failed", "needs_reconciliation"].contains(state) }
    var mayResume: Bool { state == "failed" && resumeAvailable == true }
}

struct PropertyVideoJobResult: Codable, Equatable, Sendable {
    let assetID: UUID
    let posterAssetID: UUID
    var downloadURL: URL?
    let width: Int
    let height: Int
    let durationS: Double
    let bytes: Int64
    let sha256: String
    let brandingPolicy: String?
    let sources: [ListingVideoSource]
    let originalPhotoCount: Int
    let music: VideoMusicSelection?
    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id", posterAssetID = "poster_asset_id", downloadURL = "download_url", width, height
        case durationS = "duration_s", bytes, sha256, brandingPolicy = "branding_policy", sources
        case originalPhotoCount = "original_photo_count", music
    }
    func check(request: PropertyVideoJobRequest, requireDownload: Bool = true) throws {
        let size = request.aspect == "16:9" ? (1920, 1080) : (1080, 1920)
        guard (!requireDownload || downloadURL != nil),
              downloadURL == nil || (downloadURL!.scheme == "https" && downloadURL!.user == nil && downloadURL!.password == nil),
              width >= size.0, height >= size.1, abs(Double(width) / Double(height) - Double(size.0) / Double(size.1)) < 0.01,
              durationS.isFinite, durationS > 0, durationS <= 600, bytes > 0, bytes <= 2_000_000_000,
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit), sources.count == request.sources.count,
              (0...sources.count).contains(originalPhotoCount), originalPhotoCount == sources.filter({ $0.motionKind == "original_photo" }).count, music == request.music,
              request.purpose != "listing" || brandingPolicy == "unbranded" else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        for (source, frozen) in zip(sources, request.sources) {
            guard source.isComplete, source.photoVersionID == frozen.photoVersionID,
                  source.photoAssetID.flatMap(UUID.init(uuidString:)) == frozen.photoAssetID,
                  source.photoProvenanceID.flatMap(UUID.init(uuidString:)) == frozen.photoProvenanceID else {
                throw PropertyVideoJobStore.Failure.invalidReceipt
            }
        }
    }
}

struct PropertyVideoSavedJob: Codable, Equatable, Sendable {
    let context: PropertyVideoJobContext
    let request: PropertyVideoJobRequest
    let createdAt: Date
    var reply: PropertyVideoJobReply?
    var localOutputRelativePath: String? = nil
    var capacityRefusal: PropertyVideoCapacityRefusal? = nil
    var wasRefusedBeforeAdmission: Bool { reply == nil && capacityRefusal?.provesNoAdmission(for: request) == true }
    var mayReplaceAfterResolution: Bool { reply?.isTerminal == true || wasRefusedBeforeAdmission }
}

enum PropertyVideoJobStore {
    enum Failure: Error, LocalizedError {
        case invalidReceipt, identityChanged, unresolvedJob
        var errorDescription: String? {
            switch self {
            case .invalidReceipt: return "The saved video job couldn't be verified. Your photos and existing work are kept."
            case .identityChanged: return "This video belongs to another account or listing library. Return to that account to review it."
            case .unresolvedJob: return "An earlier video request is still saved. Check its status before starting another video."
            }
        }
    }
    static func url(context: PropertyVideoJobContext, documents: URL) -> URL {
        documents.appendingPathComponent("reels/\(context.localListingID.uuidString)-server-\(context.actorID.uuidString)-\(context.orgID.uuidString).json")
    }
    static func load(context: PropertyVideoJobContext, documents: URL) throws -> PropertyVideoSavedJob? {
        let target = url(context: context, documents: documents)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let count = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0, count <= 262144 else { throw Failure.invalidReceipt }
        let saved = try JSONDecoder().decode(PropertyVideoSavedJob.self, from: Data(contentsOf: target))
        guard saved.context == context, saved.request.isValid,
              saved.request.listingID == context.listingID, saved.request.expectedOrgID == context.orgID else { throw Failure.invalidReceipt }
        if let refusal = saved.capacityRefusal {
            guard saved.reply == nil, refusal.provesNoAdmission(for: saved.request) else { throw Failure.invalidReceipt }
        }
        if let reply = saved.reply { _ = try reply.checked(request: saved.request, requireDownload: false) }
        if let path = saved.localOutputRelativePath {
            guard path.hasPrefix("reels/\(context.localListingID.uuidString)-"), path.hasSuffix(".mp4"), !path.split(separator: "/").contains(".."), path.split(separator: "/").count == 2 else { throw Failure.invalidReceipt }
        }
        return saved
    }
    static func save(_ saved: PropertyVideoSavedJob, documents: URL) throws {
        guard saved.request.isValid, saved.request.listingID == saved.context.listingID, saved.request.expectedOrgID == saved.context.orgID else { throw Failure.invalidReceipt }
        if let refusal = saved.capacityRefusal {
            guard saved.reply == nil, refusal.provesNoAdmission(for: saved.request) else { throw Failure.invalidReceipt }
        }
        if let reply = saved.reply { _ = try reply.checked(request: saved.request, requireDownload: false) }
        if let existing = try load(context: saved.context, documents: documents) {
            guard existing.request.operationID == saved.request.operationID, existing.request == saved.request else { throw Failure.invalidReceipt }
            // Admission is durable. A delayed pre-acknowledgment writer cannot
            // erase an accepted job or reopen a definitively closed operation.
            if existing.reply != nil { guard saved.reply != nil, saved.capacityRefusal == nil else { throw Failure.invalidReceipt } }
            if existing.wasRefusedBeforeAdmission { guard saved.reply == nil, saved.capacityRefusal == existing.capacityRefusal else { throw Failure.invalidReceipt } }
            if let old = existing.reply, let new = saved.reply { _ = try new.checked(request: saved.request, previous: old, requireDownload: false) }
        }
        var durable = saved
        if var reply = durable.reply, var result = reply.result {
            result.downloadURL = nil; reply.result = result; durable.reply = reply
        }
        let bytes = try JSONEncoder().encode(durable)
        guard bytes.count <= 262144 else { throw Failure.invalidReceipt }
        let target = url(context: saved.context, documents: documents)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidReceipt }
    }
    /// Archive only a resolved previous receipt; unresolved work cannot be replaced.
    static func start(_ saved: PropertyVideoSavedJob, documents: URL) throws {
        if let existing = try load(context: saved.context, documents: documents) {
            guard existing.mayReplaceAfterResolution else { throw Failure.unresolvedJob }
            let old = url(context: existing.context, documents: documents)
            let archive = old.deletingPathExtension().appendingPathExtension("\(existing.request.operationID.uuidString).history.json")
            try FileManager.default.copyItem(at: old, to: archive)
            try FileManager.default.removeItem(at: old)
        }
        try save(saved, documents: documents)
    }
}
