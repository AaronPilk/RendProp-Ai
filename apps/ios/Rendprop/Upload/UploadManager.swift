import Foundation
import Network
import Combine

/// Resumable large-file upload engine (docs/UPLOAD-AND-PUBLISH-CONTRACT.md §5).
///
/// When `Config.useLiveBackend` is on it runs the REAL path chosen by the server:
///  • **multipart** — big video (>64 MB). Each part is an `uploadTask(fromFile:)`
///    on a background `URLSession`, streaming from a temp SLICE file (never the
///    whole 2–8 GB video in memory). Per-part state {number,status,etag} is
///    persisted so a network drop or relaunch resumes only the MISSING parts.
///    Bounded to ≤ 3 parts in flight, so temp disk stays ≤ ~3×partSize.
///  • **single** — small video (≤ 64 MB): one presigned PUT. The PUT carries the
///    SAME `Content-Type` the ticket declared (derived from the file extension)
///    — the server deletes an object whose type differs from its ticket. A
///    transient failure first reconciles `/complete`, then renews that exact
///    ticket. It never blindly replays a PUT or mints a replacement reservation.
///
/// When `useLiveBackend` is off it uses **.simulate** (real disk reads, realistic
/// progress, fully offline) so the app runs end-to-end with no backend.
///
/// Posters (`uploadPoster`) are small foreground single PUTs that never touch
/// the persisted video state. Photos go through `beginPhotoBatch` →
/// `/uploads/batch` with bounded-concurrency single PUTs.
final class UploadManager: NSObject, ObservableObject {
    static let shared = UploadManager()

    /// Posted (main thread) when a video upload finishes; `userInfo` carries
    /// `"assetID": String` (the SERVER capture_assets id), `"role": String`,
    /// and when known `"listingID": UUID` (SERVER listing id) and
    /// `"listingLocalID": UUID` (the app's Listing.id) so a publish that was
    /// interrupted by a relaunch can be matched back to its listing.
    static let didCompleteNotification = Notification.Name("RendpropUploadCompleted")
    /// Posted when a photo batch finishes; `userInfo` has `"assetIDs": [String]`
    /// and `"listingID": UUID`.
    static let photosDidCompleteNotification = Notification.Name("RendpropPhotoBatchCompleted")

    enum Status: String, Codable {
        case queued, uploading, paused, failed, done
    }

    enum PartStatus: String, Codable {
        case pending, inflight, done, failed
    }

    /// One multipart part. `offset`/`length` locate its byte range in the source
    /// file; `etag` is filled from the PUT response once the part lands.
    struct PartState: Codable, Equatable {
        var number: Int
        var offset: Int64
        var length: Int64
        var status: PartStatus = .pending
        var etag: String? = nil
        var retryCount: Int = 0
        var taskID: Int? = nil
    }

    struct State: Codable, Identifiable {
        var id = UUID()
        var filePath: String              // relative to Documents (container path changes between installs)
        var bytesTotal: Int64
        var bytesSent: Int64 = 0          // done-part bytes + in-flight bytes (UI progress)
        var status: Status = .queued
        var mode: String                  // "pending" | "simulate" | "single" | "multipart"

        // Server identifiers (contract §2.1)
        var assetID: String? = nil        // capture_assets id (asset_id)
        var storageKey: String? = nil     // R2 object key
        var uploadID: String? = nil       // R2/S3 multipart session id
        var partSize: Int64? = nil
        var partCount: Int? = nil
        var parts: [PartState] = []       // multipart per-part state (persisted → resumable)

        var sha256: String? = nil
        var retryCount: Int = 0           // single mode: failed transfers of its one PUT (multipart counts per part)
        /// Owning listing — sent as listing_id when requesting the upload. For a
        /// role=render publish this is the SERVER listing id.
        var listingID: UUID? = nil
        /// Upload role sent to POST /uploads: "capture" (private uploads bucket)
        /// or "render" (public renders bucket, contract §2.7).
        var role: String = "capture"
        /// Probed video metadata, threaded into /complete.
        var metadata: UploadMetadata? = nil

        // Added 2026-09-03 (audit). ALL Optional → state persisted by older builds decodes.
        /// The `content_type` declared on the ticket and sent on the PUT (P0 fix).
        var contentType: String? = nil
        /// The app's local Listing.id (distinct from the server `listingID`) so a
        /// resumed role=render upload can finish its listing's publish.
        var listingLocalID: UUID? = nil
        /// Last capability retained for OS-task reconciliation. Retrying never
        /// trusts its age as authority to resend; `/renew` checks this ticket.
        var putURL: URL? = nil
        var putURLIssuedAt: Date? = nil
        /// Single mode: the PUT landed; only `/complete` is outstanding.
        var singlePutDone: Bool? = nil
        /// Last failure shown to the user (server message when there was one).
        var failureMessage: String? = nil
        /// Set when the server REJECTED the upload (4xx on ticket or complete):
        /// auto-resume must not loop on it. Explicit Resume probes the SAME
        /// ticket and replaces it only after confirmed legacy cancellation.
        var terminalError: String? = nil
        var transportVersion: Int? = nil
        var ticketKey: String? = nil
        var legacyRecoveryApproved: Bool? = nil
        var legacyCancellationAssetID: String? = nil
        var singleTaskID: Int? = nil
        /// The client's own bounded recovery on THIS ticket ran out: the
        /// part-URL retries, the reconciliation rounds, or the single PUT's
        /// attempts. The ticket may well be dead server-side. Auto-resume can
        /// still try it once more on a network regain; the user-visible way
        /// forward is `startOver()` — a fresh reservation for the same file.
        var recoveryExhausted: Bool? = nil

        var fractionComplete: Double {
            bytesTotal > 0 ? Double(bytesSent) / Double(bytesTotal) : 0
        }

        var fileURL: URL {
            FileStore.documents.appendingPathComponent(filePath)
        }

        /// True when the engine will pick this up on network regain / launch.
        var isAutoResumable: Bool { status == .failed && terminalError == nil }
        /// True when a user-facing Resume can reconcile retained progress.
        var canResume: Bool { status == .failed || status == .paused }
        /// True when this failed record has a ticket the engine gave up on, so
        /// "Start over" (retire it, reserve afresh, send again) is the honest
        /// offer. Never true for a record that has no ticket yet — a plain
        /// Resume simply asks for one.
        var canStartOver: Bool { status == .failed && assetID != nil && recoveryExhausted == true }

        mutating func prepareForExplicitResume() {
            // The server decides whether the original can finish. Clearing
            // identifiers here would orphan a charged reservation and its parts.
            terminalError = nil
            legacyRecoveryApproved = true
            status = .uploading
            retryCount = 0
            recoveryExhausted = nil
            failureMessage = nil
            for i in parts.indices where parts[i].status == .failed {
                parts[i].status = .pending
                parts[i].retryCount = 0
            }
        }
    }

    /// Lightweight progress for an in-flight photo batch.
    struct PhotoProgress: Equatable {
        var total: Int
        var completed: Int
        var failed: Int
    }

    @Published private(set) var state: State?
    @Published private(set) var photoProgress: PhotoProgress?
    /// Set when a large upload wants to start on cellular — UI shows a prompt.
    @Published var pendingCellularConfirmation: Bool = false
    /// The most recent terminal/transient failure message (mirrors
    /// `state?.failureMessage`, but survives the state being cleared).
    @Published private(set) var lastFailureMessage: String?

    /// Optional completion callback (server assetID). NotificationCenter also
    /// fires `didCompleteNotification`. Consumers must avoid retaining `self`.
    var onUploadComplete: ((String) -> Void)?

    /// Optional terminal-failure callback for the async `upload(...)` convenience
    /// — fired when the active upload transitions to `.failed` or is cancelled,
    /// with the server's message when there was one.
    var onUploadFailed: ((String?) -> Void)?

    /// Errors thrown by the async `upload(...)` / `uploadPoster(...)` conveniences.
    enum UploadError: LocalizedError {
        case busy, failed, missingFile
        /// The upload would run on cellular against the user's Wi-Fi-only
        /// setting (or is very large). Ask, then call again with
        /// `cellularApproved: true` — or persist the publish and wait for Wi-Fi.
        case cellularConfirmationRequired
        /// The server rejected or failed the upload — `message` is its own text.
        case server(String)

        var errorDescription: String? {
            switch self {
            case .busy:        return "Another upload is already in progress."
            case .failed:      return "The upload failed. Check your connection and try again."
            case .missingFile: return "The file to upload is missing or empty."
            case .cellularConfirmationRequired:
                return "This upload is waiting for Wi-Fi. Connect to Wi-Fi, or allow cellular uploads in Settings."
            case .server(let message): return message
            }
        }
    }

    private let monitor = NWPathMonitor()
    private(set) var pathIsExpensive = false
    private var pathIsSatisfied = true
    private var simulateTimer: Timer?
    private let maxConcurrent = 3

