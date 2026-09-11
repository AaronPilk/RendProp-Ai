import Foundation

/// Small, protected per-photo receipts. File bytes remain at their original
/// URL; this journal is deliberately not a media cache or deletion queue.
actor DirectUploadJournal {
    struct PendingPhoto: Identifiable, Sendable {
        let id: String
        let source: UploadRecovery.PhotoSource
        let message: String
        let needsRestart: Bool
        let restartGeneration: Int?
    }
    static let shared = DirectUploadJournal(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DirectUploadReceipts", isDirectory: true))
    private let directory: URL
    private var active = Set<String>()
    init(directory: URL) { self.directory = directory }

    func acquire(_ key: String) throws {
        guard active.insert(key).inserted else { throw UploadRecovery.Failure.changedTicket }
    }
    func release(_ key: String) { active.remove(key) }
    func pendingPhotos(ownerID: String) throws -> [PendingPhoto] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard files.count <= 10_000 else { throw UploadRecovery.Failure.invalidTicket }
        var result: [PendingPhoto] = []
        for file in files where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let size = values.fileSize, size <= 65_536 else { throw UploadRecovery.Failure.invalidTicket }
            let record = try JSONDecoder().decode(UploadRecovery.Journal.self, from: Data(contentsOf: file))
            guard !record.completed, let source = record.source, source.ownerID == ownerID,
                  let message = record.failureMessage else { continue }
            result.append(.init(id: file.deletingPathExtension().lastPathComponent, source: source,
                message: message, needsRestart: record.needsRestart == true || record.restartIntent != nil,
                restartGeneration: record.ticket?.restartGeneration))
        }
        return result.sorted { $0.id < $1.id }
    }
    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(DirectUploader.sha256Hex(key) + ".json")
    }
    func load(_ key: String) throws -> UploadRecovery.Journal? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let count = values.fileSize, count <= 65_536 else {
            throw UploadRecovery.Failure.invalidTicket
        }
        return try JSONDecoder().decode(UploadRecovery.Journal.self, from: Data(contentsOf: url))
    }
    func save(_ record: UploadRecovery.Journal, for key: String) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw UploadRecovery.Failure.invalidTicket }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
    }
}
