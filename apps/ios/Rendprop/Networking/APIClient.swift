import Foundation

/// Render tier alias — the shared contract (audit DECISIONS §B1) names the type
/// `RenderTier`; the model keeps it nested as `Render.Tier`. Same type.
typealias RenderTier = Render.Tier

/// Result of `POST /uploads`. Expresses BOTH server modes (contract §2.1):
///  • `.single`    — one presigned PUT (`putURL`), files ≤ 64 MB / photos.
///  • `.multipart` — R2/S3 multipart (`uploadID` + `partSize` + `partCount`),
///                   large video, resumable, per-part retry.
/// Fields are optional per mode so one type covers both wire shapes and the
/// offline Mock (which returns a single-mode ticket with a nil `putURL`).
struct UploadTicket: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case single, multipart }

    let assetID: String        // server capture_assets id (contract: asset_id)
    let mode: Mode
    // single
    var putURL: URL? = nil     // presigned PUT; nil in offline dev
    // multipart
    var uploadID: String? = nil   // R2/S3 multipart upload id
    var partSize: Int64? = nil    // uniform part size (last part smaller)
    var partCount: Int? = nil     // ceil(bytes / partSize)
    // both
    var storageKey: String? = nil // R2 object key the file lands at
}

/// Probed video metadata threaded into `POST /uploads/:id/complete` (contract
/// §2.3). All optional — the server derives what it can; we send what we know.
struct UploadMetadata: Codable, Sendable, Hashable {
    var durationS: Double? = nil
    var fps: Double? = nil
    var width: Int? = nil
    var height: Int? = nil
    var codec: String? = nil
    var isDrone: Bool? = nil
    var hasGyro: Bool? = nil
    var bytes: Int64? = nil
    var sha256: String? = nil
}

/// One file in a photo batch request (`POST /uploads/batch`, contract §2.5).
struct PhotoUploadRequest: Codable, Sendable {
    let filename: String
    var bytes: Int64? = nil
    var sha256: String? = nil
    var contentType: String? = nil
}

/// One returned photo slot from `POST /uploads/batch`.
struct PhotoTicket: Codable, Sendable {
    let index: Int
    let assetID: String
    let putURL: URL
    var storageKey: String? = nil
}

/// The org's plan + monthly allowances, decoded from `GET /me` (`entitlement`,
/// `plan`, `plan_raw`, `trial_ends_at`, `usage.by_feature`). The app renders
/// these as "used of cap" rows and gates paid tiers — NEVER as prices.
struct Entitlements: Codable, Hashable {
    /// Effective plan (`effective_plan()` — an expired trial reads "free").
    var plan: String
    /// The stored plan before trial-expiry mapping (nil on older servers).
    var planRaw: String? = nil
    var trialEndsAt: Date? = nil
    var rendersPerMonth: Int
    var photoEditsPerMonth: Int
    var reelsPerMonth: Int
    var aerialsPerMonth: Int
    var topazPerMonth: Int
    /// This window's usage. Keys: renders, photo_edits, reels, aerials, drone.
    var used: [String: Int]
    var leads: Int

    /// Monthly cap for a `used` key (renders | photo_edits | reels | aerials | drone).
    func cap(for feature: String) -> Int {
        switch feature {
        case "renders":     return rendersPerMonth
        case "photo_edits": return photoEditsPerMonth
        case "reels":       return reelsPerMonth
        case "aerials":     return aerialsPerMonth
        case "drone":       return topazPerMonth
        default:            return 0
        }
    }

    /// Remaining allowance for a feature this window (never negative).
    func remaining(_ feature: String) -> Int {
        max(0, cap(for: feature) - (used[feature] ?? 0))
    }

    /// Topaz (Cinematic / 4K Premium) is an add-on — 0 means the tier is locked.
    var canUseTopaz: Bool { topazPerMonth > 0 }
    var canUseAerial: Bool { aerialsPerMonth > 0 }
    var isTrial: Bool { plan == "trial" }
}

