import AVFoundation
import CoreGraphics
import Vision

/// On-device render engine v2 — turns a raw walkthrough into a smooth,
/// drone-style, instantly-scrubbable tour with zero server cost.
///
///   • STABILIZE — the drone feel. A first pass measures frame-to-frame camera
///                 jitter (Vision translational registration on downscaled
///                 frames), smooths the camera path with a Gaussian low-pass,
///                 and derives a per-frame correction. A small adaptive crop-in
///                 hides the moving borders. Handheld footage that came in shaky
///                 goes out gliding. Drone clips skip this (already smooth).
///   • RETIME    — handheld walks glide at 2×; drone clips a gentle 1.25×.
///                 Very short clips are sped less so they don't feel frantic.
///   • 60 FPS    — output frame cadence for a fluid scroll-scrub.
///   • SCRUB     — ≤720p H.264, keyframe every ~0.1s → the player seeks instantly.
///   • COLOR     — output tagged Rec.709 SDR so HDR/Dolby-Vision phone footage
///                 tone-maps instead of looking washed out or crushed.
///
/// HONEST FALLBACK: stabilization is best-effort. If registration is low-
/// confidence (fast pans, low light, featureless walls), we drop to identity
/// corrections and still ship the retimed/encoded tour — never worse than v1.
/// Server-side v3 (Gyroflow-grade, AI frame interpolation, 4K, grade) slots in
/// behind this same interface later.
enum RenderEngine {

    struct Output {
        let url: URL
        let durationS: Double
        let speedFactor: Double
        let stabilized: Bool
    }

    enum RenderError: LocalizedError {
        case noVideoTrack, cannotBuild, cancelled
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The video has no usable video track."
            case .cannotBuild:  return "Could not prepare the render."
            case .cancelled:    return "Render cancelled."
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.rendprop.render", qos: .userInitiated)

    // Tuning
    private static let outputFPS: Int32 = 60
    private static let encodeLongEdge: CGFloat = 1280
    private static let analyzeLongEdge: CGFloat = 384      // registration runs here — fast
    private static let smoothingSigmaFrames = 18.0         // ~0.3s @ 60fps low-pass
    private static let stabStrength: CGFloat = 0.9         // apply 90% of correction (avoid overshoot)
    private static let maxCropZoom: CGFloat = 1.12         // never crop more than 12%
    private static let maxRegistrationFailRatio = 0.4      // above this → skip stabilization

    // MARK: - Public entry

    static func render(asset: CaptureAsset,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> Output {
        progress(0.02, "Preparing your video…")

        let source = AVURLAsset(url: asset.localURL)
        guard let srcTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await srcTrack.load(.naturalSize)
        let transform = try await srcTrack.load(.preferredTransform)
        let duration = try await source.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0.2 else { throw RenderError.cannotBuild }

        // Adaptive speed: short clips shouldn't feel frantic.
        let baseSpeed: Double = asset.isDrone ? 1.25 : 2.0
        let speed = duration.seconds < 12 ? min(baseSpeed, 1.5) : baseSpeed
        let outDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speed)
        let frameCount = max(1, Int((outDuration.seconds * Double(outputFPS)).rounded()))

        // Geometry for the full-res encode.
        let encode = geometry(naturalSize: naturalSize, transform: transform, longEdge: encodeLongEdge)

        // ── Pass 1: analyze camera jitter (skipped for drone clips) ──────────
        var corrections = [CGPoint](repeating: .zero, count: frameCount)
        var cropZoom: CGFloat = 1.0
        var stabilized = false

        if !asset.isDrone {
            progress(0.05, "Smoothing the motion…")
            let analyze = geometry(naturalSize: naturalSize, transform: transform, longEdge: analyzeLongEdge)
            if let result = try await analyzeJitter(source: source, srcTrack: srcTrack,
                                                    duration: duration, outDuration: outDuration,
                                                    speed: speed, frameCount: frameCount,
                                                    geo: analyze,
                                                    progress: { p in progress(0.05 + 0.38 * p, "Smoothing the motion…") }) {
                // Corrections were measured in analyze space; scale to encode space.
                let s = encode.renderSize.width / analyze.renderSize.width
                corrections = clampCorrections(result.corrections.map { CGPoint(x: $0.x * s, y: $0.y * s) },
                                               renderSize: encode.renderSize,
                                               zoom: &cropZoom)
                stabilized = cropZoom > 1.0001
            }
        }

        // ── Pass 2: encode (retime + orient + per-frame stabilization) ───────
        progress(0.45, "Rendering your tour…")
        let outURL = FileStore.recordingsDir
            .appendingPathComponent("tour-\(asset.id.uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        try await encodePass(source: source, srcTrack: srcTrack,
                             duration: duration, outDuration: outDuration,
                             speed: speed, frameCount: frameCount,
                             geo: encode, corrections: corrections, cropZoom: cropZoom,
                             outURL: outURL,
                             progress: { p in progress(0.45 + 0.53 * p, "Rendering your tour…") })

        progress(1.0, "Done")
        return Output(url: outURL, durationS: outDuration.seconds, speedFactor: speed, stabilized: stabilized)
    }

