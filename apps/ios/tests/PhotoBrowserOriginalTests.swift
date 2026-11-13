import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "PhotoBrowserOriginalTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAIL: " + message]) }
}

@main struct PhotoBrowserOriginalTests {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8));exit(1) }
    }
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-browser-original-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let width = 768, height = 1024
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Detailed color variation catches a degraded JPEG while point samples
        // away from edges also prove the source color space was retained.
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 4) {
                // Broad painted surfaces plus luminance texture are a photo
                // control. A one-pixel alternating color checker measures
                // JPEG chroma subsampling rather than this conversion route.
                let texture = CGFloat((x * 13 + y * 7) % 25 - 12) / 255
                let r = 0.12 + 0.7 * CGFloat(x) / CGFloat(width) + texture
                let g = 0.15 + 0.65 * CGFloat(y) / CGFloat(height) + texture
                let b = 0.2 + 0.55 * CGFloat(x + y) / CGFloat(width + height) + texture
                ctx.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 1))
            }
        }
        let image = ctx.makeImage()!
        func write(_ url: URL, _ type: UTType, orientation: Int = 6) throws {
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw NSError(domain: "PhotoBrowserOriginalTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encoder unavailable: " + type.identifier])
            }
            CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImagePropertyOrientation: orientation] as CFDictionary)
            try check(CGImageDestinationFinalize(d), "fixture image encoded")
        }
        let source = folder.appendingPathComponent("raw-heic-with-legacy-jpg-name.jpg")
        try write(source, .heic)
        let rawBytes = try Data(contentsOf: source)
        let prepared = try PhotoBrowserOriginal.prepare(source)
        defer { prepared.removeTemporaryFiles() }
        try check(prepared.convertedToJPEG && prepared.url.pathExtension == "jpg" && prepared.sourceType == UTType.heic.identifier, "actual HEIC bytes detected despite oldjpg name")
        try check(prepared.pixelWidth == width && prepared.pixelHeight == height && prepared.orientation == 6, "full resolution and rotated source orientation retained")
        try check(prepared.note?.contains("unchanged source file") == true, "conversion honestly labeled rather than byte-exact claim")
        try check(Data(contentsOf: source) == rawBytes, "originalHEIC bytes never replaced or removed")
        let before = CGImageSourceCreateWithURL(source as CFURL, nil)!, after = CGImageSourceCreateWithURL(prepared.url as CFURL, nil)!
        let a = CGImageSourceCreateImageAtIndex(before, 0, nil)!, b = CGImageSourceCreateImageAtIndex(after, 0, nil)!
        try check(a.width == b.width && a.height == b.height && b.width == width && b.height == height, "no crop or downsample")
        try check(a.colorSpace?.name == b.colorSpace?.name, "embeddedsource color space preserved")
        func rgba(_ img: CGImage) -> [UInt8] {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
            defer { buffer.deallocate() }
            let c = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }
        let first = rgba(a), second = rgba(b)
        var delta: Int64 = 0, count = 0
        for i in 0..<first.count where i % 4 != 3 { delta += Int64(abs(Int(first[i]) - Int(second[i])));count += 1 }
        let mean = Double(delta) / Double(count)
        try check(mean < 3, "highquality color detail survives browserJPEG (meanerror \(mean))")
        let again = try PhotoBrowserOriginal.prepare(source)
        defer { again.removeTemporaryFiles() }
        try check(Data(contentsOf: prepared.url) == Data(contentsOf: again.url), "same source gives stable browserbytes for existing upload recovery")
        let pngWrongName = folder.appendingPathComponent("png-with-jpg-name.jpg")
        try write(pngWrongName, .png, orientation: 1)
        let pngBytes = try Data(contentsOf: pngWrongName)
        let fixedPNG = try PhotoBrowserOriginal.prepare(pngWrongName)
        defer { fixedPNG.removeTemporaryFiles() }
        try check(fixedPNG.url.pathExtension == "png" && !fixedPNG.convertedToJPEG, "actualPNG keeps correct MIMEextension without JPEGconversion")
        try check(Data(contentsOf: fixedPNG.url) == pngBytes && Data(contentsOf: pngWrongName) == pngBytes, "alreadybrowsercompatible bytes copiedexactly")
        let jpeg = folder.appendingPathComponent("already-jpeg.jpg");try write(jpeg, .jpeg)
        let pass = try PhotoBrowserOriginal.prepare(jpeg)
        try check(pass.url == jpeg && pass.temporaryDirectory == nil && !pass.convertedToJPEG, "alreadyJPEGsource passes without copy or re-encoding")
        let broken = folder.appendingPathComponent("broken.jpg");try Data("not-image".utf8).write(to: broken)
        do { _ = try PhotoBrowserOriginal.prepare(broken);try check(false,"corruptoriginal refused") }
        catch let error as PhotoBrowserOriginal.Failure { try check(error.message.contains("unreadable"), "corruptoriginal has explicit failure") }
        print("PASS: actualHEIC→fullresolutionJPEG, orientation6, P3color meanerror\(mean), stable retrybytes, exactPNG/JPEG and corruptsource refusal")
    }
}
