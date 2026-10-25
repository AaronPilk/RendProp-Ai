import Foundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

final class NativeRasterWriter {
    static let maximumManifestBytes = 256 * 1024
    // 50,000 feature points with UInt64 IDs and full Float-coordinate decimal
    // precision fit comfortably below this bound. Never read arbitrary file sizes.
    static let maximumSidecarBytes = 16 * 1024 * 1024
    // Generous allowance for quality-0.92, 8-bit native JPEGs: 4 encoded bytes
    // per permitted pixel at the raster ceiling. Not a process-memory guarantee.
    static let maximumJPEGBytes = 64 * 1024 * 1024
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func write(_ pixelBuffer: CVPixelBuffer, resolution: ImageResolution, to destination: URL) throws {
        try CaptureRasterLimits.validate(resolution)
        guard CVPixelBufferGetWidth(pixelBuffer) == resolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == resolution.height else {
            throw CaptureError.invalid("Native image resolution disagrees with ARCamera calibration.")
        }
        // Core Image interprets the sensor buffer directly. No orientation, displayTransform,
        // UIImage, resize, crop or mirror operation may enter this calibration path.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent == CGRect(x: 0, y: 0, width: resolution.width, height: resolution.height),
              let raster = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace),
              let jpeg = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError.invalid("Could not create native JPEG raster.")
        }
        // ImageIO may omit canonical Orientation=1 unless the TIFF/EXIF directory
        // is explicit. The adapter requires the actual tag, so verify its bytes.
        CGImageDestinationSetProperties(jpeg, [kCGImageDestinationOrientation: 1] as CFDictionary)
        CGImageDestinationAddImage(jpeg, raster, [kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 1],
            kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg) else { throw CaptureError.invalid("JPEG write failed; check free storage.") }
        try Self.validateJPEG(at: destination, resolution: resolution)
    }

    static func validateJPEG(at url: URL, resolution: ImageResolution) throws {
        let source = try validatedJPEGSource(at: url, resolution: resolution)
        guard let raster = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              raster.width == resolution.width, raster.height == resolution.height,
              raster.bitsPerComponent == 8 else {
            throw CaptureError.invalid("JPEG decoded dimensions or depth disagree with validated metadata.")
        }
    }

    // Kept separate from full raster decoding so every resource check is made
    // before ImageIO can allocate the decoded image.
    static func validatedJPEGSource(at url: URL, resolution: ImageResolution) throws -> CGImageSource {
        try CaptureRasterLimits.validate(resolution)
        let bytes = try boundedData(at: url, maximumBytes: maximumJPEGBytes, kind: "JPEG")
        let metadataOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, metadataOptions),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, metadataOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              properties[kCGImagePropertyDepth] as? Int == 8,
              properties[kCGImagePropertyOrientation] as? Int == 1 else {
            throw CaptureError.invalid("JPEG type, depth, dimensions or orientation failed validation.")
        }
        let native = ImageResolution(width: width, height: height)
        try CaptureRasterLimits.validate(native)
        guard native == resolution else {
            throw CaptureError.invalid("JPEG dimensions disagree with ARCamera calibration.")
        }
        return source
    }

    static func validateCapture(at root: URL) throws -> CaptureManifest {
        let rootProperties = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootProperties.isDirectory == true, rootProperties.isSymbolicLink != true else {
            throw CaptureError.invalid("Capture root must be a local directory, not a symbolic link.")
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(CaptureManifest.self, from: boundedJSONData(at: root.appendingPathComponent("manifest.json"), maximumBytes: maximumManifestBytes))
        guard manifest.schema_version == 1, manifest.format == "rendprop-arkit-capture",
              manifest.image_orientation == "sensor-native-exif-1", manifest.matrix_layout == "row-major",
              manifest.coordinate_system == "arkit-right-handed-y-up-camera-minus-z-forward",
              manifest.pose_type == "camera-to-world", manifest.world_alignment == "gravity", manifest.units == "metres" else {
            throw CaptureError.invalid("Capture manifest coordinate/schema contract is invalid.")
        }
        guard manifest.isExportable, manifest.frames.count <= 400 else {
            throw CaptureError.invalid("Export requires a complete capture with 20–400 frames and ARKit feature points. The original files remain saved.")
        }
        try validateFileSet(at: root, frameCount: manifest.frames.count)
        var lastTimestamp = -Double.infinity
        var resolution: ImageResolution?
        var pointObservations = 0
        for (index, relativePath) in manifest.frames.enumerated() {
            try autoreleasepool {
            guard relativePath == String(format: "frames/%06d.json", index + 1) else {
                throw CaptureError.invalid("Non-contiguous frame manifest.")
            }
            let frame = try decoder.decode(FrameRecord.self, from: boundedJSONData(at: root.appendingPathComponent(relativePath), maximumBytes: maximumSidecarBytes))
            try frame.validate(expectedSession: manifest.session_id)
            guard frame.image == String(format: "images/%06d.jpg", index + 1), frame.timestamp > lastTimestamp,
                  resolution == nil || resolution == frame.image_resolution else {
                throw CaptureError.invalid("Frame order, image pairing or image resolution changed.")
            }
            try validateJPEG(at: root.appendingPathComponent(frame.image), resolution: frame.image_resolution)
            lastTimestamp = frame.timestamp
            resolution = frame.image_resolution
            pointObservations += frame.raw_feature_points.count
            }
        }
        guard pointObservations == manifest.feature_point_observations else {
            throw CaptureError.invalid("Feature point count does not match sidecars.")
        }
        return manifest
    }

    static func boundedJSONData(at url: URL, maximumBytes: Int) throws -> Data {
        try boundedData(at: url, maximumBytes: maximumBytes, kind: "JSON")
    }

    private static func boundedData(at url: URL, maximumBytes: Int, kind: String) throws -> Data {
        let (readLimit, overflow) = maximumBytes.addingReportingOverflow(1)
        guard maximumBytes >= 0, !overflow else { throw CaptureError.invalid("Invalid capture file byte limit.") }
        try requireRegularFile(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        // Handle short reads without accepting only a prefix of an oversized
        // file. No length lookup or unbounded Data(contentsOf:) read is needed.
        while bytes.count < readLimit {
            let chunk = try handle.read(upToCount: min(1024 * 1024, readLimit - bytes.count)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        guard bytes.count <= maximumBytes else {
            throw CaptureError.invalid("Capture \(kind) exceeds the \(maximumBytes)-byte safety limit. Files are preserved.")
        }
        return bytes
    }

    private static func requireRegularFile(at url: URL) throws {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw CaptureError.invalid("Capture files must be regular local files, not symbolic links.")
        }
    }

    private static func validateFileSet(at root: URL, frameCount: Int) throws {
        // The picker copies the WHOLE directory. Checking only referenced files
        // would still export an unvalidated orphan/link alongside a valid capture.
        // Refuse unexpected content; preserve it for diagnosis instead of deleting
        // or silently omitting it. At most 803 declared nodes exist for 400 frames.
        var remaining: Set<String> = ["manifest.json", "images", "frames"]
        for index in 1...frameCount {
            remaining.insert(String(format: "images/%06d.jpg", index))
            remaining.insert(String(format: "frames/%06d.json", index))
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CaptureError.invalid("Capture files could not be enumerated.")
        }
        while let url = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            // Use traversal depth, not a string prefix: Foundation can return
            // /private/var children for a /var root (or the reverse). Never resolve
            // a child URL first, which would conceal that child's symbolic link.
            let relative: String
            switch enumerator.level {
            case 1: relative = url.lastPathComponent
            case 2: relative = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            default: throw CaptureError.invalid("Capture contains an unexpected nested directory.")
            }
            guard remaining.remove(relative) != nil else {
                throw CaptureError.invalid("Capture contains unexpected files or directories. Files are preserved; export is unavailable.")
            }
            let properties = try url.resourceValues(forKeys: keys)
            let directoryExpected = relative == "images" || relative == "frames"
            guard properties.isSymbolicLink != true,
                  directoryExpected ? properties.isDirectory == true : properties.isRegularFile == true else {
                throw CaptureError.invalid("Capture contains a symbolic link or an invalid file type.")
            }
        }
        if let enumerationError { throw enumerationError }
        guard remaining.isEmpty else { throw CaptureError.invalid("Capture is missing declared files or directories.") }
    }
}
