// Appended to a temporary copy of the production RenderEngine source by
// run_render_output_duration.py so the private output check is exercised
// without adding a test hook to the shipping app.
import Foundation
import AVFoundation

extension RenderEngine {
    static func checkOutputDurationFixtures(full: URL, short: URL, tiny: URL, invalid: URL) async throws {
        let fullSeconds = try await AVURLAsset(url: full).load(.duration).seconds
        let shortSeconds = try await AVURLAsset(url: short).load(.duration).seconds
        let tinySeconds = try await AVURLAsset(url: tiny).load(.duration).seconds
        guard fullSeconds >= 0.95, shortSeconds < 0.2, tinySeconds >= 0.18 else {
            fatalError("Synthetic fixture durations did not exercise the intended boundary")
        }
        try await verifyCompletedOutput(at: full, expectedDuration: 1.0)
        try await verifyCompletedOutput(at: tiny, expectedDuration: 0.2)
        do {
            try await verifyCompletedOutput(at: short, expectedDuration: 1.0)
            fatalError("FAIL: one-frame truncated MP4 was accepted")
        } catch RenderError.incompleteOutput {
            // A playable but incomplete video is classified for retry.
        }
        do {
            try await verifyCompletedOutput(at: invalid, expectedDuration: 1.0)
            fatalError("FAIL: malformed MP4 was accepted")
        } catch RenderError.incompleteOutput {
            // Broken metadata also cannot replace a previously saved tour.
        }
        print("PASS: full and valid tiny MP4 accepted; one-frame and malformed MP4 rejected")
    }
}

@main struct RenderOutputDurationTests {
    static func main() async throws {
        let args = CommandLine.arguments
        if args[1] == "--render" {
            let sourceURL = URL(fileURLWithPath: args[2])
            let expectedDuration = Double(args[3])!
            let source = AVURLAsset(url: sourceURL)
            let sourceDuration = try await source.load(.duration).seconds
            let track = try await source.loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            try FileManager.default.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
            let asset = CaptureAsset(localURL: sourceURL, durationS: sourceDuration,
                                     fps: Double(fps), width: Int(size.width),
                                     height: Int(size.height), bytes: 0)
            let output = try await RenderEngine.render(asset: asset) { _, _ in }
            let movie = AVURLAsset(url: output.url)
            let written = try await movie.load(.duration).seconds
            guard abs(output.durationS - expectedDuration) < 0.02,
                  abs(written - expectedDuration) < 0.10 else {
                fatalError("Normal render duration mismatch: requested \(expectedDuration), written \(written)")
            }
            print("PASS: actual \(expectedDuration)s RenderEngine export completed and survived output validation")
            return
        }
        try await RenderEngine.checkOutputDurationFixtures(
            full: URL(fileURLWithPath: args[1]),
            short: URL(fileURLWithPath: args[2]),
            tiny: URL(fileURLWithPath: args[3]),
            invalid: URL(fileURLWithPath: args[4]))
    }
}
