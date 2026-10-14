import Foundation
import CryptoKit

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
    var sourceBound: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case photoVersionID = "photo_version_id", photoProvenanceID = "photo_provenance_id"
        case photoAssetID = "photo_asset_id"
        case generationRequestID = "generation_request_id", generationProvenanceID = "generation_provenance_id"
        case motionKind = "motion_kind"
        case sourceBound = "source_bound"
    }
    var isComplete: Bool {
        !photoVersionID.isEmpty && photoVersionID.utf8.count <= 200 &&
        photoAssetID.flatMap(UUID.init(uuidString:)) != nil &&
        ["ai", "original_photo"].contains(motionKind) &&
        (motionKind == "original_photo" || (sourceBound == true && generationRequestID?.isEmpty == false && (generationRequestID?.utf8.count ?? 0) <= 256 && generationProvenanceID.flatMap(UUID.init(uuidString:)) != nil)) &&
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

    var canSelectForWebsite: Bool {
        schema == 1 && brandingPolicy == "unbranded" && purpose == .listing && width >= 1920 && height >= 1080 &&
        abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.01 &&
        durationS.isFinite && durationS > 0 && durationS <= 600 && bytes > 0 &&
        ownerID.flatMap(UUID.init(uuidString:)) != nil && serverListingID != nil && !includesOpeningClip &&
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
    enum CodingKeys: String, CodingKey { case schema, purpose, aspect, sources; case brandingPolicy = "branding_policy" }
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
}
