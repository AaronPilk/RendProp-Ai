import Foundation

/// Fully offline API — believable sample data + simulated render progress.
/// The app runs end-to-end on-device with no backend.
actor MockAPIClient: APIClient {
    private var renders: [UUID: (render: Render, startedAt: Date)] = [:]

    private static let sampleListings: [Listing] = [
        Listing(address: "1247 Hillcrest Drive (Sample)", beds: 4, baths: 3, sqft: 2850,
                price: .dollars(1_175_000), status: .ready, isSample: true,
                createdAt: Date().addingTimeInterval(-86_400 * 2)),
        Listing(address: "88 Marina Vista #501 (Sample)", beds: 2, baths: 2, sqft: 1240,
                price: .dollars(689_000), status: .processing, isSample: true,
                createdAt: Date().addingTimeInterval(-3_600 * 5)),
    ]

    func listings() async throws -> [Listing] {
        try? await Task.sleep(nanoseconds: 350_000_000) // feel like a network
        return Self.sampleListings
    }

    func createListing(_ listing: Listing) async throws -> Listing {
        listing
    }

    func requestUpload(filename: String, bytes: Int64) async throws -> UploadTicket {
        // Offline dev: no presigned URL → UploadManager falls back to Simulate.
        UploadTicket(id: UUID().uuidString, putURL: nil)
    }

    func completeUpload(id: String, sha256: String?) async throws {}

    func createRender(listingID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render {
        let render = Render(listingID: listingID, tier: tier, durationS: durationS,
                            enhancements: enhancements, status: "queued", progress: 0)
        renders[render.id] = (render, Date())
        return render
    }

    func renderStatus(id: UUID) async throws -> Render {
        guard let entry = renders[id] else { throw APIError.badResponse(404) }
        // Simulated pipeline: ~14s base, +3s per enhancement step.
        let steps = entry.render.pipelineSteps
        let total = 14.0 + Double(steps.count - 7) * 3.0
        let elapsed = Date().timeIntervalSince(entry.startedAt)
        var r = entry.render
        r.progress = min(1.0, elapsed / total)
        if r.progress >= 1.0 {
            r.status = "ready"
        } else {
            r.status = steps[min(steps.count - 1, Int(r.progress * Double(steps.count)))]
        }
        return r
    }
}
