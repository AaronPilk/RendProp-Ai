import Foundation

@main enum QualityChecks {
    struct Failure: Error { let reason: String }
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        count += 1
        if !condition() { throw Failure(reason: message) }
    }
    static func pose(x: Double = 0, yaw: Double = 0, pitch: Double = 0) -> [[Double]] {
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        return [[cos(y), sin(y) * sin(p), sin(y) * cos(p), x],
                [0, cos(p), -sin(p), 0], [-sin(y), cos(y) * sin(p), cos(y) * cos(p), 0], [0, 0, 0, 1]]
    }
    static func main() throws {
        let width = 64, height = 64
        let sharp: [Double] = (0..<(width * height)).map { i in ((i / width) / 4 + (i % width) / 4) % 2 == 0 ? 40 : 210 }
        let smooth: [Double] = (0..<(width * height)).map { i in 30 + Double(i % width) * 2.5 }
        let plain = Array(repeating: 120.0, count: width * height)
        let sharpScore = CaptureQualitySelector.measure(luma: sharp, width: width, height: height)!
        let blurScore = CaptureQualitySelector.measure(luma: smooth, width: width, height: height)!
        let plainScore = CaptureQualitySelector.measure(luma: plain, width: width, height: height)!
        // This is an actual convolution of a sharp fixture, not merely a low
        // score supplied to the selector and labelled "blurred" by the test.
        var convolved: [Double] = (0..<(width * height)).map { i in ((i / width) / 16 + (i % width) / 16) % 2 == 0 ? 40 : 210 }
        let beforeConvolution = CaptureQualitySelector.measure(luma: convolved, width: width, height: height)!
        for _ in 0..<20 {
            var next = convolved
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let sy = min(height - 1, max(0, y + dy)), sx = min(width - 1, max(0, x + dx))
                            sum += convolved[sy * width + sx] * Double((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1))
                        }
                    }
                    next[y * width + x] = sum / 16
                }
            }
            convolved = next
        }
        let afterConvolution = CaptureQualitySelector.measure(luma: convolved, width: width, height: height)!
        try check(beforeConvolution.laplacianVariance > 24, "Original convolution fixture was sharp")
        try check(afterConvolution.laplacianVariance < 24 && afterConvolution.lumaVariance > 36,
                  "Convolution lowered sharpness without converting the fixture to plain low texture")
        try check(sharpScore.laplacianVariance > 24 && sharpScore.lumaVariance > 36, "Sharp synthetic texture should pass")
        try check(blurScore.laplacianVariance < 24 && blurScore.lumaVariance > 36, "Smooth high-contrast blur fixture must be distinguishable from plain walls")
        try check(plainScore.laplacianVariance == 0 && plainScore.lumaVariance == 0, "Plain wall is low texture")
        var selector = CaptureQualitySelector()
        try check(selector.evaluate(sharpScore, pose: pose()) == .keep(lowTexture: false), "First sharp frame admitted")
        try check(selector.evaluate(sharpScore, pose: pose()) == .skipBaseline, "Stationary duplicate must be skipped")
        try check(selector.evaluate(sharpScore, pose: pose(x: 0.02)) == .skipBaseline, "Tiny translation must be skipped")
        try check(selector.evaluate(sharpScore, pose: pose(x: 0.04)) == .keep(lowTexture: false), "Useful translational baseline admitted")
        try check(selector.evaluate(blurScore, pose: pose(x: 0.2)) == .skipBlur, "Blurred frame must be skipped before advancing baseline")
        try check(selector.lastAcceptedPose == pose(x: 0.04), "Rejected blur must not move last accepted pose")
        try check(selector.evaluate(afterConvolution, pose: pose(x: 0.2)) == .skipBlur, "Real convolved blur is rejected")
        try check(selector.evaluate(sharpScore, pose: pose(x: 0.08)) == .keep(lowTexture: false), "Sharp follow-up compares against kept pose")
        selector = CaptureQualitySelector()
        try check(selector.evaluate(plainScore, pose: pose()) == .keep(lowTexture: true), "Plain wall warns instead of trapping capture")
        try check(selector.evaluate(plainScore, pose: pose()) == .skipBaseline, "Plain wall does not bypass motion diversity")
        try check(selector.evaluate(plainScore, pose: pose(yaw: 4)) == .keep(lowTexture: true), "Meaningful yaw accepted")
        selector = CaptureQualitySelector()
        _ = selector.evaluate(sharpScore, pose: pose())
        try check(selector.evaluate(sharpScore, pose: pose(pitch: 4)) == .keep(lowTexture: false), "Ceiling pitch is angular coverage, not zero motion")
        for matrix in [[], [[0.0]], [[Double.nan,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
                       [[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,0]],
                       [[-1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
                       [[2.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]] {
            try check(selector.evaluate(sharpScore, pose: matrix) == .invalidPose, "Non-finite, reflected or degenerate pose rejected")
        }
        try check(selector.evaluate(.init(laplacianVariance: .nan, lumaVariance: 50), pose: pose(x: 1)) == .invalidImage, "NaN sharpness rejected")
        try check(selector.evaluate(.init(laplacianVariance: -1, lumaVariance: 50), pose: pose(x: 1)) == .invalidImage, "Negative sharpness rejected")
        try check(selector.evaluate(nil, pose: pose(x: 1)) == .invalidImage, "Missing measurement rejected")
        try check(CaptureQualitySelector.measure(luma: [0, 1], width: 1, height: 2) == nil, "Degenerate raster rejected")
        try check(CaptureQualitySelector.measure(luma: plain, width: 64, height: 63) == nil, "Wrong byte count rejected")
        var invalid = plain; invalid[0] = .infinity
        try check(CaptureQualitySelector.measure(luma: invalid, width: 64, height: 64) == nil, "Infinite sample rejected")
        invalid[0] = 256
        try check(CaptureQualitySelector.measure(luma: invalid, width: 64, height: 64) == nil, "Unnormalized 8-bit sample rejected")
        // 0° and 360° are the same rotation; acos input is clamped against only
        // floating round-off, never used to repair an invalid input transform.
        selector = CaptureQualitySelector(); _ = selector.evaluate(sharpScore, pose: pose())
        try check(selector.evaluate(sharpScore, pose: pose(yaw: 360)) == .skipBaseline, "Full rotation identity is not a new viewpoint")
        print("PASS QualityChecks \(count) assertions")
    }
}
