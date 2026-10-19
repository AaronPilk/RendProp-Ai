import AVFoundation
import CoreImage
import Foundation
import UIKit

enum FileStore {
    static var documents:URL {URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)}
    static func relativePath(for url:URL)->String {String(url.path.dropFirst(documents.path.count+1))}
    static func fileSize(_ url:URL)->Int64 {Int64((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
}
/// Headless AVFoundation encoding; no app, UI, account or camera is launched.
@main struct VideoDeliveryEncodingTests {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var checks=0
        func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
        func frame(_ url:URL,_ time:Double) async throws->CGImage {
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url))
            generator.appliesPreferredTrackTransform=true
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
        }
        func center(_ image:CGImage)->[Int] {
            var data=[UInt8](repeating:0,count:image.width*image.height*4)
            data.withUnsafeMutableBytes { p in
                CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
            let offset=((image.height/2)*image.width+image.width/2)*4
            return [Int(data[offset]),Int(data[offset+1]),Int(data[offset+2])]
        }
        func cleanFrame(_ image:CGImage, expected:[Int])->Bool {
            var data=[UInt8](repeating:0,count:image.width*image.height*4)
            data.withUnsafeMutableBytes { p in
                CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
            for y in stride(from:4,to:image.height,by:8) { for x in stride(from:4,to:image.width,by:8) {
                let offset=(y*image.width+x)*4
                if (0..<3).contains(where:{abs(Int(data[offset+$0])-expected[$0])>20}) {return false}
            }}
            return true
        }
        let colors:[(CGFloat,CGFloat,CGFloat)]=[(0.9,0.15,0.1),(0.1,0.8,0.15),(0.1,0.2,0.9),(0.9,0.8,0.1),(0.85,0.1,0.85),(0.1,0.8,0.85),(0.45,0.15,0.1),(0.1,0.45,0.2),(0.1,0.2,0.45),(0.5,0.45,0.1),(0.45,0.1,0.45),(0.1,0.45,0.45)]
        var clips:[URL]=[],pixels:[[Int]]=[]
        for (index,color) in colors.enumerated() {
            let format=UIGraphicsImageRendererFormat.default();format.scale=1;format.opaque=true
            let image=UIGraphicsImageRenderer(size:CGSize(width:120,height:90),format:format).image {ctx in
                UIColor(red:color.0,green:color.1,blue:color.2,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:120,height:90))
            }
            let url=root.appendingPathComponent("source-\(index).mp4")
            let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
            let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:120,AVVideoHeightKey:90])
            let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:120,kCVPixelBufferHeightKey as String:90,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
            writer.add(input);check(writer.startWriting(),"procedural source encoder starts")
            writer.startSession(atSourceTime:.zero)
            let context=CIContext(),source=CIImage(cgImage:image.cgImage!)
            for i in 0..<3 {
                while !input.isReadyForMoreMediaData {try await Task.sleep(nanoseconds:1_000_000)}
                var pixel:CVPixelBuffer?;check(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,adaptor.pixelBufferPool!,&pixel)==kCVReturnSuccess,"procedural source pixel buffer")
                context.render(source,to:pixel!,bounds:CGRect(x:0,y:0,width:120,height:90),colorSpace:CGColorSpaceCreateDeviceRGB())
                check(adaptor.append(pixel!,withPresentationTime:CMTime(value:Int64(i),timescale:12)),"procedural source frame encoded")
            }
            input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:3,timescale:12))
            await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in writer.finishWriting{c.resume()}}
            check(writer.status == .completed,"procedural source encoder completes")
            clips.append(url);pixels.append(center(try await frame(url,0)))
        }
        let listingID=UUID(),owner=UUID().uuidString,workspace=UUID(),serverListing=UUID()
        try FileManager.default.createDirectory(at:root.appendingPathComponent("reels"),withIntermediateDirectories:true)
        let sources=(0..<12).map { ListingVideoSource(photoVersionID:"photo-version-\($0)",photoAssetID:UUID().uuidString,motionKind:"original_photo") }
        var output:[[String:Any]]=[]
        for choice in VideoAspectChoice.allCases {
            let url=root.appendingPathComponent("reels/\(listingID.uuidString)-\(choice.rawValue).mp4")
            let requestedCard: ReelTitleCard? = choice == .listing ? ReelTitleCard(title: "Agent brand", subtitle: "A company", watermark: "Made with Rendprop") : nil
            let title = VideoBrandingPolicy.titleCard(requestedCard, aspect: choice.aspect)
            check(choice != .listing || title == nil,"listing title-card policy suppresses app branding before encoding")
            try await ReelComposer.compose(shots:clips.map{.init(url:$0)},renderSize:CGSize(width:CGFloat(choice.width),height:CGFloat(choice.height)),options:.init(titleCard:title),output:url)
            let duration=try await AVURLAsset(url:url).load(.duration)
            check(abs(duration.seconds-3)<0.05,"12-shot video retains every clip in its full timeline")
            let first=try await frame(url,0.1)
            check(first.width == (choice == .listing ? 1920:1080) && first.height == (choice == .listing ? 1080:1920),"delivered purpose uses actual 1080p orientation pixels")
            for index in 0..<12 {
                let encodedFrame=try await frame(url,Double(index)*0.25+0.1)
                let actual=center(encodedFrame)
                if choice == .listing {check(cleanFrame(encodedFrame,expected:pixels[index]),"listing master retains full clean source pixels without baked branding or panels")}
                check(zip(actual,pixels[index]).allSatisfy{abs($0-$1)<20},"all twelve source shots retain exact order in encoded video")
            }
            let record=try await ListingVideoPreparation.retain(output:url,listingID:listingID,ownerID:owner,
                workspaceID:workspace,serverListingID:serverListing,purpose:choice,sources:sources,includesOpeningClip:false,brandingPolicy:choice == .listing ? "unbranded" : nil)
            check((try? ListingVideoStore.load(for:url))==record,"finished video metadata survives independent reload before selection")
            check(record.width==first.width && record.height==first.height && abs(record.durationS-duration.seconds)<0.05,"retained metadata comes from actual encoded video shape and duration")
            check(record.sources.map(\.photoVersionID)==sources.map(\.photoVersionID) && record.canSelectForWebsite==(choice == .listing),"actual output retains its ordered sources and destination eligibility")
            output.append(["purpose":choice.rawValue,"width":first.width,"height":first.height,"seconds":duration.seconds,"shots":12,"centerColorOrderChecked":true])
        }
        let result:[String:Any]=["passed":true,"checks":checks,"outputs":output,"headlessKernelOnly":true,"UIExecutions":0,"cameraCalls":0,"providerCalls":0]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PASS: \(checks) actual encoded 1080p purpose/orientation and twelve-shot order assertions")
    }
}
