import Foundation

/// Shared across all positions, including idle preview time. Closing this epoch
/// is terminal; a new recorder/session is required before additional capture.
struct StationCaptureEpochPolicy {
    private(set) var isClosed = false
    private var firstTimestamp: Double?
    private var lastTimestamp: Double?
    mutating func close() { isClosed = true }
    mutating func observe(timestamp: Double, relocalizing: Bool) -> String? {
        guard !isClosed else { return "This camera session has ended. Start a new tour." }
        let reason: String?
        if relocalizing { reason = "Camera tracking restarted. Saved positions are preserved; start a new tour to avoid mixing positions." }
        else if !timestamp.isFinite || timestamp < 0 || (lastTimestamp.map { timestamp < $0 } ?? false) {
            reason = "Camera timing changed. Saved positions are preserved; start a new tour."
        } else if firstTimestamp.map({ timestamp - $0 >= 1800 }) ?? false {
            reason = "The tour reached its 30-minute limit. Saved positions are preserved."
        } else { reason = nil }
        if let reason { isClosed = true; return reason }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        return nil
    }
}

/// Admission only. These versioned, provisional thresholds need physical-phone
/// validation; 38 accepted views are not a claim that stitching has succeeded.
struct StationCapturePolicy {
    static let targetToleranceDegrees = 5.0
    static let steadyDurationSeconds = 0.35
    static let maximumAngularSpeedDegreesPerSecond = 3.0
    static let maximumSampleGapSeconds = 0.15

    struct Guidance {
        let message: String
        let target: StationCaptureTarget?
        let targetDirection: [Double]?
        let angularErrorDegrees: Double?
        let pivotDriftMeters: Double?
        let readyToCapture: Bool
    }

    let origin: [Double]
    let referenceYawDegrees: Double
    let targets: [StationCaptureTarget]
    private(set) var completedCount = 0
    private(set) var writeInFlight = false
    private var steadySince: Double?
    private var previousTimestamp: Double?
    private var ready = false
    var isComplete: Bool { completedCount == targets.count }
    var currentTarget: StationCaptureTarget? { isComplete ? nil : targets[completedCount] }

    init(origin: [Double], referenceYawDegrees: Double, targets: [StationCaptureTarget] = StationCaptureTarget.standard) {
        self.origin = origin; self.referenceYawDegrees = referenceYawDegrees; self.targets = targets
    }

    mutating func evaluate(timestamp: Double, cameraToWorld: [[Double]], normalTracking: Bool,
                           motionBlurAcceptable: Bool, angularSpeedDegreesPerSecond: Double?) -> Guidance {
        let target = currentTarget
        let direction = target?.direction(referenceYawDegrees: referenceYawDegrees)
        func guidance(_ message: String, error: Double? = nil, drift: Double? = nil, capture: Bool = false) -> Guidance {
            Guidance(message: message, target: target, targetDirection: direction,
                     angularErrorDegrees: error, pivotDriftMeters: drift, readyToCapture: capture)
        }
        ready = false
        guard let target, let direction else { return guidance("Position saved. Preview it or move to the next position.") }
        guard !writeInFlight else { return guidance("Saving this photo…") }
        guard timestamp.isFinite, timestamp >= 0, origin.count == 3, origin.allSatisfy(\.isFinite), referenceYawDegrees.isFinite,
              let pose = Self.pose(cameraToWorld) else {
            resetDwell(); return guidance("Waiting for valid camera measurements.")
        }
        if let previousTimestamp, timestamp <= previousTimestamp || timestamp - previousTimestamp > Self.maximumSampleGapSeconds { steadySince = nil }
        previousTimestamp = timestamp
        guard normalTracking else { steadySince = nil; return guidance("Hold still while the camera finds the room.") }
        let drift = sqrt(zip(pose.origin, origin).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) })
        let cosine = zip(pose.forward, direction).reduce(0.0) { $0 + $1.0 * $1.1 }
        let angle = acos(min(1, max(-1, cosine))) * 180 / .pi
        guard drift <= StationCaptureLimits.maximumPivotDriftMeters else {
            steadySince = nil; return guidance("Move the camera back to its starting spot.", error: angle, drift: drift)
        }
        guard angle <= Self.targetToleranceDegrees else {
            steadySince = nil; return guidance(target.instruction + ". Bring the target into the center.", error: angle, drift: drift)
        }
        guard motionBlurAcceptable, let speed = angularSpeedDegreesPerSecond,
              speed.isFinite, speed >= 0, speed <= Self.maximumAngularSpeedDegreesPerSecond else {
            steadySince = nil; return guidance("Hold still on the target.", error: angle, drift: drift)
        }
        if steadySince == nil { steadySince = timestamp }
        guard timestamp - (steadySince ?? timestamp) >= Self.steadyDurationSeconds else {
            return guidance(drift > 0.05 ? "Hold still. Keep the camera close to its starting spot." : "Hold still…", error: angle, drift: drift)
        }
        ready = true
        return guidance("Taking photo…", error: angle, drift: drift, capture: true)
    }

    mutating func beginWrite() -> Bool {
        guard ready, !writeInFlight, !isComplete else { return false }
        writeInFlight = true; ready = false; steadySince = nil
        return true
    }

    @discardableResult
    mutating func finishWrite(targetID: String, succeeded: Bool) -> Bool {
        guard writeInFlight, currentTarget?.id == targetID else { return false }
        writeInFlight = false; resetDwell()
        if succeeded { completedCount += 1 }
        return true
    }

    mutating func resetDwell() { ready = false; steadySince = nil; previousTimestamp = nil }

    static func pose(_ matrix: [[Double]]) -> (origin: [Double], forward: [Double])? {
        guard matrix.count == 4, matrix.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }),
              zip(matrix[3], [0.0, 0, 0, 1]).allSatisfy({ abs($0 - $1) < 1e-6 }) else { return nil }
        for a in 0..<3 { for b in 0..<3 {
            let dot = (0..<3).reduce(0.0) { $0 + matrix[$1][a] * matrix[$1][b] }
            guard abs(dot - (a == b ? 1 : 0)) < 0.01 else { return nil }
        } }
        let determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
            - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
            + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0])
        guard abs(determinant - 1) < 0.01 else { return nil }
        let forward = (0..<3).map { -matrix[$0][2] }
        let norm = sqrt(forward.reduce(0) { $0 + $1 * $1 })
        return ((0..<3).map { matrix[$0][3] }, forward.map { $0 / norm })
    }
}
