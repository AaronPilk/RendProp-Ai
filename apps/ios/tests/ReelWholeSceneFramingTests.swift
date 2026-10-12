import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import UIKit

@main struct ReelWholeSceneFramingTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image,
                        in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return (0..<3).map { Int(bytes[(y * image.width + x) * 4 + $0]) }
        }
        func similar(_ a: [Int], _ b: [Int]) -> Bool { zip(a,b).allSatisfy { abs($0-$1) < 40 } }
        func frame(_ url: URL, at second: Double) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
        }
        func toneFrequency(_ url: URL) async throws -> Double {
            let asset=AVURLAsset(url:url)
            let track=try await asset.loadTracks(withMediaType:.audio).first!
            // Track belongs to the retained asset used for the reader.
            let actualReader=try AVAssetReader(asset:asset)
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,
                AVSampleRateKey:22050,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,
                AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
            actualReader.add(output);precondition(actualReader.startReading())
            var samples:[Float]=[]
            while let sample=output.copyNextSampleBuffer() {
                guard let block=CMSampleBufferGetDataBuffer(sample) else {continue}
                var bytes=Data(count:CMBlockBufferGetDataLength(block))
                let count=bytes.count
                bytes.withUnsafeMutableBytes{_ = CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:$0.baseAddress!)}
                bytes.withUnsafeBytes{buffer in for index in stride(from:0,to:count,by:4){samples.append(buffer.loadUnaligned(fromByteOffset:index,as:Float.self))}}
            }
            precondition(actualReader.status == .completed)
            // Exclude codec lead/tail silence and inspect the central steady tone.
            let start=max(0,samples.count/4),end=min(samples.count,samples.count*3/4)
            var crossings=0
            if end>start+1 {for i in (start+1)..<end {if samples[i-1]<0 && samples[i]>=0 {crossings+=1}}}
            return Double(crossings)*22050/Double(end-start)
        }
        func source(_ name: String, size: CGSize, rotated: Bool = false, fps: Int = 12) async throws -> URL {
            let format = UIGraphicsImageRendererFormat.default(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor(red: 0.55, green: 0.7, blue: 0.75, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                for (rect, color) in [(CGRect(x:0,y:0,width:size.width * 0.14,height:size.height),UIColor.red),
                    (CGRect(x:size.width * 0.86,y:0,width:size.width * 0.14,height:size.height),UIColor.blue),
                    (CGRect(x:0,y:0,width:size.width,height:size.height * 0.14),UIColor.green),
                    (CGRect(x:0,y:size.height * 0.86,width:size.width,height:size.height * 0.14),UIColor.yellow)] {
                    color.setFill(); ctx.fill(rect)
                }
                UIColor.white.setFill(); ctx.fill(CGRect(x:size.width * 0.40,y:0,width:size.width * 0.02,height:size.height))
            }
            let output = root.appendingPathComponent(name + ".mp4")
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
                AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:10_000_000]])
            if rotated { input.transform = CGAffineTransform(a:0,b:1,c:-1,d:0,tx:size.height,ty:0) }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input, sourcePixelBufferAttributes:[
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:Int(size.width),
                kCVPixelBufferHeightKey as String:Int(size.height),kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
            writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime:.zero)
            let context = CIContext(); let source = CIImage(cgImage:image.cgImage!)
            for i in 0..<fps {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:1_000_000) }
                var buffer:CVPixelBuffer?; precondition(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,adaptor.pixelBufferPool!,&buffer)==kCVReturnSuccess)
                context.render(source, to:buffer!, bounds:CGRect(origin:.zero,size:size), colorSpace:CGColorSpaceCreateDeviceRGB())
                precondition(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(i),timescale:CMTimeScale(fps))))
            }
            input.markAsFinished();writer.endSession(atSourceTime:CMTime(seconds:1,preferredTimescale:600))
            await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in writer.finishWriting {c.resume()} }
            precondition(writer.status == .completed);return output
        }
        let target = CGSize(width:1080,height:1920)
        let wide = try await source("landscape-full-source",size:CGSize(width:1600,height:1200))
        let rotated = try await source("rotated-full-source",size:CGSize(width:1600,height:1200),rotated:true)
        let exact = try await source("already-delivery-aspect",size:target)
        let hashes = try [wide,rotated,exact].map(hash)
        let matching = try await ReelWholeSceneFraming.normalizeIfNeeded(source:exact,renderSize:target,into:root.appendingPathComponent("same"))
        check(matching == exact && (try! hash(exact)) == hashes[2], "matching delivery shape skips an unnecessary encode and keeps original bytes")
        var copies:[URL] = [], observations:[[String:Any]] = []
        for original in [wide,rotated] {
            let output = try await ReelWholeSceneFraming.normalizeIfNeeded(source:original,renderSize:target,into:root.appendingPathComponent("copies"))
            copies.append(output)
            check(output != original,"different delivery shape gets a separate delivery copy")
            let originalFrame = try await frame(original,at:0), fitted = try await frame(output,at:0)
            check(fitted.width == 1080 && fitted.height == 1920,"whole-scene delivery output is actual1080x1920 pixels")
            let asset = AVURLAsset(url:output), originalAsset = AVURLAsset(url:original)
            let duration = try await asset.load(.duration), originalDuration = try await originalAsset.load(.duration)
            check(abs(duration.seconds - originalDuration.seconds)<0.01,"delivery framing preserves the source timeline without speed change")
            let fit = min(target.width/CGFloat(originalFrame.width),target.height/CGFloat(originalFrame.height))
            let offsetX=(target.width-CGFloat(originalFrame.width)*fit)/2,offsetY=(target.height-CGFloat(originalFrame.height)*fit)/2
            for (sx,sy) in [(0.05,0.5),(0.95,0.5),(0.5,0.05),(0.5,0.95),(0.41,0.5)] {
                let x=Int(CGFloat(originalFrame.width)*sx),y=Int(CGFloat(originalFrame.height)*sy)
                let got = pixel(fitted,Int(offsetX+CGFloat(x)*fit),Int(offsetY+CGFloat(y)*fit)), expected = pixel(originalFrame,x,y)
                if !similar(got,expected) {
                    FileHandle.standardOutput.write(Data("pixel mismatch \(original.lastPathComponent) source=\(x),\(y) fit=\(offsetX+CGFloat(x)*fit),\(offsetY+CGFloat(y)*fit) actual=\(got) expected=\(expected)\n".utf8))
                }
                check(similar(got,expected),"sharp foreground retains the whole raw provider frame and its orientation")
            }
            for (x,y) in [(2,2),(1077,2),(2,1917),(1077,1917),(540,2),(540,1917)] {
                check(pixel(fitted,x,y).max()! > 70,"same-scene matte fills encoded delivery edges without black bars")
            }
            if original == wide {
                check(pixel(fitted,310,100).min()! < 235,"delivery padding is blurred same-scene color rather than a sharp duplicate")
            }
            let last = try await frame(output,at:11.0/12)
            check(similar(pixel(last,540,960),pixel(fitted,540,960)),"last source frame remains readable after streaming normalization")
            observations.append(["source_width":originalFrame.width,"source_height":originalFrame.height,
                "output_width":fitted.width,"output_height":fitted.height,"duration":duration.seconds])
        }
        check(try [wide,rotated,exact].map(hash)==hashes,"normalization never overwrites retained paid source clips")
        let cancelled=Task { try Task.checkCancellation();return try await ReelWholeSceneFraming.normalizeIfNeeded(source:wide,renderSize:target,into:root.appendingPathComponent("cancelled")) }
        cancelled.cancel()
        do {_ = try await cancelled.value;preconditionFailure("cancelled framing must stop before reading or encoding") }catch is CancellationError {checks+=1}
        do {_ = try await ReelWholeSceneFraming.normalizeIfNeeded(source:root.appendingPathComponent("missing.mp4"),renderSize:target,into:root);preconditionFailure("unreadable input must not produce a partial reel") }catch{checks+=1}
        if !CommandLine.arguments.contains("--framing-only") {
            let output=root.appendingPathComponent("actual-composed-reel.mp4")
            try await ReelComposer.compose(shots:[.init(url:wide,caption:"WIDE ROOM"),.init(url:exact,caption:"FINAL ROOM")],
                renderSize:target,options:.init(titleCard:.init(title:"QA PROPERTY",subtitle:"WHOLE SCENE",watermark:"Made with Rendprop"),
                    shotCaptionStyle:.lowerThird,transition:.dissolve),output:output)
            let track=try await AVURLAsset(url:output).loadTracks(withMediaType:.video).first!
            let size=try await track.load(.naturalSize),duration=try await AVURLAsset(url:output).load(.duration)
            check(size==target,"actual composer emits1080delivery through existing overlay and transition path")
            check(abs(duration.seconds-1.72)<0.05,"existing dissolve overlap is preserved after whole-scene delivery framing")
            let first=try await frame(output,at:0.3)
            check(similar(pixel(first,30,960),pixel(try await frame(wide,at:0.25),44,600)),"actual composition fits the full sharp scene instead of second cover cropping")
            check(try [wide,rotated,exact].map(hash)==hashes,"final composition preserves all retained source files")
            // Real local PCM audio binds the unchanged independent voice track,
            // including its existing last-frame hold when speech outlasts video.
            let sampleRate=22050, sampleCount=22050*3
            var wav=Data()
            func ascii(_ s:String){wav.append(Data(s.utf8))}
            func little<T:FixedWidthInteger>(_ n:T){var value=n.littleEndian;withUnsafeBytes(of:&value){wav.append(contentsOf:$0)}}
            ascii("RIFF");little(UInt32(36+sampleCount*2));ascii("WAVEfmt ");little(UInt32(16));little(UInt16(1));little(UInt16(1))
            little(UInt32(sampleRate));little(UInt32(sampleRate*2));little(UInt16(2));little(UInt16(16));ascii("data");little(UInt32(sampleCount*2))
            for i in 0..<sampleCount {little(Int16(sin(Double(i)*2*Double.pi*440/Double(sampleRate))*10000))}
            let audioURL=root.appendingPathComponent("local-voice.wav");try wav.write(to:audioURL)
            let aacURL=root.appendingPathComponent("local-voice.m4a")
            let aacExport=AVAssetExportSession(asset:AVURLAsset(url:audioURL),presetName:AVAssetExportPresetAppleM4A)!
            aacExport.outputURL=aacURL;aacExport.outputFileType = .m4a
            await withCheckedContinuation {(c:CheckedContinuation<Void,Never>) in aacExport.exportAsynchronously {c.resume()}}
            guard aacExport.status == .completed else {throw aacExport.error!}
            let aacBytes=try Data(contentsOf:aacURL)
            for fps in [12,24,30] {
            let tail = fps == 12 ? exact : try await source("tail-\(fps)fps",size:target,fps:fps)
            let tailAsset=AVURLAsset(url:tail)
            let tailTrack=try await tailAsset.loadTracks(withMediaType:.video).first!
            let tailRange=try await tailTrack.load(.timeRange)
            let heldRange=await ReelComposer.auditedSourceHoldRange(track:tailTrack,range:tailRange)
            check(abs(heldRange.start.seconds-(1-1/Double(fps)))<0.002,"voice hold selects the actual final source frame instead of assuming thirty fps")
            check(abs(heldRange.duration.seconds-1/Double(fps))<0.002,"voice hold stretches exactly one measured source frame")
            _ = tailAsset // Keep a retained source asset beside the sample-reader proof.
            let voiced=root.appendingPathComponent("actual-voice-hold-reel-\(fps)fps.mp4")
            try await ReelComposer.compose(shots:[.init(url:wide),.init(url:tail)],renderSize:target,
                options:.init(titleCard:.init(title:"LOCAL QA",subtitle:"VOICE HOLD",watermark:"Rendprop"),
                    voiceover:.init(audioURL:audioURL,duration:3,transcript:"Local QA",words:[.init(text:"Local",start:0,end:0.5)],source:.myVoice),
                    captionStyle:.standard,transition:.dissolve),output:voiced)
            let voicedAsset=AVURLAsset(url:voiced), voicedDuration=try await voicedAsset.load(.duration)
            let audioTracks=try await voicedAsset.loadTracks(withMediaType:.audio)
            check(audioTracks.count==1,"existing voiceover remains a real independent audio track")
            check(abs(voicedDuration.seconds-3)<0.05,"voice-overrun still holds the final framed scene instead of clipping speech")
            let audioRange=try await audioTracks[0].load(.timeRange)
            FileHandle.standardOutput.write(Data("voice timing fps=\(fps) output=\(voicedDuration.seconds) audioStart=\(audioRange.start.seconds) audioDuration=\(audioRange.duration.seconds)\n".utf8))
            check(audioRange.duration.seconds > 2.8 && audioRange.duration.seconds < 3.15,"encoded voice spans the original three-second take within AAC priming")
            let frequency=try await toneFrequency(voiced)
            check(abs(frequency-440)<4,"delivery video framing never speeds up the voice track")
            let held=try await frame(voiced,at:2.8)
            check(pixel(held,540,960).max()!>70,"voice hold contains the last scene instead of an uncovered black frame")
            check(try Data(contentsOf:audioURL)==wav && Data(contentsOf:aacURL)==aacBytes,"independent voice source bytes remain unchanged")
            }
        }
        try JSONSerialization.data(withJSONObject:["checks":checks,"observations":observations,"source_hashes":hashes],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PASS: \(checks) actual AVFoundation whole-scene framing/composition assertions")
    }
}
