#if SPATIAL_CAPTURE_LAB
import Foundation
import CryptoKit
import ImageIO

/// Derived previews can be rebuilt from the immutable local scan. They never
/// enter the walking-capture upload queue or replace the original photographs.
final class GuidedPanoramaPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum GuidedPanoramaPreviewStore {
    static let queue = DispatchQueue(label: "rendprop.panorama.preview", qos: .userInitiated)
    private static let outputWidth = 4096

    private struct Receipt: Codable {
        let version: Int
        let sessionID: String
        let stationID: String
        let inputDigest: String
        let imageDigest: String
        let width: Int
        let height: Int
        let solidAngleCoverage: Double
    }

    static func build(tourURL: URL, stationIDs: Set<String>? = nil,
                      cancellation: GuidedPanoramaPreviewCancellation,
                      progress: @escaping (Double, String) -> Void) throws -> [PanoramaPreviewStation] {
        let manifest = try StationCaptureArchive.loadManifest(at: tourURL)
        let stations = manifest.stations.filter { !$0.frames.isEmpty && (stationIDs == nil || stationIDs!.contains($0.id)) }
        guard !stations.isEmpty else { throw CaptureError.invalid("No photos have been saved yet.") }
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GuidedPanoramaPreviews", isDirectory: true)
        try prepareDirectory(base)
        let cache = base.appendingPathComponent(manifest.session_id, isDirectory: true)
        try prepareDirectory(cache)
        var result: [PanoramaPreviewStation] = []
        for (index, station) in stations.enumerated() {
            try checkCancellation(cancellation)
            progress(Double(index) / Double(stations.count), "Preparing position \(station.index + 1)…")
            let frames = try StationCaptureArchive.loadFrames(at: tourURL, stationID: station.id)
            var digest = SHA256()
            digest.update(data: Data("rendprop-panorama-v1|4096|world-yaw-zero".utf8))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest.update(data: try encoder.encode(station))
            for frame in frames {
                try checkCancellation(cancellation)
                digest.update(data: try encoder.encode(frame))
                digest.update(data: Data(try fileDigest(tourURL.appendingPathComponent(frame.frame.image), maximumBytes: NativeRasterWriter.maximumJPEGBytes, cancellation: cancellation).utf8))
            }
            let inputDigest = hex(digest.finalize())
            let imageURL = cache.appendingPathComponent(station.id + ".png")
            let receiptURL = cache.appendingPathComponent(station.id + ".json")
            let receipt: Receipt
            if let existing = try? readReceipt(receiptURL), existing.version == 1,
               existing.sessionID == manifest.session_id, existing.stationID == station.id,
               existing.inputDigest == inputDigest, existing.width == outputWidth, existing.height == outputWidth / 2,
               existing.solidAngleCoverage.isFinite, (0...1).contains(existing.solidAngleCoverage),
               (try? verifyImage(imageURL, receipt: existing, cancellation: cancellation)) == true {
                receipt = existing
            } else {
                let inputs = frames.map { record in
                    PanoramaFrameInput(imageURL: tourURL.appendingPathComponent(record.frame.image),
                                       cameraToWorld: record.frame.camera_to_world,
                                       intrinsics: record.frame.intrinsics,
                                       resolution: record.frame.image_resolution)
                }
                let temporary = cache.appendingPathComponent(UUID().uuidString + ".partial.png")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let report = try PanoramaRenderer.render(
                    PanoramaRenderRequest(frames: inputs, origin: station.origin,
                                          referenceYawRadians: 0, maximumCameraDisplacementMetres: StationCaptureLimits.maximumPivotDriftMeters,
                                          width: outputWidth), to: temporary,
                    isCancelled: { cancellation.isCancelled }, progress: { fraction in
                        progress((Double(index) + fraction) / Double(stations.count), "Building position \(station.index + 1) of \(stations.count)…")
                    })
                try checkCancellation(cancellation)
                receipt = Receipt(version: 1, sessionID: manifest.session_id, stationID: station.id,
                                  inputDigest: inputDigest,
                                  imageDigest: try fileDigest(temporary, maximumBytes: 96 * 1024 * 1024, cancellation: cancellation),
                                  width: report.width, height: report.height, solidAngleCoverage: report.solidAngleCoverage)
                // Publish only a completed image. A missing/mismatched receipt
                // after interruption forces regeneration on the next open.
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: imageURL)
                }
                try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
            }
            let suffix = station.status == .complete ? "" : " · partial"
            result.append(PanoramaPreviewStation(id: station.id, label: "Position \(station.index + 1)\(suffix)",
                                                 panoramaURL: imageURL, position: station.origin,
                                                 coverage: receipt.solidAngleCoverage))
        }
        try checkCancellation(cancellation)
        progress(1, "Your room tour is ready.")
        return result
    }

    private static func prepareDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CaptureError.invalid("The preview cache is not a local directory.")
        }
    }

    private static func readReceipt(_ url: URL) throws -> Receipt {
        try JSONDecoder().decode(Receipt.self, from: NativeRasterWriter.boundedJSONData(at: url, maximumBytes: 8192))
    }

    private static func verifyImage(_ url: URL, receipt: Receipt, cancellation: GuidedPanoramaPreviewCancellation) throws -> Bool {
        guard try fileDigest(url, maximumBytes: 96 * 1024 * 1024, cancellation: cancellation) == receipt.imageDigest,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width == receipt.width && height == receipt.height
    }

    private static func fileDigest(_ url: URL, maximumBytes: Int, cancellation: GuidedPanoramaPreviewCancellation) throws -> String {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw CaptureError.invalid("A saved preview or photo exceeds its file limits.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try checkCancellation(cancellation)
            total += chunk.count
            guard total <= maximumBytes else { throw CaptureError.invalid("A saved file changed while preparing its preview.") }
            digest.update(data: chunk)
        }
        guard total == size else { throw CaptureError.invalid("A saved file changed while preparing its preview.") }
        return hex(digest.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func checkCancellation(_ cancellation: GuidedPanoramaPreviewCancellation) throws {
        if cancellation.isCancelled { throw CaptureError.invalid("Preview cancelled. Your original photos are saved.") }
    }
}
#endif
