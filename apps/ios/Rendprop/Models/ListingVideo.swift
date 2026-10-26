import Foundation
import CryptoKit

/// Coordinates in the original photo's oriented raster. Preparing an opening
/// may downsample this exact rectangle, but never invent missing source pixels.
struct AerialOpeningReviewedCrop: Codable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    enum CodingKeys: String, CodingKey {
        case x, y, width, height, sourceWidth = "source_width", sourceHeight = "source_height"
    }
    func isValid(aspect: String) -> Bool {
        guard x >= 0, y >= 0, width > 0, height > 0,
              width <= sourceWidth, height <= sourceHeight,
              x <= sourceWidth - width, y <= sourceHeight - height else { return false }
        switch aspect {
        case "16:9": return width >= 1920 && height >= 1080 && width % 16 == 0 && height % 9 == 0 && width / 16 == height / 9
        case "9:16": return width >= 1080 && height >= 1920 && width % 9 == 0 && height % 16 == 0 && width / 9 == height / 16
        default: return false
        }
    }
    static func centered(sourceWidth: Int, sourceHeight: Int, aspect: String) -> Self? {
        let unit: (Int, Int)
        switch aspect {
        case "16:9": unit = (16, 9)
        case "9:16": unit = (9, 16)
        default: return nil
        }
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let count = min(sourceWidth / unit.0, sourceHeight / unit.1)
        guard count >= 120 else { return nil }
        let width = count * unit.0, height = count * unit.1
        return Self(x: (sourceWidth - width) / 2, y: (sourceHeight - height) / 2,
                    width: width, height: height, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
    func translated(x deltaX: Int, y deltaY: Int) -> Self {
        guard width > 0, height > 0, sourceWidth >= width, sourceHeight >= height else { return self }
        func bounded(_ value: Int, _ delta: Int, _ maximum: Int) -> Int {
            let sum = value.addingReportingOverflow(delta)
            return sum.overflow ? (delta < 0 ? 0 : maximum) : min(maximum, max(0, sum.partialValue))
        }
        return Self(x: bounded(x, deltaX, max(0, sourceWidth - width)),
                    y: bounded(y, deltaY, max(0, sourceHeight - height)),
                    width: width, height: height, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
}

/// A frozen source identity for an accepted opening. This value does not grant
/// permission to generate, nor does it assert that a photo shows an exterior.
/// Admission and catalogue readers must verify it against the owned source.
struct PropertyVideoOpeningSource: Codable, Hashable, Sendable {
    let photoAssetID: UUID
    let photoVersionID: String
    let photoProvenanceID: UUID?
    let sha256: String
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case photoAssetID = "photo_asset_id", photoVersionID = "photo_version_id"
        case photoProvenanceID = "photo_provenance_id", sha256, bytes
    }

    var isWellFormed: Bool {
        photoVersionID == "asset:" + photoAssetID.uuidString.lowercased() &&
        PropertyVideoOpening.isSHA256(sha256) && bytes > 0 && bytes <= 52_428_800
    }
}

extension PropertyVideoOpeningSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.photoProvenanceID) else {
            throw DecodingError.keyNotFound(CodingKeys.photoProvenanceID,
                .init(codingPath: c.codingPath, debugDescription: "Opening source provenance must be explicit, including null."))
        }
        photoAssetID = try c.decode(UUID.self, forKey: .photoAssetID)
        photoVersionID = try c.decode(String.self, forKey: .photoVersionID)
        photoProvenanceID = try c.decodeIfPresent(UUID.self, forKey: .photoProvenanceID)
        sha256 = try c.decode(String.self, forKey: .sha256)
        bytes = try c.decode(Int64.self, forKey: .bytes)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(photoAssetID.uuidString.lowercased(), forKey: .photoAssetID)
        try c.encode(photoVersionID, forKey: .photoVersionID)
        try c.encode(photoProvenanceID?.uuidString.lowercased(), forKey: .photoProvenanceID)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(bytes, forKey: .bytes)
    }
}

