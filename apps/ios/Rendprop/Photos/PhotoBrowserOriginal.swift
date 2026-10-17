import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Public source comparisons need a browser-readable image. Keep the delivered
/// original bytes in the local photo history and exports; this prepares only a
/// temporary full-resolution compatibility copy for the existing cloud route.
enum PhotoBrowserOriginal {
    struct Prepared: Sendable {
        let url: URL
        let temporaryDirectory: URL?
        let sourceType: String
        let convertedToJPEG: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let orientation: Int

        var note: String? {
            convertedToJPEG
                ? "Full-resolution JPEG copy for browser compatibility; the unchanged source file remains in local history and Originals exports."
                : nil
        }
        func removeTemporaryFiles() {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(_ sourceURL: URL) throws -> Prepared {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw Failure(message: "The retained original is unreadable. Its saved file has not been changed.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let type = UTType(sourceType)
        let compatibleExtension: String?
        if type?.conforms(to: .jpeg) == true { compatibleExtension = "jpg" }
        else if type?.conforms(to: .png) == true { compatibleExtension = "png" }
        else if type?.conforms(to: .webP) == true { compatibleExtension = "webp" }
        else { compatibleExtension = nil }
        if let ext = compatibleExtension,
           (["jpg", "jpeg"].contains(sourceURL.pathExtension.lowercased()) && ext == "jpg"
                || sourceURL.pathExtension.lowercased() == ext) {
            return Prepared(url: sourceURL, temporaryDirectory: nil, sourceType: sourceType,
                            convertedToJPEG: false, pixelWidth: width, pixelHeight: height, orientation: orientation)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rendprop-browser-original-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let target = directory.appendingPathComponent("original." + (compatibleExtension ?? "jpg"))
            if compatibleExtension != nil {
                // Some old history names end in .jpg even when the bytes are
                // PNG or WebP. Correct the extension without converting pixels.
                try FileManager.default.copyItem(at: sourceURL, to: target)
            } else {
                // No thumbnail, scaling, crop or drawing context. Decode the
                // full pixel raster and keep its ICC color space and EXIF
                // orientation in the browser JPEG. JPEG is re-encoded at1.0;
                // it is never described as byte-identical to the retained source.
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      image.width == width, image.height == height,
                      let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw Failure(message: "Couldn't prepare a full-resolution browser copy. The original file stays saved.")
                }
                var output = properties
                output[kCGImageDestinationLossyCompressionQuality] = 1.0
                output[kCGImagePropertyOrientation] = orientation
                CGImageDestinationAddImage(destination, image, output as CFDictionary)
                guard CGImageDestinationFinalize(destination),
                      let verified = CGImageSourceCreateWithURL(target as CFURL, nil),
                      let actualType = CGImageSourceGetType(verified) as String?,
                      UTType(actualType)?.conforms(to: .jpeg) == true,
                      let actual = CGImageSourceCopyPropertiesAtIndex(verified, 0, nil) as? [CFString: Any],
                      actual[kCGImagePropertyPixelWidth] as? Int == width,
                      actual[kCGImagePropertyPixelHeight] as? Int == height,
                      ((actual[kCGImagePropertyOrientation] as? Int) ?? 1) == orientation else {
                    throw Failure(message: "Couldn't verify the browser copy's full resolution and orientation. The original file stays saved.")
                }
            }
            return Prepared(url: target, temporaryDirectory: directory, sourceType: sourceType,
                            convertedToJPEG: compatibleExtension == nil, pixelWidth: width, pixelHeight: height, orientation: orientation)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