/// This-month usage/cost rollup for the signed-in org (contract: GET /me → usage).
struct UsageSummary: Codable, Hashable {
    var aiSpendCents: Int? = nil   // usage.cost_cents (total infra+AI spend this month)
    var renderCount: Int? = nil    // usage.renders (this month)
    var leadCount: Int? = nil      // usage.leads
    var planName: String? = nil    // plan (effective plan string)
    /// Plan + allowances (nil on servers that predate the entitlement payload).
    var entitlements: Entitlements? = nil
    /// Identity the server holds — used to seed the public card, never shown as
    /// an email (the public agent name must never fall back to one).
    var userName: String? = nil    // user.name
    var orgName: String? = nil     // org.name
    var brandName: String? = nil   // org.brand_kit.name (the hosted card headline)

    /// AI spend as Money (integer-cents guardrail). Zero when unknown.
    var aiSpend: Money { Money(cents: aiSpendCents ?? 0) }
}

/// One AI-recommended edit for a photo (`POST /ai-photo`, edit: "suggest").
/// `edit` is one of the preset keys (twilight | sky | lawn | declutter |
/// stage); `reason` is a one-line why; `confidence` is 0–1 when the server
/// sends it, nil otherwise.
struct AIEditSuggestion: Codable, Sendable {
    let edit: String
    let reason: String
    let confidence: Double?
}

/// One AI-altered or AI-generated asset in the org's provenance log
/// (`GET /me/compliance?listing_id=`, W2-B3). This is the row a broker or a
/// compliance officer is entitled to see, and the row the public tour prints
/// its disclosure from.
///
/// `disclosure` is the legally-required sentence (California AB 723 from
/// 1 Jan 2026; NorthstarMLS from 10 Jul 2026; Wisconsin Act 69 from
/// 1 Jan 2027). It is NEVER null and it is shown VERBATIM — never summarised,
/// truncated or re-worded by the app.
struct ProvenanceRecord: Identifiable, Hashable, Sendable {
    /// `media_provenance.id` (a server UUID string).
    let id: String
    var listingID: UUID? = nil
    /// photo_edit | virtual_stage | declutter | aerial | reel | other.
    var kind: String
    /// "Living room", "Aerial intro" — may be null; fall back to `displayLabel`.
    var label: String? = nil
    /// The preset that ran (twilight | sky | lawn | declutter | stage | custom |
    /// aerial | reel), when the server recorded one.
    var edit: String? = nil
    var style: String? = nil
    /// Model family in plain words — "AI image edit" | "AI video". Never a
    /// vendor model string (that stays in the org's own CSV export).
    var model: String
    /// The exact public sentence. Show verbatim.
    var disclosure: String
    /// The UNALTERED original, when it was published (CA AB 723's
    /// "access to the original"). Nil = we never got one.
    var originalURL: URL? = nil
    /// The published altered asset, when one exists.
    var alteredURL: URL? = nil
    var createdAt: Date? = nil

    /// Plain-words model family for a kind — mirrors `modelFamily()` in
    /// services/supabase/functions/tours/index.ts, for the routes that send the
    /// raw `model_id` instead.
    static func modelFamily(_ kind: String) -> String {
        (kind == "aerial" || kind == "reel") ? "AI video" : "AI image edit"
    }

    /// Human name for a `kind` — used when the row carries no label.
    static func kindName(_ kind: String) -> String {
        switch kind {
        case "photo_edit":    return "Edited photo"
        case "virtual_stage": return "Virtually staged photo"
        case "declutter":     return "Decluttered photo"
        case "aerial":        return "Aerial intro"
        case "reel":          return "Reel clip"
        default:              return "Altered media"
        }
    }

    /// What the row is called on screen — its label, else a human name for its kind.
    var displayLabel: String {
        if let l = label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { return l }
        return Self.kindName(kind)
    }

    /// True when the unaltered original is publicly reachable. Amber when false:
    /// the disclosure is there but the "access to the original" half is not.
    var hasOriginal: Bool { originalURL != nil }
}