    // Transient (never persisted): live per-part sent bytes + per-part retry gates.
    private var inFlightBytes: [Int: Int64] = [:]
    private var partNextTry: [Int: Date] = [:]
    private var isRequestingTicket = false
    private var isCompleting = false
    private var recoveryAttempt: UUID?
    /// Consecutive `/part-urls` failures with nothing else moving. Used to
    /// have no bound at all: a 503 every five seconds, forever, with nothing
    /// on screen. Reset when a batch of URLs arrives and on every explicit
    /// (re)start.
    private var partURLFailures = 0
    /// Consecutive reconciliation rounds (`/complete` probe → `/renew`) that
    /// produced no progress — no part landed, no upload finished. Reset the
    /// moment a part's receipt lands. This is the bound `retryCount` used to
    /// carry for the WHOLE upload, which made three parts tripping over one
    /// network blip count as three strikes against the file.
    private var reconcileRounds = 0
    /// Bounds. Part-URL retries back off 5 s → 30 s and give up after eight
    /// (about three minutes of a storage that cannot plan a transfer);
    /// reconciliation gives up after five rounds without progress; a part
    /// (or the single PUT) after five failed transfers of its own.
    private static let maxPartURLAttempts = 8
    private static let maxReconcileRounds = 5
    private static let maxTransferAttemptsPerPart = 5
    /// Multiplier on the part-URL backoff. 1 in the app; the receipt/dispatch
    /// tests compress it so the bounded loop runs in milliseconds, not minutes.
    var retryDelayScale: Double = 1

    // Mock by default; LiveAPIClient when Config.useLiveBackend.
    private var api: APIClient = Config.makeAPIClient()
    private var persistState: (State?) -> Bool = UploadStore.save

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.rendprop.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // The Settings toggle defaults to ON (`@AppStorage("wifiOnlyUploads") = true`);
        // register the same default so the engine reads ON before the user has
        // ever touched the switch (it used to read false until first toggle).
        UserDefaults.standard.register(defaults: ["wifiOnlyUploads": true])

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasSatisfied = self.pathIsSatisfied
                self.pathIsExpensive = path.isExpensive
                self.pathIsSatisfied = (path.status == .satisfied)
                if !wasSatisfied && self.pathIsSatisfied {
                    self.onNetworkRegained()
                }
                // An upload parked for Wi-Fi starts on its own once the path is
                // no longer expensive (Settings promises exactly this).
                if self.pathIsSatisfied, !self.pathIsExpensive,
                   let s = self.state, s.status == .queued, self.pendingCellularConfirmation {
                    self.confirmCellularAndStart()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.rendprop.netpath"))

        // Resume anything persisted from a previous launch.
        if let saved = UploadStore.load() {
            state = saved
            lastFailureMessage = saved.failureMessage
            switch saved.status {
            case .uploading:
                // Relaunch is not consent to discard an old reservation.
                startOrResume()
            case .queued:
                // .queued means the upload was awaiting the cellular-data
                // confirmation when the app died. Re-raise the prompt instead of
                // silently starting a multi-GB upload on cellular — the UI calls
                // confirmCellularAndStart() (or cancel()) exactly as before.
                pendingCellularConfirmation = true
            case .done:
                // A completed record from an older build — its completion was
                // already consumed (or lost); never show "Complete · 100%" forever.
                state = nil
                UploadStore.save(nil)
            case .failed, .paused:
                break   // network-regain (non-terminal) or the user resumes
            }
        }
        _ = backgroundSession // create eagerly so background events attach
    }

    /// Explicit boundaries allow receipt/dispatch tests to execute this engine
    /// without a real background daemon, app journal or network monitor. The
    /// shipping singleton continues to use its OS session and durable store.
    init(api: APIClient, session: URLSession, recovering state: State,
         persistState: @escaping (State?) -> Bool) {
        self.api = api
        self.persistState = persistState
        self.state = state
        super.init()
        self.backgroundSession = session
    }

    // MARK: - Public API

    /// True if we should warn before uploading this file on the current path.
    func shouldWarnCellular(bytes: Int64) -> Bool {
        let wifiOnly = UserDefaults.standard.bool(forKey: "wifiOnlyUploads")
        return pathIsExpensive && (wifiOnly || bytes > Config.cellularWarnBytes)
    }

    /// Start uploading a video. `metadata` is threaded into `/complete`.
    /// `role` routes the object ("capture" → private bucket; "render" → public
    /// renders bucket for an app-published tour, contract §2.7). `listingID` is
    /// the SERVER listing id; `listingLocalID` the app's Listing.id.
    func begin(fileURL: URL,
               listingID: UUID? = nil,
               listingLocalID: UUID? = nil,
               role: String = "capture",
               metadata: UploadMetadata = UploadMetadata(),
               cellularApproved: Bool = false) {
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0 else { return }

        let needsWifi = shouldWarnCellular(bytes: bytes) && !cellularApproved
        if needsWifi {
            pendingCellularConfirmation = true
            // Queue it; UI confirms and calls confirmCellularAndStart(), or leaves it queued.
        }

        // Clear any prior transient bookkeeping.
        simulateTimer?.invalidate()
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        isRequestingTicket = false
        isCompleting = false
        partURLFailures = 0
        reconcileRounds = 0

        var newState = State(filePath: FileStore.relativePath(for: fileURL),
                             bytesTotal: bytes,
                             mode: Config.useLiveBackend ? "pending" : "simulate")
        newState.listingID = listingID
        newState.listingLocalID = listingLocalID
        newState.role = role
        newState.ticketKey = "ticket:\(newState.id.uuidString.lowercased())"
        // Declared once here; the ticket and the PUT both use this exact value.
        newState.contentType = DirectUploader.uploadContentType(for: fileURL, kind: "video")
        var meta = metadata
        if meta.bytes == nil { meta.bytes = bytes }
        newState.metadata = meta
        newState.status = needsWifi ? .queued : .uploading
        state = newState
        lastFailureMessage = nil
        guard persistBeforeDispatch() else { return }

        // Streaming sha256 (optional metadata) computed off-main; large-file safe.
        // Keyed by this upload's id so a digest finishing after cancel()+begin()
        // can't land on a DIFFERENT file's upload.
        computeHashInBackground(fileURL: fileURL, uploadID: newState.id)

        guard newState.status == .uploading else { return }
        startOrResume()
    }

    /// Async convenience: upload one file and resolve with the SERVER assetID
    /// when the single/multipart engine finishes. Drives the same `begin(...)`
    /// engine and completion hooks, wrapped in a continuation, so the publish
    /// step can `await` the upload (contract §4/§5). Ensures a single active
    /// upload; throws on failure or cancel (with the server's message when
    /// there is one).
    ///
    /// Cellular guard (honoured at PUBLISH time): when `cellularApproved` is
    /// false and `shouldWarnCellular(bytes:)` says so, the upload is PARKED
    /// (`.queued`, `pendingCellularConfirmation`) and this throws
    /// `.cellularConfirmationRequired` right away. The caller either asks the
    /// user and calls again with `cellularApproved: true` (or lets Settings'
    /// "Start on cellular now" / the Wi-Fi auto-start run it), keeping the
    /// publish pending; the parked upload's completion is delivered through
    /// `didCompleteNotification` with the listing ids.
    @MainActor
    func upload(fileURL: URL, listingID: UUID, listingLocalID: UUID? = nil, role: String,
                metadata: UploadMetadata, cellularApproved: Bool = false) async throws -> String {
        let relPath = FileStore.relativePath(for: fileURL)
        // The SAME file parked for Wi-Fi earlier: adopt it (the user approved
        // cellular, or asked again before Wi-Fi came back).
        if let s = state, s.status == .queued, s.filePath == relPath {
            guard cellularApproved else { throw UploadError.cellularConfirmationRequired }
            return try await awaitEngine { self.confirmCellularAndStart() }
        }
        if let s = state, s.status == .failed, s.filePath == relPath,
           s.listingID == listingID, s.role == role {
            // Retry the recorded upload, not a new request with forgotten parts.
            // Unless the engine already gave up on that record's ticket: then a
            // "Retry publish" tap is the explicit go-ahead to retire it and
            // send the file again under a fresh reservation, instead of the
            // same dead Resume failing again a minute later.
            if s.canStartOver { return try await awaitEngine { self.startOver() } }
            return try await awaitEngine { self.resume() }
        }
        // One active upload at a time — don't clobber an in-flight capture.
        if let s = state, s.status == .uploading || s.status == .queued || s.status == .paused {
            throw UploadError.busy
        }
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0 else { throw UploadError.missingFile }
        // A stale failed record from an earlier attempt must not linger under
        // the new upload (its background tasks are ignored by task description).
        if state != nil { clearState() }
        if !cellularApproved && shouldWarnCellular(bytes: bytes) {
            // Park it in the engine (status .queued + pendingCellularConfirmation)
            // so Settings' "Start on cellular now" and the Wi-Fi auto-start can
            // finish it later — its completion arrives via didCompleteNotification
            // with the listing ids — but never hold the caller's await hostage.
            begin(fileURL: fileURL, listingID: listingID, listingLocalID: listingLocalID,
                  role: role, metadata: metadata, cellularApproved: false)
            throw UploadError.cellularConfirmationRequired
        }
        return try await awaitEngine {
            self.begin(fileURL: fileURL, listingID: listingID, listingLocalID: listingLocalID,
                       role: role, metadata: metadata, cellularApproved: true)
        }
    }

