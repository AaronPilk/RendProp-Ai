import Foundation
import CryptoKit
import Darwin

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
                            transfer: (URLRequest, URL) async throws -> URLResponse = { request, file in
                                try await URLSession.shared.upload(for: request, fromFile: file).1
                            }, delay: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) async throws -> String {
        // Public photo receipts describe the retained bytes, never their legacy filename.
        let browser = ["gallery", "original", "render"].contains(role) ? try browserPhoto(fileURL) : nil
        if let browser, browser.contentType != contentType { throw BrowserPhotoFailure.unsupportedFormat }
        let bytes = browser?.bytes ?? FileStore.fileSize(fileURL)
        guard bytes > 0, let digest = browser?.sha256 ?? sha256(of: fileURL) else { throw UploadRecovery.Failure.invalidTicket }
        func checkBody() throws {
            if let browser, try browserPhoto(fileURL) != browser { throw BrowserPhotoFailure.sourceChanged }
        }
        if Config.useLiveBackend && Config.enableAuth {
            // An anonymous session may still be connecting on first launch.
            // Bind the journal AFTER that normal connection, never to a nil
            // placeholder owner that will change during the ticket request.
            guard await AuthStore.shared.ensureSession() else { throw CancellationError() }
        }
        let owner = AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject)
        let key = keyPrefix + ":" + sha256Hex("\(listingID.uuidString)|\(role)|\(digest)|\(bytes)")
        let journalKey = photoJournalKey(owner: owner ?? "anonymous-pending", listingID: listingID,
            role: role, keyPrefix: keyPrefix, digest: digest, bytes: bytes)
        func checkOwner() throws {
            try Task.checkCancellation()
            guard AuthStore.currentAccessToken.flatMap(AuthStore.jwtSubject) == owner else { throw CancellationError() }
        }
        func create() async throws -> UploadTicket {
            try checkOwner(); try checkBody()
            let ticket = try await api.requestUpload(filename: fileURL.lastPathComponent, bytes: bytes,
                listingID: listingID, sha256: digest, kind: "photo", role: role,
                contentType: contentType, idempotencyKey: key)
            try checkOwner(); try checkBody()
            if let browser { try requireBrowserTicket(ticket, contentType: browser.contentType, role: role, listingID: listingID, allowUnknown: ticket.replayed != false) }
            return ticket
        }
        if !Config.useLiveBackend { return try await create().assetID }
        let store = journalStore
        try await store.acquire(journalKey)
        do {
            var record = try await store.load(journalKey) ?? UploadRecovery.Journal()
            let explicitResume = record.ticket != nil
            // Validate BEFORE changing any recovery flags or issuing a probe.
            // Missing legacy MIME stays unknown, never mismatch or replacement authority.
            if let browser, let ticket = record.ticket {
                if let declared = record.photoContentType, declared != browser.contentType { throw BrowserPhotoFailure.legacyReceipt }
                try requireBrowserTicket(ticket, contentType: browser.contentType, role: role, listingID: listingID, allowUnknown: true)
                try checkOwner(); try checkBody()
            }
            // A ticket that already ran a whole call dry may be retired and
            // replaced on THIS later, explicit attempt — once. The flag is
            // cleared in memory now so a ticket saved by this call starts with
            // a clean slate; a failed call below sets it again.
            let allowReplacement = record.recoveryExhausted == true
            record.recoveryExhausted = nil
            if record.ticket == nil {
                let ticket = try await create()
                if let browser {
                    // A replay may be an older reservation. Keep its MIME unknown
                    // and reconcile it normally; never adopt or relabel a declaration.
                    if ticket.replayed == false { record.photoContentType = browser.contentType }
                }
                record.ticket = ticket; try await store.save(record, for: journalKey)
            }
            guard let initial = record.ticket, initial.mode == .single else { throw UploadRecovery.Failure.invalidTicket }
            if record.completed { try checkOwner(); try checkBody(); await store.release(journalKey); return initial.assetID }
            var metadata = UploadMetadata(); metadata.bytes = bytes; metadata.sha256 = digest
            var lastError: Error = UploadRecovery.Failure.invalidTicket
            for attempt in 0..<3 {
                try checkOwner()
                if attempt > 0 { try await delay(UInt64(attempt) * 1_000_000_000) }
                do {
                    try checkBody()
                    if record.dispatched || record.ticket?.replayed != false {
                        let result = try await UploadRecovery.reconcile(journal: record,
                            allowLegacyCancellation: explicitResume,
                            allowRetiredReplacement: allowReplacement,
                            persistCancellation: { id in
                                try checkOwner()
                                record.cancellationAuthorizedFor = id
                                try await store.save(record, for: journalKey)
                            }, complete: { id in
                                try checkOwner(); try checkBody()
                                try await api.completeUpload(assetID: id, parts: nil, metadata: metadata)
                            }, renew: { id in
                                try checkOwner(); try checkBody()
                                let renewed = try await api.renewUpload(assetID: id)
                                try checkOwner(); try checkBody()
                                if let browser { try requireBrowserTicket(renewed, contentType: browser.contentType, role: role, listingID: listingID, allowUnknown: record.photoContentType == nil) }
                                return renewed
                            },
                            cancel: { id in try checkOwner(); try await api.abortUpload(assetID: id) }, create: create)
                        switch result {
                        case .complete(let id):
                            try checkOwner(); try checkBody()
                            record.completed = true; try await store.save(record, for: journalKey)
                            try checkOwner(); await store.release(journalKey); return id
                        case .ticket(let ticket):
                            if let browser { try requireBrowserTicket(ticket, contentType: browser.contentType, role: role, listingID: listingID, allowUnknown: record.photoContentType == nil) }
                            try checkOwner(); try checkBody()
                            record.ticket = ticket
                            try await store.save(record, for: journalKey)
                        }
                    }
                    guard let ticket = record.ticket, let put = ticket.putURL,
                          put.scheme == "https", ticket.mode == .single else { throw UploadRecovery.Failure.invalidTicket }
                    try checkOwner(); try checkBody()
                    // Persist BEFORE handing bytes to URLSession: app death or
                    // network handover afterward is always reconciled first.
                    record.dispatched = true
                    try await store.save(record, for: journalKey)
                    let response = try await transfer(photoPutRequest(url: put, contentType: contentType), fileURL)
                    try checkOwner(); try checkBody()
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw APIError.badResponse(status) }
                    try await api.completeUpload(assetID: ticket.assetID, parts: nil, metadata: metadata)
                    try checkOwner(); try checkBody()
                    record.completed = true; try await store.save(record, for: journalKey)
                    try checkOwner(); await store.release(journalKey); return ticket.assetID
                } catch is CancellationError { throw CancellationError() }
                catch {
                    lastError = error
                    if error is UploadRecovery.Failure || error is BrowserPhotoFailure { throw error }
                    // Retry means reconcile on the next iteration, never reuse
                    // this PUT URL. A service rollout may legitimately pause it.
                    // These are the request's own fault (or the session's), not
                    // the ticket's: they stop the call without marking the
                    // ticket exhausted, so the next attempt reconciles it as
                    // usual instead of paying for a replacement.
                    if let status = (error as? APIError)?.status,
                       [400, 401, 402, 405, 413].contains(status) { throw error }
                    // The row is gone or the server aborted the ticket: no
                    // further round on it can help, so stop paying for them.
                    if UploadRecovery.isRetired(error) { break }
                }
            }
            // Every round on this reservation ran dry, or the server retired it.
            // `dispatched` stays as it is — the next attempt must still probe
            // `/complete` before anything else — but that next, explicit attempt
            // is now allowed to abort this ticket and reserve afresh. Before
            // this mark, a dead ticket under a content key made the same photo
            // impossible to upload ever again. The error itself is thrown so the
            // caller can say what happened.
            record.recoveryExhausted = true
            try? await store.save(record, for: journalKey)
            throw lastError
        } catch {
            await store.release(journalKey)
            throw error
        }
    }
    enum BrowserPhotoFailure: LocalizedError {
        case unsupportedFormat, sourceChanged, legacyReceipt
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This selected photo is not a JPEG, PNG or WebP file. Choose a browser-compatible saved version; its unchanged original remains in Photos."
            case .sourceChanged:
                return "The selected photo changed while its upload was being checked. Check its saved upload before continuing; no automatic replacement was started and its history is kept."
            case .legacyReceipt:
                return "This saved upload's photo format conflicts with the selected file. Its original, saved upload and current listing selection are kept. Check or discard any pending photo choice in Photos; no replacement upload was started."
            }
        }
    }

    struct BrowserPhoto: Equatable {
        let contentType: String
        let bytes: Int64
        let sha256: String
    }

    /// Same-descriptor, bounded signature and streaming hash. No image conversion,
    /// file rename, or whole-photo allocation. Filename is deliberately irrelevant.
    static func browserPhoto(_ url: URL) throws -> BrowserPhoto {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw BrowserPhotoFailure.unsupportedFormat }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 128 * 1024 * 1024 else { throw BrowserPhotoFailure.unsupportedFormat }
        var total: Int64 = 0, prefix = Data(), hash = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1024 * 1024) ?? Data() }
            catch { throw BrowserPhotoFailure.sourceChanged }
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= before.st_size else { throw BrowserPhotoFailure.sourceChanged }
            if prefix.count < 12 { prefix.append(chunk.prefix(12 - prefix.count)) }
            hash.update(data: chunk)
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              total == before.st_size, before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw BrowserPhotoFailure.sourceChanged }
        let mime: String
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { mime = "image/jpeg" }
        else if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { mime = "image/png" }
        else if prefix.count >= 12, prefix.prefix(4) == Data("RIFF".utf8), prefix.dropFirst(8).prefix(4) == Data("WEBP".utf8) { mime = "image/webp" }
        else { throw BrowserPhotoFailure.unsupportedFormat }
        return BrowserPhoto(contentType: mime, bytes: total, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Server public-photo key suffixes are derived from its declared MIME, not
    /// the caller filename. This rejects contradictions; it is NOT a conversion
    /// or sufficient proof by itself to adopt a legacy receipt.
    static func requireBrowserTicket(_ ticket: UploadTicket, contentType: String, role: String, listingID: UUID, allowUnknown: Bool = false) throws {
        guard ticket.mode == .single, let asset = UUID(uuidString: ticket.assetID) else { throw UploadRecovery.Failure.invalidTicket }
        if let declared = ticket.contentType, declared != contentType { throw BrowserPhotoFailure.legacyReceipt }
        guard let key = ticket.storageKey else {
            if allowUnknown { return } // Preserve old strict server reconciliation, not a MIME proof.
            throw UploadRecovery.Failure.invalidTicket
        }
        let pieces = key.split(separator: "/", omittingEmptySubsequences: false)
        let ext = contentType == "image/jpeg" ? "jpg" : contentType == "image/png" ? "png" : contentType == "image/webp" ? "webp" : ""
        let stem = role == "gallery" ? "gallery-" : role == "original" ? "original-" : ""
        let name = pieces.last.map(String.init) ?? ""
        let pattern = "^" + stem + asset.uuidString.lowercased() + "(?:-complete-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?\\." + ext + "$"
        guard !ext.isEmpty, pieces.count == 4, pieces[0] == "renders", UUID(uuidString: String(pieces[1])) != nil,
              UUID(uuidString: String(pieces[2])) == listingID,
              name.range(of: pattern, options: .regularExpression) != nil else { throw BrowserPhotoFailure.legacyReceipt }
    }

    /// Mutation-only admission. Read-only identity discovery and explicit Discard
    /// retain old receipts. Reject known contradictions before journal/PATCH;
    /// unknown legacy MIME still faces the unchanged strict server oracle.
    static func requireGalleryReceipt(fileURL: URL, ownerID: UUID, listingID: UUID, assetID: UUID,
                                      sha256: String, bytes: Int64, storageKey: String?,
                                      journalStore: DirectUploadJournal = .shared) async throws {
        let body = try browserPhoto(fileURL)
        guard body.sha256 == sha256, body.bytes == bytes else { throw BrowserPhotoFailure.sourceChanged }
        let key = photoJournalKey(owner: ownerID.uuidString.lowercased(), listingID: listingID,
            role: "gallery", keyPrefix: "gallery", digest: sha256, bytes: bytes)
        if let saved = try await journalStore.load(key), let ticket = saved.ticket {
            guard saved.completed, UUID(uuidString: ticket.assetID) == assetID else { throw UploadRecovery.Failure.invalidTicket }
            if let declared = saved.photoContentType, declared != body.contentType { throw BrowserPhotoFailure.legacyReceipt }
            try requireBrowserTicket(ticket, contentType: body.contentType, role: "gallery", listingID: listingID, allowUnknown: true)
        }
        if let storageKey {
            let current = UploadTicket(assetID: assetID.uuidString, mode: .single, storageKey: storageKey)
            try requireBrowserTicket(current, contentType: body.contentType, role: "gallery", listingID: listingID)
        }
        guard try browserPhoto(fileURL) == body else { throw BrowserPhotoFailure.sourceChanged }
    }

    /// One shared definition for writes and later, read-only photo identity lookup.
    static func photoJournalKey(owner: String, listingID: UUID, role: String, keyPrefix: String,
                                digest: String, bytes: Int64) -> String {
        "\(owner)|\(keyPrefix):" + sha256Hex("\(listingID.uuidString)|\(role)|\(digest)|\(bytes)")
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