/// Exactly one accepted aerial may precede the photo sequence. It is kept
/// outside `sources`: photo order, timing and movement retain their identities.
/// Server admission rederives this reference from its accepted aerial record;
/// a client value, legacy raw URL or local file never establishes acceptance.
struct PropertyVideoOpening: Codable, Hashable, Sendable {
    let aerialJobID: UUID
    let assetID: UUID
    let provenanceID: UUID
    let sha256: String
    let bytes: Int64
    let visibleFrames: Int
    let source: PropertyVideoOpeningSource

    enum CodingKeys: String, CodingKey {
        case aerialJobID = "aerial_job_id", assetID = "asset_id", provenanceID = "provenance_id"
        case sha256, bytes, visibleFrames = "visible_frames", source
    }

    var isWellFormed: Bool {
        Self.isSHA256(sha256) && bytes > 0 && bytes <= 134_217_728 && [120, 121, 144, 192].contains(visibleFrames) &&
        visibleFrames <= 600 * 24 && source.isWellFormed
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

extension PropertyVideoOpening {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aerialJobID = try c.decode(UUID.self, forKey: .aerialJobID)
        assetID = try c.decode(UUID.self, forKey: .assetID)
        provenanceID = try c.decode(UUID.self, forKey: .provenanceID)
        sha256 = try c.decode(String.self, forKey: .sha256)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        visibleFrames = try c.decode(Int.self, forKey: .visibleFrames)
        source = try c.decode(PropertyVideoOpeningSource.self, forKey: .source)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(aerialJobID.uuidString.lowercased(), forKey: .aerialJobID)
        try c.encode(assetID.uuidString.lowercased(), forKey: .assetID)
        try c.encode(provenanceID.uuidString.lowercased(), forKey: .provenanceID)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(visibleFrames, forKey: .visibleFrames)
        try c.encode(source, forKey: .source)
    }
}

/// Catalogue ownership is independent of the selected library's presentation
/// scope. Both must match before an accepted server record can be used locally.
struct PropertyVideoOpeningScope: Codable, Hashable, Sendable {
    let actorID: UUID
    let orgID: UUID
    let selectedLibraryOrgID: UUID
    let listingID: UUID

    enum CodingKeys: String, CodingKey {
        case actorID = "actor_id", orgID = "org_id"
        case selectedLibraryOrgID = "selected_library_org_id", listingID = "listing_id"
    }

    func matches(actorID: UUID, physicalOrgID: UUID, selectedLibraryOrgID: UUID, listingID: UUID) -> Bool {
        self.actorID == actorID && orgID == physicalOrgID &&
        self.selectedLibraryOrgID == selectedLibraryOrgID && self.listingID == listingID
    }
}

extension PropertyVideoOpeningScope {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actorID.uuidString.lowercased(), forKey: .actorID)
        try c.encode(orgID.uuidString.lowercased(), forKey: .orgID)
        try c.encode(selectedLibraryOrgID.uuidString.lowercased(), forKey: .selectedLibraryOrgID)
        try c.encode(listingID.uuidString.lowercased(), forKey: .listingID)
    }
}

