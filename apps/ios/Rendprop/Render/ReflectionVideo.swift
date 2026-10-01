import Foundation
import AVFoundation

/// A single, bounded provider input on the original movie's timeline.
struct ReflectionClip: Codable, Hashable, Identifiable {
    var id = UUID()
    var startS: Double
    var endS: Double
    var durationS: Double { endS - startS }
}

enum ReflectionVideo {
    static let maximumClipSeconds = 4.8
    private static let scale: CMTimeScale = 60_000

    enum Failure: LocalizedError {
        case invalidRange, noVideo, exportFailed, changedDuration, changedFraming, insufficientSpace
        var errorDescription: String? {
            switch self {
            case .invalidRange: return "The selected interval is outside this video. Your original is safe."
            case .noVideo: return "This clip could not be read. Your original is safe."
            case .exportFailed: return "The edited video could not be saved. Your original is safe."
            case .changedDuration: return "The AI returned a different clip length. It cannot replace this interval safely."
            case .changedFraming: return "The AI changed this video's framing. Your original has been kept."
            case .insufficientSpace: return "Free more storage before editing this video. Your original needs to stay on this phone."
            }
        }
    }

    /// Merge before splitting. Invalid persisted metadata never reaches a paid job.
    /// Integer media ticks avoid tiny tail jobs from floating-point subtraction.
    static func plan(ranges: [TimeRange], duration: Double,
                     maximum: Double = maximumClipSeconds) -> [ReflectionClip] {
        guard duration.isFinite, duration > 0, duration <= MediaImporter.maxDurationSeconds,
              maximum.isFinite, maximum > 0, maximum < 5 else { return [] }
        let end = Int64((duration * Double(scale)).rounded(.down))
        let cap = Int64((min(maximum, maximumClipSeconds) * Double(scale)).rounded(.down))
        guard cap > 0 else { return [] }
        let spans = ranges.compactMap { range -> (Int64, Int64)? in
            guard range.startS.isFinite, range.endS.isFinite, range.endS > range.startS else { return nil }
            let a = Int64((min(duration, max(0, range.startS)) * Double(scale)).rounded(.down))
            let b = min(end, Int64((min(duration, max(0, range.endS)) * Double(scale)).rounded(.down)))
            return b > a ? (a, b) : nil
        }.sorted { $0.0 < $1.0 }
        var merged: [(Int64, Int64)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else { merged.append(span) }
        }
        var clips: [ReflectionClip] = []
        for span in merged {
            // Evenly split a span so a nearly-multiple of 4.8s never leaves a
            // sub-frame tail. No footage is discarded to satisfy the cap.
            let pieces = (span.1 - span.0 + cap - 1) / cap
            for index in 0..<pieces {
                let a = span.0 + (span.1 - span.0) * index / pieces
                let b = span.0 + (span.1 - span.0) * (index + 1) / pieces
                clips.append(ReflectionClip(startS: Double(a) / Double(scale), endS: Double(b) / Double(scale)))
            }
        }
        return clips
    }

