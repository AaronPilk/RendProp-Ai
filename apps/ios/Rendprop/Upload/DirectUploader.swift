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

    // MARK: - Requests

    /// Single-PUT request for a presigned URL (video ≤ 64 MB). Background
    /// URLSession upload tasks stream from the file — multi-GB safe.
    static func putRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Multipart part-PUT request. Deliberately sets NO extra headers: R2/S3
    /// `UploadPart` presigned URLs sign only the host + query, and Content-Length
    /// is derived from the slice file by URLSession. Adding Content-Type here can
    /// break the signature.
    static func partPutRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        return request
    }

    /// Single-PUT request for a photo (contract §2.5). Content-Type mirrors the
    /// value handed to the presigner in the batch request.
    static func photoPutRequest(url: URL, contentType: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

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

    // MARK: - Temp slices (multipart)

    /// Directory holding this upload's in-flight part slices. Keyed by the server
    /// asset id so a relaunch finds the same folder.
    static func slicesDir(for assetID: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-upload-slices", isDirectory: true)
            .appendingPathComponent(assetID, isDirectory: true)
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