/// Returned only by the server's durable accepted-opening catalogue. Metadata
/// validation is not a substitute for that authenticated catalogue read, and
/// this value contains no download URL or client-controlled acceptance flag.
struct PropertyVideoAcceptedOpening: Codable, Hashable, Sendable {
    let schema: Int
    let kind: String
    let reference: PropertyVideoOpening
    let position: Int
    let scope: PropertyVideoOpeningScope
    let aspect: String
    let fps: Int
    let availableFrames: Int
    let width: Int
    let height: Int
    let durationS: Double
    let disclosure: String
    let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case schema, kind, position, scope, aspect, fps, width, height, disclosure
        case availableFrames = "available_frames", durationS = "duration_s", acceptedAt = "accepted_at"
    }

    var hasValidMediaIdentity: Bool {
        let dimensions: (Int, Int)
        switch aspect {
        case "16:9": dimensions = (1920, 1080)
        case "9:16": dimensions = (1080, 1920)
        default: return false
        }
        guard acceptedAt.utf8.count <= 64 else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let acceptedDate = fractional.date(from: acceptedAt) ?? ISO8601DateFormatter().date(from: acceptedAt)
        return schema == 1 && kind == "aerial_opening" && position == 0 &&
            reference.isWellFormed && fps == 24 && [120, 121, 144, 192].contains(availableFrames) &&
            reference.visibleFrames == availableFrames && width == dimensions.0 && height == dimensions.1 &&
            durationS.isFinite && durationS == Double(availableFrames) / 24 &&
            !disclosure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            disclosure.utf16.count <= 2000 && !disclosure.unicodeScalars.contains(where: { $0.value < 32 }) && acceptedDate != nil
    }

    func checked(actorID: UUID, physicalOrgID: UUID, selectedLibraryOrgID: UUID, listingID: UUID, aspect: String) throws -> Self {
        guard hasValidMediaIdentity, self.aspect == aspect,
              scope.matches(actorID: actorID, physicalOrgID: physicalOrgID, selectedLibraryOrgID: selectedLibraryOrgID, listingID: listingID) else {
            throw ListingVideoStore.Failure.invalidRecord
        }
        return self
    }
}