/// One `POST /ai-photo` edit. Carries the COMPLIANCE fields alongside the
/// image: the listing the photo belongs to (without it the server cannot log
/// the edit at all), a human label for the disclosure line, and the asset id of
/// the untouched ORIGINAL uploaded with `role:"original"` — which is what makes
/// the public "View original" link real (California AB 723).
struct AIPhotoEditRequest: Sendable, Hashable {
    var imageBase64: String
    var mime: String = "image/jpeg"
    /// "twilight" | "sky" | "lawn" | "declutter" | "stage" | "custom".
    var edit: String
    /// Stage only ("modern" | "rustic" | "minimalist" | "scandinavian").
    var style: String? = nil
    /// Custom only (free text, ≤ 600 chars server-side).
    var prompt: String? = nil
    /// SERVER listing id (`listings.id`), never the local UUID.
    var listingServerID: UUID? = nil
    /// "Living room", "Front exterior" — printed next to the public disclosure.
    var label: String? = nil
    /// `capture_assets.id` of the untouched source (uploads `role:"original"`).
    var originalAssetID: String? = nil
    /// One UUID per user TAP (billed provider call).
    var idempotencyKey: String? = nil
}

/// The result of one `/ai-photo` edit: the image plus its compliance envelope.
struct AIPhotoEditResult: Sendable, Hashable {
    /// Base64 of the edited image.
    let imageBase64: String
    var mime: String? = nil
    /// The exact sentence the public tour will print for this asset. Show it
    /// VERBATIM. Nil only on a server that predates the compliance wave.
    var disclosure: String? = nil
    /// `media_provenance.id` when the row was written.
    var provenanceID: String? = nil
    /// False when the edit could NOT be entered in the audit log (no listing id
    /// yet, RLS, a DB error). The edit itself still succeeded.
    var provenanceRecorded: Bool = false
    /// The server's reason, when it sent one.
    var provenanceReason: String? = nil
}

/// Everything the Aerial intro sheet knows about THE PROPERTY, sent to
/// `POST /ai-video/aerial` (contract §B4). With `imageJPEGBase64` the server runs
/// image-to-video grounded on the exterior photo; without it the result is a
/// generic invented building of the right `spaceType`. The street address is
/// never sent — only a coarse `region` ("Charlotte, NC").
struct AerialRequest: Sendable, Hashable {
    var imageJPEGBase64: String? = nil    // ≤1280 px long edge, JPEG q0.85, base64 (no data: prefix)
    var mime: String? = nil               // "image/jpeg"
    var spaceType: String                 // SpaceType.rawValue
    var region: String? = nil             // "Charlotte, NC" — never a street address
    var timeOfDay: String = "golden_hour" // golden_hour | midday | twilight | overcast
    var motion: String = "rise_reveal"    // rise_reveal | pull_back | orbit | push_in
    var style: String? = nil              // ≤200 chars free-text look hint
    var seconds: Int = 6                  // 4 | 6 | 8
    var aspect: String = "16:9"           // "16:9" | "9:16"
    /// SERVER listing id — anchors the aerial's provenance row so the clip is
    /// disclosed on the tour and appears in the broker's audit log (W2-C4).
    var listingServerID: UUID? = nil
    /// Label for the public disclosure line (defaults to "Aerial intro"
    /// server-side).
    var label: String? = nil

    var isGrounded: Bool { !(imageJPEGBase64 ?? "").isEmpty }
}

/// A prospect who submitted the hosted tour's lead form (`GET /leads`).
struct Lead: Identifiable, Codable, Hashable {
    var id: UUID
    var listingID: UUID? = nil
    var name: String
    var phone: String? = nil
    var email: String? = nil
    var message: String? = nil
    var extra: [String: String]? = nil
    var createdAt: Date
    var source: String? = nil
    var listingAddress: String? = nil
}

/// One tap-to-jump chapter sent with a publish (`{label, t_ms, sort}` on the
/// wire). `tMs` is on the RENDERED timeline (already divided by speedFactor).
struct ChapterInput: Codable, Hashable, Sendable {
    var label: String
    var tMs: Int
    var sort: Int

    /// Snake_case wire shape for `POST /renders/publish-app` / `PATCH /renders/:id/chapters`.
    var wireDictionary: [String: Any] { ["label": label, "t_ms": tMs, "sort": sort] }
}

