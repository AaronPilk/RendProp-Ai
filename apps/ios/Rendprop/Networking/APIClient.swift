import Foundation

struct UploadTicket: Codable {
    let id: String
    let putURL: URL?     // presigned PUT (R2/S3-style); nil in offline dev
}

/// The app talks only to this protocol. MockAPIClient makes the whole app run
/// offline; LiveAPIClient points at services/api (master spec Part 8.3).
protocol APIClient: Sendable {
    func listings() async throws -> [Listing]
    func createListing(_ listing: Listing) async throws -> Listing
    func requestUpload(filename: String, bytes: Int64) async throws -> UploadTicket
    func completeUpload(id: String, sha256: String?) async throws
    func createRender(listingID: UUID, tier: Render.Tier, durationS: Double) async throws -> Render
    func renderStatus(id: UUID) async throws -> Render
}

enum APIError: LocalizedError {
    case notConfigured
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "No API server configured — running in offline mode."
        case .badResponse(let c): return "Server returned status \(c)."
        }
    }
}
