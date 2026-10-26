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
    var visibleFrames: Int? = nil
    var sourceSHA256: String? = nil
    var sourceBytes: Int64? = nil
    enum CodingKeys: String, CodingKey {
        case photoID = "photo_id", photoAssetID = "photo_asset_id", photoVersionID = "photo_version_id"
        case photoProvenanceID = "photo_provenance_id", motion
        case visibleFrames = "visible_frames", sourceSHA256 = "source_sha256", sourceBytes = "source_bytes"
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
    /// nil preserves Automatic and existing journals. A chosen move applies to
    /// every source; its intent must survive planning, saving and admission.
    var motionOverride: String? = nil
    var sourceMode: String? = nil
    var compositionProfile: String? = nil
    var opening: PropertyVideoOpening? = nil
    var photoMotionProfile: PhotoMotionContract.Profile? { isPhotoMotion ? PhotoMotionContract.resolvedProfile(compositionProfile) : nil }
    var isPhotoMotion: Bool { sourceMode == PhotoMotionContract.mode }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", listingID = "listing_id", expectedOrgID = "expected_org_id"
        case purpose, aspect, sources, music, presentation
        case narrationResultID = "narration_result_id", narrationAssetID = "narration_asset_id", narrationWords = "narration_words"
        case allowOriginalPhotoFallback = "allow_original_photo_fallback"
        case motionOverride = "motion_override", sourceMode = "source_mode", compositionProfile = "composition_profile", opening
    }
    var isValid: Bool {
        PhotoMotionContract.valid(self) && ["listing", "social"].contains(purpose) && aspect == (purpose == "listing" ? "16:9" : "9:16") &&
        (1...100).contains(sources.count) && Set(sources.map(\.photoID)).count == sources.count &&
        sources.allSatisfy { !$0.photoID.isEmpty && $0.photoID.utf8.count <= 200 && !$0.photoVersionID.isEmpty && $0.photoVersionID.utf8.count <= 200 && (isPhotoMotion ? PhotoMotionContract.Direction(rawValue: $0.motion) != nil : ["fly_through", "push_in", "side_glide", "pull_back"].contains($0.motion)) } &&
        (motionOverride.map { motion in
            ["fly_through", "push_in", "side_glide", "pull_back"].contains(motion) && sources.allSatisfy { $0.motion == motion }
        } ?? true) &&
        ["cut", "dissolve", "whip"].contains(presentation.transition) &&
        ["off", "lowerThird", "punchCard", "highlightBox"].contains(presentation.shotCaptionStyle) &&
        presentation.shotLabels.count == sources.count && presentation.shotLabels.allSatisfy { ($0?.utf8.count ?? 0) <= 200 } &&
        (purpose == "social" || presentation.titleCard == nil) &&
        (narrationResultID == nil || narrationAssetID == nil) &&
        (narrationWords == nil || ((narrationWords?.count ?? 0) <= 3000 && narrationWords!.allSatisfy(\.isValid)))
    }
}