/// The app talks only to this protocol. MockAPIClient makes the whole app run
/// offline; LiveAPIClient points at the Supabase Edge Functions API
/// (docs/UPLOAD-AND-PUBLISH-CONTRACT.md §2).
///
/// Idempotency: writes that can be retried carry a STABLE `Idempotency-Key`.
/// Publish derives its own (`"publish:<listing>:<asset>"`), upload tickets use
/// `"ticket:<sha256|path-hash>:<bytes>"`, and the AI generate calls take a
/// caller-supplied key — one UUID per user TAP (so a retry of the same tap
/// replays instead of billing twice, and a second tap is a new job).
protocol APIClient: Sendable {
    func listings() async throws -> [Listing]
    func createListing(_ listing: Listing) async throws -> Listing
    /// PATCH `listings/<serverID>` (falls back to the local id only when the
    /// listing was never created server-side). Sends the full local truth:
    /// address, price, beds/baths/sqft, tagline, details, lat/lng, zillow_url,
    /// sold_at (JSON null to un-sell) and status (`uploading` → `processing`).
    func updateListing(_ listing: Listing) async throws -> Listing
    /// DELETE `listings/<serverID>` — soft-deletes and unpublishes its tours.
    func deleteListing(serverID: UUID) async throws

    // MARK: Uploads (contract §2)

