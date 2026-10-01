import CoreVideo
import Foundation
import simd
#if os(iOS)
import ARKit

enum StationCaptureRecorderState: String { case idle, preparing, ready, capturing, saving, finished }

struct StationCaptureUpdate {
    let state: StationCaptureRecorderState
    let message: String
    let savedTargets: Int
    let totalTargets: Int
    let target: StationCaptureTarget?
    let targetDirection: [Double]?
    let angularErrorDegrees: Double?
    let pivotDriftMeters: Double?
}

/// The controller owns ARSession and invokes process on MainActor. Only the
/// admitted image/depth buffers are retained; no ARFrame crosses the disk queue.
@MainActor
final class StationCaptureRecorder {
    private(set) var state: StationCaptureRecorderState = .idle
    private(set) var tourURL: URL?
    private(set) var manifest: StationCaptureManifest?
    var currentStationID: String? {
        guard let index = activeStationIndex, let manifest, index < manifest.stations.count else { return nil }
        return manifest.stations[index].id
    }
    var onUpdate: ((StationCaptureUpdate) -> Void)?
    var onFinished: ((URL?, String) -> Void)?
    private let writerQueue = DispatchQueue(label: "rendprop.station.disk", qos: .userInitiated)
    private var files: Files?
    private var policy: StationCapturePolicy?
    private var activeStationIndex: Int?
    private var previousPose: (matrix: simd_float4x4, timestamp: Double)?
    private var ending = false
    private var endReason: String?
    private var finishingStation = false
    private var lastUpdateTime = -Double.infinity
    private var epoch = StationCaptureEpochPolicy()

    // Every mutable member of Files belongs exclusively to writerQueue.
    private final class Files: @unchecked Sendable {
        let root: URL
        let raster = NativeRasterWriter()
        var manifest: StationCaptureManifest
        var error: String?
        init(root: URL, manifest: StationCaptureManifest) { self.root = root; self.manifest = manifest }
        func saveManifest() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(manifest)
            guard bytes.count <= StationCaptureLimits.maximumManifestBytes else { throw CaptureError.invalid("Tour manifest exceeds its size limit.") }
            try bytes.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
        func requireCapacity() throws {
            guard manifest.stored_bytes <= StationCaptureLimits.maximumTourBytes - StationCaptureLimits.frameReservationBytes else {
                throw CaptureError.invalid("This tour reached its storage limit. Saved positions are preserved.")
            }
            let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
            guard let available, available >= StationCaptureLimits.minimumFreeBytes + StationCaptureLimits.frameReservationBytes else {
                throw CaptureError.invalid("Not enough free storage for another photo. Saved positions are preserved.")
            }
        }
    }

    // Immutable retained camera buffers are read only on the writer queue. This
    // wrapper does not declare arbitrary CVPixelBuffer mutation thread-safe.
    private struct RetainedBuffers: @unchecked Sendable {
        let image: CVPixelBuffer
        let depth: CVPixelBuffer?
        let confidence: CVPixelBuffer?
    }

