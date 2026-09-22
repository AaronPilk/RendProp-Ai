import Foundation
import Combine

struct ReflectionWork: Codable {
    struct Piece: Codable, Identifiable {
        var clip: ReflectionClip
        var id: UUID { clip.id }
        var inputPath: String?
        var assetID: String?
        var job: AIVideoJob?
        var outputPath: String?
    }
    var id = UUID()
    var listingID: UUID
    var serverListingID: UUID
    var ownerID: String
    var source: CaptureAsset
    var sourcePath: String
    var sidecarPath: String?
    var pieces: [Piece]
    var createdAt = Date()
    var resultPath: String?
    var result: CaptureAsset?
    var originalServerAssetID: String?
    var resultServerAssetID: String?
    var disclosure: String?
    var applied = false
    var cancellationRequested = false
    var cancellationConfirmed = false

    var directory: URL { ReflectionRemoval.directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    mutating func restorePaths() {
        source.localURL = FileStore.url(fromRelativePath: sourcePath)
        source.motionSidecarURL = sidecarPath.map(FileStore.url(fromRelativePath:))
        if let resultPath { result?.localURL = FileStore.url(fromRelativePath: resultPath) }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("work.json"), options: .atomic)
    }
}

/// Owns its task across navigation and journals every paid request before send.
/// A lost submit response is retried with the SAME clip UUID, never a new charge.
@MainActor
final class ReflectionRemoval: ObservableObject {
    static var directory: URL { FileStore.documents.appendingPathComponent("ReflectionEdits", isDirectory: true) }
    private static var active: [UUID: ReflectionRemoval] = [:]
    static func controller(listingID: UUID, asset: CaptureAsset) -> ReflectionRemoval {
        if let existing = active[listingID], existing.source.id == asset.id || existing.work?.result?.id == asset.id {
            return existing
        }
        let controller = ReflectionRemoval(listingID: listingID, asset: asset)
        active[listingID] = controller
        return controller
    }

    @Published private(set) var work: ReflectionWork?
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    @Published private(set) var quote: ReflectionQuote?
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    let listingID: UUID
    private let initialAsset: CaptureAsset
    var source: CaptureAsset { work?.source ?? initialAsset }
    var canPreview: Bool { work?.resultPath != nil && work?.cancellationRequested != true }
    var resultURL: URL? { work?.resultPath.map(FileStore.url(fromRelativePath:)) }

