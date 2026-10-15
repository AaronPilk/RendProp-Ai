import Foundation
import CryptoKit

/// A lost answer or a held quality check retains the exact paid operation.
/// Returning to the same edit checks it; it does not purchase another image.
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
    }
    struct Saved {
        let request: AIPhotoEditRequest
        let url: URL
    }
    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            "A saved photo request could not be verified. Your original is safe. Contact support before starting another paid edit."
        }
    }
    private static func fingerprint(_ request: AIPhotoEditRequest, identity: Identity) throws -> String {
        var intent = request
        intent.idempotencyKey = nil
        // Upload receipt and display label can be refreshed while recovering.
        // The dispatched body itself is always the exact saved request below.
        intent.originalAssetID = nil
        intent.label = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(identity)
        bytes.append(try encoder.encode(intent))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func begin(_ proposed: AIPhotoEditRequest, identity: Identity, directory: URL) throws -> Saved {
        let digest = try fingerprint(proposed, identity: identity)
        let folder = directory.appendingPathComponent(".pending-photo-edits", isDirectory: true)
        let url = folder.appendingPathComponent(digest + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 24 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.schema == 1, entry.identity == identity, entry.fingerprint == digest,
                  try fingerprint(entry.request, identity: identity) == digest,
                  entry.request.idempotencyKey.flatMap(UUID.init(uuidString:)) != nil else { throw Failure.unavailable }
            return Saved(request: entry.request, url: url)
        }
        var request = proposed; request.idempotencyKey = UUID().uuidString
        let data = try JSONEncoder().encode(Entry(schema: 1, identity: identity, fingerprint: digest, request: request))
        guard data.count <= 24 * 1024 * 1024 else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return Saved(request: request, url: url)
    }
    static func finish(_ saved: Saved) throws {
        try FileManager.default.removeItem(at: saved.url)
    }
}
