import Foundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

final class NativeRasterWriter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func write(_ pixelBuffer: CVPixelBuffer, resolution: ImageResolution, to destination: URL) throws {
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == resolution.width,
              properties[kCGImagePropertyPixelHeight] as? Int == resolution.height,
              properties[kCGImagePropertyOrientation] as? Int == 1,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw CaptureError.invalid("JPEG dimensions, orientation or decoding failed validation.")
        }
    }

    static func validateCapture(at root: URL) throws -> CaptureManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(CaptureManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schema_version == 1, manifest.format == "rendprop-arkit-capture",
              manifest.image_orientation == "sensor-native-exif-1", manifest.matrix_layout == "row-major",
              manifest.coordinate_system == "arkit-right-handed-y-up-camera-minus-z-forward",
              manifest.pose_type == "camera-to-world", manifest.world_alignment == "gravity", manifest.units == "metres" else {
            throw CaptureError.invalid("Capture manifest coordinate/schema contract is invalid.")
        }
        guard manifest.isExportable else {
            throw CaptureError.invalid("Export requires a complete capture with at least 20 frames and ARKit feature points. The original files remain saved.")
        }
        var lastTimestamp = -Double.infinity
        var resolution: ImageResolution?
        var pointObservations = 0
        for (index, relativePath) in manifest.frames.enumerated() {
            try autoreleasepool {
            guard relativePath == String(format: "frames/%06d.json", index + 1) else {
                throw CaptureError.invalid("Non-contiguous frame manifest.")
            }
            let frame = try decoder.decode(FrameRecord.self, from: Data(contentsOf: root.appendingPathComponent(relativePath)))
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
}
