import Foundation
import ImageIO
import CoreGraphics

@main struct CaptureOrientationTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let listing = CaptureGuideIntent.listingPhotos, social = CaptureGuideIntent.socialPhotos
        check(listing.illustrativeRotationDegrees == 90 && social.illustrativeRotationDegrees == 0, "purpose selects landscape or portrait guidance")
        for reduce in [false,true] { for active in [false,true] { for paused in [false,true] {
            check(CaptureGuideAnimationPolicy(reduceMotion: reduce, sceneIsActive: active, userPaused: paused).animates == (!reduce && active && !paused), "reduced motion, background and pause each stop animation")
        }}}
        let wide = DeliveryCrop.centered(sourceWidth: 1920, sourceHeight: 1440, deliveryAspect: 16.0/9.0)!
        check(wide == DeliveryCrop(x:0,y:0.125,width:1,height:0.75), "four-to-three photo has exact centered widescreen crop")
        let portrait = DeliveryCrop.centered(sourceWidth: 1920, sourceHeight: 1440, deliveryAspect: 9.0/16.0)!
        check(abs(portrait.x - 0.2890625) < 0.00001 && abs(portrait.width - 0.421875) < 0.00001 && portrait.height == 1, "portrait preview shows the real large side trim of a wide source")
        check(DeliveryCrop.centered(sourceWidth: 0, sourceHeight: 1440, deliveryAspect: 1) == nil, "invalid crop dimensions refuse")
        check(DeliveryCrop.centered(sourceWidth: 1000, sourceHeight: 1000, deliveryAspect: .nan) == nil, "nonfinite target crop refuses")
        check(VideoAspectChoice.allCases.first == .listing, "listing is the first new-video destination")
        check(VideoFramingReviewPolicy.displayedSize(width:4000,height:3000,exifOrientation:6)?.0 == 3000, "EXIF rotation determines imported displayed orientation")
        check(VideoFramingReviewPolicy.displayedSize(width:4000,height:3000,exifOrientation:9) == nil, "unknown EXIF orientation cannot fake a framing review")
        check(VideoPreparedSourcePolicy.cropMeetsFloor(width:896,height:1195,aspect:"16:9"), "saved896x1195 photo keeps896x504 landscape crop above the480 floor")
        check(VideoPreparedSourcePolicy.cropMeetsFloor(width:855,height:480,aspect:"16:9"), "even480pixel crop boundary remains usable")
        check(!VideoPreparedSourcePolicy.cropMeetsFloor(width:480,height:640,aspect:"16:9") && VideoPreparedSourcePolicy.cropMeetsFloor(width:480,height:854,aspect:"9:16"), "the selected destination determines the actual crop floor")
        check(!VideoPreparedSourcePolicy.cropMeetsFloor(width:2048,height:256,aspect:"16:9"), "undersized panorama copy needs different input rather than a claim about its original")
        func jpeg(_ width: Int, _ height: Int, gray: CGFloat = 0.5, orientation: Int = 1) -> Data {
            let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray:gray,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
            let bytes=NSMutableData(), destination=CGImageDestinationCreateWithData(bytes,"public.jpeg" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,[kCGImagePropertyOrientation:orientation] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination));return bytes as Data
        }
        let savedJPEG=jpeg(896,1195), secondJPEG=jpeg(1195,896,gray:0.8), tinyJPEG=jpeg(160,120)
        try VideoPreparedSourcePolicy.requireUsableJPEG(savedJPEG,aspect:"16:9")
        try VideoPreparedSourcePolicy.requireUsableJPEG(jpeg(480,854),aspect:"9:16")
        var tinyRefused=false
        do { try VideoPreparedSourcePolicy.requireUsableJPEG(tinyJPEG,aspect:"16:9") }
        catch { tinyRefused=error.localizedDescription.contains("video copy") && error.localizedDescription.contains("landscape") && !error.localizedDescription.contains("1080") }
        check(tinyRefused, "actual thumbnail JPEG refuses before upload with conditional framing guidance")
        try VideoPreparedSourcePolicy.requireUsableJPEG(jpeg(854,480,orientation:6),aspect:"9:16")
        checks += 3
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        func stageDirectory() -> URL {
            let d=directory.appendingPathComponent(UUID().uuidString);try! FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);return d
        }
        let photoBytes=["B2":savedJPEG,"A1":secondJPEG,"tiny":tinyJPEG]
        var identityChecks=0, preparationProgress:[Int]=[]
        let staged=try await VideoPreparedSourcePolicy.stage(["B2","A1"],aspect:"16:9",directory:stageDirectory(),
            maximumJPEGBytes:8*1024*1024,maximumBase64Bytes:128*1024*1024,
            progress:{number,total in preparationProgress.append(number);check(total==2,"preparation progress reports the real selected count")},
            requireCurrent:{identityChecks+=1},prepare:{photoBytes[$0]!})
        check(try staged.map {try Data(contentsOf:$0)} == [savedJPEG,secondJPEG], "all exact staged JPEGs preserve manualB2A1 order and master bytes")
        check(identityChecks==3, "source staging rechecks current identity per photo and before returning")
        check(preparationProgress==[1,2], "preparation progress follows actual source staging without a provider percentage")
        var uploads=0, smallBatchRefused=false
        do {
            let files=try await VideoPreparedSourcePolicy.stage(["B2","tiny"],aspect:"16:9",directory:stageDirectory(),
                maximumJPEGBytes:8*1024*1024,maximumBase64Bytes:128*1024*1024,
                requireCurrent:{},prepare:{photoBytes[$0]!})
            uploads+=files.count
        } catch { smallBatchRefused=true }
        check(smallBatchRefused && uploads==0, "one later tiny source refuses the whole selection before first upload or paid plan")
        var current=true, preparedCount=0, revoked=false
        do {
            _=try await VideoPreparedSourcePolicy.stage(["B2","A1"],aspect:"16:9",directory:stageDirectory(),
                maximumJPEGBytes:8*1024*1024,maximumBase64Bytes:128*1024*1024,
                requireCurrent:{if !current {throw CancellationError()}},prepare:{id in preparedCount+=1;current=false;return photoBytes[id]!})
        } catch is CancellationError { revoked=true }
        check(revoked && preparedCount==1, "changed actor or consent stops unsent source staging")
        var sizeRefused=false
        do {
            _=try await VideoPreparedSourcePolicy.stage(["B2"],aspect:"16:9",directory:stageDirectory(),
                maximumJPEGBytes:savedJPEG.count-1,maximumBase64Bytes:128*1024*1024,requireCurrent:{},prepare:{photoBytes[$0]!})
        } catch VideoPreparedSourcePolicy.Failure.photoTooLarge {sizeRefused=true}
        check(sizeRefused, "source staging preserves the existing perJPEG byte cap")
        var batchRefused=false
        do {
            _=try await VideoPreparedSourcePolicy.stage(["B2","B2"],aspect:"16:9",directory:stageDirectory(),
                maximumJPEGBytes:8*1024*1024,maximumBase64Bytes:((savedJPEG.count+2)/3)*4*2-1,requireCurrent:{},prepare:{photoBytes[$0]!})
        } catch VideoPreparedSourcePolicy.Failure.batchTooLarge {batchRefused=true}
        check(batchRefused, "source staging preserves the existing total base64 cap before upload")
        let imageContext=CGContext(data:nil,width:40,height:30,bitsPerComponent:8,bytesPerRow:160,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        imageContext.setFillColor(CGColor(gray:0.5,alpha:1));imageContext.fill(CGRect(x:0,y:0,width:40,height:30))
        let actual=imageContext.makeImage()!,wideURL=directory.appendingPathComponent("wide.jpg"),rotatedURL=directory.appendingPathComponent("rotated.jpg")
        for (url,orientation) in [(wideURL,1),(rotatedURL,6)] {
            let writer=CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil)!
            CGImageDestinationAddImage(writer,actual,[kCGImagePropertyOrientation:orientation] as CFDictionary)
            check(CGImageDestinationFinalize(writer), "the owned framing fixture writes valid JPEG bytes")
        }
        let wideBytes=try! Data(contentsOf:wideURL), rotatedBytes=try! Data(contentsOf:rotatedURL)
        let wideRead=VideoPhotoFramingReader.read(photoID:"wide-reviewed",url:wideURL,aspect:16.0/9.0)!
        let rotatedRead=VideoPhotoFramingReader.read(photoID:"staged-reviewed",url:rotatedURL,aspect:16.0/9.0)!
        check(wideRead.displayedWidth==40 && wideRead.displayedHeight==30 && !wideRead.isMajorCrop,"actual decoded landscape photo keeps a modest widescreen crop")
        check(rotatedRead.displayedWidth==30 && rotatedRead.displayedHeight==40 && rotatedRead.isMajorCrop,"actual EXIF-rotated JPEG gets the major portrait-to-landscape warning")
        let key=VideoFramingReviewPolicy.selectionKey(aspect:"16:9",photoIDs:["wide-reviewed","staged-reviewed"])
        check(VideoFramingReviewPolicy.needsAcknowledgment(assessments:[wideRead,rotatedRead],selectionKey:key,acknowledgedKey:nil),"large crops require aggregate review before generation")
        check(!VideoFramingReviewPolicy.needsAcknowledgment(assessments:[wideRead,rotatedRead],selectionKey:key,acknowledgedKey:key),"the exact acknowledged selection does not ask again per photo")
        let changedKey=VideoFramingReviewPolicy.selectionKey(aspect:"9:16",photoIDs:["wide-reviewed","staged-reviewed"])
        check(VideoFramingReviewPolicy.needsAcknowledgment(assessments:[rotatedRead],selectionKey:changedKey,acknowledgedKey:key),"changing the target format cannot reuse a crop acknowledgment")
        check(try! Data(contentsOf:wideURL)==wideBytes && Data(contentsOf:rotatedURL)==rotatedBytes,"framing review never rewrites or stretches saved originals")
        check(VideoPhotoFramingReader.read(photoID:"missing",url:directory.appendingPathComponent("missing.jpg"),aspect:16.0/9.0)==nil,"unreadable selected source cannot fake a crop preview")
        let hash = String(repeating:"a",count:64), evidence = String(repeating:"b",count:64)
        let track = VerifiedMusicTrack(id:"closed",title:"Closed test fixture",assetRelativePath:"Music/closed.m4a",assetSHA256:hash,
            licenseID:"TEST-NOT-A-REAL-LICENSE",licenseEvidenceSHA256:evidence,commerciallyVerified:true,
            webAndSocialRedistributionVerified:true,attributionRequired:false,instrumentalVerified:true,measuredDurationS:20)
        check(track.isEligible, "closed reviewed fixture qualifies for metadata-bound selection")
        let selection = VideoMusicSelection(trackID:track.id,assetSHA256:hash,licenseID:track.licenseID,licenseEvidenceSHA256:evidence)
        check(selection.checked(catalog:[]) == nil, "empty production catalog admits no music")
        check(selection.checked(catalog:[track]) == track, "matching catalog asset and license evidence admit only that exact track")
        var changed = VideoMusicSelection(trackID:track.id,assetSHA256:evidence,licenseID:track.licenseID,licenseEvidenceSHA256:evidence)
        check(changed.checked(catalog:[track]) == nil, "changed track bytes cannot reuse a license receipt")
        changed = VideoMusicSelection(trackID:track.id,assetSHA256:hash,licenseID:track.licenseID,licenseEvidenceSHA256:hash)
        check(changed.checked(catalog:[track]) == nil, "changed license evidence cannot be silently restored")
        changed = selection; changed.gain = 0.8
        check(changed.checked(catalog:[track]) == nil, "music cannot exceed restrained gain ceiling")
        let loops = VideoMusicTimeline.loops(trackDurationS:20,finalVideoDurationS:53)!
        check(loops.map(\.durationS) == [20,20,13] && loops.last!.destinationStartS + loops.last!.durationS == 53, "music ends on video duration without extending it")
        check(VideoMusicTimeline.loops(trackDurationS:0,finalVideoDurationS:53) == nil, "empty music cannot enter an infinite loop")
        check(VideoMusicTimeline.loops(trackDurationS:5,finalVideoDurationS:601) == nil, "music preserves the documented video-duration bound")
        check(VideoMusicTimeline.gain(at:5,narrationDurationS:10,selection:selection) == 0.07 && VideoMusicTimeline.gain(at:12,narrationDurationS:10,selection:selection) == 0.18, "music stays quiet under narration and recovers after speech")
        print("PASS: \(checks) purpose, reduced-motion, actual JPEG floor/all-source staging, real crop, closed-license metadata and music-timeline assertions; no UI/network")
    }
}