enum PhotoMotionContract {
    enum Direction: String, CaseIterable, Sendable {
        case pushIn = "push_in", pullBack = "pull_back", slideLeft = "slide_left", slideRight = "slide_right"
        var title: String {
            switch self { case .pushIn: return "Push in"; case .pullBack: return "Pull back"
            case .slideLeft: return "Glide left"; case .slideRight: return "Glide right" }
        }
        var symbol: String {
            switch self { case .pushIn: return "arrow.down.right.and.arrow.up.left"; case .pullBack: return "arrow.up.left.and.arrow.down.right"
            case .slideLeft: return "arrow.left"; case .slideRight: return "arrow.right" }
        }
    }
    static let mode = "photo_motion_v1"
    enum Profile: String, CaseIterable, Sendable {
        case legacy = "photo-motion-v1-cfr24"
        case current = "photo-motion-v2-cfr24"
        case opening = "photo-motion-v2-opening-cfr24"
        var endScale: Double { self == .legacy ? 1.02 : 1.12 }
        var percent: Int { self == .legacy ? 2 : 12 }
    }
    static let profile = Profile.legacy.rawValue
    static let currentProfile = Profile.current.rawValue
    /// Omission belongs to the saved 2% contract; it never selects today's profile.
    static func resolvedProfile(_ raw: String?) -> Profile? {
        guard let raw else { return .legacy }
        return Profile(rawValue: raw)
    }
    static let frames = [48, 72, 96, 120]
    static func timingKey(photoID: String, provenanceID: String?, sha256: String) -> String {
        (try? JSONEncoder().encode([photoID, provenanceID, sha256]).base64EncodedString()) ?? ""
    }
    /// Display timing follows the exact local saved version and bytes, even
    /// when its published disclosure ID differs from its historical edit ID.
    static func restoredTimingKey(_ source: PropertyVideoJobSource, photoID: String, localVersionID: String, historicalProvenanceID: String?) -> String? {
        guard source.photoID == photoID, localVersionID == photoID,
              source.photoVersionID == "asset:" + source.photoAssetID.uuidString.lowercased(),
              frames.contains(source.visibleFrames ?? 0), let sha = source.sourceSHA256,
              sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }),
              (source.sourceBytes ?? 0) > 0, (source.sourceBytes ?? 0) <= 52_428_800 else { return nil }
        return timingKey(photoID: photoID, provenanceID: historicalProvenanceID?.lowercased(), sha256: sha)
    }
    static func valid(_ request: PropertyVideoJobRequest) -> Bool {
        guard let mode = request.sourceMode else {
            return request.opening == nil && request.compositionProfile == nil && request.sources.allSatisfy { $0.visibleFrames == nil && $0.sourceSHA256 == nil && $0.sourceBytes == nil }
        }
        guard let profile = resolvedProfile(request.compositionProfile) else { return false }
        guard (profile == .opening) == (request.opening != nil) else { return false }
        if let opening = request.opening {
            guard opening.isWellFormed, opening.source.photoProvenanceID == nil,
                  [120, 121].contains(opening.visibleFrames) else { return false }
        }
        let total = request.sources.reduce(0) { $0 + ($1.visibleFrames ?? 0) } + (request.opening?.visibleFrames ?? 0)
        return Set(request.sources.map(\.photoAssetID)).count == request.sources.count && mode == Self.mode && (request.narrationWords?.allSatisfy { $0.end <= Double(total) / 24 } ?? true) && request.presentation.transition == "cut" && !request.allowOriginalPhotoFallback &&
            request.motionOverride == nil && request.sources.allSatisfy {
                (request.photoMotionProfile == .legacy ? $0.motion == "push_in" : Direction(rawValue: $0.motion) != nil) && frames.contains($0.visibleFrames ?? 0) &&
                $0.photoVersionID == "asset:" + $0.photoAssetID.uuidString.lowercased() &&
                $0.sourceSHA256?.count == 64 && $0.sourceSHA256!.allSatisfy { "0123456789abcdef".contains($0) } &&
                ($0.sourceBytes ?? 0) > 0 && ($0.sourceBytes ?? 0) <= 52_428_800
            }
    }
    static func source(_ master: PropertyVideoChosenMaster, visibleFrames: Int, motion: String = "push_in") throws -> PropertyVideoJobSource {
        let value = PropertyVideoJobSource(photoID: master.photoID, photoAssetID: master.assetID,
            photoVersionID: "asset:" + master.assetID.uuidString.lowercased(), photoProvenanceID: master.historicalProvenanceID, motion: motion,
            visibleFrames: visibleFrames, sourceSHA256: master.sha256, sourceBytes: master.bytes)
        guard master.isValid, Direction(rawValue: motion) != nil, frames.contains(visibleFrames),
              master.sha256.count == 64, master.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              master.bytes > 0, master.bytes <= 52_428_800 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return value
    }
}

