import Foundation
import Network

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
///    transient failure retries the same presigned URL until its 15-min TTL,
///    then re-tickets; a `/complete` 4xx is TERMINAL (the message is surfaced,
///    no re-ticket loop); a `/complete` 409 "already complete" is success.
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
        var retryCount: Int = 0           // single-mode whole-upload retries
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
        /// Single mode: the presigned PUT URL + when it was issued, so a retry
        /// re-uses the same URL while it is valid instead of minting a new ticket
        /// (each ticket is a new server row + daily-budget charge).
        var putURL: URL? = nil
        var putURLIssuedAt: Date? = nil
        /// Single mode: the PUT landed; only `/complete` is outstanding.
        var singlePutDone: Bool? = nil
        /// Last failure shown to the user (server message when there was one).
        var failureMessage: String? = nil
        /// Set when the server REJECTED the upload (4xx on ticket or complete):
        /// auto-resume must not loop on it; only an explicit user retry
        /// (`resume()`) starts over with a fresh ticket.
        var terminalError: String? = nil

        var fractionComplete: Double {
            bytesTotal > 0 ? Double(bytesSent) / Double(bytesTotal) : 0
        }

        var fileURL: URL {
            FileStore.documents.appendingPathComponent(filePath)
        }

        /// True when the engine will pick this up on network regain / launch.
        var isAutoResumable: Bool { status == .failed && terminalError == nil }
        /// True when a user-facing "Resume" makes sense (failed, paused, or
        /// rejected — the latter starts over with a fresh ticket).
        var canResume: Bool { status == .failed || status == .paused }
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

    /// Presigned single-PUT URLs live 15 min server-side; treat one as reusable
    /// for 13 min so a retry never starts a PUT that will 403 halfway.
    private static let putURLReuseWindow: TimeInterval = 13 * 60

    // Mock by default; LiveAPIClient when Config.useLiveBackend.
    private var api: APIClient = Config.makeAPIClient()

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
                resume()
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

        var newState = State(filePath: FileStore.relativePath(for: fileURL),
                             bytesTotal: bytes,
                             mode: Config.useLiveBackend ? "pending" : "simulate")
        newState.listingID = listingID
        newState.listingLocalID = listingLocalID
        newState.role = role
        // Declared once here; the ticket and the PUT both use this exact value.
        newState.contentType = DirectUploader.uploadContentType(for: fileURL, kind: "video")
        var meta = metadata
        if meta.bytes == nil { meta.bytes = bytes }
        newState.metadata = meta
        newState.status = needsWifi ? .queued : .uploading
        state = newState
        lastFailureMessage = nil
        persist()

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
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0 else { throw UploadError.missingFile }
        let contentType = "image/jpeg"
        let key = "poster:" + DirectUploader.sha256Hex(FileStore.relativePath(for: fileURL)) + ":\(bytes)"
        let ticket = try await api.requestUpload(
            filename: fileURL.lastPathComponent, bytes: bytes, listingID: listingID,
            sha256: nil, kind: "photo", role: "render", contentType: contentType,
            idempotencyKey: key)
        guard let putURL = ticket.putURL else {
            if Config.useLiveBackend { throw UploadError.failed }   // server bug: single ticket without a URL
            return ticket.assetID                                    // offline dev
        }
        var lastError: Error = UploadError.failed
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            }
            do {
                // Photo PUT URLs are presigned WITH the content-type header — the
                // value must match the declaration exactly.
                let request = DirectUploader.photoPutRequest(url: putURL, contentType: contentType)
                let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else { throw APIError.badResponse(status) }
                var meta = UploadMetadata()
                meta.bytes = bytes
                do {
                    try await api.completeUpload(assetID: ticket.assetID, parts: nil, metadata: meta)
                } catch let err as APIError where err.isAlreadyComplete {
                    // A lost response on a successful complete — the asset is fine.
                }
                return ticket.assetID
            } catch let err as APIError where err.isValidation || err.isPayloadTooLarge || err.isNotFound || err.isForbidden {
                throw UploadError.server(err.localizedDescription)   // terminal — retrying identically won't help
            } catch {
                lastError = error
            }
        }
        if let api = lastError as? APIError { throw UploadError.server(api.localizedDescription) }
        throw lastError
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

    /// Pause. Multipart parts in flight are CANCELLED and sent back to pending
    /// (nsurlsessiond does not honour `suspend()` on background tasks — the
    /// bytes kept flowing); parts already done stay done, so resume re-uploads
    /// only what's missing. A single PUT is suspended (cancelling it would lose
    /// the whole transfer).
    func pause() {
        simulateTimer?.invalidate()
        backgroundSession.getAllTasks { tasks in
            for task in tasks {
                let desc = task.taskDescription ?? ""
                if desc.hasPrefix("part:") { task.cancel() }
                else if desc.hasPrefix("single:") { task.suspend() }
            }
        }
        mutate { st in
            st.status = .paused
            for i in st.parts.indices where st.parts[i].status == .inflight {
                st.parts[i].status = .pending
            }
        }
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        updateProgress()
    }

    /// Resume a paused/failed upload. A REJECTED upload (terminal error) starts
    /// over with a fresh ticket — an explicit user action, never a loop.
    func resume() {
        guard var s = state, s.status != .done else { return }
        if s.terminalError != nil {
            s.terminalError = nil
            s.failureMessage = nil
            s.assetID = nil
            s.storageKey = nil
            s.uploadID = nil
            s.putURL = nil
            s.putURLIssuedAt = nil
            s.singlePutDone = nil
            s.parts = []
            s.bytesSent = 0
            s.retryCount = 0
            s.mode = Config.useLiveBackend ? "pending" : "simulate"
        }
        s.status = .uploading
        s.retryCount = 0          // a fresh budget of attempts for this resume
        s.failureMessage = nil
        for i in s.parts.indices where s.parts[i].status == .failed {
            s.parts[i].status = .pending
            s.parts[i].retryCount = 0
        }
        state = s
        lastFailureMessage = nil
        partNextTry.removeAll()
        persist()
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
        if let assetID { DirectUploader.cleanSlices(for: assetID) }
        // Best-effort: tear down the server-side R2 multipart session.
        if Config.useLiveBackend, let assetID, isMultipart {
            Task { [weak self] in try? await self?.api.abortUpload(assetID: assetID) }
        }
        state = nil
        UploadStore.save(nil)
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
        state = nil
        UploadStore.save(nil)
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
            mine.forEach { if $0.state == .suspended { $0.resume() } }
            DispatchQueue.main.async {
                guard let cur = self.state, cur.status == .uploading, cur.assetID == assetID else { return }
                switch mode {
                case .multipart?:
                    let active = Set(mine.compactMap { self.partNumber(from: $0) })
                    self.mutate { st in
                        for i in st.parts.indices where st.parts[i].status != .done {
                            st.parts[i].status = active.contains(st.parts[i].number) ? .inflight : .pending
                        }
                    }
                    self.updateProgress()
                    self.pumpMultipart()
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

    /// Single mode resume decision: complete-only, re-PUT on the same URL, or a
    /// fresh ticket — whichever the persisted state says is left to do.
    private func resumeSingle(expectedAssetID: String) {
        guard let cur = state, cur.status == .uploading, cur.assetID == expectedAssetID else { return }
        if cur.singlePutDone == true {
            completeAndFinish(assetID: expectedAssetID, parts: nil, metadata: buildMetadata(from: cur))
        } else if let put = cur.putURL, Self.putURLIsFresh(cur) {
            launchSingle(putURL: put)
        } else {
            reticketSingle()
        }
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
                st.failureMessage = nil
                for i in st.parts.indices where st.parts[i].status == .failed {
                    st.parts[i].status = .pending
                    st.parts[i].retryCount = 0
                }
            }
            partNextTry.removeAll()
            startOrResume()
        default:
            break
        }
    }

    // MARK: - Ticket

    /// Stable per file + size: a retried ticket request replays server-side
    /// (once the server keys on it) instead of minting another row. Bounded:
    /// the Documents-relative path is hashed, never sent raw. (The content
    /// sha256 is often still computing at ticket time, so the path hash keeps
    /// the key identical across retries of the same upload.)
    private static func ticketIdempotencyKey(for s: State) -> String {
        "ticket:\(DirectUploader.sha256Hex(s.filePath)):\(s.bytesTotal)"
    }

    private func requestTicketAndStart(_ s: State) {
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
                    self.applyTicket(ticket)
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

    private func applyTicket(_ ticket: UploadTicket) {
        // Save the server identifiers even if the user paused mid-request, so a
        // later resume continues the SAME upload session. Only LAUNCH if still
        // uploading.
        guard var s = state else { return }
        let launch = (s.status == .uploading)
        s.assetID = ticket.assetID
        if let key = ticket.storageKey { s.storageKey = key }
        s.mode = ticket.mode.rawValue
        s.retryCount = 0
        s.singlePutDone = nil

        switch ticket.mode {
        case .single:
            guard let putURL = ticket.putURL else {
                // No presigned URL (offline / Mock fallback) → simulate gracefully.
                s.mode = "simulate"; s.putURL = nil; s.putURLIssuedAt = nil
                state = s; persist()
                if launch { runSimulate() }
                return
            }
            s.putURL = putURL
            s.putURLIssuedAt = Date()
            state = s; persist()
            if launch { launchSingle(putURL: putURL) }

        case .multipart:
            let partSize = max(1, ticket.partSize ?? Self.defaultPartSize)
            let count = ticket.partCount ?? Int((s.bytesTotal + partSize - 1) / partSize)
            s.uploadID = ticket.uploadID
            s.partSize = partSize
            s.partCount = count
            s.putURL = nil
            s.putURLIssuedAt = nil
            s.parts = (1...max(count, 1)).map { n in
                let offset = Int64(n - 1) * partSize
                let length = min(partSize, s.bytesTotal - offset)
                return PartState(number: n, offset: offset, length: max(0, length))
            }
            state = s; persist()
            if launch { pumpMultipart() }
        }
    }

    private static let defaultPartSize: Int64 = 64 * 1024 * 1024   // fallback only; server sets the real size

    // MARK: - Single mode

    private static func putURLIsFresh(_ s: State) -> Bool {
        guard let issued = s.putURLIssuedAt else { return false }
        return Date().timeIntervalSince(issued) < putURLReuseWindow
    }

    private func launchSingle(putURL: URL) {
        guard let s = state, s.status == .uploading else { return }
        // The PUT's Content-Type must equal the ticket's declaration (P0 fix).
        let contentType = s.contentType ?? DirectUploader.uploadContentType(for: s.fileURL, kind: "video")
        let task = backgroundSession.uploadTask(with: DirectUploader.putRequest(url: putURL, contentType: contentType),
                                                fromFile: s.fileURL)
        if let assetID = s.assetID { task.taskDescription = "single:\(assetID)" }
        task.resume()
    }

    /// Fresh ticket for single mode (the presigned URL expired or was refused).
    private func reticketSingle() {
        guard var s = state, s.status == .uploading else { return }
        s.assetID = nil
        s.storageKey = nil
        s.putURL = nil
        s.putURLIssuedAt = nil
        s.singlePutDone = nil
        s.mode = "pending"
        state = s
        persist()
        requestTicketAndStart(s)
    }

    private func handleSingleCompletion(task: URLSessionTask, error: Error?) {
        guard let s = state, let assetID = s.assetID,
              // A stale task from a PREVIOUS upload session (background tasks
              // outlive `state` swaps) must never drive the current upload's
              // completion — its task description names a different asset id.
              task.taskDescription == "single:\(assetID)" else { return }
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || !(200..<300).contains(httpStatus) {
            guard s.status == .uploading else { return }   // paused/cancelled → leave resumable
            // 403 = the presigned URL expired or was refused → straight to a new
            // ticket. Anything else (network drop, 5xx) retries the SAME URL while
            // it is still valid, then re-tickets.
            let wantsNewTicket = (httpStatus == 403) || !Self.putURLIsFresh(s)
            guard s.retryCount < 5 else {
                fail(httpStatus > 0 ? "Storage returned status \(httpStatus) while uploading." : nil)
                return
            }
            mutate { $0.retryCount += 1 }
            let attempt = state?.retryCount ?? 1
            let delay = pow(2.0, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let cur = self.state, cur.status == .uploading, cur.assetID == assetID else { return }
                if !wantsNewTicket, let put = cur.putURL, Self.putURLIsFresh(cur) {
                    self.launchSingle(putURL: put)
                } else {
                    self.reticketSingle()
                }
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
                self.revertToPending(numbers)
                if let api = error as? APIError,
                   api.isValidation || api.isNotFound || api.isForbidden || api.isUnauthorized || api.isConflict {
                    // The server refuses this upload session (e.g. 409 "not a
                    // multipart upload" after an abort, 404 asset gone, signed
                    // out) — don't spin on it every 5 s; the user resumes.
                    self.fail(api.localizedDescription, terminal: true)
                } else {
                    self.scheduleMultipartRetry()
                }
            }
            return
        }

        // 2. Snapshot each part's byte range on the main actor (state is main-isolated).
        let (fileURL, specs): (URL?, [PartSpec]) = await MainActor.run {
            guard let s = self.state, s.status == .uploading, s.assetID == assetID else {
                self.revertToPending(numbers); return (nil, [])   // paused/cancelled mid-fetch
            }
            var out: [PartSpec] = []
            for n in numbers {
                guard let url = urls[n],
                      let part = s.parts.first(where: { $0.number == n }) else {
                    self.handlePartRetry(n); continue
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
                self.inFlightBytes[spec.n] = 0
                task.resume()
            }
        }
    }

    private func handlePartCompletion(task: URLSessionTask, error: Error?) {
        guard let assetID = state?.assetID, let n = partNumber(from: task),
              // Ignore stale part tasks from a PREVIOUS upload session — marking
              // the current upload's part "done" with a foreign ETag would
              // corrupt the manifest and fail (or worse, mis-assemble) the file.
              task.taskDescription == "part:\(assetID):\(n)" else { return }
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
            handlePartRetry(n)
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

    private func scheduleMultipartRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.pumpMultipart() }
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
        guard !isCompleting else { return }
        isCompleting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.completeUpload(assetID: assetID, parts: parts, metadata: metadata)
                await MainActor.run {
                    self.isCompleting = false
                    self.markDone(assetID: assetID)
                }
            } catch let err as APIError where err.isAlreadyComplete {
                await MainActor.run {
                    self.isCompleting = false
                    self.markDone(assetID: assetID)
                }
            } catch {
                await MainActor.run {
                    self.isCompleting = false
                    guard self.state?.assetID == assetID else { return }
                    let api = error as? APIError
                    let terminal: Bool
                    if let api, let status = api.status {
                        terminal = (400..<500).contains(status) && status != 429 && status != 408
                    } else {
                        terminal = false
                    }
                    self.fail(error.localizedDescription, terminal: terminal)
                }
            }
        }
    }

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
        lastFailureMessage = nil
        Haptics.success()
        emitCompletion(assetID: assetID, from: s)
        // Consumed (continuation + notification). The `.done` record stays in
        // MEMORY only — observers that hop to the main actor (AppModel's
        // pending-publish handler reads `state?.role`/`assetID`) still see it,
        // Settings shows "Complete" until the next upload replaces it, and a
        // relaunch never resurrects a weeks-old "Complete · 100%" because the
        // on-disk copy is removed here (and `init` drops any legacy `.done`).
        UploadStore.save(nil)
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
    private func fail(_ message: String?, terminal: Bool = false) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastFailureMessage = (text?.isEmpty == false) ? text : nil
        mutate { st in
            st.failureMessage = (text?.isEmpty == false) ? text : nil
            if terminal { st.terminalError = (text?.isEmpty == false) ? text : "The server rejected this upload." }
            st.status = .failed
        }
    }

    // MARK: - Photo batch

    private func runPhotoBatch(listingID: UUID, fileURLs: [URL]) async {
        let requests = fileURLs.map { url in
            PhotoUploadRequest(filename: url.lastPathComponent,
                               bytes: FileStore.fileSize(url),
                               sha256: nil,
                               contentType: DirectUploader.mimeType(for: url))
        }
        let tickets: [PhotoTicket]
        do {
            tickets = try await api.requestPhotoBatch(listingID: listingID, files: requests)
        } catch {
            await MainActor.run {
                self.photoProgress?.failed = fileURLs.count
                self.lastFailureMessage = error.localizedDescription
            }
            return
        }
        let byIndex = Dictionary(uniqueKeysWithValues: fileURLs.enumerated().map { ($0.offset, $0.element) })

        var completedIDs: [String] = []
        await withTaskGroup(of: (String?, Bool).self) { group in
            var iterator = tickets.makeIterator()
            func addNext() {
                guard let ticket = iterator.next(), let fileURL = byIndex[ticket.index] else { return }
                group.addTask { [weak self] in
                    guard let self else { return (nil, false) }
                    let ok = await self.uploadOnePhoto(ticket: ticket, fileURL: fileURL)
                    return (ok ? ticket.assetID : nil, ok)
                }
            }
            for _ in 0..<min(maxConcurrent, tickets.count) { addNext() }
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

    /// Single PUT for one photo (streams from file → memory-safe), then per-file
    /// complete. Up to 5 attempts with exponential backoff; a 403 (expired
    /// 15-min staging URL) or a terminal `/complete` rejection stops early.
    private func uploadOnePhoto(ticket: PhotoTicket, fileURL: URL) async -> Bool {
        var attempt = 0
        while attempt < 5 {
            do {
                let request = DirectUploader.photoPutRequest(url: ticket.putURL,
                                                             contentType: DirectUploader.mimeType(for: fileURL))
                let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 403 { return false }   // presigned URL expired — a retry can't fix it
                if (200..<300).contains(status) {
                    var meta = UploadMetadata()
                    meta.bytes = FileStore.fileSize(fileURL)
                    do {
                        try await api.completeUpload(assetID: ticket.assetID, parts: nil, metadata: meta)
                    } catch let err as APIError where err.isAlreadyComplete {
                        // fine — already accepted
                    } catch let err as APIError where err.isValidation || err.isNotFound || err.isForbidden {
                        return false   // rejected: retrying the same bytes won't help
                    }
                    return true
                }
            } catch {
                // fall through to backoff/retry
            }
            attempt += 1
            let delay = pow(2.0, Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return false
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

    private func persist() {
        UploadStore.save(state)
    }
}

// MARK: - Codable (tolerant: older persisted state decodes with defaults)
extension UploadManager.State {
    enum CodingKeys: String, CodingKey {
        case id, filePath, bytesTotal, bytesSent, status, mode, assetID, storageKey,
             uploadID, partSize, partCount, parts, sha256, retryCount, listingID, role, metadata,
             contentType, listingLocalID, putURL, putURLIssuedAt, singlePutDone,
             failureMessage, terminalError
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
    }
}

// Per-part tolerant decode: number/offset/length are REQUIRED (a part without
// its byte range can't be re-sliced and must fail the load → fresh upload), but
// status/etag/retryCount tolerate missing keys and unknown raw values so a
// version change can't discard hours of already-uploaded parts.
extension UploadManager.PartState {
    enum CodingKeys: String, CodingKey { case number, offset, length, status, etag, retryCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number     = try c.decode(Int.self, forKey: .number)
        offset     = try c.decode(Int64.self, forKey: .offset)
        length     = try c.decode(Int64.self, forKey: .length)
        let statusRaw = try c.decodeIfPresent(String.self, forKey: .status)
        status     = statusRaw.flatMap(UploadManager.PartStatus.init(rawValue:)) ?? .pending
        etag       = try c.decodeIfPresent(String.self, forKey: .etag)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
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
                guard desc == "part:\(assetID):\(n)" else { return }
                self.inFlightBytes[n] = totalBytesSent
                self.updateProgress()
            } else if desc.hasPrefix("single:") {
                guard desc == "single:\(assetID)", var s = self.state else { return }
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
