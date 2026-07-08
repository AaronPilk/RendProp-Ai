import CoreMotion
import Foundation

/// 100Hz device-motion logging → `<video>.motion.json` sidecar, time-synced to
/// the recording clock. This is the #1 output-quality lever: it enables
/// Gyroflow-grade sub-pixel stabilization server-side (master spec 4.2/6.2).
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
    @Published var roll: Double = 0        // radians; 0 = level
    @Published var pitch: Double = 0       // radians; 0 = upright
    @Published var pace: Double = 0        // 0 = still … 1+ = too fast

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var isLogging = false
    private var startUptime: TimeInterval = 0
    private var smoothedPace: Double = 0

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

        // Pace: blend of translational + rotational motion magnitude.
        let accel = sqrt(m.userAcceleration.x * m.userAcceleration.x
                       + m.userAcceleration.y * m.userAcceleration.y
                       + m.userAcceleration.z * m.userAcceleration.z)
        let rot = sqrt(m.rotationRate.x * m.rotationRate.x
                     + m.rotationRate.y * m.rotationRate.y
                     + m.rotationRate.z * m.rotationRate.z)
        let raw = min(2.0, accel * 3.0 + rot * 0.8)
        smoothedPace = smoothedPace * 0.92 + raw * 0.08

        if isLogging {
            let t = m.timestamp - startUptime
            let s = Sample(t: t,
                           qw: m.attitude.quaternion.w, qx: m.attitude.quaternion.x,
                           qy: m.attitude.quaternion.y, qz: m.attitude.quaternion.z,
                           rrx: m.rotationRate.x, rry: m.rotationRate.y, rrz: m.rotationRate.z,
                           gx: m.gravity.x, gy: m.gravity.y, gz: m.gravity.z,
                           uax: m.userAcceleration.x, uay: m.userAcceleration.y, uaz: m.userAcceleration.z)
            lock.lock()
            samples.append(s)
            lock.unlock()
        }

        let pace = smoothedPace
        DispatchQueue.main.async {
            self.roll = self.roll * 0.85 + rollValue * 0.15
            self.pitch = self.pitch * 0.85 + pitchValue * 0.15
            self.pace = pace
        }
    }

    // MARK: - Recording sync

    /// Call at the exact moment recording starts. CMDeviceMotion.timestamp is
    /// on the same uptime clock as ProcessInfo.systemUptime, so samples align
    /// to the movie's start within a frame.
    func beginLogging() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        startUptime = ProcessInfo.processInfo.systemUptime
        isLogging = true
    }

    /// Stop logging and write `<video>.motion.json` next to the video.
    @discardableResult
    func endLogging(besideVideoAt videoURL: URL, fps: Double, width: Int, height: Int) -> URL? {
        isLogging = false
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        let sidecar = Sidecar(version: 1, sampleRateHz: 100,
                              videoFile: videoURL.lastPathComponent,
                              fps: fps, width: width, height: height,
                              samples: snapshot)
        let url = videoURL.deletingPathExtension().appendingPathExtension("motion.json")
        do {
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
