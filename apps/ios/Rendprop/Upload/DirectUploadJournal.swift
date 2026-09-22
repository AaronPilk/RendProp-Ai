import Foundation

/// Small, protected per-photo receipts. File bytes remain at their original
/// URL; this journal is deliberately not a media cache or deletion queue.
actor DirectUploadJournal {
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
