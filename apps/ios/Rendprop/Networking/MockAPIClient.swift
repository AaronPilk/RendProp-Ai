import Foundation

/// Fully offline API — believable sample data + simulated render progress.
/// The app runs end-to-end on-device with no backend. Every protocol method
/// returns a plausible value; the AI video features report honestly that they
/// need the live backend instead of handing back a fake file.
actor MockAPIClient: APIClient {
    private var renders: [UUID: (render: Render, startedAt: Date)] = [:]
    /// Listings created/updated offline, keyed by id — so `listings()` and
    /// `updateListing` round-trip like a real server would.
    private var created: [UUID: Listing] = [:]

    // MARK: - Listings

    func listings() async throws -> [Listing] {
        try? await Task.sleep(nanoseconds: 350_000_000) // feel like a network
        // Samples for the CURRENT business type (a venue owner sees venues, not
        // houses) plus anything created offline this session.
        let live = created.values.sorted { $0.createdAt > $1.createdAt }
        return SpaceType.current.sampleListings + live
    }

    func createListing(_ listing: Listing) async throws -> Listing {
        var l = listing
        l.isSample = false
        l.serverID = l.serverID ?? UUID()
        created[l.id] = l
        return l
    }

    func updateListing(_ listing: Listing) async throws -> Listing {
        var l = listing
        if l.status == .uploading { l.status = .processing }   // mirror the live mapping
        created[l.id] = l
        return l
    }

    func deleteListing(serverID: UUID) async throws {
        created = created.filter { $0.value.serverID != serverID && $0.key != serverID }
    }

    // MARK: - Uploads

    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?,
                       idempotencyKey: String?) async throws -> UploadTicket {
        // Offline dev: single-mode ticket with no presigned URL → UploadManager
        // falls back to Simulate (video) / returns the id directly (poster).
        // `role`/`contentType` are irrelevant with no real buckets.
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

    // MARK: - Renders

    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render {
        let render = Render(listingID: listingID, tier: tier, durationS: durationS,
                            enhancements: enhancements, status: "queued", progress: 0)
        renders[render.id] = (render, Date())
        return render
    }

    func renderStatus(id: UUID) async throws -> Render {
        guard let entry = renders[id] else {
            throw APIError.server(status: 404, code: "not_found", message: "Render not found.")
        }
        // Simulated pipeline: ~14s base, +3s per enhancement step.
        let steps = entry.render.pipelineSteps
        let total = 14.0 + Double(max(0, steps.count - 7)) * 3.0
        let elapsed = Date().timeIntervalSince(entry.startedAt)
        var r = entry.render
        r.progress = min(1.0, elapsed / total)
        if r.progress >= 1.0 {
            r.status = "ready"
        } else if !steps.isEmpty {
            r.status = steps[min(steps.count - 1, Int(r.progress * Double(steps.count)))]
        }
        return r
    }

    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, tier: RenderTier,
                    enhancements: Enhancements, chapters: [ChapterInput],
                    posterAssetID: String?) async throws -> PublishedTour {
        // Offline dev: synthesize a believable local slug so the flow completes.
        // Never reached in the live path (publishTour is gated on useLiveBackend,
        // which uses LiveAPIClient). Deterministic per (listing, asset) — like the
        // server's idempotent replay — so a retry yields the same slug.
        let seed = DirectUploader.sha256Hex("publish:\(listingID.uuidString):\(assetID)")
        let slug = String(seed.prefix(8))
        return PublishedTour(slug: slug, shareURL: "https://rendprop.com/f/\(slug)",
                             durationS: durationS, staged: enhancements.isActive,
                             renderID: UUID())
    }

    func updateChapters(renderID: UUID, chapters: [ChapterInput]) async throws {
        // Offline: chapters live on the local tour already; nothing to sync.
        _ = (renderID, chapters)
    }

    // MARK: - Account / usage / leads

    func me() async throws -> UsageSummary {
        // Offline: no plan, no allowances (nil → the UI hides the rows rather
        // than showing an invented "Dev" plan).
        UsageSummary(aiSpendCents: 0, renderCount: 0, leadCount: 0, planName: nil,
                     entitlements: nil, userName: nil, orgName: nil, brandName: nil)
    }

    func leads(listingServerID: UUID?) async throws -> [Lead] {
        // Offline: leads only exist once a tour is hosted — none to show.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return []
    }

    func updateBrand(_ fields: [String: String]) async throws {
        // Offline: the card already lives in UserDefaults; nothing to sync.
        _ = fields
    }

    // MARK: - AI photo (offline stubs)

    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult {
        // Offline dev: no Gemini — echo the original back so the UI flow runs
        // (style/prompt are ignored offline). The disclosure sentence mirrors
        // public.provenance_disclosure() so the compliance copy is exercised
        // offline too; nothing is recorded, because there is no audit log here.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return AIPhotoEditResult(imageBase64: request.imageBase64,
                                 mime: request.mime,
                                 disclosure: Self.offlineDisclosure(for: request.edit),
                                 provenanceID: nil,
                                 provenanceRecorded: false,
                                 provenanceReason: "You're offline — this edit isn't in the compliance log.")
    }

    /// Mirror of `public.provenance_disclosure(kind, edit)` for offline dev.
    private static func offlineDisclosure(for edit: String) -> String {
        switch edit {
        case "stage":
            return "This photo was virtually staged with AI: furniture and decor were digitally added "
                + "or restyled. The architecture, dimensions, and views are unchanged."
        case "declutter":
            return "This photo was digitally decluttered with AI: clutter and personal items were "
                + "removed. The architecture, dimensions, and views are unchanged."
        case "twilight":
            return "This photo was digitally altered with AI: the sky and lighting were changed to "
                + "simulate dusk. The property itself is unchanged."
        case "sky":
            return "This photo was digitally altered with AI: the sky was replaced. The property "
                + "itself is unchanged."
        case "lawn":
            return "This photo was digitally altered with AI: the lawn and landscaping were digitally "
                + "repaired. The property itself is unchanged."
        default:
            return "This photo was digitally altered with AI. The architecture, dimensions, and views "
                + "are unchanged."
        }
    }

    // MARK: - Compliance (offline: nothing is logged, so there is nothing to show)

    func provenance(listingServerID: UUID) async throws -> [ProvenanceRecord] {
        // Offline dev: the audit log lives server-side. An empty list is the
        // honest answer — never invented compliance rows.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return []
    }

    func attachProvenanceMedia(provenanceID: String, originalAssetID: String?,
                               alteredAssetID: String?) async throws {
        // Offline: there is no provenance row to attach anything to.
        _ = (provenanceID, originalAssetID, alteredAssetID)
    }

    func complianceCSV(listingServerID: UUID?) async throws -> Data {
        // Header-only export so the share flow is exercisable offline.
        let header = "created_at,listing_id,listing_address,kind,label,edit,style,"
            + "model_id,disclosure,original_url,altered_url,prompt_summary,id\r\n"
        return Data(header.utf8)
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

    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?,
                      idempotencyKey: String?) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "drone", grounded: nil)
    }

    func aiVideoAerial(_ request: AerialRequest, idempotencyKey: String?) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "aerial", grounded: request.isGrounded)
    }

    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         listingServerID: UUID?, label: String?,
                         idempotencyKey: String?) async throws -> AIVideoJob {
        Self.mockAIVideoJob(kind: "reel", grounded: true)
    }

    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        // Offline dev: fail HONESTLY after a short beat. The old stub "completed"
        // with a text file named .mp4, which AVPlayer and Photos then choked on.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return .failed("AI video needs the live backend — you're offline (mock mode).")
    }

    private static func mockAIVideoJob(kind: String, grounded: Bool?) -> AIVideoJob {
        let id = UUID().uuidString.lowercased()
        return AIVideoJob(requestId: id,
                          statusUrl: "https://queue.fal.run/mock/requests/\(id)/status",
                          responseUrl: "https://queue.fal.run/mock/requests/\(id)",
                          kind: kind, grounded: grounded, synthetic: true,
                          // The aerial sentence is a legal requirement, not a
                          // server nicety — it must be right offline too.
                          disclosure: kind == "aerial" ? AIVideoJob.aerialFallbackDisclosure : nil,
                          provenanceID: nil)
    }
}