extension PropertyVideoAcceptedOpening {
    init(from decoder: Decoder) throws {
        reference = try PropertyVideoOpening(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        kind = try c.decode(String.self, forKey: .kind)
        position = try c.decode(Int.self, forKey: .position)
        scope = try c.decode(PropertyVideoOpeningScope.self, forKey: .scope)
        aspect = try c.decode(String.self, forKey: .aspect)
        fps = try c.decode(Int.self, forKey: .fps)
        availableFrames = try c.decode(Int.self, forKey: .availableFrames)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        durationS = try c.decode(Double.self, forKey: .durationS)
        disclosure = try c.decode(String.self, forKey: .disclosure)
        acceptedAt = try c.decode(String.self, forKey: .acceptedAt)
    }

    func encode(to encoder: Encoder) throws {
        try reference.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(kind, forKey: .kind)
        try c.encode(position, forKey: .position)
        try c.encode(scope, forKey: .scope)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(fps, forKey: .fps)
        try c.encode(availableFrames, forKey: .availableFrames)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(disclosure, forKey: .disclosure)
        try c.encode(acceptedAt, forKey: .acceptedAt)
    }
}


enum VideoBrandingPolicy {
    /// Historical recovered settings can carry a title/mark; listing masters
    /// suppress them at the final compose boundary, regardless of saved UI state.
    static func titleCard<T>(_ requested: T?, aspect: String) -> T? {
        aspect == "9:16" ? requested : nil
    }
}

/// Immutable local identity for a finished photo video. This is a recipe and
/// publication choice, never server media authority or an automatic publish.
struct ListingVideoSource: Codable, Hashable, Sendable {
    let photoVersionID: String
    var photoAssetID: String? = nil
    var photoProvenanceID: String? = nil
    var generationRequestID: String? = nil
    var generationProvenanceID: String? = nil
    var motionKind: String = "ai"
    var motion: String? = nil
    var sourceBound: Bool? = nil
    var visibleFrames: Int? = nil
    var sourceSHA256: String? = nil
    var sourceBytes: Int64? = nil
    enum CodingKeys: String, CodingKey {
        case photoVersionID = "photo_version_id", photoProvenanceID = "photo_provenance_id"
        case photoAssetID = "photo_asset_id"
        case generationRequestID = "generation_request_id", generationProvenanceID = "generation_provenance_id"
        case motionKind = "motion_kind"
        case motion
        case sourceBound = "source_bound"
        case visibleFrames = "visible_frames", sourceSHA256 = "source_sha256", sourceBytes = "source_bytes"
    }
    var isComplete: Bool {
        !photoVersionID.isEmpty && photoVersionID.utf8.count <= 200 &&
        photoAssetID.flatMap(UUID.init(uuidString:)) != nil &&
        ["ai", "original_photo", "photo_motion"].contains(motionKind) &&
        (motionKind == "photo_motion" ? (sourceBound == true && generationRequestID == nil && generationProvenanceID == nil &&
            [48,72,96,120].contains(visibleFrames ?? 0) && sourceSHA256?.count == 64 && sourceSHA256!.allSatisfy { "0123456789abcdef".contains($0) } &&
            (sourceBytes ?? 0) > 0 && (sourceBytes ?? 0) <= 52_428_800) : (motionKind == "original_photo" || (sourceBound == true && generationRequestID?.isEmpty == false && (generationRequestID?.utf8.count ?? 0) <= 256 && generationProvenanceID.flatMap(UUID.init(uuidString:)) != nil))) &&
        (photoProvenanceID == nil || photoProvenanceID.flatMap(UUID.init(uuidString:)) != nil)
    }
}

struct ListingVideoRecord: Codable, Hashable, Sendable, Identifiable {
    var schema = 1
    let id: UUID
    let listingID: UUID
    let ownerID: String?
    let workspaceID: UUID?
    let serverListingID: UUID?
    let relativePath: String
    let purpose: VideoAspectChoice
    let width: Int
    let height: Int
    let durationS: Double
    let bytes: Int64
    let sha256: String
    let sources: [ListingVideoSource]
    let includesOpeningClip: Bool
    let createdAt: Date
    var brandingPolicy: String? = nil
    var music: VideoMusicSelection? = nil
    var sourceMode: String? = nil
    var compositionProfile: String? = nil
    var fps: Int? = nil
    var totalFrames: Int? = nil
    var sourceMotions: [String]? = nil
    var opening: PropertyVideoAcceptedOpening? = nil
    var hasValidMotionIdentity: Bool {
        if sourceMode == "photo_motion_v1" {
            let frames = sources.reduce(0) { $0 + ($1.visibleFrames ?? 0) } + (opening?.reference.visibleFrames ?? 0)
            let composite = compositionProfile == "photo-motion-v2-opening-cfr24"
            guard composite == (opening != nil), includesOpeningClip == composite else { return false }
            if let opening {
                guard opening.hasValidMediaIdentity, [120, 121].contains(opening.availableFrames),
                      opening.scope.actorID == ownerID.flatMap(UUID.init(uuidString:)),
                      opening.scope.selectedLibraryOrgID == workspaceID, opening.scope.listingID == serverListingID,
                      opening.aspect == (purpose == .listing ? "16:9" : "9:16") else { return false }
            }
            return ["photo-motion-v1-cfr24", "photo-motion-v2-cfr24", "photo-motion-v2-opening-cfr24"].contains(compositionProfile ?? "") && fps == 24 && totalFrames == frames &&
                (compositionProfile != "photo-motion-v1-cfr24" ? sourceMotions == sources.compactMap(\.motion) && sourceMotions?.count == sources.count : sourceMotions == nil) &&
                abs(durationS - Double(frames) / 24) <= 1.0 / 24 && sources.allSatisfy {
                    $0.motionKind == "photo_motion" && $0.isComplete &&
                    (compositionProfile != "photo-motion-v1-cfr24" ? ["push_in", "pull_back", "slide_left", "slide_right"].contains($0.motion ?? "") : $0.motion == nil)
                }
        }
        return opening == nil && sourceMode == nil && compositionProfile == nil && totalFrames == nil && sourceMotions == nil && sources.allSatisfy { $0.motionKind != "photo_motion" }
    }

