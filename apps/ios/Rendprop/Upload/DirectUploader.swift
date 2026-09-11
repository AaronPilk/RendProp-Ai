import Foundation
import CryptoKit

/// Helpers for the presigned PUT / multipart path. Every file read here is
/// BOUNDED — nothing loads a whole walkthrough (2–8 GB) into memory.
enum DirectUploader {
    /// Shared foreground path for gallery/original/poster/batch photos. A lost
    /// completion reply is not another PUT; it resumes the exact saved ticket.
    /// A second explicit call may replace a retired legacy ticket after the
    /// exact per-ticket cancellation receipt. No operation deletes the source.
    static func uploadPhoto(fileURL: URL, listingID: UUID, role: String,
                            contentType: String, keyPrefix: String, api: APIClient,
                            journalStore: DirectUploadJournal = .shared,
                            confirmRestart: Bool = false,
                            transfer: (URLRequest, URL) async throws -> URLResponse = { request, file in
                                try await URLSession.shared.upload(for: request, fromFile: file).1
                            }, delay: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> String {
        let bytes = FileStore.fileSize(fileURL)
        guard bytes > 0, let digest = sha256(of: fileURL) else { throw UploadRecovery.Failure.invalidTicket }
        if Config.useLiveBackend && Config.enableAuth {
            // An anonymous session may still be connecting on first launch.
            // Bind the journal AFTER that normal connection, never to a nil
            // placeholder owner that will change during the ticket request.
            guard await AuthStore.shared.ensureSession() else { throw CancellationError() }
        }
        let owner = AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject)
        let key = keyPrefix + ":" + sha256Hex("\(listingID.uuidString)|\(role)|\(digest)|\(bytes)")
        let journalKey = "\(owner ?? "anonymous-pending")|\(key)"
        func checkOwner() throws {
            try Task.checkCancellation()
            guard AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject) == owner else { throw CancellationError() }
        }
        func create() async throws -> UploadTicket {
            try checkOwner()
            return try await api.requestUpload(filename: fileURL.lastPathComponent, bytes: bytes,
                listingID: listingID, sha256: digest, kind: "photo", role: role,
                contentType: contentType, idempotencyKey: key)
        }
        if !Config.useLiveBackend { return try await create().assetID }
        let store = journalStore
        try await store.acquire(journalKey)
        var record = UploadRecovery.Journal()
        var canPersistRecord = false
        do {
            record = try await store.load(journalKey) ?? UploadRecovery.Journal()
            canPersistRecord = true
            if let owner {
                record.source = UploadRecovery.PhotoSource(ownerID: owner, relativePath: FileStore.relativePath(for: fileURL),
                    listingID: listingID, role: role, contentType: contentType, keyPrefix: keyPrefix, bytes: bytes, sha256: digest)
            }
            let explicitResume = record.ticket != nil
            try await store.save(record, for: journalKey) // prove local persistence before any reservation
            if record.ticket == nil { record.ticket = try await create(); try await store.save(record, for: journalKey) }
            guard let initial = record.ticket, initial.mode == .single else { throw UploadRecovery.Failure.invalidTicket }
            if record.completed { try checkOwner(); await store.release(journalKey); return initial.assetID }
            var metadata = UploadMetadata(); metadata.bytes = bytes; metadata.sha256 = digest
            if confirmRestart {
                guard let owner, record.needsRestart == true || record.restartIntent != nil else { throw UploadRecovery.Failure.invalidTicket }
                if record.restartIntent == nil { record.restartIntent = .init(assetID: initial.assetID, ownerID: owner) }
                try await store.save(record, for: journalKey)
                let replaced = try await UploadRecovery.restart(record.restartIntent!, ticket: initial,
                    currentOwner: { AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject) },
                    complete: { try checkOwner(); try await api.completeUpload(assetID: initial.assetID, parts: nil, metadata: metadata) },
                    replace: { id, operationID in try checkOwner(); return try await api.restartUpload(assetID: id, operationID: operationID) })
                try checkOwner()
                // Persist the returned child BEFORE evaluating whether it has
                // already expired. A lost response must not leave its identity
                // behind and start another branch of paid attempts.
                record.ticket = replaced
                record.restartIntent = nil
                record.dispatched = replaced.retryAfterSeconds != nil
                record.needsRestart = replaced.restartRequired == true
                record.completed = replaced.uploaded == true
                try await store.save(record, for: journalKey)
                if record.completed { await store.release(journalKey); return replaced.assetID }
                if replaced.restartRequired == true { throw UploadRecovery.RestartRequired(ticket: replaced) }
                if let seconds = replaced.retryAfterSeconds { throw UploadRecovery.AwaitingReceipt(seconds: seconds) }
            }
            var lastError: Error = UploadRecovery.Failure.invalidTicket
            for attempt in 0..<3 {
                try checkOwner()
                if attempt > 0 { try await delay(UInt64(attempt) * 1_000_000_000) }
                do {
                    if record.dispatched || record.ticket?.replayed != false {
                        let result = try await UploadRecovery.reconcile(journal: record,
                            allowLegacyCancellation: explicitResume,
                            persistCancellation: { id in
                                try checkOwner()
                                record.cancellationAuthorizedFor = id
                                try await store.save(record, for: journalKey)
                            }, complete: { id in
                                try checkOwner()
                                try await api.completeUpload(assetID: id, parts: nil, metadata: metadata)
                            }, renew: { id in try checkOwner(); return try await api.renewUpload(assetID: id) },
                            cancel: { id in try checkOwner(); try await api.abortUpload(assetID: id) }, create: create)
                        switch result {
                        case .complete(let id):
                            record.completed = true; record.failureMessage = nil; record.needsRestart = false
                            try await store.save(record, for: journalKey)
                            try checkOwner(); await store.release(journalKey); return id
                        case .ticket(let ticket):
                            record.ticket = ticket
                            try await store.save(record, for: journalKey)
                        }
                    }
                    guard let ticket = record.ticket, let put = ticket.putURL,
                          put.scheme == "https", ticket.mode == .single else { throw UploadRecovery.Failure.invalidTicket }
                    try checkOwner()
                    // Persist BEFORE handing bytes to URLSession: app death or
                    // network handover afterward is always reconciled first.
                    record.dispatched = true
                    try await store.save(record, for: journalKey)
                    let response = try await transfer(photoPutRequest(url: put, contentType: contentType), fileURL)
                    try checkOwner()
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw APIError.badResponse(status) }
                    try await api.completeUpload(assetID: ticket.assetID, parts: nil, metadata: metadata)
                    record.completed = true; record.failureMessage = nil; record.needsRestart = false
                    try await store.save(record, for: journalKey)
                    try checkOwner(); await store.release(journalKey); return ticket.assetID
                } catch is CancellationError { throw CancellationError() }
                catch {
                    lastError = error
                    if error is UploadRecovery.RestartRequired || error is UploadRecovery.AwaitingReceipt { throw error }
                    if error is UploadRecovery.Failure { throw error }
                    // Retry means reconcile on the next iteration, never reuse
                    // this PUT URL. A service rollout may legitimately pause it.
                    if let status = (error as? APIError)?.status,
                       [400, 401, 402, 404, 405, 413].contains(status) { throw error }
                }
            }
            throw lastError
        } catch {
            if let required = error as? UploadRecovery.RestartRequired {
                record.ticket = required.ticket; record.needsRestart = true
            }
            record.failureMessage = error.localizedDescription
            // Record the failed operation under its ORIGINAL owner/key even if
            // the account changed during the response. Never rebind its media.
            if canPersistRecord { try? await store.save(record, for: journalKey) }
            await store.release(journalKey)
            throw error
        }
    }
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

    /// Photo PUTs mirror the declared type. v2 enforces it at the gateway;
    /// legacy host-only presigning never bound Content-Type in the signature.
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
