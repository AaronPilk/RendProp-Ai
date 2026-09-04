import CoreMotion
import Foundation

/// 100Hz device-motion logging → `<video>.motion.json` sidecar, time-synced to
/// the recording clock (logging starts from the movie output's
/// `didStartRecordingTo` callback, so t=0 is the first written frame).
/// The sidecar is kept for the server-side stabilization path (master spec
/// 4.2/6.2); the on-device engine does not read it yet.
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
    /// Guards everything the motion queue and the main thread both touch:
    /// `samples`, `isLogging`, `startUptime` (audit F-D-10: unlocked reads).
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
        smoothedPace = smoothedPace * 0.975 + raw * 0.025

        lock.lock()
        if isLogging {
            let t = m.timestamp - startUptime
            if t >= 0 {
                samples.append(Sample(t: t,
                                      qw: m.attitude.quaternion.w, qx: m.attitude.quaternion.x,
                                      qy: m.attitude.quaternion.y, qz: m.attitude.quaternion.z,
                                      rrx: m.rotationRate.x, rry: m.rotationRate.y, rrz: m.rotationRate.z,
                                      gx: m.gravity.x, gy: m.gravity.y, gz: m.gravity.z,
                                      uax: m.userAcceleration.x, uay: m.userAcceleration.y, uaz: m.userAcceleration.z))
            }
        }
        lock.unlock()

        let pace = smoothedPace
        DispatchQueue.main.async {
            self.roll = self.roll * 0.85 + rollValue * 0.15
            self.pitch = self.pitch * 0.85 + pitchValue * 0.15
            self.pace = pace
        }
    }

    // MARK: - Recording sync

    /// Call when the movie output reports its first written frame.
    /// CMDeviceMotion.timestamp is on the same uptime clock as
    /// ProcessInfo.systemUptime, so samples align to the movie's start within a
    /// frame.
    func beginLogging() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        startUptime = now
        isLogging = true
        lock.unlock()
    }

    /// Stop logging without writing anything (discarded take).
    func cancelLogging() {
        lock.lock()
        isLogging = false
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Stop logging and write `<video>.motion.json` next to the video.
    @discardableResult
    func endLogging(besideVideoAt videoURL: URL, fps: Double, width: Int, height: Int) -> URL? {
        lock.lock()
        isLogging = false
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        let sidecar = Sidecar(version: 1, sampleRateHz: 100,
                              videoFile: videoURL.lastPathComponent,
                              fps: fps, width: width, height: height,
                              samples: snapshot)
        let url = Self.sidecarURL(for: videoURL)
        do {
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// `<video>.motion.json` beside the video — the same path `endLogging` writes.
    static func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("motion.json")
    }
}
