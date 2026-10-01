import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// This value-only stub excludes UIKit from the offline executable. The actual
// production store, archive validation, JPEG decoder and renderer run unchanged.
struct PanoramaPreviewStation {
    let id: String
    let label: String
    let panoramaURL: URL
    let position: [Double]
    let coverage: Double
}

@main enum GuidedPanoramaPreviewStoreTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, "accepted \(message)") } catch { checks += 1 }
    }
    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    static func snapshot(_ root: URL) throws -> [String: String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: String] = [:]
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[file.path.replacingOccurrences(of: root.path + "/", with: "")] = try digest(file)
        }
        return result
    }
    static func inode(_ url: URL) throws -> NSNumber {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber
    }
    static func receipt(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    static func writeJPEG(_ url: URL, rgb: [UInt8]) throws {
        let width = 64, height = 48
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) { for channel in 0..<3 { pixels[index * 4 + channel] = rgb[channel] } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationSetProperties(destination, [kCGImageDestinationOrientation: 1] as CFDictionary)
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyOrientation: 1, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 1],
             kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.invalid("Fixture JPEG failed.") }
    }
    static func fixture(at root: URL, sessionID: String, stationID: String) throws {
        for path in ["images", "frames", "depth"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try writeJPEG(root.appendingPathComponent("images/000001.jpg"), rgb: [210, 30, 20])
        let frame = FrameRecord(session_id: sessionID, image: "images/000001.jpg",
                                camera_to_world: [[1,0,0,0], [0,1,0,0], [0,0,1,0], [0,0,0,1]],
                                intrinsics: [[56,0,31.5], [0,56,23.5], [0,0,1]],
                                image_resolution: ImageResolution(width: 64, height: 48), timestamp: 1,
                                tracking_state: TrackingRecord(state: "normal", reason: nil), raw_feature_points: [],
                                exposure_duration_seconds: 1.0 / 120, exposure_offset_ev: 0, world_mapping_status: "mapped")
        let sidecar = StationCaptureFrame(station_id: stationID, target_id: StationCaptureTarget.standard[0].id,
                                          frame: frame, depth: nil, depth_availability: "unsupported",
                                          pivot_drift_metres: 0, angular_error_degrees: 0)
        var station = StationCaptureStation(id: stationID, index: 0, origin: [0,0,0], reference_yaw_degrees: 0, started_timestamp: 0)
        station.frames = ["frames/000001.json"]
        station.status = .partial
        var manifest = StationCaptureManifest(sessionID: sessionID, deviceModel: "generated-test-fixture", operatingSystem: "offline", depthSupported: false)
        manifest.stations = [station]
        manifest.status = .partial
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: root.appendingPathComponent("frames/000001.json"), options: .atomic)
        manifest.stored_bytes = Int64(try Data(contentsOf: root.appendingPathComponent("images/000001.jpg")).count + encoder.encode(sidecar).count)
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try StationCaptureArchive.validateForExport(at: root)
    }

    static func main() throws {
        if CommandLine.arguments.contains("--intentional-failure") { check(false, "assertion checker") }
        let sessionID = UUID().uuidString, stationID = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("panorama-store-tests-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent(sessionID)
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GuidedPanoramaPreviews").appendingPathComponent(sessionID)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: cache)
        }
        try fixture(at: root, sessionID: sessionID, stationID: stationID)
        let original = try snapshot(root)
        func build(_ cancellation: GuidedPanoramaPreviewCancellation = .init(),
                   progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> [PanoramaPreviewStation] {
            try GuidedPanoramaPreviewStore.build(tourURL: root, cancellation: cancellation, progress: progress)
        }
        let first = try build()
        check(first.count == 1 && first[0].id == stationID, "first build returns requested station identity")
        check(first[0].coverage > 0 && first[0].coverage < 1, "partial capture stays partial in projected coverage")
        check(first[0].label.contains("partial"), "partial station is visibly labelled")
        let image = first[0].panoramaURL, json = cache.appendingPathComponent(stationID + ".json")
        let firstReceipt = try receipt(json)
        let firstImageDigest = try digest(image)
        check(firstReceipt["inputDigest"] as? String != nil && firstReceipt["imageDigest"] as? String == firstImageDigest, "cache binds sources and derived image bytes")
        let firstImageInode = try inode(image), firstReceiptInode = try inode(json)
        let hit = try build()
        check(hit.count == 1 && hit[0].coverage == first[0].coverage, "cache hit returns same photographic coverage")
        check(try inode(image) == firstImageInode && inode(json) == firstReceiptInode, "cache hit does not replace image or receipt")
        check(try snapshot(root) == original, "first build and hit preserve all original bytes")

        try writeJPEG(root.appendingPathComponent("images/000001.jpg"), rgb: [20, 40, 215])
        let changedOriginal = try snapshot(root)
        _ = try build()
        let changedReceipt = try receipt(json)
        check(firstReceipt["inputDigest"] as? String != changedReceipt["inputDigest"] as? String, "source JPEG change invalidates fingerprint")
        check(firstReceipt["imageDigest"] as? String != changedReceipt["imageDigest"] as? String, "source color change regenerates actual PNG")
        let goodImage = try Data(contentsOf: image), goodImageDigest = try digest(image)
        try Data("corrupt derived PNG".utf8).write(to: image)
        _ = try build()
        check(try digest(image) == goodImageDigest, "corrupt derived image regenerated from originals")
        try Data("broken receipt".utf8).write(to: json)
        _ = try build()
        check(try receipt(json)["inputDigest"] as? String == changedReceipt["inputDigest"] as? String, "corrupt receipt is rebuilt and rebound")
        check(try digest(image) == goodImageDigest, "rebound receipt points to expected PNG")
        check(try snapshot(root) == changedOriginal, "regeneration never changes original archive")

        let beforeCancelledReceipt = try Data(contentsOf: json)
        let preCancelled = GuidedPanoramaPreviewCancellation()
        preCancelled.cancel()
        rejects("pre-cancelled cache read") { _ = try build(preCancelled) }
        check(try Data(contentsOf: image) == goodImage && Data(contentsOf: json) == beforeCancelledReceipt, "pre-cancel leaves accepted cache intact")
        // Force a new render without modifying photographs; cancellation occurs
        // after its first source, before any new PNG may be published.
        try Data("receipt requires regeneration".utf8).write(to: json)
        let during = GuidedPanoramaPreviewCancellation()
        var sawRender = false
        rejects("in-progress regeneration cancellation") {
            _ = try build(during, progress: { fraction, _ in
                if fraction > 0 && fraction < 1 { sawRender = true; during.cancel() }
            })
        }
        check(sawRender, "cancellation exercised actual renderer progress")
        check(try Data(contentsOf: image) == goodImage, "cancelled regeneration preserves previous completed preview")
        check(try snapshot(root) == changedOriginal, "cancelled regeneration preserves every raw file")
        let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        check(cacheFiles.allSatisfy { !$0.contains("partial") }, "cancelled render leaves no partial cache assets")
        _ = try build()
        check(try digest(image) == goodImageDigest, "explicit later preview succeeds after cancellation")

        let source = root.appendingPathComponent("images/000001.jpg")
        let sourceBytes = try Data(contentsOf: source)
        try Data("truncated input".utf8).write(to: source)
        rejects("corrupt source despite an existing cache") { _ = try build() }
        check(try Data(contentsOf: image) == goodImage, "invalid raw source does not replace completed cache")
        try sourceBytes.write(to: source)
        check(try snapshot(root) == changedOriginal, "fixture source restored exactly after corruption case")
        _ = try StationCaptureArchive.validateForExport(at: root)
        print("PASS GuidedPanoramaPreviewStoreTests \(checks) assertions. Actual production archive/store/renderer; generated local source images only.")
    }
}
