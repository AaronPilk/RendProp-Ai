import Foundation
import CryptoKit

/// Helpers for the .direct (presigned PUT/multipart) path.
enum DirectUploader {
    /// Streaming SHA-256 — never loads the file into memory. Run off-main.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8_000_000) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Build the background PUT request for a presigned URL. Background
    /// URLSession upload tasks stream from the file — multi-GB safe.
    static func putRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        return request
    }

    // TODO (master spec 4.4 / Part 7): R2/S3 multipart for >5GB —
    // requestUpload returns part URLs, upload each part as its own background
    // task from a file slice, persist part ETags in UploadStore, then call
    // completeUpload with the ETag manifest. The single-PUT path below covers
    // Phase 1 walkthroughs.
}