    /// POST /uploads → an `UploadTicket` (single OR multipart). The server
    /// decides the mode (video > 64 MB → multipart).
    ///
    /// `role` routes the object: "capture" → private uploads bucket; "render" →
    /// the PUBLIC renders bucket for an app-rendered tour (contract §2.7).
    /// `kind` is "video" or "photo" (a `role:"render"` photo is a tour poster).
    /// `contentType` is what the app will PUT with — the server stores it on the
    /// ticket and `/complete` rejects an object whose type differs (P0 audit
    /// fix: derive it from the file extension, never hardcode).
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?,
                       idempotencyKey: String?) async throws -> UploadTicket

    /// POST /uploads/:asset_id/part-urls → presigned URLs for the given 1-based
    /// part numbers. URLs expire in ~1 h, so request them as you go / on resume.
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL]

    /// POST /uploads/:asset_id/complete. `parts` non-nil ⇒ multipart (ETag
    /// manifest, REQUIRED); `parts` nil ⇒ single. `metadata` carries the probed
    /// video fields. ONE-SHOT server-side: a replay returns 409 "already
    /// complete", which callers treat as success.
    func completeUpload(assetID: String,
                        parts: [(number: Int, etag: String)]?,
                        metadata: UploadMetadata) async throws

    /// POST /uploads/:asset_id/abort — tears down the in-flight R2 multipart
    /// session. Safe to call on cancel.
    func abortUpload(assetID: String) async throws

    /// POST /uploads/batch → one presigned PUT slot per photo (contract §2.5).
    func requestPhotoBatch(listingID: UUID, files: [PhotoUploadRequest]) async throws -> [PhotoTicket]

    /// Legacy single-complete kept for source compatibility (offline dev / any
    /// caller still on the old signature). Prefer `completeUpload(assetID:parts:metadata:)`.
    func completeUpload(id: String, sha256: String?) async throws

    // MARK: Renders / account

    /// POST /renders — the worker-path render job (not used by the live
    /// app-render + publish-app flow). The contract REQUIRES `asset_id`.
    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render
    func renderStatus(id: UUID) async throws -> Render

    /// POST /renders/publish-app (contract §2.7) — publishes the app's ON-DEVICE
    /// render as the hosted tour (no Python worker). `assetID` MUST be the SERVER
    /// asset_id of the role=render upload (from `UploadManager.upload`).
    /// `posterAssetID` is the optional `kind:"photo", role:"render"` asset from
    /// `UploadManager.uploadPoster` (first frame JPEG) — the hosted page's
    /// og:image / video poster. Idempotent per (listing, asset): a retry after a
    /// lost response returns the SAME tour instead of minting a second slug.
    /// Returns the real server slug + share URL + `renderID` (renders.id).
    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, tier: RenderTier,
                    enhancements: Enhancements, chapters: [ChapterInput],
                    posterAssetID: String?) async throws -> PublishedTour

    /// PATCH /renders/:id/chapters — replace the published tour's tap-to-jump
    /// chapters (room tags retimed to the rendered timeline) without re-publishing.
    func updateChapters(renderID: UUID, chapters: [ChapterInput]) async throws

    /// GET /me — plan, allowances and this month's usage for Settings + tier gating.
    func me() async throws -> UsageSummary

    /// GET /leads[?listing_id=] — every lead captured on the org's hosted tours
    /// (RLS-scoped), newest first. `listingServerID` filters to one listing.
    func leads(listingServerID: UUID?) async throws -> [Lead]

    /// PATCH /me/brand — push the agent/business card into the org's brand kit
    /// so it renders on every HOSTED tour page (the public tours/portfolio
    /// functions allow-list exactly these fields). Empty-string values clear
    /// the field server-side. Best-effort: callers fire-and-forget.
    func updateBrand(_ fields: [String: String]) async throws

    /// POST /ai-photo — single-image AI edit. `request.edit` = "twilight" |
    /// "sky" | "lawn" | "declutter" | "stage" | "custom"; `style` applies to
    /// stage only, `prompt` to custom only. Sends the photo as base64 and
    /// returns the edited image PLUS its compliance envelope: the exact
    /// `disclosure` sentence the public tour will print, and whether the edit
    /// was entered in the org's audit log.
    ///
    /// Send `listingServerID` and `originalAssetID` whenever you have them —
    /// without a listing id nothing is logged at all, and without the original
    /// asset the public "View original" link (California AB 723) is dead.
    ///
    /// Throws `APIError.server(status: 400, code: "unsupported_edit", ...)` when
    /// the fair-housing denylist refuses a free-text prompt. Show the server's
    /// message, let the user re-word, and NEVER auto-retry.
    func aiPhotoEdit(_ request: AIPhotoEditRequest) async throws -> AIPhotoEditResult

    /// GET /me/compliance?listing_id= — the org's AI provenance rows for one
    /// listing (member-gated), newest first. Every row's `disclosure` is the
    /// legally-required sentence and is shown VERBATIM.
    func provenance(listingServerID: UUID) async throws -> [ProvenanceRecord]

    /// GET /me/compliance?format=csv — the broker-exportable AI audit log as raw
    /// CSV bytes. `listingServerID` narrows it to one listing; nil exports the
    /// whole workspace.
    func complianceCSV(listingServerID: UUID?) async throws -> Data

    /// PATCH /me/compliance/:id — attach the untouched ORIGINAL and/or the
    /// published ALTERED result to a provenance row after their uploads land.
    /// The original alone satisfies California AB 723's access requirement; both
    /// together let the tour render the side-by-side "Before / after" pair
    /// NorthstarMLS asks for. Each id is a `capture_assets.id` of an uploaded
    /// PHOTO in the public renders bucket for the SAME listing — the server
    /// refuses anything else, so "View original" can never be spoofed.
    func attachProvenanceMedia(provenanceID: String, originalAssetID: String?,
                               alteredAssetID: String?) async throws

    /// POST /ai-photo with `edit: "suggest"` — the AI looks at the photo and
    /// returns up to 3 recommended preset edits (twilight | sky | lawn |
    /// declutter | stage), each with a one-line reason and an optional 0–1
    /// confidence. An empty array means the photo already looks good. Not
    /// charged against the monthly photo-edit allowance (separate burst limit).
    func aiPhotoSuggest(imageBase64: String, mime: String) async throws -> [AIEditSuggestion]

    /// POST /ai-photo with `edit: "improve_prompt"` — rewrites a rough
    /// custom-edit idea (≤ 300 chars sent) into a sharper, more specific prompt
    /// (≤ 400 back). The function requires `image_b64` on every call, so the
    /// photo rides along; the rewrite itself is text-only. Not charged against
    /// the monthly allowance.
    func aiImprovePrompt(imageBase64: String, mime: String, prompt: String) async throws -> String

    // MARK: AI video (ai-video edge function — async fal submit + poll)

    /// POST /ai-video/drone — Topaz motion smoothing + upscale of an UPLOADED
    /// role="render" asset (public renders bucket, or the server 400s).
    /// `tier` = "1080p60" | "4k30" | "4k60". Returns the queued job to poll.
    /// 402 when the plan's `topaz_per_month` is 0 (Team add-on).
    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?,
                      idempotencyKey: String?) async throws -> AIVideoJob

    /// POST /ai-video/aerial — AI establishing shot grounded on the property's
    /// exterior photo when `request.imageJPEGBase64` is set (Seedance image-to-
    /// video: starts on the photo and flies out), otherwise a generic invented
    /// building of the right space type (Veo text-to-video). The street address
    /// is never sent. `AIVideoJob.grounded`/`.synthetic` echo the server's
    /// flags so the UI can disclose "AI-generated — not real drone footage".
    func aiVideoAerial(_ request: AerialRequest, idempotencyKey: String?) async throws -> AIVideoJob

    /// POST /ai-video/reel-clip — animate a photo (base64) into a 2–12 s motion
    /// clip (Seedance image-to-video). `listingServerID` anchors the clip's
    /// provenance row so the generated motion is disclosed on the tour and in
    /// the broker's audit log.
    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         listingServerID: UUID?, label: String?,
                         idempotencyKey: String?) async throws -> AIVideoJob

    /// GET /ai-video/status — poll one submitted job. fal result URLs EXPIRE, so
    /// download the video promptly on `.completed`.
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus
}

