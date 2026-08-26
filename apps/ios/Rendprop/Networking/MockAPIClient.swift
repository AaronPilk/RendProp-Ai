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

    func updateListing(_ listing: Listing) async throws -> Listing {
        listing
    }

    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String) async throws -> UploadTicket {
        // Offline dev: single-mode ticket with no presigned URL → UploadManager
        // falls back to Simulate. `role` is irrelevant with no real buckets.
        UploadTicket(assetID: UUID().uuidString, mode: .single, putURL: nil, storageKey: nil)
    }

    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL] {
        // Offline: no real R2 targets. The multipart path only runs under
        // useLiveBackend, so this is never exercised offline.
        [:]
    }

    func completeUpload(assetID: String,
                        parts: [(number: Int, etag: String)]?,
                        metadata: UploadMetadata) async throws {}

    func abortUpload(assetID: String) async throws {}

    func requestPhotoBatch(listingID: UUID, files: [PhotoUploadRequest]) async throws -> [PhotoTicket] {
        // Offline: synthetic slots so callers get the right shape. The placeholder
        // host is never hit unless useLiveBackend is on (which uses LiveAPIClient).
        files.enumerated().map { (i, _) in
            let placeholder = URL(string: "https://offline.rendprop.invalid/\(UUID().uuidString)")
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return PhotoTicket(index: i, assetID: UUID().uuidString,
                               putURL: placeholder, storageKey: nil)
        }
    }

    func completeUpload(id: String, sha256: String?) async throws {}

    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render {
        let render = Render(listingID: listingID, tier: tier, durationS: durationS,
                            enhancements: enhancements, status: "queued", progress: 0)
        renders[render.id] = (render, Date())
        return render
    }

    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, staged: Bool, tier: Render.Tier,
                    enhancements: Enhancements, chapters: [[String: Any]]) async throws -> PublishedTour {
        // Offline dev: synthesize a believable local slug so the flow completes.
        // Never reached in the live path (publishTour is gated on useLiveBackend,
        // which uses LiveAPIClient).
        let slug = String(UUID().uuidString.prefix(8)).lowercased()
        return PublishedTour(slug: slug, shareURL: "https://rendprop.app/f/\(slug)",
                             durationS: durationS, staged: staged)
    }

    func me() async throws -> UsageSummary {
        // Believable offline sample — only shown when useLiveBackend is true.
        UsageSummary(aiSpendCents: 0, renderCount: 0, leadCount: 0, planName: "Dev")
    }

    func aiPhotoEdit(imageBase64: String, mime: String, edit: String,
                     style: String?, prompt: String?) async throws -> String {
        // Offline dev: no Gemini — echo the original back so the UI flow runs
        // (style/prompt are ignored offline).
        try? await Task.sleep(nanoseconds: 500_000_000)
        return imageBase64
    }

    func aiPhotoSuggest(imageBase64: String, mime: String) async throws -> [AIEditSuggestion] {
        // Offline dev: two believable canned suggestions so the SuggestSheet
        // flow (rows → tap → aiEdit) is fully exercisable without a backend.
        try? await Task.sleep(nanoseconds: 900_000_000)
        return [
            AIEditSuggestion(edit: "twilight",
                             reason: "Warm dusk light would make this shot feel premium.",
                             confidence: 0.9),
            AIEditSuggestion(edit: "declutter",
                             reason: "A few loose items pull focus from the space itself.",
                             confidence: 0.65),
        ]
    }

    func aiImprovePrompt(imageBase64: String, mime: String, prompt: String) async throws -> String {
        // Offline dev: echo the idea back, embellished, so the replace-the-field
        // UX runs end-to-end.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let rough = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rough.isEmpty else {
            return "Brighten the room with soft natural light, keeping every surface true to the photo."
        }
        return rough + " — with balanced natural light, true-to-life colors, and crisp detail. "
            + "Keep the layout and architecture exactly as photographed."
    }

    // MARK: - AI video (offline stubs — the real flows run only on LiveAPIClient)

    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "drone")
    }

    func aiVideoAerial(address: String?, prompt: String?, seconds: Int, aspect: String) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "aerial")
    }

    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "reel")
    }

    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        // Offline dev: "complete" after a short beat with a local placeholder file
        // so any caller's poll → download flow finishes instead of hanging. Not a
        // real video — the AI video features are gated on useLiveBackend anyway.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let placeholder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-ai-video-\(job.requestId).mp4")
        if !FileManager.default.fileExists(atPath: placeholder.path) {
            try? Data("rendprop offline placeholder".utf8).write(to: placeholder)
        }
        return .completed(videoURL: placeholder)
    }

    private static func mockAIVideoJob(kind: String) -> AIVideoJob {
        let id = UUID().uuidString.lowercased()
        return AIVideoJob(requestId: id,
                          statusUrl: "https://queue.fal.run/mock/requests/\(id)/status",
                          responseUrl: "https://queue.fal.run/mock/requests/\(id)",
                          kind: kind)
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
