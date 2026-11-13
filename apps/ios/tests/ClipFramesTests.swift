import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import UIKit

@main struct ClipFramesTests {
    // Pinned bytes remove unrelated runtime encoder startup from this decoder gate.
    // The original writer and the observed hosted failure remain in fixture provenance.
    static let fixtureSHA256 = "b16c9f4cb5aaf826f9820ac4846a44c54fbe989c861b88f925095d789ccc60a3"


    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mp4 = root.appendingPathComponent("known-good.mp4")
        precondition(CommandLine.arguments.count == 3, "known-good fixture path is provided")
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let bytes = try Data(contentsOf: fixtureURL)
        precondition(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == fixtureSHA256,
                     "pinned known-good fixture SHA matches its preserved encoder provenance")
        try bytes.write(to: mp4)
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
