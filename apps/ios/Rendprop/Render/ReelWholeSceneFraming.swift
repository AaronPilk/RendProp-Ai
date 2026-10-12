import AVFoundation
import CoreImage
import Foundation

/// Delivery framing runs after raw provider frames pass property QC. The
/// complete decoded scene is fitted, never cropped, over a blurred copy of
/// that same frame. This cannot recover details a provider already removed.
enum ReelWholeSceneFraming {
    enum FramingError: LocalizedError {
        case unreadable, invalidSize, encoder, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read a saved clip for the reel. Your clips have been kept."
            case .invalidSize: return "Couldn't work out the reel's video size."
            case .encoder: return "Couldn't prepare a full-scene clip. Your clips have been kept."
            case .empty: return "The full-scene clip was empty. Your clips have been kept."
            }
        }
    }

    /// Same-aspect clips keep their original bytes and avoid another encode.
    /// Only delivery copies use the matte; retained paid originals stay intact.
    static func normalizeIfNeeded(source: URL, renderSize: CGSize, into directory: URL) async throws -> URL {
        try Task.checkCancellation()
        guard renderSize.width.isFinite, renderSize.height.isFinite,
              renderSize.width >= 16, renderSize.height >= 16,
              renderSize.width.rounded() == renderSize.width, renderSize.height.rounded() == renderSize.height else {
            throw FramingError.invalidSize
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FramingError.unreadable }
        let (natural, preferred, range) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        let display = CGRect(origin: .zero, size: natural).applying(preferred)
        guard display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0,
              range.duration.seconds.isFinite, range.duration > .zero else { throw FramingError.unreadable }
        let sourceRatio = display.width / display.height, targetRatio = renderSize.width / renderSize.height
        if abs(sourceRatio - targetRatio) < 0.00001 { return source }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("full-scene-\(UUID().uuidString).mp4")
        do {
            try await normalize(asset: asset, track: track, preferred: preferred, range: range,
                                renderSize: renderSize, output: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Shared pure geometry also executes against encoded edge-marked fixtures.
    static func framedImage(_ image: CIImage, renderSize: CGSize) -> CIImage {
        let extent = image.extent
        let source = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let width = extent.width, height = extent.height
        let canvas = CGRect(origin: .zero, size: renderSize)
        let cover = max(renderSize.width / width, renderSize.height / height)
        let background = source.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
            .transformed(by: CGAffineTransform(translationX: (renderSize.width - width * cover) / 2,
                                               y: (renderSize.height - height * cover) / 2))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(renderSize.width, renderSize.height) * 0.035])
            .cropped(to: canvas)
        let fit = min(renderSize.width / width, renderSize.height / height)
        let foreground = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: (renderSize.width - width * fit) / 2,
                                               y: (renderSize.height - height * fit) / 2))
        return foreground.composited(over: background).cropped(to: canvas)
    }

    /// AV track transforms are expressed in top-left display coordinates;
    /// CoreImage uses bottom-left. Convert both sides before applying rotation.
    static func orientedImage(_ image: CIImage, preferred: CGAffineTransform) -> CIImage {
        let box = image.extent
        let source = image.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        let topLeft = source.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.height))
        let rotated = topLeft.transformed(by: preferred)
        let bounds = rotated.extent
        return rotated.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height))
    }

    private static func normalize(asset: AVAsset, track: AVAssetTrack, preferred: CGAffineTransform,
                                  range: CMTimeRange, renderSize: CGSize, output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let read = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        read.alwaysCopiesSampleData = false
        guard reader.canAdd(read) else { throw FramingError.unreadable }
        reader.add(read); reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let width = Int(renderSize.width), height = Int(renderSize.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw FramingError.encoder }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? FramingError.encoder }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var firstTime: CMTime?, frames = 0
        do {
            while let sample = read.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw FramingError.unreadable }
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstTime == nil { firstTime = sourceTime }
                let time = CMTimeSubtract(sourceTime, firstTime!)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing else { throw writer.error ?? FramingError.encoder }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else { throw FramingError.encoder }
                var destination: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
                      let destination else { throw FramingError.encoder }
                let image = orientedImage(CIImage(cvPixelBuffer: pixels), preferred: preferred)
                context.render(framedImage(image, renderSize: renderSize), to: destination,
                               bounds: CGRect(origin: .zero, size: renderSize), colorSpace: colorSpace)
                guard adaptor.append(destination, withPresentationTime: time) else { throw writer.error ?? FramingError.encoder }
                frames += 1
                if frames % 4 == 0 { await Task.yield() }
            }
            try Task.checkCancellation()
            guard reader.status == .completed, frames > 0 else { throw reader.error ?? FramingError.empty }
            input.markAsFinished()
            writer.endSession(atSourceTime: range.duration)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            try Task.checkCancellation()
            guard writer.status == .completed,
                  ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                throw writer.error ?? FramingError.empty
            }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }
}
