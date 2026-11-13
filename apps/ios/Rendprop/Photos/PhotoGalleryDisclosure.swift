import Foundation
import CryptoKit

/// A retained capture is not an AI output. Certify that exact local source
/// without treating an edit label alone as permission to omit its disclosure.
enum PhotoGalleryDisclosure {
    struct RetainedOriginal: Equatable {
        let version: PhotoVersionHistory.Version
        let capture: PhotoVersionHistory.Version
        let sha256: String
        let bytes: Int64
    }
    enum Failure: Error, LocalizedError {
        case changedOriginal
        var errorDescription: String? {
            "The retained original changed while its listing photo was uploading. Your published selection has been kept. Open Photos and retry."
        }
    }

    static func retainedOriginal(version: PhotoVersionHistory.Version, imageURL: URL,
                                 sourceURL: URL, maxBytes: Int64) throws -> RetainedOriginal? {
        guard version.edit == "capture-original" else { return nil }
        let file = "orig-\(version.familyID).jpg"
        guard version.id == version.familyID + "-original",
              version.originalVerified, version.sourceHistoryKnown,
              version.effects.isEmpty, version.parentID == nil, version.sourceID == nil,
              version.stagingBaseID == nil, version.style == nil,
              version.stagingReferenceID == nil, version.stagingBrief == nil,
              version.customReviewed == nil,
              version.imageFile == file, version.originalFile == file else { return nil }
        let directory = imageURL.deletingLastPathComponent().standardizedFileURL
        let expected = directory.appendingPathComponent(file).standardizedFileURL
        guard imageURL.standardizedFileURL == expected,
              sourceURL.standardizedFileURL == expected else { return nil }
        let index = try PhotoVersionHistory.load(directory: directory)
        guard index.versions[version.id] == version,
              let capture = index.versions[version.familyID],
              capture.id == version.familyID, capture.familyID == version.familyID,
              capture.edit == "capture", capture.originalVerified, capture.sourceHistoryKnown,
              capture.effects.isEmpty, capture.parentID == nil, capture.sourceID == nil,
              capture.stagingBaseID == nil, capture.originalFile == file,
              capture.imageFile == "enh-\(version.familyID).jpg",
              capture.createdAt == version.createdAt else { return nil }
        let values = try expected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= maxBytes else { return nil }
        let handle = try FileHandle(forReadingFrom: expected)
        defer { try? handle.close() }
        var hash = SHA256(), total: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            total += Int64(chunk.count)
            guard total <= maxBytes else { throw Failure.changedOriginal }
            hash.update(data: chunk)
        }
        guard total == Int64(size) else { throw Failure.changedOriginal }
        return RetainedOriginal(version: version, capture: capture,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total)
    }

    static func requireUnchanged(_ original: RetainedOriginal, imageURL: URL,
                                 sourceURL: URL, maxBytes: Int64) throws {
        guard try retainedOriginal(version: original.version, imageURL: imageURL,
                                   sourceURL: sourceURL, maxBytes: maxBytes) == original else {
            throw Failure.changedOriginal
        }
    }
}