// MARK: - Convenience overloads (protocol requirements can't carry defaults)
extension APIClient {
    /// Capture uploads (the common case) don't specify a role or type.
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String) async throws -> UploadTicket {
        try await requestUpload(filename: filename, bytes: bytes, listingID: listingID,
                                sha256: sha256, kind: kind, role: "capture",
                                contentType: nil, idempotencyKey: nil)
    }

    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String) async throws -> UploadTicket {
        try await requestUpload(filename: filename, bytes: bytes, listingID: listingID,
                                sha256: sha256, kind: kind, role: role,
                                contentType: nil, idempotencyKey: nil)
    }

    /// Aerial without a caller key (a fresh key is minted per call, so a retry
    /// is a new job — prefer the keyed variant from the sheet's per-tap UUID).
    func aiVideoAerial(_ request: AerialRequest) async throws -> AIVideoJob {
        try await aiVideoAerial(request, idempotencyKey: nil)
    }

    /// Source-compatible edit without the compliance fields — returns only the
    /// image. Prefer `aiPhotoEdit(_:)`: the listing id, the label and the
    /// original asset id are what make the disclosure and the public
    /// "View original" link real.
    func aiPhotoEdit(imageBase64: String, mime: String, edit: String,
                     style: String?, prompt: String?,
                     idempotencyKey: String?) async throws -> String {
        try await aiPhotoEdit(AIPhotoEditRequest(imageBase64: imageBase64, mime: mime, edit: edit,
                                                 style: style, prompt: prompt,
                                                 idempotencyKey: idempotencyKey)).imageBase64
    }

    func aiPhotoEdit(imageBase64: String, mime: String, edit: String,
                     style: String?, prompt: String?) async throws -> String {
        try await aiPhotoEdit(imageBase64: imageBase64, mime: mime, edit: edit,
                              style: style, prompt: prompt, idempotencyKey: nil)
    }

    /// Whole-workspace audit export (every listing).
    func complianceCSV() async throws -> Data {
        try await complianceCSV(listingServerID: nil)
    }

    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?) async throws -> AIVideoJob {
        try await aiVideoDrone(assetID: assetID, tier: tier, targetFps: targetFps, idempotencyKey: nil)
    }

    /// Source-compatible reel clip with no listing anchor — the generation is
    /// NOT entered in the compliance log. Prefer the listing-aware requirement.
    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int,
                         idempotencyKey: String?) async throws -> AIVideoJob {
        try await aiVideoReelClip(imageBase64: imageBase64, mime: mime, prompt: prompt,
                                  seconds: seconds, listingServerID: nil, label: nil,
                                  idempotencyKey: idempotencyKey)
    }

    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int) async throws -> AIVideoJob {
        try await aiVideoReelClip(imageBase64: imageBase64, mime: mime, prompt: prompt,
                                  seconds: seconds, listingServerID: nil, label: nil,
                                  idempotencyKey: nil)
    }

    /// Source-compat for the pre-audit publish call (`staged:` + raw chapter
    /// dictionaries). `staged` is derived server-side from `enhancements`, so it
    /// is dropped; dictionaries are converted to `ChapterInput`. Prefer the
    /// poster-aware requirement.
    @available(*, deprecated, message: "Use publishApp(listingID:assetID:durationS:speedFactor:tier:enhancements:chapters:posterAssetID:)")
    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, staged: Bool, tier: Render.Tier,
                    enhancements: Enhancements, chapters: [[String: Any]]) async throws -> PublishedTour {
        _ = staged
        let converted: [ChapterInput] = chapters.enumerated().compactMap { idx, dict in
            guard let label = (dict["label"] as? String) ?? (dict["name"] as? String), !label.isEmpty else { return nil }
            let t = (dict["t_ms"] as? Int) ?? (dict["tMs"] as? Int) ?? Int(((dict["t_ms"] as? Double) ?? 0).rounded())
            let sort = (dict["sort"] as? Int) ?? idx
            return ChapterInput(label: label, tMs: max(0, t), sort: sort)
        }
        return try await publishApp(listingID: listingID, assetID: assetID, durationS: durationS,
                                    speedFactor: speedFactor, tier: tier, enhancements: enhancements,
                                    chapters: converted, posterAssetID: nil)
    }
}

