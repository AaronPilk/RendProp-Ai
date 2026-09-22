import Foundation
import AVFoundation

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct RenderEngineRuntimeTests {
    static var assertions = 0
    static func check(_ value: Bool, _ message: String) {
        assertions += 1
        guard value else { fatalError("render assertion failed: \(message)") }
    }
    static func asset(_ source: URL) -> CaptureAsset {
        CaptureAsset(localURL: source, durationS: 1.5, fps: 30, width: 64, height: 48, bytes: 1000)
    }
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        try fm.createDirectory(at: FileStore.recordingsDir, withIntermediateDirectories: true)
        let probe = Probe()
        let first = try await RenderEngine.render(asset: asset(source)) { value, _ in probe.record(value) }
        check(fm.fileExists(atPath: first.url.path), "completed output exists")
        check(abs(first.durationS - 1) < 0.02, "retimed duration remains one second")
        check(first.speedFactor == 1.5, "short-clip speed unchanged")
        check(probe.snapshot.last == 1, "completion progress delivered")
        check(probe.snapshot.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "progress bounded")
        let rendered = AVURLAsset(url: first.url)
        check(abs(try await rendered.load(.duration).seconds - first.durationS) < 0.05, "actual MP4 duration matches receipt")
        check(try await rendered.loadTracks(withMediaType: .video).count == 1, "completed output has video")
        let saved = try Data(contentsOf: first.url)
        check(saved.count > 100, "actual encoded bytes present")

        // Independent serial owners must let both renders complete; no shared
        // global queue/state may cancel or finish the other listing's export.
        async let a = RenderEngine.render(asset: asset(source)) { _, _ in }
        async let b = RenderEngine.render(asset: asset(source)) { _, _ in }
        let pair = try await (a, b)
        check(pair.0.url != pair.1.url, "simultaneous render destinations distinct")
        check(fm.fileExists(atPath: pair.0.url.path) && fm.fileExists(atPath: pair.1.url.path), "both actual simultaneous renders complete")

        // Cancellation before the task starts must not publish a partial file.
        let cancelledAsset = asset(source)
        let cancelled = Task { try await RenderEngine.render(asset: cancelledAsset) { _, _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled render unexpectedly succeeded") }
        catch is CancellationError { assertions += 1 }
        catch RenderEngine.RenderError.cancelled { assertions += 1 }
        let cancelledURL = FileStore.recordingsDir.appendingPathComponent("tour-\(cancelledAsset.id.uuidString.prefix(8)).mp4")
        check(!fm.fileExists(atPath: cancelledURL.path), "cancelled render never publishes")
        check(try Data(contentsOf: first.url) == saved, "cancelled independent render leaves previous output untouched")
        check(try fm.contentsOfDirectory(atPath: FileStore.recordingsDir.path).allSatisfy { !$0.hasSuffix(".part.mp4") }, "no partial export remains")
        check(assertions == 14, "exact runtime assertion count")
        print("PASS: \(assertions) actual RenderEngine assertions; 3 completed renders; 1 cancelled render; 0 skips")
        try await RenderEngine.verifyStalledCancellation(sourceURL: source,
            directory: FileStore.recordingsDir.deletingLastPathComponent())
    }
}
