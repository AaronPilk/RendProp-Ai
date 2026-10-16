import Foundation
import ImageIO

enum PhotoOrientation: String, CaseIterable, Hashable, Sendable {
    case landscape, portrait, square, unknown

    var label: String { rawValue.capitalized }

    static func measured(width: Int, height: Int) -> Self {
        guard width > 0, height > 0 else { return .unknown }
        return width == height ? .square : width > height ? .landscape : .portrait
    }

    static func filtered<T>(_ items: [T], by filter: Self?, orientation: (T) -> Self) -> [T] {
        items.filter { filter == nil || orientation($0) == filter }
    }

    static func counts(_ values: [Self]) -> [Self: Int] {
        values.reduce(into: Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })) { $0[$1, default: 0] += 1 }
    }

    static func summary(_ values: [Self]) -> String {
        let count = counts(values)
        return allCases.filter { count[$0, default: 0] > 0 }
            .map { "\(count[$0, default: 0]) \($0.rawValue)" }.joined(separator: " · ")
    }
}

struct PhotoPixelGeometry: Equatable, Sendable {
    let width: Int
    let height: Int
    var orientation: PhotoOrientation { .measured(width: width, height: height) }
}

struct PhotoGeometryInput: Hashable, Sendable {
    let id: String
    let url: URL
    let bytes: Int?
    let modified: Date?

    init(id: String, url: URL) {
        self.id = id
        self.url = url
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        bytes = (values?[.size] as? NSNumber)?.intValue
        modified = values?[.modificationDate] as? Date
    }
}

/// Observes the exact saved image with a tiny transformed decode. No rewrite,
/// upload or full-resolution raster is needed to classify a photo.
enum PhotoGeometryReader {
    static func observe(_ inputs: [PhotoGeometryInput]) async -> [PhotoGeometryInput: PhotoOrientation] {
        let worker = Task.detached(priority: .utility) {
            var values: [PhotoGeometryInput: PhotoOrientation] = [:]
            for input in inputs {
                guard !Task.isCancelled else { break }
                guard PhotoGeometryInput(id: input.id, url: input.url) == input else { continue }
                let size = autoreleasepool { read(url: input.url) }
                // A replaced version cannot inherit the previous file's label.
                guard PhotoGeometryInput(id: input.id, url: input.url) == input else { continue }
                values[input] = size?.orientation ?? .unknown
            }
            return values
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    static func read(url: URL) -> PhotoPixelGeometry? {
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
              ] as CFDictionary) != nil else { return nil }
        return PhotoPixelGeometry(width: size.0, height: size.1)
    }
}

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

/// A usability floor for the exact processing copy, not a claim of1080p detail.
/// The retained selected photo is never resized or rejected from this metadata.
enum VideoPreparedSourcePolicy {
    static let minimumCropEdge = 480

    enum Failure: LocalizedError {
        case unreadable, smallCopy(portrait: Bool), photoTooLarge, batchTooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read the prepared video photo. Choose that saved photo again."
            case .smallCopy(let portrait):
                return portrait
                    ? "This photo's video copy is too small after portrait framing. Choose the full-resolution Original or a portrait photo for a Social video. Your saved photo is unchanged."
                    : "This photo's video copy is too small after landscape framing. Choose the full-resolution Original or a landscape photo for a Listing video. Your saved photo is unchanged."
            case .photoTooLarge: return "A photo is too large for this video recipe. Choose a smaller copy; your original is unchanged."
            case .batchTooLarge: return "These photos are too large to prepare together. Choose fewer photos or smaller copies. No video clips have been submitted."
            }
        }
    }

    static func cropMeetsFloor(width: Int, height: Int, aspect: String) -> Bool {
        guard (1...2048).contains(width), (1...2048).contains(height), ["16:9", "9:16"].contains(aspect) else { return false }
        let (numerator, denominator) = aspect == "16:9" ? (16, 9) : (9, 16)
        let cropWidth = min(width, height * numerator / denominator)
        let cropHeight = min(height, width * denominator / numerator)
        return min(cropWidth - cropWidth % 2, cropHeight - cropHeight % 2) >= minimumCropEdge
    }

    static func requireUsableJPEG(_ jpeg: Data, aspect: String) throws {
        guard ["16:9", "9:16"].contains(aspect),
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let size = VideoFramingReviewPolicy.displayedSize(width: width, height: height,
                exifOrientation: properties[kCGImagePropertyOrientation] as? Int ?? 1),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil else {
            throw Failure.unreadable
        }
        guard cropMeetsFloor(width: size.0, height: size.1, aspect: aspect) else { throw Failure.smallCopy(portrait: aspect == "9:16") }
    }

    /// Freeze and check every copy before the caller can upload or buy a plan.
    /// Files bound peak memory to one JPEG; their order is the user's tap order.
    @MainActor static func stage<Photo>(_ photos: [Photo], aspect: String, directory: URL,
        maximumJPEGBytes: Int, maximumBase64Bytes: Int,
        progress: @MainActor (Int, Int) -> Void = { _, _ in },
        requireCurrent: @MainActor () throws -> Void, prepare: @MainActor (Photo) throws -> Data) async throws -> [URL] {
        var files: [URL] = [], encodedBytes = 0
        for (index, photo) in photos.enumerated() {
            try requireCurrent()
            progress(index + 1, photos.count)
            let jpeg = try prepare(photo)
            guard jpeg.count <= maximumJPEGBytes else { throw Failure.photoTooLarge }
            try requireUsableJPEG(jpeg, aspect: aspect)
            encodedBytes += ((jpeg.count + 2) / 3) * 4
            guard encodedBytes <= maximumBase64Bytes else { throw Failure.batchTooLarge }
            let file = directory.appendingPathComponent("source-\(index).jpg")
            try jpeg.write(to: file, options: .atomic)
            files.append(file)
            await Task.yield()
        }
        try requireCurrent()
        return files
    }
}

/// Reads the saved version's actual image metadata and decodes a tiny,
/// orientation-correct thumbnail. No original is rewritten or stretched.
enum VideoPhotoFramingReader {
    static func read(photoID: String, url: URL, aspect: Double) -> VideoPhotoFramingAssessment? {
        guard let size = PhotoGeometryReader.read(url: url),
              let crop = DeliveryCrop.centered(sourceWidth: Double(size.width), sourceHeight: Double(size.height), deliveryAspect: aspect) else { return nil }
        return .init(photoID: photoID, sourceURL: url, displayedWidth: size.width, displayedHeight: size.height, crop: crop)
    }
}