/// Read-only server catalogue proof for a full master. Local edit history IDs
/// remain local; a new Photo motion request uses this listing-bound disclosure.
struct PropertyVideoPhotoCatalogue: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        let photoID: UUID
        let assetID: UUID
        let versionID: String
        let provenanceID: UUID?
        let bytes: Int64?
        let sha256: String?
        let eligible: Bool
        let needsPreparation: Bool
        let versionKind: String
        let preparationMode: String
        enum CodingKeys: String, CodingKey {
            case photoID = "photo_id", assetID = "photo_asset_id", versionID = "photo_version_id", provenanceID = "photo_provenance_id"
            case bytes, sha256, eligible, needsPreparation = "needs_preparation", versionKind = "version_kind", preparationMode = "preparation_mode"
        }
        func source(for master: PropertyVideoChosenMaster, visibleFrames: Int, motion: String = "push_in") throws -> PropertyVideoJobSource {
            guard master.isValid, photoID == assetID, assetID == master.assetID,
                  versionID == "asset:" + master.assetID.uuidString.lowercased(), sha256 == master.sha256, bytes == master.bytes,
                  !eligible, needsPreparation, preparationMode == "chosen",
                  ["original", "declutter", "stage", "edited"].contains(versionKind),
                  versionKind == "original" ? (provenanceID == nil && master.historicalProvenanceID == nil) : (provenanceID != nil && master.historicalProvenanceID != nil) else {
                throw PropertyVideoJobStore.Failure.invalidReceipt
            }
            var source = try PhotoMotionContract.source(master, visibleFrames: visibleFrames, motion: motion)
            source = PropertyVideoJobSource(photoID: source.photoID, photoAssetID: source.photoAssetID,
                photoVersionID: source.photoVersionID, photoProvenanceID: provenanceID, motion: source.motion,
                visibleFrames: source.visibleFrames, sourceSHA256: source.sourceSHA256, sourceBytes: source.sourceBytes)
            return source
        }
    }
    let listingID: UUID
    let orgID: UUID
    let selectedLibraryOrgID: UUID
    let selectedCount: Int
    let sources: [Source]
    let nextOffset: Int?
    enum CodingKeys: String, CodingKey {
        case listingID = "listing_id", orgID = "org_id", selectedLibraryOrgID = "selected_library_org_id", selectedCount = "selected_count", sources, nextOffset = "next_offset"
    }
    func checked(context: PropertyVideoJobContext, physicalOrgID: UUID, offset: Int) throws -> Self {
        guard listingID == context.listingID, selectedLibraryOrgID == context.orgID, orgID == physicalOrgID,
              (0...1000).contains(selectedCount), offset >= 0, offset <= selectedCount,
              sources.count == min(100, selectedCount - offset),
              nextOffset == (offset + 100 < selectedCount ? offset + 100 : nil),
              Set(sources.map(\.assetID)).count == sources.count else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return self
    }
    static func resolve(_ masters: [PropertyVideoChosenMaster], frames: [Int], sources: [Source], motion: String = "push_in") throws -> [PropertyVideoJobSource] {
        guard masters.count == frames.count, Set(masters.map(\.assetID)).count == masters.count,
              Set(sources.map(\.assetID)).count == sources.count else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return try zip(masters, frames).map { master, count in
            guard let source = sources.first(where: { $0.assetID == master.assetID }) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            return try source.source(for: master, visibleFrames: count, motion: motion)
        }
    }
}

