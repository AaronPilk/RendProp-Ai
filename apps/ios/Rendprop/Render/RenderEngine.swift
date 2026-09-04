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
///   • SCRUB     — ≤720p H.264, ALL-INTRA (every frame a keyframe) → the player
///                 seeks any position instantly.
///   • COLOR     — both compositions and the writer are tagged Rec.709 SDR so
///                 HDR/Dolby-Vision phone footage tone-maps instead of looking
///                 washed out or crushed.
///
/// HONEST FALLBACK: stabilization is best-effort. If registration is low-
/// confidence (fast pans, low light, featureless walls) — or pass 1 fails for
/// any reason other than cancellation — we drop to identity corrections and
/// still ship the retimed/encoded tour — never worse than v1.
///
/// OUTPUT SAFETY: the encode writes to a unique temp file next to the final
/// path and is moved into place only after the writer reports `.completed`.
/// The existing tour (if any) is never deleted first, so a failed or cancelled
/// re-render can't take the live tour with it (audit F-D-01).
///
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
        case badDimensions
        case tooShort
        case tooLong(Double)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack:  return "The video has no usable video track."
            case .cannotBuild:   return "Could not prepare the render."
            case .cancelled:     return "Render cancelled."
            case .badDimensions: return "The video reports no picture size, so it can't be rendered. Try re-exporting it."
            case .tooShort:      return "The video is too short to render — record at least a second."
            case .tooLong(let s):
                let minutes = Int(s / 60), seconds = Int(s) % 60
                return "This video is \(minutes):\(String(format: "%02d", seconds)) long. Tours render up to \(Int(RenderEngine.maxSourceSeconds / 60)) minutes — trim it and try again."
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.rendprop.render", qos: .userInitiated)

    /// Thread-safe cancellation flag bridged into the AVFoundation callback
    /// queues. `Task.isCancelled` is always FALSE inside plain dispatch-queue
    /// callbacks (there is no task context there), so checking it in the
    /// reader/writer loops never fired — cancelling the outer task used to
    /// leave the encoder running to completion. `withTaskCancellationHandler`
    /// sets this flag instead, and the loops poll it every iteration.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Progress reporter throttled to ~10 Hz (the encode loop produces a sample
    /// per output frame — 60/s — and each report used to hop to the main actor).
    private final class ProgressThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date.distantPast
        private var lastValue = -1.0
        private let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func send(_ value: Double, force: Bool = false) {
            lock.lock()
            let now = Date()
            let due = force || value >= 1.0 || now.timeIntervalSince(last) >= 0.1 || value - lastValue >= 0.02
            if due { last = now; lastValue = value }
            lock.unlock()
            if due { report(value) }
        }
    }

    // Tuning
    private static let outputFPS: Int32 = 60
    private static let encodeLongEdge: CGFloat = 1280
    private static let analyzeLongEdge: CGFloat = 384      // registration runs here — fast
    private static let smoothingSigmaFrames = 18.0         // ~0.3s @ 60fps low-pass
    private static let stabStrength: CGFloat = 0.9         // apply 90% of correction (avoid overshoot)
    private static let maxCropZoom: CGFloat = 1.12         // never crop more than 12%
    private static let maxRegistrationFailRatio = 0.4      // above this → skip stabilization
    /// A registration offset larger than this fraction of the frame is a scene
    /// cut / whip pan, not jitter — count it as a failure (audit F-D-32).
    private static let maxPlausibleShiftFraction: CGFloat = 0.08
    /// Sources longer than this are refused with a clear error (kept in step
    /// with MediaImporter.maxDurationSeconds and the capture cap).
    static let maxSourceSeconds: Double = MediaImporter.maxDurationSeconds
    /// Anything shorter than this is a tap, not a walkthrough.
    static let minSourceSeconds: Double = MediaImporter.minDurationSeconds

    // MARK: - Public entry

    static func render(asset: CaptureAsset,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> Output {
        // Bridge task cancellation into the dispatch-queue render loops (see
        // CancelFlag) so leaving the screen actually stops the encode instead
        // of burning CPU/battery to completion in the background.
        let cancelFlag = CancelFlag()
        // Screen-awake / background-task holds for the render are owned by the
        // caller (RenderCoordinator keeps `isIdleTimerDisabled` for the whole
        // render + publish job) — the engine stays UI-agnostic.
        return try await withTaskCancellationHandler {
            try await renderBody(asset: asset, cancelFlag: cancelFlag, progress: progress)
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private static func renderBody(asset: CaptureAsset,
                                   cancelFlag: CancelFlag,
                                   progress: @escaping @Sendable (Double, String) -> Void) async throws -> Output {
        progress(0.02, "Preparing your video…")
        sweepStaleTempFiles(in: FileStore.recordingsDir)

        let source = AVURLAsset(url: asset.localURL)
        guard let srcTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await srcTrack.load(.naturalSize)
        let transform = try await srcTrack.load(.preferredTransform)
        let duration = try await source.load(.duration)
        guard naturalSize.width > 0, naturalSize.height > 0,
              naturalSize.width.isFinite, naturalSize.height.isFinite else {
            throw RenderError.badDimensions
        }
        guard duration.seconds.isFinite, duration.seconds >= minSourceSeconds else { throw RenderError.tooShort }
        guard duration.seconds <= maxSourceSeconds else { throw RenderError.tooLong(duration.seconds) }

        // Adaptive speed: short clips shouldn't feel frantic.
        let baseSpeed: Double = asset.isDrone ? 1.25 : 2.0
        let speed = duration.seconds < 12 ? min(baseSpeed, 1.5) : baseSpeed
        let outDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speed)
        let frameCount = max(1, Int((outDuration.seconds * Double(outputFPS)).rounded()))

        // Geometry for the full-res encode.
        let encode = geometry(naturalSize: naturalSize, transform: transform, longEdge: encodeLongEdge)
        guard encode.renderSize.width >= 2, encode.renderSize.height >= 2 else {
            throw RenderError.badDimensions
        }

        // ── Pass 1: analyze camera jitter (skipped for drone clips) ──────────
        var corrections = [CGPoint](repeating: .zero, count: frameCount)
        var cropZoom: CGFloat = 1.0
        var stabilized = false

        if !asset.isDrone {
            progress(0.05, "Smoothing the motion…")
            let analyze = geometry(naturalSize: naturalSize, transform: transform, longEdge: analyzeLongEdge)
            let analyzeProgress = ProgressThrottle { p in progress(0.05 + 0.38 * p, "Smoothing the motion…") }
            var result: AnalyzeResult?
            do {
                result = try await analyzeJitter(source: source, srcTrack: srcTrack,
                                                 duration: duration, outDuration: outDuration,
                                                 speed: speed, frameCount: frameCount,
                                                 geo: analyze, cancelFlag: cancelFlag,
                                                 progress: { p in analyzeProgress.send(p) })
            } catch RenderError.cancelled {
                throw RenderError.cancelled
            } catch is CancellationError {
                throw RenderError.cancelled
            } catch {
                // Any other pass-1 failure (reader error, Vision unavailable,
                // odd pixel format) → ship the UNSTABILIZED tour rather than
                // failing the whole render (audit F-D-12).
                result = nil
            }
            if cancelFlag.isCancelled { throw RenderError.cancelled }
            if let result {
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
        // Unique temp name in the SAME directory (same volume → the final move
        // is an atomic rename). The existing tour is left untouched until the
        // new file is complete.
        let tempURL = FileStore.recordingsDir
            .appendingPathComponent(".tour-\(asset.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).part.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        let encodeProgress = ProgressThrottle { p in progress(0.45 + 0.53 * p, "Rendering your tour…") }
        do {
            try await encodePass(source: source, srcTrack: srcTrack,
                                 duration: duration, outDuration: outDuration,
                                 speed: speed, frameCount: frameCount,
                                 geo: encode, corrections: corrections, cropZoom: cropZoom,
                                 outURL: tempURL, cancelFlag: cancelFlag,
                                 progress: { p in encodeProgress.send(p) })
        } catch {
            // Never leave a partial mp4 in Documents on failure/cancel — it
            // would linger (and get backed up) forever. The previous tour, if
            // any, is still intact at outURL.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Move into place only now that the writer reported .completed.
        do {
            try replaceItem(at: outURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw RenderError.cannotBuild
        }

        progress(1.0, "Done")
        return Output(url: outURL, durationS: outDuration.seconds, speedFactor: speed, stabilized: stabilized)
    }

    // MARK: - File plumbing

    /// Atomic-as-possible swap: `replaceItemAt` when a previous tour exists
    /// (an APFS rename), a plain move otherwise.
    private static func replaceItem(at dest: URL, with temp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
    }

    /// A render killed mid-encode (app terminated) leaves a `.part.mp4` behind;
    /// clear any older than an hour so they can't accumulate.
    private static func sweepStaleTempFiles(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items where url.lastPathComponent.hasPrefix(".tour-") && url.lastPathComponent.hasSuffix(".part.mp4") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Geometry (orientation + downscale to ≤ longEdge)

    private struct Geometry {
        let renderSize: CGSize
        let normalize: CGAffineTransform   // source pixels → upright render space (top-left origin)
    }

    private static func geometry(naturalSize: CGSize, transform: CGAffineTransform, longEdge: CGFloat) -> Geometry {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let scale = min(1.0, longEdge / max(1, max(orientedSize.width, orientedSize.height)))
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

    /// Tag the composition output as Rec.709 SDR. HDR / Dolby Vision sources
    /// are then tone-mapped by the compositor (not just relabelled by the
    /// writer's color properties) — audit F-D-11. Applied to BOTH passes so
    /// the analysis sees the same picture that gets encoded.
    private static func tag709(_ vc: AVMutableVideoComposition) {
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }

    // MARK: - Pass 1: jitter analysis

    private struct AnalyzeResult { let corrections: [CGPoint] }

    private static func analyzeJitter(source: AVAsset, srcTrack: AVAssetTrack,
                                      duration: CMTime, outDuration: CMTime,
                                      speed: Double, frameCount: Int, geo: Geometry,
                                      cancelFlag: CancelFlag,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> AnalyzeResult? {
        let (composition, compTrack) = try retimeComposition(source: source, srcTrack: srcTrack,
                                                             duration: duration, outDuration: outDuration)

        // Single instruction: orient + scale to small analyze size.
        let vc = AVMutableVideoComposition()
        vc.renderSize = geo.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: outputFPS)
        tag709(vc)
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

        let maxShiftX = geo.renderSize.width * maxPlausibleShiftFraction
        let maxShiftY = geo.renderSize.height * maxPlausibleShiftFraction

        return try await runOnQueue { () throws -> AnalyzeResult? in
            var raw = [CGPoint]()                 // cumulative CONTENT path (top-left coords)
            raw.reserveCapacity(frameCount)
            var pos = CGPoint.zero
            raw.append(pos)

            var previous: CVPixelBuffer?
            var failures = 0
            var seen = 0

            while let sample = output.copyNextSampleBuffer() {
                if cancelFlag.isCancelled { reader.cancelReading(); throw RenderError.cancelled }
                try autoreleasepoolThrowing {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                    if let prev = previous {
                        let req = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
                        let handler = VNImageRequestHandler(cvPixelBuffer: prev, options: [:])
                        do {
                            try handler.perform([req])
                            if let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                                let t = obs.alignmentTransform
                                if abs(t.tx) > maxShiftX || abs(t.ty) > maxShiftY {
                                    // Implausible jump (scene cut / whip pan) — not jitter.
                                    failures += 1
                                } else {
                                    // SIGN (measured empirically, see audit/VISION-SIGN.txt):
                                    // Vision returns the transform aligning CURRENT back onto
                                    // PREVIOUS, in its lower-left image space. In top-left
                                    // content terms that is  Δx = −tx  and  Δy = +ty.
                                    // Accumulating +tx on x amplified horizontal jitter (~1.9×).
                                    pos = CGPoint(x: pos.x - t.tx, y: pos.y + t.ty)
                                }
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

            // Smooth the content path; correction = smoothed − raw moves the
            // content toward the smoothed path. Apply strength.
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
                                   outURL: URL, cancelFlag: CancelFlag,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let (composition, compTrack) = try retimeComposition(source: source, srcTrack: srcTrack,
                                                             duration: duration, outDuration: outDuration)

        let vc = AVMutableVideoComposition()
        vc.renderSize = geo.renderSize
        let fd = CMTime(value: 1, timescale: outputFPS)
        vc.frameDuration = fd
        tag709(vc)

        // One instruction per output frame so each gets its own stabilization transform.
        // (Metadata only — cheap. Same top-left coord space as the content path.)
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
                // ALL-INTRA: every frame is a keyframe. Any scrub position decodes
                // exactly and instantly → buttery, drone-smooth scrubbing (no
                // stepping between sparse keyframes). Costs more bitrate/size, worth
                // it for the scroll-scrub feel. Higher bitrate keeps it crisp.
                AVVideoAverageBitRateKey: 14_000_000,
                AVVideoMaxKeyFrameIntervalKey: 1,          // keyframe every frame (all-intra)
                AVVideoAllowFrameReorderingKey: false,     // no B-frames → every frame independent
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Lets the encoder size its rate control for a 60 fps stream
                // instead of guessing from the first samples.
                AVVideoExpectedSourceFrameRateKey: Int(outputFPS),
            ],
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw RenderError.cannotBuild }
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? RenderError.cannotBuild }
        guard writer.startWriting() else { throw writer.error ?? RenderError.cannotBuild }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(0.01, outDuration.seconds)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if cancelFlag.isCancelled {
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
                                } else if reader.status == .cancelled || cancelFlag.isCancelled {
                                    // A cancelled reader hits EOF early — finishing
                                    // the writer here would ship a TRUNCATED tour.
                                    cont.resume(throwing: RenderError.cancelled)
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
        } catch {
            // Tear down cleanly so the partial file can be deleted (the caller
            // removes outURL) and AVFoundation doesn't dealloc a live writer.
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RenderError.cannotBuild }
    }

    // MARK: - Transform + smoothing helpers

    /// Translate by the correction, then zoom about the center (hides the
    /// moving borders). The translate happens BEFORE the zoom, so it is scaled
    /// by the zoom on screen — divide by `zoom` so the effective on-screen shift
    /// equals the intended correction (audit F-D-30 / VISION-SIGN.txt).
    private static func stabilizeTransform(correction: CGPoint, zoom: CGFloat,
                                           width: CGFloat, height: CGFloat) -> CGAffineTransform {
        let z = max(zoom, 1.0)
        let zoomAboutCenter = CGAffineTransform(translationX: width / 2, y: height / 2)
            .scaledBy(x: z, y: z)
            .translatedBy(x: -width / 2, y: -height / 2)
        let translate = CGAffineTransform(translationX: correction.x / z, y: correction.y / z)
        return translate.concatenating(zoomAboutCenter)   // translate first, then zoom
    }

    /// Pick the smallest crop-zoom that hides the largest correction, then clamp
    /// every correction into that margin so no black borders can appear.
    /// (Margins are in on-screen pixels; stabilizeTransform divides by the zoom
    /// so the applied shift is exactly the clamped value.)
    private static func clampCorrections(_ corrections: [CGPoint], renderSize: CGSize,
                                         zoom: inout CGFloat) -> [CGPoint] {
        let W = max(1, renderSize.width), H = max(1, renderSize.height)
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
