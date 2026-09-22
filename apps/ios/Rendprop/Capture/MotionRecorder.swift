import CoreMotion
import Foundation

/// 100Hz device-motion logging → `<video>.motion.json` sidecar. Each segment
/// uses its estimated host anchor and measured joined offset, and the final
/// file duration bounds its samples. Frame-exact sensor alignment requires a
/// physical-device trace; delegate timing alone does not prove it.
///
/// STATUS, honestly (audit F-D-10): the sidecar is WRITE-ONLY today. The
/// on-device engine does not read it, and nothing uploads it — the schema's
/// `capture_assets.has_gyro` / Gyroflow path is not built. It is kept because
/// it is cheap to record and impossible to record retroactively; it must not be
/// surfaced to the user as a feature until something consumes it (the "Gyro
/// sidecar" chip on Review & Submit was removed for exactly that reason).
///
/// Also publishes smoothed level + pace values that drive the guidance overlays.
final class MotionRecorder: ObservableObject {
    struct Sample: Codable {
        let t: Double                      // seconds since recording start
        let qw, qx, qy, qz: Double         // attitude quaternion
        let rrx, rry, rrz: Double          // rotation rate (rad/s)
        let gx, gy, gz: Double             // gravity
        let uax, uay, uaz: Double          // user acceleration (g)
    }

    struct Sidecar: Codable {
        let version: Int
        let sampleRateHz: Double
        let videoFile: String
        let fps: Double
        let width: Int
        let height: Int
        let samples: [Sample]
    }

    // Overlay signals (published on main, smoothed)
    @Published var roll: Double = 0        // radians; 0 = level (+ = top of the phone tilted right)
    @Published var pitch: Double = 0       // radians; 0 = upright (− = leaning back)
    @Published var pace: Double = 0        // 0 = still … 1+ = too fast

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    /// Guards samples and segment state shared with the serial motion queue.
    private let lock = NSLock()
    private var samples: [Sample] = []
    private struct Segment {
        let startUptime: TimeInterval
        let joinedOffset: TimeInterval
        let firstSampleIndex: Int
    }
    private var segment: Segment?
    private var finalizedThrough: TimeInterval = 0

    // Smoothing state — motion queue only (`maxConcurrentOperationCount = 1`,
    // so `ingest` is serial). The published values are derived from these.
    private var smoothedRoll: Double = 0
    private var smoothedPitch: Double = 0
    private var smoothedPace: Double = 0
    private var lastPublishUptime: TimeInterval = 0

    /// Device motion arrives at 100 Hz, but publishing at 100 Hz re-rendered the
    /// whole capture overlay (bubble, pace ring, upright banner) a hundred times
    /// a second while the camera was already saturating the GPU. The instruments
    /// look just as live at 30.
    private static let publishInterval: TimeInterval = 1.0 / 30.0

    /// Serial queue owning every sidecar FILE operation. Encoding a 10-minute
    /// take is ~60 000 samples × 13 doubles through JSONEncoder — that ran on
    /// the main thread inside the "recording finished" callback and froze the UI
    /// for seconds right after Stop. Deletes go through the same queue, so a
    /// Retake can never race a write that is still in flight.
    private static let fileQueue = DispatchQueue(label: "com.rendprop.motion.sidecar", qos: .utility)