    /// Playback describes this immutable output, never today's draft profile.
    var savedPlaybackMotionLabel: String? {
        guard sourceMode == "photo_motion_v1" else { return nil }
        guard hasValidMotionIdentity else { return "Photo motion · Motion details unavailable" }
        if compositionProfile == "photo-motion-v1-cfr24" { return "Photo motion · 2% zoom" }
        let directions = Set(sourceMotions ?? [])
        switch directions.count == 1 ? directions.first : nil {
        case "push_in": return "Photo motion · Push in · 12%"
        case "pull_back": return "Photo motion · Pull back · 12%"
        case "slide_left": return "Photo motion · Glide left · 12%"
        case "slide_right": return "Photo motion · Glide right · 12%"
        default: return "Photo motion · Mixed directions · 12%"
        }
    }

    var canSelectForWebsite: Bool {
        hasValidMotionIdentity && schema == 1 && brandingPolicy == "unbranded" && purpose == .listing && width >= 1920 && height >= 1080 &&
        abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.01 &&
        durationS.isFinite && durationS > 0 && durationS <= 600 && bytes > 0 &&
        ownerID.flatMap(UUID.init(uuidString:)) != nil && serverListingID != nil && (!includesOpeningClip || opening != nil) &&
        (1...VideoSelectionCapacity.maximumPhotos).contains(sources.count) && sources.allSatisfy(\.isComplete)
    }
}

/// A publication action is different from an immutable encoded output. One
/// saved action survives lost replies; a later explicit selection gets a new ID.
struct ListingVideoPublication: Codable, Hashable, Sendable {
    let operationID: UUID
    let record: ListingVideoRecord
    let createdAt: Date
    var posterAssetID: String? = nil
    var outputAssetID: String? = nil
}

/// The output and its first-frame cover keep one server identity across
/// explicit reselections. Publication operations remain separate retry receipts.
struct ListingVideoUploadedAssets: Codable, Hashable, Sendable {
    let record: ListingVideoRecord
    let outputAssetID: String
    let posterAssetID: String
}

enum ListingVideoStore {
    enum Failure: Error, LocalizedError {
        case invalidRecord, missingOutput, changedOutput, incompleteLineage
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "This saved video doesn't match the listing. Its file has been kept."
            case .missingOutput: return "The selected listing video isn't on this phone. Choose another saved video."
            case .changedOutput: return "The selected video's file changed. Review and select the finished video again."
            case .incompleteLineage: return "This video can be saved or shared, but its source history isn't complete enough to publish on the listing website. Make a new Listing video from reviewed photos."
            }
        }
    }
    static func metadataURL(for video: URL) -> URL { video.appendingPathExtension("listing-video.json") }
    static func fileURL(_ record: ListingVideoRecord, documents: URL) throws -> URL {
        guard !record.relativePath.hasPrefix("/"), !record.relativePath.split(separator: "/").contains(".."),
              record.relativePath.hasPrefix("reels/"), record.relativePath.hasSuffix(".mp4") else { throw Failure.invalidRecord }
        let url = documents.appendingPathComponent(record.relativePath).standardizedFileURL
        guard url.deletingLastPathComponent() == documents.appendingPathComponent("reels").standardizedFileURL,
              url.lastPathComponent.lowercased().hasPrefix(record.listingID.uuidString.lowercased() + "-") else { throw Failure.invalidRecord }
        return url
    }
    static func load(for video: URL) throws -> ListingVideoRecord {
        let metadata = metadataURL(for: video)
        guard let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 131072 else { throw Failure.invalidRecord }
        let record = try JSONDecoder().decode(ListingVideoRecord.self, from: Data(contentsOf: metadata))
        guard record.schema == 1, record.sources.count <= VideoSelectionCapacity.maximumPhotos,
              record.sha256.count == 64, record.sha256.allSatisfy({ $0.isHexDigit }),
              video.lastPathComponent == URL(fileURLWithPath: record.relativePath).lastPathComponent else { throw Failure.invalidRecord }
        return record
    }
    static func save(_ record: ListingVideoRecord, documents: URL) throws {
        let video = try fileURL(record, documents: documents)
        guard ((try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == Int(record.bytes) else { throw Failure.missingOutput }
        let bytes = try JSONEncoder().encode(record), target = metadataURL(for: video)
        guard bytes.count <= 131072 else { throw Failure.invalidRecord }
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidRecord }
    }
    static func validate(_ record: ListingVideoRecord, documents: URL, listingID: UUID, ownerID: String?, workspaceID: UUID?, serverListingID: UUID?) throws -> URL {
        guard record.listingID == listingID, record.ownerID == ownerID, record.workspaceID == workspaceID,
              record.serverListingID == serverListingID else { throw Failure.invalidRecord }
        guard record.canSelectForWebsite else { throw Failure.incompleteLineage }
        let url = try fileURL(record, documents: documents)
        guard (try? load(for: url)) == record else { throw Failure.changedOutput }
        guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == Int(record.bytes) else { throw Failure.missingOutput }
        guard try digest(url) == record.sha256 else { throw Failure.changedOutput }
        return url
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1048576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Selection is a durable pin independent of the listing's UI snapshot;
    /// background pruning never consults an actor or deletes the chosen file.
    static func selectedFile(listingID: UUID, documents: URL) -> URL {
        documents.appendingPathComponent("reels/\(listingID.uuidString)-website-selection.json")
    }
    static func select(_ record: ListingVideoRecord, documents: URL) throws {
        guard record.canSelectForWebsite else { throw Failure.incompleteLineage }
        let bytes = try JSONEncoder().encode(record), target = selectedFile(listingID: record.listingID, documents: documents)
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidRecord }
    }
    static func selected(listingID: UUID, documents: URL) -> ListingVideoRecord? {
        let url = selectedFile(listingID: listingID, documents: documents)
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0, bytes <= 131072,
              let data = try? Data(contentsOf: url), data.count <= 131072,
              let record = try? JSONDecoder().decode(ListingVideoRecord.self, from: data), record.listingID == listingID else { return nil }
        return record
    }

    static func pendingFile(listingID: UUID, documents: URL) -> URL {
        documents.appendingPathComponent("reels/\(listingID.uuidString)-website-publish.json")
    }
    static func pending(listingID: UUID, documents: URL) throws -> ListingVideoRecord? {
        try publication(listingID: listingID, documents: documents)?.record
    }
    static func publication(listingID: UUID, documents: URL) throws -> ListingVideoPublication? {
        let url = pendingFile(listingID: listingID, documents: documents)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0, bytes <= 131072 else { throw Failure.invalidRecord }
        let publication = try JSONDecoder().decode(ListingVideoPublication.self, from: Data(contentsOf: url))
        guard publication.record.listingID == listingID, publication.record.canSelectForWebsite,
              publication.posterAssetID == nil || publication.posterAssetID.flatMap(UUID.init(uuidString:)) != nil,
              publication.outputAssetID == nil || publication.outputAssetID.flatMap(UUID.init(uuidString:)) != nil else { throw Failure.invalidRecord }
        return publication
    }
    static func beginPublication(_ record: ListingVideoRecord, documents: URL) throws -> ListingVideoPublication {
        if let existing = try publication(listingID: record.listingID, documents: documents) {
            guard existing.record == record else { throw Failure.invalidRecord }
            return existing
        }
        let uploaded = try uploadedAssets(for: record, documents: documents)
        let publication = ListingVideoPublication(operationID: UUID(), record: record, createdAt: Date(),
            posterAssetID: uploaded?.posterAssetID, outputAssetID: uploaded?.outputAssetID)
        try savePublication(publication, documents: documents)
        return publication
    }
    static func savePublication(_ publication: ListingVideoPublication, documents: URL) throws {
        if let saved = try self.publication(listingID: publication.record.listingID, documents: documents) {
            guard saved.operationID == publication.operationID, saved.record == publication.record else { throw Failure.invalidRecord }
        }
        let data = try JSONEncoder().encode(publication), target = pendingFile(listingID: publication.record.listingID, documents: documents)
        try data.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == data else { throw Failure.invalidRecord }
    }
    static func uploadedAssets(for record: ListingVideoRecord, documents: URL) throws -> ListingVideoUploadedAssets? {
        let target = try fileURL(record, documents: documents).appendingPathExtension("website-assets.json")
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard let count = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0, count <= 131072 else { throw Failure.invalidRecord }
        let receipt = try JSONDecoder().decode(ListingVideoUploadedAssets.self, from: Data(contentsOf: target))
        guard receipt.record == record, UUID(uuidString: receipt.outputAssetID) != nil,
              UUID(uuidString: receipt.posterAssetID) != nil else { throw Failure.invalidRecord }
        return receipt
    }
    static func retainServerAssets(_ record: ListingVideoRecord, outputAssetID: String, posterAssetID: String, documents: URL) throws {
        let receipt = ListingVideoUploadedAssets(record: record, outputAssetID: outputAssetID, posterAssetID: posterAssetID)
        guard UUID(uuidString: outputAssetID) != nil, UUID(uuidString: posterAssetID) != nil else { throw Failure.invalidRecord }
        if let existing = try uploadedAssets(for: record, documents: documents), existing != receipt { throw Failure.invalidRecord }
        let target = try fileURL(record, documents: documents).appendingPathExtension("website-assets.json")
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 131072 else { throw Failure.invalidRecord }
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidRecord }
    }
    static func retainUploadedAssets(_ publication: ListingVideoPublication, documents: URL) throws {
        guard let output = publication.outputAssetID, let poster = publication.posterAssetID,
              UUID(uuidString: output) != nil, UUID(uuidString: poster) != nil else { throw Failure.invalidRecord }
        let receipt = ListingVideoUploadedAssets(record: publication.record, outputAssetID: output, posterAssetID: poster)
        if let existing = try uploadedAssets(for: publication.record, documents: documents), existing != receipt { throw Failure.invalidRecord }
        let target = try fileURL(publication.record, documents: documents).appendingPathExtension("website-assets.json")
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 131072 else { throw Failure.invalidRecord }
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidRecord }
    }
    static func finishPublication(_ record: ListingVideoRecord, operationID: UUID, documents: URL) throws {
        guard let saved = try publication(listingID: record.listingID, documents: documents),
              saved.record.id == record.id, saved.operationID == operationID else { return }
        try FileManager.default.removeItem(at: pendingFile(listingID: record.listingID, documents: documents))
    }
}

