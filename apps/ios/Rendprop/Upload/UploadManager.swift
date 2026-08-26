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
///  • **single** — small video (≤ 64 MB): one presigned PUT.
///
/// When `useLiveBackend` is off it uses **.simulate** (real disk reads, realistic
/// progress, fully offline) so the app runs end-to-end with no backend.
///
/// Photos go through `beginPhotoBatch` → `/uploads/batch` with bounded-concurrency
/// single PUTs.
final class UploadManager: NSObject, ObservableObject {
    static let shared = UploadManager()

    /// Posted (main thread) when a video upload finishes; `userInfo` carries
    /// `"assetID": String` (the SERVER capture_assets id) and, when known,
    /// `"listingID": UUID`. Lets the render step be sequenced AFTER the upload.
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

        var fractionComplete: Double {
            bytesTotal > 0 ? Double(bytesSent) / Double(bytesTotal) : 0
        }

        var fileURL: URL {
            FileStore.documents.appendingPathComponent(filePath)
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

    /// Optional completion callback (server assetID). NotificationCenter also
    /// fires `didCompleteNotification`. Consumers must avoid retaining `self`.
    var onUploadComplete: ((String) -> Void)?

    /// Optional terminal-failure callback for the async `upload(...)` convenience
    /// — fired when the active upload transitions to `.failed` or is cancelled.
    /// Nil for the fire-and-forget `begin(...)` capture path.
    var onUploadFailed: (() -> Void)?

    /// Errors thrown by the async `upload(...)` convenience.
    enum UploadError: LocalizedError {
        case busy, failed, missingFile
        var errorDescription: String? {
            switch self {
            case .busy:        return "Another upload is already in progress."
            case .failed:      return "The upload failed. Check your connection and try again."
            case .missingFile: return "The file to upload is missing or empty."
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
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasSatisfied = self.pathIsSatisfied
                self.pathIsExpensive = path.isExpensive
                self.pathIsSatisfied = (path.status == .satisfied)
                if !wasSatisfied && self.pathIsSatisfied {
                    self.onNetworkRegained()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.rendprop.netpath"))

        // Resume anything persisted from a previous launch.
        if let saved = UploadStore.load() {
            state = saved
            if saved.status == .uploading {
                resume()
            } else if saved.status == .queued {
                // .queued means the upload was awaiting the cellular-data
                // confirmation when the app died. Re-raise the prompt instead of
                // silently starting a multi-GB upload on cellular — the UI calls
                // confirmCellularAndStart() (or cancel()) exactly as before.
                pendingCellularConfirmation = true
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
    /// renders bucket for an app-published tour, contract §2.7).
    func begin(fileURL: URL,
               listingID: UUID? = nil,
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
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        isRequestingTicket = false

        var newState = State(filePath: FileStore.relativePath(for: fileURL),
                             bytesTotal: bytes,
                             mode: Config.useLiveBackend ? "pending" : "simulate")
        newState.listingID = listingID
        newState.role = role
        var meta = metadata
        if meta.bytes == nil { meta.bytes = bytes }
        newState.metadata = meta
        newState.status = needsWifi ? .queued : .uploading
        state = newState
        persist()

        // Streaming sha256 (optional metadata) computed off-main; large-file safe.
        computeHashInBackground(fileURL: fileURL)

        guard newState.status == .uploading else { return }
        startOrResume()
    }

    /// Async convenience: upload one file and resolve with the SERVER assetID
    /// when the single/multipart engine finishes. Drives the same `begin(...)`
    /// engine and completion hooks, wrapped in a continuation, so the publish
    /// step can `await` the upload (contract §4/§5). Ensures a single active
    /// upload; throws on failure or cancel.
    ///
    /// `cellularApproved` is forced true here: the publish upload is a
    /// foreground, user-initiated action (the user already chose to create the
    /// tour), and hanging on a Wi-Fi prompt would stall the awaited publish.
    @MainActor
    func upload(fileURL: URL, listingID: UUID, role: String,
                metadata: UploadMetadata) async throws -> String {
        // One active upload at a time — don't clobber an in-flight capture.
        if let s = state, s.status == .uploading || s.status == .queued || s.status == .paused {
            throw UploadError.busy
        }
        guard FileStore.fileSize(fileURL) > 0 else { throw UploadError.missingFile }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var settled = false
            func finish(_ result: Result<String, Error>) {
                guard !settled else { return }
                settled = true
                self.onUploadComplete = nil
                self.onUploadFailed = nil
                cont.resume(with: result)
            }
            self.onUploadComplete = { assetID in finish(.success(assetID)) }
            self.onUploadFailed = { finish(.failure(UploadError.failed)) }
            self.begin(fileURL: fileURL, listingID: listingID, role: role,
                       metadata: metadata, cellularApproved: true)
        }
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

    func pause() {
        simulateTimer?.invalidate()
        backgroundSession.getAllTasks { $0.forEach { $0.suspend() } }
        mutate { $0.status = .paused }
    }

    func resume() {
        guard var s = state, s.status != .done else { return }
        s.status = .uploading
        state = s
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
        if let assetID { DirectUploader.cleanSlices(for: assetID) }
        // Best-effort: tear down the server-side R2 multipart session.
        if Config.useLiveBackend, let assetID, isMultipart {
            Task { [weak self] in try? await self?.api.abortUpload(assetID: assetID) }
        }
        state = nil
        UploadStore.save(nil)
        // Resolve any awaiting upload() as a failure (cancel is a failed publish).
        onUploadFailed?()
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
                guard let cur = self.state, cur.status == .uploading else { return }
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
                    if mine.isEmpty { self.requestTicketAndStart(cur) }
                    // else the running single task will complete via the delegate.
                case .none:
                    self.requestTicketAndStart(cur)
                }
            }
        }
    }

    private func onNetworkRegained() {
        guard let s = state else { return }
        switch s.status {
        case .uploading:
            startOrResume()
        case .failed:
            // Network came back — clear per-part failures and retry only what's missing.
            mutate { st in
                st.status = .uploading
                st.retryCount = 0
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

    private func requestTicketAndStart(_ s: State) {
        guard !isRequestingTicket else { return }
        isRequestingTicket = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await self.api.requestUpload(
                    filename: s.fileURL.lastPathComponent, bytes: s.bytesTotal,
                    listingID: s.listingID, sha256: s.sha256, kind: "video", role: s.role)
                await MainActor.run {
                    self.isRequestingTicket = false
                    self.applyTicket(ticket)
                }
            } catch {
                await MainActor.run {
                    self.isRequestingTicket = false
                    self.mutate { $0.status = .failed }
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

        switch ticket.mode {
        case .single:
            guard let putURL = ticket.putURL else {
                // No presigned URL (offline / Mock fallback) → simulate gracefully.
                s.mode = "simulate"; state = s; persist()
                if launch { runSimulate() }
                return
            }
            state = s; persist()
            if launch { launchSingle(putURL: putURL) }

        case .multipart:
            let partSize = max(1, ticket.partSize ?? Self.defaultPartSize)
            let count = ticket.partCount ?? Int((s.bytesTotal + partSize - 1) / partSize)
            s.uploadID = ticket.uploadID
            s.partSize = partSize
            s.partCount = count
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

    private func launchSingle(putURL: URL) {
        guard let s = state else { return }
        let task = backgroundSession.uploadTask(with: DirectUploader.putRequest(url: putURL),
                                                fromFile: s.fileURL)
        if let assetID = s.assetID { task.taskDescription = "single:\(assetID)" }
        task.resume()
    }

    private func handleSingleCompletion(task: URLSessionTask, error: Error?) {
        guard let s = state, let assetID = s.assetID,
              // A stale task from a PREVIOUS upload session (background tasks
              // outlive `state` swaps) must never drive the current upload's
              // completion — its task description names a different asset id.
              task.taskDescription == "single:\(assetID)" else { return }
        if let error {
            _ = error
            guard s.status == .uploading else { return }   // paused/cancelled → leave resumable
            guard s.retryCount < 5 else { mutate { $0.status = .failed }; return }
            mutate { $0.retryCount += 1 }
            let attempt = state?.retryCount ?? 1
            let delay = pow(2.0, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let cur = self.state, cur.status == .uploading else { return }
                self.requestTicketAndStart(cur)   // single PUT can't resume a partial → fresh ticket
            }
            return
        }
        // Success — single PUT needs no ETag manifest.
        let meta = buildMetadata(from: s)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.completeUpload(assetID: assetID, parts: nil, metadata: meta)
                await MainActor.run { self.markDone(assetID: assetID) }
            } catch {
                await MainActor.run { self.mutate { $0.status = .failed } }  // /complete retried on resume
            }
        }
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
                mutate { $0.status = .failed }
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
                self.scheduleMultipartRetry()
            }
            return
        }

        // 2. Snapshot each part's byte range on the main actor (state is main-isolated).
        let (fileURL, specs): (URL?, [PartSpec]) = await MainActor.run {
            guard let s = self.state, s.status == .uploading else {
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
                guard let s = self.state, s.status == .uploading,
                      s.parts.first(where: { $0.number == spec.n })?.status == .inflight else {
                    DirectUploader.removeSlice(for: assetID, part: spec.n)
                    self.revertToPending([spec.n])
                    return
                }
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

        if let error {
            _ = error
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
        let meta = buildMetadata(from: s)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.completeUpload(assetID: assetID, parts: manifest, metadata: meta)
                await MainActor.run { self.markDone(assetID: assetID) }
            } catch {
                await MainActor.run { self.mutate { $0.status = .failed } }  // retried on resume
            }
        }
    }

    // MARK: - Completion

    private func markDone(assetID: String) {
        mutate { st in
            st.status = .done
            st.bytesSent = st.bytesTotal
        }
        DirectUploader.cleanSlices(for: assetID)
        inFlightBytes.removeAll()
        partNextTry.removeAll()
        Haptics.success()
        emitCompletion(assetID: assetID)
    }

    private func emitCompletion(assetID: String) {
        let listingID = state?.listingID
        onUploadComplete?(assetID)
        var info: [String: Any] = ["assetID": assetID]
        if let listingID { info["listingID"] = listingID }
        NotificationCenter.default.post(name: Self.didCompleteNotification, object: self, userInfo: info)
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
            await MainActor.run { self.photoProgress?.failed = fileURLs.count }
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
    /// complete. Up to 5 attempts with exponential backoff.
    private func uploadOnePhoto(ticket: PhotoTicket, fileURL: URL) async -> Bool {
        var attempt = 0
        while attempt < 5 {
            do {
                let request = DirectUploader.photoPutRequest(url: ticket.putURL,
                                                             contentType: DirectUploader.mimeType(for: fileURL))
                let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    var meta = UploadMetadata()
                    meta.bytes = FileStore.fileSize(fileURL)
                    try await api.completeUpload(assetID: ticket.assetID, parts: nil, metadata: meta)
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
            mutate { $0.status = .failed }
            return
        }
        try? handle.seek(toOffset: UInt64(s.bytesSent))

        // Compute checksum once, off-main, while "uploading".
        if s.sha256 == nil { computeHashInBackground(fileURL: s.fileURL) }

        let chunk = 4_000_000  // ~4MB per tick ≈ realistic Wi-Fi pace
        simulateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, var s = self.state, s.status == .uploading else {
                timer.invalidate()
                return
            }
            let data = autoreleasepool { handle.readData(ofLength: chunk) }
            if data.isEmpty {
                timer.invalidate()
                try? handle.close()
                s.bytesSent = s.bytesTotal
                s.status = .done
                self.state = s
                self.persist()
                Haptics.success()
                return
            }
            s.bytesSent = min(s.bytesTotal, s.bytesSent + Int64(data.count))
            self.state = s
            // Persist every ~2% so a kill mid-upload resumes close to where it died.
            if s.bytesSent % Int64(chunk * 12) < Int64(chunk) { self.persist() }
        }
    }

    // MARK: - Helpers

    private func computeHashInBackground(fileURL: URL) {
        guard state?.sha256 == nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let digest = DirectUploader.sha256(of: fileURL) else { return }
            DispatchQueue.main.async {
                guard let self, var s = self.state, s.sha256 == nil else { return }
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
        guard var s = state else { return }
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
        if !wasFailed, s.status == .failed { onUploadFailed?() }
    }

    private func persist() {
        UploadStore.save(state)
    }
}

// MARK: - Codable (tolerant: older persisted state decodes with defaults)
extension UploadManager.State {
    enum CodingKeys: String, CodingKey {
        case id, filePath, bytesTotal, bytesSent, status, mode, assetID, storageKey,
             uploadID, partSize, partCount, parts, sha256, retryCount, listingID, role, metadata
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
