import Foundation

/// An ingested photo becomes visible only after both its original and its
/// brightened copy are durable. Failed writes never masquerade as success.
enum PhotoCaptureStorage {
    enum Failure: Error { case invalidID, alreadyExists }

    static func writePair(original: Data, enhanced: Data, id: String, directory: URL,
                          write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            throw Failure.invalidID
        }
        let before = directory.appendingPathComponent("orig-\(id).jpg")
        let after = directory.appendingPathComponent("enh-\(id).jpg")
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !files.fileExists(atPath: before.path), !files.fileExists(atPath: after.path) else {
            throw Failure.alreadyExists
        }
        do {
            try write(original, before)
            try write(enhanced, after)
        } catch {
            try? files.removeItem(at: before)
            try? files.removeItem(at: after)
            throw error
        }
    }
}
