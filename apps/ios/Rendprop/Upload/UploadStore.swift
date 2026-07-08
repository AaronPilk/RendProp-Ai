import Foundation

/// Persists upload state to disk so uploads resume across app launches,
/// network loss, and reboots (master spec 4.4).
enum UploadStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("upload-state.json")
    }

    static func save(_ state: UploadManager.State?) {
        guard let state else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func load() -> UploadManager.State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(UploadManager.State.self, from: data)
    }
}
