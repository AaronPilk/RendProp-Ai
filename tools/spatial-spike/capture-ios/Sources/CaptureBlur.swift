import Foundation
import simd

/// Rotational motion-blur prediction from two consecutive ARKit camera poses.
///
/// Pure value types only: no UIKit or ARKit. Motion blur is a plausible capture
/// limitation, not a proven explanation of reconstruction failures. This
/// provisional estimator predicts rotational smear from consecutive poses:
/// smear_px = fx * radians(omega_deg_s * exposure_s). Translation blur and
/// rolling shutter are not modelled; the prediction is a first-order guide.
struct CaptureBlurEstimate: Equatable {
    let angularSpeedDegreesPerSecond: Double
    let predictedSmearPixels: Double
}

enum CaptureBlurVerdict: Equatable {
    case ok
    case unavailable
    /// Smear at or above the warn threshold with a short exposure: slow down.
    case tooFast(skip: Bool)
    /// Smear at or above the warn threshold while the camera meters at 1/60 s
    /// or longer: the room needs more light (or an even slower pan).
    case tooDark(skip: Bool)

    var skipsFrame: Bool {
        switch self {
        case .ok: return false
        case .unavailable: return true
        case .tooFast(let skip), .tooDark(let skip): return skip
        }
    }
    var hint: String? {
        switch self {
        case .ok: return nil
        case .unavailable: return "Hold steady while camera motion and exposure become available."
        case .tooFast: return "Slow down. Pan the phone more slowly so photos are not smeared."
        case .tooDark: return "More light. Turn on lamps or open blinds, and pan more slowly."
        }
    }
}

struct CaptureBlurEstimator {
    static let warnSmearPixels = 3.0
    static let skipSmearPixels = 4.0
    static let longExposureSeconds = 1.0 / 60.0
    static let maximumSampleIntervalSeconds = 0.1

    /// Geodesic angle (degrees) between the rotation parts of two camera-to-world
    /// transforms, or nil when either is not a finite rigid rotation.
    static func rotationAngleDegrees(_ previous: simd_float4x4, _ current: simd_float4x4) -> Double? {
        guard let a = rotation(previous), let b = rotation(current) else { return nil }
        // Relative rotation M = Ra^T Rb in Double. atan2 of the antisymmetric
        // part against the trace stays accurate for the sub-degree angles seen
        // between consecutive ARFrames, where acos(trace) alone loses precision.
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 { m[i][j] = (0..<3).reduce(0.0) { $0 + a[i][$1] * b[j][$1] } }
        }
        let cosine = (m[0][0] + m[1][1] + m[2][2] - 1.0) / 2.0
        let axis = [m[2][1] - m[1][2], m[0][2] - m[2][0], m[1][0] - m[0][1]]
        let sine = sqrt(axis.reduce(0.0) { $0 + $1 * $1 }) / 2.0
        return atan2(sine, cosine) * 180.0 / .pi
    }

    static func angularSpeedDegreesPerSecond(previous: simd_float4x4, current: simd_float4x4,
                                             previousTimestamp: TimeInterval, currentTimestamp: TimeInterval) -> Double? {
        guard previousTimestamp.isFinite, currentTimestamp.isFinite else { return nil }
        let interval = currentTimestamp - previousTimestamp
        guard interval > 0, interval <= maximumSampleIntervalSeconds, interval.isFinite,
              let angle = rotationAngleDegrees(previous, current) else { return nil }
        let speed = angle / interval
        return speed.isFinite ? speed : nil
    }

    static func predictedSmearPixels(angularSpeedDegreesPerSecond: Double, exposureDuration: TimeInterval, fx: Float) -> Double? {
        let focal = Double(fx)
        guard angularSpeedDegreesPerSecond.isFinite, angularSpeedDegreesPerSecond >= 0,
              exposureDuration.isFinite, exposureDuration > 0, exposureDuration < 1,
              focal.isFinite, focal > 0 else { return nil }
        let smear = focal * (angularSpeedDegreesPerSecond * exposureDuration) * .pi / 180.0
        return smear.isFinite ? smear : nil
    }

    static func estimate(previous: simd_float4x4, current: simd_float4x4,
                         previousTimestamp: TimeInterval, currentTimestamp: TimeInterval,
                         exposureDuration: TimeInterval, fx: Float) -> CaptureBlurEstimate? {
        guard let speed = angularSpeedDegreesPerSecond(previous: previous, current: current,
                                                       previousTimestamp: previousTimestamp, currentTimestamp: currentTimestamp),
              let smear = predictedSmearPixels(angularSpeedDegreesPerSecond: speed, exposureDuration: exposureDuration, fx: fx)
        else { return nil }
        return CaptureBlurEstimate(angularSpeedDegreesPerSecond: speed, predictedSmearPixels: smear)
    }

    static func verdict(for estimate: CaptureBlurEstimate?, exposureDuration: TimeInterval) -> CaptureBlurVerdict {
        guard let estimate, exposureDuration.isFinite, exposureDuration > 0, exposureDuration < 1,
              estimate.angularSpeedDegreesPerSecond.isFinite, estimate.angularSpeedDegreesPerSecond >= 0,
              estimate.predictedSmearPixels.isFinite, estimate.predictedSmearPixels >= 0 else { return .unavailable }
        let smear = estimate.predictedSmearPixels
        guard smear.isFinite, smear >= warnSmearPixels else { return .ok }
        let skip = smear >= skipSmearPixels
        // Float32 exposure from ARCamera can land a hair under 1/60; treat that as 1/60.
        if exposureDuration.isFinite, exposureDuration >= longExposureSeconds - 1e-9 { return .tooDark(skip: skip) }
        return .tooFast(skip: skip)
    }

    static var manifestThresholds: [String: Double] {
        ["warn_smear_px": warnSmearPixels, "skip_smear_px": skipSmearPixels,
         "long_exposure_seconds": longExposureSeconds, "maximum_sample_interval_seconds": maximumSampleIntervalSeconds]
    }

    private static func rotation(_ transform: simd_float4x4) -> [[Double]]? {
        var columns: [[Double]] = []
        for column in 0..<3 {
            let values = [Double(transform[column][0]), Double(transform[column][1]), Double(transform[column][2])]
            guard values.allSatisfy(\.isFinite) else { return nil }
            columns.append(values)
        }
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + columns[a][$1] * columns[b][$1] }
                if abs(dot - (a == b ? 1 : 0)) >= 0.01 { return nil }
            }
        }
        let a = columns[0], b = columns[1], c = columns[2]
        let determinant = a[0] * (b[1] * c[2] - b[2] * c[1])
            - b[0] * (a[1] * c[2] - a[2] * c[1])
            + c[0] * (a[1] * b[2] - a[2] * b[1])
        guard abs(determinant - 1) < 0.01 else { return nil }
        return columns
    }
}
