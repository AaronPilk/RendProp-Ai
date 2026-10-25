import Foundation

/// A take is durable before its pieces are joined. Paths are relative to
/// Documents so a container relocation does not strand the original footage.
struct RecoverableTake: Identifiable, Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var piecePaths: [String]
    var sidecarPath: String?
    var joinedPath: String?
    var tags: [RoomTag]
    var people: [TimeRange]
    var seconds: Double
    var fps: Double
    var width: Int
    var height: Int

    var pieces: [URL] { piecePaths.compactMap(TakeRecoveryStore.mediaURL) }
    var sidecar: URL? { sidecarPath.flatMap(TakeRecoveryStore.mediaURL) }
    var joined: URL? { joinedPath.flatMap(TakeRecoveryStore.mediaURL) }
}

enum TakeRecoveryStore {
    enum RecoveryError: LocalizedError {
        case invalidRecord
        var errorDescription: String? { "This saved take has invalid recovery information. Its original files have been kept." }
    }

    private static var directory: URL { FileStore.documents.appendingPathComponent("TakeRecovery", isDirectory: true) }

    /// All paths must remain in the capture folder. No absolute paths, parent
    /// traversal or symlinks into another folder are followed from a journal.
    static func mediaURL(_ path: String) -> URL? {
        guard path.hasPrefix("Recordings/"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else { return nil }
        let url = FileStore.documents.appendingPathComponent(path).standardizedFileURL
        let base = FileStore.recordingsDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else { return nil }
        return url
    }

    private static func validate(_ take: RecoverableTake) throws {
        guard !take.piecePaths.isEmpty, take.piecePaths.count <= 12_000,
              Set(take.piecePaths).count == take.piecePaths.count,
              take.piecePaths.allSatisfy({ mediaURL($0) != nil }),
              take.sidecarPath.map({ mediaURL($0) != nil }) ?? true,
              take.joinedPath.map({ mediaURL($0) != nil && !take.piecePaths.contains($0) }) ?? true,
              take.seconds.isFinite, take.seconds >= 0,
              take.fps.isFinite, take.fps > 0, take.width > 0, take.height > 0,
              take.people.allSatisfy({ $0.startS.isFinite && $0.endS.isFinite && $0.startS >= 0 && $0.endS >= $0.startS && $0.endS <= take.seconds + 0.001 })
        else { throw RecoveryError.invalidRecord }
    }

    /// A failed write never replaces a good journal or removes any footage.
    static func save(_ take: RecoverableTake) throws {
        try validate(take)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(take)
        try data.write(to: directory.appendingPathComponent("\(take.id.uuidString).json"), options: .atomic)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    struct Library {
        var takes: [RecoverableTake]
        var unreadableCount: Int
        var otherRecordings: [OtherRecording] = []
    }

    struct OtherRecording: Identifiable {
        var id: URL { url }
        let url: URL
        let createdAt: Date?
        let bytes: Int
    }

    /// Old builds left paused parts without a journal. Expose the actual files
    /// for manual export; timestamps cannot prove which parts form one take.
    private static func otherRecordings(excluding takes: [RecoverableTake]) -> [OtherRecording] {
        let referenced = Set(takes.flatMap { $0.piecePaths + [$0.joinedPath].compactMap { $0 } })
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: FileStore.recordingsDir,
                                             includingPropertiesForKeys: Array(keys)) else { return [] }
        return urls.compactMap { url -> OtherRecording? in
            guard url.lastPathComponent.hasPrefix("walkthrough-"), url.pathExtension.lowercased() == "mov",
                  !referenced.contains("Recordings/" + url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return OtherRecording(url: url, createdAt: values.creationDate, bytes: values.fileSize ?? 0)
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func load() -> Library {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            return Library(takes: [], unreadableCount: 0, otherRecordings: otherRecordings(excluding: []))
        }
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return Library(takes: [], unreadableCount: 1, otherRecordings: otherRecordings(excluding: []))
        }
        var takes: [RecoverableTake] = []
        var unreadable = 0
        for url in urls where url.pathExtension == "json" {
            do {
                let take = try JSONDecoder().decode(RecoverableTake.self, from: Data(contentsOf: url))
                try validate(take)
                guard url.deletingPathExtension().lastPathComponent == take.id.uuidString else { throw RecoveryError.invalidRecord }
                takes.append(take)
            } catch {
                // Never discard a damaged journal: it may be the only ordered
                // record linking footage to its tags and timing.
                unreadable += 1
            }
        }
        return Library(takes: takes.sorted { $0.createdAt > $1.createdAt }, unreadableCount: unreadable,
                       otherRecordings: otherRecordings(excluding: takes))
    }

    /// Only the explicit discard of the currently recording take uses this.
    /// Source files are owned by CameraManager's confirmed discard operation.
    static func forgetDiscarded(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }
}
