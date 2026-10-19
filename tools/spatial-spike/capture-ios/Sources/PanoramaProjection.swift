import Foundation
import simd

/// Rotation-only projection for photographs taken around one camera position.
/// It does not estimate depth, correct parallax, or fill an unobserved direction.
enum PanoramaProjection {
    static func direction(longitude: Double, latitude: Double) -> SIMD3<Double> {
        let horizontal = cos(latitude)
        return SIMD3(sin(longitude) * horizontal, sin(latitude), -cos(longitude) * horizontal)
    }

    static func direction(x: Int, y: Int, width: Int, height: Int,
                          referenceYawRadians: Double = 0) -> SIMD3<Double> {
        let longitude = ((Double(x) + 0.5) / Double(width) * 2 - 1) * .pi + referenceYawRadians
        let latitude = (.pi / 2) - (Double(y) + 0.5) / Double(height) * .pi
        return direction(longitude: longitude, latitude: latitude)
    }

    static func wrappedLongitude(_ value: Double) -> Double {
        let wrapped = (value + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return (wrapped < 0 ? wrapped + 2 * .pi : wrapped) - .pi
    }

    struct Camera {
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Int, height: Int
        let position: SIMD3<Double>
        let coneCosine: Double

        init(cameraToWorld c: [[Double]], intrinsics k: [[Double]], resolution: ImageResolution) throws {
            guard c.count == 4, c.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }),
                  k.count == 3, k.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
                throw CaptureError.invalid("Panorama camera measurements are invalid. Original photos are preserved.")
            }
            guard zip(c[3], [0.0, 0, 0, 1]).allSatisfy({ abs($0 - $1) < 1e-6 }) else {
                throw CaptureError.invalid("Panorama camera transform is not affine.")
            }
            for a in 0..<3 {
                for b in 0..<3 {
                    let dot = (0..<3).reduce(0.0) { $0 + c[$1][a] * c[$1][b] }
                    guard abs(dot - (a == b ? 1 : 0)) < 0.001 else {
                        throw CaptureError.invalid("Panorama camera rotation is not rigid.")
                    }
                }
            }
            let determinant = c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1])
                - c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0])
                + c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0])
            guard abs(determinant - 1) < 0.001 else {
                throw CaptureError.invalid("Panorama camera rotation is reflected.")
            }
            try CaptureRasterLimits.validate(resolution)
            guard resolution.width >= 2, resolution.height >= 2,
                  k[0][0] > 0, k[1][1] > 0,
                  Float(k[0][0]) > 0, Float(k[1][1]) > 0,
                  k[0][0] < 1_000_000, k[1][1] < 1_000_000,
                  k[0][1] == 0, k[1][0] == 0, k[2] == [0, 0, 1],
                  k[0][2] >= 0, k[0][2] < Double(resolution.width),
                  k[1][2] >= 0, k[1][2] < Double(resolution.height) else {
                throw CaptureError.invalid("Panorama calibration is outside the supported native pinhole format.")
            }
            right = SIMD3(Float(c[0][0]), Float(c[1][0]), Float(c[2][0]))
            up = SIMD3(Float(c[0][1]), Float(c[1][1]), Float(c[2][1]))
            forward = SIMD3(-Float(c[0][2]), -Float(c[1][2]), -Float(c[2][2]))
            position = SIMD3(c[0][3], c[1][3], c[2][3])
            fx = Float(k[0][0]); fy = Float(k[1][1]); cx = Float(k[0][2]); cy = Float(k[1][2])
            width = resolution.width; height = resolution.height
            let farX = max(k[0][2], Double(width - 1) - k[0][2]) / k[0][0]
            let farY = max(k[1][2], Double(height - 1) - k[1][2]) / k[1][1]
            // The image rectangle is inside this angular cone. A conservative
            // margin also covers Float rotation roundoff; the final exact
            // projection, not this acceleration bound, decides coverage.
            coneCosine = max(-1, 1 / sqrt(1 + farX * farX + farY * farY) - 0.003)
        }

        func pixel(for direction: SIMD3<Float>) -> SIMD2<Float>? {
            let depth = simd_dot(direction, forward)
            guard depth > 0 else { return nil }
            let u = fx * simd_dot(direction, right) / depth + cx
            let v = cy - fy * simd_dot(direction, up) / depth
            guard u >= 0, v >= 0, u <= Float(width - 1), v <= Float(height - 1) else { return nil }
            return SIMD2(u, v)
        }

        /// Conservative equirectangular row intervals, split at the wrap seam.
        /// Integer ranges may include extra rays; they must never omit a valid ray.
        func columnRanges(latitude: Double, referenceYawRadians: Double, outputWidth: Int) -> [Range<Int>] {
            let f = simd_normalize(SIMD3<Double>(Double(forward.x), Double(forward.y), Double(forward.z)))
            let denominator = cos(latitude) * sqrt(max(0, 1 - f.y * f.y))
            let numerator = coneCosine - sin(latitude) * f.y
            if denominator < 1e-10 { return numerator <= 0 ? [0..<outputWidth] : [] }
            let ratio = numerator / denominator
            if ratio <= -1 { return [0..<outputWidth] }
            if ratio > 1 { return [] }
            let centre = PanoramaProjection.wrappedLongitude(atan2(f.x, -f.z) - referenceYawRadians)
            let halfWidth = acos(max(-1, min(1, ratio))) / (2 * .pi) * Double(outputWidth)
            let centrePixel = (centre + .pi) / (2 * .pi) * Double(outputWidth) - 0.5
            let low = Int(floor(centrePixel - halfWidth)) - 1
            let high = Int(ceil(centrePixel + halfWidth)) + 2
            if high - low >= outputWidth { return [0..<outputWidth] }
            if low < 0 { return [0..<min(outputWidth, high), max(0, low + outputWidth)..<outputWidth] }
            if high > outputWidth { return [low..<outputWidth, 0..<min(outputWidth, high - outputWidth)] }
            return [low..<high]
        }
    }
}