    /// Wire the one-shot completion/failure hooks to a continuation, then run
    /// `start` (which drives the engine). Resolves with the server asset id.
    @MainActor
    private func awaitEngine(_ start: @escaping () -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var settled = false
            func finish(_ result: Result<String, Error>) {
                guard !settled else { return }
                settled = true
                self.onUploadComplete = nil
                self.onUploadFailed = nil
                cont.resume(with: result)
            }
            self.onUploadComplete = { assetID in finish(.success(assetID)) }
            self.onUploadFailed = { message in
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                finish(.failure(trimmed.isEmpty ? UploadError.failed : UploadError.server(trimmed)))
            }
            start()
        }
    }

    /// Upload the tour POSTER (a first-frame JPEG the app renders) for
    /// `POST /renders/publish-app {poster_asset_id}`: `POST /uploads {kind:
    /// "photo", role:"render", content_type:"image/jpeg", listing_id}` → one
    /// foreground PUT → `/complete`. Returns the SERVER asset id. `listingID`
    /// is the SERVER listing id (the poster must belong to the same listing as
    /// the render). Independent of the persisted video-upload state. Offline
    /// (mock) tickets carry no PUT URL → the synthetic id is returned so the
    /// publish flow completes.
    func uploadPoster(fileURL: URL, listingID: UUID) async throws -> String {
        try await uploadBrowserPhoto(fileURL: fileURL, listingID: listingID,
                                     role: "render", contentType: "image/jpeg",
                                     keyPrefix: "poster")
    }

    /// Upload the UNTOUCHED ORIGINAL behind an AI photo edit (contract §2.7 /
    /// W2-B4): `POST /uploads {kind:"photo", role:"original", content_type,
    /// listing_id}` → one foreground PUT → `/complete`. Returns the SERVER asset
    /// id, which goes to `POST /ai-photo {original_asset_id}` so the tour's
    /// public "View original" link is a real file — California AB 723 requires
    /// access to the unaltered version, not just a disclosure sentence.
    ///
    /// The server allows jpeg/png/webp ONLY here (a HEIC "View original" link
    /// would not open in a browser) with the full 50 MB photo ceiling. We refuse
    /// anything else up front rather than burning a round trip on a 400.
    /// `listingID` is the SERVER listing id.
    func uploadOriginal(fileURL: URL, listingID: UUID) async throws -> String {
        let contentType = DirectUploader.uploadContentType(for: fileURL, kind: "photo")
        guard ["image/jpeg", "image/png", "image/webp"].contains(contentType) else {
            throw UploadError.server(
                "The original has to be a JPEG, PNG or WebP so the public \"View original\" link opens.")
        }
        return try await uploadBrowserPhoto(fileURL: fileURL, listingID: listingID,
                                            role: "original", contentType: contentType,
                                            keyPrefix: "original")
    }

    /// Upload ONE of the listing's own photos for the public tour page's
    /// gallery (`role:"gallery"`, public renders bucket, key `gallery-<uuid>`).
    ///
    /// The tour host has rendered a gallery since day one and `GET /tours/:slug`
    /// had nothing to put in it, because no photo a listing owns was ever
    /// uploaded anywhere public unless an AI edit forced it (AB 723). This is
    /// that path, for the ordinary photos.
    ///
    /// Server-side this rides the POSTER lane: same bucket, same jpeg|png|webp
    /// allowlist, same 10 MB ceiling. The caller enforces the ceiling first so a
    /// too-big photo is skipped rather than charged for and rejected.
    func uploadGalleryPhoto(fileURL: URL, listingID: UUID) async throws -> String {
        let contentType = DirectUploader.uploadContentType(for: fileURL, kind: "photo")
        guard ["image/jpeg", "image/png", "image/webp"].contains(contentType) else {
            throw UploadError.server("A gallery photo has to be a JPEG, PNG or WebP to show on the page.")
        }
        return try await uploadBrowserPhoto(fileURL: fileURL, listingID: listingID,
                                            role: "gallery", contentType: contentType,
                                            keyPrefix: "gallery")
    }

    /// Upload the PUBLISHED ALTERED photo behind an AI edit (`role:"render"`,
    /// `kind:"photo"` → the public renders bucket, same path the tour poster
    /// takes). Its asset id goes to `PATCH /me/compliance/:id
    /// {altered_asset_id}` so the tour can render the side-by-side
    /// "Before / after" pair NorthstarMLS asks for. Server ceiling for this role
    /// is 10 MB and jpeg/png/webp. `listingID` is the SERVER listing id.
    func uploadAlteredPhoto(fileURL: URL, listingID: UUID) async throws -> String {
        let contentType = DirectUploader.uploadContentType(for: fileURL, kind: "photo")
        guard ["image/jpeg", "image/png", "image/webp"].contains(contentType) else {
            throw UploadError.server("The edited photo has to be a JPEG, PNG or WebP to be published.")
        }
        return try await uploadBrowserPhoto(fileURL: fileURL, listingID: listingID,
                                            role: "render", contentType: contentType,
                                            keyPrefix: "altered")
    }

    /// Shared single-PUT path for the browser-served photos we publish to the
    /// PUBLIC renders bucket: the tour poster and the AI edit's altered result
    /// (`role:"render"`), and its unaltered original (`role:"original"`).
    /// Independent of the persisted video-upload state, so it never disturbs an
    /// in-flight walkthrough upload. Offline (mock) tickets carry no PUT URL →
    /// the synthetic id is returned so the calling flow completes.
    private func uploadBrowserPhoto(fileURL: URL, listingID: UUID, role: String,
                                    contentType: String, keyPrefix: String) async throws -> String {
        try await DirectUploader.uploadPhoto(fileURL: fileURL, listingID: listingID, role: role,
                                              contentType: contentType, keyPrefix: keyPrefix, api: api)
    }

    /// Upload a batch of photos (contract §2.5) — bounded-concurrency single PUTs.
    func beginPhotoBatch(listingID: UUID, fileURLs: [URL]) {
        let urls = fileURLs.filter { FileStore.fileSize($0) > 0 }
        guard !urls.isEmpty else { return }
        photoProgress = PhotoProgress(total: urls.count, completed: 0, failed: 0)
        Task { [weak self] in await self?.runPhotoBatch(listingID: listingID, fileURLs: urls) }
    }

    func confirmCellularAndStart() {
        pendingCellularConfirmation = false
        guard var s = state else { return }
        s.status = .uploading
        state = s
        persist()
        startOrResume()
    }

    /// Pause scheduling, not an already-dispatched physical write. Cancelling a
    /// v2 part mid-transfer can leave the server unable to prove whether bytes
    /// landed; that one-dispatch operation must not be replayed. Up to three
    /// existing parts (or one single PUT) may settle while paused; their receipts
    /// are retained, and no new parts or completion requests start until Resume.
    func pause() {
        simulateTimer?.invalidate()
        mutate { $0.status = .paused }
        partNextTry.removeAll()
        updateProgress()
    }

    /// Explicit Resume allows replacing a legacy ticket only AFTER the server
    /// names it retired and acknowledges that exact ticket's cancellation.
    func resume() {
        guard var s = state, s.status != .done else { return }
        // A Resume on a ticket the engine already gave up on is the user asking
        // for one more full try at it (Start over sits right next to it), so
        // it gets a fresh round budget. A Resume on an ordinary failure just
        // continues the same bounded budget: five dead Resumes in a row
        // converge on the exhausted state instead of cycling forever.
        if s.recoveryExhausted == true { reconcileRounds = 0 }
        s.prepareForExplicitResume()
        state = s
        lastFailureMessage = nil
        partNextTry.removeAll()
        partURLFailures = 0
        guard persistBeforeDispatch() else { return }
        startOrResume()
    }

    /// The user's answer to a ticket the engine gave up on (`canStartOver`):
    /// retire that reservation and send the SAME file again under a fresh one.
    /// This is the one place a replacement reservation is minted for a video
    /// without the server first retiring the old ticket itself — it costs a
    /// reservation, which is why only an explicit tap (or an explicit "Retry
    /// publish" through `upload(...)`) gets here, never a timer.
    ///
    /// Only this ticket's OS tasks are stopped; the abort is best effort (a
    /// dead ticket often 404s or 409s it) and its slices are dropped. The new
    /// record keeps the listing, role, metadata, declared content type and the
    /// already-computed digest, and gets a NEW operation key (a replayed key
    /// would hand back the very reservation we are leaving). Like Resume it
    /// does not re-ask about cellular: this upload was approved (or on Wi-Fi)
    /// when it started, and an awaiting `upload()` must not be parked.
    /// Nothing on this phone is deleted.
    func startOver() {
        guard let s = state, s.canStartOver, let retiredID = s.assetID else { return }
        guard FileStore.fileSize(s.fileURL) > 0 else {
            // Nothing left to send. Leave `.failed` for a moment so the
            // failure below is a real transition — that is what resolves an
            // awaiting `upload()` (`mutate` only notifies on failed's edge).
            mutate { $0.status = .uploading }
            fail("The video to upload is no longer on this phone.", terminal: true)
            return
        }
        simulateTimer?.invalidate()
        backgroundSession.getAllTasks { tasks in
            for task in tasks where task.taskDescription == "single:\(retiredID)" ||
                task.taskDescription?.hasPrefix("part:\(retiredID):") == true { task.cancel() }
        }
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        isRequestingTicket = false
        isCompleting = false
        recoveryAttempt = nil
        partURLFailures = 0
        reconcileRounds = 0
        DirectUploader.cleanSlices(for: retiredID)
        if Config.useLiveBackend {
            Task { [weak self] in try? await self?.api.abortUpload(assetID: retiredID) }
        }

        var fresh = State(filePath: s.filePath, bytesTotal: s.bytesTotal,
                          mode: Config.useLiveBackend ? "pending" : "simulate")
        fresh.listingID = s.listingID
        fresh.listingLocalID = s.listingLocalID
        fresh.role = s.role
        fresh.metadata = s.metadata
        fresh.contentType = s.contentType
        fresh.sha256 = s.sha256
        fresh.ticketKey = "ticket:\(fresh.id.uuidString.lowercased())"
        fresh.status = .uploading
        state = fresh
        lastFailureMessage = nil
        guard persistBeforeDispatch() else { return }
        if fresh.sha256 == nil { computeHashInBackground(fileURL: fresh.fileURL, uploadID: fresh.id) }
        startOrResume()
    }

    func cancel() {
        simulateTimer?.invalidate()
        let assetID = state?.assetID
        let isMultipart = (state?.mode == "multipart")
        backgroundSession.getAllTasks { $0.forEach { $0.cancel() } }
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        isRequestingTicket = false
        isCompleting = false
        partURLFailures = 0
        reconcileRounds = 0
        if let assetID { DirectUploader.cleanSlices(for: assetID) }
        // Best-effort: tear down the server-side R2 multipart session.
        if Config.useLiveBackend, let assetID, isMultipart {
            Task { [weak self] in try? await self?.api.abortUpload(assetID: assetID) }
        }
        state = nil
        _ = persistState(nil)
        // Resolve any awaiting upload() as a failure (cancel is a failed publish).
        onUploadFailed?(nil)
    }

    /// Drop a finished/failed record without touching background tasks for it
    /// (they are ignored by task description). Used before a fresh `upload()`.
    private func clearState() {
        simulateTimer?.invalidate()
        if let assetID = state?.assetID { DirectUploader.cleanSlices(for: assetID) }
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        isRequestingTicket = false
        isCompleting = false
        partURLFailures = 0
        reconcileRounds = 0
        state = nil
        _ = persistState(nil)
    }

    // MARK: - Dispatch

    private func startOrResume() {
        guard Config.useLiveBackend else { runSimulate(); return }
        reconcileAndResume()
    }

    /// Reconcile persisted state with whatever the background session is actually
    /// doing (tasks survive relaunch), then launch only what's missing.
    private func reconcileAndResume() {
        guard let s = state else { return }
        guard let assetID = s.assetID else { requestTicketAndStart(s); return }
        let mode = UploadTicket.Mode(rawValue: s.mode)
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let mine = tasks.filter { ($0.taskDescription ?? "").contains(assetID) }
            DispatchQueue.main.async {
                guard let cur = self.state, cur.status == .uploading, cur.assetID == assetID else { return }
                mine.forEach { if $0.state == .suspended { $0.resume() } }
                switch mode {
                case .multipart?:
                    let active = Set(mine.compactMap { self.partNumber(from: $0) })
                    self.mutate { st in
                        for i in st.parts.indices where st.parts[i].status != .done {
                            st.parts[i].status = active.contains(st.parts[i].number) ? .inflight : .pending
                        }
                    }
                    self.updateProgress()
                    if mine.isEmpty { self.reconcileTicket(expectedAssetID: assetID) }
                    else { self.pumpMultipart() }
                case .single?:
                    if !mine.isEmpty { return }   // the running PUT completes via the delegate
                    // A PUT that finished while the app was dead delivers its
                    // completion shortly after relaunch — give it a moment before
                    // deciding to re-send, or we'd upload the same bytes twice.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.resumeSingle(expectedAssetID: assetID)
                    }
                case .none:
                    self.requestTicketAndStart(cur)
                }
            }
        }
    }

    /// An absent OS task is ambiguous, not permission to resend its bytes.
    private func resumeSingle(expectedAssetID: String) {
        guard let cur = state, cur.status == .uploading, cur.assetID == expectedAssetID else { return }
        reconcileTicket(expectedAssetID: expectedAssetID)
    }

    private func onNetworkRegained() {
        guard let s = state else { return }
        switch s.status {
        case .uploading:
            startOrResume()
        case .failed:
            // Network came back — clear per-part failures and retry only what's
            // missing. A server REJECTION is not a network problem: leave it for
            // the user (Settings "Resume" / the publish retry button).
            guard s.terminalError == nil else { return }
            mutate { st in
                st.status = .uploading
                st.retryCount = 0
                // A regained network earns the ticket one more bounded run;
                // if that runs dry too, the exhausted state (and Start over)
                // simply come back.
                st.recoveryExhausted = nil
                st.failureMessage = nil
                for i in st.parts.indices where st.parts[i].status == .failed {
                    st.parts[i].status = .pending
                    st.parts[i].retryCount = 0
                }
            }
            partNextTry.removeAll()
            partURLFailures = 0
            reconcileRounds = 0
            startOrResume()
        default:
            break
        }
    }

    // MARK: - Ticket

    /// New operations persist a UUID key before requesting any ticket. Old
    /// records retain their exact historical path/size key during migration;
    /// changing it before the old cancellation receipt would reserve twice.
    private static func ticketIdempotencyKey(for s: State) -> String {
        s.ticketKey ?? "ticket:\(DirectUploader.sha256Hex(s.filePath)):\(s.bytesTotal)"
    }

    private func requestTicketAndStart(_ s: State) {
        if let assetID = s.assetID { reconcileTicket(expectedAssetID: assetID); return }
        guard persistBeforeDispatch() else { return }
        guard !isRequestingTicket else { return }
        isRequestingTicket = true
        let expectedID = s.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await self.api.requestUpload(
                    filename: s.fileURL.lastPathComponent, bytes: s.bytesTotal,
                    listingID: s.listingID, sha256: s.sha256, kind: "video", role: s.role,
                    contentType: s.contentType ?? DirectUploader.uploadContentType(for: s.fileURL, kind: "video"),
                    idempotencyKey: Self.ticketIdempotencyKey(for: s))
                await MainActor.run {
                    self.isRequestingTicket = false
                    guard self.state?.id == expectedID else { return }   // cancelled/replaced meanwhile
                    self.applyTicket(ticket, reconcileBeforeTransfer: ticket.replayed != false)
                }
            } catch {
                await MainActor.run {
                    self.isRequestingTicket = false
                    guard self.state?.id == expectedID else { return }
                    // 400/401/403/404/413 = the server refused THIS request (bad
                    // listing id, forbidden role, type not allowed, signed out) —
                    // retrying on network regain would loop. 429/5xx/offline are
                    // transient and stay auto-resumable.
                    let api = error as? APIError
                    let terminal = api.map { $0.isValidation || $0.isUnauthorized || $0.isForbidden
                                              || $0.isNotFound || $0.isPayloadTooLarge } ?? false
                    self.fail(error.localizedDescription, terminal: terminal)
                }
            }
        }
    }

    private func applyTicket(_ ticket: UploadTicket, reconcileBeforeTransfer: Bool = false) {
        // Save the server identifiers even if the user paused mid-request, so a
        // later resume continues the SAME upload session. Only LAUNCH if still
        // uploading.
        guard var s = state else { return }
        let sameTicket = s.assetID.map { UploadRecovery.sameAsset($0, ticket.assetID) } ?? false
        let launch = (s.status == .uploading)
        s.assetID = ticket.assetID
        if let key = ticket.storageKey { s.storageKey = key }
        s.mode = ticket.mode.rawValue
        s.transportVersion = ticket.transportVersion
        if !sameTicket {
            s.singlePutDone = nil
            s.singleTaskID = nil
            s.legacyCancellationAssetID = nil
            s.legacyRecoveryApproved = nil
            s.parts = []
            s.bytesSent = 0
        }
        if ticket.uploaded == true { state = s; persist(); markDone(assetID: ticket.assetID); return }

        switch ticket.mode {
        case .single:
            guard let putURL = ticket.putURL else {
                if Config.useLiveBackend {
                    state = s; persist(); fail(UploadRecovery.Failure.invalidTicket.localizedDescription, terminal: true); return
                }
                s.mode = "simulate"; s.putURL = nil; s.putURLIssuedAt = nil
                state = s; persist()
                if launch { runSimulate() }
                return
            }
            s.putURL = putURL
            s.putURLIssuedAt = Date()
            state = s; guard persistBeforeDispatch() else { return }
            if launch {
                if reconcileBeforeTransfer { reconcileTicket(expectedAssetID: ticket.assetID) }
                else { launchSingle(putURL: putURL) }
            }

        case .multipart:
            let partSize = max(1, ticket.partSize ?? Self.defaultPartSize)
            let count = ticket.partCount ?? Int((s.bytesTotal + partSize - 1) / partSize)
            s.uploadID = ticket.uploadID
            s.partSize = partSize
            s.partCount = count
            s.putURL = nil
            s.putURLIssuedAt = nil
            let priorParts = sameTicket ? s.parts : []
            s.parts = (1...max(count, 1)).map { n in
                let offset = Int64(n - 1) * partSize
                let length = min(partSize, s.bytesTotal - offset)
                if let prior = priorParts.first(where: { $0.number == n && $0.offset == offset && $0.length == length }) {
                    return prior
                }
                return PartState(number: n, offset: offset, length: max(0, length))
            }
            for receipt in ticket.confirmedParts ?? [] {
                if let i = s.parts.firstIndex(where: { $0.number == receipt.number }) {
                    s.parts[i].status = .done
                    s.parts[i].etag = receipt.etag
                    s.parts[i].taskID = nil
                }
            }
            state = s; guard persistBeforeDispatch() else { return }
            if launch {
                if reconcileBeforeTransfer { reconcileTicket(expectedAssetID: ticket.assetID) }
                else { pumpMultipart() }
            }
        }
    }

    private static let defaultPartSize: Int64 = 64 * 1024 * 1024   // fallback only; server sets the real size

    // MARK: - Single mode

    private func launchSingle(putURL: URL) {
        guard let s = state, s.status == .uploading else { return }
        // The PUT's Content-Type must equal the ticket's declaration (P0 fix).
        let contentType = s.contentType ?? DirectUploader.uploadContentType(for: s.fileURL, kind: "video")
        let task = backgroundSession.uploadTask(with: DirectUploader.putRequest(url: putURL, contentType: contentType),
                                                fromFile: s.fileURL)
        if let assetID = s.assetID { task.taskDescription = "single:\(assetID)" }
        mutate { $0.singleTaskID = task.taskIdentifier }
        guard persistBeforeDispatch() else { task.cancel(); return }
        task.resume()
    }

    private func handleSingleCompletion(task: URLSessionTask, error: Error?) {
        guard let s = state, let assetID = s.assetID,
              // A stale task from a PREVIOUS upload session (background tasks
              // outlive `state` swaps) must never drive the current upload's
              // completion — its task description names a different asset id.
              task.taskDescription == "single:\(assetID)",
              s.singleTaskID == nil || s.singleTaskID == task.taskIdentifier else { return }
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || !(200..<300).contains(httpStatus) {
            guard s.status == .uploading else { return }   // paused/cancelled → leave resumable
            // Single mode has exactly one part, so `retryCount` IS that part's
            // transfer count — it is no longer also spent by every
            // reconciliation round (see `reconcileRounds`). Five failed PUTs of
            // the same file against freshly renewed URLs means this ticket is
            // not going to take the bytes: say so, and offer a fresh one.
            guard s.retryCount < Self.maxTransferAttemptsPerPart else {
                fail((httpStatus > 0 ? "Storage returned status \(httpStatus) while uploading." : "The upload kept failing before storage accepted it.")
                     + " Your original is safe — tap Start over to send it again under a new upload ticket.",
                     exhausted: true)
                return
            }
            mutate { $0.retryCount += 1 }
            let attempt = state?.retryCount ?? 1
            let delay = pow(2.0, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let cur = self.state, cur.status == .uploading, cur.assetID == assetID else { return }
                self.reconcileTicket(expectedAssetID: assetID)
            }
            return
        }
        // Success — single PUT needs no ETag manifest. Remember the PUT landed so
        // a resume only re-sends `/complete`, never the bytes.
        mutate { $0.singlePutDone = true }
        completeAndFinish(assetID: assetID, parts: nil, metadata: buildMetadata(from: s))
    }

    // MARK: - Multipart mode

    /// Launch up to `maxConcurrent` parts; only materialize temp slices for the
    /// parts actually in flight. Re-entrant-safe (marks picked parts inflight
    /// synchronously before the async URL fetch).
    private func pumpMultipart() {
        guard let s = state, s.status == .uploading, s.mode == "multipart",
              let assetID = s.assetID else { return }

        if !s.parts.isEmpty, s.parts.allSatisfy({ $0.status == .done }) {
            finishMultipart(); return
        }

        let inflight = s.parts.filter { $0.status == .inflight }.count
        guard inflight < maxConcurrent else { return }

        let now = Date()
        let ready = s.parts.filter {
            $0.status == .pending && (partNextTry[$0.number].map { $0 <= now } ?? true)
        }
        let batch = Array(ready.prefix(maxConcurrent - inflight))
        guard !batch.isEmpty else {
            // Nothing launchable right now. If a part permanently failed and none
            // are in flight, the whole upload is failed (but resumable).
            if inflight == 0 && s.parts.contains(where: { $0.status == .failed }) {
                fail(nil)
            }
            return
        }

        let numbers = batch.map { $0.number }
        mutate { st in
            for i in st.parts.indices where numbers.contains(st.parts[i].number) {
                st.parts[i].status = .inflight
            }
        }
        Task { [weak self] in await self?.launchParts(assetID: assetID, numbers: numbers) }
    }

    /// Small value describing one part to slice + upload. Snapshotted on the main
    /// actor (where `state` lives), then used off-main for the heavy disk copy.
    private struct PartSpec { let n: Int; let url: URL; let offset: Int64; let length: Int64 }

    private func launchParts(assetID: String, numbers: [Int]) async {
        // 1. Fetch presigned part URLs (off the main thread — this is `await`ed
        //    on the cooperative pool, not on main).
        let urls: [Int: URL]
        do {
            urls = try await api.fetchPartURLs(assetID: assetID, numbers: numbers)
        } catch {
            await MainActor.run {
                guard self.state?.assetID == assetID else { return }
                self.revertToPending(numbers)
                if (error as? APIError)?.status == 409 {
                    // part-urls uses a generic conflict for legacy/aborted
                    // tickets. Complete must identify which before any cancel.
                    self.reconcileTicket(expectedAssetID: assetID)
                    return
                }
                if let api = error as? APIError,
                   api.isValidation || api.isNotFound || api.isForbidden || api.isUnauthorized || api.isConflict {
                    // The server refuses this upload session (e.g. 409 "not a
                    // multipart upload" after an abort, 404 asset gone, signed
                    // out) — don't spin on it every 5 s; the user resumes. A
                    // ticket that is simply gone is also marked exhausted, so
                    // the offer is Start over rather than a Resume that 404s.
                    self.fail(api.localizedDescription, terminal: true, exhausted: UploadRecovery.isRetired(api))
                } else {
                    self.scheduleMultipartRetry()
                }
            }
            return
        }

        // 2. Snapshot each part's byte range on the main actor (state is main-isolated).
        let (fileURL, specs): (URL?, [PartSpec]) = await MainActor.run {
            // Storage planned a batch: the part-URL failure streak is over.
            self.partURLFailures = 0
            guard let s = self.state, s.status == .uploading, s.assetID == assetID else {
                self.revertToPending(numbers); return (nil, [])   // paused/cancelled mid-fetch
            }
            var out: [PartSpec] = []
            for n in numbers {
                guard let url = urls[n],
                      let part = s.parts.first(where: { $0.number == n }) else {
                    self.handlePartRetry(n); continue
                }
                guard UploadRecovery.isBoundedCapability(url) else {
                    // Rolling back just the edge handler must not turn a v2
                    // reservation into reusable host-only multipart PUT URLs.
                    self.fail(UploadRecovery.Failure.incompatibleTransport.localizedDescription, terminal: true)
                    return (nil, [])
                }
                out.append(PartSpec(n: n, url: url, offset: part.offset, length: part.length))
            }
            return (s.fileURL, out)
        }
        guard let fileURL, !specs.isEmpty else { return }

        // 3. Materialize each temp slice OFF the main thread (a slice can be tens of
        //    MB — copying it on main janks the UI and risks a watchdog kill), then
        //    hop to main ONLY to create + resume the background upload task.
        for spec in specs {
            let slice = DirectUploader.sliceURL(for: assetID, part: spec.n)
            do {
                try DirectUploader.writeSlice(of: fileURL, offset: spec.offset,
                                              length: spec.length, to: slice)
            } catch {
                // Disk write failed (e.g. disk full) — drop any partial slice and
                // send this part back through retry. Never crashes the upload.
                DirectUploader.removeSlice(for: assetID, part: spec.n)
                await MainActor.run { self.handlePartRetry(spec.n) }
                continue
            }
            await MainActor.run {
                // Re-check the part is still wanted (not paused/cancelled/reverted
                // while we were slicing).
                guard let s = self.state, s.status == .uploading, s.assetID == assetID,
                      s.parts.first(where: { $0.number == spec.n })?.status == .inflight else {
                    DirectUploader.removeSlice(for: assetID, part: spec.n)
                    self.revertToPending([spec.n])
                    return
                }
                // Part PUT URLs sign only host + query — NO content type header
                // (the object's type was fixed at CreateMultipartUpload).
                let task = self.backgroundSession.uploadTask(
                    with: DirectUploader.partPutRequest(url: spec.url), fromFile: slice)
                task.taskDescription = "part:\(assetID):\(spec.n)"
                self.mutate { state in
                    if let i = state.parts.firstIndex(where: { $0.number == spec.n }) {
                        state.parts[i].taskID = task.taskIdentifier
                    }
                }
                self.inFlightBytes[spec.n] = 0
                guard self.persistBeforeDispatch() else { task.cancel(); return }
                task.resume()
            }
        }
    }

    private func handlePartCompletion(task: URLSessionTask, error: Error?) {
        guard let assetID = state?.assetID, let n = partNumber(from: task),
              // Ignore stale part tasks from a PREVIOUS upload session — marking
              // the current upload's part "done" with a foreign ETag would
              // corrupt the manifest and fail (or worse, mis-assemble) the file.
              task.taskDescription == "part:\(assetID):\(n)",
              let part = state?.parts.first(where: { $0.number == n }),
              part.taskID == nil || part.taskID == task.taskIdentifier else { return }
        DirectUploader.removeSlice(for: assetID, part: n)   // temp slice no longer needed
        inFlightBytes[n] = nil
        guard let s = state else { return }                 // cancelled

        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || !(200..<300).contains(httpStatus) {
            if s.status == .paused {
                // Suspended/interrupted — keep it resumable, no retry burn.
                mutate { st in
                    if let i = st.parts.firstIndex(where: { $0.number == n }),
                       st.parts[i].status != .done { st.parts[i].status = .pending }
                }
                return
            }
            // The failure counts against THIS part, never the whole upload:
            // three parts tripping over one network blip is one bad moment,
            // not three strikes against the file. A part that has failed its
            // own transfer five times marks the upload failed (resumable — a
            // regained network resets it), exactly like an exhausted slice.
            let attempts = part.retryCount + 1
            guard attempts <= Self.maxTransferAttemptsPerPart else {
                mutate { st in
                    if let i = st.parts.firstIndex(where: { $0.number == n }) { st.parts[i].status = .failed }
                    st.failureMessage = "Part \(n) of the upload kept failing. It will resume when the connection recovers."
                    st.status = .failed
                }
                updateProgress()
                return
            }
            // Fetching fresh part URLs is the recovery operation: v2 resolves a
            // recorded uncertain dispatch or refuses it, never another write.
            // Probe complete first so a lost final acknowledgement wins.
            mutate { st in
                if let i = st.parts.firstIndex(where: { $0.number == n }) {
                    st.parts[i].status = .pending
                    st.parts[i].retryCount = attempts
                }
            }
            reconcileTicket(expectedAssetID: assetID)
            updateProgress()
            return
        }

        // Success — the part ETag lives in the response headers (contract §5).
        let etag = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Etag")
        guard let etag, !etag.isEmpty else { handlePartRetry(n); return }
        mutate { st in
            if let i = st.parts.firstIndex(where: { $0.number == n }) {
                st.parts[i].status = .done
                st.parts[i].etag = etag
                st.parts[i].retryCount = 0
            }
        }
        partNextTry[n] = nil
        reconcileRounds = 0   // a receipt landed: real progress, the round budget starts over
        updateProgress()
        if state?.parts.allSatisfy({ $0.status == .done }) == true {
            finishMultipart()
        } else {
            pumpMultipart()
        }
    }

    private func handlePartRetry(_ n: Int) {
        guard let s = state, s.status == .uploading,
              let idx = s.parts.firstIndex(where: { $0.number == n }) else { return }
        if s.parts[idx].retryCount >= 5 {
            // Exhausted — mark this part and the whole upload failed (resumable).
            mutate { st in
                if let i = st.parts.firstIndex(where: { $0.number == n }) { st.parts[i].status = .failed }
                st.failureMessage = "Part \(n) of the upload kept failing. It will resume when the connection recovers."
                st.status = .failed
            }
            return
        }
        let attempt = s.parts[idx].retryCount + 1
        mutate { st in
            if let i = st.parts.firstIndex(where: { $0.number == n }) {
                st.parts[i].status = .pending
                st.parts[i].retryCount = attempt
            }
        }
        let delay = pow(2.0, Double(attempt))
        partNextTry[n] = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pumpMultipart() }
        pumpMultipart()   // let other pending parts keep the pipe full
    }

    private func revertToPending(_ numbers: [Int]) {
        mutate { st in
            for i in st.parts.indices
            where numbers.contains(st.parts[i].number) && st.parts[i].status == .inflight {
                st.parts[i].status = .pending
            }
        }
        for n in numbers { inFlightBytes[n] = nil }
    }

    /// `/part-urls` failed for a transient-looking reason (5xx, offline). Try
    /// again with backoff — 5 s doubling to a 30 s ceiling — but only
    /// `maxPartURLAttempts` times in a row. Then it is a real, visible failure
    /// with Start over on offer, not a silent five-second loop for the rest of
    /// the day. The counter resets whenever a batch of URLs does arrive.
    private func scheduleMultipartRetry() {
        partURLFailures += 1
        guard partURLFailures <= Self.maxPartURLAttempts else {
            partURLFailures = 0
            fail("Storage kept refusing to plan the next parts of this upload. Your original is safe — "
                 + "tap Start over to send it again under a new upload ticket.", exhausted: true)
            return
        }
        let delay = min(30.0, 5.0 * pow(2.0, Double(partURLFailures - 1))) * retryDelayScale
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pumpMultipart() }
    }

    private func finishMultipart() {
        guard let s = state, let assetID = s.assetID else { return }
        let ordered = s.parts.sorted { $0.number < $1.number }
        let manifest: [(number: Int, etag: String)] = ordered.compactMap { p in
            guard let e = p.etag else { return nil }
            return (p.number, e)
        }
        guard manifest.count == s.parts.count, !manifest.isEmpty else {
            // An ETag went missing. Send the affected parts back to .pending so
            // the resume path RE-UPLOADS them — leaving them .done-without-etag
            // would loop resume → finishMultipart → failed forever.
            mutate { st in
                st.status = .failed          // resumable
                for i in st.parts.indices
                where st.parts[i].status == .done && st.parts[i].etag == nil {
                    st.parts[i].status = .pending
                }
            }
            return
        }
        completeAndFinish(assetID: assetID, parts: manifest, metadata: buildMetadata(from: s))
    }

    // MARK: - Completion

    /// `POST /uploads/:id/complete` for both modes. 2xx → done. 409 "already
    /// complete" → done (a lost response on a successful complete). Any other
    /// 4xx → TERMINAL (the server rejected/deleted the object — e.g. a type or
    /// size mismatch — so re-ticketing in a loop only burns the daily budget;
    /// the message is surfaced). 5xx/offline → resumable.
    private func completeAndFinish(assetID: String, parts: [(number: Int, etag: String)]?,
                                   metadata: UploadMetadata) {
        reconcileTicket(expectedAssetID: assetID)
    }

    /// One metadata reconciliation path for relaunch, transfer failure and
    /// completion failure. Only the server can authorize another physical write.
    private func reconcileTicket(expectedAssetID assetID: String) {
        guard !isCompleting else { return }
        guard let snapshot = state, snapshot.status == .uploading, snapshot.assetID == assetID else { return }
        // Rounds are counted here, transiently, and reset the moment a part's
        // receipt lands. They used to be charged to the persisted per-upload
        // `retryCount`, which every failing part also consumed — so a big
        // multipart upload on a flaky link "ran out of retries" after a handful
        // of part hiccups spread across different parts. This guard catches
        // the loops where every round SUCCEEDS yet nothing lands (a renewed
        // ticket whose part URLs keep 409ing); the catch below counts the
        // rounds that throw.
        guard reconcileRounds < Self.maxReconcileRounds else {
            fail(Self.reconciliationExhaustedMessage, exhausted: true)
            return
        }
        reconcileRounds += 1
        isCompleting = true
        let attemptID = UUID()
        recoveryAttempt = attemptID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryAttempt == attemptID {
                    self.recoveryAttempt = nil
                    self.isCompleting = false
                }
            }
            let ticket = UploadTicket(assetID: assetID,
                mode: snapshot.mode == "multipart" ? .multipart : .single,
                putURL: snapshot.putURL, uploadID: snapshot.uploadID,
                partSize: snapshot.partSize, partCount: snapshot.partCount,
                storageKey: snapshot.storageKey, transportVersion: snapshot.transportVersion)
            let parts = snapshot.parts.compactMap { part -> (number: Int, etag: String)? in
                guard let etag = part.etag, part.status == .done else { return nil }
                return (part.number, etag)
            }
            func requireCurrent() throws {
                guard self.state?.id == snapshot.id, self.state?.assetID == assetID,
                      self.state?.status == .uploading else { throw CancellationError() }
            }
            do {
                let result = try await UploadRecovery.reconcile(
                    journal: .init(ticket: ticket, cancellationAuthorizedFor: snapshot.legacyCancellationAssetID),
                    allowLegacyCancellation: snapshot.legacyRecoveryApproved == true,
                    incompleteMultipart: ticket.mode == .multipart && parts.count != snapshot.partCount,
                    persistCancellation: { id in
                        try requireCurrent()
                        self.mutate { $0.legacyCancellationAssetID = id }
                        guard self.persistState(self.state) else { throw CocoaError(.fileWriteUnknown) }
                    }, complete: { id in
                        try requireCurrent()
                        try await self.api.completeUpload(assetID: id, parts: ticket.mode == .multipart ? parts : nil,
                                                          metadata: self.buildMetadata(from: snapshot))
                    }, renew: { id in
                        try requireCurrent()
                        return try await self.api.renewUpload(assetID: id)
                    }, cancel: { id in
                        try requireCurrent()
                        // The caller explicitly resumed THIS retired ticket.
                        // Only its OS tasks stop; unrelated transfers are untouched.
                        let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                            self.backgroundSession.getAllTasks { continuation.resume(returning: $0) }
                        }
                        for task in tasks where task.taskDescription == "single:\(id)" ||
                            task.taskDescription?.hasPrefix("part:\(id):") == true { task.cancel() }
                        try requireCurrent()
                        try await self.api.abortUpload(assetID: id)
                    }, create: {
                        try requireCurrent()
                        return try await self.api.requestUpload(filename: snapshot.fileURL.lastPathComponent,
                            bytes: snapshot.bytesTotal, listingID: snapshot.listingID, sha256: snapshot.sha256,
                            kind: "video", role: snapshot.role, contentType: snapshot.contentType,
                            idempotencyKey: Self.ticketIdempotencyKey(for: snapshot))
                    })
                try requireCurrent()
                self.isCompleting = false
                self.recoveryAttempt = nil
                switch result {
                case .complete(let id): self.markDone(assetID: id)
                case .ticket(let renewed): self.applyTicket(renewed)
                }
            } catch is CancellationError {
                // Pausing or replacing the record is not a server failure.
            } catch {
                guard self.state?.id == snapshot.id, self.state?.assetID == assetID,
                      self.state?.status == .uploading else { return }
                let status = (error as? APIError)?.status
                let terminal = error is UploadRecovery.Failure ||
                    (status.map { (400..<500).contains($0) && $0 != 429 && $0 != 408 } ?? false)
                // A transient answer (5xx, offline, 429) leaves the record
                // resumable as before — but each such round is counted, so five
                // of them in a row end in the exhausted state with Start over
                // on offer instead of "Tap Resume to check again" forever. A
                // ticket the server retired outright (gone, or aborted behind
                // our back) is terminal AND exhausted: no Resume can revive it,
                // only a fresh reservation. The legacy-consent failure stays a
                // plain terminal so its explicit Resume path is untouched.
                let retired = UploadRecovery.isRetired(error)
                let ranDry = !terminal && self.reconcileRounds >= Self.maxReconcileRounds
                if ranDry {
                    self.fail(Self.reconciliationExhaustedMessage, exhausted: true)
                } else {
                    self.fail(error.localizedDescription, terminal: terminal, exhausted: retired)
                }
            }
        }
    }

    private static let reconciliationExhaustedMessage =
        "Upload recovery couldn't get a storage receipt for this upload ticket after several tries. "
        + "Your original is safe — tap Start over to send it again under a new ticket, or Resume to check this one once more."

    private func markDone(assetID: String) {
        guard let s = state, s.assetID == assetID || s.mode == "simulate" else { return }
        mutate { st in
            st.status = .done
            st.bytesSent = st.bytesTotal
            st.failureMessage = nil
            st.terminalError = nil
        }
        DirectUploader.cleanSlices(for: assetID)
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        partURLFailures = 0
        reconcileRounds = 0
        lastFailureMessage = nil
        Haptics.success()
        emitCompletion(assetID: assetID, from: s)
        // Consumed (continuation + notification). The `.done` record stays in
        // MEMORY only — observers that hop to the main actor (AppModel's
        // pending-publish handler reads `state?.role`/`assetID`) still see it,
        // Settings shows "Complete" until the next upload replaces it, and a
        // relaunch never resurrects a weeks-old "Complete · 100%" because the
        // on-disk copy is removed here (and `init` drops any legacy `.done`).
        _ = persistState(nil)
    }

    private func emitCompletion(assetID: String, from s: State) {
        onUploadComplete?(assetID)
        var info: [String: Any] = ["assetID": assetID, "role": s.role]
        if let listingID = s.listingID { info["listingID"] = listingID }
        if let local = s.listingLocalID { info["listingLocalID"] = local }
        NotificationCenter.default.post(name: Self.didCompleteNotification, object: self, userInfo: info)
    }

    /// Single choke point for failures: records the message, flips to `.failed`
    /// (which notifies any awaiting `upload()` via `mutate`), and marks server
    /// rejections terminal so the auto-resume paths leave them alone.
    /// `exhausted` marks a ticket the engine's own bounded recovery gave up
    /// on: still auto-resumable once on a network regain, but from now on the
    /// record offers Start over (`State.canStartOver`).
    private func fail(_ message: String?, terminal: Bool = false, exhausted: Bool = false) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastFailureMessage = (text?.isEmpty == false) ? text : nil
        mutate { st in
            st.failureMessage = (text?.isEmpty == false) ? text : nil
            if terminal { st.terminalError = (text?.isEmpty == false) ? text : "The server rejected this upload." }
            if exhausted { st.recoveryExhausted = true }
            st.status = .failed
        }
    }

    // MARK: - Photo batch

    private func runPhotoBatch(listingID: UUID, fileURLs: [URL]) async {
        guard fileURLs.count <= 200 else {
            await MainActor.run {
                self.photoProgress?.failed = fileURLs.count
                self.lastFailureMessage = "Choose at most 200 photos per upload. No files were sent."
            }
            return
        }
        // Per-file stable receipts avoid re-reserving the whole batch when one
        // photo fails. The same three-transfer ceiling and per-file server
        // charging remain; completed local originals are never thrown away.
        var completedIDs: [String] = []
        await withTaskGroup(of: (String?, Bool).self) { group in
            var iterator = fileURLs.makeIterator()
            func addNext() {
                guard let fileURL = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return (nil, false) }
                    do {
                        let id = try await DirectUploader.uploadPhoto(fileURL: fileURL, listingID: listingID,
                            role: "capture", contentType: DirectUploader.mimeType(for: fileURL),
                            keyPrefix: "photo", api: self.api)
                        return (id, true)
                    } catch {
                        await MainActor.run { self.lastFailureMessage = error.localizedDescription }
                        return (nil, false)
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, fileURLs.count) { addNext() }
            while let (assetID, ok) = await group.next() {
                if let assetID { completedIDs.append(assetID) }
                await MainActor.run {
                    if ok { self.photoProgress?.completed += 1 }
                    else  { self.photoProgress?.failed += 1 }
                }
                addNext()
            }
        }

        let ids = completedIDs
        await MainActor.run {
            NotificationCenter.default.post(name: Self.photosDidCompleteNotification, object: self,
                                            userInfo: ["assetIDs": ids, "listingID": listingID])
        }
    }

    // MARK: - Simulate mode (offline dev; real disk reads, resumes from offset)

    private func runSimulate() {
        simulateTimer?.invalidate()
        guard let s = state,
              let handle = try? FileHandle(forReadingFrom: s.fileURL) else {
            fail("The file to upload is missing.", terminal: true)
            return
        }
        try? handle.seek(toOffset: UInt64(max(0, s.bytesSent)))

        // Compute checksum once, off-main, while "uploading".
        if s.sha256 == nil { computeHashInBackground(fileURL: s.fileURL, uploadID: s.id) }

        let chunk = 4_000_000  // ~4MB per tick ≈ realistic Wi-Fi pace
        simulateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, var s = self.state, s.status == .uploading else {
                timer.invalidate()
                try? handle.close()
                return
            }
            let data = autoreleasepool { handle.readData(ofLength: chunk) }
            if data.isEmpty {
                timer.invalidate()
                try? handle.close()
                // Finish through the SAME completion path as the live engine so an
                // awaiting upload() resolves and didCompleteNotification fires
                // (it used to set .done silently and hang the publish).
                let assetID = s.assetID ?? "mock-\(s.id.uuidString.lowercased())"
                if s.assetID == nil { self.mutate { $0.assetID = assetID } }
                self.markDone(assetID: assetID)
                return
            }
            s.bytesSent = min(s.bytesTotal, s.bytesSent + Int64(data.count))
            self.state = s
            // Persist every ~2% so a kill mid-upload resumes close to where it died.
            if s.bytesSent % Int64(chunk * 12) < Int64(chunk) { self.persist() }
        }
    }

    // MARK: - Helpers

    private func computeHashInBackground(fileURL: URL, uploadID: UUID) {
        guard let s = state, s.id == uploadID, s.sha256 == nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let digest = DirectUploader.sha256(of: fileURL) else { return }
            DispatchQueue.main.async {
                // Only land on the SAME upload this digest was started for.
                guard let self, var s = self.state, s.id == uploadID, s.sha256 == nil else { return }
                s.sha256 = digest
                if s.metadata?.sha256 == nil { s.metadata?.sha256 = digest }
                self.state = s
                self.persist()
            }
        }
    }

    private func buildMetadata(from s: State) -> UploadMetadata {
        var m = s.metadata ?? UploadMetadata()
        if m.bytes == nil { m.bytes = s.bytesTotal }
        if m.sha256 == nil { m.sha256 = s.sha256 }
        return m
    }

    /// Recompute UI progress = done-part bytes + in-flight bytes. Publishes only
    /// (no disk write — structural persistence happens on status changes).
    private func updateProgress() {
        guard var s = state, s.mode == "multipart" else { return }
        let done = s.parts.filter { $0.status == .done }.reduce(Int64(0)) { $0 + $1.length }
        let inflight = inFlightBytes.values.reduce(Int64(0), +)
        let sent = min(s.bytesTotal, done + inflight)
        if sent != s.bytesSent {
            s.bytesSent = sent
            state = s
        }
    }

    private func partNumber(from task: URLSessionTask) -> Int? {
        guard let d = task.taskDescription, d.hasPrefix("part:") else { return nil }
        return Int(d.split(separator: ":").last.map(String.init) ?? "")
    }

    private func mutate(_ change: (inout State) -> Void) {
        guard var s = state else { return }
        let wasFailed = (s.status == .failed)
        change(&s)
        state = s
        persist()
        // Single choke point for terminal failure → notify any awaiting upload().
        if !wasFailed, s.status == .failed { onUploadFailed?(s.failureMessage) }
    }

    @discardableResult
    private func persist() -> Bool {
        persistState(state)
    }

    /// Sending/cancelling without a saved ticket identity cannot be recovered
    /// after a process kill. Refuse that transition, not the original media.
    private func persistBeforeDispatch() -> Bool {
        guard persist() else {
            fail("Upload progress could not be saved. Your original is safe. Free some device storage and tap Resume.", terminal: true)
            return false
        }
        return true
    }
}

