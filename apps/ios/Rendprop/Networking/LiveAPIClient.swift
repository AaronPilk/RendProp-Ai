import Foundation

/// Round a coordinate to 3 decimal places (~110 m). Only a coarse fix ever
/// leaves the device or lands in the listing model — the privacy manifest
/// declares CoarseLocation, not precise (2026-08 audit P0-6). The street
/// address stays exact; it's the product.
func coarseCoordinate(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

/// Live client against the Supabase Edge Functions API
/// (docs/BACKEND-ARCHITECTURE.md §2). Base = `https://<ref>.supabase.co/functions/v1`.
///
/// Every request carries:
///   • `apikey: <supabase anon key>`      (public, RLS enforces access)
///   • `Authorization: Bearer <jwt>`      (owner routes; from AuthStore)
///   • `Idempotency-Key`                  (on all writes — safe retries)
///
/// Wire JSON is snake_case. We decode into private DTOs (snake_case → camelCase
/// via `.convertFromSnakeCase`) and map to the app's models, and we build write
/// bodies as explicit snake_case dictionaries (mirrors the AI/ clients' style),
/// so the app models never have to match the DB column names.
final class LiveAPIClient: APIClient {
    private let base: URL
    private let session: URLSession

    init?(baseURL: URL? = Config.apiBaseURL) {
        guard let baseURL else { return nil }
        self.base = baseURL
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Request plumbing

    /// Build a URL by appending path segments individually (never string-joins,
    /// so ids with slashes/odd chars can't corrupt the path).
    private func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var u = base
        for s in segments { u.appendPathComponent(s) }
        guard !query.isEmpty,
              var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        comps.queryItems = query
        return comps.url ?? u
    }

    private func makeRequest(url: URL, method: String = "GET", json: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = AuthStore.currentAccessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func execute(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    // Decoder built per call (JSONDecoder isn't Sendable — no shared static).
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: data)
    }

    /// ISO8601 → Date, tolerant of fractional seconds (Supabase timestamps).
    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Date → ISO8601 string for write bodies (e.g. sold_at on PATCH).
    private static func isoString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - Listings

    func listings() async throws -> [Listing] {
        let data = try await execute(makeRequest(url: url(["listings"])))
        let dtos: [ListingDTO] = try decode(data)
        return dtos.map(mapListing)
    }

    func createListing(_ listing: Listing) async throws -> Listing {
        let data = try await execute(makeRequest(url: url(["listings"]), method: "POST",
                                                 json: listingBody(listing, includeStatus: false)))
        return mapListing(try decode(data))
    }

    func updateListing(_ listing: Listing) async throws -> Listing {
        let data = try await execute(makeRequest(url: url(["listings", listing.id.uuidString]),
                                                 method: "PATCH",
                                                 json: listingBody(listing, includeStatus: true)))
        return mapListing(try decode(data))
    }

    // MARK: - Uploads (contract §2)

    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String) async throws -> UploadTicket {
        var body: [String: Any] = ["filename": filename, "bytes": bytes, "kind": kind, "role": role]
        if let listingID { body["listing_id"] = listingID.uuidString }
        if let sha256 { body["sha256"] = sha256 }
        let data = try await execute(makeRequest(url: url(["uploads"]), method: "POST", json: body))
        let dto: UploadTicketDTO = try decode(data)
        let mode = UploadTicket.Mode(rawValue: dto.mode ?? "single") ?? .single
        return UploadTicket(assetID: dto.assetId, mode: mode,
                            putURL: dto.putUrl, uploadID: dto.uploadId,
                            partSize: dto.partSize, partCount: dto.partCount,
                            storageKey: dto.storageKey)
    }

    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL] {
        let body: [String: Any] = ["numbers": numbers]
        let data = try await execute(makeRequest(url: url(["uploads", assetID, "part-urls"]),
                                                 method: "POST", json: body))
        let dto: PartURLsDTO = try decode(data)
        var out: [Int: URL] = [:]
        for entry in dto.urls {
            if let u = URL(string: entry.url) { out[entry.number] = u }
        }
        return out
    }

    func completeUpload(assetID: String,
                        parts: [(number: Int, etag: String)]?,
                        metadata: UploadMetadata) async throws {
        var body: [String: Any] = [:]
        if let parts {   // multipart: ETag manifest is REQUIRED
            body["parts"] = parts.map { ["number": $0.number, "etag": $0.etag] }
        }
        if let v = metadata.durationS { body["duration_s"] = v }
        if let v = metadata.fps       { body["fps"] = v }
        if let v = metadata.width     { body["width"] = v }
        if let v = metadata.height    { body["height"] = v }
        if let v = metadata.codec     { body["codec"] = v }
        if let v = metadata.isDrone   { body["is_drone"] = v }
        if let v = metadata.hasGyro   { body["has_gyro"] = v }
        if let v = metadata.bytes     { body["bytes"] = v }
        if let v = metadata.sha256    { body["sha256"] = v }
        _ = try await execute(makeRequest(url: url(["uploads", assetID, "complete"]),
                                          method: "POST", json: body))
    }

    func abortUpload(assetID: String) async throws {
        _ = try await execute(makeRequest(url: url(["uploads", assetID, "abort"]),
                                          method: "POST", json: [:]))
    }

    func requestPhotoBatch(listingID: UUID, files: [PhotoUploadRequest]) async throws -> [PhotoTicket] {
        let body: [String: Any] = [
            "listing_id": listingID.uuidString,
            "kind": "photo",
            "files": files.map { f -> [String: Any] in
                var d: [String: Any] = ["filename": f.filename]
                if let b = f.bytes { d["bytes"] = b }
                if let s = f.sha256 { d["sha256"] = s }
                if let c = f.contentType { d["content_type"] = c }
                return d
            },
        ]
        let data = try await execute(makeRequest(url: url(["uploads", "batch"]), method: "POST", json: body))
        let dto: PhotoBatchDTO = try decode(data)
        return dto.assets.compactMap { slot in
            guard let put = slot.putUrl else { return nil }
            return PhotoTicket(index: slot.index, assetID: slot.assetId,
                               putURL: put, storageKey: slot.storageKey)
        }
    }

    func completeUpload(id: String, sha256: String?) async throws {
        // Legacy single-complete. Delegates to the richer path with a minimal body.
        try await completeUpload(assetID: id, parts: nil,
                                 metadata: UploadMetadata(sha256: sha256))
    }

    // MARK: - Renders

    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render {
        // NOTE: `assetID` must be the server capture_assets id returned by
        // /uploads. Today the call site passes the local CaptureAsset.id (the
        // upload runs async in the background), so wiring the real live path
        // requires threading the server asset_id back from createUpload → here.
        // See ReviewSubmitView.start() (TODO).
        let body: [String: Any] = [
            "listing_id": listingID.uuidString,
            "asset_id": assetID.uuidString,
            "tier": tier.rawValue,
            "duration_s": durationS,
            "enhancements": ["declutter": enhancements.declutter,
                             "style": enhancements.style.rawValue],
        ]
        let data = try await execute(makeRequest(url: url(["renders"]), method: "POST", json: body))
        let dto: RenderDTO = try decode(data)
        return mapRender(dto, fallbackListingID: listingID, fallbackTier: tier,
                         fallbackDuration: durationS, fallbackEnhancements: enhancements)
    }

    func renderStatus(id: UUID) async throws -> Render {
        let data = try await execute(makeRequest(url: url(["renders", id.uuidString])))
        let dto: RenderDTO = try decode(data)
        return mapRender(dto, fallbackListingID: nil, fallbackTier: .smooth,
                         fallbackDuration: 0, fallbackEnhancements: Enhancements(), fallbackID: id)
    }

    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, staged: Bool, tier: Render.Tier,
                    enhancements: Enhancements, chapters: [[String: Any]]) async throws -> PublishedTour {
        var body: [String: Any] = [
            "listing_id": listingID.uuidString,
            "asset_id": assetID,
            "duration_s": durationS,
            "speed_factor": speedFactor,
            "staged": staged,
            "tier": tier.rawValue,
            "enhancements": ["declutter": enhancements.declutter,
                             "style": enhancements.style.rawValue],
        ]
        if !chapters.isEmpty { body["chapters"] = chapters }
        let data = try await execute(makeRequest(url: url(["renders", "publish-app"]),
                                                 method: "POST", json: body))
        let dto: PublishAppDTO = try decode(data)
        guard let slug = dto.slug, let share = dto.shareUrl else {
            throw APIError.badResponse(-1)   // server didn't return a slug/share_url
        }
        return PublishedTour(slug: slug, shareURL: share,
                             videoURL: nil, posterURL: nil,
                             durationS: dto.durationS, staged: dto.staged,
                             renderID: dto.id.flatMap(UUID.init(uuidString:)))
    }

    // MARK: - Account / usage

    func aiPhotoEdit(imageBase64: String, mime: String, edit: String,
                     style: String?, prompt: String?) async throws -> String {
        var body: [String: Any] = ["image_b64": imageBase64, "mime": mime, "edit": edit]
        if let style, !style.trimmingCharacters(in: .whitespaces).isEmpty {
            body["style"] = style                       // stage only
        }
        if let prompt {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body["prompt"] = String(trimmed.prefix(600)) }   // custom only, server cap 600
        }
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body))
        struct Resp: Decodable { let imageB64: String }
        let r: Resp = try decode(data)
        return r.imageB64
    }

    func aiPhotoSuggest(imageBase64: String, mime: String) async throws -> [AIEditSuggestion] {
        let body: [String: Any] = ["image_b64": imageBase64, "mime": mime, "edit": "suggest"]
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body))
        // Tolerant decode: every field optional, malformed entries dropped, and
        // only the five runnable preset edits pass through (so every row the UI
        // shows maps to a real aiPhotoEdit mode). Cap at 3 per the contract.
        struct Resp: Decodable {
            struct Item: Decodable { let edit: String?; let reason: String?; let confidence: Double? }
            let suggestions: [Item]?
        }
        let allowed: Set<String> = ["twilight", "sky", "lawn", "declutter", "stage"]
        let r: Resp = try decode(data)
        let mapped = (r.suggestions ?? []).compactMap { item -> AIEditSuggestion? in
            guard let edit = item.edit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  allowed.contains(edit) else { return nil }
            return AIEditSuggestion(edit: edit,
                                    reason: item.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                    confidence: item.confidence)
        }
        return Array(mapped.prefix(3))
    }

    func aiImprovePrompt(imageBase64: String, mime: String, prompt: String) async throws -> String {
        let rough = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = ["image_b64": imageBase64, "mime": mime,
                                   "edit": "improve_prompt",
                                   "prompt": String(rough.prefix(300))]   // contract: rough idea ≤ 300
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body))
        struct Resp: Decodable { let prompt: String? }
        let r: Resp = try decode(data)
        guard let improved = r.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !improved.isEmpty else {
            throw APIError.badResponse(-1)   // server didn't return an improved prompt
        }
        return improved
    }

    // MARK: - AI video (ai-video edge function — async fal submit + poll)

    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?) async throws -> AIVideoJob {
        var body: [String: Any] = ["asset_id": assetID, "tier": tier]
        if let targetFps { body["target_fps"] = targetFps }
        return try await submitAIVideo(path: "drone", body: body, fallbackKind: "drone")
    }

    func aiVideoAerial(style: String?, prompt: String?, seconds: Int, aspect: String) async throws -> AIVideoJob {
        var body: [String: Any] = ["seconds": seconds, "aspect": aspect]
        // No address on the wire (2026-08-26): Veo's safety filter can reject
        // prompts that name real residential addresses — jobs failed in seconds.
        if let style, !style.trimmingCharacters(in: .whitespaces).isEmpty {
            body["style"] = String(style.prefix(200))
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            body["prompt"] = prompt
        }
        return try await submitAIVideo(path: "aerial", body: body, fallbackKind: "aerial")
    }

    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int) async throws -> AIVideoJob {
        var body: [String: Any] = ["image_b64": imageBase64, "mime": mime, "seconds": seconds]
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            body["prompt"] = prompt
        }
        return try await submitAIVideo(path: "reel-clip", body: body, fallbackKind: "reel")
    }

    /// Shared submit → decode for the three generate routes (202 responses).
    private func submitAIVideo(path: String, body: [String: Any],
                               fallbackKind: String) async throws -> AIVideoJob {
        let data = try await execute(makeRequest(url: url(["ai-video", path]),
                                                 method: "POST", json: body))
        let dto: AIVideoJobDTO = try decode(data)
        guard let requestId = dto.requestId, !requestId.isEmpty,
              let statusUrl = dto.statusUrl, !statusUrl.isEmpty,
              let responseUrl = dto.responseUrl, !responseUrl.isEmpty else {
            throw APIError.badResponse(-1)   // server didn't return the fal job ids
        }
        return AIVideoJob(requestId: requestId, statusUrl: statusUrl,
                          responseUrl: responseUrl, kind: dto.kind ?? fallbackKind)
    }

    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus {
        // status_url/response_url are full fal URLs — percent-encode them FULLY
        // (URLComponents.percentEncodedQuery) so nothing inside them (:, /, or
        // any future ? & =) can corrupt our own query string.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let plain = url(["ai-video", "status"])
        var comps = URLComponents(url: plain, resolvingAgainstBaseURL: false)
        comps?.percentEncodedQuery = "status_url=\(enc(job.statusUrl))&response_url=\(enc(job.responseUrl))"
        // Fallback keeps this total (a missing query just 400s server-side and
        // surfaces as a normal APIError to the caller's retry/fallback path).
        let target = comps?.url ?? plain

        let data = try await execute(makeRequest(url: target))
        let dto: AIVideoStatusDTO = try decode(data)
        switch dto.status {
        case "completed":
            guard let s = dto.videoUrl, let videoURL = URL(string: s) else {
                throw APIError.badResponse(-1)   // completed but no video url
            }
            return .completed(videoURL: videoURL)
        case "failed":
            return .failed(dto.error ?? "The AI video job failed.")
        default:
            // "processing" and anything unknown → keep polling (tolerant decode).
            return .processing(queuePosition: dto.queuePosition)
        }
    }

    func updateBrand(_ fields: [String: String]) async throws {
        // PATCH /me/brand — the org brand kit is what the PUBLIC tour/portfolio
        // pages render as the agent card, so this is what puts the agent's
        // identity on every hosted share link (2026-08-26 audit P0-1).
        _ = try await execute(makeRequest(url: url(["me", "brand"]), method: "PATCH", json: fields))
    }

    func me() async throws -> UsageSummary {
        let data = try await execute(makeRequest(url: url(["me"])))
        let dto: MeDTO = try decode(data)
        // /me returns `plan` as a string and `usage.{cost_cents,leads,renders,listings}`
        // (see services/supabase/functions/me/index.ts). cost_cents can be fractional
        // (round4), so decode it as Double and round to whole cents for Money.
        return UsageSummary(aiSpendCents: dto.usage?.costCents.map { Int($0.rounded()) },
                            renderCount: dto.usage?.renders,
                            leadCount: dto.usage?.leads,
                            planName: dto.plan)
    }

    // MARK: - Write bodies (explicit snake_case; omit nil/empty so PATCH is partial)

    private func listingBody(_ l: Listing, includeStatus: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "space_type": l.spaceType.rawValue,
            "address": l.address,
        ]
        if l.price.cents > 0 { b["price_cents"] = l.price.cents }
        if l.beds > 0 { b["beds"] = l.beds }
        if l.baths > 0 { b["baths"] = l.baths }
        if l.sqft > 0 { b["sqft"] = l.sqft }
        if let t = l.tagline, !t.trimmingCharacters(in: .whitespaces).isEmpty { b["tagline"] = t }
        if let d = l.details, !d.isEmpty { b["details"] = d }
        if let lat = l.latitude { b["lat"] = coarseCoordinate(lat) }
        if let lng = l.longitude { b["lng"] = coarseCoordinate(lng) }
        if includeStatus { b["status"] = l.status.rawValue }
        if let sold = l.soldAt { b["sold_at"] = Self.isoString(from: sold) }
        return b
    }

    // MARK: - DTO → model mapping

    private func mapListing(_ dto: ListingDTO) -> Listing {
        Listing(
            id: dto.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            address: dto.address ?? "",
            beds: dto.beds ?? 0,
            baths: dto.baths ?? 0,
            sqft: dto.sqft ?? 0,
            price: Money(cents: dto.priceCents ?? 0),
            status: Listing.Status(rawValue: dto.status ?? "") ?? .draft,
            isSample: false,
            spaceTypeRaw: dto.spaceType,
            createdAt: Self.parseDate(dto.createdAt) ?? Date(),
            soldAt: Self.parseDate(dto.soldAt),
            zillowURL: nil,
            mainPhotoRelPath: nil,          // main_photo_key is a remote R2 key, not a local path (TODO)
            latitude: dto.lat,
            longitude: dto.lng,
            tagline: dto.tagline,
            details: dto.details?.value
        )
    }

    /// Tolerant `[String: String]` decoder for jsonb maps: numbers/bools are
    /// stringified and null/nested values are DROPPED (never thrown) — so one
    /// off-type value (e.g. a future MLS import writing {"year_built": 1998})
    /// can't fail the entire /listings array decode.
    struct TolerantStringMap: Decodable {
        let value: [String: String]

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            var out: [String: String] = [:]
            let c = try decoder.container(keyedBy: AnyKey.self)
            for key in c.allKeys {
                if let s = try? c.decode(String.self, forKey: key) {
                    out[key.stringValue] = s
                } else if let i = try? c.decode(Int.self, forKey: key) {
                    out[key.stringValue] = String(i)
                } else if let d = try? c.decode(Double.self, forKey: key) {
                    out[key.stringValue] = String(d)
                } else if let b = try? c.decode(Bool.self, forKey: key) {
                    out[key.stringValue] = String(b)
                }
                // null / arrays / objects: skipped — tolerate, never throw.
            }
            value = out
        }
    }

    private func mapRender(_ dto: RenderDTO, fallbackListingID: UUID?, fallbackTier: Render.Tier,
                           fallbackDuration: Double, fallbackEnhancements: Enhancements,
                           fallbackID: UUID? = nil) -> Render {
        var r = Render(
            listingID: dto.listingId.flatMap(UUID.init(uuidString:)) ?? fallbackListingID ?? UUID(),
            tier: dto.tier.flatMap(Render.Tier.init(rawValue:)) ?? fallbackTier,
            durationS: dto.durationS ?? fallbackDuration,
            enhancements: dto.enhancements ?? fallbackEnhancements,
            status: dto.status ?? "queued",
            progress: dto.progress ?? 0
        )
        if let idStr = dto.id, let uuid = UUID(uuidString: idStr) { r.id = uuid }
        else if let fallbackID { r.id = fallbackID }
        if let t = dto.tour {
            r.shareSlug = t.slug
            r.shareURL = t.shareUrl
            r.scrubURL = t.scrubUrl
            r.videoURL = t.videoUrl
            r.posterURL = t.poster
        }
        return r
    }

    // MARK: - Wire DTOs (snake_case decoded via .convertFromSnakeCase)

    private struct ListingDTO: Decodable {
        let id: String?
        let spaceType: String?
        let address: String?
        let tagline: String?
        let details: TolerantStringMap?
        let priceCents: Int?
        let beds: Int?
        let baths: Double?
        let sqft: Int?
        let lat: Double?
        let lng: Double?
        let status: String?
        let soldAt: String?
        let createdAt: String?
    }

    private struct UploadTicketDTO: Decodable {
        let assetId: String
        let mode: String?
        let putUrl: URL?
        let uploadId: String?
        let partSize: Int64?
        let partCount: Int?
        let storageKey: String?
    }

    private struct PartURLsDTO: Decodable {
        struct Entry: Decodable { let number: Int; let url: String }
        let urls: [Entry]
    }

    private struct PhotoBatchDTO: Decodable {
        struct Slot: Decodable {
            let index: Int
            let assetId: String
            let putUrl: URL?
            let storageKey: String?
        }
        let assets: [Slot]
    }

    private struct RenderDTO: Decodable {
        let id: String?
        let listingId: String?
        let assetId: String?
        let tier: String?
        let durationS: Double?
        let status: String?
        let progress: Double?
        let enhancements: Enhancements?
        let costCents: Int?
        let currentStep: String?
        let tour: TourDTO?

        /// Nested `tour` on GET /renders/:id (contract §2.6) — the worker-path
        /// published tour. Keys arrive snake_case (share_url, scrub_url, …) and
        /// are mapped via `.convertFromSnakeCase`.
        struct TourDTO: Decodable {
            let slug: String?
            let shareUrl: String?
            let scrubUrl: String?
            let videoUrl: String?
            let poster: String?
        }
    }

    private struct PublishAppDTO: Decodable {
        let id: String?
        let slug: String?
        let shareUrl: String?      // share_url
        let durationS: Double?     // duration_s
        let staged: Bool?
        let videoKey: String?      // video_key (R2 object key, not a URL)
        let posterKey: String?     // poster_key
    }

    /// 202 body of POST /ai-video/{drone,aerial,reel-clip} — fal's queue ids
    /// verbatim plus the route's `kind`. Extra fields (model_id, tier, synthetic,
    /// …) are ignored. All optional → tolerant decode; required ones re-checked
    /// in `submitAIVideo`.
    private struct AIVideoJobDTO: Decodable {
        let requestId: String?     // request_id
        let statusUrl: String?     // status_url
        let responseUrl: String?   // response_url
        let kind: String?
    }

    /// Body of GET /ai-video/status — one of processing/completed/failed.
    private struct AIVideoStatusDTO: Decodable {
        let status: String?
        let queuePosition: Int?    // queue_position (processing only, may be null)
        let videoUrl: String?      // video_url (completed only — EXPIRES)
        let error: String?         // failed only
    }

    private struct MeDTO: Decodable {
        // /me returns `plan` as a scalar string and a `usage` rollup — see
        // services/supabase/functions/me/index.ts.
        struct Usage: Decodable {
            let month: String?
            let costCents: Double?   // cost_cents (round4 → may be fractional)
            let leads: Int?
            let renders: Int?
            let listings: Int?
        }
        let plan: String?
        let usage: Usage?
    }
}
