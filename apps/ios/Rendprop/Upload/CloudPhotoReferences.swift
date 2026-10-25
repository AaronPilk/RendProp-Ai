import Foundation

/// Genuine server photo identities, bound to exact file bytes and their account.
/// This actor hashes off the main actor. It never uploads or resolves by filename.
actor CloudPhotoReferences {
    static let shared = CloudPhotoReferences(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudPhotoReferences", isDirectory: true))
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private struct Fingerprint: Codable, Equatable {
        let ownerID: UUID
        let orgID: UUID
        let listingID: UUID
        let sha256: String
        let bytes: Int64
        var key: String { DirectUploader.sha256Hex("\(ownerID)|\(orgID)|\(listingID)|\(sha256)|\(bytes)") }
    }
    private struct Reference: Codable {
        let fingerprint: Fingerprint
        let sourceID: UUID
    }
    private struct GalleryReference: Codable {
        let fingerprint: Fingerprint
        let assetID: UUID
    }
    private func galleryTicketMatches(_ ticket: UploadTicket, orgID: UUID, listingID: UUID) -> Bool {
        let prefix = "renders/\(orgID.uuidString.lowercased())/\(listingID.uuidString.lowercased())/gallery-"
        guard ticket.mode == .single, let key = ticket.storageKey, key.hasPrefix(prefix) else { return false }
        let suffix = String(key.dropFirst(prefix.count))
        return !suffix.isEmpty && key.utf8.count <= 500
            && !suffix.contains("/") && !suffix.contains("\\") && !suffix.contains("%")
            && !suffix.contains("?") && !suffix.contains("#")
            && !suffix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private func fingerprint(fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID) throws -> Fingerprint {
        try Task.checkCancellation()
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0, bytes <= 128 * 1024 * 1024, let digest = DirectUploader.sha256(of: fileURL),
              FileStore.fileSize(fileURL) == bytes else { throw UploadRecovery.Failure.invalidTicket }
        try Task.checkCancellation()
        return Fingerprint(ownerID: ownerID, orgID: orgID, listingID: listingID, sha256: digest, bytes: bytes)
    }

    /// Called only with the ID from a scoped cloud-media response after importing
    /// its exact enhanced file. No local filename is accepted as proof of identity.
    func save(sourceID: UUID, fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID) throws {
        let fingerprint = try fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID)
        let record = Reference(fingerprint: fingerprint, sourceID: sourceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let file = directory.appendingPathComponent(fingerprint.key + ".json")
        try JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A separate receipt for a confirmed gallery upload or exact byte match
    /// against the server's scoped gallery selection. A photos-table/source ID
    /// is not necessarily a capture_assets gallery ID and is never reused here.
    func saveGalleryAssetID(assetID: UUID, fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID,
                            expectedSHA256: String? = nil, expectedBytes: Int64? = nil,
                            physicalOrgID: UUID? = nil,
                            journalStore: DirectUploadJournal = .shared) async throws {
        let fingerprint = try fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID)
        if let expectedSHA256, let expectedBytes {
            guard fingerprint.sha256 == expectedSHA256, fingerprint.bytes == expectedBytes else {
                throw UploadRecovery.Failure.invalidTicket
            }
        } else {
            guard expectedSHA256 == nil, expectedBytes == nil else { throw UploadRecovery.Failure.invalidTicket }
            let key = DirectUploader.photoJournalKey(owner: ownerID.uuidString.lowercased(), listingID: listingID,
                role: "gallery", keyPrefix: "gallery", digest: fingerprint.sha256, bytes: fingerprint.bytes)
            // Older upload journals may have been cleaned. Absence is not
            // proof of an ID and must not poison this separate identity cache.
            guard let record = try await journalStore.load(key) else { return }
            guard record.completed, let ticket = record.ticket,
                  galleryTicketMatches(ticket, orgID: physicalOrgID ?? orgID, listingID: listingID),
                  UUID(uuidString: ticket.assetID) == assetID,
                  try self.fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID) == fingerprint
            else { throw UploadRecovery.Failure.invalidTicket }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let file = directory.appendingPathComponent(fingerprint.key + ".gallery.json")
        try JSONEncoder().encode(GalleryReference(fingerprint: fingerprint, assetID: assetID))
            .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func galleryAssetID(fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID,
                        physicalOrgID: UUID? = nil,
                        journalStore: DirectUploadJournal = .shared) async throws -> UUID? {
        let fingerprint = try fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID)
        let file = directory.appendingPathComponent(fingerprint.key + ".gallery.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= 4096 else { throw UploadRecovery.Failure.invalidTicket }
            let record = try JSONDecoder().decode(GalleryReference.self, from: Data(contentsOf: file))
            guard record.fingerprint == fingerprint else { throw UploadRecovery.Failure.invalidTicket }
            return record.assetID
        }
        let key = DirectUploader.photoJournalKey(owner: ownerID.uuidString.lowercased(), listingID: listingID,
            role: "gallery", keyPrefix: "gallery", digest: fingerprint.sha256, bytes: fingerprint.bytes)
        guard let record = try await journalStore.load(key), record.completed, let ticket = record.ticket,
              galleryTicketMatches(ticket, orgID: physicalOrgID ?? orgID, listingID: listingID),
              let assetID = UUID(uuidString: ticket.assetID),
              try self.fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID) == fingerprint
        else { return nil }
        return assetID
    }

    /// A completed DirectUploader journal already retains the real capture_assets
    /// ID using owner + listing + role + SHA-256 + bytes. Reuse that receipt across
    /// relaunches; no mutation, guessed media association, or duplicate reservation.
    func sourceID(fileURL: URL, ownerID: UUID, orgID: UUID, listingID: UUID,
                  journalStore: DirectUploadJournal = .shared) async throws -> UUID? {
        let fingerprint = try fingerprint(fileURL: fileURL, ownerID: ownerID, orgID: orgID, listingID: listingID)
        let file = directory.appendingPathComponent(fingerprint.key + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= 4096 else { throw UploadRecovery.Failure.invalidTicket }
            let record = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: file))
            guard record.fingerprint == fingerprint else { throw UploadRecovery.Failure.invalidTicket }
            return record.sourceID
        }
        for (prefix, role) in [("gallery", "gallery"), ("altered", "render"), ("photo", "capture"), ("original", "original")] {
            try Task.checkCancellation()
            let key = DirectUploader.photoJournalKey(owner: ownerID.uuidString.lowercased(), listingID: listingID,
                role: role, keyPrefix: prefix, digest: fingerprint.sha256, bytes: fingerprint.bytes)
            guard let record = try await journalStore.load(key), record.completed, let ticket = record.ticket,
                  ticket.mode == .single, let assetID = UUID(uuidString: ticket.assetID) else { continue }
            return assetID
        }
        return nil
    }
}
