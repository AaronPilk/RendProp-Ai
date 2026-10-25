import Foundation

/// Conservative capture admission, not a claim of geometric room coverage.
/// These are provisional phone-calibration thresholds on a <=160px luma grid.
/// Blank painted walls are low texture, not proof of camera motion: warn there
/// instead of trapping the agent in a room that cannot pass a sharpness test.
struct CaptureQualitySelector {
    static let minimumLaplacianVariance = 24.0
    static let lowTextureVariance = 36.0
    static let minimumTranslationMetres = 0.035
    static let minimumRotationDegrees = 3.0
    static let maximumSampleDimension = 160

    struct Measurement: Equatable {
        let laplacianVariance: Double
        let lumaVariance: Double
        var isValid: Bool {
            laplacianVariance.isFinite && lumaVariance.isFinite && laplacianVariance >= 0 && lumaVariance >= 0
        }
    }
    enum Decision: Equatable {
        case keep(lowTexture: Bool), skipBlur, skipBaseline, invalidPose, invalidImage
    }
    private(set) var lastAcceptedPose: [[Double]]?

    static func measure(luma: [Double], width: Int, height: Int) -> Measurement? {
        guard (3...maximumSampleDimension).contains(width), (3...maximumSampleDimension).contains(height),
              luma.count == width * height, luma.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        var luminanceSum = 0.0, luminanceSquares = 0.0
        var laplacianSum = 0.0, laplacianSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x, center = luma[i]
                let laplacian = luma[i - 1] + luma[i + 1] + luma[i - width] + luma[i + width] - 4 * center
                luminanceSum += center; luminanceSquares += center * center
                laplacianSum += laplacian; laplacianSquares += laplacian * laplacian
                count += 1
            }
        }
        return .init(laplacianVariance: max(0, laplacianSquares / count - pow(laplacianSum / count, 2)),
                     lumaVariance: max(0, luminanceSquares / count - pow(luminanceSum / count, 2)))
    }

    mutating func evaluate(_ measurement: Measurement?, pose: [[Double]]) -> Decision {
        guard Self.validPose(pose) else { return .invalidPose }
        guard let measurement, measurement.isValid else { return .invalidImage }
        let lowTexture = measurement.lumaVariance < Self.lowTextureVariance
        if !lowTexture && measurement.laplacianVariance < Self.minimumLaplacianVariance { return .skipBlur }
        if let previous = lastAcceptedPose {
            let translation = sqrt((0..<3).reduce(0.0) { $0 + pow(pose[$1][3] - previous[$1][3], 2) })
            // trace(R_previous^T * R_current) uses all three axes, so looking
            // up to cover a ceiling is not mistaken for zero angular movement.
            let trace = (0..<3).reduce(0.0) { sum, c in
                sum + (0..<3).reduce(0.0) { $0 + previous[$1][c] * pose[$1][c] }
            }
            let angle = acos(min(1, max(-1, (trace - 1) / 2))) * 180 / .pi
            if translation < Self.minimumTranslationMetres && angle < Self.minimumRotationDegrees { return .skipBaseline }
        }
        lastAcceptedPose = pose
        return .keep(lowTexture: lowTexture)
    }

    private static func validPose(_ m: [[Double]]) -> Bool {
        guard m.count == 4, m.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return false }
        guard zip(m[3], [0.0, 0, 0, 1]).allSatisfy({ abs($0 - $1) < 1e-6 }) else { return false }
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = (0..<3).reduce(0.0) { $0 + m[$1][a] * m[$1][b] }
                if abs(dot - (a == b ? 1 : 0)) >= 0.01 { return false }
            }
        }
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        return abs(det - 1) < 0.01
    }
}
