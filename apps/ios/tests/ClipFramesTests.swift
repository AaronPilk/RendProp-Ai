import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import UIKit

@main struct ClipFramesTests {
    @MainActor static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64,
        ])
        precondition(writer.canAdd(input), "synthetic video writer accepts its input")
        writer.add(input)
        precondition(writer.startWriting(), "synthetic video writer starts")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let until = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < until else { throw NSError(domain: "clip-fixture", code: 1) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, "synthetic frame allocation succeeds")
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<96 {
                let offset = y * rowBytes + x * 4
                base[offset] = UInt8(30 + frame)
                base[offset + 1] = UInt8(50 + x)
                base[offset + 2] = UInt8(70 + y)
                base[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "synthetic frame append succeeds")
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        precondition(writer.status == .completed, "synthetic video writer completes")
    }

    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mp4 = root.appendingPathComponent("known-good.mp4")
        try await makeVideo(at: mp4)
        let bytes = try Data(contentsOf: mp4)
        let tmp = root.appendingPathComponent("same-video.tmp")
        let mp4Copy = root.appendingPathComponent("same-video.mp4")
        try bytes.write(to: tmp); try bytes.write(to: mp4Copy)
        let tmpBytes = try Data(contentsOf: tmp), mp4Bytes = try Data(contentsOf: mp4Copy)
        check(bytes.count > 1000 && tmpBytes == bytes && mp4Bytes == bytes, "tmp and mp4 fixtures contain identical nonempty MP4 bytes")
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration)
        check(duration.seconds > 1.9 && duration.seconds < 2.1, "known-good video has its real two-second duration")
        let mp4Frames = await ClipFrames.extract(from: mp4Copy)
        check(mp4Frames.count == 3, "known-good mp4 yields all three actual AVFoundation frames")
        check(mp4Frames.map(\.at) == ["first", "middle", "last"], "actual frame labels match the drift request contract")
        for frame in mp4Frames {
            check(frame.jpeg.starts(with: [0xff, 0xd8]), "actual frame is JPEG data")
            let image = UIImage(data: frame.jpeg)
            check(image != nil && max(image!.size.width, image!.size.height) <= 768, "actual JPEG frame decodes within the production maximum size")
        }
        // Measure the suffix claim, without forcing a fabricated failure.
        let tmpFrames = await ClipFrames.extract(from: tmp)
        let tmpDuration = try? await AVURLAsset(url: tmp).load(.duration)
        let normalized = ReelClipPathHarness.clipPath(forDownloaded: tmp)
        let normalizedBytes = try Data(contentsOf: normalized)
        check(normalized.pathExtension == "mp4" && normalized != mp4Copy, "normalizing a download never overwrites its existing mp4 sibling")
        check(normalizedBytes == bytes, "normalization preserves the exact MP4 bytes")
        let preservedSibling = try Data(contentsOf: mp4Copy)
        check(preservedSibling == bytes, "normalization preserves the sibling media bytes")
        let normalizedFrames = await ClipFrames.extract(from: normalized)
        check(normalizedFrames.count == 3, "normalized download yields all three actual AVFoundation frames")
        let bad = root.appendingPathComponent("invalid.mp4")
        try Data("not a video".utf8).write(to: bad)
        let invalid = await ClipFrames.extract(from: bad)
        check(invalid.isEmpty, "corrupt media returns no frames and remains held")
        let absent = await ClipFrames.extract(from: root.appendingPathComponent("absent.mp4"))
        check(absent.isEmpty, "missing media returns no frames and remains held")
        let summary: [String: Any] = [
            "assertions": checks, "mp4_bytes": bytes.count,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "mp4_frame_count": mp4Frames.count, "tmp_frame_count": tmpFrames.count,
            "tmp_duration_seconds": tmpDuration?.seconds ?? -1,
            "normalized_frame_count": normalizedFrames.count,
            "tmp_decodes_identically": tmpFrames.map(\.at) == mp4Frames.map(\.at)
                && zip(tmpFrames, mp4Frames).allSatisfy { $0.jpeg == $1.jpeg },
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: root.appendingPathComponent("result.json"))
        print("PASS: \(checks) actual iOS AVFoundation assertions; identical .tmp frame count = \(tmpFrames.count), .mp4 = \(mp4Frames.count)")
    }
}
