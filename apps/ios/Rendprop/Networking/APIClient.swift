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

    /// Server-declared admin flag (`/me` → `is_admin`). nil = this server build
    /// does not send it, which is the case today (the admin role lives in
    /// `public.profiles.is_admin` and is read only by the admin function). The
    /// owner console then probes `GET /admin/spend` once and hides itself on a
    /// 403. NEVER derive this from a hardcoded email or a local flag: the
    /// server is the enforcement, this only decides whether a row is drawn.
    var isAdmin: Bool? = nil
    /// Membership role when the server sends one ("owner" | "admin" | "agent" |
    /// "marketing"). Secondary to `isAdmin`.
    var role: String? = nil

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

// MARK: - AI voiceover (ai-voice edge function — docs/VOICEOVER-CONTRACT.md)

/// One ElevenLabs voice from `GET /ai-voice/voices`.
///
/// Wire fields are Optional and decoded leniently — a new field, a null, or a
/// voice the vendor returns half-populated must never fail the whole picker.
/// Read through the non-optional accessors; the array the client hands back has
/// already dropped anything with no usable id.
struct AIVoice: Codable, Identifiable, Hashable, Sendable {
    // Wire (snake_case → camelCase via .convertFromSnakeCase).
    let voiceId: String?
    let name: String?
    /// Pre-flattened by the server into one display string ("narration · american").
    let labels: String?

