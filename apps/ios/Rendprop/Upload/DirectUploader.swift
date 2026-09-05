import Foundation
import CryptoKit

/// Helpers for the presigned PUT / multipart path. Every file read here is
/// BOUNDED — nothing loads a whole walkthrough (2–8 GB) into memory.
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

    /// Lowercase-hex SHA-256 of a string — used to build bounded, stable
    /// idempotency keys ("ticket:<hash of path>:<bytes>").
    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Lowercase-hex SHA-256 of raw bytes — used to digest a request body into
    /// a deterministic `Idempotency-Key` (LiveAPIClient) without putting the
    /// payload itself in a header. In-memory: only for bodies we already built
    /// in memory, never for a capture file (use `sha256(of:)` for those).
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Content types

    /// The `content_type` declared on the upload ticket AND sent on the PUT —
    /// derived from the file extension, never hardcoded. The server stores the
    /// declared type and `/complete` deletes an object whose observed type
    /// differs (P0 audit fix: a `.mp4` render PUT as `video/quicktime` was
    /// rejected forever). Unknown extensions fall back to the kind's default
    /// (the server's own allow-list defaults).
    static func uploadContentType(for url: URL, kind: String) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4":         return "video/mp4"
        case "mov", "qt":   return "video/quicktime"
        case "m4v":         return "video/x-m4v"
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "heic":        return "image/heic"
        case "heif":        return "image/heif"
        case "webp":        return "image/webp"
        default:            return kind == "photo" ? "image/jpeg" : "video/mp4"
        }
    }

    /// Photo MIME for the batch path (contract §2.5). Unknown → octet-stream so
    /// the server's allow-list rejects it at ticket time rather than after the
    /// bytes are up.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "heic":        return "image/heic"
        case "heif":        return "image/heif"
        case "webp":        return "image/webp"
        case "gif":         return "image/gif"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - Requests

    /// Single-PUT request for a presigned URL (video ≤ 64 MB). Background
    /// URLSession upload tasks stream from the file — multi-GB safe. The
    /// Content-Type MUST equal the type declared on the ticket: single-video
    /// PUT URLs sign only the host, so R2 records whatever we send and
    /// `/complete` compares it to the declaration.
    static func putRequest(url: URL, contentType: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Multipart part-PUT request. Deliberately sets NO extra headers: R2/S3
    /// `UploadPart` presigned URLs sign only the host + query (verified in
    /// services/supabase/functions/_shared/r2.ts `presignUploadPart`), and the
    /// object's type comes from `CreateMultipartUpload` server-side. Content-
    /// Length is derived from the slice file by URLSession.
    static func partPutRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        return request
    }

    /// Single-PUT request for a photo (contract §2.5) — also used for the tour
    /// POSTER (`kind:"photo", role:"render"`). Photo PUT URLs are presigned WITH
    /// the content-type header, so the value must mirror what the ticket
    /// declared exactly or the signature fails.
    static func photoPutRequest(url: URL, contentType: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Temp slices (multipart)

    /// Directory holding this upload's in-flight part slices. Keyed by the server
    /// asset id so a relaunch finds the same folder. Lives in Application
    /// Support (excluded from backup) rather than `tmp` — iOS may purge `tmp`
    /// while the app is not running, which cost a retry per purged slice.
    static func slicesDir(for assetID: String) -> URL {
        let root = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("rp-upload-slices", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
        }
        let safeID = assetID.replacingOccurrences(of: "/", with: "_")
        let dir = root.appendingPathComponent(safeID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sliceURL(for assetID: String, part n: Int) -> URL {
        slicesDir(for: assetID).appendingPathComponent("part-\(n)")
    }

    static func removeSlice(for assetID: String, part n: Int) {
        try? FileManager.default.removeItem(at: sliceURL(for: assetID, part: n))
    }

    /// Delete every temp slice for an upload (success / cancel / abort).
    static func cleanSlices(for assetID: String) {
        try? FileManager.default.removeItem(at: slicesDir(for: assetID))
    }

    /// Copy the byte range `[offset, offset+length)` of `source` into a fresh
    /// `destination` file, streaming in bounded chunks. NEVER loads the range
    /// (up to hundreds of MB) into memory. Overwrites any existing destination.
    static func writeSlice(of source: URL, offset: Int64, length: Int64, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        try reader.seek(toOffset: UInt64(max(0, offset)))
        var remaining = max(0, length)
        let bufferSize = 4 * 1024 * 1024   // 4 MB copy window
        while remaining > 0 {
            let toRead = Int(min(Int64(bufferSize), remaining))
            let chunk = try autoreleasepool { try reader.read(upToCount: toRead) } ?? Data()
            if chunk.isEmpty { break }     // EOF safety — never over-read
            try writer.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        try writer.synchronize()
    }
}
