import Foundation
import CryptoKit

struct PhotoGalleryAsset: Codable, Equatable, Sendable {
    let assetID: UUID
    let sha256: String
    let bytes: Int64
}

struct PhotoGallerySelection: Codable, Equatable, Sendable {
    let listingID: UUID
    let orgID: UUID
    let libraryOrgID: UUID
    let galleryAssetIDs: [UUID]?
    let mainPhotoKey: String?
    let galleryAssets: [PhotoGalleryAsset]

    init(listingID: UUID, orgID: UUID, libraryOrgID: UUID, galleryAssetIDs: [UUID]?,
         mainPhotoKey: String?, galleryAssets: [PhotoGalleryAsset] = []) {
        self.listingID = listingID; self.orgID = orgID; self.libraryOrgID = libraryOrgID
        self.galleryAssetIDs = galleryAssetIDs; self.mainPhotoKey = mainPhotoKey
        self.galleryAssets = galleryAssets
    }
}

struct PhotoGalleryRemovalOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let actorID: UUID
    let libraryOrgID: UUID
    let localListingID: UUID
    let serverListingID: UUID
    let familyID: String
    let selectedVersionID: String
    let requestedAssetIDs: [UUID]
    let expectedGalleryAssetIDs: [UUID]?
    let expectedMainPhotoKey: String?

    var scope: PhotoListingRemovalJournal.Scope {
        .init(actorID: actorID, libraryOrgID: libraryOrgID, localListingID: localListingID,
              serverListingID: serverListingID, familyID: familyID)
    }

    fileprivate func hasSameIntent(as other: Self) -> Bool {
        scope == other.scope && selectedVersionID == other.selectedVersionID
            && requestedAssetIDs == other.requestedAssetIDs
            && expectedGalleryAssetIDs == other.expectedGalleryAssetIDs
            && expectedMainPhotoKey == other.expectedMainPhotoKey
    }
}

struct PhotoGalleryRemovalReply: Codable, Equatable, Sendable {
    let selection: PhotoGallerySelection
    let operationID: UUID
    let replayed: Bool
    let requestedAssetIDs: [UUID]
    let removedAssetIDs: [UUID]
}

protocol ListingGalleryRemovalAPI: Sendable {
    @MainActor func gallerySelection(serverID: UUID, libraryOrgID: UUID) async throws -> PhotoGallerySelection
    @MainActor func removeGalleryAssets(_ operation: PhotoGalleryRemovalOperation) async throws -> PhotoGalleryRemovalReply
}

/// The exact compare-and-set request survives a lost reply. The API/UI owns
/// current-session authority; this journal contains no credentials or URLs.
final class PhotoListingRemovalJournal: @unchecked Sendable {
    struct Scope: Codable, Equatable, Sendable {
        let actorID: UUID
        let libraryOrgID: UUID
        let localListingID: UUID
        let serverListingID: UUID
        let familyID: String
    }
    enum Failure: Error, LocalizedError {
        case invalidOperation, unreadable, pendingOperation, mismatchedOperation
        var errorDescription: String? {
            switch self {
            case .invalidOperation: return "This photo removal could not be verified. Your saved photos have been kept."
            case .unreadable: return "The saved photo removal could not be read safely. Your saved photos have been kept."
            case .pendingOperation: return "An earlier removal for this photo still needs its saved result checked."
            case .mismatchedOperation: return "This reply does not match the saved photo removal. The pending request has been kept."
            }
        }
    }
    private struct Entry: Codable {
        let schema: Int
        let scope: Scope
        let operation: PhotoGalleryRemovalOperation
    }
    // Separate instances in the same app must not replace each other's intent.
    private static let lock = NSLock()
    private let directory: URL
    private let maximumJournalBytes = 32 * 1024

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.appendingPathComponent(".photo-listing-removals", isDirectory: true)
    }

    func load(scope: Scope) throws -> PhotoGalleryRemovalOperation? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadUnlocked(scope: scope)
    }

    /// Persist before PATCH. A new proposed UUID for the same intent recovers
    /// the old exact operation; changed intent cannot overwrite an unknown one.
    func begin(_ proposed: PhotoGalleryRemovalOperation) throws -> PhotoGalleryRemovalOperation {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try Self.validate(proposed)
        if let saved = try loadUnlocked(scope: proposed.scope) {
            guard saved.hasSameIntent(as: proposed) else { throw Failure.pendingOperation }
            return saved
        }
        try requireDirectory(create: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Entry(schema: 1, scope: proposed.scope, operation: proposed))
        guard bytes.count <= maximumJournalBytes else { throw Failure.invalidOperation }
        let target = try journalURL(scope: proposed.scope)
        let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString).tmp")
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: temporary.path, contents: bytes, attributes: attributes) else {
            throw Failure.unreadable
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        // Same-directory rename exposes only the complete, permissioned entry.
        // moveItem refuses an existing destination instead of overwriting it.
        try FileManager.default.moveItem(at: temporary, to: target)
        return proposed
    }

    /// Only an exact confirmed operation may be retired. A failed/lost PATCH
    /// does not call this method, preserving its original snapshot and UUID.
    func finish(_ operation: PhotoGalleryRemovalOperation) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try Self.validate(operation)
        guard let saved = try loadUnlocked(scope: operation.scope) else { return }
        guard saved == operation else { throw Failure.mismatchedOperation }
        try FileManager.default.removeItem(at: journalURL(scope: operation.scope))
    }

    private func journalURL(scope: Scope) throws -> URL {
        guard Self.identifier(scope.familyID) else { throw Failure.invalidOperation }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private func requireDirectory(create: Bool) throws {
        guard directory.isFileURL else { throw Failure.unreadable }
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard create else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unreadable }
        if create { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    private func loadUnlocked(scope: Scope) throws -> PhotoGalleryRemovalOperation? {
        let url = try journalURL(scope: scope)
        try requireDirectory(create: false)
        let exists = FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard exists else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue == 0o600,
              let size = values.fileSize, size > 0, size <= maximumJournalBytes else { throw Failure.unreadable }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size, bytes.count <= maximumJournalBytes,
              let entry = try? JSONDecoder().decode(Entry.self, from: bytes),
              entry.schema == 1, entry.scope == scope, entry.operation.scope == scope else { throw Failure.unreadable }
        try Self.validate(entry.operation)
        return entry.operation
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 240
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
            && value != "." && value != ".."
    }
    private static func validate(_ operation: PhotoGalleryRemovalOperation) throws {
        let requested = operation.requestedAssetIDs
        guard identifier(operation.familyID), identifier(operation.selectedVersionID),
              (1...100).contains(requested.count), Set(requested).count == requested.count else { throw Failure.invalidOperation }
        if let expected = operation.expectedGalleryAssetIDs {
            guard expected.count <= 100, Set(expected).count == expected.count else { throw Failure.invalidOperation }
        }
        if let key = operation.expectedMainPhotoKey {
            guard !key.isEmpty, key.utf8.count <= 500, !key.hasPrefix("/"),
                  !key.contains("://"), !key.contains("?"), !key.contains("#"), !key.contains("\\"),
                  !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
            else { throw Failure.invalidOperation }
        }
    }
}
