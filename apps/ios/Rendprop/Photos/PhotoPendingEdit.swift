import Foundation
import CryptoKit
import Darwin

/// A lost answer or a held quality check retains the exact paid operation.
/// Explicit recovery reads only the saved operation; it never dispatches an edit.
enum PhotoPendingEdit {
    struct Identity: Codable, Equatable {
        let actor: String
        let library: UUID
        let listing: UUID
        let sourceVersion: String
    }
    struct Entry: Codable {
        let schema: Int
        let identity: Identity
        let fingerprint: String
        let request: AIPhotoEditRequest
        var parentVersion: String? = nil
        var stagingReferenceID: String? = nil
    }
    struct Saved: Identifiable {
        let request: AIPhotoEditRequest
        let url: URL
        let identity: Identity
        var parentVersion: String? = nil
        var stagingReferenceID: String? = nil
        var id: String { url.lastPathComponent }
        var outputID: String { "saved-" + request.idempotencyKey!.lowercased() }
    }
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            "A saved photo request could not be verified. Your original is safe. Contact support before starting another paid edit."
        }
    }
    private static func fingerprint(_ request: AIPhotoEditRequest, identity: Identity,
                                    parentVersion: String? = nil, stagingReferenceID: String? = nil) throws -> String {
        var intent = request
        intent.idempotencyKey = nil
        // Upload receipt and display label can be refreshed while recovering.
        // The dispatched body itself is always the exact saved request below.
        intent.originalAssetID = nil
        intent.label = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(identity)
        bytes.append(try encoder.encode(intent))
        if parentVersion != nil || stagingReferenceID != nil {
            bytes.append(try encoder.encode(["parent": parentVersion ?? "", "reference": stagingReferenceID ?? ""]))
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func begin(_ proposed: AIPhotoEditRequest, identity: Identity, directory: URL,
                      parentVersion: String? = nil, stagingReferenceID: String? = nil) throws -> Saved {
        let digest = try fingerprint(proposed, identity: identity, parentVersion: parentVersion, stagingReferenceID: stagingReferenceID)
        let folder = directory.appendingPathComponent(".pending-photo-edits", isDirectory: true)
        let url = folder.appendingPathComponent(digest + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try read(url, directory: directory, expected: identity)
        }
        var request = proposed; request.idempotencyKey = UUID().uuidString
        let data = try JSONEncoder().encode(Entry(schema: 1, identity: identity, fingerprint: digest, request: request,
            parentVersion: parentVersion, stagingReferenceID: stagingReferenceID))
        guard data.count <= 24 * 1024 * 1024 else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return Saved(request: request, url: url, identity: identity, parentVersion: parentVersion,
                     stagingReferenceID: stagingReferenceID)
    }
    /// No request is reconstructed here. Even a journal written before dispatch
    /// is safe to check: a missing server operation is a read-only 404.
    static func read(_ url: URL, directory: URL, expected: Identity) throws -> Saved {
        let folder = directory.appendingPathComponent(".pending-photo-edits", isDirectory: true)
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              let folderValues = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              let data = try? boundedBytes(url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.schema == 1, entry.identity == expected,
              entry.fingerprint + ".json" == url.lastPathComponent,
              try fingerprint(entry.request, identity: expected, parentVersion: entry.parentVersion, stagingReferenceID: entry.stagingReferenceID) == entry.fingerprint,
              entry.request.idempotencyKey.flatMap(UUID.init(uuidString:)) != nil else { throw Failure.unavailable }
        return Saved(request: entry.request, url: url, identity: entry.identity,
                     parentVersion: entry.parentVersion, stagingReferenceID: entry.stagingReferenceID)
    }
    static func saved(actor: String, library: UUID, listing: UUID, directory: URL) throws -> [Saved] {
        let folder = directory.appendingPathComponent(".pending-photo-edits", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unavailable }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard files.count <= 100 else { throw Failure.unavailable }
        var found: [Saved] = []
        var aggregateBytes = 0
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == "json",
                  let bytes = try? boundedBytes(url, maxBytes: min(24 * 1024 * 1024, 64 * 1024 * 1024 - aggregateBytes)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: bytes) else { throw Failure.unavailable }
            aggregateBytes += bytes.count
            // Other accounts/libraries are never displayed or requested.
            guard entry.identity.actor == actor, entry.identity.library == library,
                  entry.identity.listing == listing else { continue }
            found.append(try read(url, directory: directory, expected: entry.identity))
        }
        guard Set(found.compactMap { $0.request.idempotencyKey }).count == found.count else { throw Failure.unavailable }
        return found
    }
    private static func boundedBytes(_ url: URL, maxBytes: Int = 24 * 1024 * 1024) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = maxBytes
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { throw Failure.unavailable }
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw Failure.unavailable
    }
    static func finish(_ saved: Saved) throws {
        try FileManager.default.removeItem(at: saved.url)
    }
}