extension PropertyVideoJobSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.visibleFrames, .sourceSHA256, .sourceBytes] where c.contains(key) {
            guard try !c.decodeNil(forKey: key) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        }
        photoID = try c.decode(String.self, forKey: .photoID); photoAssetID = try c.decode(UUID.self, forKey: .photoAssetID)
        photoVersionID = try c.decode(String.self, forKey: .photoVersionID); photoProvenanceID = try c.decodeIfPresent(UUID.self, forKey: .photoProvenanceID)
        motion = try c.decode(String.self, forKey: .motion); visibleFrames = try c.decodeIfPresent(Int.self, forKey: .visibleFrames)
        sourceSHA256 = try c.decodeIfPresent(String.self, forKey: .sourceSHA256); sourceBytes = try c.decodeIfPresent(Int64.self, forKey: .sourceBytes)
    }
}
extension PropertyVideoJobRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.sourceMode, .motionOverride, .compositionProfile, .opening] where c.contains(key) {
            guard try !c.decodeNil(forKey: key) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        }
        operationID = try c.decode(UUID.self, forKey: .operationID); listingID = try c.decode(UUID.self, forKey: .listingID)
        expectedOrgID = try c.decode(UUID.self, forKey: .expectedOrgID); purpose = try c.decode(String.self, forKey: .purpose); aspect = try c.decode(String.self, forKey: .aspect)
        sources = try c.decode([PropertyVideoJobSource].self, forKey: .sources); narrationResultID = try c.decodeIfPresent(UUID.self, forKey: .narrationResultID)
        narrationAssetID = try c.decodeIfPresent(UUID.self, forKey: .narrationAssetID); narrationWords = try c.decodeIfPresent([PropertyVideoNarrationWord].self, forKey: .narrationWords)
        music = try c.decodeIfPresent(VideoMusicSelection.self, forKey: .music); presentation = try c.decode(PropertyVideoPresentation.self, forKey: .presentation)
        allowOriginalPhotoFallback = try c.decode(Bool.self, forKey: .allowOriginalPhotoFallback)
        motionOverride = try c.decodeIfPresent(String.self, forKey: .motionOverride); sourceMode = try c.decodeIfPresent(String.self, forKey: .sourceMode)
        compositionProfile = try c.decodeIfPresent(String.self, forKey: .compositionProfile)
        opening = try c.decodeIfPresent(PropertyVideoOpening.self, forKey: .opening)
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
    var sourceMode: String? = nil
    var compositionProfile: String? = nil
    enum CodingKeys: String, CodingKey {
        case consentRevision = "consent_revision", processorConsent = "processor_consent", qualityProfile = "quality_profile"
        case sourceMode = "source_mode", compositionProfile = "composition_profile"
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
        if request.isPhotoMotion {
            guard sourceMode == PhotoMotionContract.mode, compositionProfile == request.photoMotionProfile?.rawValue,
                  qualityProfile == request.photoMotionProfile?.rawValue, consentRevision == "photo-motion-v1",
                  processorConsent == nil, processorMetadataUnknown != true else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        } else if sourceMode != nil || compositionProfile != nil { throw PropertyVideoJobStore.Failure.invalidReceipt }
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
        if sourceMode == PhotoMotionContract.mode, PhotoMotionContract.Profile(rawValue: compositionProfile ?? "") != nil,
           qualityProfile == compositionProfile, consentRevision == "photo-motion-v1", processorConsent == nil { return "photo-motion-v1" }
        if !hasProcessorMetadata { return nil }
        let fal = ["legacy", "fal-kling3-4k-v1", "fal-kling3-4k-steady-v2"].contains(qualityProfile ?? "")
        if consentRevision == "property-video-jobs-v1", processorConsent == nil, fal { return "property-video-jobs-v1" }
        if consentRevision == PropertyVideoProcessorContract.known.token, processorConsent?.isKnown == true,
           fal || qualityProfile == PropertyVideoProcessorContract.known.profiles.first { return "property-video-jobs-v2" }
        return nil
    }
    /// Only a short, plain status message may reach the saved-job attention UI.
    /// Exception descriptions and provider responses are not inputs to this path.
    var boundedAttentionMessage: String? {
        guard let message, message.utf8.count <= 400,
              !message.unicodeScalars.contains(where: {
                  [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
              }) else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    var renderedSourceCount: Int { sourceMode == PhotoMotionContract.mode ? (state == "ready" ? sourceCount : 0) : (completedSources ?? 0) }
    var isTerminal: Bool { ["ready", "cancelled", "failed", "needs_reconciliation"].contains(state) }
    var mayResume: Bool { state == "failed" && resumeAvailable == true }
}


/// Malformed additive metadata must not make an otherwise usable status/cancel
/// receipt unreadable. Its authority is explicitly unknown instead.
extension PropertyVideoJobReply {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.sourceMode), try c.decodeNil(forKey: .sourceMode) { throw PropertyVideoJobStore.Failure.invalidReceipt }
        sourceMode = try c.decodeIfPresent(String.self, forKey: .sourceMode); compositionProfile = try c.decodeIfPresent(String.self, forKey: .compositionProfile)
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
        try c.encodeIfPresent(sourceMode, forKey: .sourceMode); try c.encodeIfPresent(compositionProfile, forKey: .compositionProfile)
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
    var sourceMode: String? = nil
    var compositionProfile: String? = nil
    var fps: Int? = nil
    var totalFrames: Int? = nil
    var sourceMotions: [String]? = nil
    var opening: PropertyVideoAcceptedOpening? = nil
    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id", posterAssetID = "poster_asset_id", downloadURL = "download_url", width, height
        case durationS = "duration_s", bytes, sha256, brandingPolicy = "branding_policy", sources
        case originalPhotoCount = "original_photo_count", music, opening
        case sourceMode = "source_mode", compositionProfile = "composition_profile", fps, totalFrames = "total_frames", sourceMotions = "source_motions"
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
        if request.isPhotoMotion {
            let expectedFrames = request.sources.reduce(0) { $0 + ($1.visibleFrames ?? 0) } + (request.opening?.visibleFrames ?? 0)
            guard opening?.reference == request.opening else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            if let opening {
                guard opening.hasValidMediaIdentity, [120, 121].contains(opening.availableFrames),
                      opening.aspect == request.aspect, opening.scope.listingID == request.listingID,
                      opening.scope.selectedLibraryOrgID == request.expectedOrgID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            }
            guard sourceMode == PhotoMotionContract.mode, compositionProfile == request.photoMotionProfile?.rawValue, fps == 24,
                  totalFrames == expectedFrames,
                  request.photoMotionProfile != .legacy ? sourceMotions == request.sources.map(\.motion) : sourceMotions == nil, abs(durationS - Double(expectedFrames) / 24) <= 1.0 / 24,
                  originalPhotoCount == 0 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        } else if opening != nil || sourceMode != nil || compositionProfile != nil || totalFrames != nil || sourceMotions != nil { throw PropertyVideoJobStore.Failure.invalidReceipt }
        for (source, frozen) in zip(sources, request.sources) {
            if request.isPhotoMotion {
                guard source.motionKind == "photo_motion", source.visibleFrames == frozen.visibleFrames,
                      source.sourceSHA256 == frozen.sourceSHA256, source.sourceBytes == frozen.sourceBytes,
                      source.generationRequestID == nil, source.generationProvenanceID == nil,
                      request.photoMotionProfile != .legacy ? source.motion == frozen.motion : source.motion == nil else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            } else if source.motionKind == "photo_motion" { throw PropertyVideoJobStore.Failure.invalidReceipt }
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
        if saved.request.isPhotoMotion, saved.processorPermission != nil { throw Failure.invalidReceipt }
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
        if saved.request.isPhotoMotion, saved.processorPermission != nil { throw Failure.invalidReceipt }
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

// MARK: Explicit unchanged video master (separate from local history identity)
struct PropertyVideoChosenMaster: Codable, Equatable, Sendable {
    let photoID: String
    let localVersionID: String
    let assetID: UUID
    let sha256: String
    let bytes: Int64
    let historicalProvenanceID: UUID?
    var isValid: Bool { !photoID.isEmpty && photoID.utf8.count <= 200 && !localVersionID.isEmpty && localVersionID.utf8.count <= 240 && sha256.count == 64 && sha256.allSatisfy { "0123456789abcdef".contains($0) } && bytes > 0 && bytes <= 52_428_800 }
}
struct PropertyVideoPrivateSourceRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    let listingID: UUID
    let expectedOrgID: UUID
    let photoID: String
    let photoAssetID: UUID
    let photoVersionID: String
    let photoProvenanceID: UUID?
    let sourceSHA256: String
    let sourceBytes: Int64
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", listingID = "listing_id", expectedOrgID = "expected_org_id", photoID = "photo_id", photoAssetID = "photo_asset_id", photoVersionID = "photo_version_id", photoProvenanceID = "photo_provenance_id", sourceSHA256 = "source_sha256", sourceBytes = "source_bytes"
    }
    init(operationID: UUID, context: PropertyVideoJobContext, master: PropertyVideoChosenMaster) {
        self.operationID = operationID; listingID = context.listingID; expectedOrgID = context.orgID
        photoID = master.photoID; photoAssetID = master.assetID; photoVersionID = "asset:" + master.assetID.uuidString.lowercased()
        photoProvenanceID = master.historicalProvenanceID; sourceSHA256 = master.sha256; sourceBytes = master.bytes
    }
    func matches(context: PropertyVideoJobContext, master: PropertyVideoChosenMaster) -> Bool {
        master.isValid && listingID == context.listingID && expectedOrgID == context.orgID && photoID == master.photoID && photoAssetID == master.assetID && photoVersionID == "asset:" + master.assetID.uuidString.lowercased() && photoProvenanceID == master.historicalProvenanceID && sourceSHA256 == master.sha256 && sourceBytes == master.bytes
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID); try c.encode(listingID, forKey: .listingID); try c.encode(expectedOrgID, forKey: .expectedOrgID); try c.encode(photoID, forKey: .photoID); try c.encode(photoAssetID, forKey: .photoAssetID); try c.encode(photoVersionID, forKey: .photoVersionID)
        if let photoProvenanceID { try c.encode(photoProvenanceID, forKey: .photoProvenanceID) } else { try c.encodeNil(forKey: .photoProvenanceID) }
        try c.encode(sourceSHA256, forKey: .sourceSHA256); try c.encode(sourceBytes, forKey: .sourceBytes)
    }
}
struct PropertyVideoPrivateSourceReply: Decodable, Sendable {
    struct Master: Codable, Equatable, Sendable {
        let assetID: UUID; let versionID: String; let photoID: String; let sha256: String; let bytes: Int64; let photoProvenanceID: UUID?; let sourceProvenanceID: UUID?
        enum CodingKeys: String, CodingKey { case assetID = "asset_id", versionID = "version_id", photoID = "photo_id", sha256, bytes, photoProvenanceID = "photo_provenance_id", sourceProvenanceID = "source_provenance_id" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.photoProvenanceID), c.contains(.sourceProvenanceID) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            assetID = try c.decode(UUID.self, forKey: .assetID); versionID = try c.decode(String.self, forKey: .versionID); photoID = try c.decode(String.self, forKey: .photoID); sha256 = try c.decode(String.self, forKey: .sha256); bytes = try c.decode(Int64.self, forKey: .bytes)
            photoProvenanceID = try c.decodeIfPresent(UUID.self, forKey: .photoProvenanceID); sourceProvenanceID = try c.decodeIfPresent(UUID.self, forKey: .sourceProvenanceID)
        }
    }
    struct Source: Codable, Equatable, Sendable {
        struct Preparation: Codable, Equatable, Sendable {
            let preparationID: UUID; let sourceAssetID: UUID; let sourceSHA256: String; let width: Int; let height: Int; let policy: String
            enum CodingKeys: String, CodingKey { case preparationID = "preparation_id", sourceAssetID = "source_asset_id", sourceSHA256 = "source_sha256", width, height, policy }
        }
        let photoID: String; let assetID: UUID; let versionID: String; let provenanceID: UUID?; let bytes: Int64; let sha256: String; let eligible: Bool; let preparation: Preparation
        enum CodingKeys: String, CodingKey { case photoID = "photo_id", assetID = "photo_asset_id", versionID = "photo_version_id", provenanceID = "photo_provenance_id", bytes, sha256, eligible, preparation }
    }
    let actorID: UUID; let preparationID: UUID; let operationID: UUID; let listingID: UUID; let orgID: UUID; let libraryID: UUID; let state: String; let master: Master; let source: Source?
    enum CodingKeys: String, CodingKey { case actorID = "actor_id", preparationID = "preparation_id", operationID = "operation_id", listingID = "listing_id", orgID = "org_id", libraryID = "selected_library_org_id", state, master, source }
    func checked(context: PropertyVideoJobContext, request: PropertyVideoPrivateSourceRequest, previous: Self? = nil) throws -> Self {
        guard actorID == context.actorID, operationID == request.operationID, listingID == context.listingID, libraryID == context.orgID,
              master.assetID == request.photoAssetID, master.versionID == request.photoVersionID, master.photoID == request.photoID,
              master.sha256 == request.sourceSHA256, master.bytes == request.sourceBytes, master.sourceProvenanceID == request.photoProvenanceID,
              (request.photoProvenanceID == nil) == (master.photoProvenanceID == nil),
              ["queued", "preparing", "ready", "failed"].contains(state),
              previous == nil || previous!.preparationID == preparationID && previous!.orgID == orgID && previous!.master.photoProvenanceID == master.photoProvenanceID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if state == "ready" {
            guard let s = source, s.eligible, s.assetID != master.assetID, s.photoID == request.photoID, s.versionID == request.photoVersionID, s.provenanceID == master.photoProvenanceID,
                  s.bytes > 0, s.bytes <= 8_388_608, s.sha256.count == 64, s.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  s.preparation.preparationID == preparationID, s.preparation.sourceAssetID == request.photoAssetID,
                  s.preparation.sourceSHA256 == request.sourceSHA256, s.preparation.policy == "video-jpeg-v1",
                  (1...2048).contains(s.preparation.width), (1...2048).contains(s.preparation.height) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        } else if source != nil { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return self
    }
    func jobSource(motion: String) throws -> PropertyVideoJobSource {
        guard state == "ready", let source else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return .init(photoID: master.photoID, photoAssetID: source.assetID, photoVersionID: master.versionID, photoProvenanceID: master.photoProvenanceID, motion: motion)
    }
}
