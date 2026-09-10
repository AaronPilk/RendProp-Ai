import ARKit
import Foundation

// Every mutable property except SessionFiles is owned by delegateQueue. SessionFiles
// belongs to writerQueue. A nonblocking gate allows exactly one retained pixel buffer.
final class CaptureRecorder: NSObject, ARSessionDelegate {
    let delegateQueue = DispatchQueue(label: "spatial.capture.frames", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "spatial.capture.disk", qos: .utility)
    private let bufferGate = DispatchSemaphore(value: 1)
    private let rasterWriter = NativeRasterWriter()
    private var active: SessionFiles?
    private var cadence = FrameCadence()
    private var firstTimestamp: Double?
    private var resolution: ImageResolution?
    private var nextIndex = 1
    private var trackingSkips = 0
    private var busySkips = 0
    var onStatus: ((String) -> Void)?
    var onFinished: ((URL?, String, Bool) -> Void)?

    private final class SessionFiles {
        let root: URL
        let sessionID: String
        var manifest: CaptureManifest
        var writeError: String?
        init(root: URL, manifest: CaptureManifest) { self.root = root; self.sessionID = manifest.session_id; self.manifest = manifest }
    }

    func start(deviceModel: String, operatingSystem: String, completion: @escaping (Result<Void, Error>) -> Void) {
        delegateQueue.async {
            guard self.active == nil else { return }
            do {
                let sid = UUID().uuidString
                let archive = try CaptureArchive.local()
                guard try archive.prepareRoot(createIfMissing: true) else {
                    throw CaptureError.invalid("Capture storage could not be prepared.")
                }
                let root = archive.root.appendingPathComponent(sid, isDirectory: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("frames"), withIntermediateDirectories: true)
                let files = SessionFiles(root: root, manifest: CaptureManifest(sessionID: sid, deviceModel: deviceModel, operatingSystem: operatingSystem))
                try self.writeManifest(files)
                self.active = files
                self.cadence = FrameCadence()
                self.firstTimestamp = nil
                self.resolution = nil
                self.nextIndex = 1
                self.trackingSkips = 0
                self.busySkips = 0
                DispatchQueue.main.async { completion(.success(())) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func finish(status: String = "complete", detail: String = "Stopped by the operator.") {
        delegateQueue.async { self.finishOnDelegateQueue(status: status, detail: detail) }
    }

    private func finishOnDelegateQueue(status: String, detail: String) {
        guard let files = active else { return }
        active = nil // Stop admission immediately; queued writer work is drained before finalization.
        let skippedTracking = trackingSkips
        let skippedBusy = busySkips
        writerQueue.async {
            files.manifest.status = files.writeError == nil ? status : "failed"
            files.manifest.status_detail = files.writeError ?? detail
            files.manifest.finished_at = ISO8601DateFormatter().string(from: Date())
            files.manifest.skipped_tracking_frames = skippedTracking
            files.manifest.skipped_busy_frames = skippedBusy
            do {
                try self.writeManifest(files)
                var ready = false
                var message = "\(files.manifest.frames.count) frames saved. \(files.manifest.status_detail)"
                if files.manifest.status == "complete" {
                    do { _ = try NativeRasterWriter.validateCapture(at: files.root); ready = true }
                    catch { message += " \(error.localizedDescription)" }
                }
                DispatchQueue.main.async { self.onFinished?(files.root, message, ready) }
            } catch {
                DispatchQueue.main.async { self.onFinished?(files.root, "Final manifest could not be saved: \(error.localizedDescription). Files are preserved; export is unavailable.", false) }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let files = active else { return }
        if firstTimestamp == nil { firstTimestamp = frame.timestamp }
        guard frame.timestamp - (firstTimestamp ?? frame.timestamp) < 600, nextIndex <= 400 else {
            finishOnDelegateQueue(status: "limit_reached", detail: "Reached the 400-frame or 10-minute spike limit. Files preserved; start a new shorter capture.")
            return
        }
        guard case .normal = frame.camera.trackingState else { trackingSkips += 1; return }
        guard bufferGate.wait(timeout: .now()) == .success else { busySkips += 1; return }
        guard cadence.accept(timestamp: frame.timestamp, normalTracking: true) else { bufferGate.signal(); return }
        let camera = frame.camera
        let size = ImageResolution(width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height))
        guard resolution == nil || resolution == size else {
            bufferGate.signal()
            finishOnDelegateQueue(status: "failed", detail: "Camera raster size changed during capture; preserved without mixing calibration.")
            return
        }
        resolution = size
        let index = nextIndex
        // Snapshot image, pose, calibration and point cloud from this one ARFrame.
        // Never retain ARFrame itself or query currentFrame later on the writer queue.
        let buffer = frame.capturedImage
        let cloud = frame.rawFeaturePoints
        let positions = cloud?.points ?? []
        let identifiers = cloud?.identifiers ?? []
        guard positions.count <= 50_000, positions.count == identifiers.count else {
            bufferGate.signal()
            finishOnDelegateQueue(status: "failed", detail: "ARKit supplied more than 50,000 points in a frame; stopped without truncation.")
            return
        }
        let points: [FeaturePoint] = positions.enumerated().map { i, point in
            return FeaturePoint(id: String(identifiers[i]), position: [Double(point.x), Double(point.y), Double(point.z)])
        }
        let record = FrameRecord(session_id: files.sessionID, image: String(format: "images/%06d.jpg", index),
            camera_to_world: CaptureGeometry.rows(camera.transform), intrinsics: CaptureGeometry.rows(camera.intrinsics),
            image_resolution: size, timestamp: frame.timestamp, tracking_state: TrackingRecord(state: "normal", reason: nil),
            raw_feature_points: points, exposure_duration_seconds: camera.exposureDuration,
            exposure_offset_ev: Double(camera.exposureOffset), world_mapping_status: mappingName(frame.worldMappingStatus))
        nextIndex += 1
        writerQueue.async {
            defer { self.bufferGate.signal() }
            autoreleasepool {
                do {
                    guard files.writeError == nil else { return }
                    try record.validate(expectedSession: files.manifest.session_id)
                    let imageURL = files.root.appendingPathComponent(record.image)
                    let temporary = files.root.appendingPathComponent(String(format: "images/%06d.partial.jpg", index))
                    try self.rasterWriter.write(buffer, resolution: size, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: imageURL)
                    let sidecar = String(format: "frames/%06d.json", index)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(record).write(to: files.root.appendingPathComponent(sidecar), options: .atomic)
                    files.manifest.frames.append(sidecar)
                    files.manifest.feature_point_observations += points.count
                    files.manifest.image_bytes += (try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    // Manifest advancement is last: crashes can leave recoverable orphan files,
                    // but cannot declare a frame durable before both paired files exist.
                    try self.writeManifest(files)
                    let count = files.manifest.frames.count
                    DispatchQueue.main.async { self.onStatus?("\(count) frames saved. Walk slowly around the room; aim for 150–250 frames. Stop when ready.") }
                } catch {
                    files.writeError = error.localizedDescription
                    self.delegateQueue.async {
                        guard self.active === files else { return }
                        self.finishOnDelegateQueue(status: "failed", detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard active != nil else { return }
        let message: String
        switch camera.trackingState {
        case .normal: message = "Tracking normal. Keep moving slowly."
        case .notAvailable: message = "Tracking unavailable; frames are being skipped."
        case .limited(let reason):
            // Relocalization is a coordinate continuity risk even without a preceding
            // interruption callback. Phase A never mixes frames across this boundary.
            if reason == .relocalizing {
                finishOnDelegateQueue(status: "interrupted", detail: "ARKit began relocalizing. Start a fresh capture to keep one coordinate epoch.")
                return
            }
            message = "Tracking limited (\(reason)); frames are being skipped."
        }
        DispatchQueue.main.async { self.onStatus?(message) }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        // Apple advises against pause() inside this callback. Finalize data only;
        // the controller pauses after the pending disk write completes.
        finishOnDelegateQueue(status: "interrupted", detail: "Capture interrupted. Saved files remain available; begin a new capture.")
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
    func session(_ session: ARSession, didFailWithError error: Error) {
        finishOnDelegateQueue(status: "failed", detail: "AR session failed: \(error.localizedDescription)")
    }

    private func writeManifest(_ files: SessionFiles) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(files.manifest).write(to: files.root.appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func mappingName(_ value: ARFrame.WorldMappingStatus) -> String {
        switch value {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }
}
