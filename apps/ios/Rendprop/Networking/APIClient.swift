import Foundation

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

/// This-month usage/cost rollup for the signed-in org (contract: GET /me → usage).
struct UsageSummary: Codable, Hashable {
    var aiSpendCents: Int? = nil   // usage.cost_cents (total infra+AI spend this month)
    var renderCount: Int? = nil    // usage.renders
    var leadCount: Int? = nil      // usage.leads
    var planName: String? = nil    // plan (scalar string)

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

/// The app talks only to this protocol. MockAPIClient makes the whole app run
/// offline; LiveAPIClient points at the Supabase Edge Functions API
/// (docs/UPLOAD-AND-PUBLISH-CONTRACT.md §2).
protocol APIClient: Sendable {
    func listings() async throws -> [Listing]
    func createListing(_ listing: Listing) async throws -> Listing
    func updateListing(_ listing: Listing) async throws -> Listing

    // MARK: Uploads (contract §2)

    /// POST /uploads → an `UploadTicket` (single OR multipart). `listingID`,
    /// `sha256`, and `kind` complete the contract body; all optional-friendly so
    /// callers that only have a file can still request a ticket. The server
    /// decides the mode (video > 64 MB → multipart).
    ///
    /// `role` routes the object: "capture" (default) → private uploads bucket;
    /// "render" → the PUBLIC renders bucket for an app-rendered tour (contract
    /// §2.7). A convenience overload below defaults `role` to "capture" so
    /// existing capture call sites are unchanged.
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String) async throws -> UploadTicket

    /// POST /uploads/:asset_id/part-urls → presigned URLs for the given 1-based
    /// part numbers. URLs expire in ~1 h, so request them as you go / on resume.
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL]

    /// POST /uploads/:asset_id/complete. `parts` non-nil ⇒ multipart (ETag
    /// manifest, REQUIRED); `parts` nil ⇒ single. `metadata` carries the probed
    /// video fields.
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

    /// POST /renders — the contract REQUIRES `asset_id`, so it flows through here.
    func createRender(listingID: UUID, assetID: UUID, tier: Render.Tier, durationS: Double,
                      enhancements: Enhancements) async throws -> Render
    func renderStatus(id: UUID) async throws -> Render

    /// POST /renders/publish-app (contract §2.7) — publishes the app's ON-DEVICE
    /// render as the hosted tour (no Python worker). `assetID` MUST be the SERVER
    /// asset_id of the role=render upload (from `requestUpload`/`/complete`).
    /// `chapters` are room tags mapped to `[{label, t_ms, sort}]`. Returns the
    /// real server slug + public share URL.
    func publishApp(listingID: UUID, assetID: String, durationS: Double,
                    speedFactor: Double, staged: Bool, tier: Render.Tier,
                    enhancements: Enhancements, chapters: [[String: Any]]) async throws -> PublishedTour

    /// GET /me — usage/cost for the Settings "Usage" section.
    func me() async throws -> UsageSummary

    /// PATCH /me/brand — push the agent/business card into the org's brand kit
    /// so it renders on every HOSTED tour page (the public tours/portfolio
    /// functions allow-list exactly these fields). Empty-string values clear
    /// the field server-side. Best-effort: callers fire-and-forget.
    func updateBrand(_ fields: [String: String]) async throws

    /// POST /ai-photo — single-image AI edit. `edit` = "twilight" | "sky" |
    /// "lawn" | "declutter" | "stage" | "custom". `style` applies to stage only
    /// ("modern" | "rustic" | "minimalist" | "scandinavian"); `prompt` to custom
    /// only (free text, ≤ 600 chars). Pass nil for both on the preset edits.
    /// Sends the photo as base64, returns the edited image as base64 (PNG).
    func aiPhotoEdit(imageBase64: String, mime: String, edit: String,
                     style: String?, prompt: String?) async throws -> String

    /// POST /ai-photo with `edit: "suggest"` — the AI looks at the photo and
    /// returns up to 3 recommended preset edits (twilight | sky | lawn |
    /// declutter | stage), each with a one-line reason and an optional 0–1
    /// confidence. An empty array means the photo already looks good.
    func aiPhotoSuggest(imageBase64: String, mime: String) async throws -> [AIEditSuggestion]

    /// POST /ai-photo with `edit: "improve_prompt"` — rewrites a rough
    /// custom-edit idea (≤ 300 chars sent) into a sharper, more specific prompt
    /// (≤ 400 back). The target photo rides along because the function requires
    /// `image_b64` — and it lets the AI tailor the prompt to the actual shot.
    func aiImprovePrompt(imageBase64: String, mime: String, prompt: String) async throws -> String

    // MARK: AI video (ai-video edge function — async fal submit + poll)

    /// POST /ai-video/drone — Topaz motion smoothing + upscale of an UPLOADED
    /// role="render" asset (public renders bucket, or the server 400s).
    /// `tier` = "1080p60" | "4k30" | "4k60". Returns the queued job to poll.
    func aiVideoDrone(assetID: String, tier: String, targetFps: Int?) async throws -> AIVideoJob

    /// POST /ai-video/aerial — SYNTHETIC AI establishing shot (Veo). `style` is
    /// an optional look-and-feel hint ("modern glass house with a pool") woven
    /// into the server's guarded prompt; the street address is deliberately NOT
    /// sent — Veo's safety filter rejects prompts naming real addresses, and it
    /// adds nothing visually. `seconds` snaps to 4/6/8; `aspect` = "16:9"|"9:16".
    /// The UI must always disclose the result as AI-generated footage.
    func aiVideoAerial(style: String?, prompt: String?, seconds: Int, aspect: String) async throws -> AIVideoJob

    /// POST /ai-video/reel-clip — animate a photo (base64) into a 2–12 s motion
    /// clip (Seedance image-to-video).
    func aiVideoReelClip(imageBase64: String, mime: String, prompt: String?, seconds: Int) async throws -> AIVideoJob

    /// GET /ai-video/status — poll one submitted job. fal result URLs EXPIRE, so
    /// download the video promptly on `.completed`.
    func aiVideoStatus(_ job: AIVideoJob) async throws -> AIVideoStatus
}

extension APIClient {
    /// Back-compat overload — capture uploads (the common case) don't specify a
    /// role. Forwards to the role-aware requirement with `role: "capture"`.
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String) async throws -> UploadTicket {
        try await requestUpload(filename: filename, bytes: bytes, listingID: listingID,
                                sha256: sha256, kind: kind, role: "capture")
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
    var videoURL: String? = nil
    var posterURL: String? = nil
    var durationS: Double? = nil
    var staged: Bool? = nil
    var renderID: UUID? = nil
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
