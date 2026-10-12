import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

@main struct OriginalPhotoMotionTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64), format: format).image { ctx in
            let colors: [UIColor] = [.red, .green, .blue, .yellow]
            for y in 0..<2 { for x in 0..<2 {
                colors[y * 2 + x].setFill()
                ctx.fill(CGRect(x: x * 48, y: y * 32, width: 48, height: 32))
            } }
        }
        let jpeg = source.jpegData(compressionQuality: 1)!
        let input = root.appendingPathComponent("selected-photo.jpg")
        try jpeg.write(to: input)
        let hash = SHA256.hash(data: jpeg)
        func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { ptr in
                let ctx = CGContext(data: ptr.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let index = (y * image.width + x) * 4
            return bytes[index..<index + 3].map(Int.init)
        }
        func close(_ actual: [Int], _ expected: [Int]) -> Bool {
            zip(actual, expected).allSatisfy { abs($0 - $1) < 35 }
        }
        let decodedSource = UIImage(data: jpeg)!.cgImage!
        for (name, size) in [("wide", CGSize(width: 320, height: 180)), ("portrait", CGSize(width: 180, height: 320))] {
            let output = root.appendingPathComponent("clip-photo-motion-\(name).mp4")
            try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: output)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            check(abs(duration.seconds - 5) < 0.05, "fallback produces a readable five-second video")
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let natural = try await track.load(.naturalSize)
            check(natural == size, "fallback preserves the selected output shape")
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var images: [CGImage] = []
            for second in [0.0, 2.5, 4.9] {
                let (frame, _) = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                images.append(frame)
                let fit = min(size.width / 96, size.height / 64)
                // All quadrants remain the same room/source, in the same order.
                for (sx, sy) in [(24, 16), (72, 16), (24, 48), (72, 48)] {
                    let x = Int((size.width - 96 * fit) / 2 + CGFloat(sx) * fit)
                    let y = Int((size.height - 64 * fit) / 2 + CGFloat(sy) * fit)
                    check(close(pixel(frame, x: x, y: y), pixel(decodedSource, x: sx, y: sy)), "fallback uses the same selected photo pixels and orientation")
                }
                let bar = name == "portrait" ? pixel(frame, x: Int(size.width / 2), y: 10)
                                             : pixel(frame, x: 10, y: Int(size.height / 2))
                check(bar.max()! < 20, "fallback aspect fits the source without stretching or inventing geometry")
            }
            check(pixel(images[0], x: Int(size.width / 2), y: name == "portrait" ? 101 : 1) != pixel(images[2], x: Int(size.width / 2), y: name == "portrait" ? 101 : 1), "fallback contains deterministic motion inside the source bounds")
            check(OriginalPhotoMotion.isClip(output), "durable clip name identifies photo motion separately from AI")
            try OriginalPhotoMotion.saveSummary(count: 2, for: output)
            check(OriginalPhotoMotion.summaryCount(for: output) == 2, "original photo motion disclosure persists after reopening")
        }
        // A camera JPEG with EXIF rotation must retain its displayed geometry,
        // rather than being stretched back into the sensor's unrotated shape.
        let rotatedData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(rotatedData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, decodedSource, [kCGImagePropertyOrientation: 6] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "oriented JPEG fixture is valid")
        let oriented = rotatedData as Data
        let rotatedOutput = root.appendingPathComponent("clip-photo-motion-rotated.mp4")
        try await OriginalPhotoMotion.render(jpeg: oriented, renderSize: CGSize(width: 180, height: 320), output: rotatedOutput)
        let rotationGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: rotatedOutput))
        let (rotationFrame, _) = try await rotationGenerator.image(at: CMTime(seconds: 4.9, preferredTimescale: 600))
        // After rotating clockwise: upper left blue, upper right red, lower left
        // yellow, lower right green. Their 2:3 displayed shape has 25px bars.
        for (x, y, expected) in [(45, 93, [0, 0, 254]), (135, 93, [254, 0, 0]), (45, 227, [255, 255, 1]), (135, 227, [0, 255, 1])] {
            check(close(pixel(rotationFrame, x: x, y: y), expected), "fallback bakes camera EXIF orientation without changing source geometry")
        }
        check(pixel(rotationFrame, x: 90, y: 10).max()! < 20 && pixel(rotationFrame, x: 90, y: 40).max()! > 200, "oriented source keeps its displayed aspect ratio")
        let after = try Data(contentsOf: input)
        check(SHA256.hash(data: after) == hash && after == jpeg, "fallback never changes the selected source file")
        let invalid = root.appendingPathComponent("invalid.mp4")
        do { try await OriginalPhotoMotion.render(jpeg: Data("not an image".utf8), renderSize: CGSize(width: 180, height: 320), output: invalid); preconditionFailure("invalid photo cannot produce a fallback") } catch { checks += 1 }
        check(!FileManager.default.fileExists(atPath: invalid.path), "invalid source leaves no publishable output")
        let cancelled = root.appendingPathComponent("cancelled.mp4")
        let task = Task { try await Task.sleep(nanoseconds: 5_000_000); try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: CGSize(width: 180, height: 320), output: cancelled) }
        task.cancel()
        do { try await task.value; preconditionFailure("cancelled rendering must refuse") } catch { check(error is CancellationError, "cancelled fallback preserves cancellation") }
        check(!FileManager.default.fileExists(atPath: cancelled.path), "cancelled fallback cannot become a reel clip")
        print("PASS: \(checks) actual iOS AVFoundation source-photo motion assertions")
        try JSONSerialization.data(withJSONObject: ["assertions": checks, "duration_seconds": 5, "formats": ["wide", "portrait"]], options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("result.json"))
    }
}