// MARK: - Codable (tolerant: older persisted state decodes with defaults)
extension UploadManager.State {
    enum CodingKeys: String, CodingKey {
        case id, filePath, bytesTotal, bytesSent, status, mode, assetID, storageKey,
             uploadID, partSize, partCount, parts, sha256, retryCount, listingID, role, metadata,
             contentType, listingLocalID, putURL, putURLIssuedAt, singlePutDone,
             failureMessage, terminalError, transportVersion, ticketKey,
             legacyRecoveryApproved, legacyCancellationAssetID, singleTaskID,
             recoveryExhausted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filePath    = try c.decode(String.self, forKey: .filePath)
        bytesTotal  = try c.decodeIfPresent(Int64.self, forKey: .bytesTotal) ?? 0
        bytesSent   = try c.decodeIfPresent(Int64.self, forKey: .bytesSent) ?? 0
        // Decode status via its raw string so an UNKNOWN value (written by a
        // newer build) degrades to .queued — which re-raises the start prompt —
        // instead of throwing away resumable per-part progress.
        let statusRaw = try c.decodeIfPresent(String.self, forKey: .status)
        status      = statusRaw.flatMap(UploadManager.Status.init(rawValue:)) ?? .queued
        mode        = try c.decodeIfPresent(String.self, forKey: .mode) ?? "simulate"
        assetID     = try c.decodeIfPresent(String.self, forKey: .assetID)
        storageKey  = try c.decodeIfPresent(String.self, forKey: .storageKey)
        uploadID    = try c.decodeIfPresent(String.self, forKey: .uploadID)
        partSize    = try c.decodeIfPresent(Int64.self, forKey: .partSize)
        partCount   = try c.decodeIfPresent(Int.self, forKey: .partCount)
        parts       = try c.decodeIfPresent([UploadManager.PartState].self, forKey: .parts) ?? []
        sha256      = try c.decodeIfPresent(String.self, forKey: .sha256)
        retryCount  = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        listingID   = try c.decodeIfPresent(UUID.self, forKey: .listingID)
        role        = try c.decodeIfPresent(String.self, forKey: .role) ?? "capture"
        metadata    = try c.decodeIfPresent(UploadMetadata.self, forKey: .metadata)
        contentType     = try c.decodeIfPresent(String.self, forKey: .contentType)
        listingLocalID  = try c.decodeIfPresent(UUID.self, forKey: .listingLocalID)
        putURL          = try c.decodeIfPresent(URL.self, forKey: .putURL)
        putURLIssuedAt  = try c.decodeIfPresent(Date.self, forKey: .putURLIssuedAt)
        singlePutDone   = try c.decodeIfPresent(Bool.self, forKey: .singlePutDone)
        failureMessage  = try c.decodeIfPresent(String.self, forKey: .failureMessage)
        terminalError   = try c.decodeIfPresent(String.self, forKey: .terminalError)
        transportVersion = try c.decodeIfPresent(Int.self, forKey: .transportVersion)
        ticketKey = try c.decodeIfPresent(String.self, forKey: .ticketKey)
        legacyRecoveryApproved = try c.decodeIfPresent(Bool.self, forKey: .legacyRecoveryApproved)
        legacyCancellationAssetID = try c.decodeIfPresent(String.self, forKey: .legacyCancellationAssetID)
        singleTaskID = try c.decodeIfPresent(Int.self, forKey: .singleTaskID)
        recoveryExhausted = try c.decodeIfPresent(Bool.self, forKey: .recoveryExhausted)
    }
}