    private init(listingID: UUID, asset: CaptureAsset) {
        self.listingID = listingID
        self.initialAsset = asset
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let saved = dirs.compactMap { url -> ReflectionWork? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("work.json")),
                  var value = try? JSONDecoder().decode(ReflectionWork.self, from: data),
                  value.listingID == listingID, value.ownerID == AuthStore.shared.userID,
                  value.source.id == asset.id || value.result?.id == asset.id else { return nil }
            value.restorePaths()
            return value
        }.sorted { $0.createdAt > $1.createdAt }
        work = saved.first
    }

    func loadQuote(model: AppModel, listing: Listing) async {
        guard Config.useLiveBackend, await AuthStore.shared.ensureSession() else { return }
        do {
            let serverID = try await model.ensureServerListing(listing)
            quote = try await model.api.reflectionQuote(listingID: serverID)
        } catch { self.error = error.localizedDescription }
    }

    func start(clips: [ReflectionClip], model: AppModel, listing: Listing) {
        guard !isBusy else { return }
        launch {
            guard await AIConsent.shared.ensureGranted(), await AuthStore.shared.ensureSession(),
                  let owner = AuthStore.shared.userID else { return }
            let serverID = try await model.ensureServerListing(listing)
            if self.work == nil || self.work?.cancellationConfirmed == true {
                let quote = try await model.api.reflectionQuote(listingID: serverID)
                self.quote = quote
                guard quote.available, !clips.isEmpty, clips.count <= quote.remainingClips,
                      clips.allSatisfy({ $0.durationS > 0 && $0.durationS <= min(4.8, quote.maxClipSeconds) }),
                      clips.reduce(0, { $0 + $1.durationS }) <= quote.maximumSeconds else {
                    throw APIError.server(status: 402, code: "quota_exceeded", message: "Select fewer intervals to fit your available AI clips and this video's edit limit.")
                }
                guard FileStore.freeSpaceBytes() > self.source.bytes * 3 + 300_000_000 else {
                    throw ReflectionVideo.Failure.insufficientSpace
                }
                let source = self.source
                self.work = ReflectionWork(listingID: listing.id, serverListingID: serverID,
                    ownerID: owner, source: source, sourcePath: FileStore.relativePath(for: source.localURL),
                    sidecarPath: source.motionSidecarURL.map(FileStore.relativePath(for:)),
                    pieces: clips.map { ReflectionWork.Piece(clip: $0) })
                try self.checkpoint()
            }
            guard self.work?.cancellationRequested != true, self.work?.applied != true else { return }
            try self.checkOwner()
            try await self.process(model: model)
        }
    }

    func cancel(model: AppModel) {
        guard let saved = work, !saved.applied else { return }
        // This flag is durable even if the request cannot reach the server.
        work?.cancellationRequested = true
        do { try checkpoint() } catch { self.error = error.localizedDescription; return }
        task?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        task = nil
        isBusy = true
        task = Task { @MainActor in
            do {
                try self.checkOwner()
                try await model.api.cancelReflectionBatch(saved.id)
                self.work?.cancellationConfirmed = true
                try self.checkpoint()
                self.message = "Cancelled. The original is unchanged and this edit uses no AI clips."
                self.error = nil
            } catch {
                self.error = "Cancellation needs a connection to return your AI clips. Retry cancellation. \(error.localizedDescription)"
            }
            if self.operationID == operationID {
                self.isBusy = false
                self.task = nil
            }
        }
    }

    func accept(model: AppModel, completion: @escaping (CaptureAsset) -> Void) {
        guard !isBusy, let saved = work, saved.result != nil, !saved.cancellationRequested else { return }
        launch {
            try self.checkOwner()
            if !saved.applied {
                self.message = "Saving the original and edited video for the disclosure…"
                if self.work?.originalServerAssetID == nil {
                    let id = try await self.upload(saved.source.localURL, serverID: saved.serverListingID)
                    try self.checkOwner()
                    self.work?.originalServerAssetID = id
                    try self.checkpoint()
                }
                if self.work?.resultServerAssetID == nil, let resultURL = self.resultURL {
                    let id = try await self.upload(resultURL, serverID: saved.serverListingID)
                    try self.checkOwner()
                    self.work?.resultServerAssetID = id
                    try self.checkpoint()
                }
                guard let original = self.work?.originalServerAssetID, let result = self.work?.resultServerAssetID else {
                    throw ReflectionVideo.Failure.exportFailed
                }
                let receipt = try await model.api.applyReflectionBatch(saved.id, originalAssetID: original, alteredAssetID: result)
                guard receipt.provenance.recorded, receipt.provenance.id != nil else {
                    throw APIError.server(status: 503, code: "upstream", message: "The edit's disclosure could not be saved. Retry before using the result.")
                }
                self.work?.disclosure = receipt.disclosure
                self.work?.applied = true
                try self.checkpoint()
            }
            try self.checkOwner()
            guard let result = self.work?.result else { throw ReflectionVideo.Failure.exportFailed }
            model.assets[self.listingID] = result
            completion(result)
            self.message = "Reflection removal applied. Your original is saved. Create or render the tour again to use this version."
        }
    }

    private func process(model: AppModel) async throws {
        guard let saved = work else { return }
        for i in saved.pieces.indices {
            try checkOwner()
            try Task.checkCancellation()
            if work?.cancellationRequested == true { throw CancellationError() }
            message = "Editing interval \(i + 1) of \(saved.pieces.count)…"
            let clip = saved.pieces[i].clip
            if work?.pieces[i].inputPath == nil {
                let output = saved.directory.appendingPathComponent("input-\(clip.id.uuidString)-\(UUID().uuidString).mp4")
                try await ReflectionVideo.extract(source: saved.source.localURL, clip: clip, destination: output)
                work?.pieces[i].inputPath = FileStore.relativePath(for: output)
                try checkpoint()
            }
            if work?.pieces[i].assetID == nil, let path = work?.pieces[i].inputPath {
                let id = try await upload(FileStore.url(fromRelativePath: path), serverID: saved.serverListingID)
                work?.pieces[i].assetID = id
                try checkpoint()
            }
            try checkOwner()
            try Task.checkCancellation()
            guard work?.cancellationRequested != true, let assetID = work?.pieces[i].assetID else { throw CancellationError() }
            if work?.pieces[i].job == nil {
                // clip.id was saved BEFORE uploading/submitting and survives
                // retry, a lost response, process death and phone restart.
                let job = try await model.api.removeReflections(assetID: assetID, listingID: saved.serverListingID,
                    batchID: saved.id, idempotencyKey: clip.id)
                work?.pieces[i].job = job
                try checkpoint()
            }
            guard let job = work?.pieces[i].job else { throw APIError.decoding }
            if work?.pieces[i].outputPath == nil {
                let remote = try await poll(job, api: model.api)
                try Task.checkCancellation()
                let output = saved.directory.appendingPathComponent("output-\(clip.id.uuidString)-\(UUID().uuidString).mp4")
                let (temporary, response) = try await URLSession.shared.download(from: remote)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError.badResponse(502) }
                try FileManager.default.moveItem(at: temporary, to: output)
                work?.pieces[i].outputPath = FileStore.relativePath(for: output)
                try checkpoint()
            }
        }
        try Task.checkCancellation()
        if work?.resultPath == nil {
            message = "Putting the edited intervals back into your video…"
            let output = saved.directory.appendingPathComponent("edited-\(UUID().uuidString).mp4")
            let replacements = try (work?.pieces ?? []).map { piece -> (ReflectionClip, URL) in
                guard let path = piece.outputPath else { throw ReflectionVideo.Failure.noVideo }
                return (piece.clip, FileStore.url(fromRelativePath: path))
            }
            try await ReflectionVideo.splice(source: saved.source.localURL, replacements: replacements, destination: output)
            var result = try await MediaImporter.makeAsset(from: output, isDrone: saved.source.isDrone, deleteOnFailure: false)
            result.roomTags = saved.source.roomTags
            // The original's ranges are evidence; do not say Vision verified
            // the generated output or automatically offer another paid pass.
            result.personVisibleRanges = []
            work?.resultPath = FileStore.relativePath(for: output)
            work?.result = result
            try checkpoint()
        }
        message = "Compare the edit with your original. Check mirrors, walls and details before accepting."
    }

    private func poll(_ job: AIVideoJob, api: APIClient) async throws -> URL {
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try checkOwner()
            switch try await api.aiVideoStatus(job) {
            case .completed(let url):
                guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw APIError.invalidURL }
                return url
            case .failed(let message): throw APIError.server(status: 502, code: "upstream", message: message)
            case .processing: try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw APIError.server(status: 503, code: "upstream", message: "This edit is still waiting. Retry to check the same jobs, or cancel to return your AI clips.")
    }

    private func upload(_ url: URL, serverID: UUID) async throws -> String {
        let probe = await MediaImporter.probe(url: url)
        guard probe.hasVideoTrack, probe.isPlayable, probe.duration > 0, FileStore.fileSize(url) > 0 else {
            throw ReflectionVideo.Failure.noVideo
        }
        try checkOwner()
        // role original is photo-only in the existing upload contract. Both
        // complete videos use render; apply resolves their distinct asset IDs.
        return try await UploadManager.shared.upload(fileURL: url, listingID: serverID, role: "render",
            metadata: UploadMetadata(durationS: probe.duration, fps: probe.fps, width: probe.width,
                height: probe.height, bytes: FileStore.fileSize(url)))
    }

    private func checkOwner() throws {
        guard let work, AuthStore.shared.userID == work.ownerID else { throw CancellationError() }
    }
    private func checkpoint() throws { try work?.save() }
    private func launch(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        error = nil
        isBusy = true
        let operationID = UUID()
        self.operationID = operationID
        task = Task { @MainActor in
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            if self.operationID == operationID {
                self.isBusy = false
                self.task = nil
            }
        }
    }
}
