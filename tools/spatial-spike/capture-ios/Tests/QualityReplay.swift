import Foundation
import CoreVideo
import CoreGraphics
import ImageIO

/// Read-only calibration aid. A saved JPEG cannot recover ARKit's original Y
/// plane; ImageIO decodes its pixels into native-resolution grayscale first.
/// Selection and box sampling are the actual production code, not a Python
/// approximation. This replay is not a camera or reconstruction acceptance test.
@main enum QualityReplay {
    struct Manifest: Decodable { let frames: [String] }
    struct Frame: Decodable { let image: String; let camera_to_world: [[Double]] }
    enum Failure: Error { case input, jpeg, pixelBuffer, imageContext, sample, allRejected }

    static func measurement(_ url: URL) throws -> CaptureQualitySelector.Measurement {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
              image.width <= 8192, image.height <= 8192,
              image.width * image.height <= 16_000_000 else { throw Failure.jpeg }
        var optional: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &optional) == kCVReturnSuccess,
              let buffer = optional else { throw Failure.pixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let context = CGContext(data: base, width: image.width, height: image.height,
                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw Failure.imageContext }
            // No EXIF transform, thumbnail, JPEG rewrite or pose transform.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard let measured = CapturedQualityBridge.measure(buffer) else { throw Failure.sample }
        return measured
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.input }
        let capture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: capture.appendingPathComponent("manifest.json")))
        guard (20...400).contains(manifest.frames.count) else { throw Failure.input }
        var selector = CaptureQualitySelector()
        var counts = ["accepted": 0, "blur": 0, "baseline": 0, "low_texture_accepted": 0, "invalid_pose": 0, "invalid_image": 0]
        var laplacians = [Double](), variances = [Double]()
        for relative in manifest.frames {
            guard relative.range(of: #"^frames/[0-9]{6}\.json$"#, options: .regularExpression) != nil else { throw Failure.input }
            let frame = try decoder.decode(Frame.self, from: Data(contentsOf: capture.appendingPathComponent(relative)))
            guard frame.image.range(of: #"^images/[0-9]{6}\.jpg$"#, options: .regularExpression) != nil else { throw Failure.input }
            try autoreleasepool {
                let measured = try measurement(capture.appendingPathComponent(frame.image))
                laplacians.append(measured.laplacianVariance); variances.append(measured.lumaVariance)
                switch selector.evaluate(measured, pose: frame.camera_to_world) {
                case .keep(let lowTexture): counts["accepted", default: 0] += 1; if lowTexture { counts["low_texture_accepted", default: 0] += 1 }
                case .skipBlur: counts["blur", default: 0] += 1
                case .skipBaseline: counts["baseline", default: 0] += 1
                case .invalidPose: counts["invalid_pose", default: 0] += 1
                case .invalidImage: counts["invalid_image", default: 0] += 1
                }
            }
        }
        guard counts["accepted", default: 0] > 0 else { throw Failure.allRejected }
        func percentiles(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["p05": sorted[Int(Double(sorted.count - 1) * 0.05)], "p50": sorted[sorted.count / 2], "p95": sorted[Int(Double(sorted.count - 1) * 0.95)]]
        }
        let result: [String: Any] = ["frames": manifest.frames.count, "decisions": counts,
            "laplacian_variance": percentiles(laplacians), "luma_variance": percentiles(variances),
            "source": "JPEG decoded grayscale; original AR luma unavailable",
            "production_code": "CaptureQualitySelector and extracted CaptureRecorder.qualityMeasurement",
            "camera_acceptance": false, "reconstruction_acceptance": false]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); print("")
    }
}