struct ListingVideoComposition: Codable, Sendable {
    var schema = 1
    var purpose = "listing"
    var aspect = "16:9"
    var brandingPolicy = "unbranded"
    enum CodingKeys: String, CodingKey { case schema, purpose, aspect, sources, opening; case brandingPolicy = "branding_policy"; case sourceMode = "source_mode", compositionProfile = "composition_profile", fps, totalFrames = "total_frames" }
    var sourceMode: String? = nil
    var compositionProfile: String? = nil
    var fps: Int? = nil
    var totalFrames: Int? = nil
    var opening: PropertyVideoAcceptedOpening? = nil
    let sources: [ListingVideoSource]
    init(sources: [ListingVideoSource]) {
        self.sources = sources.map { retained in
            var source = retained
            // Failed/unbound AI is local audit context, not a deliverable.
            // Original-photo motion publishes the registered photo lineage.
            if source.motionKind == "original_photo", source.sourceBound != true {
                source.generationRequestID = nil
                source.generationProvenanceID = nil
            }
            return source
        }
    }
    init(record: ListingVideoRecord) {
        self.init(sources: record.sources)
        sourceMode = record.sourceMode; compositionProfile = record.compositionProfile
        fps = record.fps; totalFrames = record.totalFrames; opening = record.opening
    }

}

