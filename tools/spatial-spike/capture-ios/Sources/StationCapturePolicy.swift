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
    static let maximumSteadyCameraSpanMetres = 0.025
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

    private(set) var origin: [Double]
    private(set) var referenceYawDegrees: Double
    let targets: [StationCaptureTarget]
    let profile: StationCaptureGeometryProfile
    private(set) var isAnchored: Bool
    private(set) var completedCount = 0
    private(set) var writeInFlight = false
    private var steadySince: Double?
    private var previousTimestamp: Double?
    private var ready = false
    private var steadyPositions: [[Double]] = []
    private var acceptedPositions: [[Double]] = []
    private var pendingWritePosition: [Double]?
    private var pendingAnchor: (origin: [Double], referenceYaw: Double)?
    private var geometryRejectionSince: Double?
    var isComplete: Bool { completedCount == targets.count }
    var currentTarget: StationCaptureTarget? { isComplete ? nil : targets[completedCount] }

    init(origin: [Double], referenceYawDegrees: Double, targets: [StationCaptureTarget]? = nil,
         profile: StationCaptureGeometryProfile = .legacyPivotV1, anchorAtFirstPhoto: Bool = false) {
        self.origin = origin; self.referenceYawDegrees = referenceYawDegrees; self.targets = targets ?? profile.targets
        self.profile = profile; self.isAnchored = !anchorAtFirstPhoto
    }

    mutating func evaluate(timestamp: Double, cameraToWorld: [[Double]], normalTracking: Bool,
                           motionBlurAcceptable: Bool, angularSpeedDegreesPerSecond: Double?,
                           intrinsics: [[Double]]? = nil, resolution: ImageResolution? = nil) -> Guidance {
        let target = currentTarget
        var direction = target?.direction(referenceYawDegrees: referenceYawDegrees)
        func guidance(_ message: String, error: Double? = nil, drift: Double? = nil, capture: Bool = false,
                      mode: GuidanceMode = .waiting, steadyProgress: Double = 0) -> Guidance {
            Guidance(message: message, target: target, targetDirection: direction,
                     angularErrorDegrees: error, pivotDriftMeters: drift, readyToCapture: capture,
                     mode: mode, steadyProgress: steadyProgress)
        }
        ready = false; pendingAnchor = nil
        guard let target, let initialDirection = direction else { return guidance("All 38 photos saved. Preview this viewpoint before moving.", mode: .complete) }
        guard !writeInFlight else { return guidance("Saving this photo…", mode: .saving) }
        guard timestamp.isFinite, timestamp >= 0, origin.count == 3, origin.allSatisfy(\.isFinite), referenceYawDegrees.isFinite,
              let pose = Self.pose(cameraToWorld) else {
            resetDwell(); return guidance("Waiting for valid camera measurements.")
        }
        if let previousTimestamp, timestamp <= previousTimestamp || timestamp - previousTimestamp > Self.maximumSampleGapSeconds {
            clearSteadyInterval(); geometryRejectionSince = nil
        }
        previousTimestamp = timestamp
        guard normalTracking else { clearSteadyInterval(); geometryRejectionSince = nil; return guidance("Hold still while the camera finds the room.") }
        var drift = isAnchored ? Self.distance(pose.origin, origin) : 0
        let span = acceptedPositions.map { Self.distance(pose.origin, $0) }.max() ?? 0
        let cosine = zip(pose.forward, initialDirection).reduce(0.0) { $0 + $1.0 * $1.1 }
        var angle = acos(min(1, max(-1, cosine))) * 180 / .pi
        guard drift <= profile.maximumPivotDriftMetres,
              profile != .handheldV2 || span <= profile.maximumCameraSpanMetres else {
            clearSteadyInterval()
            if geometryRejectionSince == nil { geometryRejectionSince = timestamp }
            // Reject every out-of-bounds frame immediately. A brief tracking
            // fluctuation gets a steady cue before asking the person to move.
            let transient = profile == .handheldV2 && timestamp - (geometryRejectionSince ?? timestamp) < Self.steadyDurationSeconds
            return guidance(transient ? "Stay where you are. Hold the phone steady while this viewpoint settles."
                            : "Stay at this viewpoint. Bring the phone back toward its starting place, then hold still.",
                            error: angle, drift: drift, mode: transient ? .steady : .returnToPivot)
        }
        geometryRejectionSince = nil
        guard angle <= Self.targetToleranceDegrees else {
            clearSteadyInterval(); return guidance(target.index == 0 ? "First photo: point straight ahead, then hold still. Photos save automatically." : "Stay where you are. Turn to look at the next part of the room, then hold still.", error: angle, drift: drift, mode: .aim)
        }
        if profile == .handheldV2, !Self.poleIsPhotographed(target: target, cameraToWorld: cameraToWorld,
                                                         intrinsics: intrinsics, resolution: resolution) {
            clearSteadyInterval()
            return guidance("The \(target.phaseTitle.lowercased()) must be inside the photo. Tilt the phone toward it while keeping your body upright.",
                            error: angle, drift: drift, mode: .aim)
        }
        guard motionBlurAcceptable, let speed = angularSpeedDegreesPerSecond,
              speed.isFinite, speed >= 0, speed <= Self.maximumAngularSpeedDegreesPerSecond else {
            clearSteadyInterval(); return guidance("On target. Stop turning and hold still for the automatic photo.", error: angle, drift: drift, mode: .steady)
        }
        if steadyPositions.contains(where: { Self.distance($0, pose.origin) > Self.maximumSteadyCameraSpanMetres }) {
            clearSteadyInterval()
        }
        if steadySince == nil { steadySince = timestamp }
        steadyPositions.append(pose.origin)
        guard timestamp - (steadySince ?? timestamp) >= Self.steadyDurationSeconds else {
            return guidance(isAnchored ? "Hold still for the automatic photo…" : "Hold still. Setting your viewpoint with the first photo…", error: angle, drift: drift,
                            mode: .steady, steadyProgress: min(1, max(0, (timestamp - (steadySince ?? timestamp)) / Self.steadyDurationSeconds)))
        }
        if !isAnchored {
            // Only a fully admitted, still first photo establishes the origin.
            // Once established it never follows later phone movement.
            let reference = atan2(pose.forward[0], -pose.forward[2]) * 180 / .pi - target.yaw_degrees
            pendingAnchor = (pose.origin, reference)
            direction = target.direction(referenceYawDegrees: reference)
            let anchoredCosine = zip(pose.forward, direction ?? initialDirection).reduce(0.0) { $0 + $1.0 * $1.1 }
            angle = acos(min(1, max(-1, anchoredCosine))) * 180 / .pi
            drift = 0
        }
        pendingWritePosition = pose.origin
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

    /// Coarse recovery deliberately avoids changing axis/centimeter commands as
    /// the person turns or tilts the phone to follow a photograph target.
    static func returnInstruction(viewOffset: [Double]) -> String? {
        guard viewOffset.count == 3, viewOffset.allSatisfy(\.isFinite),
              (viewOffset.map(abs).max() ?? 0) > 0.001,
              viewOffset.reduce(0, { $0 + $1 * $1 }).isFinite else { return nil }
        return "Stay at this viewpoint. Bring the phone back toward its starting place."
    }

    mutating func beginWrite() -> Bool {
        guard ready, pendingWritePosition != nil, !writeInFlight, !isComplete else { return false }
        if let pendingAnchor {
            origin = pendingAnchor.origin; referenceYawDegrees = pendingAnchor.referenceYaw
            isAnchored = true; self.pendingAnchor = nil
        }
        writeInFlight = true; ready = false; clearSteadyInterval()
        return true
    }

    @discardableResult
    mutating func finishWrite(targetID: String, succeeded: Bool) -> Bool {
        guard writeInFlight, currentTarget?.id == targetID else { return false }
        writeInFlight = false
        if succeeded, let position = pendingWritePosition { acceptedPositions.append(position); completedCount += 1 }
        pendingWritePosition = nil; resetDwell()
        return true
    }

    private mutating func clearSteadyInterval() { steadySince = nil; steadyPositions.removeAll(keepingCapacity: true) }
    mutating func resetDwell() { ready = false; clearSteadyInterval(); previousTimestamp = nil; pendingAnchor = nil }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) })
    }

    /// Project the actual gravity pole into the native sensor raster, matching
    /// the preview's pinhole convention. An image-edge margin keeps a clipped
    /// pole from masquerading as complete ceiling/floor coverage.
    static func poleIsPhotographed(target: StationCaptureTarget, cameraToWorld c: [[Double]],
                                   intrinsics k: [[Double]]?, resolution: ImageResolution?) -> Bool {
        guard target.id == "ceiling" || target.id == "floor" else { return true }
        guard pose(c) != nil, let k, let resolution,
              k.count == 3, k.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              resolution.width >= 2, resolution.height >= 2,
              (try? CaptureRasterLimits.validate(resolution)) != nil,
              k[0][0] > 0, k[1][1] > 0, k[0][0] < 1_000_000, k[1][1] < 1_000_000,
              k[0][1] == 0, k[1][0] == 0, k[2] == [0, 0, 1],
              k[0][2] >= 0, k[0][2] < Double(resolution.width),
              k[1][2] >= 0, k[1][2] < Double(resolution.height) else { return false }
        let sign = target.id == "ceiling" ? 1.0 : -1.0
        let depth = -sign * c[1][2]
        guard depth.isFinite, depth > 0 else { return false }
        let u = k[0][0] * sign * c[1][0] / depth + k[0][2]
        let v = k[1][2] - k[1][1] * sign * c[1][1] / depth
        let maxX = Double(resolution.width - 1), maxY = Double(resolution.height - 1)
        return u.isFinite && v.isFinite && (maxX * 0.08...maxX * 0.92).contains(u)
            && (maxY * 0.08...maxY * 0.92).contains(v)
    }

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
