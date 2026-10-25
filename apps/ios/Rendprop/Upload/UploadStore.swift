import Foundation

/// Persists upload state to disk so uploads resume across app launches,
/// network loss, and reboots (master spec 4.4). The record is device-local
/// (excluded from backup): a restore onto another phone has no source video
/// or background session to resume, so carrying the record over would only
/// surface a phantom "failed upload".
enum UploadStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("upload-state.json")
    }

    @discardableResult
    static func save(_ state: UploadManager.State?) -> Bool {
        guard let state else {
            try? FileManager.default.removeItem(at: fileURL)
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
        guard let data = try? JSONEncoder().encode(state) else { return false }
        var url = fileURL
        do {
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            // Disk-full or sandbox hiccup: the in-memory state still drives the
            // engine; callers must not dispatch bytes/cancel tickets without a
            // durable identity. The next explicit resume may retry the write.
            return false
        }
    }

    static func load() -> UploadManager.State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(UploadManager.State.self, from: data)
    }
}