    /// The id to send to `aiVoiceTTS`. Empty only for a row the client filtered out.
    var voiceID: String { voiceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var id: String { voiceID }
    /// What the picker row shows. Never empty.
    var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Voice" : n
    }
    /// The secondary line under the name. Empty when the vendor sent no labels.
    var subtitle: String { labels?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

/// The finished result of `POST /ai-voice/tts`: an audio file to download plus
/// the word timings the captions are drawn from.
///
/// `words` may be EMPTY and that is a normal state, not an error — the server
/// returns no words rather than inventing timings when ElevenLabs' alignment is
/// missing or malformed, and captions then simply don't render (per the
/// contract: captions degrade off, they never drift).
struct AIVoiceResult: Sendable, Equatable {
    /// Short-lived SIGNED R2 URL (~15 min). Download it immediately — this is
    /// not a permanent address and it is not safe to persist.
    let audioURL: URL
    /// Seconds. See `durationSource` before laying out a video on it.
    let durationS: Double
    /// Word timings relative to the START of this audio, ready for `CaptionWord`
    /// consumers. Empty means "no captions", never "captions at zero".
    let words: [CaptionWord]
    /// The voice's display name ("Rachel"), for the disclosure and the UI.
    let voiceName: String
    /// Characters billed to ElevenLabs for this script.
    let characters: Int
    /// "audio/mpeg".
    let mime: String
    /// Where `durationS` came from, verbatim from the server:
    /// `"alignment"` (authoritative) | `"bitrate_estimate"` (computed from the
    /// mp3's size at the CBR the server requested) | `"last_word"` | `"unknown"`.
    /// `"unknown"` means `durationS` is 0 and nothing should be laid out on it.
    let durationSource: String
    /// The sentence the public tour prints for this AI-generated audio.
    /// Show it verbatim; nil only if the server sent none.
    let disclosure: String?
    /// `media_provenance.id` when the row was written.
    let provenanceID: String?
    /// False when the voiceover could NOT be entered in the audit log (usually
    /// no listing id yet). The audio itself still succeeded.
    let provenanceRecorded: Bool

    /// True when the server gave a duration it actually measured or computed,
    /// rather than admitting it has none.
    var hasReliableDuration: Bool { durationSource != "unknown" && durationS > 0 }
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
    ///
    /// `idempotencyKey` identifies the LOGICAL ticket ("ticket:<hash of the
    /// file path>:<bytes>"). The server replays it: a retry after a lost
    /// response, an expired staging PUT URL or a relaunch returns the SAME
    /// `asset_id`/`storage_key` (with a fresh PUT URL) instead of minting
    /// another asset row and charging the workspace's daily upload budget
    /// again (audit F-E-06). Pass nil only where no retry can happen — the
    /// client then derives a key from the route + payload.
    func requestUpload(filename: String, bytes: Int64,
                       listingID: UUID?, sha256: String?, kind: String,
                       role: String, contentType: String?,
                       idempotencyKey: String?) async throws -> UploadTicket

    /// POST /uploads/:asset_id/part-urls → presigned URLs for the given 1-based
    /// part numbers. URLs expire in ~1 h, so request them as you go / on resume.
    func fetchPartURLs(assetID: String, numbers: [Int]) async throws -> [Int: URL]

    /// POST /uploads/:asset_id/complete. `parts` non-nil ⇒ multipart (ETag
    /// manifest, REQUIRED); `parts` nil ⇒ single. `metadata` carries the probed
    /// video fields. Idempotent server-side: a replay returns 200 + the same
    /// asset row. (An older server answers 409 "already complete"; callers
    /// treat that as success too — `APIError.isAlreadyComplete`.)
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
    /// (≤ 400 back). TEXT-ONLY: the server never looks at the image for this
    /// mode, so `imageBase64` is accepted for source compatibility and is NOT
    /// sent (uploading several MB over cellular for a call that ignores them
    /// was audit F-E-16). Not charged against the monthly allowance.
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

    // MARK: AI voiceover (ai-voice edge function — docs/VOICEOVER-CONTRACT.md)

    /// GET /ai-voice/voices — the ElevenLabs voice catalogue for the picker,
    /// cached 10 minutes server-side. Rows with no usable id are dropped, so
    /// every element is safe to pass straight back to `aiVoiceTTS`.
    ///
    /// Throws `APIError.server(status: 503, code: "upstream", …)` when the
    /// server has no ElevenLabs credential configured. Show that message — it
    /// is deliberately NOT an empty list, because an empty picker looks like
    /// "no voices exist" rather than "this needs setting up".
    func aiVoices() async throws -> [AIVoice]

    /// POST /ai-voice/tts — speak `text` in `voiceID` and return the audio URL
    /// plus word timings for captions.
    ///
    /// `text` is capped at 1,000 characters SERVER-side (400 beyond it) and is
    /// run through the fair-housing gate before a cent is spent: a script that
    /// steers on family status, religion, race, disability, sex, or the
    /// safety / school / "exclusive" proxies comes back as
    /// `APIError.server(status: 400, code: "unsupported_edit", …)` with a
    /// message naming the offending phrase. Show that message, let the agent
    /// re-word, and NEVER auto-retry — the same text will always be refused.
    ///
    /// `listingServerID` anchors the provenance row so the tour can disclose
    /// the audio as AI-generated; without it nothing is logged.
    /// `idempotencyKey` is one UUID per user TAP: a repeat inside two minutes
    /// is refused with 409 `conflict` rather than billed twice.
    ///
    /// The returned `audioURL` is a short-lived signed URL — download it now.
    func aiVoiceTTS(text: String, voiceID: String, listingServerID: UUID?,
                    label: String, idempotencyKey: String) async throws -> AIVoiceResult

    // MARK: Admin console (owner/admin only — docs/ADMIN-CONSOLE-CONTRACT.md)
    //
    // Every route is a GET and the ADMIN ROLE IS SERVER-ENFORCED: the function
    // reads `public.profiles.is_admin` for the caller's `auth.uid()` and 403s
    // otherwise. Nothing the app sends can grant it, so these calls are a
    // convenience for the owner, never a permission check. A 403 means "not an
    // admin" — hide the entry point; a 401 means the session is gone.

    /// GET /admin/spend?window=today|7d|30d — cost-ledger rollup for the window,
    /// with the `coverage` object that says what the total does NOT include.
    func adminSpend(window: AdminSpendWindow) async throws -> AdminSpendReport

    /// GET /admin/providers — the external-API inventory plus a live boolean per
    /// credential. A credential VALUE (or prefix, suffix or length) is never
    /// returned by the server and must never be rendered by the app.
    func adminProviders() async throws -> AdminProvidersReport

    /// GET /admin/usage — per-org plan, this month's counters against the plan
    /// entitlements, and who is blocked. Org-level aggregates only.
    func adminUsage() async throws -> AdminUsageReport

    /// GET /admin/health — credential configuration and the last success/failure
    /// visible in data already held. Makes NO outbound provider calls.
    func adminHealth() async throws -> AdminHealthReport
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

// MARK: - Admin console models (docs/ADMIN-CONSOLE-CONTRACT.md, version 1)
//
// The contract guarantees every field is present (optionals arrive as explicit
// `null`, arrays as `[]`). We still decode EVERY field as Optional and expose
// non-optional computed accessors, for the same reason `MeDTO` does: one added
// or renamed key on the server must not blank the whole screen with a decoding
// error while the owner is in the field. Wire JSON is snake_case and decodes
// through `LiveAPIClient.decode` (`.convertFromSnakeCase`), so the property
// names below are the camelCase form of the contract's keys.
//
// Timestamps stay `String` on the wire (the shared decoder sets no
// `dateDecodingStrategy`) and are parsed on demand by `AdminTimestamp`.

/// The window the spend figures cover. Raw values are the wire query values.
enum AdminSpendWindow: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    /// Segmented-control label.
    var label: String {
        switch self {
        case .today:      return "Today"
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        }
    }

    /// Sentence form, for headers and copy.
    var phrase: String {
        switch self {
        case .today:      return "today"
        case .sevenDays:  return "the last 7 days"
        case .thirtyDays: return "the last 30 days"
        }
    }
}

/// ISO-8601 → Date for the admin payloads (tolerant of fractional seconds,
/// mirroring `LiveAPIClient.parseDate`).
enum AdminTimestamp {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: GET /admin/spend

/// One bucket of the spend breakdown (`by_provider` / `by_feature`).
struct AdminSpendBucket: Decodable, Hashable, Sendable, Identifiable {
    var key: String? = nil
    var label: String? = nil
    var totalCents: Double? = nil
    var rows: Int? = nil
    /// Bucket ÷ total, 0–1 (0 when the total is 0).
    var share: Double? = nil

    var id: String { key ?? label ?? UUID().uuidString }
    var displayName: String { AdminText.name(label, key, fallback: "Unattributed") }
}

/// One workspace's slice of the window's spend (`by_org`). `orgId` and `plan`
/// are nullable: rows whose org was deleted arrive as "(unattributed)".
struct AdminSpendOrg: Decodable, Hashable, Sendable {
    var orgId: String? = nil
    var orgName: String? = nil
    var plan: String? = nil
    var totalCents: Double? = nil
    var rows: Int? = nil
    var share: Double? = nil

    var displayName: String { AdminText.name(orgName, orgId, fallback: "(unattributed)") }
}

/// One place spend either does or does not become a ledger row.
struct AdminCoverageSource: Decodable, Hashable, Sendable {
    var key: String? = nil
    var label: String? = nil
    var represented: Bool? = nil
    var detail: String? = nil
    var reference: String? = nil

    var isRepresented: Bool { represented ?? false }
    var displayName: String { AdminText.name(label, key, fallback: "Unnamed source") }
}

/// What `total_cents` does and does not include. Rendered next to the total
/// whenever `complete` is false — the contract requires it, and an owner who
/// trusts an incomplete number is worse off than one shown no number at all.
struct AdminSpendCoverage: Decodable, Hashable, Sendable {
    var complete: Bool? = nil
    var headline: String? = nil
    var representedCount: Int? = nil
    var missingCount: Int? = nil
    var sources: [AdminCoverageSource]? = nil

    /// True only when the server positively says the ledger is complete.
    /// A missing `coverage` object is NOT completeness.
    var isComplete: Bool { complete == true }
    var allSources: [AdminCoverageSource] { sources ?? [] }
    var unrepresented: [AdminCoverageSource] { allSources.filter { !$0.isRepresented } }
}

/// `GET /admin/spend?window=today|7d|30d`.
struct AdminSpendReport: Decodable, Hashable, Sendable {
    var window: String? = nil
    var from: String? = nil
    var to: String? = nil
    var generatedAt: String? = nil
    var totalCents: Double? = nil
    var ledgerRows: Int? = nil
    /// True when the window held more ledger rows than the server's read cap —
    /// the totals are then a LOWER BOUND.
    var truncated: Bool? = nil
    var byProvider: [AdminSpendBucket]? = nil
    var byFeature: [AdminSpendBucket]? = nil
    var byOrg: [AdminSpendOrg]? = nil
    var coverage: AdminSpendCoverage? = nil

    var providerBuckets: [AdminSpendBucket] { byProvider ?? [] }
    var featureBuckets: [AdminSpendBucket] { byFeature ?? [] }
    var orgBuckets: [AdminSpendOrg] { byOrg ?? [] }
    var isTruncated: Bool { truncated == true }
    var generatedDate: Date? { AdminTimestamp.parse(generatedAt) }
}

// MARK: GET /admin/providers

/// One priced SKU behind a provider: what calls it, and what a unit costs.
struct AdminProviderModel: Decodable, Hashable, Sendable {
    var sku: String? = nil
    var label: String? = nil
    var unit: String? = nil
    /// nil where the repo has no committed price for the SKU.
    var unitCostCents: Double? = nil
    var trigger: String? = nil
    var source: String? = nil

    var displayName: String { AdminText.name(label, sku, fallback: "Unnamed model") }
}

/// One external API. `credentialEnv` / `envNames` are env var NAMES; the server
/// never sends a credential value, prefix, suffix or length, and the app never
/// renders one.
struct AdminProvider: Decodable, Hashable, Sendable {
    var key: String? = nil
    var name: String? = nil
    /// "ai" | "infra" | "integration".
    var kind: String? = nil
    var billable: Bool? = nil
    var credentialEnv: String? = nil
    var envNames: [String]? = nil
    /// True only when every env var in `envNames` is set to a non-empty value.
    var configured: Bool? = nil
    /// The `cost_ledger.provider` value these rows carry — nil when the
    /// provider never writes ledger rows (part of the coverage story).
    var ledgerProvider: String? = nil
    var models: [AdminProviderModel]? = nil

    var displayName: String { AdminText.name(name, key, fallback: "Unnamed provider") }
    var modelList: [AdminProviderModel] { models ?? [] }
    var envList: [String] { envNames ?? credentialEnv.map { [$0] } ?? [] }
    /// nil = the server did not say (never rendered as a ✓ or an ✗).
    var isConfigured: Bool? { configured }
}

/// `GET /admin/providers`.
struct AdminProvidersReport: Decodable, Hashable, Sendable {
    var generatedAt: String? = nil
    var providerCount: Int? = nil
    var configuredCount: Int? = nil
    var providers: [AdminProvider]? = nil

    var providerList: [AdminProvider] { providers ?? [] }
}

// MARK: GET /admin/usage

/// One "used of cap" counter, built from an org row's paired used/cap fields.
struct AdminUsageCounter: Hashable, Sendable, Identifiable {
    let key: String
    let label: String
    let used: Int
    let cap: Int

    var id: String { key }
    /// cap 0 means the plan does not include the feature at all.
    var isIncluded: Bool { cap > 0 }
    var isAtCap: Bool { cap > 0 && used >= cap }
}

/// One workspace's plan, this month's counters and why it is blocked.
/// Org-level aggregates only — the contract carries no person's name or email.
struct AdminOrgUsage: Decodable, Hashable, Sendable {
    var orgId: String? = nil
    var orgName: String? = nil
    /// Effective plan (an expired trial reads "free"), as the charge paths see it.
    var plan: String? = nil
    /// `orgs.plan` as stored, before trial-expiry mapping.
    var planRaw: String? = nil
    var trialEndsAt: String? = nil
    var spendCentsMonth: Double? = nil
    var cogsCeilingCents: Double? = nil
    var spendShareOfCeiling: Double? = nil
    var rendersUsed: Int? = nil
    var rendersCap: Int? = nil
    var photoEditsUsed: Int? = nil
    var photoEditsCap: Int? = nil
    var reelsUsed: Int? = nil
    var reelsCap: Int? = nil
    var aerialsUsed: Int? = nil
    var aerialsCap: Int? = nil
    var droneUsed: Int? = nil
    var droneCap: Int? = nil
    var jobsInFlight: Int? = nil
    var jobsOrphaned: Int? = nil
    var blocked: Bool? = nil
    /// Stable slugs; `blocked` is true iff this is non-empty.
    var blockedReasons: [String]? = nil

    var displayName: String { AdminText.name(orgName, orgId, fallback: "(unattributed)") }
    var isBlocked: Bool { blocked == true || !(blockedReasons ?? []).isEmpty }
    var reasons: [String] { blockedReasons ?? [] }
    var trialEndsDate: Date? { AdminTimestamp.parse(trialEndsAt) }

    /// The five metered features, in the order Settings already shows them.
    var counters: [AdminUsageCounter] {
        [
            AdminUsageCounter(key: "renders", label: "Tour renders",
                              used: rendersUsed ?? 0, cap: rendersCap ?? 0),
            AdminUsageCounter(key: "photo_edits", label: "Photo edits",
                              used: photoEditsUsed ?? 0, cap: photoEditsCap ?? 0),
            AdminUsageCounter(key: "reels", label: "Reel clips",
                              used: reelsUsed ?? 0, cap: reelsCap ?? 0),
            AdminUsageCounter(key: "aerials", label: "Aerial intros",
                              used: aerialsUsed ?? 0, cap: aerialsCap ?? 0),
            AdminUsageCounter(key: "drone", label: "Drone-glide upscales",
                              used: droneUsed ?? 0, cap: droneCap ?? 0),
        ]
    }
}

/// `GET /admin/usage`.
struct AdminUsageReport: Decodable, Hashable, Sendable {
    var generatedAt: String? = nil
    var month: String? = nil
    var monthStart: String? = nil
    var orgCount: Int? = nil
    var blockedCount: Int? = nil
    /// True when more than the server's cap of orgs exist; the list is the top N.
    var truncated: Bool? = nil
    var orgs: [AdminOrgUsage]? = nil

    var orgList: [AdminOrgUsage] { orgs ?? [] }
    var blockedOrgs: [AdminOrgUsage] { orgList.filter { $0.isBlocked } }
    var isTruncated: Bool { truncated == true }
}

// MARK: GET /admin/health

/// One provider's credential state and last known success.
struct AdminHealthProvider: Decodable, Hashable, Sendable {
    var key: String? = nil
    var name: String? = nil
    var credentialEnv: String? = nil
    var configured: Bool? = nil
    /// "ok" | "idle" | "unmetered" | "unconfigured".
    var status: String? = nil
    var ledgerProvider: String? = nil
    var lastSuccessAt: String? = nil
    var lastSuccessDetail: String? = nil
    var rowsInWindow: Int? = nil
    var spendCentsInWindow: Double? = nil

    var displayName: String { AdminText.name(name, key, fallback: "Unnamed provider") }
    var lastSuccessDate: Date? { AdminTimestamp.parse(lastSuccessAt) }
}

/// One failing pipeline step and how often it failed in the window.
struct AdminFailureStep: Decodable, Hashable, Sendable {
    var key: String? = nil
    var count: Int? = nil

    var displayName: String { AdminText.pretty(key ?? "unknown") }
}

/// Render-job failures in the window. Deliberately carries NO provider error
/// text — an upstream message can contain a signed URL or key material, so the
/// server sends only the step and the exception type.
struct AdminJobFailures: Decodable, Hashable, Sendable {
    var windowDays: Int? = nil
    var failedJobs: Int? = nil
    var orphanedJobs: Int? = nil
    var lastFailureAt: String? = nil
    var lastFailureStep: String? = nil
    var lastFailureType: String? = nil
    var byStep: [AdminFailureStep]? = nil

    var stepList: [AdminFailureStep] { byStep ?? [] }
    var lastFailureDate: Date? { AdminTimestamp.parse(lastFailureAt) }
    var hasFailures: Bool { (failedJobs ?? 0) > 0 || (orphanedJobs ?? 0) > 0 }
}

/// `GET /admin/health`.
struct AdminHealthReport: Decodable, Hashable, Sendable {
    var generatedAt: String? = nil
    /// Always false today: this route calls no provider API.
    var checkedProviderApis: Bool? = nil
    var note: String? = nil
    var windowDays: Int? = nil
    var providers: [AdminHealthProvider]? = nil
    var jobFailures: AdminJobFailures? = nil

    var providerList: [AdminHealthProvider] { providers ?? [] }
    var didCallProviders: Bool { checkedProviderApis == true }
}

// MARK: - Admin display helpers

/// Small string helpers shared by the admin models. Kept out of the view so the
/// SwiftUI bodies stay short enough for the type-checker.
enum AdminText {
    /// First non-empty of `primary`, `secondary`, else `fallback`.
    static func name(_ primary: String?, _ secondary: String?, fallback: String) -> String {
        for candidate in [primary, secondary] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return fallback
    }

    /// "photo_edits_at_cap" → "Photo edits at cap".
    static func pretty(_ slug: String) -> String {
        let spaced = slug.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty else { return "—" }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Human sentence for a `blocked_reasons` slug (contract's known values).
    static func blockedReason(_ slug: String) -> String {
        switch slug {
        case "renders_at_cap":       return "Tour renders at their monthly cap"
        case "photo_edits_at_cap":   return "Photo edits at their monthly cap"
        case "reels_at_cap":         return "Reel clips at their monthly cap"
        case "aerials_at_cap":       return "Aerial intros at their monthly cap"
        case "drone_at_cap":         return "Drone-glide upscales at their monthly cap"
        case "spend_ceiling_reached": return "Monthly spend ceiling reached"
        case "jobs_in_flight_max":   return "Too many render jobs in flight"
        case "orphaned_jobs":        return "Stuck render jobs need clearing"
        default:                     return pretty(slug)
        }
    }

    /// Provider `kind` slug → label. `pretty` alone would render "ai" as "Ai".
    /// nil when the server sent nothing, so callers can omit the whole clause.
    static func kind(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "":            return nil
        case "ai":          return "AI"
        case "infra":       return "Infrastructure"
        case "integration": return "Integration"
        default:            return pretty(value)
        }
    }

    /// Plan slug → display label ("pro" → "Pro", "" → "—").
    static func plan(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return pretty(trimmed)
    }
}