    // MARK: - Geometry (orientation + downscale to ≤ longEdge)

    private struct Geometry {
        let renderSize: CGSize
        let normalize: CGAffineTransform   // source pixels → upright render space (top-left origin)
    }

    private static func geometry(naturalSize: CGSize, transform: CGAffineTransform, longEdge: CGFloat) -> Geometry {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let scale = min(1.0, longEdge / max(orientedSize.width, orientedSize.height))
        let renderSize = CGSize(width: (orientedSize.width * scale / 2).rounded(.down) * 2,
                                height: (orientedSize.height * scale / 2).rounded(.down) * 2)
        var normalize = transform
        normalize = normalize.concatenating(CGAffineTransform(translationX: -orientedRect.origin.x,
                                                              y: -orientedRect.origin.y))
        normalize = normalize.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return Geometry(renderSize: renderSize, normalize: normalize)
    }

    // MARK: - Retime composition (shared by both passes)

    private static func retimeComposition(source: AVAsset, srcTrack: AVAssetTrack,
                                          duration: CMTime, outDuration: CMTime) throws
        -> (AVMutableComposition, AVMutableCompositionTrack) {
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.cannotBuild
        }
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcTrack, at: .zero)
        compTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: outDuration)
        return (composition, compTrack)
    }

    // MARK: - Pass 1: jitter analysis

    private struct AnalyzeResult { let corrections: [CGPoint] }

    private static func analyzeJitter(source: AVAsset, srcTrack: AVAssetTrack,
                                      duration: CMTime, outDuration: CMTime,
                                      speed: Double, frameCount: Int, geo: Geometry,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> AnalyzeResult? {
        let (composition, compTrack) = try retimeComposition(source: source, srcTrack: srcTrack,
                                                             duration: duration, outDuration: outDuration)

        // Single instruction: orient + scale to small analyze size.
        let vc = AVMutableVideoComposition()
        vc.renderSize = geo.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: outputFPS)
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: outDuration)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        li.setTransform(geo.normalize, at: .zero)
        instr.layerInstructions = [li]
        vc.instructions = [instr]

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = vc
        output.alwaysCopiesSampleData = true   // we hold the previous frame across iterations
        guard reader.canAdd(output) else { throw RenderError.cannotBuild }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.cannotBuild }

        return try await runOnQueue { () throws -> AnalyzeResult? in
            var raw = [CGPoint]()                 // cumulative measured camera path
            raw.reserveCapacity(frameCount)
            var pos = CGPoint.zero
            raw.append(pos)

            var previous: CVPixelBuffer?
            var failures = 0
            var seen = 0

            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw RenderError.cancelled }
                try autoreleasepoolThrowing {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                    if let prev = previous {
                        let req = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
                        let handler = VNImageRequestHandler(cvPixelBuffer: prev, options: [:])
                        do {
                            try handler.perform([req])
                            if let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                                let t = obs.alignmentTransform
                                pos = CGPoint(x: pos.x + t.tx, y: pos.y + t.ty)
                            } else { failures += 1 }
                        } catch { failures += 1 }
                        raw.append(pos)
                    }
                    previous = buffer
                    seen += 1
                    if seen % 8 == 0 {
                        progress(min(1.0, Double(seen) / Double(max(1, frameCount))))
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? RenderError.cannotBuild }

            // Too many failures → not enough signal to trust; skip stabilization.
            let comparisons = max(1, raw.count - 1)
            if raw.count < 8 || Double(failures) / Double(comparisons) > maxRegistrationFailRatio {
                return nil
            }

            // Smooth the path, correction = smoothed − raw, apply strength.
            let smoothed = gaussianSmooth(raw, sigma: smoothingSigmaFrames)
            var corrections = zip(smoothed, raw).map { s, r in
                CGPoint(x: (s.x - r.x) * stabStrength, y: (s.y - r.y) * stabStrength)
            }
            // Pad/trim to exactly frameCount so indices line up with the encode pass.
            if corrections.count < frameCount, let last = corrections.last {
                corrections.append(contentsOf: Array(repeating: last, count: frameCount - corrections.count))
            } else if corrections.count > frameCount {
                corrections = Array(corrections.prefix(frameCount))
            }
            return AnalyzeResult(corrections: corrections)
        }
    }

    // MARK: - Pass 2: encode with per-frame stabilization

    private static func encodePass(source: AVAsset, srcTrack: AVAssetTrack,
                                   duration: CMTime, outDuration: CMTime,
                                   speed: Double, frameCount: Int, geo: Geometry,
                                   corrections: [CGPoint], cropZoom: CGFloat,
                                   outURL: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let (composition, compTrack) = try retimeComposition(source: source, srcTrack: srcTrack,
                                                             duration: duration, outDuration: outDuration)

        let vc = AVMutableVideoComposition()
        vc.renderSize = geo.renderSize
        let fd = CMTime(value: 1, timescale: outputFPS)
        vc.frameDuration = fd

        // One instruction per output frame so each gets its own stabilization transform.
        // (Metadata only — cheap. Same top-left coord space as Vision, so no y-flip bug.)
        let W = geo.renderSize.width, H = geo.renderSize.height
        var instructions = [AVMutableVideoCompositionInstruction]()
        instructions.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let start = CMTimeMultiply(fd, multiplier: Int32(i))
            var thisDuration = fd
            if i == frameCount - 1 {
                let remaining = CMTimeSubtract(outDuration, start)
                if remaining.seconds > 0 { thisDuration = remaining }
            }
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: start, duration: thisDuration)
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
            let c = corrections.indices.contains(i) ? corrections[i] : .zero
            let stab = stabilizeTransform(correction: c, zoom: cropZoom, width: W, height: H)
            li.setTransform(geo.normalize.concatenating(stab), at: start)
            instr.layerInstructions = [li]
            instructions.append(instr)
        }
        vc.instructions = instructions

        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        readerOutput.videoComposition = vc
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw RenderError.cannotBuild }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(geo.renderSize.width),
            AVVideoHeightKey: Int(geo.renderSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 6,          // keyframe every ~0.1s
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

        let totalSeconds = max(0.01, outDuration.seconds)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        reader.cancelReading(); writerInput.markAsFinished()
                        cont.resume(throwing: RenderError.cancelled); return
                    }
                    var didResume = false
                    autoreleasepool {
                        if let sample = readerOutput.copyNextSampleBuffer() {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            progress(min(1.0, pts / totalSeconds))
                            if !writerInput.append(sample) {
                                reader.cancelReading(); writerInput.markAsFinished()
                                cont.resume(throwing: writer.error ?? RenderError.cannotBuild)
                                didResume = true
                            }
                        } else {
                            writerInput.markAsFinished()
                            if reader.status == .failed {
                                cont.resume(throwing: reader.error ?? RenderError.cannotBuild)
                            } else {
                                cont.resume(returning: ())
                            }
                            didResume = true
                        }
                    }
                    if didResume { return }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RenderError.cannotBuild }
    }

    // MARK: - Transform + smoothing helpers

    /// Zoom-about-center (hides moving borders) then translate by the correction,
    /// all in the render space (top-left origin — matches Vision's measurements).
    private static func stabilizeTransform(correction: CGPoint, zoom: CGFloat,
                                           width: CGFloat, height: CGFloat) -> CGAffineTransform {
        let zoomAboutCenter = CGAffineTransform(translationX: width / 2, y: height / 2)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -width / 2, y: -height / 2)
        let translate = CGAffineTransform(translationX: correction.x, y: correction.y)
        return translate.concatenating(zoomAboutCenter)   // translate first, then zoom
    }

    /// Pick the smallest crop-zoom that hides the largest correction, then clamp
    /// every correction into that margin so no black borders can appear.
    private static func clampCorrections(_ corrections: [CGPoint], renderSize: CGSize,
                                         zoom: inout CGFloat) -> [CGPoint] {
        let W = renderSize.width, H = renderSize.height
        let maxFrac = corrections.map { max(abs($0.x) / W, abs($0.y) / H) }.max() ?? 0
        zoom = min(maxCropZoom, max(1.0, 1.0 + 2.0 * maxFrac + 0.02))
        guard zoom > 1.0001 else { return [CGPoint](repeating: .zero, count: corrections.count) }
        let marginX = (zoom - 1) / zoom * (W / 2) * 0.98
        let marginY = (zoom - 1) / zoom * (H / 2) * 0.98
        return corrections.map {
            CGPoint(x: min(max($0.x, -marginX), marginX),
                    y: min(max($0.y, -marginY), marginY))
        }
    }

    /// Gaussian low-pass over a point path. Removes high-frequency shake while
    /// following the low-frequency intended motion (the walk / pan).
    private static func gaussianSmooth(_ path: [CGPoint], sigma: Double) -> [CGPoint] {
        guard path.count > 2, sigma > 0 else { return path }
        let radius = Int((sigma * 3).rounded())
        var kernel = [Double]()
        var sum = 0.0
        for i in -radius...radius {
            let w = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel.append(w); sum += w
        }
        kernel = kernel.map { $0 / sum }

        var out = [CGPoint](); out.reserveCapacity(path.count)
        let n = path.count
        for i in 0..<n {
            var ax = 0.0, ay = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)     // clamp at edges
                let w = kernel[k + radius]
                ax += Double(path[j].x) * w
                ay += Double(path[j].y) * w
            }
            out.append(CGPoint(x: ax, y: ay))
        }
        return out
    }

    // MARK: - Queue / autorelease plumbing

    private static func runOnQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func autoreleasepoolThrowing(_ body: () throws -> Void) throws {
        var captured: Error?
        autoreleasepool {
            do { try body() } catch { captured = error }
        }
        if let captured { throw captured }
    }
}
