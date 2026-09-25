import ARKit
import Foundation
import CoreVideo
import simd

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
    private var quality = CaptureQualitySelector()
    private var blurSkips = 0
    private var baselineSkips = 0
    private var qualitySkips = 0
    private var lowTextureFrames = 0
    private var motionBlurSkips = 0
    private var previousPose: (transform: simd_float4x4, timestamp: TimeInterval)?
    var onStatus: ((String) -> Void)?
    var onFinished: ((URL?, String, Bool, CaptureStopReason?) -> Void)?

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
                files.manifest.quality_policy = "luma-baseline-v1-provisional"
                files.manifest.quality_thresholds = [
                    "sample_max_dimension": Double(CaptureQualitySelector.maximumSampleDimension),
                    "minimum_laplacian_variance": CaptureQualitySelector.minimumLaplacianVariance,
                    "low_texture_variance": CaptureQualitySelector.lowTextureVariance,
                    "minimum_translation_metres": CaptureQualitySelector.minimumTranslationMetres,
                    "minimum_rotation_degrees": CaptureQualitySelector.minimumRotationDegrees]
                files.manifest.motion_blur_thresholds = CaptureBlurEstimator.manifestThresholds
                try self.writeManifest(files)
                self.active = files
                self.cadence = FrameCadence()
                self.firstTimestamp = nil
                self.resolution = nil
                self.nextIndex = 1
                self.trackingSkips = 0
                self.busySkips = 0
                self.quality = CaptureQualitySelector()
                self.blurSkips = 0
                self.baselineSkips = 0
                self.qualitySkips = 0
                self.lowTextureFrames = 0
                self.motionBlurSkips = 0
                self.previousPose = nil
                DispatchQueue.main.async { completion(.success(())) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func finish(status: String = "complete", detail: String = "Stopped by the operator.") {
        delegateQueue.async { self.finishOnDelegateQueue(status: status, detail: detail) }
    }

    private func finishOnDelegateQueue(status: String, detail: String, stopReason: CaptureStopReason? = nil) {
        guard let files = active else { return }
        active = nil // Stop admission immediately; queued writer work is drained before finalization.
        let skippedTracking = trackingSkips
        let skippedBusy = busySkips
        let skippedBlur = blurSkips, skippedBaseline = baselineSkips
        let skippedQuality = qualitySkips, lowTexture = lowTextureFrames
        let skippedMotionBlur = motionBlurSkips
        writerQueue.async {
            files.manifest.status = files.writeError == nil ? status : "failed"
            files.manifest.status_detail = files.writeError ?? detail
            files.manifest.stop_reason = stopReason
            files.manifest.finished_at = ISO8601DateFormatter().string(from: Date())
            files.manifest.skipped_tracking_frames = skippedTracking
            files.manifest.skipped_busy_frames = skippedBusy
            files.manifest.skipped_blur_frames = skippedBlur
            files.manifest.skipped_baseline_frames = skippedBaseline
            files.manifest.skipped_quality_frames = skippedQuality
            files.manifest.low_texture_frames = lowTexture
            files.manifest.skipped_motion_blur_frames = skippedMotionBlur
            do {
                try self.writeManifest(files)
                var ready = false
                var message = "\(files.manifest.frames.count) photos saved. \(files.manifest.status_detail)"
                if files.manifest.status == "complete" {
                    do { _ = try NativeRasterWriter.validateCapture(at: files.root); ready = true }
                    catch { message += " \(error.localizedDescription)" }
                }
                DispatchQueue.main.async { self.onFinished?(files.root, message, ready, stopReason) }
            } catch {
                DispatchQueue.main.async { self.onFinished?(files.root, "Final manifest could not be saved: \(error.localizedDescription). Files are preserved; export is unavailable.", false, stopReason) }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let files = active else { return }
        guard frame.timestamp.isFinite else {
            finishOnDelegateQueue(status: "failed", detail: "Camera timing is invalid. Your saved photos are preserved.")
            return
        }
        if firstTimestamp == nil { firstTimestamp = frame.timestamp }
        let elapsed = frame.timestamp - (firstTimestamp ?? frame.timestamp)
        guard elapsed.isFinite, elapsed >= 0 else {
            finishOnDelegateQueue(status: "failed", detail: "Camera timing changed unexpectedly. Your saved photos are preserved.")
            return
        }
        if elapsed >= 600 || nextIndex > 400 {
            let reason: CaptureStopReason = nextIndex > 400 ? .frameLimit : .durationLimit
            // All admitted writes drain first. A normal ceiling can finish a
            // complete scan; failed writes and full-file validation still gate it.
            finishOnDelegateQueue(status: "complete", detail: reason == .frameLimit
                ? "The 400-photo limit was reached. Check your coverage before using this scan."
                : "The 10-minute limit was reached. Check your coverage before using this scan.", stopReason: reason)
            return
        }
        guard case .normal = frame.camera.trackingState else { trackingSkips += 1; previousPose = nil; return }
        // Instantaneous angular speed over the previous normally tracked ARFrame
        // (about 1/60 s apart), evaluated for every frame so a cadence-admitted
        // frame is judged by the motion actually happening around its exposure.
        let motionPreviousPose = previousPose
        let blurEstimate = motionPreviousPose.flatMap {
            CaptureBlurEstimator.estimate(previous: $0.transform, current: frame.camera.transform,
                                          previousTimestamp: $0.timestamp, currentTimestamp: frame.timestamp,
                                          exposureDuration: frame.camera.exposureDuration, fx: frame.camera.intrinsics[0][0])
        }
        previousPose = (frame.camera.transform, frame.timestamp)
        guard bufferGate.wait(timeout: .now()) == .success else { busySkips += 1; return }
        guard cadence.isEligible(timestamp: frame.timestamp, normalTracking: true) else { bufferGate.signal(); return }
        let camera = frame.camera
        let blurVerdict = CaptureBlurEstimator.verdict(for: blurEstimate, exposureDuration: camera.exposureDuration)
        if blurVerdict.skipsFrame {
            // Not recorded and not counted toward the 400-photo cap.
            motionBlurSkips += 1
            bufferGate.signal()
            if let hint = blurVerdict.hint {
                DispatchQueue.main.async { self.onStatus?("\(hint) Waiting for a usable photo; you can stop any time.") }
            }
            return
        }
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
        let measuredPose = CaptureGeometry.rows(camera.transform)
        var quality = self.quality // Commit this copy only after all candidate checks pass.
        let selection = quality.evaluate(Self.qualityMeasurement(buffer), pose: measuredPose)
        switch selection {
        case .keep: break
        case .skipBlur:
            blurSkips += 1
            bufferGate.signal()
            DispatchQueue.main.async { self.onStatus?("Hold the phone steady and move more slowly. Blurry frames are being skipped; you can stop any time.") }
            return
        case .skipBaseline:
            baselineSkips += 1
            bufferGate.signal()
            DispatchQueue.main.async { self.onStatus?("Take a small step or gently turn toward a new angle. Repeated viewpoints are being skipped.") }
            return
        case .invalidPose, .invalidImage:
            qualitySkips += 1
            bufferGate.signal()
            DispatchQueue.main.async { self.onStatus?("Waiting for a usable camera frame. Your saved frames are safe and Stop remains available.") }
            return
        }
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
            camera_to_world: measuredPose, intrinsics: CaptureGeometry.rows(camera.intrinsics),
            image_resolution: size, timestamp: frame.timestamp, tracking_state: TrackingRecord(state: "normal", reason: nil),
            raw_feature_points: points, exposure_duration_seconds: camera.exposureDuration,
            exposure_offset_ev: Double(camera.exposureOffset), world_mapping_status: mappingName(frame.worldMappingStatus),
            angular_speed_deg_s: blurEstimate?.angularSpeedDegreesPerSecond,
            predicted_smear_px: blurEstimate?.predictedSmearPixels,
            motion_previous_timestamp: motionPreviousPose?.timestamp,
            motion_previous_camera_to_world: motionPreviousPose.map { CaptureGeometry.rows($0.transform) })
        do { try record.validate(expectedSession: files.sessionID) }
        catch {
            qualitySkips += 1
            bufferGate.signal()
            DispatchQueue.main.async { self.onStatus?("Waiting for valid camera measurements. Your saved photos are safe.") }
            return
        }
        // A rejected candidate never consumes cadence or the accepted viewpoint.
        guard cadence.accept(timestamp: frame.timestamp, normalTracking: true) else { bufferGate.signal(); return }
        self.quality = quality
        if selection == .keep(lowTexture: true) { lowTextureFrames += 1 }
        nextIndex += 1
        let admittedLowTexture = selection == .keep(lowTexture: true)
        let blurHint = blurVerdict.hint
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
                    DispatchQueue.main.async {
                        self.onStatus?(blurHint != nil
                            ? "\(count) photos saved. \(blurHint!)"
                            : admittedLowTexture
                            ? "\(count) photos saved. Include furniture, corners or doorways as you move. Stop when the room is covered."
                            : count >= 300
                                ? "\(count) photos saved. Check that you covered the room, then tap Stop and save. Capture ends at 400 photos."
                                : "\(count) photos saved. Move slowly and keep some of the same room details in view. Aim for 300–350 photos.")
                    }
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

    private static func qualityMeasurement(_ buffer: CVPixelBuffer) -> CaptureQualitySelector.Measurement? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard (3...8192).contains(width), (3...8192).contains(height), rowBytes >= width,
              width * height <= 16 * 1024 * 1024, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(1, (max(width, height) + CaptureQualitySelector.maximumSampleDimension - 1) / CaptureQualitySelector.maximumSampleDimension)
        let sampleWidth = width / stride, sampleHeight = height / stride
        var samples = [Double](); samples.reserveCapacity(sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                var sum = 0
                for sy in (y * stride)..<((y + 1) * stride) {
                    for sx in (x * stride)..<((x + 1) * stride) { sum += Int(bytes[sy * rowBytes + sx]) }
                }
                var luma = Double(sum) / Double(stride * stride)
                if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { luma = min(255, max(0, (luma - 16) * 255 / 219)) }
                samples.append(luma)
            }
        }
        // This thumbnail is only a metric. The writer receives the untouched
        // original buffer, native JPEG dimensions, K and measured camera pose.
        return CaptureQualitySelector.measure(luma: samples, width: sampleWidth, height: sampleHeight)
    }
}
