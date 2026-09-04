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
///   • `Authorization: Bearer <jwt>`      (owner routes; refreshed via AuthStore
///                                         right before sending — never stale)
///   • `Idempotency-Key`                  (on writes — STABLE for retryable
///                                         operations so a retry replays)
///
/// Non-2xx responses are decoded from the server's `{error, code}` envelope
/// into `APIError.server` so the UI shows the message the backend wrote for
/// the user. A 401 is refreshed-and-retried exactly once; a second 401 signs
/// the user out so the publish gate re-prompts.
///
/// Wire JSON is snake_case. We decode into private DTOs (snake_case → camelCase
/// via `.convertFromSnakeCase`) and map to the app's models, and we build write
/// bodies as explicit snake_case dictionaries (mirrors the AI/ clients' style),
/// so the app models never have to match the DB column names.
final class LiveAPIClient: APIClient {
    private let base: URL
    private let session: URLSession
    /// Longer timeout for the AI routes (`Config.aiRequestTimeout`) — a Gemini
    /// photo edit or a fal submit routinely outlives the default 60 s.
    private let aiSession: URLSession

    init?(baseURL: URL? = Config.apiBaseURL) {
        guard let baseURL else { return nil }
        self.base = baseURL
        self.session = URLSession(configuration: .default)
        let aiConfig = URLSessionConfiguration.default
        aiConfig.timeoutIntervalForRequest = Config.aiRequestTimeout
        aiConfig.timeoutIntervalForResource = max(Config.aiRequestTimeout, 600)
        self.aiSession = URLSession(configuration: aiConfig)
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

    /// Assemble a request. `idempotencyKey` should be STABLE for a logical
    /// operation (publish, ticket, one AI tap) so a retry after a lost response
    /// replays server-side instead of double-creating/double-billing. When nil,
    /// a fresh UUID is minted for non-GET requests (previous behaviour — fine
    /// for endpoints with no replay semantics). The bearer token attached here
    /// may be stale; `execute()` re-attaches a freshly-refreshed one.
    private func makeRequest(url: URL, method: String = "GET", json: [String: Any]? = nil,
                             idempotencyKey: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = AuthStore.currentAccessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            let key = idempotencyKey.map(Self.boundedIdempotencyKey) ?? UUID().uuidString
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// The server accepts keys of 8…128 chars; longer ones are hashed so the
    /// key stays stable AND valid.
    private static func boundedIdempotencyKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 8 && trimmed.count <= 128 { return trimmed }
        if trimmed.count > 128 { return "k:" + DirectUploader.sha256Hex(trimmed) }
        return "k:" + String(DirectUploader.sha256Hex(trimmed).prefix(32))
    }

    /// Send, verify 2xx, decode the error envelope otherwise. Refreshes the JWT
    /// first (never sends a token we know is expired), and on a 401 forces ONE
    /// refresh + retry; a 401 after that means the session is dead → sign out.
    private func execute(_ req: URLRequest, session: URLSession? = nil) async throws -> Data {
        let client = session ?? self.session
        var request = req
        if Config.enableAuth, let token = await AuthStore.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await client.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        if (200..<300).contains(http.statusCode) { return data }

        if http.statusCode == 401, Config.enableAuth, AuthStore.shared.isSignedIn {
            let refreshed = await AuthStore.shared.forceRefresh()
            if refreshed, let fresh = AuthStore.storedAccessToken() {
                request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                let (data2, resp2) = try await client.data(for: request)
                guard let http2 = resp2 as? HTTPURLResponse else { throw APIError.badResponse(-1) }
                if (200..<300).contains(http2.statusCode) { return data2 }
                if http2.statusCode == 401 {
                    // Refreshed token still rejected — the session is dead.
                    await AuthStore.shared.signOut()
                }
                throw Self.serverError(status: http2.statusCode, data: data2)
            }
            // Refresh failed: `performRefresh` already signed out on a definitive
            // 4xx; a network failure keeps the session for a later retry.
        }
        throw Self.serverError(status: http.statusCode, data: data)
    }

    /// Decode `{ error, code }` (contract §B4) into `APIError.server`. Tolerant:
    /// a non-JSON body (gateway HTML) or a missing `error` falls back to a
    /// friendly per-status message. `RPnnn:` RPC prefixes are stripped.
    private struct ErrorEnvelope: Decodable {
        let error: String?
        let code: String?
        let message: String?
    }

    static func serverError(status: Int, data: Data) -> APIError {
        var message: String? = nil
        var code: String? = nil
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            message = env.error ?? env.message
            code = env.code
        }
        let cleaned = message.map { raw -> String in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = s.range(of: #"^RP\d{3}:\s*"#, options: .regularExpression) {
                s = String(s[range.upperBound...])
            }
            return s
        }
        let finalMessage = (cleaned?.isEmpty == false) ? cleaned : nil
        return .server(status: status, code: code, message: finalMessage ?? APIError.defaultMessage(for: status))
    }