/// Completed work only: these fractions are not supplier percentages or an ETA.
struct NativeGenerationProgress: Equatable {
    /// Five completed aerial stages; queued_input has completed none of them.
    static let aerialTotal = 5
    static let aerialProgressVersion = 2
    let completed: Int?
    let total: Int?
    let unit: String
    let phase: String
    let active: Bool
    let lastCheckedAt: Date?
    let lastProgressAt: Date?
    let checksExpected: Bool
    let checkFailed: Bool
    var percent: Int? {
        guard let completed, let total, total > 0, completed >= 0, completed <= total else { return nil }
        return Int((Double(completed) / Double(total) * 100).rounded())
    }
    func checkIsStale(at now: Date) -> Bool {
        checksExpected && active && (lastCheckedAt.map { now.timeIntervalSince($0) > 60 } ?? true)
    }
    func canIndicateLive(at now: Date) -> Bool { active && !checkFailed && !checkIsStale(at: now) }
    static func steps(kind: String, phase: String?) -> Int? {
        if kind == "aerial" {
            switch phase {
            case "queued_input", "preparing_input": return 0
            case "queued_assessment", "checking_source": return 1
            case "queued_generation", "dispatching", "processing": return 2
            case "queued_qualification", "qualifying": return 3
            case "queued_quality", "checking_quality": return 4
            case "ready_for_acceptance", "accepted": return aerialTotal
            default: return nil
            }
        }
        if kind == "photo_motion" {
            switch phase { case "queued", "generating": return 1; case "quality_review", "composing": return 2; case "ready": return 3; default: return nil }
        }
        if kind == "video" {
            switch phase { case "queued": return 1; case "generating": return 2; case "quality_review": return 3; case "composing": return 4; case "ready": return 5; default: return nil }
        }
        return nil
    }
    static func stepTotal(kind: String?) -> Int? {
        switch kind { case "aerial": return aerialTotal; case "photo_motion": return 3; case "video": return 5; default: return nil }
    }
    /// Build 119 saved aerial counts on a 1...6 scale. Keep their high-water
    /// mark when restoring a request, but never mistake one for a new count.
    static func normalizedAerialMilestone(_ saved: Int?, version: Int?) -> Int? {
        guard let saved else { return nil }
        if version == aerialProgressVersion { return (0...aerialTotal).contains(saved) ? saved : nil }
        return (1...(aerialTotal + 1)).contains(saved) ? saved - 1 : nil
    }
    static func retained(previous: Int?, incoming: Int?, incomplete: Bool, total: Int) -> Int? {
        let value = [previous, incoming].compactMap { $0 }.max()
        guard let value, value >= 0, value <= total, !incomplete || value < total else { return nil }
        return value
    }
    static func aerialPhase(_ raw: String?) -> String {
        switch raw {
        case "queued_input": return "Waiting for processor · photo preparation"
        case "preparing_input": return "Preparing photo"
        case "queued_assessment": return "Waiting for processor · exterior check"
        case "checking_source": return "Checking exterior photo"
        case "queued_generation": return "Waiting for processor · opening generation"
        case "dispatching", "processing": return "Generating opening"
        case "queued_qualification": return "Waiting for processor · video preparation"
        case "qualifying": return "Preparing opening video"
        case "queued_quality": return "Waiting for processor · video checks"
        case "checking_quality": return "Checking opening video"
        case "ready_for_acceptance": return "Ready to review"
        case "accepted": return "Opening saved"
        case "failed", "ineligible": return "Opening needs attention"
        case "cancelled": return "Opening stopped"
        default: return "Checking saved request"
        }
    }
}
