import Foundation
import Network

/// Large-file upload manager. Three modes (Config.uploadMode):
///  .simulate — chunk-reads the real file from disk with realistic progress;
///              fully offline, survives relaunch (resumes from saved offset).
///  .direct   — presigned PUT via background URLSession (streams from file,
///              multi-GB safe, continues when app is backgrounded/killed).
///  .tus      — TODO: TUSKit path when a tus server exists.
final class UploadManager: NSObject, ObservableObject {
    static let shared = UploadManager()

    enum Status: String, Codable {
        case queued, uploading, paused, failed, done
    }

    struct State: Codable, Identifiable {
        var id = UUID()
        var filePath: String              // relative to Documents (container path changes between installs)
        var bytesTotal: Int64
        var bytesSent: Int64 = 0
        var status: Status = .queued
        var mode: String
        var uploadID: String?             // server-side upload session id
        var sha256: String?
        var retryCount: Int = 0

        var fractionComplete: Double {
            bytesTotal > 0 ? Double(bytesSent) / Double(bytesTotal) : 0
        }

        var fileURL: URL {
            FileStore.documents.appendingPathComponent(filePath)
        }
    }

    @Published private(set) var state: State?
    /// Set when a large upload wants to start on cellular — UI shows a prompt.
    @Published var pendingCellularConfirmation: Bool = false

    private let monitor = NWPathMonitor()
    private(set) var pathIsExpensive = false
    private var simulateTimer: Timer?
    private var api: APIClient = MockAPIClient()

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.rendprop.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathIsExpensive = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "com.rendprop.netpath"))

        // Resume anything persisted from a previous launch.
        if let saved = UploadStore.load() {
            state = saved
            if saved.status == .uploading || saved.status == .queued {
                resume()
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

    func begin(fileURL: URL, cellularApproved: Bool = false) {
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0 else { return }

        if shouldWarnCellular(bytes: bytes) && !cellularApproved {
            pendingCellularConfirmation = true
            // Queue it; UI confirms and calls begin(cellularApproved: true) or leaves queued.
        }

        let relative = fileURL.path.replacingOccurrences(of: FileStore.documents.path + "/", with: "")
        var newState = State(filePath: relative, bytesTotal: bytes, mode: Config.uploadMode.rawValue)
        newState.status = (shouldWarnCellular(bytes: bytes) && !cellularApproved) ? .queued : .uploading
        state = newState
        persist()

        guard newState.status == .uploading else { return }
        run()
    }

    func confirmCellularAndStart() {
        pendingCellularConfirmation = false
        guard var s = state else { return }
        s.status = .uploading
        state = s
        persist()
        run()
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
        run()
    }

    func cancel() {
        simulateTimer?.invalidate()
        backgroundSession.getAllTasks { $0.forEach { $0.cancel() } }
        state = nil
        UploadStore.save(nil)
    }

    // MARK: - Dispatch

    private func run() {
        guard let s = state else { return }
        switch Config.UploadMode(rawValue: s.mode) ?? .simulate {
        case .simulate: runSimulate()
        case .direct:   runDirect()
        case .tus:      runSimulate()   // TODO: TUSKit — falls back to simulate for now
        }
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
        if s.sha256 == nil {
            let url = s.fileURL
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let digest = DirectUploader.sha256(of: url)
                DispatchQueue.main.async { self?.mutate { $0.sha256 = digest } }
            }
        }

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

    // MARK: - Direct mode (presigned PUT, background URLSession)

    private func runDirect() {
        guard let s = state else { return }
        Task {
            do {
                let ticket = try await api.requestUpload(filename: s.fileURL.lastPathComponent,
                                                         bytes: s.bytesTotal)
                await MainActor.run {
                    self.mutate { $0.uploadID = ticket.id }
                    guard let putURL = ticket.putURL else {
                        // No presigned URL available (offline dev) → simulate instead.
                        self.runSimulate()
                        return
                    }
                    let task = self.backgroundSession.uploadTask(with: DirectUploader.putRequest(url: putURL),
                                                                 fromFile: s.fileURL)
                    task.resume()
                }
            } catch {
                await MainActor.run { self.mutate { $0.status = .failed } }
            }
        }
    }

    // MARK: - Helpers

    private func mutate(_ change: (inout State) -> Void) {
        guard var s = state else { return }
        change(&s)
        state = s
        persist()
    }

    private func persist() {
        UploadStore.save(state)
    }
}

// MARK: - Background URLSession delegate
extension UploadManager: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        DispatchQueue.main.async {
            self.mutate { $0.bytesSent = totalBytesSent }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let _ = error {
                // Auto-retry with backoff, up to 5 attempts.
                guard var s = self.state, s.retryCount < 5 else {
                    self.mutate { $0.status = .failed }
                    return
                }
                s.retryCount += 1
                self.state = s
                self.persist()
                let delay = pow(2.0, Double(s.retryCount))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.run() }
            } else {
                self.mutate { $0.bytesSent = $0.bytesTotal; $0.status = .done }
                Haptics.success()
                if let s = self.state, let uploadID = s.uploadID {
                    let digest = s.sha256
                    Task { try? await self.api.completeUpload(id: uploadID, sha256: digest) }
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundSessionBridge.shared.completionHandler?()
            BackgroundSessionBridge.shared.completionHandler = nil
        }
    }
}
