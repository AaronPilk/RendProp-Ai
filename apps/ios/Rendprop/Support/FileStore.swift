import Foundation

/// App-container paths + free-space checks.
enum FileStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var recordingsDir: URL { subdir("Recordings") }
    static var importsDir: URL { subdir("Imports") }

    private static func subdir(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newRecordingURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return recordingsDir.appendingPathComponent("walkthrough-\(stamp).mov")
    }

    /// Path of `url` relative to Documents (e.g. "Recordings/tour-ab12.mp4").
    /// Persist THIS, never the absolute path — iOS can change the container base
    /// between launches/reinstalls. Falls back to the last path component.
    static func relativePath(for url: URL) -> String {
        let base = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base) {
            let trimmed = String(path.dropFirst(base.count)).drop(while: { $0 == "/" })
            return String(trimmed)
        }
        return url.lastPathComponent
    }

    /// Rebuild an absolute URL from a Documents-relative path.
    static func url(fromRelativePath rel: String) -> URL {
        documents.appendingPathComponent(rel)
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
    }

    /// Free space available for "important" usage (what recording needs).
    static func freeSpaceBytes() -> Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// 4K/60 ≈ ~400 MB/min. Pre-flight: is there room for `minutes` of capture?
    static func hasSpace(forMinutes minutes: Double) -> Bool {
        freeSpaceBytes() > Int64(minutes * 400_000_000) + 500_000_000 // + headroom
    }
}
