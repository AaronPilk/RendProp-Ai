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
    static func canBeginFacingStraightAhead(forwardY: Double) -> Bool { forwardY.isFinite && abs(forwardY) < 0.5 }

    enum GuidanceMode: Equatable { case waiting, aim, returnToPivot, steady, saving, complete }
    enum AimDirection: Equatable {
        case left, right, up, down, centered
        var instruction: String {
            switch self {
            case .left: return "← Turn the phone left"
            case .right: return "Turn the phone right →"
            case .up: return "↑ Tilt the phone up"
            case .down: return "↓ Tilt the phone down"
            case .centered: return "On target — hold still"
            }
        }
    }

    struct Guidance {
        let message: String
        let target: StationCaptureTarget?
        let targetDirection: [Double]?
        let angularErrorDegrees: Double?
        let pivotDriftMeters: Double?
        let readyToCapture: Bool
        let mode: GuidanceMode
        let steadyProgress: Double
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
        func guidance(_ message: String, error: Double? = nil, drift: Double? = nil, capture: Bool = false,
                      mode: GuidanceMode = .waiting, steadyProgress: Double = 0) -> Guidance {
            Guidance(message: message, target: target, targetDirection: direction,
                     angularErrorDegrees: error, pivotDriftMeters: drift, readyToCapture: capture,
                     mode: mode, steadyProgress: steadyProgress)
        }
        ready = false
        guard let target, let direction else { return guidance("All 38 photos saved. Preview this viewpoint before moving.", mode: .complete) }
        guard !writeInFlight else { return guidance("Saving this photo…", mode: .saving) }
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
            steadySince = nil; return guidance("The phone moved away from its starting spot. Bring the lens back; don't walk around the room.", error: angle, drift: drift, mode: .returnToPivot)
        }
        guard angle <= Self.targetToleranceDegrees else {
            steadySince = nil; return guidance(target.index == 0 ? "First photo: point straight ahead. Photos save automatically." : "Keep the lens over the same spot. Follow the arrow, then pause.", error: angle, drift: drift, mode: .aim)
        }
        guard motionBlurAcceptable, let speed = angularSpeedDegreesPerSecond,
              speed.isFinite, speed >= 0, speed <= Self.maximumAngularSpeedDegreesPerSecond else {
            steadySince = nil; return guidance("On target. Stop turning and hold still for the automatic photo.", error: angle, drift: drift, mode: .steady)
        }
        if steadySince == nil { steadySince = timestamp }
        guard timestamp - (steadySince ?? timestamp) >= Self.steadyDurationSeconds else {
            return guidance(drift > 0.05 ? "Hold still. Keep the lens over its starting spot." : "Hold still for the automatic photo…", error: angle, drift: drift,
                            mode: .steady, steadyProgress: min(1, max(0, (timestamp - (steadySince ?? timestamp)) / Self.steadyDurationSeconds)))
        }
        ready = true
        return guidance("Taking photo…", error: angle, drift: drift, capture: true, mode: .steady, steadyProgress: 1)
    }

    /// Capture turns are around gravity, not the phone's changing local axes.
    /// In particular, a floor target behind a ceiling-facing camera requires a
    /// downward tilt; a view-space azimuth alone would incorrectly say "left".
    static func captureAimDirection(cameraToWorld: [[Double]], targetDirection: [Double],
                                    angularErrorDegrees: Double?) -> AimDirection? {
        guard let pose = pose(cameraToWorld), targetDirection.count == 3,
              targetDirection.allSatisfy(\.isFinite) else { return nil }
        let length = sqrt(targetDirection.reduce(0) { $0 + $1 * $1 })
        guard length.isFinite, length > 0.000_001 else { return nil }
        let target = targetDirection.map { $0 / length }
        let cosine = zip(pose.forward, target).reduce(0.0) { $0 + $1.0 * $1.1 }
        let error = angularErrorDegrees ?? acos(min(1, max(-1, cosine))) * 180 / .pi
        guard error.isFinite, error >= 0 else { return nil }
        if error <= targetToleranceDegrees { return .centered }
        let currentHorizontal = hypot(pose.forward[0], pose.forward[2])
        let targetHorizontal = hypot(target[0], target[2])
        let pitchError = atan2(target[1], targetHorizontal) - atan2(pose.forward[1], currentHorizontal)
        // Heading is ill-defined at the poles. First tilt away from/toward the
        // pole, then correct yaw once a horizontal direction is meaningful.
        if currentHorizontal < 0.15 || targetHorizontal < 0.15 {
            return pitchError > 0 ? .up : .down
        }
        let yawDifference = atan2(target[0], -target[2]) - atan2(pose.forward[0], -pose.forward[2])
        let yawError = atan2(sin(yawDifference), cos(yawDifference))
        if abs(pitchError) > abs(yawError) { return pitchError > 0 ? .up : .down }
        if abs(abs(yawError) - .pi) < 0.000_001 { return .left }
        return yawError > 0 ? .right : .left
    }

    /// The input is a direction transformed by ARCamera.viewMatrix for the
    /// displayed orientation (w=0), not a point offset from a drifting station.
    static func aimDirection(viewVector: [Double], angularErrorDegrees: Double?) -> AimDirection? {
        guard viewVector.count == 3, viewVector.allSatisfy(\.isFinite),
              viewVector.reduce(0, { $0 + $1 * $1 }) > 0.000_001 else { return nil }
        let length = sqrt(viewVector.reduce(0, { $0 + $1 * $1 }))
        guard length.isFinite else { return nil }
        let measuredError = acos(min(1, max(-1, -viewVector[2] / length))) * 180 / .pi
        let error = angularErrorDegrees ?? measuredError
        guard error.isFinite, error >= 0 else { return nil }
        if error <= targetToleranceDegrees { return .centered }
        let horizontal = atan2(viewVector[0], -viewVector[2])
        let vertical = atan2(viewVector[1], hypot(viewVector[0], viewVector[2]))
        if abs(vertical) > abs(horizontal) { return vertical > 0 ? .up : .down }
        // Exactly behind is ambiguous; choose the plan's counterclockwise turn.
        if abs(viewVector[0]) < 0.000_001, viewVector[2] >= 0 { return .left }
        return horizontal > 0 ? .right : .left
    }

    /// Screen-aligned translation back to the pivot, separate from turning.
    static func returnInstruction(viewOffset: [Double]) -> String? {
        guard viewOffset.count == 3, viewOffset.allSatisfy(\.isFinite),
              let axis = (0..<3).max(by: { abs(viewOffset[$0]) < abs(viewOffset[$1]) }),
              abs(viewOffset[axis]) > 0.001 else { return nil }
        guard let distance = Int(exactly: ceil(abs(viewOffset[axis]) * 100)) else { return nil }
        let direction: String
        switch axis {
        case 0: direction = viewOffset[0] > 0 ? "right" : "left"
        case 1: direction = viewOffset[1] > 0 ? "up" : "down"
        default: direction = viewOffset[2] < 0 ? "away from you" : "toward you"
        }
        return "Move the phone about \(distance) cm \(direction)"
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
