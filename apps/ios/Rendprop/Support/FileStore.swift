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
