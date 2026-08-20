import Foundation

struct UploadTicket: Codable {
    let id: String       // server capture_assets id (contract: asset_id)
    let putURL: URL?     // presigned PUT (R2/S3-style); nil in offline dev
    /// R2 object key the file lands at (contract: storage_key). Optional so the
    /// offline Mock and any legacy decode still work.
    var storageKey: String? = nil
}

/// This-month usage/cost rollup for the signed-in org (contract: GET /me → usage).
struct UsageSummary: Codable, Hashable {
    var aiSpendCents: Int? = nil   // usage.ai_spend_cents
    var renderCount: Int? = nil    // usage.render_count
    var leadCount: Int? = nil      // usage.lead_count
    var planName: String? = nil    // plan.name

    /// AI spend as Money (integer-cents guardrail). Zero when unknown.
    var aiSpend: Money { Money(cents: aiSpendCents ?? 0) }
}

/// The app talks only to this protocol. MockAPIClient makes the whole app run
/// offline; LiveAPIClient points at the Supabase Edge Functions API
/// (docs/BACKEND-ARCHITECTURE.md §2).
protocol APIClient: Sendable {
    func listings() async throws -> [Listing]
    func createListing(_ listing: Listing) async throws -> Listing
    func updateListing(_ listing: Listing) async throws -> Listing
    /// POST /uploads → presigned R2 PUT + storage_key + asset_id. `listingID`,
    /// `sha256`, and `kind` complete the contract body; all optional-friendly so
    /// callers that only have a file can still request a ticket.
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String) async throws -> UploadTicket
    func completeUpload(id: String, sha256: String?) async throws
    /// POST /renders — the contract REQUIRES `asset_id`, so it flows through here.
    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render
    func renderStatus(id: UUID) async throws -> Render
    /// GET /me — usage/cost for the Settings "Usage" section.
    func me() async throws -> UsageSummary
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
