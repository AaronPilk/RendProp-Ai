import Foundation
import ImageIO

struct VideoPhotoFramingAssessment: Identifiable, Sendable {
    let photoID: String
    let sourceURL: URL
    let displayedWidth: Int
    let displayedHeight: Int
    let crop: DeliveryCrop
    var id: String { photoID }
    var loss: Double { 1 - crop.width * crop.height }
    var isMajorCrop: Bool { loss > VideoFramingReviewPolicy.majorCropThreshold }
    var orientationLabel: String { displayedWidth > displayedHeight ? "Landscape" : displayedWidth < displayedHeight ? "Portrait" : "Square" }
}

enum VideoFramingReviewPolicy {
    static let majorCropThreshold = 0.30
    static func displayedSize(width: Int, height: Int, exifOrientation: Int) -> (Int, Int)? {
        guard width > 0, height > 0, (1...8).contains(exifOrientation) else { return nil }
        return (5...8).contains(exifOrientation) ? (height, width) : (width, height)
    }
    static func selectionKey(aspect: String, photoIDs: [String]) -> String {
        (try? JSONEncoder().encode([aspect] + photoIDs).base64EncodedString()) ?? ""
    }
    static func needsAcknowledgment(assessments: [VideoPhotoFramingAssessment], selectionKey: String, acknowledgedKey: String?) -> Bool {
        assessments.contains(where: \.isMajorCrop) && selectionKey != acknowledgedKey
    }
}

/// Reads the saved version's actual image metadata and decodes a tiny,
/// orientation-correct thumbnail. No original is rewritten or stretched.
enum VideoPhotoFramingReader {
    static func read(photoID: String, url: URL, aspect: Double) -> VideoPhotoFramingAssessment? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let size = VideoFramingReviewPolicy.displayedSize(width: width, height: height,
                exifOrientation: properties[kCGImagePropertyOrientation] as? Int ?? 1),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil,
              let crop = DeliveryCrop.centered(sourceWidth: Double(size.0), sourceHeight: Double(size.1), deliveryAspect: aspect) else { return nil }
        return .init(photoID: photoID, sourceURL: url, displayedWidth: size.0, displayedHeight: size.1, crop: crop)
    }
}
