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
    var consentRevision: String? = nil
    var processorConsent: PropertyVideoProcessorRecord? = nil
    var qualityProfile: String? = nil
    var processorMetadataUnknown: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case consentRevision = "consent_revision", processorConsent = "processor_consent", qualityProfile = "quality_profile"
        case processorMetadataUnknown
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
        var current = self
        if let previous, previous.processorMetadataUnknown == true ||
            (previous.hasProcessorMetadata && (previous.consentRevision != consentRevision || previous.processorConsent != processorConsent || previous.qualityProfile != qualityProfile)) {
            current.processorMetadataUnknown = true
        }
        return current
    }
    var hasProcessorMetadata: Bool { consentRevision != nil || processorConsent != nil || qualityProfile != nil || processorMetadataUnknown == true }
    /// nil means a future/partial record, never a license to choose today's route.
    var resumeConsentToken: String? {
        guard processorMetadataUnknown != true else { return nil }
        if !hasProcessorMetadata { return nil }
        let fal = ["legacy", "fal-kling3-4k-v1", "fal-kling3-4k-steady-v2"].contains(qualityProfile ?? "")
        if consentRevision == "property-video-jobs-v1", processorConsent == nil, fal { return "property-video-jobs-v1" }
        if consentRevision == PropertyVideoProcessorContract.known.token, processorConsent?.isKnown == true,
           fal || qualityProfile == PropertyVideoProcessorContract.known.profiles.first { return "property-video-jobs-v2" }
        return nil
    }
    var isTerminal: Bool { ["ready", "cancelled", "failed", "needs_reconciliation"].contains(state) }
    var mayResume: Bool { state == "failed" && resumeAvailable == true }
}


