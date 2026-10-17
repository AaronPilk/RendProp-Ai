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
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "custom-capture", directory: root)
        let custom = try PhotoVersionHistory.saveEdit(jpeg: original, id: "custom", parentID: "custom-capture", sourceID: "custom-capture", edit: "custom", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: root)
        let customPhoto = EnhancedPhoto(id: custom.id, originalURL: root.appendingPathComponent("orig-custom-capture.jpg"),
            enhancedURL: root.appendingPathComponent(custom.imageFile))
        func rejectsCustom(_ input: [EnhancedPhoto], _ message: String, options: PhotoExportRenderer.Options = .init()) throws {
            do {
                let output = try PhotoExportRenderer.prepare(input, options: options)
                try? FileManager.default.removeItem(at: output.directory)
                check(false, message)
            } catch PhotoVersionHistory.Failure.customReviewRequired { checks += 1 }
        }
        try rejectsCustom([customPhoto], "unreviewed custom cannot be exported by the actual renderer")
        let tempBefore = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Rendprop-photos-") })
        try rejectsCustom([photo, customPhoto], "bulk export cannot include an unreviewed custom after an approved photo")
        let tempAfter = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Rendprop-photos-") })
        check(tempBefore == tempAfter, "a rejected bulk export removes all partial prepared output")
        let alias = EnhancedPhoto(id: "unknown-alias", originalURL: customPhoto.originalURL, enhancedURL: customPhoto.enhancedURL)
        try rejectsCustom([alias], "filename lookup still fences custom output when the view has an older alias")
        let forgedID = EnhancedPhoto(id: "capture", originalURL: customPhoto.originalURL, enhancedURL: customPhoto.enhancedURL)
        do {
            let output = try PhotoExportRenderer.prepare([forgedID], options: .init())
            try? FileManager.default.removeItem(at: output.directory)
            preconditionFailure("an approved capture id cannot hide a different unreviewed custom file")
        } catch PhotoVersionHistory.Failure.changedVersion { checks += 1 }
        let rawCustom = try PhotoExportRenderer.prepare([customPhoto], options: .init(original: true))
        defer { try? FileManager.default.removeItem(at: rawCustom.directory) }
        check((try? Data(contentsOf: rawCustom.images[0])) == original, "unreviewed custom still allows exact original download")
        check((try? PhotoVersionHistory.load(directory: root).versions[custom.id]?.customReviewed) == false,
              "original download does not approve the edited custom image")
        let descendant = try PhotoVersionHistory.saveEdit(jpeg: original, id: "custom-sky", parentID: custom.id, sourceID: custom.id, edit: "sky", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: root)
        let descendantPhoto = EnhancedPhoto(id: descendant.id, originalURL: customPhoto.originalURL, enhancedURL: root.appendingPathComponent(descendant.imageFile))
        try rejectsCustom([descendantPhoto], "a preset descendant cannot bypass custom download review")
        let earlierUnreviewedCustom = EnhancedPhoto(id: photo.id, originalURL: customPhoto.enhancedURL, enhancedURL: photo.enhancedURL)
        try rejectsCustom([earlierUnreviewedCustom], "earlier-source export cannot expose an unreviewed custom ancestor", options: .init(original: true))
        try rejectsCustom([earlierUnreviewedCustom], "paired-original export cannot expose an unreviewed custom ancestor")
        let beforeReview = try PhotoVersionHistory.load(directory: root)
        try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile, sourceFile: "orig-custom-capture.jpg",
            review: .init(comparedSource: true, fixedFeaturesMatch: true, colorsAndMaterialsMatch: true, onlyRequestedChange: true), directory: root)
        let reviewed = try PhotoVersionHistory.load(directory: root)
        check(reviewed.current == beforeReview.current && reviewed.listingSelections == beforeReview.listingSelections,
              "reviewing a download leaves publication and editing selections unchanged")
        let customPack = try PhotoExportRenderer.prepare([customPhoto], options: .init())
        defer { try? FileManager.default.removeItem(at: customPack.directory) }
        // Build 61: every saved version of the photo rides along, named by what
        // it is; a descendant that was never reviewed is withheld and noted.
        check(!customPack.files.contains { $0.lastPathComponent.contains("-version-3-") }, "an unreviewed custom descendant is withheld from the package")
        check(customPack.images.count == 4 && customPack.files.count == 7, "reviewed custom exports with its original, every stored version and each disclosure")
        check(customPack.images.map(\.lastPathComponent) == ["01-retained-original.jpg", "01-version-1-enhanced.jpg", "01-version-2-ai-edit.jpg", "01-edited.jpg"], "other versions sit between the original and the current edit")
        let customNote = try String(contentsOf: customPack.directory.appendingPathComponent("01-disclosure.txt"), encoding: .utf8)
        check(customNote.contains("1 saved version of this photo was not included"), "the photo's note says a version was withheld")
        let enhancedCopy = try Data(contentsOf: customPack.directory.appendingPathComponent("01-version-1-enhanced.jpg"))
        check(enhancedCopy == original, "an exported version is the exact stored bytes")
        check((try? Data(contentsOf: customPack.directory.appendingPathComponent("01-version-2-ai-edit.jpg"))) == original, "current stored JPEG version is byte exact beside its rendered delivery copy")
        let enhancedNote = try String(contentsOf: customPack.directory.appendingPathComponent("01-version-1-enhanced-disclosure.txt"), encoding: .utf8)
        check(enhancedNote.hasPrefix("Original enhancement.") && enhancedNote.contains("enhanced on this phone"), "each exported version carries its own disclosure note")
        try rejectsCustom([descendantPhoto], "review of one custom output cannot approve a different descendant download")
        let mls = try PhotoExportRenderer.prepare([photo], options: .init())
        defer { try? FileManager.default.removeItem(at: mls.directory) }
        check(mls.images.count == 4 && mls.files.count == 7, "MLS package includes current delivery, original, every saved version and their disclosures")
        check(mls.images.map(\.lastPathComponent) == ["01-retained-original.jpg", "01-version-1-enhanced.jpg", "01-version-2-virtually-staged-modern.jpg", "01-edited.jpg"], "Photos receives original before current edit")
        check(mls.images.last?.lastPathComponent == "01-edited.jpg", "current edit is the last photo added")
        let batch = try PhotoExportRenderer.prepare([photo, photo], options: .init())
        defer { try? FileManager.default.removeItem(at: batch.directory) }
        check(batch.images.map(\.lastPathComponent) == ["01-retained-original.jpg", "01-version-1-enhanced.jpg", "01-version-2-virtually-staged-modern.jpg", "01-edited.jpg", "02-retained-original.jpg", "02-version-1-enhanced.jpg", "02-version-2-virtually-staged-modern.jpg", "02-edited.jpg"],
              "batch Photos saves each original before its current edit")
        check(batch.files.map(\.lastPathComponent) == ["01-disclosure.txt", "01-edited.jpg", "01-retained-original.jpg", "01-version-1-enhanced-disclosure.txt", "01-version-1-enhanced.jpg", "01-version-2-virtually-staged-modern-disclosure.txt", "01-version-2-virtually-staged-modern.jpg", "02-disclosure.txt", "02-edited.jpg", "02-retained-original.jpg", "02-version-1-enhanced-disclosure.txt", "02-version-1-enhanced.jpg", "02-version-2-virtually-staged-modern-disclosure.txt", "02-version-2-virtually-staged-modern.jpg"],
              "batch Files retains alphabetical pairing independent of Photos order")
        check(mls.files.map(\.lastPathComponent) == ["01-disclosure.txt", "01-edited.jpg", "01-retained-original.jpg", "01-version-1-enhanced-disclosure.txt", "01-version-1-enhanced.jpg", "01-version-2-virtually-staged-modern-disclosure.txt", "01-version-2-virtually-staged-modern.jpg"], "matching names pair metadata and source")
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
        check(legacyPack.images.count == 2 && !legacyPack.images.contains { $0.lastPathComponent.contains("retained-original") }, "unknown legacy cannot fabricate original pair")
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
        // One ZIP for the whole export (build 58): every prepared file plus a
        // README, stored uncompressed, readable by any unarchiver. The archive
        // is parsed back here from its central directory, not trusted blindly.
        let bundle = try PhotoExportRenderer.prepare([photo, pngPhoto], options: .init(includeOriginals: true))
        defer { try? FileManager.default.removeItem(at: bundle.directory) }
        let archive = try PhotoExportRenderer.package(bundle, archiveName: "2050 Laney Pond Dr., Unit #4 / Apt \"B\"", now: Date(timeIntervalSince1970: 1_791_700_000))
        check(archive.lastPathComponent == "2050 Laney Pond Dr., Unit #4 Apt B photos.zip", "archive is named after the listing with unsafe characters dropped")
        check(archive.deletingLastPathComponent().standardizedFileURL.path == bundle.directory.standardizedFileURL.path, "archive sits beside the prepared files for the same cleanup")
        let zipBytes = try Data(contentsOf: archive)
        func le32(_ at: Int) -> UInt32 { zipBytes[at..<at+4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        func le16(_ at: Int) -> Int { Int(zipBytes[at]) | Int(zipBytes[at+1]) << 8 }
        let eocd = zipBytes.count - 22
        check(le32(eocd) == 0x06054b50 && le16(eocd + 20) == 0, "end of central directory record closes the archive")
        let entryCount = le16(eocd + 10), directoryOffset = Int(le32(eocd + 16))
        check(entryCount == bundle.files.count + 1, "ZIP carries every prepared file including disclosure notes")
        var cursor = directoryOffset, names: [String] = [], storedBytes = 0
        for _ in 0..<entryCount {
            check(le32(cursor) == 0x02014b50 && le16(cursor + 10) == 0, "central directory entry uses the store method")
            let nameLength = le16(cursor + 28), size = Int(le32(cursor + 24)), localOffset = Int(le32(cursor + 42))
            let name = String(decoding: zipBytes[cursor + 46..<cursor + 46 + nameLength], as: UTF8.self)
            names.append(name); storedBytes += size
            check(le32(localOffset) == 0x04034b50, "local header offset points at a local file header")
            let localNameLength = le16(localOffset + 26), dataStart = localOffset + 30 + localNameLength
            if let original = bundle.files.first(where: { $0.lastPathComponent == name }) {
                check((try? Data(contentsOf: original)) == zipBytes[dataStart..<dataStart + size], "stored bytes equal the prepared file \(name)")
            }
            cursor += 46 + nameLength + le16(cursor + 30) + le16(cursor + 32)
        }
        check(names.first == "README.txt" && Set(names).count == names.count, "README first, no duplicate names")
        check(bundle.files.allSatisfy { names.contains($0.lastPathComponent) }, "every disclosure note, original and JPEG is in the archive")
        let readme = String(decoding: zipBytes[(30 + "README.txt".utf8.count)..<(30 + "README.txt".utf8.count + Int(le32(18)))], as: UTF8.self)
        check(readme.contains("disclosure") && readme.contains("2 photos"), "README explains the numbering and the disclosure notes")
        check(readme.contains("2 saved versions (same number, '-version-<n>-<what it is>'") && readme.contains("Unreviewed custom edits are withheld"), "README explains the version labels without promising withheld images")
        check(directoryOffset == storedBytes + names.reduce(0) { $0 + 30 + $1.utf8.count }, "local headers and stored bytes fill the archive up to the central directory")
        check(bundle.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "packaging leaves the prepared files in place")
        // Build 60: parse the actual listing package back through its headers,
        // central directory and CRC fields; the video bytes are synthetic.
        func storedEntries(_ url: URL) throws -> [String: Data] {
            let data = try Data(contentsOf: url)
            func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p+1]) << 8 }
            func u32(_ p: Int) -> UInt32 { data[p..<p+4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
            let end = data.count - 22
            check(u32(end) == 0x06054b50, "listing package closes its central directory")
            var p = Int(u32(end + 16)), result: [String: Data] = [:]
            for _ in 0..<u16(end + 10) {
                check(u32(p) == 0x02014b50 && u16(p + 10) == 0, "listing extra uses stored ZIP entry")
                let nameLength = u16(p + 28), size = Int(u32(p + 24)), local = Int(u32(p + 42))
                let name = String(decoding: data[p+46..<p+46+nameLength], as: UTF8.self)
                check(result[name] == nil, "listing package never duplicates an archive name")
                check(u32(local) == 0x04034b50 && u32(local + 14) == u32(p + 16), "listing extra header and directory agree on CRC")
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                let body = Data(data[start..<start+size])
                check(ZipArchive.crc32(body) == u32(p + 16), "listing extra CRC matches its preserved bytes")
                result[name] = body
                p += 46 + nameLength + u16(p + 30) + u16(p + 32)
            }
            return result
        }
        // A stored extension is not a format guarantee: capture storage keeps
        // an imported PNG/HEIC's original bytes under the old .jpg convention.
        let formatsDir = root.appendingPathComponent("real-formats")
        try PhotoVersionHistory.saveCapture(original: png, enhanced: png, id: "png-capture", directory: formatsDir)
        let pngEdit = try PhotoVersionHistory.saveEdit(jpeg: png, id: "png-sky", parentID: "png-capture", sourceID: "png-capture", edit: "sky", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: formatsDir)
        let pngStaged = try PhotoVersionHistory.saveEdit(jpeg: original, id: "png-stage", parentID: pngEdit.id, sourceID: pngEdit.id, edit: "stage", style: "modern",
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: formatsDir)
        let pngHistoryPhoto = EnhancedPhoto(id: pngStaged.id, originalURL: formatsDir.appendingPathComponent("orig-png-capture.jpg"), enhancedURL: formatsDir.appendingPathComponent(pngStaged.imageFile))
        let pngHistory = try PhotoExportRenderer.prepare([pngHistoryPhoto], options: .init())
        defer { try? FileManager.default.removeItem(at: pngHistory.directory) }
        check(pngHistory.images.map(\.lastPathComponent) == ["01-retained-original.png", "01-version-1-enhanced.png", "01-version-2-blue-sky.png", "01-version-3-virtually-staged-modern.jpg", "01-edited.jpg"], "retained PNG filenames describe their real bytes despite stored jpg names")
        for file in pngHistory.images.filter({ $0.pathExtension == "png" }) {
            check((try? Data(contentsOf: file)) == png, "every retained PNG version keeps exact stored bytes")
            let image = CGImageSourceCreateWithURL(file as CFURL, nil)!
            check(CGImageSourceGetType(image) as String? == "public.png", "each .png retained file is an actual PNG")
        }
        let pngOriginal = try PhotoExportRenderer.prepare([pngHistoryPhoto], options: .init(original: true))
        defer { try? FileManager.default.removeItem(at: pngOriginal.directory) }
        check(pngOriginal.images[0].lastPathComponent == "01-retained-original.png" && (try? Data(contentsOf: pngOriginal.images[0])) == png, "original-only PNG export corrects the legacy suffix without transcoding")
        let pngCurrentPhoto = EnhancedPhoto(id: pngEdit.id, originalURL: pngHistoryPhoto.originalURL, enhancedURL: formatsDir.appendingPathComponent(pngEdit.imageFile))
        let pngCurrent = try PhotoExportRenderer.prepare([pngCurrentPhoto], options: .init(destination: .web, aspect: .portrait, framing: .crop, levelDegrees: 3))
        defer { try? FileManager.default.removeItem(at: pngCurrent.directory) }
        check((try? Data(contentsOf: pngCurrent.directory.appendingPathComponent("01-version-2-blue-sky.png"))) == png, "current stored PNG version is exact even when delivery JPEG is labeled cropped and leveled")
        let pngCurrentJPEG = try Data(contentsOf: pngCurrent.directory.appendingPathComponent("01-edited.jpg"))
        check(pngCurrentJPEG.starts(with: [0xff,0xd8,0xff]) && pngCurrentJPEG != png, "current PNG receives a separate actual JPEG delivery copy")
        let heicBytes = NSMutableData()
        guard let heicWriter = CGImageDestinationCreateWithData(heicBytes, "public.heic" as CFString, 1, nil) else {
            preconditionFailure("The simulator must supply the real HEIC ImageIO encoder for this gate")
        }
        CGImageDestinationAddImage(heicWriter, source.cgImage!, nil)
        check(CGImageDestinationFinalize(heicWriter), "a real HEIC fixture is encoded by ImageIO")
        let heic = heicBytes as Data
        let heicSource = CGImageSourceCreateWithData(heic as CFData, nil)!
        check(CGImageSourceGetType(heicSource) as String? == "public.heic", "HEIC fixture has a real HEIC container")
        try PhotoVersionHistory.saveCapture(original: heic, enhanced: heic, id: "heic-capture", directory: formatsDir)
        let heicStage = try PhotoVersionHistory.saveEdit(jpeg: original, id: "heic-stage", parentID: "heic-capture", sourceID: "heic-capture", edit: "stage", style: "modern",
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: formatsDir)
        let heicPhoto = EnhancedPhoto(id: heicStage.id, originalURL: formatsDir.appendingPathComponent("orig-heic-capture.jpg"), enhancedURL: formatsDir.appendingPathComponent(heicStage.imageFile))
        let heicHistory = try PhotoExportRenderer.prepare([heicPhoto], options: .init())
        defer { try? FileManager.default.removeItem(at: heicHistory.directory) }
        check(heicHistory.images.map(\.lastPathComponent) == ["01-retained-original.heic", "01-version-1-enhanced.heic", "01-version-2-virtually-staged-modern.jpg", "01-edited.jpg"], "retained HEIC filenames describe their real bytes despite stored jpg names")
        check(heicHistory.images.filter({ $0.pathExtension == "heic" }).allSatisfy { (try? Data(contentsOf: $0)) == heic }, "HEIC original and enhancement stay byte exact")
        let heicCurrentPhoto = EnhancedPhoto(id: "heic-capture", originalURL: heicPhoto.originalURL, enhancedURL: formatsDir.appendingPathComponent("enh-heic-capture.jpg"))
        let heicCurrent = try PhotoExportRenderer.prepare([heicCurrentPhoto], options: .init(aspect: .portrait, framing: .crop, levelDegrees: 3))
        defer { try? FileManager.default.removeItem(at: heicCurrent.directory) }
        check((try? Data(contentsOf: heicCurrent.directory.appendingPathComponent("01-version-1-enhanced.heic"))) == heic, "current stored HEIC version is exact beside a cropped and leveled JPEG delivery copy")
        check((try? Data(contentsOf: heicCurrent.directory.appendingPathComponent("01-edited.jpg")))?.starts(with: [0xff,0xd8,0xff]) == true, "current HEIC renders an actual JPEG without replacing its stored bytes")
        // More than nine versions must still sort chronologically in Files.
        let manyDir = root.appendingPathComponent("many-versions")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "many-capture", directory: manyDir)
        var parent = "many-capture"
        for position in 1...12 {
            let made = try PhotoVersionHistory.saveEdit(jpeg: original, id: "many-\(position)", parentID: parent, sourceID: parent,
                edit: position == 12 ? "stage" : "declutter", style: position == 12 ? "modern" : nil,
                disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: manyDir)
            parent = made.id
        }
        let manyPhoto = EnhancedPhoto(id: parent, originalURL: manyDir.appendingPathComponent("orig-many-capture.jpg"), enhancedURL: manyDir.appendingPathComponent("edit-\(parent).jpg"))
        let many = try PhotoExportRenderer.prepare([manyPhoto], options: .init())
        defer { try? FileManager.default.removeItem(at: many.directory) }
        let chronologicalNames = many.images.filter { $0.lastPathComponent.contains("-version-") }.map(\.lastPathComponent)
        check(chronologicalNames.count == 13 && chronologicalNames == chronologicalNames.sorted() && chronologicalNames.first == "01-version-01-enhanced.jpg" && chronologicalNames.last == "01-version-13-virtually-staged-modern.jpg", "ten or more retained versions sort in the actual chronological order")
        check(Set(many.files.map(\.lastPathComponent)).count == many.files.count, "repeated edit slugs cannot duplicate archive filenames")
        let manyNote = try String(contentsOf: many.directory.appendingPathComponent("01-disclosure.txt"), encoding: .utf8)
        check(manyNote.contains("Virtually staged") && manyNote.contains("Digitally decluttered"), "a staged declutter lineage discloses both effects")
        let earlierDeclutterNote = try String(contentsOf: many.directory.appendingPathComponent("01-version-02-decluttered-disclosure.txt"), encoding: .utf8)
        check(earlierDeclutterNote.contains("Digitally decluttered") && !earlierDeclutterNote.contains("Virtually staged"), "each predecessor discloses its own effects rather than the latest staging")
        // Refuse an incomplete export rather than silently promising every file.
        let missingDir = root.appendingPathComponent("missing-versions")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "missing-capture", directory: missingDir)
        let missingStage = try PhotoVersionHistory.saveEdit(jpeg: original, id: "missing-stage", parentID: "missing-capture", sourceID: "missing-capture", edit: "stage", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: missingDir)
        let missingPhoto = EnhancedPhoto(id: missingStage.id, originalURL: missingDir.appendingPathComponent("orig-missing-capture.jpg"), enhancedURL: missingDir.appendingPathComponent(missingStage.imageFile))
        try FileManager.default.removeItem(at: missingDir.appendingPathComponent("enh-missing-capture.jpg"))
        do {
            let output = try PhotoExportRenderer.prepare([missingPhoto], options: .init())
            try? FileManager.default.removeItem(at: output.directory)
            check(false, "a missing retained version cannot be silently omitted")
        } catch let error as PhotoExportRenderer.Failure {
            check(error.message.contains("enh-missing-capture.jpg") && error.message.contains("Nothing was exported"), "missing-version refusal names the unavailable retained file")
        }
        try original.write(to: missingDir.appendingPathComponent("enh-missing-capture.jpg"))
        try FileManager.default.removeItem(at: missingPhoto.originalURL)
        do {
            let output = try PhotoExportRenderer.prepare([missingPhoto], options: .init())
            try? FileManager.default.removeItem(at: output.directory)
            check(false, "a missing verified original cannot be silently omitted")
        } catch let error as PhotoExportRenderer.Failure {
            check(error.message.contains("orig-missing-capture.jpg") && error.message.contains("Nothing was exported"), "missing-original refusal names the unavailable retained file")
        }
        let justCurrent = try PhotoExportRenderer.prepare([missingPhoto], options: .init(includeOriginals: false))
        defer { try? FileManager.default.removeItem(at: justCurrent.directory) }
        check(justCurrent.images.count == 1 && justCurrent.files.count == 2, "current-only export remains available when an original was lost")
        let customArchive = try PhotoExportRenderer.package(customPack, archiveName: "Reviewed custom")
        let customEntries = try storedEntries(customArchive)
        check(!customEntries.keys.contains { $0.contains("-version-3-") }, "the ZIP never contains an unreviewed custom ancestor or descendant")
        let customReadme = String(decoding: customEntries["README.txt"]!, as: UTF8.self)
        check(customReadme.contains("Unreviewed custom edits are withheld") && !customReadme.contains("Every image Rendprop holds"), "README explicitly admits unreviewed versions are withheld")
        // A file may disappear or history may change after initial admission.
        // The default reader still reads real immutable source files; the seam
        // injects that exact filesystem timing deterministically, not a fake export.
        let raceDir = root.appendingPathComponent("raced-history")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "race-capture", directory: raceDir)
        let racePhoto = EnhancedPhoto(id: "race-capture", originalURL: raceDir.appendingPathComponent("orig-race-capture.jpg"), enhancedURL: raceDir.appendingPathComponent("enh-race-capture.jpg"))
        var changed = false
        do {
            let output = try PhotoExportRenderer.prepare([racePhoto], options: .init(), readRetained: { url in
                let data = try Data(contentsOf: url)
                if !changed {
                    changed = true
                    _ = try PhotoVersionHistory.saveEdit(jpeg: original, id: "race-edit", parentID: "race-capture", sourceID: "race-capture", edit: "sky", style: nil,
                        disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: raceDir)
                }
                return data
            })
            try? FileManager.default.removeItem(at: output.directory)
            check(false, "a history change during export prevents mixed version delivery")
        } catch PhotoVersionHistory.Failure.changedVersion { checks += 1 }
        check(changed && (try? Data(contentsOf: racePhoto.originalURL)) == original, "history-race refusal preserves the original source bytes")
        let duplicateDir = root.appendingPathComponent("duplicate-history")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: original, id: "duplicate-capture", directory: duplicateDir)
        _ = try PhotoVersionHistory.saveEdit(jpeg: original, id: "duplicate-edit", parentID: "duplicate-capture", sourceID: "duplicate-capture", edit: "sky", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: duplicateDir)
        let indexURL = duplicateDir.appendingPathComponent(".photo-history.json")
        var duplicateIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
        var duplicateVersions = duplicateIndex["versions"] as! [String: [String: Any]]
        duplicateVersions["duplicate-edit"]!["imageFile"] = "enh-duplicate-capture.jpg"
        duplicateIndex["versions"] = duplicateVersions
        try JSONSerialization.data(withJSONObject: duplicateIndex).write(to: indexURL, options: .atomic)
        do {
            _ = try PhotoVersionHistory.load(directory: duplicateDir)
            check(false, "one stored image cannot masquerade as two different saved versions")
        } catch PhotoVersionHistory.Failure.invalidHistory { checks += 1 }
        let video = root.appendingPathComponent("source-walkthrough.mp4")
        let videoBytes = Data([0,0,0,24,102,116,121,112]) + Data("synthetic walkthrough bytes".utf8)
        let details = root.appendingPathComponent("details-note.txt")
        let detailsBytes = Data("2050 Laney Pond Dr.\nListing page: https://example.invalid/s/one\nMLS-safe page (no branding): https://example.invalid/u/one".utf8)
        try videoBytes.write(to: video); try detailsBytes.write(to: details)
        let extras = [PhotoExportRenderer.Extra(name:"walkthrough-tour.mp4",url:video,note:"walkthrough tour"),
                      PhotoExportRenderer.Extra(name:"listing-details.txt",url:details,note:"address and share links"),
                      PhotoExportRenderer.Extra(name:"README.txt",url:details,note:"a colliding source name")]
        let listingArchive = try PhotoExportRenderer.package(bundle, archiveName:"Complete listing", extras:extras)
        let listingEntries = try storedEntries(listingArchive)
        check(listingArchive.lastPathComponent == "Complete listing listing.zip", "complete package is named as a listing ZIP")
        check(listingEntries["walkthrough-tour.mp4"] == videoBytes, "listing ZIP includes exact walkthrough bytes")
        check(listingEntries["listing-details.txt"] == detailsBytes, "listing ZIP includes exact details note")
        check(listingEntries["README-2.txt"] == detailsBytes, "extra colliding with README receives a unique safe name")
        check(bundle.files.allSatisfy { listingEntries[$0.lastPathComponent] == (try? Data(contentsOf:$0)) }, "whole package preserves every photo original and disclosure")
        let listingReadme = String(decoding: listingEntries["README.txt"]!, as:UTF8.self)
        check(listingReadme.contains("walkthrough-tour.mp4") && listingReadme.contains("listing-details.txt") && listingReadme.contains("AI-generated"), "listing README describes extras and generated-media disclosure")
        check((try? Data(contentsOf:video)) == videoBytes && (try? Data(contentsOf:details)) == detailsBytes, "listing package leaves extra files byte exact in place")
        let videosOnly = try PhotoExportRenderer.prepareEmpty()
        defer { try? FileManager.default.removeItem(at:videosOnly.directory) }
        let videoArchive: URL
        do { videoArchive = try PhotoExportRenderer.package(videosOnly,archiveName:"Video only",extras:Array(extras.prefix(2))) }
        catch { check(false, "video-only listing must package without photos"); fatalError("unreachable") }
        let videoEntries = try storedEntries(videoArchive)
        check(Set(videoEntries.keys) == ["README.txt","walkthrough-tour.mp4","listing-details.txt"], "video-only listing ZIP contains all files without photos")
        check(videoEntries["walkthrough-tour.mp4"] == videoBytes, "video-only package retains exact source video bytes")
        let missing = PhotoExportRenderer.Extra(name:"gone.mp4",url:root.appendingPathComponent("missing.mp4"),note:"missing source")
        do {
            _ = try PhotoExportRenderer.package(videosOnly,archiveName:"Missing source",extras:[missing])
            preconditionFailure("a missing extra cannot be silently dropped from the listing package")
        } catch { checks += 1 }
        check((try? Data(contentsOf:video)) == videoBytes, "failed packaging cannot remove the listing video")
        checks += try CoordinatorExportChecks.run()
        print("Actual UIKit rendering and export packaging: \(checks) passed")
    }
}
