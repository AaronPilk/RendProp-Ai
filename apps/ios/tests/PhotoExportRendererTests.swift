// Synthetic renderer fixture. No customer media, camera, provider or Photos writes.
import Foundation
import UIKit
import ImageIO

@main struct RendererTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ text: String) {
            precondition(condition(), text); checks += 1
        }
        func brightness(_ image: UIImage, x: Int, y: Int) -> Int {
            let cg = image.cgImage!, width = cg.width, height = cg.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let offset = (y * width + x) * 4
            return (Int(data[offset]) + Int(data[offset+1]) + Int(data[offset+2])) / 3
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 300))
        }
        let rendered = PhotoExportRenderer.render(source, aspect: .original, framing: .fit, label: nil)
        check(rendered.cgImage?.width == 400 && rendered.cgImage?.height == 300, "original pixel dimensions preserved")
        check(brightness(rendered, x: 380, y: 285) == 255, "clean image no overlay")
        let labelled = PhotoExportRenderer.render(source, aspect: .original, framing: .fit, label: "Virtually staged")
        check(brightness(labelled, x: 380, y: 285) < 100, "label strip visible at full-resolution output")
        check(brightness(labelled, x: 380, y: 20) == 255, "label does not alter upper image")
        let crop = PhotoExportRenderer.render(source, aspect: .portrait, framing: .crop, label: nil)
        check(crop.cgImage?.width == 169 && crop.cgImage?.height == 300, "portrait crop dimensions")
        check(brightness(crop, x: 0, y: 50) == 255, "center crop actually excludes left red strip")
        let fit = PhotoExportRenderer.render(source, aspect: .portrait, framing: .fit, label: nil)
        check(fit.cgImage?.width == 225 && fit.cgImage?.height == 400, "fit preserves canvas ratio without upscaling")
        check(brightness(fit, x: 0, y: 0) == 255, "fit adds white border")
        let oriented = UIImage(cgImage: source.cgImage!, scale: 1, orientation: .right)
        let rotated = PhotoExportRenderer.render(oriented, aspect: .original, framing: .fit, label: nil)
        check(rotated.cgImage?.width == 300 && rotated.cgImage?.height == 400, "orientation reflected in actual output pixels")
        check(rotated.imageOrientation == .up, "orientation baked into pixels")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = source.jpegData(compressionQuality: 0.92)!
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "capture", directory: root)
        let version = try PhotoVersionHistory.saveEdit(jpeg: original, id: "stage", parentID: "capture", sourceID: "capture", edit: "stage", style: "modern",
                                                      disclosure: "Furniture digitally added.", provenanceID: "row", provenanceRecorded: true, directory: root)
        let photo = EnhancedPhoto(id: "stage", originalURL: root.appendingPathComponent("orig-capture.jpg"), enhancedURL: root.appendingPathComponent(version.imageFile))
        let mls = try PhotoExportRenderer.prepare([photo], options: .init())
        defer { try? FileManager.default.removeItem(at: mls.directory) }
        check(mls.images.count == 2 && mls.files.count == 3, "MLS package includes current, original and disclosure")
        check(mls.images.map(\.lastPathComponent) == ["01-retained-original.jpg", "01-edited.jpg"], "Photos receives original before current edit")
        check(mls.images.last?.lastPathComponent == "01-edited.jpg", "current edit is the last photo added")
        let batch = try PhotoExportRenderer.prepare([photo, photo], options: .init())
        defer { try? FileManager.default.removeItem(at: batch.directory) }
        check(batch.images.map(\.lastPathComponent) == ["01-retained-original.jpg", "01-edited.jpg", "02-retained-original.jpg", "02-edited.jpg"],
              "batch Photos saves each original before its current edit")
        check(batch.files.map(\.lastPathComponent) == ["01-disclosure.txt", "01-edited.jpg", "01-retained-original.jpg", "02-disclosure.txt", "02-edited.jpg", "02-retained-original.jpg"],
              "batch Files retains alphabetical pairing independent of Photos order")
        check(mls.files.map(\.lastPathComponent) == ["01-disclosure.txt", "01-edited.jpg", "01-retained-original.jpg"], "matching names pair metadata and source")
        let mlsImage = UIImage(contentsOfFile: mls.directory.appendingPathComponent("01-edited.jpg").path)!
        check(brightness(mlsImage, x: 380, y: 285) > 240, "MLS file is clean with no banned text overlay")
        let retained = try Data(contentsOf: mls.directory.appendingPathComponent("01-retained-original.jpg"))
        check(retained == original, "exported retained original byte exact")
        let caption = try String(contentsOf: mls.directory.appendingPathComponent("01-disclosure.txt"), encoding: .utf8)
        check(caption.contains("Virtually staged") && caption.contains("Compare with the original"), "caption reflects persistent provenance")
        let web = try PhotoExportRenderer.prepare([photo], options: .init(destination: .web))
        defer { try? FileManager.default.removeItem(at: web.directory) }
        let webImage = UIImage(contentsOfFile: web.directory.appendingPathComponent("01-edited.jpg").path)!
        check(brightness(webImage, x: 380, y: 285) < 100, "web label burns into exported copy")
        let raw = try PhotoExportRenderer.prepare([photo], options: .init(original: true, aspect: .portrait, framing: .crop))
        defer { try? FileManager.default.removeItem(at: raw.directory) }
        check(raw.images.count == 1 && raw.files.count == 1, "original-only export no captions claiming alterations")
        check((try? Data(contentsOf: raw.images[0])) == original, "original ignores crop and keeps exact bytes")
        check((try? Data(contentsOf: photo.enhancedURL)) == original, "export did not write label onto stored version")
        check((try? Data(contentsOf: photo.originalURL)) == original, "export did not crop stored original")
        let noLabel = try PhotoExportRenderer.prepare([photo], options: .init(destination: .web, includeLabel: false, includeOriginals: false))
        defer { try? FileManager.default.removeItem(at: noLabel.directory) }
        check(noLabel.images.count == 1 && noLabel.files.count == 2, "web clean export still carries disclosure")
        let cleanWeb = UIImage(contentsOfFile: noLabel.images[0].path)!
        check(brightness(cleanWeb, x: 380, y: 285) > 240, "optional overlay can be disabled without deleting captions")
        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyURL = legacyDir.appendingPathComponent("enh-old.jpg")
        try original.write(to: legacyURL)
        let legacy = EnhancedPhoto(id: "old", originalURL: legacyURL, enhancedURL: legacyURL)
        let legacyPack = try PhotoExportRenderer.prepare([legacy], options: .init())
        defer { try? FileManager.default.removeItem(at: legacyPack.directory) }
        check(legacyPack.images.count == 1, "unknown legacy cannot fabricate original pair")
        check((try? String(contentsOf: legacyPack.files[0], encoding: .utf8).contains("unverified")) == true, "legacy caption admits missing provenance")
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        for degrees in [-5.0, 5.0] {
            let leveled = PhotoExportRenderer.render(blue, aspect: .original, framing: .fit, label: nil, levelDegrees: degrees)
            let w = leveled.cgImage!.width, h = leveled.cgImage!.height
            check(w < 400 && h < 300, "manual level crops without enlarging the photograph")
            check(abs(Double(w) / Double(h) - 4.0 / 3) < 0.01, "manual level retains source aspect")
            for (x,y) in [(2,2),(w-3,2),(2,h-3),(w-3,h-3)] {
                check(brightness(leveled,x:x,y:y) < 150, "leveled copy has photographed pixels at every corner")
            }
        }
        let pngURL = root.appendingPathComponent("input.png")
        let originalPNGURL = root.appendingPathComponent("untouched.png")
        let png = blue.pngData()!
        try png.write(to: pngURL); try png.write(to: originalPNGURL)
        let pngPhoto = EnhancedPhoto(id:"synthetic-png",originalURL:originalPNGURL,enhancedURL:pngURL)
        let pngExport = try PhotoExportRenderer.prepare([pngPhoto],options:.init(includeOriginals:false,levelDegrees:3))
        defer { try? FileManager.default.removeItem(at:pngExport.directory) }
        let actualJPEG = try Data(contentsOf:pngExport.images[0])
        check(actualJPEG.starts(with:[0xff,0xd8,0xff]), "PNG input is encoded as actual JPEG bytes")
        let jpegSource = CGImageSourceCreateWithData(actualJPEG as CFData,nil)!
        check(CGImageSourceGetType(jpegSource) as String? == "public.jpeg", "ImageIO identifies exported copy as JPEG")
        check(pngExport.images[0].pathExtension == "jpg", "encoded JPEG has .jpg extension")
        check((try? Data(contentsOf:pngURL)) == png, "JPEG export preserves saved PNG bytes")
        check((try? Data(contentsOf:originalPNGURL)) == png, "JPEG export preserves PNG original bytes")
        let sourceExport = try PhotoExportRenderer.prepare([pngPhoto],options:.init(original:true,aspect:.portrait,framing:.crop,levelDegrees:5))
        defer { try? FileManager.default.removeItem(at:sourceExport.directory) }
        check((try? Data(contentsOf:sourceExport.images[0])) == png, "original ignores level, ratio and JPEG conversion")
        check(sourceExport.images[0].pathExtension == "png", "retained original keeps its supplied original format")
        let exportCaption = try String(contentsOf:pngExport.files.first(where:{$0.pathExtension == "txt"})!,encoding:.utf8)
        check(exportCaption.contains("manually leveled and cropped"), "framing adjustment is recorded without claiming generative geometry")
        print("Actual UIKit rendering and export packaging: \(checks) passed")
    }
}