/// One submitted ai-video job (202 from `POST /ai-video/*`). Carries fal's own
/// queue URLs verbatim — stateless v1: nothing is persisted server-side, the
/// app holds these and polls `aiVideoStatus` until completed/failed.
struct AIVideoJob: Codable, Sendable {
    let requestId: String       // request_id
    let statusUrl: String       // status_url (queue.fal.run — polled via our server)
    let responseUrl: String     // response_url
    let kind: String            // "drone" | "aerial" | "reel" | "declutter"
    /// Aerial only: true when the server ran image-to-video on the exterior
    /// photo (the clip depicts THIS property); false = generic invented scenery.
    var grounded: Bool? = nil
    /// True for AI-generated footage the UI must disclose as such.
    var synthetic: Bool? = nil
    /// The exact disclosure sentence for THIS generation, written by the server
    /// (an aerial's begins "Drone-style movement is simulated. No drone footage
    /// was captured."). Show it verbatim in the app and in the share text.
    /// Optional so a job persisted by an older build still decodes.
    var disclosure: String? = nil
    /// `media_provenance.id` when the server logged the generation.
    var provenanceID: String? = nil

    /// The sentence to show when the server sent none (older server / offline):
    /// HousingWire's recommended simulated-movement disclosure.
    static let aerialFallbackDisclosure =
        "Drone-style movement is simulated. No drone footage was captured. "
        + "This establishing shot was generated by AI."

    /// The disclosure to print for this job — the server's own sentence when it
    /// sent one, otherwise the aerial fallback for aerials. Never empty for an
    /// aerial; nil for kinds we have no canned sentence for.
    var disclosureText: String? {
        if let d = disclosure?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return kind == "aerial" ? Self.aerialFallbackDisclosure : nil
    }
}

/// One poll of `GET /ai-video/status`.
enum AIVideoStatus: Sendable {
    case processing(queuePosition: Int?)
    /// fal result URLs EXPIRE — download the file promptly.
    case completed(videoURL: URL)
    case failed(String)
}

