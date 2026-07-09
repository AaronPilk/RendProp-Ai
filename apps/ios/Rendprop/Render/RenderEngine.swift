import AVFoundation
import CoreGraphics

/// On-device render engine v1 — turns a raw walkthrough into a fast, smooth,
/// instantly-scrubbable tour with zero server cost:
///
///   • RETIME  — handheld walks speed up 2× (walk normal; the tour glides).
///               Drone clips get a gentle 1.25× (they already glide).
///   • 60 FPS  — 30fps footage sped 2× yields TRUE 60fps output frames.
///   • SCRUB   — 720p H.264 with very short keyframe interval, so the
///               scroll-scrub player seeks instantly (the buttery feel).
///   • Capture-time cinematicExtended stabilization is already baked in.
///
/// Server-side v2 (Gyroflow-grade stabilization, AI interpolation, 4K, grade)
/// slots in behind the same interface later.
enum RenderEngine {

    struct Output {
        let url: URL
        let durationS: Double
        let speedFactor: Double
    }

    enum RenderError: LocalizedError {
        case noVideoTrack, cannotBuild
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no usable video track."
            case .cannotBuild:  return "Could not prepare the render."
            }
        }
    }

    /// Render `asset` into a smooth scrub-ready tour. Progress: 0…1 + phase label.
    static func render(asset: CaptureAsset,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> Output {
        let speed: Double = asset.isDrone ? 1.25 : 2.0
        progress(0.02, "Preparing your video…")

        let source = AVURLAsset(url: asset.localURL)
        guard let srcTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await srcTrack.load(.naturalSize)
        let transform = try await srcTrack.load(.preferredTransform)
        let duration = try await source.load(.duration)

        // ── Composition: retime the whole take ─────────────────────────────
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.cannotBuild
        }
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                      of: srcTrack, at: .zero)
        let outDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speed)
        compTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                 toDuration: outDuration)

        // ── Orientation + downscale to ≤1280 on the long edge ──────────────
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let scale = min(1.0, 1280.0 / max(orientedSize.width, orientedSize.height))
        let renderSize = CGSize(width: (orientedSize.width * scale / 2).rounded(.down) * 2,
                                height: (orientedSize.height * scale / 2).rounded(.down) * 2)

        var normalize = transform
        normalize = normalize.concatenating(CGAffineTransform(translationX: -orientedRect.origin.x,
                                                              y: -orientedRect.origin.y))
        normalize = normalize.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)   // 60fps output
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: outDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layer.setTransform(normalize, at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        // ── Reader ──────────────────────────────────────────────────────────
        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw RenderError.cannotBuild }
        reader.add(readerOutput)

        // ── Writer: H.264, short GOP = instant scrubbing ────────────────────
        let outURL = FileStore.recordingsDir
            .appendingPathComponent("tour-\(asset.id.uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 6,          // keyframe every 0.1s
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw RenderError.cannotBuild }
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? RenderError.cannotBuild }
        guard writer.startWriting() else { throw writer.error ?? RenderError.cannotBuild }
        writer.startSession(atSourceTime: .zero)

        progress(0.05, "Rendering your tour…")
        let totalSeconds = max(0.01, outDuration.seconds)

        // ── Pump frames ─────────────────────────────────────────────────────
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.rendprop.render")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        progress(0.05 + 0.90 * min(1.0, pts / totalSeconds), "Rendering your tour…")
                        if !writerInput.append(sample) {
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            cont.resume(throwing: writer.error ?? RenderError.cannotBuild)
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            cont.resume(throwing: reader.error ?? RenderError.cannotBuild)
                        } else {
                            cont.resume(returning: ())
                        }
                        return
                    }
                }
            }
        }

        progress(0.97, "Finishing up…")
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RenderError.cannotBuild
        }
        progress(1.0, "Done")
        return Output(url: outURL, durationS: totalSeconds, speedFactor: speed)
    }
}