    func startUpdates() {
        guard manager.isDeviceMotionAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            self.ingest(m)
        }
    }

    func stopUpdates() {
        manager.stopDeviceMotionUpdates()
    }

    private func ingest(_ m: CMDeviceMotion) {
        // Level: with the phone upright in portrait, gravity ≈ (0, -1, 0).
        // Roll = lateral tilt, pitch = forward/back lean.
        let rollValue = atan2(m.gravity.x, -m.gravity.y)
        let pitchValue = atan2(m.gravity.z, -m.gravity.y)

        // Pace: blend of translational + rotational motion magnitude. Rotation
        // is weighted up (whip pans are what hurt the render) and the low-pass
        // is ~0.4 s so footfalls don't flicker the ring (audit F-D-24).
        let accel = sqrt(m.userAcceleration.x * m.userAcceleration.x
                       + m.userAcceleration.y * m.userAcceleration.y
                       + m.userAcceleration.z * m.userAcceleration.z)
        let rot = sqrt(m.rotationRate.x * m.rotationRate.x
                     + m.rotationRate.y * m.rotationRate.y
                     + m.rotationRate.z * m.rotationRate.z)
        let raw = min(2.0, accel * 2.2 + rot * 1.0)
        // Smoothed here (serial motion queue) rather than on main: the filter
        // then always sees every 100 Hz sample, no matter how often we publish.
        smoothedPace = smoothedPace * 0.975 + raw * 0.025
        smoothedRoll = smoothedRoll * 0.85 + rollValue * 0.15
        smoothedPitch = smoothedPitch * 0.85 + pitchValue * 0.15

        lock.lock()
        if let segment {
            let local = m.timestamp - segment.startUptime
            let t = segment.joinedOffset + local
            // A queued sample from before this segment must never be remapped
            // using its new joined offset. Ordered timestamps are an invariant.
            if local >= 0, t.isFinite, t >= (samples.last?.t ?? 0) {
                samples.append(Sample(t: t,
                                      qw: m.attitude.quaternion.w, qx: m.attitude.quaternion.x,
                                      qy: m.attitude.quaternion.y, qz: m.attitude.quaternion.z,
                                      rrx: m.rotationRate.x, rry: m.rotationRate.y, rrz: m.rotationRate.z,
                                      gx: m.gravity.x, gy: m.gravity.y, gz: m.gravity.z,
                                      uax: m.userAcceleration.x, uay: m.userAcceleration.y, uaz: m.userAcceleration.z))
            }
        }
        lock.unlock()

        // Throttle the UI updates (logging above still runs at the full rate).
        guard m.timestamp - lastPublishUptime >= Self.publishInterval else { return }
        lastPublishUptime = m.timestamp
        let r = smoothedRoll, p = smoothedPitch, pace = smoothedPace
        DispatchQueue.main.async {
            self.roll = r
            self.pitch = p
            self.pace = pace
        }
    }

    // MARK: - Recording sync

    /// Reset a fresh take; a segment callback supplies its media-clock anchor.
    func beginLogging() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        segment = nil
        finalizedThrough = 0
        lock.unlock()
    }

    /// The camera estimates frame-zero host time from its recording clock
    /// before dispatching the delegate callback to main. The joined offset is
    /// the sum of finalized file durations, never elapsed wall time or UI taps.
    /// Absolute sensor-to-movie synchronization still needs a device trace.
    func beginSegment(atUptime start: TimeInterval, joinedOffset: TimeInterval) {
        lock.lock()
        if start.isFinite, joinedOffset.isFinite, joinedOffset >= finalizedThrough, segment == nil {
            segment = Segment(startUptime: start, joinedOffset: joinedOffset, firstSampleIndex: samples.count)
        }
        lock.unlock()
    }

    /// Freeze at the actual finalized media duration, including frames written
    /// after Pause/Stop was tapped. Discard samples beyond that file endpoint.
    func finishSegment(duration: TimeInterval) {
        lock.lock()
        if let segment {
            let length = duration.isFinite ? max(0, duration) : 0
            let end = segment.joinedOffset + length
            if segment.firstSampleIndex < samples.count {
                let kept = samples[segment.firstSampleIndex...].filter {
                    $0.t >= segment.joinedOffset && $0.t < end
                }
                samples.replaceSubrange(segment.firstSampleIndex..., with: kept)
            }
            finalizedThrough = end
        }
        segment = nil
        lock.unlock()
    }

    /// Stop logging without writing anything (discarded take).
    func cancelLogging() {
        lock.lock()
        segment = nil
        finalizedThrough = 0
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Stop logging and write `<video>.motion.json` next to the video.
    ///
    /// The encode + write happen on `fileQueue`; this returns the path the file
    /// WILL have. Nothing in the app reads the sidecar back (it exists for the
    /// server-side stabilization path, `capture_assets.has_gyro`), so returning
    /// before the bytes land costs nothing — and it keeps a multi-second
    /// JSONEncoder run off the main thread at the exact moment the user taps
    /// Stop. A failed write simply leaves no file.
    @discardableResult
    func endLogging(besideVideoAt videoURL: URL, fps: Double, width: Int, height: Int) -> URL? {
        lock.lock()
        segment = nil
        // Only measured, completed segments may be persisted. This also makes
        // an early caller fail closed instead of keeping export-time samples.
        let snapshot = samples.filter { $0.t >= 0 && $0.t < finalizedThrough }
        samples.removeAll(keepingCapacity: false)
        finalizedThrough = 0
        lock.unlock()
        return Self.write(snapshot, besideVideoAt: videoURL, fps: fps, width: width, height: height)
    }

    /// A pause checkpoint retains the in-memory take while serializing only
    /// finalized media. Ordered with endLogging/copy/delete on the file queue.
    @discardableResult
    func checkpointLogging(besideVideoAt videoURL: URL, fps: Double, width: Int, height: Int) -> URL? {
        lock.lock()
        let snapshot = samples.filter { $0.t >= 0 && $0.t < finalizedThrough }
        lock.unlock()
        return Self.write(snapshot, besideVideoAt: videoURL, fps: fps, width: width, height: height)
    }

    private static func write(_ snapshot: [Sample], besideVideoAt videoURL: URL,
                              fps: Double, width: Int, height: Int) -> URL? {
        guard !snapshot.isEmpty else { return nil }

        let sidecar = Sidecar(version: 1, sampleRateHz: 100,
                              videoFile: videoURL.lastPathComponent,
                              fps: fps, width: width, height: height,
                              samples: snapshot)
        let url = Self.sidecarURL(for: videoURL)
        Self.fileQueue.async {
            guard let data = try? JSONEncoder().encode(sidecar) else { return }
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    /// Rebind a joined take's aggregate sidecar without deleting its recoverable
    /// source. Awaiting the same file queue includes any checkpoint still writing.
    static func copySidecar(from sourceVideoURL: URL, to destinationVideoURL: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                let source = sidecarURL(for: sourceVideoURL)
                let target = sidecarURL(for: destinationVideoURL)
                do {
                    let original = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: source))
                    let copy = Sidecar(version: original.version, sampleRateHz: original.sampleRateHz,
                                       videoFile: destinationVideoURL.lastPathComponent, fps: original.fps,
                                       width: original.width, height: original.height, samples: original.samples)
                    try JSONEncoder().encode(copy).write(to: target, options: .atomic)
                    continuation.resume(returning: target)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }

    /// `<video>.motion.json` beside the video — the same path `endLogging` writes.
    static func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("motion.json")
    }

    /// Remove a take's sidecar. Ordered behind any in-flight `endLogging` write
    /// on the same serial queue, so a fast Retake cannot leave the file behind.
    static func deleteSidecar(for videoURL: URL) {
        let url = sidecarURL(for: videoURL)
        fileQueue.async { try? FileManager.default.removeItem(at: url) }
    }
}
