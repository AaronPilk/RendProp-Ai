// The gate appends this extension to a TEMPORARY copy of the complete, actual
// RenderEngine.swift. No production visibility/test door is added. The only
// fake is a writer input that exercises documented "not ready" backpressure;
// reader/writer lifecycle and EncodeSession are the real AVFoundation/code.
extension RenderEngine {
    private final class StalledWriterInput: AVAssetWriterInput {
        let requested = DispatchSemaphore(value: 0)
        override var isReadyForMoreMediaData: Bool { false }
        override func requestMediaDataWhenReady(on queue: DispatchQueue,
                                                using block: @escaping @Sendable () -> Void) {
            queue.async(execute: block)
            requested.signal()
        }
    }

    static func verifyStalledCancellation(sourceURL: URL, directory: URL) async throws {
        let source = AVURLAsset(url: sourceURL)
        let track = try await source.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: source)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 64, height: 48)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(.identity, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        output.videoComposition = composition
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("stalled.mp4"), fileType: .mp4)
        let input = StalledWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        writer.add(input)
        let queue = DispatchQueue(label: "rendprop.fixture.stalled")
        let session = EncodeSession(reader: reader, output: output, writer: writer, input: input,
                                    queue: queue,
                                    cancelFlag: CancelFlag(), duration: 1.5, progress: { _ in })
        let task = Task.detached { try await session.run() }
        let requested = input.requested
        let didRequest = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { cont.resume(returning: requested.wait(timeout: .now() + 5) == .success) }
        }
        guard didRequest else {
            fatalError("stalled fixture never reached requestMediaDataWhenReady")
        }
        // Observe the only ready callback finishing before cancellation. The
        // mutant cannot accidentally pass because that callback sees the flag.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if finished.wait(timeout: .now() + 3) != .success {
                // A deliberate removed-cancel-wakeup mutant must exit1 here,
                // not time out and be mistaken for a product/test success.
                FileHandle.standardError.write(Data("FAIL: stalled encode cancellation did not resume\n".utf8))
                exit(1)
            }
        }
        task.cancel()
        let result = await task.result
        finished.signal()
        guard case .failure(RenderError.cancelled) = result else {
            fatalError("stalled cancellation returned the wrong result")
        }
        guard reader.status == .cancelled, writer.status == .cancelled else {
            fatalError("stalled cancellation did not close the actual reader/writer")
        }
        print("PASS: 3 stalled-session assertions; cancellation wakes without another ready callback; 0 skips")
    }
}