    func startTour(deviceModel: String, operatingSystem: String, depthSupported: Bool) async throws {
        guard state == .idle else { throw CaptureError.invalid("Start a new tour screen to create a new camera session.") }
        state = .preparing; emit("Preparing local tour storage…")
        do {
            let created: Files = try await withCheckedThrowingContinuation { continuation in
                writerQueue.async {
                    do {
                        let parent = try StationCaptureArchive.localRoot()
                        try StationCaptureArchive.prepareRoot(parent)
                        let id = UUID().uuidString
                        let root = parent.appendingPathComponent(id, isDirectory: true)
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                        for name in ["images", "frames", "depth"] {
                            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
                        }
                        let created = Files(root: root, manifest: StationCaptureManifest(sessionID: id, deviceModel: deviceModel,
                                                                                       operatingSystem: operatingSystem, depthSupported: depthSupported))
                        try created.requireCapacity(); try created.saveManifest()
                        continuation.resume(returning: created)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            files = created; tourURL = created.root; manifest = created.manifest
            if ending { finalizeTour(); throw CaptureError.invalid("Capture closed while preparing. Saved files are preserved.") }
            state = .ready
            emit("Stand where you want to scan. Hold the camera still and tap Scan this position.")
        } catch {
            if files == nil { state = .finished; emit(error.localizedDescription); onFinished?(tourURL, error.localizedDescription) }
            throw error
        }
    }

    func beginStation(frame: ARFrame) throws {
        guard state == .ready, !ending, let files, let manifest else { throw CaptureError.invalid("Wait until the previous position has finished saving.") }
        if let reason = epoch.observe(timestamp: frame.timestamp, relocalizing: Self.isRelocalizing(frame.camera.trackingState)) {
            endTour(reason: reason); throw CaptureError.invalid(reason)
        }
        guard manifest.stations.count < StationCaptureLimits.maximumStations else { throw CaptureError.invalid("This test tour supports up to eight positions. Finish and save this tour.") }
        guard case .normal = frame.camera.trackingState,
              frame.timestamp.isFinite, frame.timestamp >= 0,
              let pose = StationCapturePolicy.pose(CaptureGeometry.rows(frame.camera.transform)) else {
            throw CaptureError.invalid("Hold still and point at room details until camera tracking is ready.")
        }
        guard abs(pose.forward[1]) < 0.5 else { throw CaptureError.invalid("Point the camera straight ahead to begin this position.") }
        let reference = atan2(pose.forward[0], -pose.forward[2]) * 180 / .pi
        let station = StationCaptureStation(id: UUID().uuidString, index: manifest.stations.count, origin: pose.origin,
                                           reference_yaw_degrees: reference, started_timestamp: frame.timestamp)
        activeStationIndex = station.index
        policy = StationCapturePolicy(origin: pose.origin, referenceYawDegrees: reference)
        previousPose = nil; finishingStation = false
        state = .saving; emit("Saving the starting position…")
        writerQueue.async {
            do {
                try files.requireCapacity()
                files.manifest.stations.append(station)
                try files.saveManifest()
                let snapshot = files.manifest
                DispatchQueue.main.async {
                    self.manifest = snapshot
                    guard !self.ending, !self.finishingStation else { return }
                    self.state = .capturing
                    self.emit("Follow the target. Keep the camera at this spot as you turn around it.")
                }
            } catch { self.diskFailure(files, error: error) }
        }
    }

    func process(frame: ARFrame) {
        // Watch the epoch during previews and disk writes too. A relocalization
        // between positions must never silently establish a new coordinate frame.
        if files != nil, !ending, state != .finished,
           let reason = epoch.observe(timestamp: frame.timestamp, relocalizing: Self.isRelocalizing(frame.camera.trackingState)) {
            endTour(reason: reason); return
        }
        guard state == .capturing, !ending, !finishingStation, let files, let index = activeStationIndex,
              var policy, let manifest, index < manifest.stations.count else { return }
        let camera = frame.camera
        let normal: Bool
        if case .normal = camera.trackingState { normal = true } else { normal = false }
        let previous = previousPose
        let estimate = normal ? previous.flatMap {
            CaptureBlurEstimator.estimate(previous: $0.matrix, current: camera.transform, previousTimestamp: $0.timestamp,
                                          currentTimestamp: frame.timestamp, exposureDuration: camera.exposureDuration, fx: camera.intrinsics[0][0])
        } : nil
        previousPose = normal ? (camera.transform, frame.timestamp) : nil
        let measuredPose = CaptureGeometry.rows(camera.transform)
        let guidance = policy.evaluate(timestamp: frame.timestamp, cameraToWorld: measuredPose, normalTracking: normal,
                                       motionBlurAcceptable: estimate.map { $0.predictedSmearPixels <= 2 } ?? false,
                                       angularSpeedDegreesPerSecond: estimate?.angularSpeedDegreesPerSecond)
        self.policy = policy
        if frame.timestamp - lastUpdateTime >= 0.1 || guidance.readyToCapture {
            lastUpdateTime = frame.timestamp; emit(guidance.message, guidance: guidance)
        }
        guard guidance.readyToCapture, let target = guidance.target,
              let drift = guidance.pivotDriftMeters, let angle = guidance.angularErrorDegrees else { return }
        let cloud = frame.rawFeaturePoints
        let positions = cloud?.points ?? [], identifiers = cloud?.identifiers ?? []
        guard positions.count <= 50_000, positions.count == identifiers.count else {
            endTour(reason: "Camera measurements exceeded the capture limit. Saved photos are preserved."); return
        }
        let number = manifest.frameCount + 1
        let points = positions.enumerated().map { FeaturePoint(id: String(identifiers[$0.offset]), position: [Double($0.element.x), Double($0.element.y), Double($0.element.z)]) }
        let frameRecord = FrameRecord(session_id: manifest.session_id, image: String(format: "images/%06d.jpg", number),
                                      camera_to_world: measuredPose, intrinsics: CaptureGeometry.rows(camera.intrinsics),
                                      image_resolution: ImageResolution(width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height)),
                                      timestamp: frame.timestamp, tracking_state: TrackingRecord(state: "normal", reason: nil),
                                      raw_feature_points: points, exposure_duration_seconds: camera.exposureDuration,
                                      exposure_offset_ev: Double(camera.exposureOffset), world_mapping_status: Self.mappingName(frame.worldMappingStatus),
                                      angular_speed_deg_s: estimate?.angularSpeedDegreesPerSecond, predicted_smear_px: estimate?.predictedSmearPixels,
                                      motion_previous_timestamp: previous?.timestamp,
                                      motion_previous_camera_to_world: previous.map { CaptureGeometry.rows($0.matrix) })
        do { try frameRecord.validate(expectedSession: manifest.session_id) }
        catch { self.policy?.resetDwell(); emit("Waiting for valid camera measurements. Saved photos are safe."); return }
        guard self.policy?.beginWrite() == true else { return }
        // Snapshot all image/depth buffers from this one frame before leaving it.
        // Exactly one image and optional depth/confidence pair can be in flight.
        let buffers = RetainedBuffers(image: frame.capturedImage, depth: frame.sceneDepth?.depthMap, confidence: frame.sceneDepth?.confidenceMap)
        let stationID = manifest.stations[index].id
        state = .saving; emit("Saving photo \((self.policy?.completedCount ?? 0) + 1) of \(StationCaptureTarget.standard.count)…")
        writerQueue.async {
            do {
                guard files.error == nil else { return }
                try files.requireCapacity()
                let imageURL = files.root.appendingPathComponent(frameRecord.image)
                let temporary = files.root.appendingPathComponent(String(format: "images/%06d.partial.jpg", number))
                guard !FileManager.default.fileExists(atPath: imageURL.path), !FileManager.default.fileExists(atPath: temporary.path) else {
                    throw CaptureError.invalid("A saved photo already exists. It was not overwritten.")
                }
                try files.raster.write(buffers.image, resolution: frameRecord.image_resolution, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: imageURL)
                var depthMetadata: StationCaptureDepth?
                if let depth = buffers.depth {
                    let raw = try StationDepthPacking.copyDepth(depth)
                    let depthPath = String(format: "depth/%06d.f32", number)
                    try Self.writeNew(raw.data, to: files.root.appendingPathComponent(depthPath))
                    var confidencePath: String?
                    if let confidence = buffers.confidence {
                        let data = try StationDepthPacking.copyConfidence(confidence, width: raw.width, height: raw.height)
                        confidencePath = String(format: "depth/%06d.confidence", number)
                        try Self.writeNew(data, to: files.root.appendingPathComponent(confidencePath!))
                    }
                    depthMetadata = StationCaptureDepth(path: depthPath, width: raw.width, height: raw.height, confidence_path: confidencePath)
                }
                let record = StationCaptureFrame(station_id: stationID, target_id: target.id, frame: frameRecord,
                                                 depth: depthMetadata, depth_availability: depthMetadata != nil ? "available" : (manifest.depth_supported ? "unavailable-on-this-frame" : "unsupported"),
                                                 pivot_drift_metres: drift, angular_error_degrees: angle)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let sidecarBytes = try encoder.encode(record)
                guard sidecarBytes.count <= NativeRasterWriter.maximumSidecarBytes else { throw CaptureError.invalid("Photo measurements exceed their size limit.") }
                let sidecar = String(format: "frames/%06d.json", number)
                try Self.writeNew(sidecarBytes, to: files.root.appendingPathComponent(sidecar))
                var newBytes = Int64(sidecarBytes.count) + Int64(try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                if let depthMetadata {
                    newBytes += Int64(depthMetadata.width * depthMetadata.height * 4)
                    if depthMetadata.confidence_path != nil { newBytes += Int64(depthMetadata.width * depthMetadata.height) }
                }
                guard files.manifest.stored_bytes + newBytes <= StationCaptureLimits.maximumTourBytes else { throw CaptureError.invalid("Tour storage limit reached. Files are preserved.") }
                // Commit count last. Any failure before this leaves originals
                // preserved and fails export, never invents a durable target.
                files.manifest.stations[index].frames.append(sidecar)
                files.manifest.stored_bytes += newBytes
                let complete = files.manifest.stations[index].frames.count == files.manifest.stations[index].targets.count
                if complete {
                    files.manifest.stations[index].status = .complete
                    files.manifest.stations[index].status_detail = "All capture targets saved. Check the panoramic preview for gaps and seams."
                    files.manifest.stations[index].finished_at = ISO8601DateFormatter().string(from: Date())
                }
                try files.saveManifest()
                let snapshot = files.manifest
                DispatchQueue.main.async {
                    self.manifest = snapshot
                    self.policy?.finishWrite(targetID: target.id, succeeded: true)
                    guard !self.ending, !self.finishingStation else { return }
                    if complete {
                        self.activeStationIndex = nil; self.previousPose = nil
                        self.state = .ready; self.emit("Position saved. Check the preview, then move to the next position.")
                    } else { self.state = .capturing; self.emit("Photo saved. \(self.policy?.currentTarget?.instruction ?? "Follow the next target").") }
                }
            } catch { self.diskFailure(files, error: error) }
        }
    }

    func finishStation() {
        guard let files, let index = activeStationIndex, !ending, !finishingStation else { return }
        finishingStation = true; state = .saving; emit("Saving this position. Missing targets will remain marked as gaps…")
        writerQueue.async {
            do {
                guard index < files.manifest.stations.count else { throw CaptureError.invalid("The position was not saved.") }
                if files.manifest.stations[index].status != .complete {
                    files.manifest.stations[index].status = .partial
                    files.manifest.stations[index].status_detail = "Stopped before all targets were captured. Missing image coverage remains explicit."
                    files.manifest.stations[index].finished_at = ISO8601DateFormatter().string(from: Date())
                }
                try files.saveManifest()
                let snapshot = files.manifest
                DispatchQueue.main.async {
                    self.manifest = snapshot; self.activeStationIndex = nil; self.policy = nil; self.previousPose = nil
                    self.finishingStation = false
                    guard !self.ending else { return }
                    self.state = .ready; self.emit("Position saved with missing coverage. Preview it before continuing.")
                }
            } catch { self.diskFailure(files, error: error) }
        }
    }

    func endTour(reason: String? = nil) {
        guard !ending, state != .finished else { return }
        epoch.close()
        if state == .idle { ending = true; state = .finished; onFinished?(nil, reason ?? "Capture closed."); return }
        ending = true; endReason = reason
        state = .saving; emit("Saving your tour…")
        // If preparation is still running, its completion performs finalization.
        guard files != nil else { return }
        finalizeTour()
    }

    private func finalizeTour() {
        guard let files else { return }
        let reason = endReason
        writerQueue.async {
            do {
                let finished = ISO8601DateFormatter().string(from: Date())
                for index in files.manifest.stations.indices where files.manifest.stations[index].status == .capturing {
                    files.manifest.stations[index].status = files.error != nil ? .failed : (reason != nil ? .interrupted : .partial)
                    files.manifest.stations[index].status_detail = files.error ?? reason ?? "Stopped before all targets were captured."
                    files.manifest.stations[index].finished_at = finished
                }
                files.manifest.status = files.error != nil ? .failed : reason != nil ? .interrupted :
                    (!files.manifest.stations.isEmpty && files.manifest.stations.allSatisfy { $0.status == .complete } ? .complete : .partial)
                files.manifest.status_detail = files.error ?? reason ?? "Saved locally. Review the panoramic previews; no cloud processing was started."
                files.manifest.finished_at = finished
                try files.saveManifest()
                let snapshot = files.manifest
                DispatchQueue.main.async {
                    self.manifest = snapshot; self.policy = nil; self.activeStationIndex = nil; self.previousPose = nil
                    self.state = .finished; self.emit(snapshot.status_detail)
                    self.onFinished?(files.root, snapshot.status_detail)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .finished; self.emit("Final tour metadata could not be saved. Original files are preserved.")
                    self.onFinished?(files.root, "Final tour metadata could not be saved: \(error.localizedDescription)")
                }
            }
        }
    }

    // Called only from writerQueue, then posts the terminal request to MainActor.
    nonisolated private func diskFailure(_ files: Files, error: Error) {
        files.error = error.localizedDescription
        DispatchQueue.main.async {
            self.policy?.resetDwell()
            if !self.ending { self.endTour(reason: error.localizedDescription) }
        }
    }

    private func emit(_ message: String, guidance: StationCapturePolicy.Guidance? = nil) {
        onUpdate?(StationCaptureUpdate(state: state, message: message,
                                       savedTargets: policy?.completedCount ?? 0, totalTargets: StationCaptureTarget.standard.count,
                                       target: guidance?.target ?? policy?.currentTarget,
                                       targetDirection: guidance?.targetDirection ?? policy?.currentTarget?.direction(referenceYawDegrees: policy?.referenceYawDegrees ?? 0),
                                       angularErrorDegrees: guidance?.angularErrorDegrees, pivotDriftMeters: guidance?.pivotDriftMeters))
    }

    nonisolated private static func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.invalid("A saved capture file already exists. It was not overwritten.") }
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func mappingName(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status { case .notAvailable: return "notAvailable"; case .limited: return "limited"; case .extending: return "extending"; case .mapped: return "mapped"; @unknown default: return "unknown" }
    }
    private static func isRelocalizing(_ state: ARCamera.TrackingState) -> Bool {
        if case .limited(.relocalizing) = state { return true }; return false
    }
}
#endif

/// Copies native packed rows without interpreting invalid depth values. NaN/zero
/// depth holes remain exactly as recorded; consumers must use validity/confidence.
enum StationDepthPacking {
    static func copyDepth(_ buffer: CVPixelBuffer) throws -> (data: Data, width: Int, height: Int) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { throw CaptureError.invalid("Unexpected LiDAR depth format.") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        return (try copyRows(buffer, bytesPerPixel: 4), width, height)
    }
    static func copyConfidence(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw CaptureError.invalid("Depth confidence does not match its depth image.")
        }
        let data = try copyRows(buffer, bytesPerPixel: 1)
        guard data.allSatisfy({ $0 <= 2 }) else { throw CaptureError.invalid("Unknown depth confidence value.") }
        return data
    }
    private static func copyRows(_ buffer: CVPixelBuffer, bytesPerPixel: Int) throws -> Data {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              width * height <= StationCaptureLimits.maximumDepthPixels, rowBytes >= width * bytesPerPixel,
              !CVPixelBufferIsPlanar(buffer), CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw CaptureError.invalid("LiDAR buffer failed its size or layout checks.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureError.invalid("LiDAR depth pixels are unavailable.") }
        var data = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height { data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * bytesPerPixel) }
        return data
    }
}
