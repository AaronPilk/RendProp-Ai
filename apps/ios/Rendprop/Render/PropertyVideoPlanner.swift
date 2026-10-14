import Foundation
import CryptoKit

/// Visual scene labels are editing hints, never measured rooms or a connected
/// route. Closed values keep model prose out of generation prompts and captions.
enum PropertyVideoScene: String, Codable, CaseIterable, Sendable {
    case frontExterior = "front_exterior", entry, living, kitchen, dining, bedroom, bathroom, outdoor
    case rearExterior = "rear_exterior", detail, unknown
    var rank: Int {
        switch self {
        case .frontExterior: return 0; case .entry: return 1; case .living: return 2
        case .kitchen: return 3; case .dining: return 4; case .bedroom: return 5
        case .bathroom: return 6; case .outdoor: return 7; case .rearExterior: return 8
        case .detail: return 9; case .unknown: return 10
        }
    }
    var caption: String? {
        switch self {
        case .frontExterior: return "WELCOME HOME"; case .entry: return "STEP INSIDE"
        case .living: return "LIVING SPACE"; case .kitchen: return "THE KITCHEN"
        case .dining: return "DINING SPACE"; case .bedroom: return "BEDROOM"
        case .bathroom: return "BATHROOM"; case .outdoor: return "OUTDOOR SPACE"
        case .rearExterior: return "THE BACKYARD"; case .detail, .unknown: return nil
        }
    }
}
enum PropertyVideoMotion: String, Codable, Sendable {
    case flyThrough = "fly_through", pushIn = "push_in", sideGlide = "side_glide", pullBack = "pull_back"
    var dispatchValue: String { rawValue }
}
struct PropertyVideoPlanPhoto: Codable, Hashable, Sendable {
    let photoID: String
    let assetID: UUID
    enum CodingKeys: String, CodingKey { case photoID = "photo_id", assetID = "asset_id" }
}
struct PropertyVideoSceneRow: Codable, Hashable, Sendable {
    let photoID: String
    let assetID: UUID
    let scene: PropertyVideoScene
    let confidence: Double
    let motion: PropertyVideoMotion
    let seconds: Double
    enum CodingKeys: String, CodingKey { case photoID = "photo_id", assetID = "asset_id", scene, confidence, motion, seconds }
    var confident: Bool { confidence > 0.6 && scene != .unknown }
    var dispatchMotion: String { confident ? motion.dispatchValue : "push_in" }
}
struct PropertyVideoPlanReply: Codable, Sendable {
    let schema: Int
    let listingID: UUID
    let orgID: UUID
    let photos: [PropertyVideoSceneRow]
    let model: String
    enum CodingKeys: String, CodingKey { case schema, listingID = "listing_id", orgID = "org_id", photos, model }
    func checked(listingID: UUID, orgID: UUID, requested: [PropertyVideoPlanPhoto]) throws -> [PropertyVideoSceneRow] {
        guard schema == 1, self.listingID == listingID, self.orgID == orgID,
              photos.count == requested.count, (1...20).contains(photos.count),
              Set(photos.map(\.photoID)).count == photos.count,
              zip(photos, requested).allSatisfy({ $0.photoID == $1.photoID && $0.assetID == $1.assetID }),
              photos.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) && $0.seconds == 5 }) else {
            throw PropertyVideoPlanner.Failure.invalidReply
        }
        return photos
    }
}
protocol PropertyVideoPlanningAPI: AnyObject {
    @MainActor func propertyVideoPlan(listingID: UUID, orgID: UUID, photos: [PropertyVideoPlanPhoto],
                           idempotencyKey: String) async throws -> PropertyVideoPlanReply
}