    static func extract(source: URL, clip: ReflectionClip, destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= MediaImporter.maxDurationSeconds,
              clip.startS.isFinite, clip.endS.isFinite, clip.startS >= 0,
              clip.durationS > 0, clip.durationS <= maximumClipSeconds,
              clip.endS <= duration + 1 / Double(scale) else { throw Failure.invalidRange }
        guard !FileManager.default.fileExists(atPath: destination.path), source != destination else { throw Failure.exportFailed }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        let videoComposition = AVMutableVideoComposition(propertiesOf: asset)
        tag709(videoComposition)
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: time(clip.startS), end: time(clip.endS))
        try await export(session, to: destination)
        let probe = await MediaImporter.probe(url: destination)
        guard probe.hasVideoTrack, probe.isPlayable, probe.duration > 0, probe.duration < 5,
              abs(probe.duration - clip.durationS) <= tolerance(fps: probe.fps) else { throw Failure.changedDuration }
    }

    /// Compose every original interval, replacing only the chosen ranges. Audio
    /// always comes from the complete original, including through edited spans.
    /// Full encode is intentional: provider output may use a different codec/FPS.
    static func splice(source: URL, replacements: [(ReflectionClip, URL)], destination: URL) async throws {
        try Task.checkCancellation()
        guard !replacements.isEmpty, source != destination,
              !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.invalidRange }
        let original = AVURLAsset(url: source)
        let sourceDuration = try await original.load(.duration)
        guard sourceDuration.seconds.isFinite, sourceDuration.seconds > 0,
              sourceDuration.seconds <= MediaImporter.maxDurationSeconds,
              let sourceVideo = try await original.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let originalSize = try await displaySize(sourceVideo)
        let fps = Double(try await sourceVideo.load(.nominalFrameRate))
        guard fps.isFinite, fps > 0, originalSize.width > 0, originalSize.height > 0 else { throw Failure.noVideo }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed
        }
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        func append(_ track: AVAssetTrack, from: CMTime, length: CMTime, at: CMTime) async throws {
            guard length.seconds > 0 else { return }
            try picture.insertTimeRange(CMTimeRange(start: from, duration: length), of: track, at: at)
            let size = try await track.load(.naturalSize)
            let preferred = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(preferred)
            guard abs(rect.width) > 0, abs(rect.height) > 0 else { throw Failure.noVideo }
            let ratio = abs(rect.width / rect.height) / (originalSize.width / originalSize.height)
            guard abs(ratio - 1) < 0.01 else { throw Failure.changedFraming }
            let translate = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            let resize = CGAffineTransform(scaleX: originalSize.width / abs(rect.width), y: originalSize.height / abs(rect.height))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: picture)
            layer.setTransform(preferred.concatenating(translate).concatenating(resize), at: at)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: at, duration: length)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }
        var cursor = CMTime.zero
        for (clip, outputURL) in replacements.sorted(by: { $0.0.startS < $1.0.startS }) {
            try Task.checkCancellation()
            guard clip.startS.isFinite, clip.endS.isFinite,
                  clip.startS >= cursor.seconds, clip.endS <= sourceDuration.seconds + 1 / Double(scale),
                  clip.durationS > 0, clip.durationS <= maximumClipSeconds else { throw Failure.invalidRange }
            let start = time(clip.startS), end = time(clip.endS)
            if CMTimeCompare(start, cursor) > 0 {
                try await append(sourceVideo, from: cursor, length: start - cursor, at: cursor)
            }
            let replacement = AVURLAsset(url: outputURL)
            guard let video = try await replacement.loadTracks(withMediaType: .video).first,
                  try await replacement.load(.isPlayable) else { throw Failure.noVideo }
            let actual = try await replacement.load(.duration)
            let span = end - start
            guard abs(actual.seconds - span.seconds) <= tolerance(fps: fps) else { throw Failure.changedDuration }
            let usable = CMTimeMinimum(actual, span)
            try await append(video, from: .zero, length: usable, at: start)
            // A provider's frame quantization may leave <=one frame missing.
            // Fill that instant from the source; never freeze or shift the take.
            if CMTimeCompare(usable, span) < 0 {
                try await append(sourceVideo, from: start + usable, length: span - usable, at: start + usable)
            }
            cursor = end
        }
        if CMTimeCompare(cursor, sourceDuration) < 0 {
            try await append(sourceVideo, from: cursor, length: sourceDuration - cursor, at: cursor)
        }
        for audio in try await original.loadTracks(withMediaType: .audio) {
            guard let destinationAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.exportFailed
            }
            let available = try await audio.load(.timeRange)
            let retained = CMTimeRangeGetIntersection(available, otherRange: CMTimeRange(start: .zero, duration: sourceDuration))
            if retained.duration.seconds > 0 { try destinationAudio.insertTimeRange(retained, of: audio, at: retained.start) }
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = originalSize
        videoComposition.frameDuration = time(1 / fps)
        videoComposition.instructions = instructions
        tag709(videoComposition)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: sourceDuration)
        try await export(session, to: destination)
        let result = await MediaImporter.probe(url: destination)
        guard result.hasVideoTrack, result.isPlayable, FileStore.fileSize(destination) > 0,
              result.duration <= MediaImporter.maxDurationSeconds,
              abs(result.duration - sourceDuration.seconds) <= tolerance(fps: fps),
              result.width == Int(originalSize.width), result.height == Int(originalSize.height) else { throw Failure.changedDuration }
        let resultAudio = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        let sourceAudio = try await original.loadTracks(withMediaType: .audio)
        guard resultAudio.count == sourceAudio.count else { throw Failure.exportFailed }
    }

    private static func displaySize(_ track: AVAssetTrack) async throws -> CGSize {
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: scale) }
    private static func tolerance(fps: Double) -> Double { 1 / max(1, fps) + 0.001 }

    /// Match RenderEngine's SDR delivery policy for both provider inputs and
    /// the full splice. Mixing untreated HDR code values with SDR AI frames
    /// would change brightness at each edit boundary. AVFoundation performs
    /// the color conversion; real-device HDR highlight quality remains a
    /// separate acceptance check, and the original HDR file is never changed.
    private static func tag709(_ composition: AVMutableVideoComposition) {
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }

    private static func export(_ session: AVAssetExportSession, to destination: URL) async throws {
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try await ExportOperation(session).run()
        try Task.checkCancellation()
    }

    /// AVAssetExportSession is not Sendable. Its start/cancel/completion state
    /// is confined to one queue, matching the ownership pattern in RenderEngine.
    private final class ExportOperation: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let queue = DispatchQueue(label: "com.rendprop.reflection.export")
        private var cancelled = false
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ session: AVAssetExportSession) { self.session = session }

        func run() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        if self.cancelled { continuation.resume(throwing: CancellationError()); return }
                        self.continuation = continuation
                        self.session.exportAsynchronously { [weak self] in
                            guard let self else { return }
                            self.queue.async { self.finish() }
                        }
                    }
                }
            } onCancel: {
                self.queue.async {
                    self.cancelled = true
                    if self.continuation != nil { self.session.cancelExport() }
                }
            }
        }

        private func finish() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let continuation else { return }
            self.continuation = nil
            if cancelled { continuation.resume(throwing: CancellationError()) }
            else if session.status == .completed { continuation.resume() }
            else { continuation.resume(throwing: Failure.exportFailed) }
        }
    }
}
