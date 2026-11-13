import Foundation
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// A delivery derivative is not a replacement photo or an AI result. Its durable
/// source binding stays local; the existing gallery API receives its real bytes.
actor PhotoGalleryDerivativeStore {
    static let shared = PhotoGalleryDerivativeStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoGalleryDerivatives", isDirectory: true))
    struct Source: Codable, Equatable, Sendable {
        let identity: PhotoCloudSelectionIdentity
        let versionID: String
        let familyID: String
        let imageFile: String
        let historySHA256: String
        let sha256: String
        let bytes: Int64
        func validate() throws {
            try PhotoCloudSelectionTarget(assetID: identity.serverListingID, sha256: sha256, bytes: bytes).validate()
            guard [versionID, familyID, imageFile].allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 240 && $0 != "." && $0 != ".." &&
                $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            }), historySHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw PhotoCloudSelectionFailure.unmapped
            }
        }
    }
    struct Loaded: Sendable {
        let url: URL
        let delivery: PhotoCloudBrowserDelivery
    }
    private struct Record: Codable {
        let schema: Int
        let source: Source
        let delivery: PhotoCloudBrowserDelivery
        let sourceType: String
        let width: Int
        let height: Int
        let orientation: Int
    }
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private func refused() -> Failure {
        Failure(message: "This photo's browser copy could not be verified. Its original and current listing choice are kept.")
    }
    static func needsBrowserDelivery(_ sourceURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let kind = CGImageSourceGetType(source) as String? else { return false }
        if [UTType.heic.identifier, UTType.heif.identifier].contains(kind) { return true }
        return [UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(kind) &&
            ((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 9_500_000
    }
    private static func unchangedCaptureMetadata(_ version: PhotoVersionHistory.Version) -> Bool {
        version.id == version.familyID && version.edit == "capture" && version.originalVerified && version.sourceHistoryKnown &&
        version.imageFile == "enh-\(version.familyID).jpg" && version.originalFile == "orig-\(version.familyID).jpg" &&
        version.effects.isEmpty && version.parentID == nil && version.sourceID == nil && version.stagingBaseID == nil &&
        version.style == nil && version.stagingReferenceID == nil && version.stagingBrief == nil &&
        version.customReviewed == nil && version.stagingReviewed == nil && version.disclosure == nil &&
        version.provenanceID == nil && version.originalAssetID == nil && version.serverListingID == nil && !version.provenanceRecorded
    }
    static func verifiedCapture(_ version: PhotoVersionHistory.Version, imageURL: URL, originalURL: URL) throws -> Bool {
        if let retained = try PhotoGalleryDisclosure.retainedOriginal(version: version, imageURL: imageURL,
                sourceURL: originalURL, maxBytes: 128 * 1024 * 1024) {
            return unchangedCaptureMetadata(retained.capture)
        }
        guard unchangedCaptureMetadata(version),
              imageURL.lastPathComponent == version.imageFile,
              originalURL.lastPathComponent == version.originalFile,
              imageURL.deletingLastPathComponent().standardizedFileURL == originalURL.deletingLastPathComponent().standardizedFileURL,
              try PhotoVersionHistory.load(directory: imageURL.deletingLastPathComponent()).versions[version.id] == version else { return false }
        return try measure(imageURL) == measure(originalURL)
    }
    static func historySHA256(_ version: PhotoVersionHistory.Version, directory: URL) throws -> String {
        let history = try PhotoVersionHistory.load(directory: directory)
        guard history.versions[version.id] == version else { throw PhotoCloudSelectionFailure.changed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return DirectUploader.sha256Hex(try encoder.encode([version, history.versions[version.familyID]]))
    }
    /// Same open descriptor, regular-file and change checks also apply to HEIC.
    /// No path or filename is treated as a content identity.
    static func measure(_ url: URL) throws -> PhotoCloudDeliverySource {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw PhotoCloudSelectionFailure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 128 * 1024 * 1024 else { throw PhotoCloudSelectionFailure.changed }
        var digest = SHA256(), total: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= before.st_size else { throw PhotoCloudSelectionFailure.changed }
            digest.update(data: data)
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              total == before.st_size, current.st_mode & S_IFMT == S_IFREG,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PhotoCloudSelectionFailure.changed
        }
        return .init(sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total)
    }
    private func requireSource(_ url: URL, _ source: Source) throws {
        try source.validate()
        let history = try PhotoVersionHistory.load(directory: url.deletingLastPathComponent())
        guard let version = history.versions[source.versionID], version.familyID == source.familyID,
              version.imageFile == source.imageFile,
              try Self.historySHA256(version, directory: url.deletingLastPathComponent()) == source.historySHA256 else {
            throw PhotoCloudSelectionFailure.changed
        }
        guard try Self.measure(url) == .init(sha256: source.sha256, bytes: source.bytes) else { throw PhotoCloudSelectionFailure.changed }
    }
    private func entryURL(_ source: Source) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key, isDirectory: true)
    }
    private func requireDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw refused() }
    }
    private func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw refused() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw refused() }
    }
    /// Read-only: never regenerates a missing/corrupt derivative, uploads, or
    /// changes a selection. Its absence remains an explicit preparation step.
    func lookup(sourceURL: URL, source: Source) throws -> Loaded? {
        try source.validate()
        let entry = try entryURL(source)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try requireDirectory(directory)
        let exists = FileManager.default.fileExists(atPath: entry.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) != nil
        guard exists else { return nil }
        try requireSource(sourceURL, source)
        try requireDirectory(entry)
        let metadata = entry.appendingPathComponent("binding.json")
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attrs = try FileManager.default.attributesOfItem(atPath: metadata.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 8192,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw refused() }
        let data = try Data(contentsOf: metadata)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard data.count == size, record.schema == 1, record.source == source,
              record.width > 0, record.height > 0, (1...8).contains(record.orientation),
              [UTType.heic.identifier, UTType.heif.identifier, UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(record.sourceType) else { throw refused() }
        let file = entry.appendingPathComponent("browser.jpg")
        let actual = try DirectUploader.browserPhoto(file)
        guard actual.contentType == "image/jpeg", actual.sha256 == record.delivery.sha256,
              actual.bytes == record.delivery.bytes, actual.bytes <= 9_500_000 else { throw refused() }
        try requireSource(sourceURL, source)
        return .init(url: file, delivery: record.delivery)
    }
    /// The caller certifies a current verified capture, not merely an edit name.
    /// A saved copy is reused byte-for-byte even if encoder behavior changes later.
    func prepare(sourceURL: URL, source: Source, physicalOrgID: UUID,
                 version: PhotoVersionHistory.Version, originalURL: URL) throws -> Loaded {
        guard source.versionID == version.id, source.familyID == version.familyID, source.imageFile == version.imageFile,
              source.historySHA256 == (try Self.historySHA256(version, directory: sourceURL.deletingLastPathComponent())),
              try Self.verifiedCapture(version, imageURL: sourceURL, originalURL: originalURL) else { throw refused() }
        if let existing = try lookup(sourceURL: sourceURL, source: source) {
            guard existing.delivery.physicalOrgID == physicalOrgID else { throw PhotoCloudSelectionFailure.identityChanged }
            return existing
        }
        try requireSource(sourceURL, source)
        guard let image = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let kind = CGImageSourceGetType(image) as String?,
              [UTType.heic.identifier, UTType.heif.identifier, UTType.jpeg.identifier, UTType.png.identifier, UTType.webP.identifier].contains(kind) else { throw refused() }
        let prepared = try PhotoBrowserOriginal.prepareGallery(sourceURL)
        defer { prepared.removeTemporaryFiles() }
        try requireSource(sourceURL, source)
        guard try Self.verifiedCapture(version, imageURL: sourceURL, originalURL: originalURL) else { throw refused() }
        let actual = try DirectUploader.browserPhoto(prepared.url)
        guard prepared.convertedToJPEG, actual.contentType == "image/jpeg" else { throw refused() }
        guard actual.bytes <= 9_500_000 else {
            throw Failure(message: "The website copy is too large to upload. The full-size original and current listing choice are kept.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(directory)
        var excluded = directory; var backup = URLResourceValues(); backup.isExcludedFromBackup = true
        try excluded.setResourceValues(backup)
        let staging = directory.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("browser.jpg")
        try FileManager.default.copyItem(at: prepared.url, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard try DirectUploader.browserPhoto(file) == actual else { throw refused() }
        let delivery = PhotoCloudBrowserDelivery(sha256: actual.sha256, bytes: actual.bytes, physicalOrgID: physicalOrgID)
        let record = Record(schema: 1, source: source, delivery: delivery, sourceType: prepared.sourceType,
                            width: prepared.pixelWidth, height: prepared.pixelHeight, orientation: prepared.orientation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let metadata = staging.appendingPathComponent("binding.json")
        try encoder.encode(record).write(to: metadata, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        try sync(file); try sync(metadata); try sync(staging)
        try requireSource(sourceURL, source); try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: entryURL(source))
        try sync(directory)
        guard let saved = try lookup(sourceURL: sourceURL, source: source) else { throw refused() }
        return saved
    }
}