enum PropertyVideoPlanner {
    enum Failure: Error { case invalidInput, invalidReply }
    struct Context: Codable, Hashable, Sendable {
        let ownerID: UUID
        let orgID: UUID
        let listingID: UUID
    }
    struct Input: Codable, Hashable, Sendable {
        let photoID: String
        let assetID: UUID
        let jpegDigest: String
    }
    struct Planned: Codable, Hashable, Sendable {
        let input: Input
        let scene: PropertyVideoScene
        let confidence: Double
        let motion: String
        var confident: Bool { confidence > 0.6 && scene != .unknown }
        var caption: String? { confident ? scene.caption : nil }
    }
    struct Result: Sendable {
        let photos: [Planned]
        let usedFallback: Bool
        let classifiedBatches: Int
        var notice: String {
            usedFallback ? "Automatic scene planning wasn't available. Keeping all photos in your selected order with restrained motion."
                : "Scenes planned automatically. Every selected photo is kept; uncertain scenes retain their position."
        }
    }
    private struct Cache: Codable {
        let schema: Int
        let context: Context
        let input: Input
        let row: PropertyVideoSceneRow
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func stableBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func cacheURL(_ input: Input, context: Context, documents: URL) throws -> URL {
        let key = try stableBytes([context.ownerID.uuidString, context.orgID.uuidString, context.listingID.uuidString, input.photoID, input.jpegDigest])
        return documents.appendingPathComponent("reels/\(context.listingID.uuidString)-scene-plan", isDirectory: true)
            .appendingPathComponent(digest(key) + ".json")
    }
    private static func cached(_ input: Input, context: Context, documents: URL) -> PropertyVideoSceneRow? {
        guard let target = try? cacheURL(input, context: context, documents: documents),
              let count = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0, count <= 16384,
              let bytes = try? Data(contentsOf: target), let saved = try? JSONDecoder().decode(Cache.self, from: bytes),
              saved.schema == 1, saved.context == context, saved.input.photoID == input.photoID,
              saved.input.jpegDigest == input.jpegDigest,
              saved.row.photoID == input.photoID, saved.row.assetID == saved.input.assetID,
              saved.row.confidence.isFinite && (0...1).contains(saved.row.confidence), saved.row.seconds == 5 else { return nil }
        // Reusing a visual decision for identical prepared bytes does not assert
        // that an old upload is still owned. Generation uses the NEW exact input.
        return PropertyVideoSceneRow(photoID: input.photoID, assetID: input.assetID, scene: saved.row.scene,
            confidence: saved.row.confidence, motion: saved.row.motion, seconds: saved.row.seconds)
    }
    private static func save(_ row: PropertyVideoSceneRow, input: Input, context: Context, documents: URL) throws {
        let target = try cacheURL(input, context: context, documents: documents)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try stableBytes(Cache(schema: 1, context: context, input: input, row: row))
        guard bytes.count <= 16384 else { throw Failure.invalidInput }
        try bytes.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == bytes else { throw Failure.invalidInput }
    }
    static func ordered(_ photos: [Planned], automatic: Bool) -> [Planned] {
        guard automatic else { return photos }
        let sorted = photos.enumerated().filter { $0.element.confident }.sorted {
            $0.element.scene.rank == $1.element.scene.rank ? $0.offset < $1.offset : $0.element.scene.rank < $1.element.scene.rank
        }.map(\.element)
        var iterator = sorted.makeIterator()
        // Unknown/low-confidence photos stay in their original absolute slots.
        // Confident scenes are globally ranked; equal scenes remain stable.
        return photos.map { $0.confident ? iterator.next()! : $0 }
    }
    static func plan(inputs: [Input], context: Context, api: PropertyVideoPlanningAPI?, automaticOrder: Bool,
                     documents: URL, requireCurrent: @MainActor @Sendable () throws -> Void) async throws -> Result {
        try await requireCurrent()
        guard (1...VideoSelectionCapacity.maximumPhotos).contains(inputs.count),
              Set(inputs.map(\.photoID)).count == inputs.count,
              inputs.allSatisfy({ !$0.photoID.isEmpty && $0.photoID.utf8.count <= 200 && $0.jpegDigest.count == 64 && $0.jpegDigest.allSatisfy(\.isHexDigit) }) else { throw Failure.invalidInput }
        func fallback() -> Result {
            Result(photos: inputs.map { Planned(input: $0, scene: .unknown, confidence: 0, motion: "push_in") },
                usedFallback: true, classifiedBatches: 0)
        }
        var rows: [String: PropertyVideoSceneRow] = [:]
        for input in inputs { if let cached = cached(input, context: context, documents: documents) { rows[input.photoID] = cached } }
        let missing = inputs.filter { rows[$0.photoID] == nil }
        guard missing.isEmpty || api != nil else { return fallback() }
        var calls = 0
        do {
            for start in stride(from: 0, to: missing.count, by: 20) {
                try await requireCurrent()
                let group = Array(missing[start..<min(start + 20, missing.count)])
                let requested = group.map { PropertyVideoPlanPhoto(photoID: $0.photoID, assetID: $0.assetID) }
                let key = digest(try stableBytes(["property-video-plan-v1", context.ownerID.uuidString,
                    context.orgID.uuidString, context.listingID.uuidString] + group.map { "\($0.photoID)|\($0.assetID)|\($0.jpegDigest)" }))
                let reply = try await api!.propertyVideoPlan(listingID: context.listingID, orgID: context.orgID,
                    photos: requested, idempotencyKey: "property-video-plan:" + key)
                try await requireCurrent()
                let checked = try reply.checked(listingID: context.listingID, orgID: context.orgID, requested: requested)
                for (row, input) in zip(checked, group) { try save(row, input: input, context: context, documents: documents); rows[input.photoID] = row }
                calls += 1
            }
        } catch {
            try await requireCurrent() // Never turn revocation/account changes into a fresh fallback run.
            if error is CancellationError { throw error }
            return fallback() // One refusal/malformed batch ends planning; no automatic retry or partial reorder.
        }
        try await requireCurrent()
        let planned = inputs.map { input -> Planned in
            let row = rows[input.photoID]!
            return Planned(input: input, scene: row.scene, confidence: row.confidence, motion: row.dispatchMotion)
        }
        return Result(photos: ordered(planned, automatic: automaticOrder), usedFallback: false, classifiedBatches: calls)
    }
}
