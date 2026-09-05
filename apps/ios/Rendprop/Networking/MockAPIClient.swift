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
        // than showing an invented "Dev" plan). `isAdmin` IS true here so the
        // owner console is reachable in the offline build — there is no server
        // to ask, and the mock's job is to make every screen exercisable.
        UsageSummary(aiSpendCents: 0, renderCount: 0, leadCount: 0, planName: nil,
                     entitlements: nil, userName: nil, orgName: nil, brandName: nil,
                     isAdmin: true, role: "owner")
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

    // MARK: - Admin console (offline sample data)
    //
    // Believable enough to exercise every state of AdminConsoleView without a
    // backend: a total that does NOT add up to real spend, a coverage object
    // that says exactly why, one blocked workspace, and one provider whose
    // credential is missing. Numbers are grounded in docs/AI-COST-MODEL.md so
    // they read as plausible rather than random.
    //
    // NOTE: no credential value, prefix or length appears here — only env var
    // NAMES and booleans, matching what the server is allowed to send.

    func adminSpend(window: AdminSpendWindow) async throws -> AdminSpendReport {
        try? await Task.sleep(nanoseconds: 350_000_000)
        let f = Self.spendFactor(window)
        let providers: [AdminSpendBucket] = [
            Self.bucket("fal", "fal.ai", 310.4, 41, f),
            Self.bucket("gemini", "Google Gemini", 74.1, 33, f),
            Self.bucket("anthropic", "Anthropic", 26.9, 18, f),
            Self.bucket("cloudflare", "Cloudflare Stream", 7.34, 4, f),
        ]
        let features: [AdminSpendBucket] = [
            Self.bucket("hero", "AI hero clip", 240.0, 10, f),
            Self.bucket("restage", "Virtual restage", 96.3, 26, f),
            Self.bucket("declutter", "Auto-declutter", 52.8, 41, f),
            Self.bucket("qc", "QC drift judge", 22.5, 15, f),
            Self.bucket("stream_deliver", "Tour delivery", 7.14, 4, f),
        ]
        let orgs: [AdminSpendOrg] = [
            AdminSpendOrg(orgId: "0f1e2d3c-4b5a-4968-8776-655443322110",
                          orgName: "Harbor Realty", plan: "pro",
                          totalCents: Self.round4(299.84 * f),
                          rows: Self.scaleRows(74, f), share: 0.7161),
            AdminSpendOrg(orgId: "3c2b1a09-8877-4655-a443-322110ffeedd",
                          orgName: "Fixture Agent", plan: "free",
                          totalCents: Self.round4(118.9 * f),
                          rows: Self.scaleRows(22, f), share: 0.2839),
        ]
        return AdminSpendReport(
            window: window.rawValue,
            from: Self.iso(Date().addingTimeInterval(-Self.windowSeconds(window))),
            to: Self.iso(Date()),
            generatedAt: Self.iso(Date()),
            totalCents: Self.round4(418.74 * f),
            ledgerRows: Self.scaleRows(96, f),
            truncated: false,
            byProvider: providers,
            byFeature: features,
            byOrg: orgs,
            coverage: Self.sampleCoverage)
    }

    func adminProviders() async throws -> AdminProvidersReport {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let providers: [AdminProvider] = [
            AdminProvider(
                key: "gemini", name: "Google Gemini", kind: "ai", billable: true,
                credentialEnv: "GEMINI_API_KEY", envNames: ["GEMINI_API_KEY"],
                configured: true, ledgerProvider: "gemini",
                models: [
                    AdminProviderModel(
                        sku: "gemini-2.5-flash-image",
                        label: "Nano Banana — image edit",
                        unit: "image", unitCostCents: 3.9,
                        trigger: "POST /ai-photo (AI Photo Studio: twilight, sky, lawn, declutter, stage); worker restage",
                        source: "docs/AI-COST-MODEL.md §1 — Nano Banana direct"),
                ]),
            AdminProvider(
                key: "fal", name: "fal.ai", kind: "ai", billable: true,
                credentialEnv: "FAL_KEY", envNames: ["FAL_KEY"],
                configured: true, ledgerProvider: "fal",
                models: [
                    AdminProviderModel(
                        sku: "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
                        label: "Seedance 1.0 Pro Fast — image-to-video",
                        unit: "second of generated clip", unitCostCents: 4.8,
                        trigger: "POST /ai-video/reel-clip (Reel clip); POST /ai-video/aerial (grounded); worker hero clip",
                        source: "docs/AI-COST-MODEL.md §1 — ~$0.24 / 5s clip"),
                    AdminProviderModel(
                        sku: "fal-ai/flux-pro/v1/fill",
                        label: "Flux Fill — masked inpaint",
                        unit: "image", unitCostCents: 4.0,
                        trigger: "Worker auto-declutter (masked region only)",
                        source: "docs/AI-COST-MODEL.md §1 — ~$0.04/img"),
                ]),
            AdminProvider(
                key: "anthropic", name: "Anthropic", kind: "ai", billable: true,
                credentialEnv: "ANTHROPIC_API_KEY", envNames: ["ANTHROPIC_API_KEY"],
                configured: true, ledgerProvider: "anthropic",
                models: [
                    AdminProviderModel(
                        sku: "claude-haiku-4.5",
                        label: "Claude Haiku 4.5 — QC drift judge",
                        unit: "4-image QC call", unitCostCents: 0.9,
                        trigger: "Worker QC after each enhanced segment; escalates to Sonnet on low confidence",
                        source: "docs/AI-COST-MODEL.md §3 — $1/$5 per 1M tokens, cached"),
                ]),
            AdminProvider(
                key: "kie", name: "KIE.ai (fallback route)", kind: "ai", billable: true,
                credentialEnv: "KIE_API_KEY", envNames: ["KIE_API_KEY"],
                configured: false, ledgerProvider: "kie",
                models: [
                    AdminProviderModel(
                        sku: "kie/nano-banana",
                        label: "Nano Banana via KIE",
                        unit: "image", unitCostCents: 9.0,
                        trigger: "Only when the Google direct route fails",
                        source: "docs/AI-COST-MODEL.md §1 — ~$0.09/img via KIE"),
                ]),
            AdminProvider(
                key: "cloudflare", name: "Cloudflare (R2 + Stream)", kind: "infra", billable: true,
                credentialEnv: "CLOUDFLARE_ACCOUNT_ID",
                envNames: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN"],
                configured: true, ledgerProvider: "cloudflare",
                models: [
                    AdminProviderModel(
                        sku: "stream/delivery",
                        label: "Stream delivery",
                        unit: "minute watched", unitCostCents: 0.1,
                        trigger: "Every hosted tour view",
                        source: "docs/AI-COST-MODEL.md §3 — $0.001/min watched"),
                ]),
            AdminProvider(
                key: "topaz", name: "Topaz Labs", kind: "ai", billable: true,
                credentialEnv: "TOPAZ_API_KEY", envNames: ["TOPAZ_API_KEY"],
                configured: false, ledgerProvider: nil,
                models: [
                    AdminProviderModel(
                        sku: "topaz/video-upscale",
                        label: "Drone-glide upscale",
                        unit: "clip", unitCostCents: nil,
                        trigger: "POST /ai-video/drone (Team add-on)",
                        source: "No committed price in the repo for this SKU."),
                ]),
        ]
        return AdminProvidersReport(generatedAt: Self.iso(Date()),
                                    providerCount: providers.count,
                                    configuredCount: providers.filter { $0.configured == true }.count,
                                    providers: providers)
    }

    func adminUsage() async throws -> AdminUsageReport {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let orgs: [AdminOrgUsage] = [
            AdminOrgUsage(
                orgId: "0f1e2d3c-4b5a-4968-8776-655443322110",
                orgName: "Harbor Realty", plan: "pro", planRaw: "pro",
                trialEndsAt: nil,
                spendCentsMonth: 299.84, cogsCeilingCents: 5000,
                spendShareOfCeiling: 0.06,
                rendersUsed: 12, rendersCap: 40,
                photoEditsUsed: 88, photoEditsCap: 300,
                reelsUsed: 3, reelsCap: 15,
                aerialsUsed: 1, aerialsCap: 10,
                droneUsed: 0, droneCap: 0,
                jobsInFlight: 1, jobsOrphaned: 0,
                blocked: false, blockedReasons: []),
            AdminOrgUsage(
                orgId: "3c2b1a09-8877-4655-a443-322110ffeedd",
                orgName: "Fixture Agent", plan: "free", planRaw: "trial",
                trialEndsAt: Self.iso(Date().addingTimeInterval(-3 * 86_400)),
                spendCentsMonth: 118.9, cogsCeilingCents: 800,
                spendShareOfCeiling: 0.1486,
                rendersUsed: 1, rendersCap: 1,
                photoEditsUsed: 10, photoEditsCap: 10,
                reelsUsed: 0, reelsCap: 1,
                aerialsUsed: 0, aerialsCap: 2,
                droneUsed: 0, droneCap: 1,
                jobsInFlight: 1, jobsOrphaned: 1,
                blocked: true,
                blockedReasons: ["renders_at_cap", "photo_edits_at_cap", "orphaned_jobs"]),
        ]
        return AdminUsageReport(generatedAt: Self.iso(Date()),
                                month: Self.currentMonth,
                                monthStart: Self.iso(Self.startOfMonth),
                                orgCount: orgs.count,
                                blockedCount: orgs.filter { $0.blocked == true }.count,
                                truncated: false,
                                orgs: orgs)
    }

    func adminHealth() async throws -> AdminHealthReport {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let providers: [AdminHealthProvider] = [
            AdminHealthProvider(
                key: "fal", name: "fal.ai", credentialEnv: "FAL_KEY",
                configured: true, status: "ok", ledgerProvider: "fal",
                lastSuccessAt: Self.iso(Date().addingTimeInterval(-1_800)),
                lastSuccessDetail: "hero / fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
                rowsInWindow: 41, spendCentsInWindow: 310.4),
            AdminHealthProvider(
                key: "gemini", name: "Google Gemini", credentialEnv: "GEMINI_API_KEY",
                configured: true, status: "ok", ledgerProvider: "gemini",
                lastSuccessAt: Self.iso(Date().addingTimeInterval(-7_400)),
                lastSuccessDetail: "restage / gemini-2.5-flash-image",
                rowsInWindow: 33, spendCentsInWindow: 74.1),
            AdminHealthProvider(
                key: "anthropic", name: "Anthropic", credentialEnv: "ANTHROPIC_API_KEY",
                configured: true, status: "idle", ledgerProvider: "anthropic",
                lastSuccessAt: nil, lastSuccessDetail: nil,
                rowsInWindow: 0, spendCentsInWindow: 0),
            AdminHealthProvider(
                key: "topaz", name: "Topaz Labs", credentialEnv: "TOPAZ_API_KEY",
                configured: false, status: "unconfigured", ledgerProvider: nil,
                lastSuccessAt: nil, lastSuccessDetail: nil,
                rowsInWindow: 0, spendCentsInWindow: 0),
            AdminHealthProvider(
                key: "kie", name: "KIE.ai (fallback route)", credentialEnv: "KIE_API_KEY",
                configured: false, status: "unconfigured", ledgerProvider: "kie",
                lastSuccessAt: nil, lastSuccessDetail: nil,
                rowsInWindow: 0, spendCentsInWindow: 0),
        ]
        let failures = AdminJobFailures(
            windowDays: 7, failedJobs: 3, orphanedJobs: 1,
            lastFailureAt: Self.iso(Date().addingTimeInterval(-2 * 86_400)),
            lastFailureStep: "enhance", lastFailureType: "ProviderError",
            byStep: [AdminFailureStep(key: "enhance", count: 2),
                     AdminFailureStep(key: "reaper", count: 1)])
        return AdminHealthReport(
            generatedAt: Self.iso(Date()),
            checkedProviderApis: false,
            note: "No provider API is called by this route. Success is inferred from cost ledger rows; "
                + "failures are render-job failures, which are not attributed to a provider.",
            windowDays: 7,
            providers: providers,
            jobFailures: failures)
    }

    // MARK: Admin sample-data helpers

    /// The offline coverage story — the same shape and the same honesty the
    /// live contract requires: the ledger does NOT see in-app AI spend.
    private static let sampleCoverage = AdminSpendCoverage(
        complete: false,
        headline: "Ledger covers worker renders only — app AI spend is NOT counted.",
        representedCount: 3,
        missingCount: 2,
        sources: [
            AdminCoverageSource(
                key: "worker_pipeline",
                label: "Worker render pipeline (declutter / restage / hero / QC)",
                represented: true,
                detail: "The pipeline writes one cost ledger row per metered provider call.",
                reference: "services/pipeline/cost_ledger.py"),
            AdminCoverageSource(
                key: "stream_delivery",
                label: "Cloudflare Stream delivery",
                represented: true,
                detail: "Metered per minute watched and written to the ledger.",
                reference: "docs/AI-COST-MODEL.md §3"),
            AdminCoverageSource(
                key: "r2_storage",
                label: "R2 storage and operations",
                represented: true,
                detail: "Rolled up per job at completion.",
                reference: "docs/AI-COST-MODEL.md §3"),
            AdminCoverageSource(
                key: "app_ai_photo",
                label: "In-app AI photo edits (POST /ai-photo)",
                represented: false,
                detail: "The ai-photo edge function never writes a cost ledger row, so every Photo "
                    + "Studio edit is invisible here and to the per-org monthly COGS ceiling. Real "
                    + "spend is HIGHER than the number above.",
                reference: "docs/handoff/E-network.md §2 (finding F-E-15)"),
            AdminCoverageSource(
                key: "app_ai_video",
                label: "In-app AI video (reel clips, aerial intros, drone upscales)",
                represented: false,
                detail: "The ai-video edge function submits billable fal jobs and writes no ledger row.",
                reference: "docs/handoff/E-network.md §2 (finding F-E-15)"),
        ])

    private static func bucket(_ key: String, _ label: String,
                               _ cents: Double, _ rows: Int, _ factor: Double) -> AdminSpendBucket {
        AdminSpendBucket(key: key, label: label,
                         totalCents: round4(cents * factor),
                         rows: scaleRows(rows, factor),
                         share: round4(cents / 418.74))
    }

    /// Scales the 7-day sample so switching the window visibly changes the numbers.
    private static func spendFactor(_ window: AdminSpendWindow) -> Double {
        switch window {
        case .today:      return 0.16
        case .sevenDays:  return 1.0
        case .thirtyDays: return 3.7
        }
    }

    private static func windowSeconds(_ window: AdminSpendWindow) -> TimeInterval {
        switch window {
        case .today:      return 86_400
        case .sevenDays:  return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func scaleRows(_ rows: Int, _ factor: Double) -> Int {
        max(0, Int((Double(rows) * factor).rounded()))
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static var startOfMonth: Date {
        let cal = Calendar.current
        let parts = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: parts) ?? Date()
    }

    private static var currentMonth: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        let year = parts.year ?? 2026
        let month = parts.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    // MARK: - AI routing brain (offline sample data)
    //
    // Four tasks, chosen to put every state of AdminRoutingView on screen with
    // no backend:
    //
    //   • photo.stage        a RETIREMENT tombstone (enabled:false + a
    //                        retire_after) sitting next to its successor, and a
    //                        `legacy` row that must never get a switch.
    //   • video.reel_clip    an OPEN CIRCUIT on the third step, and a DISABLED
    //                        Kie step whose note starts "Disabled until …" —
    //                        the legal reason a provider is off, which the
    //                        screen prints verbatim. It shares `same_model_as`
    //                        with step 1, so the "same model as fal" chip draws
    //                        and an owner can see it is a cheaper QUEUE, not a
    //                        different model.
    //   • judge.fair_housing our own offline regex at 0c / no_retention as
    //                        step 1 — the row that proves "the regex always
    //                        runs first" is a table row, not a convention.
    //   • 3d.world           the one min_plan above free, and the one task with
    //                        NO legacy row (`legacy: null`) because nothing
    //                        ships for it yet.
    //
    // The flag starts OFF, exactly as it ships. Both writes MUTATE this actor's
    // state and answer the server's small ack shape, so the screen's
    // write → re-read loop behaves offline the way it does live: a switch moves
    // only after the "server" has confirmed it. Route ids are stable uuids so a
    // toggle survives the re-read.

    /// The master flag, offline. Ships OFF — see `handleRoutingWrite`.
    private var routingFlagEnabled = false
    private var routingFlagChangedAt: String?
    private var routingFlagChangedByYou = false
    /// route_id → the `enabled` the console last set, overriding the fixture.
    private var routingStepOverrides: [String: Bool] = [:]

    func adminRouting() async throws -> AdminRoutingReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let tasks = Self.routingTasks(now: Date()).map { task in
            var t = task
            let steps = (t.steps ?? []).map { step -> AdminRoutingStep in
                guard let id = step.routeId, let override = routingStepOverrides[id] else { return step }
                var s = step
                s.enabled = override
                return s
            }
            t.steps = steps
            // Recomputed, never carried over: a step the console just switched
            // has to change this count or the summary line would lie.
            t.liveStepCount = steps.filter {
                $0.isEnabled && !$0.isLegacyStep && !$0.hasRetired
            }.count
            return t
        }
        return AdminRoutingReport(
            generatedAt: Self.iso(Date()),
            enabled: routingFlagEnabled,
            // Both audit booleans are ALWAYS sent, like the server's — it emits
            // `false`/`false` on a flag nobody has touched, never null. The
            // console has to read "nobody has changed this yet" off that, so
            // the mock must not hand it a friendlier shape than the wire does.
            flag: AdminRoutingFlag(enabled: routingFlagEnabled,
                                   changedAt: routingFlagChangedAt,
                                   changedByIsYou: routingFlagChangedAt != nil && routingFlagChangedByYou,
                                   changedByRecorded: routingFlagChangedAt != nil),
            spendWindowDays: 30,
            spendTruncated: false,
            routesTruncated: false,
            note: Self.routingNote,
            policies: [AdminRoutingPolicy(plan: "free", policy: "cheapest"),
                       AdminRoutingPolicy(plan: "solo", policy: "cheapest"),
                       AdminRoutingPolicy(plan: "pro", policy: "best"),
                       AdminRoutingPolicy(plan: "team", policy: "best")],
            routes: tasks)
    }

    func adminSetRoutingFlag(enabled: Bool) async throws -> AdminRoutingWriteAck {
        try? await Task.sleep(nanoseconds: 250_000_000)
        routingFlagEnabled = enabled
        routingFlagChangedAt = Self.iso(Date())
        routingFlagChangedByYou = true
        // The server's own sentences, word for word — the screen shows this
        // note verbatim, so a paraphrase here would hide a wording change.
        return AdminRoutingWriteAck(
            ok: true,
            enabled: enabled,
            changedAt: routingFlagChangedAt,
            note: enabled
                ? "The router is ON. Each task now resolves to its table-driven chain."
                : "The router is OFF. Every task resolves to its legacy step — behaviour is exactly what shipped.")
    }

    func adminSetRouteStep(routeID: String, enabled: Bool) async throws -> AdminRoutingWriteAck {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let id = routeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = Self.routingTasks(now: Date())
        guard let task = all.first(where: { ($0.steps ?? []).contains { $0.routeId == id } }),
              let step = (task.steps ?? []).first(where: { $0.routeId == id }) else {
            throw APIError.server(status: 404, code: "not_found", message: "No such route step")
        }
        // The legacy row is the flag-OFF answer: enabling it would put today's
        // model into a flag-ON chain too, disabling it would delete that
        // answer. The server 409s it, so the mock does — offline must not be
        // the one build where that switch appears to work.
        guard !step.isLegacyStep else {
            throw APIError.server(
                status: 409, code: "conflict",
                message: "That is the task's legacy step (the flag-off answer) and is not switchable. "
                    + "Turn the router itself off with POST /admin/routing/flag instead.")
        }
        routingStepOverrides[id] = enabled
        // The step ack carries NO `note` — the flag ack is the only one that
        // does (docs/ADMIN-CONSOLE-CONTRACT.md §POST /admin/routing/step).
        return AdminRoutingWriteAck(
            ok: true,
            enabled: enabled,
            changedAt: Self.iso(Date()),
            note: nil,
            routeId: id,
            task: task.task,
            position: step.position,
            provider: step.provider,
            model: step.model,
            auditRecorded: true)
    }

    // MARK: Routing sample-data helpers

    /// The server's own paragraph about what the 30-day figures mean. Printed
    /// verbatim by the console, so it is copied here verbatim too.
    private static let routingNote =
        "With `enabled` false every task resolves to its `legacy` step and behaviour is exactly "
        + "what shipped. `spend_30d_cents` is matched on the EXACT (provider, model) pair a cost_ledger "
        + "row carries, so a zero means no row with that exact pair in the window — not that the step is unused."

    private static func routingTasks(now: Date) -> [AdminRoutingTask] {
        [routingPhotoStage(now: now),
         routingReelClip(now: now),
         routingFairHousing(now: now),
         routingWorld(now: now)]
    }

    /// A chain with a retirement tombstone in it, plus the legacy row.
    private static func routingPhotoStage(now: Date) -> AdminRoutingTask {
        let steps: [AdminRoutingStep] = [
            routingStep(id: "8f1c0a41-0001-4c2a-9f10-1a2b3c4d5e01", position: 1,
                        provider: "gemini", model: "gemini-3.1-flash-image",
                        unit: "image", unitCents: 6.7,
                        capabilities: ["prompt-edit", "fidelity"], maxLatencyS: 60,
                        privacyTier: "retained_30d", enabled: true,
                        health: routingHealth(now: now, okAgo: 1_800, failures: 0, p95: 4_200),
                        spendCents: 74.1, spendRows: 33),
            routingStep(id: "8f1c0a41-0002-4c2a-9f10-1a2b3c4d5e02", position: 2,
                        provider: "openai", model: "gpt-image-2",
                        unit: "image", unitCents: 4.1,
                        capabilities: ["prompt-edit", "fidelity", "mask"], maxLatencyS: 120,
                        privacyTier: "retained_30d", enabled: true,
                        note: "4.1c is the medium-quality 1024 floor — higher quality costs more",
                        health: routingHealth(now: now, okAgo: 6 * 86_400, failures: 0, p95: 9_100),
                        spendCents: 0, spendRows: 0),
            // Retirement tombstone: never routed, kept so the retirement is a
            // fact in the table rather than a sentence in a document.
            routingStep(id: "8f1c0a41-0090-4c2a-9f10-1a2b3c4d5e90", position: 90,
                        provider: "gemini", model: "gemini-2.5-flash-image",
                        unit: "image", unitCents: 3.9,
                        capabilities: ["prompt-edit"], maxLatencyS: 60,
                        privacyTier: "retained_30d", enabled: false,
                        retireAfter: "2026-10-02",
                        note: "RETIRED 2026-10-02. Superseded by gemini-3.1-flash-image (step 1).",
                        health: nil, spendCents: 0, spendRows: 0),
            routingLegacyStep(id: "8f1c0a41-0099-4c2a-9f10-1a2b3c4d5e99", position: 99,
                              provider: "gemini", model: "gemini-2.5-flash-image",
                              unit: "image", unitCents: 3.9,
                              capabilities: ["prompt-edit"],
                              spendCents: 118.9, spendRows: 41),
        ]
        return routingTask("photo.stage", steps: steps)
    }

    /// The one with an OPEN CIRCUIT and the "Disabled until …" Kie step.
    private static func routingReelClip(now: Date) -> AdminRoutingTask {
        let family = "bytedance/seedance-1.0-pro-fast"
        let steps: [AdminRoutingStep] = [
            routingStep(id: "6b2d1e52-0001-4a33-8c44-5d6e7f801101", position: 1,
                        provider: "fal", model: "bytedance/seedance/v1/pro/fast/image-to-video",
                        unit: "second", unitCents: 4.86,
                        capabilities: ["i2v", "1080p", "5s", "6s", "16:9", "9:16"], maxLatencyS: 600,
                        sameModelAs: family, privacyTier: "retained_30d", enabled: true,
                        health: routingHealth(now: now, okAgo: 900, failures: 0, p95: 41_000),
                        spendCents: 310.4, spendRows: 41),
            // Disabled on purpose. The note leads with "Disabled until" because
            // that prefix is what the console prints VERBATIM — it is the legal
            // reason the step is off, and paraphrasing one would be the bug.
            routingStep(id: "6b2d1e52-0002-4a33-8c44-5d6e7f801102", position: 2,
                        provider: "kie", model: "bytedance/v1-pro-fast-image-to-video",
                        unit: "second", unitCents: 3.6,
                        capabilities: ["i2v", "1080p", "5s", "6s", "16:9", "9:16"], maxLatencyS: 600,
                        sameModelAs: family, privacyTier: "trains_by_default", enabled: false,
                        note: "Disabled until commercial and redistribution rights are confirmed in "
                            + "writing. privacy_tier is the conservative assumption until Kie's terms "
                            + "are read — it also keeps customer media off this step if somebody "
                            + "enables it early.",
                        health: nil, spendCents: 0, spendRows: 0),
            // Circuit OPEN: the only availability-independent fallback is the
            // one having trouble, which is exactly the state worth seeing.
            routingStep(id: "6b2d1e52-0003-4a33-8c44-5d6e7f801103", position: 3,
                        provider: "fal", model: "minimax/hailuo-02/standard/image-to-video",
                        unit: "second", unitCents: 4.5,
                        capabilities: ["i2v", "768p", "6s", "16:9", "9:16"], maxLatencyS: 600,
                        privacyTier: "retained_30d", enabled: true,
                        note: "different model = the only availability-independent fallback; 768p and "
                            + "6s max, so it is dropped for a caller that hard-requires 1080p",
                        health: AdminRoutingHealth(
                            open: true,
                            openUntil: iso(now.addingTimeInterval(14 * 60)),
                            consecutiveFailures: 5,
                            p95LatencyMs: 96_000,
                            lastOkAt: iso(now.addingTimeInterval(-3 * 86_400)),
                            lastFailAt: iso(now.addingTimeInterval(-120)),
                            lastErrorClass: "upstream"),
                        spendCents: 22.5, spendRows: 5),
            routingLegacyStep(id: "6b2d1e52-0099-4a33-8c44-5d6e7f801199", position: 99,
                              provider: "fal",
                              model: "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
                              unit: "second", unitCents: 4.8,
                              capabilities: ["i2v", "1080p", "5s", "16:9", "9:16"],
                              spendCents: 240.0, spendRows: 10),
        ]
        return routingTask("video.reel_clip", steps: steps)
    }

    /// Not a failover chain: our own offline regex always runs first, free, and
    /// the two models are an OR. Also the only `no_retention` row on screen.
    private static func routingFairHousing(now: Date) -> AdminRoutingTask {
        let steps: [AdminRoutingStep] = [
            routingStep(id: "2a7f9c63-0001-4b18-9e55-0c1d2e3f4a01", position: 1,
                        provider: "rendprop", model: "fairhousing-regex",
                        unit: "call", unitCents: 0,
                        capabilities: ["classifier", "deterministic", "offline"], maxLatencyS: 1,
                        privacyTier: "no_retention", enabled: true,
                        note: "our own code (_shared/fairhousing.ts). Runs BEFORE resolveRoute on "
                            + "every free-text task and cannot be bypassed.",
                        health: routingHealth(now: now, okAgo: 300, failures: 0, p95: 3),
                        spendCents: 0, spendRows: 0),
            routingStep(id: "2a7f9c63-0002-4b18-9e55-0c1d2e3f4a02", position: 2,
                        provider: "anthropic", model: "claude-haiku-4-5",
                        unit: "call", unitCents: 0.045,
                        capabilities: ["classifier", "text"], maxLatencyS: 30,
                        privacyTier: "retained_30d", enabled: true,
                        note: "OR with step 3, not a failover: flag if EITHER flags. watch "
                            + ">= 2026-10-15 for a successor.",
                        health: routingHealth(now: now, okAgo: 5_400, failures: 0, p95: 1_900),
                        spendCents: 26.9, spendRows: 18),
            routingStep(id: "2a7f9c63-0003-4b18-9e55-0c1d2e3f4a03", position: 3,
                        provider: "openai", model: "gpt-5.6-luna",
                        unit: "call", unitCents: 0.01,
                        capabilities: ["classifier", "text"], maxLatencyS: 30,
                        privacyTier: "retained_30d", enabled: true,
                        note: "OR with step 2, not a failover: flag if EITHER flags",
                        health: routingHealth(now: now, okAgo: 5_500, failures: 1, p95: 2_400),
                        spendCents: 1.2, spendRows: 12),
        ]
        return routingTask("judge.fair_housing", steps: steps)
    }

    /// The one task with NO legacy row — nothing ships for it yet — and the one
    /// `min_plan` above free.
    private static func routingWorld(now: Date) -> AdminRoutingTask {
        let steps: [AdminRoutingStep] = [
            routingStep(id: "4d5e6f70-0001-4c99-8a11-2b3c4d5e6f01", position: 1,
                        provider: "worldlabs", model: "marble-1.1",
                        unit: "world", unitCents: 120.0,
                        capabilities: ["3d", "world", "image_to_world"], maxLatencyS: 1_800,
                        minPlan: "pro", privacyTier: "retained_30d", enabled: true,
                        note: "$1.20 a world is a COGS hole on an unpaid tier. No adapter exists yet, "
                            + "and WorldLabs retention/training terms are UNVERIFIED — confirm them "
                            + "before this carries customer media.",
                        health: nil, spendCents: 0, spendRows: 0),
        ]
        return AdminRoutingTask(task: "3d.world",
                                stepCount: steps.count,
                                liveStepCount: 1,
                                legacy: nil,
                                steps: steps)
    }

    /// Group a task's steps, deriving both counts the way the server does.
    private static func routingTask(_ slug: String, steps: [AdminRoutingStep]) -> AdminRoutingTask {
        let legacy = steps.first(where: { $0.isLegacyStep })
        return AdminRoutingTask(
            task: slug,
            stepCount: steps.count,
            liveStepCount: steps.filter { $0.isEnabled && !$0.isLegacyStep && !$0.hasRetired }.count,
            legacy: legacy.map {
                AdminRoutingLegacy(routeId: $0.routeId, provider: $0.provider, model: $0.model)
            },
            steps: steps)
    }

    private static func routingStep(id: String, position: Int,
                                    provider: String, model: String,
                                    unit: String, unitCents: Double,
                                    capabilities: [String], maxLatencyS: Double,
                                    minPlan: String = "free",
                                    sameModelAs: String? = nil,
                                    privacyTier: String,
                                    enabled: Bool,
                                    retireAfter: String? = nil,
                                    note: String? = nil,
                                    health: AdminRoutingHealth?,
                                    spendCents: Double, spendRows: Int) -> AdminRoutingStep {
        var step = AdminRoutingStep()
        step.routeId = id
        step.position = position
        step.provider = provider
        step.model = model
        step.unit = unit
        step.unitCents = unitCents
        step.capabilities = capabilities
        step.maxLatencyS = maxLatencyS
        step.minPlan = minPlan
        step.enabled = enabled
        step.sameModelAs = sameModelAs
        step.privacyTier = privacyTier
        step.retireAfter = retireAfter
        step.isLegacy = false
        step.note = note
        step.updatedAt = iso(Date().addingTimeInterval(-86_400))
        step.health = health
        // The wire spelling the shared decoder produces is the capital-D one
        // (`"30d".capitalized == "30D"`); the fixture fills it so the mock
        // exercises the same accessor a live payload does.
        step.spend30DCents = round4(spendCents)
        step.spend30DRows = spendRows
        return step
    }

    /// `note == "legacy"` exactly — router.ts looks these up by string
    /// equality, and the console keys "this is what runs today" off it. Always
    /// `enabled:false` so it can never leak into a flag-ON chain.
    private static func routingLegacyStep(id: String, position: Int,
                                          provider: String, model: String,
                                          unit: String, unitCents: Double,
                                          capabilities: [String],
                                          spendCents: Double, spendRows: Int) -> AdminRoutingStep {
        var step = routingStep(id: id, position: position, provider: provider, model: model,
                               unit: unit, unitCents: unitCents, capabilities: capabilities,
                               maxLatencyS: 600, privacyTier: "retained_30d", enabled: false,
                               note: "legacy", health: nil,
                               spendCents: spendCents, spendRows: spendRows)
        step.isLegacy = true
        return step
    }

    private static func routingHealth(now: Date, okAgo: TimeInterval, failures: Int,
                                      p95: Double) -> AdminRoutingHealth {
        AdminRoutingHealth(open: false,
                           openUntil: nil,
                           consecutiveFailures: failures,
                           p95LatencyMs: p95,
                           lastOkAt: iso(now.addingTimeInterval(-okAgo)),
                           lastFailAt: nil,
                           lastErrorClass: nil)
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

    // MARK: - AI voiceover (offline: a real fixture, honestly labelled)

    func aiVoices() async throws -> [AIVoice] {
        try? await Task.sleep(nanoseconds: 400_000_000) // feel like a network
        // The five ElevenLabs stock voices an agent is most likely to pick, so
        // the picker, the selection state and the preview row all exercise
        // offline. The ids are the real public premade ids, so a device that
        // later points at the live backend keeps working with a stored choice.
        return [
            AIVoice(voiceId: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", labels: "narration · american · calm"),
            AIVoice(voiceId: "AZnzlk1XvdvUeBnXmlld", name: "Domi", labels: "narration · american · confident"),
            AIVoice(voiceId: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", labels: "narration · american · soft"),
            AIVoice(voiceId: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", labels: "narration · american · deep"),
            AIVoice(voiceId: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", labels: "narration · british · authoritative"),
        ]
    }

    func aiVoiceTTS(text: String, voiceID: String, listingServerID: UUID?,
                    label: String, idempotencyKey: String) async throws -> AIVoiceResult {
        try? await Task.sleep(nanoseconds: 1_400_000_000) // TTS takes a beat

        // Offline dev: the fair-housing gate lives on the server, so the offline
        // path CANNOT be the place an agent learns the rule. Refusing here too
        // keeps the two paths honest — and keeps a demo from recording a script
        // that the live backend would reject the moment they go online.
        if let offending = Self.offlineFairHousingHit(text) {
            throw APIError.server(
                status: 400, code: "unsupported_edit",
                message: "This voiceover script can't be voiced: the phrase \"\(offending)\" describes "
                    + "who should live in the home, the neighborhood's people, or its safety and schools, "
                    + "rather than the property itself. Fair-housing law applies to a spoken script exactly "
                    + "as it does to a written listing description. Describe the space and let the buyer "
                    + "decide it fits. (Offline check — the server's is the authoritative one.)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.server(status: 400, code: "validation", message: "text is required")
        }
        guard trimmed.count <= 1000 else {
            throw APIError.server(status: 400, code: "validation",
                                  message: "Script is too long: \(trimmed.count) characters (max 1000).")
        }

        // Believable word timings: ~2.6 words a second, which is the real
        // measured pace of an ElevenLabs narration voice, with a longer beat
        // after sentence-ending punctuation. Real enough that the caption
        // renderer and the reel stitcher are genuinely exercised offline.
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var words: [CaptionWord] = []
        var t = 0.18                                  // a short lead-in of silence
        for token in tokens {
            // Longer words take longer; punctuation buys a pause after.
            let spoken = max(0.16, Double(token.count) * 0.062)
            words.append(CaptionWord(text: token, start: (t * 1000).rounded() / 1000,
                                     end: ((t + spoken) * 1000).rounded() / 1000))
            t += spoken
            // Written out rather than as a nested ternary: chained ternaries of
            // Double literals are exactly the shape that has stalled this
            // project's type-checker before.
            let pause: Double
            if token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?") {
                pause = 0.30
            } else if token.hasSuffix(",") || token.hasSuffix(";") {
                pause = 0.16
            } else {
                pause = 0.075
            }
            t += pause
        }
        let duration = ((t + 0.2) * 1000).rounded() / 1000

        let catalogue = (try? await aiVoices()) ?? []
        let voiceName = catalogue.first(where: { $0.voiceID == voiceID })?.displayName ?? "Rachel"

        // There is no audio file offline. Point at a URL that does not resolve
        // rather than at a fake file: the old ai-video stub "completed" with a
        // text file named .mp4 and AVPlayer choked on it downstream. A caller
        // that tries to download this gets a clean network failure it can
        // report, not a corrupt asset it plays.
        guard let url = URL(string: "https://mock.invalid/ai-voice/\(UUID().uuidString.lowercased()).mp3") else {
            throw APIError.invalidURL
        }
        return AIVoiceResult(
            audioURL: url,
            durationS: duration,
            words: words,
            voiceName: voiceName,
            characters: trimmed.count,
            mime: "audio/mpeg",
            durationSource: "alignment",
            disclosure: "This voiceover was generated by AI from a written script. "
                + "The voice is synthetic and is not the agent's own.",
            provenanceID: nil,
            provenanceRecorded: false)
    }

    // MARK: - AI room chapters (docs/AI-CHAPTERS-CONTRACT.md)

    /// Six believable rooms for a 90-second walkthrough — the shape a real
    /// `POST /ai-chapters` returns for a three-bedroom single-level house, so
    /// the whole pre-fill flow (auto-call on an empty tagger, the "Suggest room
    /// names" button, editing a chip, the warnings footnote) runs offline.
    ///
    /// The timestamps are in the SUBMITTED asset's own timeline, exactly as the
    /// server's are, so a caller that forgets the `speedFactor` conversion for a
    /// render asset gets the same wrong answer offline that it would get live.
    /// Offline must not be kinder than production about a contract rule.
    func aiChapters(listingServerID: UUID, assetID: UUID, maxChapters: Int,
                    idempotencyKey: String) async throws -> AIChaptersResult {
        try? await Task.sleep(nanoseconds: 1_200_000_000) // watching a video takes a beat

        let all: [AIChapter] = [
            AIChapter(label: "Entry", startS: 0, endS: 9, confidence: 0.94,
                      description: "Tiled entry with a coat closet and a sightline down the hall."),
            AIChapter(label: "Living Room", startS: 9, endS: 24, confidence: 0.96,
                      description: "South-facing windows, oak floors and a gas fireplace."),
            AIChapter(label: "Kitchen", startS: 24, endS: 41, confidence: 0.97,
                      description: "Quartz counters, a gas range and a walk-in pantry."),
            AIChapter(label: "Dining", startS: 41, endS: 55, confidence: 0.82,
                      description: "Open to the kitchen, with a pendant over the table."),
            AIChapter(label: "Primary", startS: 55, endS: 74, confidence: 0.91,
                      description: "Corner room with an en-suite and a double closet."),
            AIChapter(label: "Backyard", startS: 74, endS: 90, confidence: 0.88,
                      description: "Fenced lawn with a covered patio and mature trees."),
        ]
        let kept = Array(all.prefix(max(1, min(24, maxChapters))))

        return AIChaptersResult(
            chapters: kept,
            summary: "A single-level three-bedroom laid out around a central hall, "
                + "with the living space at the front and the primary suite at the back.",
            videoSeconds: 90,
            model: "gemini-3.6-flash (offline sample)",
            costCentsEstimate: 1.05,
            warnings: kept.count < all.count
                ? ["\(all.count - kept.count) extra suggestions were trimmed to keep the top \(kept.count)."]
                : [],
            disclosure: "This media was digitally altered or generated with AI.",
            provenanceID: nil,
            provenanceRecorded: false)
    }

    /// A DELIBERATELY SMALL offline echo of the server's fair-housing script
    /// gate — the phrases the contract names, nothing more. The server's
    /// `_shared/fairhousing.ts` is the authoritative and complete list; this
    /// exists so an offline demo cannot teach an agent a habit the live backend
    /// will refuse. Returns the offending phrase, or nil.
    private static func offlineFairHousingHit(_ text: String) -> String? {
        let patterns = [
            "great for families", "perfect for families", "ideal for families",
            "for a young couple", "young professionals", "family-friendly", "family friendly",
            "safe neighborhood", "safe neighbourhood", "safe area", "low crime", "crime-free",
            "good schools", "great schools", "school district",
            "exclusive community", "exclusive neighborhood", "no kids", "no children",
            "adults only", "raise a family", "walk to st.", "bachelor pad",
        ]
        let haystack = text.lowercased()
        for p in patterns where haystack.contains(p) { return p }
        return nil
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
