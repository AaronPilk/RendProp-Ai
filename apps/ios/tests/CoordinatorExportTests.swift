// Actual UIKit encoded coordinator ZIP gate; procedural images only.
import Foundation
import UIKit
import ImageIO

enum CoordinatorExportChecks {
    @MainActor static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ text: String) {
            precondition(condition(), text); checks += 1
        }
        func zip(_ url: URL) throws -> [String: Data] {
            let bytes = try Data(contentsOf: url)
            func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p+1]) << 8 }
            func u32(_ p: Int) -> UInt32 { UInt32(bytes[p]) | UInt32(bytes[p+1]) << 8 | UInt32(bytes[p+2]) << 16 | UInt32(bytes[p+3]) << 24 }
            let end = bytes.count - 22
            check(u32(end) == 0x06054b50, "coordinator ZIP closes central directory")
            var p = Int(u32(end + 16)), contents: [String: Data] = [:], names = Set<String>()
            for _ in 0..<u16(end + 10) {
                check(u32(p) == 0x02014b50 && u16(p + 10) == 0, "coordinator ZIP uses stored bytes")
                let length = u16(p + 28), size = Int(u32(p + 24)), local = Int(u32(p + 42))
                let name = String(decoding: bytes[p+46..<p+46+length], as: UTF8.self)
                check(name == "README.txt" || PhotoExportRenderer.coordinatorPathIsSafe(name), "coordinator ZIP only permits its explicit nested folder allowlist")
                check(names.insert(name.lowercased()).inserted, "coordinator ZIP has no case-insensitive duplicates")
                check(u32(local) == 0x04034b50 && u32(local + 14) == u32(p + 16), "coordinator ZIP header CRC binds directory")
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                let data = Data(bytes[start..<start+size])
                check(ZipArchive.crc32(data) == u32(p + 16), "coordinator ZIP CRC binds every emitted byte")
                contents[name] = data
                p += 46 + length + u16(p + 30) + u16(p + 32)
            }
            return contents
        }
        func pixels(_ image: UIImage) -> (Int, Int) { (image.cgImage!.width, image.cgImage!.height) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-export-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { ctx in
            UIColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 300))
        }
        let png = image.pngData()!, jpeg = image.jpegData(compressionQuality: 0.91)!
        try PhotoVersionHistory.saveCapture(original: png, enhanced: jpeg, id: "base", directory: root)
        let declutter = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: "declutter", parentID: "base", sourceID: "base", edit: "declutter", style: nil,
            disclosure: "Movable items removed; fixed features retained.", provenanceID: nil, provenanceRecorded: false, directory: root)
        let staged = try PhotoVersionHistory.saveEdit(jpeg: png, id: "stage", parentID: declutter.id, sourceID: declutter.id, edit: "stage", style: "modern",
            disclosure: "Furniture digitally added.", provenanceID: nil, provenanceRecorded: false, directory: root)
        let unreviewed = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: "custom", parentID: staged.id, sourceID: staged.id, edit: "custom", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: root)
        let descendant = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: "custom-sky", parentID: unreviewed.id, sourceID: unreviewed.id, edit: "sky", style: nil,
            disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: root)
        try PhotoVersionHistory.saveCapture(original: jpeg, enhanced: jpeg, id: "other", directory: root)
        let photos = [EnhancedPhoto(id: descendant.id, originalURL: root.appendingPathComponent("orig-base.jpg"), enhancedURL: root.appendingPathComponent(descendant.imageFile)),
                      EnhancedPhoto(id: "other", originalURL: root.appendingPathComponent("orig-other.jpg"), enhancedURL: root.appendingPathComponent("enh-other.jpg"))]
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".photo-history.json"))
        let prepared = try PhotoExportRenderer.prepareCoordinator(photos)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let video = root.appendingPathComponent("walkthrough.mp4"), videoBytes = Data([0,0,0,16,0x66,0x74,0x79,0x70,1,2,3,4])
        try videoBytes.write(to: video)
        let details = root.appendingPathComponent("listing-details.txt"), detailsBytes = Data("Address and price with original fields.\n".utf8)
        try detailsBytes.write(to: details)
        let extras = [PhotoExportRenderer.Extra(name: "walkthrough.mp4", url: video, note: "Original walkthrough tour."),
                      .init(name: "WALKTHROUGH.mp4", url: video, note: "Second saved video with same readable name."),
                      .init(name: "listing-details.txt", url: details, note: "Actual listing fields and links.")]
        let archive = try PhotoExportRenderer.packageCoordinator(prepared, archiveName: "855 Central Ave", extras: extras)
        let contents = try zip(archive), names = Set(contents.keys)
        check(contents["Originals/01-retained-original.png"] == png, "coordinator original master preserves exact bytes and real format")
        check(contents["Decluttered/01-version-02-decluttered.jpg"] == jpeg, "coordinator declutter master retains the full saved bytes")
        check(contents["Staged/01-version-03-virtually-staged-modern.png"] == png, "coordinator staging master retains the full saved bytes and format")
        check(contents["Enhanced/01-version-01-enhanced.jpg"] == jpeg && contents["Enhanced/02-version-01-enhanced.jpg"] == jpeg, "coordinator includes predecessors and other photo families")
        check(!names.contains(where: { $0.contains("version-04-") || $0.contains("version-05-") }), "coordinator never exports unreviewed custom versions or descendants")
        check(contents["Videos/walkthrough.mp4"] == videoBytes && contents["Videos/WALKTHROUGH-2.mp4"] == videoBytes, "coordinator preserves every video with deterministic collision names")
        check(contents["Attachments/listing-details.txt"] == detailsBytes, "coordinator retains the actual listing details")
        let readme = String(decoding: contents["README.txt"]!, as: UTF8.self)
        check(readme.contains("custom-sky [edit-custom-sky.jpg]") && readme.contains("stage [edit-stage.jpg]") && readme.contains("selected-version fallback"), "coordinator names the exact withheld current and earlier fallback in README")
        check(readme.contains("Decluttered and Staged") && readme.contains("Masters are exact saved bytes") && readme.contains("center-cropped") && readme.contains("without borders or upscaling"), "coordinator README separates unchanged masters from cropped upload copies")
        check(readme.contains("Videos/walkthrough.mp4 — Original walkthrough") && readme.contains("AI-generated motion must be disclosed"), "coordinator README explains video and motion provenance")
        for (folder, aspect, width, height) in [("MLS", PhotoExportLayout.Aspect.landscape, 400, 300), ("Zillow", .landscape, 400, 300),
                                               ("Instagram/Feed4x5", .feed, 240, 300), ("Instagram/Stories9x16", .portrait, 169, 300)] {
            for (category, stem, source) in [("Enhanced", "01-version-01-enhanced", jpeg), ("Decluttered", "01-version-02-decluttered", jpeg),
                                            ("Staged", "01-version-03-virtually-staged-modern", png), ("Enhanced", "02-version-01-enhanced", jpeg)] {
                let path = folder + "/" + category + "/" + stem
                check(contents[path + ".jpg"] != nil, "coordinator emits every platform and saved-version JPEG")
                let data = contents[path + ".jpg"]!, actual = UIImage(data: data)!
                check(data.starts(with: [0xff,0xd8,0xff]) && CGImageSourceGetType(CGImageSourceCreateWithData(data as CFData, nil)!) as String? == "public.jpeg", "coordinator upload copies encode real JPEG bytes")
                let (w,h) = pixels(actual)
                check(w == width && h == height && w <= 400 && h <= 300, "coordinator upload dimensions use the intended ratio without fake upscaling")
                let expected = PhotoExportRenderer.render(UIImage(data: source)!, aspect: aspect, framing: .crop, label: nil).jpegData(compressionQuality: 0.97)!
                check(data == expected, "coordinator upload JPEG is the actual clean centered crop at quality 0.97")
                check(contents[path + "-disclosure.txt"] != nil, "coordinator platform JPEG carries its matching disclosure")
                let caption = contents[path + "-disclosure.txt"]!
                let text = String(decoding: caption, as: UTF8.self)
                check(text.contains("Available source: 400×300 pixels. Export: \(width)×\(height) pixels") && text.contains("Centered crop may remove content") && text.contains("short edge is below 1080"), "coordinator caption reports true pixels and low available resolution")
                if category == "Staged" { check(text.contains("Virtually staged"), "coordinator staged upload retains its staging disclosure") }
                if category == "Decluttered" { check(text.contains("Digitally decluttered"), "coordinator declutter upload retains its declutter disclosure") }
            }
        }
        check((try? Data(contentsOf: root.appendingPathComponent("orig-base.jpg"))) == png && (try? Data(contentsOf: root.appendingPathComponent(staged.imageFile))) == png, "coordinator does not alter retained originals or staged files")
        check((try? Data(contentsOf: root.appendingPathComponent(".photo-history.json"))) == indexBefore, "coordinator grants no review or publication permission")
        check((try? Data(contentsOf: video)) == videoBytes && (try? Data(contentsOf: details)) == detailsBytes, "coordinator leaves videos and details in place unchanged")
        for unsafe in ["../source.jpg", "MLS/../source.jpg", "/MLS/Enhanced/source.jpg", "MLS/Enhanced/C:source.jpg", "Instagram/Feed4x5/../source.jpg", "Unknown/photo.jpg", "MLS//file.jpg", "Staged/a\\b.jpg"] {
            check(!PhotoExportRenderer.coordinatorPathIsSafe(unsafe), "coordinator explicit path allowlist rejects traversal and unknown folders")
        }
        let videoOnly = try PhotoExportRenderer.prepareCoordinator([])
        defer { try? FileManager.default.removeItem(at: videoOnly.directory) }
        let videoZIP = try PhotoExportRenderer.packageCoordinator(videoOnly, archiveName: "No photos", extras: extras)
        let videoContents = try zip(videoZIP)
        check(Set(videoContents.keys) == ["README.txt", "Videos/walkthrough.mp4", "Videos/WALKTHROUGH-2.mp4", "Attachments/listing-details.txt"], "coordinator video-only listing still hands over all files")
        // A missing approved predecessor must not be silently discarded.
        try FileManager.default.removeItem(at: root.appendingPathComponent(declutter.imageFile))
        do {
            let partial = try PhotoExportRenderer.prepareCoordinator(photos)
            try? FileManager.default.removeItem(at: partial.directory)
            check(false, "coordinator missing approved predecessor must refuse partial delivery")
        } catch { checks += 1 }
        print("Coordinator encoded ZIP: \(checks) passed")
        return checks
    }
}
