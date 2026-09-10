import Foundation

struct CaptureArchiveEntry {
    let id: String
    let createdAt: Date?
    let frameCount: Int?
    let status: String
    let issue: String?
}

struct CaptureArchivePage {
    let entries: [CaptureArchiveEntry]
    let hasMore: Bool
}

// Only this app's Captures directory is used. A page retains at most 50 small
// summaries, never all manifests/images or an unbounded list of capture folders.
struct CaptureArchive {
    static let pageSize = 50
    static let maximumManifestBytes = NativeRasterWriter.maximumManifestBytes
    let root: URL

    static func local() throws -> CaptureArchive {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return CaptureArchive(root: documents.appendingPathComponent("Captures", isDirectory: true))
    }

    @discardableResult
    func prepareRoot(createIfMissing: Bool) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let properties: URLResourceValues
        do { properties = try root.resourceValues(forKeys: keys) }
        catch {
            let failure = error as NSError
            let missing = failure.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
            guard missing else { throw error } // Permission/I/O errors are not an empty archive.
            guard createIfMissing else { return false }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return try prepareRoot(createIfMissing: false)
        }
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw CaptureError.invalid("Capture storage is not a local directory. Files were not changed.")
        }
        // Room photos must not silently enter iCloud/device backups. Apply this
        // to the parent before writing any attempt, including pre-existing data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedRoot = root
        try protectedRoot.setResourceValues(values)
        protectedRoot.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        guard try protectedRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw CaptureError.invalid("Could not exclude capture storage from backups. Capture was not started.")
        }
        return true
    }

    func captureURL(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains("\\") else {
            throw CaptureError.invalid("Invalid saved capture identifier.")
        }
        let url = root.appendingPathComponent(id, isDirectory: true)
        let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw CaptureError.invalid("Saved capture is not a local capture directory.")
        }
        return url
    }

    func manifest(id: String) throws -> CaptureManifest {
        let url = try captureURL(id: id).appendingPathComponent("manifest.json")
        let bytes = try NativeRasterWriter.boundedJSONData(at: url, maximumBytes: Self.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(CaptureManifest.self, from: bytes)
        guard manifest.format == "rendprop-arkit-capture", manifest.schema_version == 1,
              manifest.session_id.caseInsensitiveCompare(id) == .orderedSame,
              manifest.frames.count <= 400,
              ["recording", "complete", "interrupted", "failed", "limit_reached"].contains(manifest.status),
              ISO8601DateFormatter().date(from: manifest.started_at) != nil else {
            throw CaptureError.invalid("Saved manifest has an invalid capture identity, status, or schema.")
        }
        return manifest
    }

    func page(offset: Int) throws -> CaptureArchivePage {
        guard offset >= 0 else { throw CaptureError.invalid("Invalid saved-capture page.") }
        guard try prepareRoot(createIfMissing: false) else { return CaptureArchivePage(entries: [], hasMore: false) }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CaptureError.invalid("Saved captures could not be listed. Files are preserved.")
        }
        var encountered = 0
        var entries: [CaptureArchiveEntry] = []
        var hasMore = false
        while let url = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if encountered < offset { encountered += 1; continue }
            if entries.count == Self.pageSize { hasMore = true; break }
            do {
                let manifest = try manifest(id: id)
                entries.append(CaptureArchiveEntry(id: id, createdAt: ISO8601DateFormatter().date(from: manifest.started_at),
                    frameCount: manifest.frames.count, status: manifest.status, issue: nil))
            } catch {
                // A corrupt/incomplete attempt remains visible; it is not hidden
                // or reclassified as a completed room. Do not display user paths.
                entries.append(CaptureArchiveEntry(id: id, createdAt: nil, frameCount: nil,
                    status: "unreadable", issue: "Manifest missing or invalid; files preserved."))
            }
        }
        if let enumerationError { throw enumerationError }
        return CaptureArchivePage(entries: entries, hasMore: hasMore)
    }

    func validateForExport(id: String) throws -> URL {
        guard try prepareRoot(createIfMissing: false) else { throw CaptureError.invalid("Saved capture storage is missing.") }
        _ = try manifest(id: id) // Re-read identity/status from bounded on-disk bytes.
        let url = try captureURL(id: id)
        _ = try NativeRasterWriter.validateCapture(at: url) // Every JPEG/sidecar, on every export.
        return url
    }
}
