import Foundation
import UIKit
import Combine
import CryptoKit

/// One OS-owned background session survives leaving the spatial screen. Only
/// JPEG bytes go through it; the small authenticated state transitions are
/// retried from the durable journal when iOS wakes us or the app next opens.
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
    private var subscriptions = Set<AnyCancellable>()
    private var reconnecting = false
    private var journalURL: URL?
    private var backgroundDrain: UIBackgroundTaskIdentifier = .invalid
    private var drainTask: Task<Void, Never>?

    private init() {
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
                guard decoded.count <= 32, Set(decoded.map(\.id)).count == decoded.count else { throw SpatialClientError.unreadableJournal }
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
    private func persist() throws {
        guard let journalURL, recoveryError == nil else { throw SpatialClientError.unreadableJournal }
        do {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 4 * 1024 * 1024 else { throw SpatialClientError.unreadableJournal }
            try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        } catch {
            recoveryError = "Upload progress could not be saved. Your capture is preserved; uploading has paused."
            throw error
        }
    }

    func enqueue(capture: URL, listingLocalID: UUID, listingID: UUID, roomLabel: String, allowCellular: Bool) async throws {
        guard let ownerID, UUID(uuidString: ownerID) != nil else { throw SpatialClientError.accountChanged }
        guard recoveryError == nil, records.count < 32 else { throw SpatialClientError.unreadableJournal }
        let label = roomLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 80, let captureID = UUID(uuidString: capture.lastPathComponent) else {
            throw SpatialClientError.invalidCapture
        }
        if records.contains(where: { $0.ownerID == ownerID && $0.captureID == captureID }) { reconnect(); return }
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
        let record = try SpatialUploadRecord(id: UUID(), ownerID: ownerID, listingLocalID: listingLocalID,
            listingID: listingID, captureID: captureID, roomLabel: label, allowCellular: allowCellular, frames: prepared).validated()
        records.append(record)
        try persist() // A network operation is never allowed before this receipt.
        pump()
    }

    func retry(_ id: UUID) {
        guard let i = try? assertOwner(id) else { return }
        records[i].failure = nil
        for index in records[i].frames.indices { records[i].frames[index].reconciliations = 0 }
        do { try persist(); reconnect() } catch { }
    }
    func records(for listingID: UUID) -> [SpatialUploadRecord] {
        records.filter { $0.listingLocalID == listingID && owns($0) && !$0.queued }
    }

    func pause(jobID: UUID) throws {
        guard let i = records.firstIndex(where: { $0.jobID == jobID && owns($0) }) else { return }
        records[i].pausedByUser = true
        records[i].failure = SpatialClientError.uploadPaused.localizedDescription
        let prefix = records[i].taskPrefix
        try persist() // Stop durable scheduling before requesting cloud cancel.
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(prefix) == true { task.cancel() }
        }
    }
    func resume(jobID: UUID) throws {
        guard let i = records.firstIndex(where: { $0.jobID == jobID && owns($0) }) else { return }
        records[i].pausedByUser = false
        records[i].failure = nil
        records[i].queued = false
        for index in records[i].frames.indices { records[i].frames[index].reconciliations = 0 }
        try persist()
        reconnect()
    }

    func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        session.getAllTasks { tasks in
            Task { @MainActor in
                self.reconnecting = false
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
            if let jobID = record.jobID {
                let job = try await api.startSpatialJob(id: jobID)
                i = try assertOwner(id)
                guard job.id == jobID, job.listingID == record.listingID,
                      [.queued, .processing, .review, .ready].contains(job.status) else {
                    throw SpatialClientError.invalidResponse
                }
                records[i].queued = true
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
            }
            try persist()
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
            if let ticketID = frame.ticketID, frame.phase == .sending || frame.phase == .uploaded {
                guard frame.reconciliations < 3 else { throw SpatialClientError.uploadUncertain }
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
                if case .renew(let url) = outcome {
                    records[i].frames[index].reconciliations += 1
                    records[i].frames[index].putURL = url
                    records[i].frames[index].phase = .ticketed
                    try persist()
                    return // pump schedules this SAME receipt, never a new ticket.
                }
                records[i].frames[index].phase = .uploaded
                records[i].frames[index].putURL = nil
                try persist()
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
                let ticket = try await api.requestUpload(filename: "spatial-\(record.captureID.uuidString)-\(index).jpg",
                    bytes: frame.bytes, listingID: record.listingID, sha256: frame.sha256, kind: "photo", role: "capture",
                    contentType: "image/jpeg", idempotencyKey: "spatial:\(record.id.uuidString):\(index)")
                i = try assertOwner(id)
                guard ticket.mode == .single, let putURL = ticket.putURL, putURL.scheme == "https", putURL.host != nil else {
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
            do { try persist() } catch { task.cancel(); throw error }
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
        records[i].failure = (error as? LocalizedError)?.errorDescription ?? "Upload paused. Your capture is saved. Tap Resume upload to reconnect."
        do { try persist() } catch { }
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
