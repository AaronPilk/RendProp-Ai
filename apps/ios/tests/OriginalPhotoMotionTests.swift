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
            // Small landmarks distinguish an honest center crop from stretching
            // the entire source to fill a differently shaped output.
            UIColor.white.setFill(); ctx.fill(CGRect(x: 41, y: 0, width: 4, height: 64))
            UIColor.cyan.setFill(); ctx.fill(CGRect(x: 0, y: 21, width: 96, height: 4))
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
        // These execute the production UIKit preparation path, rather than the
        // closed UIImage boundary used by the independent request/recovery gate.
        var prepDimensions: [[String: Any]] = []
        for (name, size, expected, aspect) in [
            ("small", CGSize(width: 720, height: 1280), CGSize(width: 720, height: 1280), "9:16"),
            ("available-2K", CGSize(width: 1152, height: 2048), CGSize(width: 1152, height: 2048), "9:16"),
            ("available-HD-wide", CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080), "16:9"),
            ("large", CGSize(width: 2304, height: 4096), CGSize(width: 1152, height: 2048), "9:16")
        ] {
            let generated = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                for stripe in 0..<64 {
                    UIColor(red: CGFloat(stripe % 5) / 5 + 0.1, green: CGFloat(stripe % 7) / 8 + 0.1,
                        blue: CGFloat(stripe % 3) / 4 + 0.1, alpha: 1).setFill()
                    ctx.fill(CGRect(x: CGFloat(stripe) * size.width / 64, y: 0,
                        width: ceil(size.width / 64), height: size.height))
                }
            }
            let stored = generated.jpegData(compressionQuality: 1)!
            let url = root.appendingPathComponent("source-\(name).jpg"); try stored.write(to: url)
            let prepared = try ReelQualityPrep.preparedReelJPEG(photo: EnhancedPhoto(enhancedURL: url), aspect: aspect)
            let decoded = UIImage(data: prepared)!
            if name == "small" {
                check(decoded.size == expected, "small source JPEG is never upscaled to pretend detail")
            } else {
                check(decoded.size == expected, "source JPEG retains the available full-resolution pixels up to 2048")
            }
            let fresh = UIImage(contentsOfFile: url.path)!
            let expectedData = AIImagePrep.downscaled(AIImagePrep.reelSource(fresh, aspect: aspect), maxDimension: 2048).jpegData(compressionQuality: 0.95)!
            check(prepared == expectedData, "source JPEG uses the actual high-quality 0.95 encoder")
            check(CGImageSourceGetType(CGImageSourceCreateWithData(prepared as CFData, nil)!) as String? == "public.jpeg", "conditioning bytes are an actual JPEG")
            check(try Data(contentsOf: url) == stored, "source preparation does not alter the stored photo bytes")
            prepDimensions.append(["name": name, "available_width": Int(size.width), "available_height": Int(size.height),
                "prepared_width": Int(decoded.size.width), "prepared_height": Int(decoded.size.height)])
        }
        let cropSource = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { ctx in
            for (x, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill(); ctx.fill(CGRect(x: x * 400, y: 0, width: 400, height: 1200))
            }
        }
        let cropURL = root.appendingPathComponent("crop-source.jpg")
        let cropStored = cropSource.jpegData(compressionQuality: 1)!; try cropStored.write(to: cropURL)
        let cropPrepared = try ReelQualityPrep.preparedReelJPEG(photo: EnhancedPhoto(enhancedURL: cropURL), aspect: "9:16")
        let cropImage = UIImage(data: cropPrepared)!
        check(cropImage.size == CGSize(width: 675, height: 1200), "source crop uses available pixels without upscaling")
        check(close(pixel(cropImage.cgImage!, x: 30, y: 600), [0, 255, 0]) && close(pixel(cropImage.cgImage!, x: 645, y: 600), [0, 0, 255]), "source JPEG center crop preserves the selected photo geometry")
        check(try Data(contentsOf: cropURL) == cropStored, "center-cropped conditioning keeps the original file unchanged")
        // A deterministic high-detail source makes the former 1.5MB decoded
        // QC ceiling visible. Real encoded bytes are also captured through the
        // production QC serializer by the runner's optional transport gate.
        let detailedWidth = 1152, detailedHeight = 2048
        var random: UInt32 = 0x12345678
        var detailedPixels = [UInt8](repeating: 255, count: detailedWidth * detailedHeight * 4)
        for index in 0..<(detailedWidth * detailedHeight) {
            for component in 0..<3 {
                random = 1664525 &* random &+ 1013904223
                detailedPixels[index * 4 + component] = UInt8(truncatingIfNeeded: random >> 24)
            }
        }
        let detailedProvider = CGDataProvider(data: Data(detailedPixels) as CFData)!
        let detailedCG = CGImage(width: detailedWidth, height: detailedHeight, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: detailedWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: detailedProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let detailedStored = UIImage(cgImage: detailedCG).jpegData(compressionQuality: 1)!
        let detailedURL = root.appendingPathComponent("source-high-detail.jpg")
        try detailedStored.write(to: detailedURL)
        let detailedPrepared = try ReelQualityPrep.preparedReelJPEG(photo: EnhancedPhoto(enhancedURL: detailedURL), aspect: "9:16")
        let detailedB64 = detailedPrepared.base64EncodedString()
        check(UIImage(data: detailedPrepared)!.size == CGSize(width: 1152, height: 2048), "high-detail JPEG keeps the full available 2048 geometry")
        check(detailedB64.count > 2_000_000, "real encoded high-detail JPEG proves the former QC source ceiling was too small")
        check(detailedB64.count <= 12_000_000, "full-quality encoded source fits the generation-aligned source ceiling")
        check(detailedPrepared == AIImagePrep.downscaled(AIImagePrep.reelSource(UIImage(contentsOfFile: detailedURL.path)!, aspect: "9:16"), maxDimension: 2048).jpegData(compressionQuality: 0.95)!, "high-detail source keeps the actual 0.95 JPEG quality")
        check(try Data(contentsOf: detailedURL) == detailedStored, "high-detail source preparation preserves stored bytes")
        try detailedPrepared.write(to: root.appendingPathComponent("source-high-detail-prepared.jpg"))
        if CommandLine.arguments.contains("--prep-only") { print("PASS: \(checks) actual UIKit source-quality assertions"); return }
        let formats = [("wide", CGSize(width: 320, height: 180)), ("portrait", CGSize(width: 180, height: 320)),
            ("fullHD-portrait", CGSize(width: 1080, height: 1920)), ("fullHD-wide", CGSize(width: 1920, height: 1080))]
        for (name, size) in formats {
            let output = root.appendingPathComponent("clip-photo-motion-\(name).mp4")
            try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: output)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            check(abs(duration.seconds - 5) < 0.05, "fallback produces a readable five-second video")
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let natural = try await track.load(.naturalSize)
            check(natural == size, "fallback preserves the selected output shape")
            let ratio = await ReelQualityPrep.reelDisplayAspect(output)
            check(ratio.map { abs($0 - size.width / size.height) < 0.0001 } ?? false, "ready preview measures the actual encoded display aspect")
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var images: [CGImage] = []
            for second in [0.0, 2.5, 4.9] {
                let (frame, _) = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                images.append(frame)
                let w = Int(size.width), h = Int(size.height)
                let edgePoints: [(Int, Int)] = [(1, 1), (w-2, 1), (1, h-2), (w-2, h-2),
                    (1, h/2), (w-2, h/2), (w/2, 1), (w/2, h-2)]
                for (x, y) in edgePoints {
                    check(pixel(frame, x: x, y: y).max()! > 90, "fallback encodes source pixels to every edge without black bars")
                }
                let t = CGFloat(Int(second * 30)) / 149
                let scale = max(size.width / 96, size.height / 64) * (1 + 0.02 * t * t * (3 - 2 * t))
                // Visible source samples remain the same room, without outpaint.
                for (sx, sy) in [(40, 16), (56, 16), (40, 48), (56, 48)] {
                    let x = Int((size.width - 96 * scale) / 2 + CGFloat(sx) * scale)
                    let y = Int((size.height - 64 * scale) / 2 + CGFloat(sy) * scale)
                    check(close(pixel(frame, x: x, y: y), pixel(decodedSource, x: sx, y: sy)), "fallback uses the same selected photo pixels and orientation")
                }
                for (sx, sy) in [(42, 10), (32, 22)] {
                    let x = Int((size.width - 96 * scale) / 2 + CGFloat(sx) * scale)
                    let y = Int((size.height - 64 * scale) / 2 + CGFloat(sy) * scale)
                    check(close(pixel(frame, x: x, y: y), pixel(decodedSource, x: sx, y: sy)), "fallback center crop preserves source geometry without stretching")
                }
            }
            check((images[0].dataProvider!.data! as Data) != (images[2].dataProvider!.data! as Data), "fallback contains deterministic motion inside the source bounds")
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
        // yellow, lower right green. Their displayed shape is center-cropped.
        for (x, y, expected) in [(45, 93, [0, 0, 254]), (135, 93, [254, 0, 0]), (45, 227, [255, 255, 1]), (135, 227, [0, 255, 1])] {
            check(close(pixel(rotationFrame, x: x, y: y), expected), "fallback bakes camera EXIF orientation without changing source geometry")
        }
        for (x, y) in [(1, 1), (178, 1), (1, 318), (178, 318)] {
            check(pixel(rotationFrame, x: x, y: y).max()! > 90, "oriented source fills every output edge with actual photo pixels")
        }
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
        try JSONSerialization.data(withJSONObject: ["assertions": checks, "duration_seconds": 5, "formats": formats.map(\.0),
            "source_preparation": prepDimensions, "conditioning_jpeg_quality": 0.95,
            "high_detail_source": ["jpeg_bytes": detailedPrepared.count, "base64_characters": detailedB64.count,
                "width": 1152, "height": 2048, "sha256": SHA256.hash(data: detailedPrepared).map { String(format: "%02x", $0) }.joined()]], options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("result.json"))
    }
}