    // Decoder built per call (JSONDecoder isn't Sendable — no shared static).
    // Decode failures surface as `APIError.decoding` (a readable message) rather
    // than the raw DecodingError text.
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try d.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
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
                                                 json: listingBody(listing, forPatch: false)))
        return mapListing(try decode(data))
    }

    func updateListing(_ listing: Listing) async throws -> Listing {
        // PATCH the SERVER row (serverID), never the local UUID — the local id
        // is unknown to the backend once the listing has been created there.
        let target = listing.serverID ?? listing.id
        let data = try await execute(makeRequest(url: url(["listings", target.uuidString]),
                                                 method: "PATCH",
                                                 json: listingBody(listing, forPatch: true)))
        return mapListing(try decode(data))
    }

    func deleteListing(serverID: UUID) async throws {
        _ = try await execute(makeRequest(url: url(["listings", serverID.uuidString]),
                                          method: "DELETE"))
    }

    // MARK: - Uploads (contract §2)

    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?,
                       idempotencyKey: String?) async throws -> UploadTicket {
        var body: [String: Any] = ["filename": filename, "bytes": bytes, "kind": kind, "role": role]
        if let listingID { body["listing_id"] = listingID.uuidString }
        if let sha256, !sha256.isEmpty { body["sha256"] = sha256 }
        // Declare the exact type the PUT will carry — `/complete` HEAD-verifies
        // observed == declared and DELETES the object on mismatch (P0 fix).
        if let contentType, !contentType.isEmpty { body["content_type"] = contentType }
        let data = try await execute(makeRequest(url: url(["uploads"]), method: "POST", json: body,
                                                 idempotencyKey: idempotencyKey))
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
        // Stable per asset: a retried complete carries the same key.
        _ = try await execute(makeRequest(url: url(["uploads", assetID, "complete"]),
                                          method: "POST", json: body,
                                          idempotencyKey: "complete:\(assetID)"))
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
        // Worker path (not the live app flow). `assetID` must be the SERVER
        // capture_assets id returned by /uploads — the local CaptureAsset id is
        // rejected by the server (RP409 asset not uploaded).
        let body: [String: Any] = [
            "listing_id": listingID.uuidString,
            "asset_id": assetID.uuidString,
            "tier": tier.rawValue,
            "duration_s": durationS,
            "enhancements": ["declutter": enhancements.declutter,
                             "style": enhancements.style.rawValue],
        ]
        let data = try await execute(makeRequest(url: url(["renders"]), method: "POST", json: body,
                                                 idempotencyKey: "render:\(listingID.uuidString):\(assetID.uuidString):\(tier.rawValue)"))
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
                    speedFactor: Double, tier: RenderTier,
                    enhancements: Enhancements, chapters: [ChapterInput],
                    posterAssetID: String?) async throws -> PublishedTour {
        var body: [String: Any] = [
            "listing_id": listingID.uuidString,
            "asset_id": assetID,
            "duration_s": durationS,
            "speed_factor": speedFactor,
            // Derived server-side from `enhancements`; sent for older servers.
            "staged": enhancements.isActive,
            "tier": tier.rawValue,
            "enhancements": ["declutter": enhancements.declutter,
                             "style": enhancements.style.rawValue],
        ]
        if !chapters.isEmpty {
            body["chapters"] = chapters
                .sorted { $0.sort < $1.sort }
                .prefix(60)
                .map { $0.wireDictionary }
        }
        if let posterAssetID, !posterAssetID.isEmpty { body["poster_asset_id"] = posterAssetID }
        // Stable per (listing, asset): a retry after a lost response replays the
        // SAME job + slug instead of publishing a second public tour.
        let key = "publish:\(listingID.uuidString.lowercased()):\(assetID)"
        let data = try await execute(makeRequest(url: url(["renders", "publish-app"]),
                                                 method: "POST", json: body, idempotencyKey: key))
        let dto: PublishAppDTO = try decode(data)
        guard let slug = dto.slug, let share = dto.shareUrl else {
            throw APIError.decoding   // server didn't return a slug/share_url
        }
        // The MLS-safe twin. Optional on the wire — `Listing.serverUnbrandedURL`
        // derives it from the slug when an older server omits it.
        let unbranded = dto.unbrandedUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PublishedTour(slug: slug, shareURL: share,
                             unbrandedURL: (unbranded?.isEmpty == false) ? unbranded : nil,
                             videoURL: dto.videoUrl, posterURL: dto.posterUrl ?? dto.poster,
                             durationS: dto.durationS, staged: dto.staged,
                             renderID: dto.id.flatMap(UUID.init(uuidString:)))
    }

    func updateChapters(renderID: UUID, chapters: [ChapterInput]) async throws {
        let body: [String: Any] = [
            "chapters": chapters.sorted { $0.sort < $1.sort }.prefix(60).map { $0.wireDictionary },
        ]
        _ = try await execute(makeRequest(url: url(["renders", renderID.uuidString, "chapters"]),
                                          method: "PATCH", json: body))
    }

    // MARK: - AI photo

    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult {
        var body: [String: Any] = ["image_b64": request.imageBase64,
                                   "mime": request.mime,
                                   "edit": request.edit]
        if let style = request.style, !style.trimmingCharacters(in: .whitespaces).isEmpty {
            body["style"] = style                       // stage only
        }
        if let prompt = request.prompt {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body["prompt"] = String(trimmed.prefix(600)) }   // custom only, server cap 600
        }
        // Industry-aware prompts server-side (a restaurant is not staged like a
        // living room) — contract §B4.
        body["space_type"] = SpaceType.current.rawValue
        // COMPLIANCE (W2-B3/C3): without listing_id the server cannot enter the
        // edit in the org's audit log at all; original_asset_id is what makes
        // the public "View original" link real (California AB 723).
        if let listing = request.listingServerID { body["listing_id"] = listing.uuidString }
        if let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            body["label"] = String(label.prefix(80))
        }
        if let original = request.originalAssetID?.trimmingCharacters(in: .whitespaces), !original.isEmpty {
            body["original_asset_id"] = original
        }
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body,
                                                 idempotencyKey: request.idempotencyKey),
                                     session: aiSession)
        let r: AIPhotoEditDTO = try decode(data)
        guard let out = r.imageB64, !out.isEmpty else { throw APIError.decoding }
        let disclosure = r.disclosure?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIPhotoEditResult(imageBase64: out,
                                 mime: r.mime,
                                 disclosure: (disclosure?.isEmpty == false) ? disclosure : nil,
                                 provenanceID: r.provenance?.id,
                                 provenanceRecorded: r.provenance?.recorded ?? false,
                                 provenanceReason: r.provenance?.reason)
    }

    // MARK: - Compliance (GET /me/compliance — the broker's AI audit log)

    func provenance(listingServerID: UUID) async throws -> [ProvenanceRecord] {
        let query = [URLQueryItem(name: "listing_id", value: listingServerID.uuidString)]
        let data = try await execute(makeRequest(url: url(["me", "compliance"], query: query)))
        // `{ rows: [...] }` per W2-B3; tolerate a bare array too.
        let rows: [ComplianceRowDTO]
        if let wrapped: ComplianceDTO = try? decode(data), let list = wrapped.rows {
            rows = list
        } else if let bare: [ComplianceRowDTO] = try? decode(data) {
            rows = bare
        } else {
            throw APIError.decoding
        }
        return rows.compactMap(Self.mapProvenance)
    }

    func complianceCSV(listingServerID: UUID?) async throws -> Data {
        var query = [URLQueryItem(name: "format", value: "csv")]
        if let listingServerID {
            query.append(URLQueryItem(name: "listing_id", value: listingServerID.uuidString))
        }
        // The body is text/csv, not JSON — `execute` returns the raw bytes and
        // still decodes the `{error, code}` envelope on a non-2xx.
        return try await execute(makeRequest(url: url(["me", "compliance"], query: query)))
    }

    func attachProvenanceMedia(provenanceID: String, originalAssetID: String?,
                               alteredAssetID: String?) async throws {
        var body: [String: Any] = [:]
        if let originalAssetID, !originalAssetID.isEmpty { body["original_asset_id"] = originalAssetID }
        if let alteredAssetID, !alteredAssetID.isEmpty { body["altered_asset_id"] = alteredAssetID }
        guard !body.isEmpty else { return }   // the server requires at least one field
        // No stable idempotency key: attaching the original and attaching the
        // altered result are two DIFFERENT patches to the same row, and a shared
        // key would let the second replay the first.
        _ = try await execute(makeRequest(url: url(["me", "compliance", provenanceID]),
                                          method: "PATCH", json: body))
    }

    /// One provenance row → the app model. A row with no disclosure sentence is
    /// DROPPED: it would render a compliance line that discloses nothing.
    private static func mapProvenance(_ r: ComplianceRowDTO) -> ProvenanceRecord? {
        let disclosure = r.disclosure?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !disclosure.isEmpty else { return nil }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        func cleanURL(_ s: String?) -> URL? { clean(s).flatMap { URL(string: $0) } }
        let kind = (clean(r.kind)?.lowercased()) ?? "other"
        // `/me/compliance` sends the vendor `model_id`; `/tours` sends the plain
        // words. Show plain words either way — never a vendor model string.
        let model = clean(r.model) ?? ProvenanceRecord.modelFamily(kind)
        return ProvenanceRecord(
            id: clean(r.id) ?? UUID().uuidString,
            listingID: r.listingId.flatMap(UUID.init(uuidString:)),
            kind: kind,
            label: clean(r.label),
            edit: clean(r.edit),
            style: clean(r.style),
            model: model,
            disclosure: disclosure,
            originalURL: cleanURL(r.originalUrl),
            alteredURL: cleanURL(r.alteredUrl),
            createdAt: parseDate(r.createdAt))
    }

    func aiPhotoSuggest(imageBase64: String, mime: String) async throws -> [AIEditSuggestion] {
        let body: [String: Any] = ["image_b64": imageBase64, "mime": mime, "edit": "suggest",
                                   "space_type": SpaceType.current.rawValue]
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body),
                                     session: aiSession)
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
                                   "prompt": String(rough.prefix(300)),   // contract: rough idea ≤ 300
                                   "space_type": SpaceType.current.rawValue]
        let data = try await execute(makeRequest(url: url(["ai-photo"]), method: "POST", json: body),
                                     session: aiSession)
        struct Resp: Decodable { let prompt: String? }
        let r: Resp = try decode(data)
        guard let improved = r.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !improved.isEmpty else {
            throw APIError.decoding   // server didn't return an improved prompt
        }
        return improved
    }

    // MARK: - AI video (ai-video edge function — async fal submit + poll)

    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?,
                      idempotencyKey: String?) async throws -> AIVideoJob {
        var body: [String: Any] = ["asset_id": assetID, "tier": tier]
        if let targetFps { body["target_fps"] = targetFps }
        return try await submitAIVideo(path: "drone", body: body, fallbackKind: "drone",
                                       idempotencyKey: idempotencyKey)
    }

    func aiVideoAerial(_ request: AerialRequest, idempotencyKey: String?) async throws -> AIVideoJob {
        var body: [String: Any] = [
            "space_type": request.spaceType,
            "time_of_day": request.timeOfDay,
            "motion": request.motion,
            "seconds": request.seconds,
            "aspect": request.aspect,
        ]
        // Grounded: the exterior photo rides along (base64, no data: prefix) and
        // the server runs image-to-video on it. Never the street address — only
        // the coarse region ("Charlotte, NC") for scenery context.
        if let image = request.imageJPEGBase64, !image.isEmpty {
            body["image_b64"] = image
            body["mime"] = request.mime ?? "image/jpeg"
        }
        if let region = request.region?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
            body["region"] = String(region.prefix(120))
        }
        if let style = request.style?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty {
            body["style"] = String(style.prefix(200))
        }
        // COMPLIANCE: anchors the aerial's provenance row so the simulated
        // camera movement is disclosed on the tour and in the audit log.
        if let listing = request.listingServerID { body["listing_id"] = listing.uuidString }
        if let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            body["label"] = String(label.prefix(80))
        }
        var job = try await submitAIVideo(path: "aerial", body: body, fallbackKind: "aerial",
                                          idempotencyKey: idempotencyKey)
        // Older servers don't echo the flags — derive from what we sent so the
        // UI's disclosure is always correct.
        if job.grounded == nil { job.grounded = request.isGrounded }
        if job.synthetic == nil { job.synthetic = true }
        return job
    }

    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         listingServerID: UUID?, label: String?,
                         idempotencyKey: String?) async throws -> AIVideoJob {
        var body: [String: Any] = ["image_b64": imageBase64, "mime": mime, "seconds": seconds]
        if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            body["prompt"] = prompt
        }
        if let listingServerID { body["listing_id"] = listingServerID.uuidString }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            body["label"] = String(label.prefix(80))
        }
        return try await submitAIVideo(path: "reel-clip", body: body, fallbackKind: "reel",
                                       idempotencyKey: idempotencyKey)
    }

    /// Shared submit → decode for the three generate routes (202 responses).
    private func submitAIVideo(path: String, body: [String: Any],
                               fallbackKind: String, idempotencyKey: String?) async throws -> AIVideoJob {
        let data = try await execute(makeRequest(url: url(["ai-video", path]),
                                                 method: "POST", json: body,
                                                 idempotencyKey: idempotencyKey),
                                     session: aiSession)
        let dto: AIVideoJobDTO = try decode(data)
        guard let requestId = dto.requestId, !requestId.isEmpty,
              let statusUrl = dto.statusUrl, !statusUrl.isEmpty,
              let responseUrl = dto.responseUrl, !responseUrl.isEmpty else {
            throw APIError.decoding   // server didn't return the fal job ids
        }
        let disclosure = dto.disclosure?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIVideoJob(requestId: requestId, statusUrl: statusUrl,
                          responseUrl: responseUrl, kind: dto.kind ?? fallbackKind,
                          grounded: dto.grounded, synthetic: dto.synthetic,
                          disclosure: (disclosure?.isEmpty == false) ? disclosure : nil,
                          provenanceID: dto.provenance?.id)
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

        let data = try await execute(makeRequest(url: target), session: aiSession)
        let dto: AIVideoStatusDTO = try decode(data)
        switch dto.status {
        case "completed":
            guard let s = dto.videoUrl, let videoURL = URL(string: s) else {
                throw APIError.decoding   // completed but no video url
            }
            return .completed(videoURL: videoURL)
        case "failed":
            return .failed(dto.error ?? "The AI video job failed.")
        default:
            // "processing" and anything unknown → keep polling (tolerant decode).
            return .processing(queuePosition: dto.queuePosition)
        }
    }

    // MARK: - Account / usage / leads

    func updateBrand(_ fields: [String: String]) async throws {
        // PATCH /me/brand — the org brand kit is what the PUBLIC tour/portfolio
        // pages render as the agent card, so this is what puts the agent's
        // identity on every hosted share link (2026-08-26 audit P0-1).
        _ = try await execute(makeRequest(url: url(["me", "brand"]), method: "PATCH", json: fields))
    }

    func me() async throws -> UsageSummary {
        let data = try await execute(makeRequest(url: url(["me"])))
        let dto: MeDTO = try decode(data)
        // /me returns `plan` (effective), `plan_raw`, `trial_ends_at`,
        // `entitlement {…_per_month}` and `usage.{cost_cents, leads, renders,
        // listings, by_feature{…}}` — see services/supabase/functions/me/index.ts.
        // cost_cents can be fractional (round4) → round to whole cents for Money.
        let usage = dto.usage
        var entitlements: Entitlements? = nil
        if let ent = dto.entitlement {
            var used: [String: Int] = [:]
            if let bf = usage?.byFeature {
                if let v = bf.renders?.value    { used["renders"] = v }
                if let v = bf.photoEdits?.value { used["photo_edits"] = v }
                if let v = bf.reels?.value      { used["reels"] = v }
                if let v = bf.aerials?.value    { used["aerials"] = v }
                if let v = bf.drone?.value      { used["drone"] = v }
            }
            if used["renders"] == nil, let r = usage?.renders?.value { used["renders"] = r }
            entitlements = Entitlements(
                plan: dto.plan ?? dto.org?.plan ?? "free",
                planRaw: dto.planRaw,
                trialEndsAt: Self.parseDate(dto.trialEndsAt),
                rendersPerMonth: ent.rendersPerMonth?.value ?? 0,
                photoEditsPerMonth: ent.photoEditsPerMonth?.value ?? 0,
                reelsPerMonth: ent.reelsPerMonth?.value ?? 0,
                aerialsPerMonth: ent.aerialsPerMonth?.value ?? 0,
                topazPerMonth: ent.topazPerMonth?.value ?? 0,
                used: used,
                leads: usage?.leads?.value ?? 0)
        }
        let summary = UsageSummary(
            aiSpendCents: usage?.costCents.map { Int($0.rounded()) },
            renderCount: usage?.renders?.value,
            leadCount: usage?.leads?.value,
            planName: dto.plan ?? dto.org?.plan,
            entitlements: entitlements,
            userName: dto.user?.name,
            orgName: dto.org?.name,
            brandName: dto.org?.brandKit?.name)
        // Let the Account row show the server-side name (never an email).
        await AuthStore.shared.applyServerIdentity(userName: summary.userName, orgName: summary.orgName)
        return summary
    }

    func leads(listingServerID: UUID?) async throws -> [Lead] {
        var query: [URLQueryItem] = []
        if let listingServerID { query.append(URLQueryItem(name: "listing_id", value: listingServerID.uuidString)) }
        let data = try await execute(makeRequest(url: url(["leads"], query: query)))
        // `{ leads: [...] }` per contract; tolerate a bare array too.
        let dtos: [LeadDTO]
        if let wrapped: LeadsDTO = try? decode(data), let list = wrapped.leads {
            dtos = list
        } else if let bare: [LeadDTO] = try? decode(data) {
            dtos = bare
        } else {
            throw APIError.decoding
        }
        return dtos.map(mapLead).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Write bodies (explicit snake_case)

    /// Listing → wire body. POST omits empty/zero fields (a fresh row); PATCH
    /// sends the FULL local truth, using JSON null to clear a server value the
    /// user removed (un-sell, drop the Zillow link, unknown beds) — a partial
    /// PATCH that omits them would leave stale values on the hosted page.
    private func listingBody(_ l: Listing, forPatch: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "space_type": l.spaceType.rawValue,
            "address": l.address,
        ]
        func put(_ key: String, _ value: Any, when present: Bool) {
            if present { b[key] = value } else if forPatch { b[key] = NSNull() }
        }
        put("price_cents", l.price.cents, when: l.price.cents > 0)
        put("beds", l.beds, when: l.beds > 0)
        put("baths", l.baths, when: l.baths > 0)
        put("sqft", l.sqft, when: l.sqft > 0)
        let tagline = l.tagline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        put("tagline", tagline, when: !tagline.isEmpty)
        if let d = l.details, !d.isEmpty {
            b["details"] = d
        } else if forPatch {
            b["details"] = [String: String]()   // column is NOT NULL default '{}'
        }
        if let lat = l.latitude, let lng = l.longitude, lat.isFinite, lng.isFinite {
            b["lat"] = coarseCoordinate(lat)
            b["lng"] = coarseCoordinate(lng)
        } else if forPatch {
            b["lat"] = NSNull()
            b["lng"] = NSNull()
        }
        let zillow = l.zillowURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        put("zillow_url", zillow, when: !zillow.isEmpty)
        if forPatch {
            // The DB check set is draft|capturing|processing|ready|expired|archived —
            // the app's transient `uploading` maps to `processing`; never sent raw.
            b["status"] = Self.wireStatus(l.status)
            b["sold_at"] = l.soldAt.map { Self.isoString(from: $0) } ?? NSNull()
        } else if let sold = l.soldAt {
            b["sold_at"] = Self.isoString(from: sold)
        }
        return b
    }

    /// Local → server status vocabulary (F-supabase-13).
    private static func wireStatus(_ s: Listing.Status) -> String {
        switch s {
        case .uploading:  return "processing"
        case .draft:      return "draft"
        case .processing: return "processing"
        case .ready:      return "ready"
        case .expired:    return "expired"
        }
    }

    /// Server → local status. `archived` (sold/archived folder) is a READY tour
    /// whose `sold_at` carries the archive state; `capturing` is a draft.
    private static func localStatus(_ raw: String?) -> Listing.Status {
        switch raw ?? "" {
        case "archived":  return .ready
        case "capturing": return .draft
        default:          return Listing.Status(rawValue: raw ?? "") ?? .draft
        }
    }

    // MARK: - DTO → model mapping

    private func mapListing(_ dto: ListingDTO) -> Listing {
        let serverID = dto.id.flatMap(UUID.init(uuidString:))
        var l = Listing(
            id: serverID ?? UUID(),
            address: dto.address ?? "",
            beds: dto.beds ?? 0,
            baths: dto.baths ?? 0,
            sqft: dto.sqft ?? 0,
            price: Money(cents: dto.priceCents ?? 0),
            status: Self.localStatus(dto.status),
            isSample: false,
            spaceTypeRaw: dto.spaceType,
            createdAt: Self.parseDate(dto.createdAt) ?? Date(),
            soldAt: Self.parseDate(dto.soldAt),
            zillowURL: dto.zillowUrl.flatMap { $0.isEmpty ? nil : $0 },
            mainPhotoRelPath: nil,          // main_photo_key is a remote R2 key, not a local path
            latitude: dto.lat,
            longitude: dto.lng,
            tagline: dto.tagline,
            details: dto.details?.value
        )
        l.serverID = serverID
        return l
    }

    private func mapLead(_ dto: LeadDTO) -> Lead {
        let name = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        return Lead(
            id: dto.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            listingID: dto.listingId.flatMap(UUID.init(uuidString:)),
            name: name.isEmpty ? "Someone" : name,
            phone: clean(dto.phone),
            email: clean(dto.email),
            message: clean(dto.message),
            extra: dto.extra?.value,
            createdAt: Self.parseDate(dto.createdAt) ?? Date(),
            source: clean(dto.source),
            listingAddress: clean(dto.listingAddress))
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

    /// Tolerant integer: accepts JSON ints, doubles (rounded), numeric strings
    /// and null — a count that arrives as `3.0` must not fail the whole /me.
    struct LenientInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }
            if let i = try? c.decode(Int.self) { value = i; return }
            if let d = try? c.decode(Double.self), d.isFinite { value = Int(d.rounded()); return }
            if let s = try? c.decode(String.self) { value = Int(s.trimmingCharacters(in: .whitespaces)); return }
            value = nil
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
        let zillowUrl: String?
        let mainPhotoKey: String?
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
        let costCents: Double?
        let currentStep: String?
        let error: String?
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
        let videoUrl: String?      // video_url (public URL, when the server sends one)
        let posterUrl: String?     // poster_url
        let poster: String?        // alt key some routes use
        let unbrandedUrl: String?  // unbranded_url — the MLS-safe /u/<slug> twin
    }

    /// 202 body of POST /ai-video/{drone,aerial,reel-clip} — fal's queue ids
    /// verbatim plus the route's `kind` and the aerial's `grounded`/`synthetic`
    /// flags. Extra fields (model_id, tier, …) are ignored. All optional →
    /// tolerant decode; required ones re-checked in `submitAIVideo`.
    private struct AIVideoJobDTO: Decodable {
        let requestId: String?     // request_id
        let statusUrl: String?     // status_url
        let responseUrl: String?   // response_url
        let kind: String?
        let grounded: Bool?
        let synthetic: Bool?
        /// The exact public disclosure sentence for this generation (W2-B3).
        let disclosure: String?
        let provenance: ProvenanceEnvelopeDTO?
    }

    /// `provenance: { id, recorded, reason? }` — the same envelope every AI
    /// route returns once the compliance wave landed.
    private struct ProvenanceEnvelopeDTO: Decodable {
        let id: String?
        let recorded: Bool?
        let reason: String?
    }

    /// Body of POST /ai-photo (a completed edit).
    private struct AIPhotoEditDTO: Decodable {
        let imageB64: String?
        let mime: String?
        let disclosure: String?
        let provenance: ProvenanceEnvelopeDTO?
    }

    /// Body of GET /me/compliance — the org's AI audit log.
    private struct ComplianceDTO: Decodable {
        let rows: [ComplianceRowDTO]?
    }

    /// One provenance row. `model` is the plain-words family (/tours);
    /// `model_id` is the vendor string (/me/compliance) and is deliberately not
    /// surfaced — the app shows the family.
    private struct ComplianceRowDTO: Decodable {
        let id: String?
        let listingId: String?
        let kind: String?
        let label: String?
        let edit: String?
        let style: String?
        let model: String?
        let disclosure: String?
        let originalUrl: String?
        let alteredUrl: String?
        let createdAt: String?
    }

    /// Body of GET /ai-video/status — one of processing/completed/failed.
    private struct AIVideoStatusDTO: Decodable {
        let status: String?
        let queuePosition: Int?    // queue_position (processing only, may be null)
        let videoUrl: String?      // video_url (completed only — EXPIRES)
        let error: String?         // failed only
    }

    private struct MeDTO: Decodable {
        struct User: Decodable {
            let id: String?
            let email: String?
            let name: String?
        }
        struct BrandKit: Decodable {
            let name: String?      // other brand fields are ignored (tolerant)
        }
        struct Org: Decodable {
            let id: String?
            let name: String?
            let handle: String?
            let plan: String?
            let brandKit: BrandKit?
        }
        struct Entitlement: Decodable {
            let rendersPerMonth: LenientInt?
            let photoEditsPerMonth: LenientInt?
            let reelsPerMonth: LenientInt?
            let aerialsPerMonth: LenientInt?
            let topazPerMonth: LenientInt?
            let seats: LenientInt?
        }
        struct Usage: Decodable {
            struct ByFeature: Decodable {
                let renders: LenientInt?
                let photoEdits: LenientInt?
                let reels: LenientInt?
                let aerials: LenientInt?
                let drone: LenientInt?
            }
            let month: String?
            let costCents: Double?   // cost_cents (round4 → may be fractional)
            let leads: LenientInt?
            let renders: LenientInt?
            let listings: LenientInt?
            let byFeature: ByFeature?
        }
        let user: User?
        let org: Org?
        let plan: String?
        let planRaw: String?
        let trialEndsAt: String?
        let entitlement: Entitlement?
        let usage: Usage?
    }

    private struct LeadsDTO: Decodable {
        let leads: [LeadDTO]?
    }

    private struct LeadDTO: Decodable {
        let id: String?
        let listingId: String?
        let name: String?
        let phone: String?
        let email: String?
        let message: String?
        let extra: TolerantStringMap?
        let createdAt: String?
        let source: String?
        let listingAddress: String?
    }
}
