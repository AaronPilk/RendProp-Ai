import Foundation

@MainActor enum PropertyVideoNarrationUpload {
    private struct Receipt: Decodable {
        let narrationAssetID: UUID
        let listingID: UUID
        let selectedLibraryOrgID: UUID
        let sha256: String
        let ready: Bool
        let putURL: URL?
        let headers: [String: String]?
        enum CodingKeys: String, CodingKey {
            case narrationAssetID = "narration_asset_id", listingID = "listing_id", selectedLibraryOrgID = "selected_library_org_id"
            case sha256, ready, putURL = "put_url", headers
        }
    }
    private struct Pending: Codable {
        let operationID: UUID
        let context: PropertyVideoJobContext
        let sha256: String
        let bytes: Int64
    }
    static func upload(_ voice: Voiceover, operationID: UUID, context: PropertyVideoJobContext,
                       requireCurrent: @MainActor () throws -> Void) async throws -> UUID {
        try requireCurrent()
        guard voice.duration.isFinite, voice.duration > 0, voice.duration <= 600 else {
            throw AIImagePrep.error("This narration is too long for a property video. Keep it under ten minutes; the recording is unchanged.")
        }
        let ext = voice.audioURL.pathExtension.lowercased()
        guard ["m4a", "mp3"].contains(ext) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let bytes = FileStore.fileSize(voice.audioURL)
        guard bytes > 1024, bytes <= 20 * 1024 * 1024 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let digest = try await Task.detached(priority: .utility) { try ListingVideoStore.digest(voice.audioURL) }.value
        try requireCurrent()
        let directory = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pendingURL = directory.appendingPathComponent("\(context.localListingID.uuidString)-narration-\(context.actorID.uuidString)-\(context.orgID.uuidString)-\(digest).json")
        let pending: Pending
        if FileManager.default.fileExists(atPath: pendingURL.path) {
            guard let count = try pendingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0, count <= 4096 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))
            guard pending.context == context, pending.sha256 == digest, pending.bytes == bytes else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        } else {
            pending = Pending(operationID: operationID, context: context, sha256: digest, bytes: bytes)
            let data = try JSONEncoder().encode(pending)
            try data.write(to: pendingURL, options: .atomic)
            guard try Data(contentsOf: pendingURL) == data else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        }
        let body: [String: Any] = ["operation_id": pending.operationID.uuidString.lowercased(),
            "listing_id": context.listingID.uuidString.lowercased(), "expected_org_id": context.orgID.uuidString.lowercased(),
            "bytes": bytes, "sha256": digest, "mime": ext == "mp3" ? "audio/mpeg" : "audio/mp4"]
        let prepared = try JSONDecoder().decode(Receipt.self, from: await PropertyVideoJobHTTP.data("POST", context: context,
            segments: ["audio", "prepare"], body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            idempotencyKey: "property-video-audio:" + pending.operationID.uuidString.lowercased()))
        func checked(_ receipt: Receipt) throws {
            guard receipt.listingID == context.listingID, receipt.selectedLibraryOrgID == context.orgID, receipt.sha256 == digest else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        }
        try checked(prepared); try requireCurrent()
        if prepared.ready { return prepared.narrationAssetID }
        let completedBody = try JSONSerialization.data(withJSONObject: ["expected_org_id": context.orgID.uuidString.lowercased(),
            "listing_id": context.listingID.uuidString.lowercased()], options: [.sortedKeys])
        func complete() async throws -> Receipt {
            let completed = try JSONDecoder().decode(Receipt.self, from: await PropertyVideoJobHTTP.data("POST", context: context,
                segments: ["audio", prepared.narrationAssetID.uuidString.lowercased(), "complete"], body: completedBody,
                idempotencyKey: "property-video-audio-complete:" + prepared.narrationAssetID.uuidString.lowercased()))
            try requireCurrent(); try checked(completed)
            guard completed.ready, completed.narrationAssetID == prepared.narrationAssetID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            return completed
        }
        // Reconcile before immutable PUT: the previous transfer may have
        // succeeded even when its reply was lost. Repeating it would receive
        // If-None-Match 412 and could strand otherwise valid recorded narration.
        do { return try await complete().narrationAssetID }
        catch {
            guard let api = error as? APIError, api.status == 409 else { throw error }
        }
        guard let put = prepared.putURL, let headers = prepared.headers else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        guard try ListingVideoStore.digest(voice.audioURL) == digest else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try await PropertyVideoJobHTTP.putAudio(url: put, headers: headers, file: voice.audioURL, requireCurrent: requireCurrent)
        return try await complete().narrationAssetID
    }
}
