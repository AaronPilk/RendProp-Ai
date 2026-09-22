import Foundation
import UIKit
import Combine
import CryptoKit

/// One OS-owned background session survives leaving the spatial screen. Only
/// JPEG bytes go through it; the small authenticated state transitions are
/// retried from the durable journal when iOS wakes us or the app next opens.
///
/// Journal discipline: a receipt that must outlive the process (a ticket
/// handed to URLSession, an enqueue, a pause) is written synchronously; the
/// many small per-frame transitions between receipts are coalesced into one
/// write a few hundred milliseconds later, and flushed before any server call
/// and whenever the app leaves the foreground. Finished rooms are pruned, so
/// the journal stays small and the room cap counts live rooms only.
@MainActor
final class SpatialUploadCoordinator: ObservableObject {
    static let sessionIdentifier = "com.rendprop.spatial.upload.v1"
    static let shared = SpatialUploadCoordinator()
    @Published private(set) var records: [SpatialUploadRecord] = []
    @Published private(set) var recoveryError: String?
    var finishBackgroundEvents: (() -> Void)?
    private let api: APIClient = Config.makeAPIClient()
    private let delegate = SpatialTransferDelegate()
    private var session: URLSession!
    private var active = Set<String>()
    private var preparingTransfers = Set<String>()
    private var starting = Set<UUID>()
    private var cleaning = Set<UUID>()
    private var subscriptions = Set<AnyCancellable>()
    private var reconnecting = false
    private var journalURL: URL?
    private var journalDirty = false
    private var journalFlush: Task<Void, Never>?
    private static let journalDebounceNanoseconds: UInt64 = 350_000_000
    /// A job absent from one refresh may simply not exist yet (the list was
    /// fetched a moment before `/spatial` answered). Two sightings, spaced
    /// apart, are needed before a record is dropped as server-orphaned.
    private var missingSightings: [UUID: (count: Int, at: Date)] = [:]
    private var backgroundDrain: UIBackgroundTaskIdentifier = .invalid
    private var drainTask: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [SpatialUploadPreferences.wifiOnlyKey: SpatialUploadPreferences.wifiOnlyDefault])
        do {
            let fm = FileManager.default
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SpatialUploads", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var excluded = dir
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let file = dir.appendingPathComponent("journal-v1.json")
            if fm.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, let size = values.fileSize, size <= 4 * 1024 * 1024 else {
                    throw SpatialClientError.unreadableJournal
                }
                let decoded = try JSONDecoder().decode([SpatialUploadRecord].self, from: Data(contentsOf: file))
                guard decoded.count <= SpatialUploadRecord.liveRoomLimit, Set(decoded.map(\.id)).count == decoded.count else {
                    throw SpatialClientError.unreadableJournal
                }
                records = try decoded.map { try $0.validated() }
            }
            journalURL = file
        } catch { recoveryError = SpatialClientError.unreadableJournal.localizedDescription }

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.reconnect() } }.store(in: &subscriptions)
        // Whatever was coalesced must reach disk before iOS can suspend or kill us.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.flushJournalQuietly() } }.store(in: &subscriptions)
        }
        AuthStore.shared.$userID.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }.store(in: &subscriptions)
        reconnect()
    }

    private var ownerID: String? {
        // Read the live credential subject, not a remembered display identity.
        // Anonymous JWTs work exactly like identified JWTs for capture/upload.
        guard let token = AuthStore.currentAccessToken else { return nil }
        return AuthStore.jwtSubject(token)
    }
    private func owns(_ record: SpatialUploadRecord) -> Bool { ownerID == record.ownerID }
    private func assertOwner(_ id: UUID) throws -> Int {
        guard let i = records.firstIndex(where: { $0.id == id }), owns(records[i]) else { throw SpatialClientError.accountChanged }
        guard recoveryError == nil else { throw SpatialClientError.unreadableJournal }
        guard !records[i].isUserPaused else { throw SpatialClientError.uploadPaused }
        return i
    }

    // MARK: Journal

    /// Coalesced write. Marks the journal dirty and schedules one write a few
    /// hundred milliseconds out; several frame transitions share it.
    private func persist() throws {
        guard journalURL != nil, recoveryError == nil else { throw SpatialClientError.unreadableJournal }
        journalDirty = true
        guard journalFlush == nil else { return }
        journalFlush = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.journalDebounceNanoseconds) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.journalFlush = nil
            if self.journalDirty { do { try self.persistNow() } catch { } }
        }
    }
    /// Synchronous write for receipts that must outlive the process.
    private func persistNow() throws {
        journalFlush?.cancel()
        journalFlush = nil
        guard let journalURL, recoveryError == nil else { throw SpatialClientError.unreadableJournal }
        do {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 4 * 1024 * 1024 else { throw SpatialClientError.unreadableJournal }
            try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            journalDirty = false
        } catch {
            recoveryError = "Upload progress could not be saved. Your capture is preserved; uploading has paused."
            throw error
        }
    }
    /// Flush before a server call: the state the call is about to change must
    /// already be on disk, otherwise a crash mid-call replays from stale state.
    private func flushJournal() throws {
        if journalDirty { try persistNow() }
    }
    private func flushJournalQuietly() {
        do { try flushJournal() } catch { }
    }

    // MARK: Records

    func enqueue(capture: URL, listingLocalID: UUID, listingID: UUID, roomLabel: String, allowCellular: Bool) async throws {
        guard let ownerID, UUID(uuidString: ownerID) != nil else { throw SpatialClientError.accountChanged }
        guard recoveryError == nil else { throw SpatialClientError.unreadableJournal }
        pruneFinishedRecords()
        guard records.count < SpatialUploadRecord.liveRoomLimit else { throw SpatialClientError.tooManyRooms }
        let label = roomLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 80, let captureID = UUID(uuidString: capture.lastPathComponent) else {
            throw SpatialClientError.invalidCapture
        }
        if let existing = records.first(where: { $0.ownerID == ownerID && $0.captureID == captureID }) {
            // A live record for this capture keeps going; a record that can
            // never finish is replaced by a fresh attempt instead of being
            // "resumed" into the same dead end.
            guard existing.isTerminalFailure else { reconnect(); return }
            records.removeAll { $0.id == existing.id }
            try persist()
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            let archive = try CaptureArchive.local()
            let validated = try archive.validateForExport(id: captureID.uuidString)
            guard validated.standardizedFileURL == capture.standardizedFileURL else { throw SpatialClientError.invalidCapture }
            let manifest = try archive.manifest(id: captureID.uuidString)
            var frames: [SpatialUploadRecord.Frame] = []
            var metadataBytes = 0
            for sidecar in manifest.frames {
                let bytes = try NativeRasterWriter.boundedJSONData(at: validated.appendingPathComponent(sidecar), maximumBytes: 1024 * 1024)
                metadataBytes += try JSONEncoder().encode(JSONDecoder().decode(SpatialJSON.self, from: bytes)).count
                guard metadataBytes <= 16 * 1024 * 1024 else { throw SpatialClientError.invalidCapture }
                let frame = try JSONDecoder().decode(FrameRecord.self, from: bytes)
                let jpeg = try Data(contentsOf: validated.appendingPathComponent(frame.image), options: .mappedIfSafe)
                let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
                frames.append(.init(imagePath: frame.image, sidecarPath: sidecar, bytes: Int64(jpeg.count), sha256: hash))
            }
            return frames
        }.value
        guard self.ownerID == ownerID else { throw SpatialClientError.accountChanged }
        guard records.count < SpatialUploadRecord.liveRoomLimit else { throw SpatialClientError.tooManyRooms }
        let record = try SpatialUploadRecord(id: UUID(), ownerID: ownerID, listingLocalID: listingLocalID,
            listingID: listingID, captureID: captureID, roomLabel: label, allowCellular: allowCellular, frames: prepared).validated()
        records.append(record)
        try persistNow() // A network operation is never allowed before this receipt.
        pump()
    }

    func retry(_ id: UUID) {
        guard let i = try? assertOwner(id), !records[i].isTerminalFailure else { return }
        records[i].failure = nil
        records[i].serviceUnavailable = nil
        // Reconciliation budget resets per owner tap; the reissue count does
        // not, so a retired idempotency key is never reused.
        for index in records[i].frames.indices { records[i].frames[index].reconciliations = 0 }
        do { try persistNow(); reconnect() } catch { }
    }
    /// Drop a record the owner has given up on. Never touches the saved capture.
    func forget(_ id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), owns(records[i]) else { return }
        records.remove(at: i)
        do { try persistNow() } catch { }
    }
    func records(for listingID: UUID) -> [SpatialUploadRecord] {
        records.filter { $0.listingLocalID == listingID && owns($0) && !$0.queued }
    }

    func pause(jobID: UUID) throws {
        guard let i = records.firstIndex(where: { $0.jobID == jobID && owns($0) }) else { return }
        records[i].pausedByUser = true
        records[i].failure = SpatialClientError.uploadPaused.localizedDescription
        let prefix = records[i].taskPrefix
        try persistNow() // Stop durable scheduling before requesting cloud cancel.
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(prefix) == true { task.cancel() }
        }
    }
    func resume(jobID: UUID) throws {
        guard let i = records.firstIndex(where: { $0.jobID == jobID && owns($0) }) else { return }
        records[i].pausedByUser = false
        records[i].failure = nil
        records[i].serviceUnavailable = nil
        records[i].queued = false
        for index in records[i].frames.indices { records[i].frames[index].reconciliations = 0 }
        try persistNow()
        reconnect()
    }

    /// The screen already polls the listing's jobs; this is how records learn
    /// that the server took their room (free the photos, forget the record)
    /// or dropped it. The coordinator never polls on its own.
    func observeServerJobs(_ jobs: [SpatialJob], listingID: UUID) {
        var views: [UUID: SpatialUploadRecord.ServerView] = [:]
        let now = Date()
        for record in records where owns(record) && record.listingID == listingID {
            guard let jobID = record.jobID else { continue }
            if let job = jobs.first(where: { $0.id == jobID }) {
                missingSightings[record.id] = nil
                views[jobID] = .job(job)
                continue
            }
            // Count a sighting only when the previous one is at least five
            // seconds old, so two quick Refresh taps cannot outrun `/spatial`.
            let previous = missingSightings[record.id]
            var count = previous?.count ?? 0
            let newSighting = previous.map { now.timeIntervalSince($0.at) >= 5 } ?? true
            if newSighting {
                count += 1
                missingSightings[record.id] = (count: count, at: now)
            }
            views[jobID] = count >= 2 ? .missing : .unknown
        }
        pruneFinishedRecords(server: views)
    }

    /// Drop records the phone has nothing left to do for, so the cap counts
    /// live rooms and the journal stops growing. Photos are released only for
    /// rooms the server has fully taken (see `SpatialUploadRecord.retention`).
    private func pruneFinishedRecords(server: [UUID: SpatialUploadRecord.ServerView] = [:]) {
        guard recoveryError == nil else { return }
        var changed = false
        for record in records {
            let view = (owns(record) ? record.jobID.flatMap { server[$0] } : nil) ?? .unknown
            switch record.retention(captureExists: captureExists(record), server: view) {
            case .keep:
                continue
            case .forget:
                records.removeAll { $0.id == record.id }
                missingSightings[record.id] = nil
                changed = true
            case .cleanUpAndForget:
                releaseLocalCapture(record)
            }
        }
        if changed { do { try persist() } catch { } }
    }
    private func captureExists(_ record: SpatialUploadRecord) -> Bool {
        guard let root = try? CaptureArchive.local().captureURL(id: record.captureID.uuidString) else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
    }
    /// Free the room's photos and sidecars now that the server holds every
    /// frame and has moved the job past uploading; then forget the record.
    /// Never called on the way in, and a failed cleanup keeps the record so
    /// the next reconnect tries again.
    private func releaseLocalCapture(_ record: SpatialUploadRecord) {
        guard record.isFullyConfirmed, !cleaning.contains(record.id) else { return }
        cleaning.insert(record.id)
        let recordID = record.id
        let captureID = record.captureID
        Task { @MainActor [weak self] in
            let released = await Task.detached(priority: .utility) { () -> Bool in
                do { try Self.releaseCaptureFiles(captureID: captureID); return true } catch { return false }
            }.value
            guard let self else { return }
            self.cleaning.remove(recordID)
            guard released else { return }
            self.records.removeAll { $0.id == recordID }
            self.missingSightings[recordID] = nil
            do { try self.persist() } catch { }
        }
    }
    private nonisolated static func releaseCaptureFiles(captureID: UUID) throws {
        let fm = FileManager.default
        let archive = try CaptureArchive.local()
        let root = archive.root.appendingPathComponent(captureID.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return } // Already gone: nothing to free.
        let verified = try archive.captureURL(id: captureID.uuidString) // Refuses symlinks and odd ids.
        for name in ["images", "frames"] {
            let dir = verified.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        }
        // The small manifest stays: the saved-captures list keeps the room's
        // date and frame count, and its detail says where the photos went.
        let manifestURL = verified.appendingPathComponent("manifest.json")
        guard var manifest = try? JSONDecoder().decode(CaptureManifest.self,
            from: NativeRasterWriter.boundedJSONData(at: manifestURL, maximumBytes: NativeRasterWriter.maximumManifestBytes)) else { return }
        manifest.status_detail = "Uploaded for private 3D generation. The photos were released from this phone to free space; the room lives in your 3D walkthrough."
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
    }

    func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        session.getAllTasks { tasks in
            Task { @MainActor in
                self.reconnecting = false
                self.pruneFinishedRecords()
                for task in tasks {
                    guard task.state != .completed && task.state != .canceling else { continue }
                    guard let key = task.taskDescription, let parsed = Self.parse(key),
                          let record = self.records.first(where: { $0.id == parsed.0 }), self.owns(record), !record.isUserPaused,
                          record.frames.indices.contains(parsed.1) else { task.cancel(); continue }
                    self.active.insert(key)
                    if task.state == .suspended { task.resume() }
                }
                self.pump()
            }
        }
    }

    private func pump() {
        guard recoveryError == nil, !reconnecting else { return }
        for record in records where owns(record) && !record.queued && !record.isUserPaused && record.failure == nil {
            if record.jobID == nil || record.confirmedCount == record.frames.count {
                guard !starting.contains(record.id) else { continue }
                starting.insert(record.id)
                Task { await self.advanceJob(record.id) }
                continue
            }
            for index in record.frames.indices where record.frames[index].phase != .attached {
                guard active.count < 3 else { return }
                let key = record.taskPrefix + String(index)
                guard !active.contains(key) else { continue }
                active.insert(key)
                Task { await self.advanceFrame(record.id, index: index, key: key) }
            }
        }
    }

    private func advanceJob(_ id: UUID) async {
        defer { starting.remove(id); pump() }
        do {
            var i = try assertOwner(id)
            let record = records[i]
            try flushJournal()
            if let jobID = record.jobID {
                let job = try await api.startSpatialJob(id: jobID)
                i = try assertOwner(id)
                guard job.id == jobID, job.listingID == record.listingID,
                      [.queued, .processing, .review, .ready].contains(job.status) else {
                    throw SpatialClientError.invalidResponse
                }
                records[i].queued = true
                try persist()
                // The server now owns the whole room; the local copy is redundant.
                releaseLocalCapture(records[i])
            } else {
                let root = try CaptureArchive.local().captureURL(id: record.captureID.uuidString)
                let manifest = try JSONDecoder().decode(SpatialJSON.self, from:
                    NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent("manifest.json"), maximumBytes: 64 * 1024))
                let request = SpatialCreateRequest(listingID: record.listingID, roomLabel: record.roomLabel,
                    captureID: record.captureID, manifest: manifest)
                let job = try await api.createSpatialJob(request, operationID: record.id)
                i = try assertOwner(id)
                guard job.listingID == record.listingID else { throw SpatialClientError.invalidResponse }
                records[i].jobID = job.id
                try persistNow()
            }
        } catch { fail(id, error) }
    }

    private func advanceFrame(_ id: UUID, index: Int, key: String) async {
        preparingTransfers.insert(key)
        var handedToSystem = false
        defer { preparingTransfers.remove(key); if !handedToSystem { active.remove(key); pump() } }
        do {
            var i = try assertOwner(id)
            let record = records[i]
            guard let jobID = record.jobID, record.frames.indices.contains(index) else { throw SpatialClientError.invalidResponse }
            var frame = record.frames[index]
            // An OS/process interruption can lose a PUT's client receipt. Ask
            // /complete first; replaying a spent physical-write capability is
            // neither safe nor evidence that the previous bytes failed to land.
            // A ticket whose PUT capability has aged out (≤ 1 h on the server,
            // common when uploads wait for Wi-Fi) takes the same road: renew
            // this asset before any transfer, never PUT with a stale signature.
            if let ticketID = frame.ticketID, frame.phase == .sending || frame.phase == .uploaded || record.needsRenewal(index: index) {
                guard frame.reconciliations < 3 else { throw SpatialClientError.uploadUncertain }
                try flushJournal()
                let outcome = try await SpatialUploadRecovery.reconcile(ticketID: ticketID, probe: {
                    _ = try self.assertOwner(id)
                    do {
                        try await self.api.completeUpload(assetID: ticketID, parts: nil,
                            metadata: UploadMetadata(bytes: frame.bytes, sha256: frame.sha256))
                        return .complete
                    } catch {
                        // Only server-declared pending/uncertain receipts enter
                        // renewal. A 401, offline error or forbidden workspace
                        // is not permission to schedule another transfer.
                        guard UploadRecovery.mayReconcile(error, incompleteMultipart: false) else { throw error }
                        return .needsReconciliation
                    }
                }, renew: { originalID in
                    _ = try self.assertOwner(id)
                    let ticket = try await self.api.renewUpload(assetID: originalID)
                    _ = try self.assertOwner(id)
                    return ticket
                })
                i = try assertOwner(id)
                switch outcome {
                case .renew(let url):
                    records[i].frames[index].reconciliations += 1
                    records[i].frames[index].putURL = url
                    records[i].frames[index].phase = .ticketed
                    try persist()
                    return // pump schedules this SAME receipt, never a new ticket.
                case .expired:
                    // The server retired this reservation for good (48 h, or
                    // aborted). Renewing it again can never work, so the frame
                    // buys a fresh ticket under a new key — a bounded number
                    // of times — instead of failing into a Resume loop.
                    guard records[i].reissueTicket(index: index) else { throw SpatialClientError.ticketRetired }
                    try persistNow()
                    return // pump requests a new ticket for this frame.
                case .complete:
                    break
                }
                records[i].frames[index].phase = .uploaded
                records[i].frames[index].putURL = nil
                try persistNow()
                let root = try CaptureArchive.local().captureURL(id: record.captureID.uuidString)
                let sidecar = try NativeRasterWriter.boundedJSONData(at: root.appendingPathComponent(frame.sidecarPath), maximumBytes: 1024 * 1024)
                let input = SpatialInput(ticketID: ticketID, relativePath: frame.imagePath,
                                         frame: try JSONDecoder().decode(SpatialJSON.self, from: sidecar))
                let job = try await api.attachSpatialInputs(jobID: jobID, files: [input])
                i = try assertOwner(id)
                guard job.id == jobID, job.listingID == record.listingID else { throw SpatialClientError.invalidResponse }
                records[i].frames[index].phase = .attached
                records[i].frames[index].taskID = nil
                try persist()
                return
            }
            if frame.ticketID == nil {
                try flushJournal()
                let ticket: UploadTicket
                do {
                    ticket = try await api.requestUpload(filename: "spatial-\(record.captureID.uuidString)-\(index).jpg",
                        bytes: frame.bytes, listingID: record.listingID, sha256: frame.sha256, kind: "photo", role: "capture",
                        contentType: "image/jpeg", idempotencyKey: record.ticketKey(index: index))
                } catch {
                    // A replayed key can still point at a reservation the
                    // server's sweep has not retired yet. Move to the next key.
                    guard SpatialUploadRecovery.isReplayConflict(error) else { throw error }
                    i = try assertOwner(id)
                    guard records[i].reissueTicket(index: index) else { throw SpatialClientError.ticketRetired }
                    try persistNow()
                    return
                }
                i = try assertOwner(id)
                // The first ticket is held to the same standard as a renewal:
                // a v2 receipt with one bounded, signed, expiring capability.
                guard ticket.mode == .single, ticket.transportVersion == 2, ticket.uploaded != true,
                      let putURL = ticket.putURL, UploadRecovery.isBoundedCapability(putURL) else {
                    throw SpatialClientError.invalidResponse
                }
                records[i].frames[index].ticketID = ticket.assetID
                records[i].frames[index].putURL = putURL
                records[i].frames[index].phase = .ticketed
                try persist()
                frame = records[i].frames[index]
            }
            guard let putURL = frame.putURL else { throw SpatialClientError.invalidResponse }
            let root = try CaptureArchive.local().captureURL(id: record.captureID.uuidString)
            let file = root.appendingPathComponent(frame.imagePath)
            var request = URLRequest(url: putURL)
            request.httpMethod = "PUT"
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue(String(frame.bytes), forHTTPHeaderField: "Content-Length")
            request.allowsCellularAccess = record.allowCellular
            request.allowsExpensiveNetworkAccess = record.allowCellular
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = key
            records[i].frames[index].taskID = task.taskIdentifier
            records[i].frames[index].phase = .sending
            do { try persistNow() } catch { task.cancel(); throw error } // The OS task must be on disk before it runs.
            handedToSystem = true
            task.resume()
        } catch { fail(id, error) }
    }

    fileprivate func transferFinished(key: String?, taskID: Int, status: Int?, failed: Bool) {
        guard let key, let (id, index) = Self.parse(key) else { return }
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].frames.indices.contains(index) else { return }
        let success = !failed && status.map { (200...299).contains($0) } == true
        guard records[i].acceptTransportReceipt(index: index, taskID: taskID, success: success) else { return }
        active.remove(key)
        if !success && !records[i].isUserPaused {
            // Keep `.sending`: a failed client response is not proof the server
            // failed. Resume reconciles the original ticket before any new PUT.
            records[i].failure = SpatialClientError.uploadUncertain.localizedDescription
        }
        do { try persist() } catch { }
        pump()
    }
    fileprivate func eventsDrained() {
        // URLSession finished delivering *its* callbacks, not our authenticated
        // /complete -> /inputs -> /start transitions. Give those a bounded drain
        // before yielding iOS's wake assertion; otherwise only three photos
        // upload and the job silently waits for the owner to reopen the app.
        guard finishBackgroundEvents != nil else { reconnect(); return }
        if backgroundDrain == .invalid {
            backgroundDrain = UIApplication.shared.beginBackgroundTask(withName: "Spatial upload receipts") { [weak self] in
                Task { @MainActor in self?.finishDrain() }
            }
        }
        reconnect()
        drainTask?.cancel()
        drainTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(20)
            repeat {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                if !reconnecting && preparingTransfers.isEmpty && starting.isEmpty { break }
            } while Date() < deadline
            finishDrain()
        }
    }
    private func finishDrain() {
        drainTask?.cancel()
        drainTask = nil
        flushJournalQuietly() // Nothing coalesced may be lost to the suspension that follows.
        let finished = finishBackgroundEvents
        finishBackgroundEvents = nil
        finished?()
        if backgroundDrain != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundDrain)
            backgroundDrain = .invalid
        }
    }
    private func fail(_ id: UUID, _ error: Error) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard !records[i].isUserPaused else { return }
        if Self.isServiceUnavailable(error) {
            // `/start` said the service is switched off. Every photo is on the
            // server; a Resume button would only fail the same way, so the
            // screen shows the honest disabled state and re-checks capability.
            records[i].serviceUnavailable = true
            records[i].failure = "3D rooms aren't available yet. Every photo is uploaded and your capture is saved on this phone; generation can start once the service is switched on."
        } else {
            records[i].failure = (error as? LocalizedError)?.errorDescription ?? "Upload paused. Your capture is saved. Tap Resume upload to reconnect."
            if Self.isTerminal(error) { records[i].terminal = true }
        }
        do { try persist() } catch { }
    }
    /// RP503 "3D generation is not configured yet" from `/start`, or the
    /// offline mock. Other 503s ("state could not be confirmed — retry") are
    /// transient and keep the ordinary Resume path.
    private nonisolated static func isServiceUnavailable(_ error: Error) -> Bool {
        if case SpatialClientError.noLiveService = error { return true }
        guard let api = error as? APIError, api.status == 503, case .server(_, _, let text) = api else { return false }
        return text.localizedCaseInsensitiveContains("not configured")
    }
    /// Failures no retry can fix: the capture itself failed verification, or
    /// the server rejected the request as such (400/403/404). Everything else
    /// stays resumable.
    private nonisolated static func isTerminal(_ error: Error) -> Bool {
        if case SpatialClientError.invalidCapture = error { return true }
        guard let api = error as? APIError, let status = api.status else { return false }
        return [400, 403, 404].contains(status)
    }
    private static func parse(_ key: String) -> (UUID, Int)? {
        let fields = key.split(separator: ":")
        guard fields.count == 3, fields[0] == "spatial", let id = UUID(uuidString: String(fields[1])),
              let index = Int(fields[2]), (0..<400).contains(index) else { return nil }
        return (id, index)
    }
}

private final class SpatialTransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let taskID = task.taskIdentifier
        let failed = error != nil
        Task { @MainActor in SpatialUploadCoordinator.shared.transferFinished(key: key, taskID: taskID, status: status, failed: failed) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in SpatialUploadCoordinator.shared.eventsDrained() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A write capability is for one gateway; redirects cannot carry room
        // bytes or capability query parameters to another origin.
        completionHandler(nil)
    }
}
