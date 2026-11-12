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
    var captureComplete = false
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
    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
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
    static func fixture(at root: URL, sessionID: String, stationID: String,
                        profile: StationCaptureGeometryProfile = .legacyPivotV1,
                        positions: [[Double]] = [[0, 0, 0]], validate: Bool = true) throws {
        for path in ["images", "frames", "depth"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        var station = StationCaptureStation(id: stationID, index: 0, origin: [0,0,0], reference_yaw_degrees: 0, started_timestamp: 0)
        station.targets = profile.targets
        station.status = .partial
        var manifest = StationCaptureManifest(sessionID: sessionID, deviceModel: "generated-test-fixture", operatingSystem: "offline", depthSupported: false, profile: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, position) in positions.enumerated() {
            let number = String(format: "%06d", index + 1)
            let imagePath = "images/\(number).jpg", framePath = "frames/\(number).json"
            try writeJPEG(root.appendingPathComponent(imagePath), rgb: [210, 30, 20])
            let yaw = profile.targets[index].yaw_degrees * .pi / 180
            let frame = FrameRecord(session_id: sessionID, image: imagePath,
                camera_to_world: [[cos(yaw),0,-sin(yaw),position[0]], [0,1,0,position[1]], [sin(yaw),0,cos(yaw),position[2]], [0,0,0,1]],
                intrinsics: [[56,0,31.5], [0,56,23.5], [0,0,1]],
                image_resolution: ImageResolution(width: 64, height: 48), timestamp: Double(index + 1),
                tracking_state: TrackingRecord(state: "normal", reason: nil), raw_feature_points: [],
                exposure_duration_seconds: 1.0 / 120, exposure_offset_ev: 0, world_mapping_status: "mapped")
            let sidecar = StationCaptureFrame(station_id: stationID, target_id: profile.targets[index].id,
                frame: frame, depth: nil, depth_availability: "unsupported",
                pivot_drift_metres: sqrt(position.reduce(0) { $0 + $1 * $1 }), angular_error_degrees: 0)
            let sidecarBytes = try encoder.encode(sidecar)
            try sidecarBytes.write(to: root.appendingPathComponent(framePath), options: .atomic)
            manifest.stored_bytes += Int64(try Data(contentsOf: root.appendingPathComponent(imagePath)).count + sidecarBytes.count)
            station.frames.append(framePath)
        }
        manifest.stations = [station]
        manifest.status = .partial
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        if validate { _ = try StationCaptureArchive.validateForExport(at: root) }
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
        let legacyManifestURL = root.appendingPathComponent("manifest.json")
        let legacyManifestBytes = try Data(contentsOf: legacyManifestURL)
        let legacyManifest = try StationCaptureArchive.loadManifest(at: root)
        let legacyJSON = try receipt(legacyManifestURL)
        check(legacyManifest.geometryProfile == .legacyPivotV1 && legacyManifest.schema_version == 1,
              "legacy fixture imports under its original profile")
        check(legacyJSON["capture_policy"] == nil && legacyJSON["maximum_camera_span_metres"] == nil,
              "legacy fixture retains absent v2 fields")
        let legacyEncoder = JSONEncoder(); legacyEncoder.outputFormatting = [.sortedKeys]
        check(try legacyEncoder.encode(legacyManifest) == legacyManifestBytes, "legacy golden manifest re-exports byte for byte")
        func build(_ cancellation: GuidedPanoramaPreviewCancellation = .init(),
                   progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> [PanoramaPreviewStation] {
            try GuidedPanoramaPreviewStore.build(tourURL: root, cancellation: cancellation, progress: progress)
        }
        let first = try build()
        check(first.count == 1 && first[0].id == stationID, "first build returns requested station identity")
        check(first[0].coverage > 0 && first[0].coverage < 1, "partial capture stays partial in projected coverage")
        check(first[0].label.contains("partial"), "partial station is visibly labelled")
        check(!first[0].captureComplete, "partial archive cannot advertise complete navigation after rendering")
        let image = first[0].panoramaURL, json = cache.appendingPathComponent(stationID + ".json")
        let firstReceipt = try receipt(json)
        let firstImageDigest = try digest(image)
        check(firstReceipt["inputDigest"] as? String != nil && firstReceipt["imageDigest"] as? String == firstImageDigest, "cache binds sources and derived image bytes")
        check(firstReceipt["geometryProfile"] as? String == StationCaptureGeometryProfile.legacyPivotV1.rawValue
              && firstReceipt["cameraDisplacementLimitMetres"] as? Double == 0.10
              && firstReceipt["cameraSpanLimitMetres"] as? Double == 0.20, "legacy cache identifies its supported profile and limits")
        let firstImageInode = try inode(image), firstReceiptInode = try inode(json)
        let hit = try build()
        check(hit.count == 1 && hit[0].coverage == first[0].coverage, "cache hit returns same photographic coverage")
        check(!hit[0].captureComplete, "cache hit preserves partial archive navigation status")
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
        try checkProfiles(at: temporary)
        print("PASS GuidedPanoramaPreviewStoreTests \(checks) assertions. Actual production archive/store/renderer; generated local source images only.")
    }

    static func checkProfiles(at temporary: URL) throws {
        let sessionID = UUID().uuidString, stationID = UUID().uuidString
        let root = temporary.appendingPathComponent(sessionID)
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GuidedPanoramaPreviews").appendingPathComponent(sessionID)
        defer { try? FileManager.default.removeItem(at: cache) }
        try fixture(at: root, sessionID: sessionID, stationID: stationID)
        func build() throws -> [PanoramaPreviewStation] {
            try GuidedPanoramaPreviewStore.build(tourURL: root, cancellation: .init(), progress: { _, _ in })
        }
        let legacy = try build()
        let image = legacy[0].panoramaURL, json = cache.appendingPathComponent(stationID + ".json")
        let legacyReceipt = try receipt(json), legacyImage = try Data(contentsOf: image)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let legacyBytes = try Data(contentsOf: manifestURL), legacyObject = try receipt(manifestURL)
        let invalidDeclarations: [[String: Any]] = [
            ["maximum_pivot_drift_metres": 0.20],
            ["capture_policy": StationCaptureGeometryProfile.handheldV2.rawValue],
            ["capture_policy": NSNull()],
            ["maximum_camera_span_metres": NSNull()],
            ["schema_version": 2],
            ["schema_version": 2, "capture_policy": "station-unknown-v3", "maximum_pivot_drift_metres": 0.20, "maximum_camera_span_metres": 0.20],
            ["schema_version": 2, "capture_policy": StationCaptureGeometryProfile.handheldV2.rawValue, "maximum_pivot_drift_metres": 0.20, "maximum_camera_span_metres": 0.30]
        ]
        for mutation in invalidDeclarations {
            var changed = legacyObject
            mutation.forEach { changed[$0.key] = $0.value }
            try writeJSON(changed, to: manifestURL)
            let before = try snapshot(root)
            rejects("misdeclared or unsupported geometry despite cached PNG: \(mutation)") { _ = try build() }
            check(try snapshot(root) == before && Data(contentsOf: image) == legacyImage,
                  "invalid declared geometry preserves original files and accepted cache")
            try legacyBytes.write(to: manifestURL, options: .atomic)
        }
        var handheldObject = legacyObject
        handheldObject["schema_version"] = 2
        handheldObject["capture_policy"] = StationCaptureGeometryProfile.handheldV2.rawValue
        handheldObject["maximum_pivot_drift_metres"] = 0.20
        handheldObject["maximum_camera_span_metres"] = 0.20
        handheldObject["target_plan"] = StationCaptureGeometryProfile.handheldV2.targetPlan
        var changedStations = handheldObject["stations"] as! [[String: Any]]
        let targetData = try JSONEncoder().encode(StationCaptureGeometryProfile.handheldV2.targets)
        changedStations[0]["targets"] = try JSONSerialization.jsonObject(with: targetData)
        handheldObject["stations"] = changedStations
        try writeJSON(handheldObject, to: manifestURL)
        let profileChangedOriginal = try snapshot(root)
        _ = try build()
        let handheldReceipt = try receipt(json)
        check(handheldReceipt["inputDigest"] as? String != legacyReceipt["inputDigest"] as? String,
              "supported profile change invalidates cache fingerprint with unchanged source poses/photos")
        check(handheldReceipt["geometryProfile"] as? String == StationCaptureGeometryProfile.handheldV2.rawValue
              && handheldReceipt["cameraDisplacementLimitMetres"] as? Double == 0.20
              && handheldReceipt["cameraSpanLimitMetres"] as? Double == 0.20, "handheld cache binds exact supported limits")
        check(try Data(contentsOf: image) == legacyImage && snapshot(root) == profileChangedOriginal,
              "profile change preserves identical photographic projection and every declared raw byte")
        let receiptMutations: [[String: Any]] = [
            ["geometryProfile": "station-unknown-v3"],
            ["geometryProfile": StationCaptureGeometryProfile.legacyPivotV1.rawValue],
            ["cameraDisplacementLimitMetres": 0.10],
            ["cameraSpanLimitMetres": 0.30],
            ["maximumCameraDisplacementMetres": 0.10],
            ["maximumCameraSpanMetres": 0.10]
        ]
        for mutation in receiptMutations {
            var changed = handheldReceipt
            mutation.forEach { changed[$0.key] = $0.value }
            try writeJSON(changed, to: json)
            let changedInode = try inode(json)
            _ = try build()
            check(try inode(json) != changedInode, "tampered cached policy or measured geometry is regenerated: \(mutation)")
            let corrected = try receipt(json)
            check(corrected["geometryProfile"] as? String == StationCaptureGeometryProfile.handheldV2.rawValue
                  && corrected["cameraDisplacementLimitMetres"] as? Double == 0.20
                  && corrected["cameraSpanLimitMetres"] as? Double == 0.20
                  && corrected["maximumCameraDisplacementMetres"] as? Double == 0
                  && corrected["maximumCameraSpanMetres"] as? Double == 0, "regenerated receipt accurately reports original measured geometry")
        }
        check(try snapshot(root) == profileChangedOriginal, "cache policy tampering does not change any original")

        let boundedID = UUID().uuidString, boundedStationID = UUID().uuidString
        let boundedRoot = temporary.appendingPathComponent(boundedID)
        let boundedCache = cache.deletingLastPathComponent().appendingPathComponent(boundedID)
        defer { try? FileManager.default.removeItem(at: boundedCache) }
        try fixture(at: boundedRoot, sessionID: boundedID, stationID: boundedStationID,
                    profile: .handheldV2, positions: [[0, 0, 0], [0.18, 0, 0]])
        let boundedOriginal = try snapshot(boundedRoot)
        let bounded = try GuidedPanoramaPreviewStore.build(tourURL: boundedRoot, cancellation: .init(), progress: { _, _ in })
        let boundedReceipt = try receipt(boundedCache.appendingPathComponent(boundedStationID + ".json"))
        check(bounded.count == 1 && bounded[0].coverage > 0, "actual store renders validated one-sided 18 cm handheld photos")
        check(abs((boundedReceipt["maximumCameraDisplacementMetres"] as? Double ?? -1) - 0.18) < 1e-12
              && abs((boundedReceipt["maximumCameraSpanMetres"] as? Double ?? -1) - 0.18) < 1e-12,
              "actual cache reports 18 cm measured radius and span")
        _ = try StationCaptureArchive.validateForExport(at: boundedRoot)
        check(try snapshot(boundedRoot) == boundedOriginal, "handheld import/export/preview leaves every original unchanged")

        for positions in [[[0.0, 0, 0], [0.18, 0, 0], [-0.18, 0, 0]], [[0.0, 0, 0], [0.201, 0, 0]]] {
            let invalidID = UUID().uuidString, invalidStationID = UUID().uuidString
            let invalidRoot = temporary.appendingPathComponent(invalidID)
            let invalidCache = cache.deletingLastPathComponent().appendingPathComponent(invalidID)
            defer { try? FileManager.default.removeItem(at: invalidCache) }
            try fixture(at: invalidRoot, sessionID: invalidID, stationID: invalidStationID,
                        profile: .handheldV2, positions: positions, validate: false)
            let original = try snapshot(invalidRoot)
            rejects("out-of-bounds handheld archive span/radius") {
                _ = try GuidedPanoramaPreviewStore.build(tourURL: invalidRoot, cancellation: .init(), progress: { _, _ in })
            }
            rejects("out-of-bounds handheld archive export") { _ = try StationCaptureArchive.validateForExport(at: invalidRoot) }
            check(try snapshot(invalidRoot) == original, "rejected handheld archive originals are preserved")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: invalidCache.path)) ?? []
            check(files.isEmpty, "rejected geometry publishes no preview image or receipt")
        }
    }
}