// Per-part tolerant decode: number/offset/length are REQUIRED (a part without
// its byte range can't be re-sliced and must fail the load → fresh upload), but
// status/etag/retryCount tolerate missing keys and unknown raw values so a
// version change can't discard hours of already-uploaded parts.
extension UploadManager.PartState {
    enum CodingKeys: String, CodingKey { case number, offset, length, status, etag, retryCount, taskID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number     = try c.decode(Int.self, forKey: .number)
        offset     = try c.decode(Int64.self, forKey: .offset)
        length     = try c.decode(Int64.self, forKey: .length)
        let statusRaw = try c.decodeIfPresent(String.self, forKey: .status)
        status     = statusRaw.flatMap(UploadManager.PartStatus.init(rawValue:)) ?? .pending
        etag       = try c.decodeIfPresent(String.self, forKey: .etag)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        taskID = try c.decodeIfPresent(Int.self, forKey: .taskID)
    }
}

// MARK: - Background URLSession delegate
extension UploadManager: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let desc = task.taskDescription ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only the CURRENT upload session's tasks may drive progress —
            // stale background tasks from a replaced session are ignored.
            guard let assetID = self.state?.assetID else { return }
            if desc.hasPrefix("part:"), let n = self.partNumber(from: task) {
                guard desc == "part:\(assetID):\(n)",
                      let part = self.state?.parts.first(where: { $0.number == n }),
                      part.taskID == nil || part.taskID == task.taskIdentifier else { return }
                self.inFlightBytes[n] = totalBytesSent
                self.updateProgress()
            } else if desc.hasPrefix("single:") {
                guard desc == "single:\(assetID)", var s = self.state,
                      s.singleTaskID == nil || s.singleTaskID == task.taskIdentifier else { return }
                s.bytesSent = min(s.bytesTotal, totalBytesSent)
                self.state = s
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let desc = task.taskDescription ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if desc.hasPrefix("part:") {
                self.handlePartCompletion(task: task, error: error)
            } else if desc.hasPrefix("single:") {
                self.handleSingleCompletion(task: task, error: error)
            }
            // Unrecognized tasks (e.g. stale) are ignored.
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundSessionBridge.shared.completionHandler?()
            BackgroundSessionBridge.shared.completionHandler = nil
        }
    }
}
