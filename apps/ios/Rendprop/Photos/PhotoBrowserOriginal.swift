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
        var fullRaster = true

        var note: String? {
            if !fullRaster { return "JPEG website copy up to 4096 pixels; the unchanged full-size source remains in local history and Originals exports." }
            return convertedToJPEG
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

    /// A gallery delivery has the existing10MiB public-photo ceiling. Large
    /// compatible originals use a separate max4096px browser copy; the saved
    /// source and original-disclosure prepare() path stay unchanged.
    static func prepareGallery(_ sourceURL: URL) throws -> Prepared {
      // Metadata first, without a full-raster decode.64MP admits the actual
      // 8160x6120 source. It is a finite input bound, not a peakRSS promise.
      // 128MiB below is compressed-file size, never a decoded-raster cap.
      let resource = try sourceURL.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard resource.isRegularFile == true, resource.isSymbolicLink != true,
        let sourceBytes = resource.fileSize, sourceBytes > 0, sourceBytes <= 128 * 1024 * 1024,
        let source = CGImageSourceCreateWithURL(
          sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let sourceType = CGImageSourceGetType(source) as String?,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 64_000_000 / height
      else {
        throw Failure(
          message:
            "This photo is too large to prepare safely for the website. The original stays saved and can still be used by supported original-photo tools."
        )
      }
      let compatible = [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier]
        .contains(sourceType)
      if !compatible || sourceBytes <= 9_500_000 {
        let full = try prepare(sourceURL)
        let bytes =
          (try FileManager.default.attributesOfItem(atPath: full.url.path)[.size] as? NSNumber)?
          .int64Value ?? 0
        if bytes > 0, bytes <= 9_500_000 { return full }
        full.removeTemporaryFiles()
      }
      try Task.checkCancellation()
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary), image.width > 0, image.height > 0, image.width <= 4096,
        image.height <= 4096
      else {
        throw Failure(
          message: "Couldn't prepare this photo's website copy. The full-size original stays saved.")
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Rendprop-gallery-copy-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      do {
        let target = directory.appendingPathComponent("gallery.jpg")
        for quality in [0.90, 0.80, 0.70, 0.60] {
          try Task.checkCancellation()
          try? FileManager.default.removeItem(at: target)
          guard
            let destination = CGImageDestinationCreateWithURL(
              target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
          else {
            throw Failure(
              message: "Couldn't save this photo's website copy. The original stays saved.")
          }
          // The thumbnail transform already appliedEXIF orientation.
          // Keep the actual thumbnail raster / color, not source pixel tags.
          var output = properties
          output[kCGImagePropertyPixelWidth] = image.width
          output[kCGImagePropertyPixelHeight] = image.height
          output[kCGImagePropertyOrientation] = 1
          output[kCGImageDestinationLossyCompressionQuality] = quality
          CGImageDestinationAddImage(destination, image, output as CFDictionary)
          guard CGImageDestinationFinalize(destination) else {
            throw Failure(
              message: "Couldn't finish this photo's website copy. The original stays saved.")
          }
          // A fresh file stat is required after each rewrite; URL resource
          // values may cache an earlier encode's file size.
          let size =
            (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?
            .int64Value ?? 0
          if size > 0, size <= 9_500_000 {
            guard let verified = CGImageSourceCreateWithURL(target as CFURL, nil),
              let actualType = CGImageSourceGetType(verified) as String?,
              UTType(actualType)?.conforms(to: .jpeg) == true,
              let actual = CGImageSourceCopyPropertiesAtIndex(verified, 0, nil) as? [CFString: Any],
              actual[kCGImagePropertyPixelWidth] as? Int == image.width,
              actual[kCGImagePropertyPixelHeight] as? Int == image.height,
              ((actual[kCGImagePropertyOrientation] as? Int) ?? 1) == 1
            else {
              throw Failure(
                message: "Couldn't verify this photo's website copy. The original stays saved.")
            }
            return Prepared(
              url: target, temporaryDirectory: directory, sourceType: sourceType,
              convertedToJPEG: true,
              pixelWidth: image.width, pixelHeight: image.height, orientation: 1, fullRaster: false)
          }
        }
        throw Failure(
          message:
            "This photo's website copy is still too large to upload. The full-size original and current listing choice are kept."
        )
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }
}