/// Malformed additive metadata must not make an otherwise usable status/cancel
/// receipt unreadable. Its authority is explicitly unknown instead.
extension PropertyVideoJobReply {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(UUID.self, forKey: .jobID); operationID = try c.decode(UUID.self, forKey: .operationID)
        listingID = try c.decode(UUID.self, forKey: .listingID); orgID = try c.decode(UUID.self, forKey: .orgID)
        selectedLibraryOrgID = try c.decode(UUID.self, forKey: .selectedLibraryOrgID)
        sourceCount = try c.decode(Int.self, forKey: .sourceCount); manifestSHA256 = try c.decode(String.self, forKey: .manifestSHA256)
        state = try c.decode(String.self, forKey: .state)
        completedSources = try c.decodeIfPresent(Int.self, forKey: .completedSources)
        resumeAvailable = try c.decodeIfPresent(Bool.self, forKey: .resumeAvailable)
        message = try c.decodeIfPresent(String.self, forKey: .message); result = try c.decodeIfPresent(PropertyVideoJobResult.self, forKey: .result)
        let present = c.contains(.consentRevision) || c.contains(.processorConsent) || c.contains(.qualityProfile)
        consentRevision = try? c.decode(String.self, forKey: .consentRevision)
        processorConsent = try? c.decode(PropertyVideoProcessorRecord.self, forKey: .processorConsent)
        qualityProfile = try? c.decode(String.self, forKey: .qualityProfile)
        processorMetadataUnknown = (try? c.decode(Bool.self, forKey: .processorMetadataUnknown)) == true ||
            (present && (!c.contains(.consentRevision) || !c.contains(.processorConsent) || !c.contains(.qualityProfile) || consentRevision == nil || qualityProfile == nil ||
             (c.contains(.processorConsent) && (try? c.decodeNil(forKey: .processorConsent)) != true && processorConsent == nil)))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobID, forKey: .jobID); try c.encode(operationID, forKey: .operationID)
        try c.encode(listingID, forKey: .listingID); try c.encode(orgID, forKey: .orgID)
        try c.encode(selectedLibraryOrgID, forKey: .selectedLibraryOrgID); try c.encode(sourceCount, forKey: .sourceCount)
        try c.encode(manifestSHA256, forKey: .manifestSHA256); try c.encode(state, forKey: .state)
        try c.encodeIfPresent(completedSources, forKey: .completedSources); try c.encodeIfPresent(resumeAvailable, forKey: .resumeAvailable)
        try c.encodeIfPresent(message, forKey: .message); try c.encodeIfPresent(result, forKey: .result)
        if hasProcessorMetadata {
            if let consentRevision { try c.encode(consentRevision, forKey: .consentRevision) } else { try c.encodeNil(forKey: .consentRevision) }
            if let processorConsent { try c.encode(processorConsent, forKey: .processorConsent) } else { try c.encodeNil(forKey: .processorConsent) }
            if let qualityProfile { try c.encode(qualityProfile, forKey: .qualityProfile) } else { try c.encodeNil(forKey: .qualityProfile) }
        }
        try c.encodeIfPresent(processorMetadataUnknown, forKey: .processorMetadataUnknown)
    }
}
struct PropertyVideoProcessorRecord: Codable, Equatable, Sendable {
    private static func isDate(_ text: String) -> Bool {
        guard text.utf8.count <= 64 else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: text) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) != nil
    }
    let token: String; let disclosureRevision: String; let processors: [String]; let recordedAt: String
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: PropertyVideoMetadataKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["token", "disclosure_revision", "processors", "recorded_at"] else { throw PropertyVideoProcessorFailure.unknownSavedAuthority }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token); disclosureRevision = try c.decode(String.self, forKey: .disclosureRevision)
        processors = try c.decode([String].self, forKey: .processors); recordedAt = try c.decode(String.self, forKey: .recordedAt)
    }
    enum CodingKeys: String, CodingKey { case token, disclosureRevision = "disclosure_revision", processors, recordedAt = "recorded_at" }
    var isKnown: Bool { token == PropertyVideoProcessorContract.known.token && disclosureRevision == PropertyVideoProcessorContract.known.disclosureRevision && processors == ["kie"] && Self.isDate(recordedAt) }
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
    var processorPermission: PropertyVideoProcessorSnapshot? = nil
    var stopRequested: Bool? = nil
    var abandoned: PropertyVideoOperationClosure? = nil
    var wasRefusedBeforeAdmission: Bool { reply == nil && capacityRefusal?.provesNoAdmission(for: request) == true }
    var mayReplaceAfterResolution: Bool { reply?.isTerminal == true || wasRefusedBeforeAdmission || abandoned?.matches(request) == true }
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
        if let permission = saved.processorPermission { guard permission.matches(saved.context) else { throw Failure.invalidReceipt } }
        if let closure = saved.abandoned { guard saved.reply == nil, closure.matches(saved.request) else { throw Failure.invalidReceipt } }
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
        if let permission = saved.processorPermission { guard permission.matches(saved.context) else { throw Failure.invalidReceipt } }
        if let closure = saved.abandoned { guard saved.reply == nil, closure.matches(saved.request) else { throw Failure.invalidReceipt } }
        if let refusal = saved.capacityRefusal {
            guard saved.reply == nil, refusal.provesNoAdmission(for: saved.request) else { throw Failure.invalidReceipt }
        }
        if let reply = saved.reply { _ = try reply.checked(request: saved.request, requireDownload: false) }
        if let existing = try load(context: saved.context, documents: documents) {
            guard existing.request.operationID == saved.request.operationID, existing.request == saved.request, existing.processorPermission == saved.processorPermission else { throw Failure.invalidReceipt }
            // Admission is durable. A delayed pre-acknowledgment writer cannot
            // erase an accepted job or reopen a definitively closed operation.
            if existing.stopRequested == true { guard saved.stopRequested == true else { throw Failure.invalidReceipt } }
            if let closed = existing.abandoned { guard saved.reply == nil, saved.abandoned == closed else { throw Failure.invalidReceipt } }
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
    /// Synchronous local stop journal; never deletes originals/history or
    /// assumes an unknown operation has been accepted or abandoned.
    static func actorJobs(actorID: UUID, documents: URL) throws -> [PropertyVideoSavedJob] {
        let directory = documents.appendingPathComponent("reels", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        guard files.count <= 10000 else { throw Failure.invalidReceipt }
        var result: [PropertyVideoSavedJob] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains(".history.") {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262144,
                  let decoded = try? JSONDecoder().decode(PropertyVideoSavedJob.self, from: Data(contentsOf: file)),
                  decoded.context.actorID == actorID, file == url(context: decoded.context, documents: documents),
                  let saved = try load(context: decoded.context, documents: documents) else { continue }
            result.append(saved)
        }
        return result
    }
    static func requestStop(actorID: UUID, documents: URL, processorOnly: Bool = false) throws {
        for var saved in try actorJobs(actorID: actorID, documents: documents) where !saved.mayReplaceAfterResolution || saved.reply?.mayResume == true {
            if processorOnly && saved.processorPermission == nil && saved.reply?.consentRevision != "property-video-jobs-v2" { continue }
            saved.stopRequested = true
            try save(saved, documents: documents)
        }
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

private struct PropertyVideoMetadataKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}