/// Result of `POST /renders/publish-app` — the app-published tour's public
/// identity. `slug`/`shareURL` are the REAL server values (never fabricated).
struct PublishedTour: Sendable, Hashable {
    let slug: String
    let shareURL: String
    /// The MLS-safe `/u/<slug>` twin (`unbranded_url`). Optional — a server
    /// that predates the compliance wave doesn't send it and the app derives
    /// it from the slug instead.
    var unbrandedURL: String? = nil
    var videoURL: String? = nil
    var posterURL: String? = nil
    var durationS: Double? = nil
    var staged: Bool? = nil
    /// Server `renders.id` — the id `PATCH /renders/:id/chapters` takes.
    var renderID: UUID? = nil
}

/// Errors from the API layer. `.server` carries the backend's `{error, code}`
/// envelope verbatim so the UI can show the message the server wrote for the
/// user ("…Upgrade for more", "try again in a few minutes", "already complete")
/// instead of a bare status code. `errorDescription` IS that message.
enum APIError: Error, LocalizedError {
    case invalidURL
    case badResponse(Int)
    case decoding
    case notConfigured
    /// Non-2xx with the server's envelope. `code` is one of: validation |
    /// unauthorized | forbidden | not_found | conflict | plan_required |
    /// quota_exceeded | rate_limited | payload_too_large | upstream | internal
    /// (nil on older servers — the status still classifies it).
    case server(status: Int, code: String?, message: String)

    /// HTTP status when known (nil for invalidURL/decoding/notConfigured and
    /// for a `badResponse` with no real status).
    var status: Int? {
        switch self {
        case .badResponse(let c):       return c > 0 ? c : nil
        case .server(let s, _, _):      return s
        case .invalidURL, .decoding, .notConfigured: return nil
        }
    }

    /// Machine-readable server code when the envelope carried one.
    var code: String? {
        if case .server(_, let c, _) = self { return c }
        return nil
    }

    /// 402 — plan boundary / monthly allowance reached → show an "Upgrade plan"
    /// CTA opening `Config.pricingURL` (no prices in-app).
    var isQuota: Bool { status == 402 || code == "quota_exceeded" || code == "plan_required" }
    /// 401 — session expired/revoked → re-prompt sign-in.
    var isUnauthorized: Bool { status == 401 || code == "unauthorized" }
    /// 409 — duplicate / already complete / account deleting.
    var isConflict: Bool { status == 409 || code == "conflict" }
    /// 429 — burst or daily limit → "try again in a few minutes".
    var isRateLimited: Bool { status == 429 || code == "rate_limited" }
    var isNotFound: Bool { status == 404 || code == "not_found" }
    var isForbidden: Bool { status == 403 || code == "forbidden" }
    var isPayloadTooLarge: Bool { status == 413 || code == "payload_too_large" }
    /// 400 — the request itself was rejected; retrying identically won't help.
    var isValidation: Bool { status == 400 || code == "validation" }

    /// A `/complete` replay on an upload the server already accepted — success.
    var isAlreadyComplete: Bool {
        guard isConflict, case .server(_, _, let message) = self else { return false }
        return message.localizedCaseInsensitiveContains("already complete")
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server address is invalid."
        case .notConfigured:
            return "No API server configured — running in offline mode."
        case .decoding:
            return "The server sent an unexpected response. Please try again."
        case .badResponse(let c):
            return c > 0 ? "Server returned status \(c)." : "The server returned an unexpected response."
        case .server(_, _, let message):
            return message
        }
    }

    var recoverySuggestion: String? {
        if isQuota { return "Upgrade your plan to continue." }
        if isRateLimited { return "Try again in a few minutes." }
        if isUnauthorized { return "Sign in again to continue." }
        return nil
    }

    /// Friendly fallback when the server sent no `error` string for a status.
    static func defaultMessage(for status: Int) -> String {
        switch status {
        case 400: return "The server rejected the request."
        case 401: return "Your session has expired. Please sign in again."
        case 402: return "This feature isn't included in your current plan."
        case 403: return "You don't have permission to do that in this workspace."
        case 404: return "That item wasn't found on the server."
        case 409: return "That action conflicts with the current state — please try again."
        case 413: return "That file is too large to send."
        case 429: return "Too many requests — try again in a few minutes."
        case 500..<600: return "The server had a problem. Please try again shortly."
        default: return "Server returned status \(status)."
        }
    }
}
