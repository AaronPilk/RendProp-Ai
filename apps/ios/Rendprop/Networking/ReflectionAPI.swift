import Foundation

struct ReflectionQuote: Decodable, Sendable {
    let available: Bool
    let remainingClips: Int
    let maxClipSeconds: Double
    let maxBatchCents: Double
    let unitCostCents: Double

    var maximumSeconds: Double {
        guard unitCostCents.isFinite, unitCostCents > 0,
              maxBatchCents.isFinite, maxBatchCents > 0 else { return 0 }
        return maxBatchCents / unitCostCents
    }
}

struct ReflectionApplication: Decodable, Sendable {
    let disclosure: String
    let provenance: ReflectionProvenance
}

struct ReflectionProvenance: Decodable, Sendable {
    let id: String?
    let recorded: Bool
}

// Offline/older API implementations must never pretend a billable edit ran.
extension APIClient {
    func reflectionQuote(listingID: UUID) async throws -> ReflectionQuote { throw APIError.notConfigured }
    func removeReflections(assetID: String, listingID: UUID, batchID: UUID,
                           idempotencyKey: UUID) async throws -> AIVideoJob { throw APIError.notConfigured }
    func cancelReflectionBatch(_ batchID: UUID) async throws { throw APIError.notConfigured }
    func applyReflectionBatch(_ batchID: UUID, originalAssetID: String,
                              alteredAssetID: String) async throws -> ReflectionApplication { throw APIError.notConfigured }
}
