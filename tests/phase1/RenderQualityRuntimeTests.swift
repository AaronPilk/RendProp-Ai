// Actual AVFoundation exports from generated fixtures. This does not exercise
// a camera or claim that a simulator proves physical capture quality.
import Foundation
import AVFoundation

@main struct RenderQualityRuntimeTests {
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let receiptURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedWidth = Int(CommandLine.arguments[3])!
        let expectedHeight = Int(CommandLine.arguments[4])!
        let expectedMotion = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : nil
        let source = AVURLAsset(url: input)
        let duration = try await source.load(.duration).seconds
        let track = try await source.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let sourceFPS = try await track.load(.nominalFrameRate)
        try FileManager.default.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
        let asset = CaptureAsset(localURL: input, durationS: duration, fps: Double(sourceFPS),
                                 width: Int(size.width), height: Int(size.height), bytes: 0)
        let output = try await RenderEngine.render(asset: asset) { _, _ in }
        let result = AVURLAsset(url: output.url)
        let videos = try await result.loadTracks(withMediaType: .video)
        let audio = try await result.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audio.isEmpty else { fatalError("video/silent tour contract changed") }
        let writtenSize = try await videos[0].load(.naturalSize)
        guard Int(writtenSize.width) == expectedWidth, Int(writtenSize.height) == expectedHeight else {
            fatalError("HD dimensions missing: \(writtenSize), expected \(expectedWidth)x\(expectedHeight)")
        }
        let writtenDuration = try await result.load(.duration).seconds
        guard output.speedFactor == 1.5, abs(writtenDuration - duration / 1.5) < 0.04 else {
            fatalError("retiming/duration contract changed")
        }
        guard ["applied", "steady", "unavailable"].contains(output.motionSmoothing),
              output.stabilized == (output.motionSmoothing == "applied") else {
            fatalError("Motion diagnostic and corrected-motion boolean disagree")
        }
        if let expectedMotion, output.motionSmoothing != expectedMotion {
            fatalError("Motion smoothing status mismatch: \(output.motionSmoothing), expected \(expectedMotion)")
        }
        let receipt: [String: Any] = ["path": output.url.path, "width": Int(writtenSize.width),
            "height": Int(writtenSize.height), "duration": writtenDuration,
            "speedFactor": output.speedFactor, "audioTracks": audio.count,
            "sourceDuration": duration, "stabilized": output.stabilized,
            "motionSmoothing": output.motionSmoothing]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: receiptURL, options: .atomic)
        print("PASS: actual RenderEngine output \(expectedWidth)x\(expectedHeight); reviewed pipeline; unchanged retiming; silent tour")
    }
}
