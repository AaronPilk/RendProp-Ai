import Foundation
import Combine

private enum ReflectionOperation {
    @TaskLocal static var id: UUID?
}

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
    nonisolated static var directory: URL { FileStore.documents.appendingPathComponent("ReflectionEdits", isDirectory: true) }
    private static var active: [String: ReflectionRemoval] = [:]
    static func controller(listingID: UUID, asset: CaptureAsset) -> ReflectionRemoval {
        let key = "\(AuthStore.shared.userID ?? "signed-out"):\(listingID.uuidString)"
        if let existing = active[key], existing.source.id == asset.id || existing.work?.result?.id == asset.id {
            return existing
        }
        let controller = ReflectionRemoval(listingID: listingID, asset: asset)
        active[key] = controller
        return controller
    }

    @Published private(set) var work: ReflectionWork?
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    @Published private(set) var quote: ReflectionQuote?
    @Published private(set) var accountMatches = false
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var quoteID = UUID()
    private let ownerID: String?
    private var accountObserver: AnyCancellable?
    let listingID: UUID
    private let initialAsset: CaptureAsset
    var source: CaptureAsset { work?.source ?? initialAsset }
    var canPreview: Bool { isCurrentOwner && work?.resultPath != nil && work?.cancellationRequested != true }
    var resultURL: URL? { isCurrentOwner ? work?.resultPath.map(FileStore.url(fromRelativePath:)) : nil }
    private var isCurrentOwner: Bool { ownerID != nil && AuthStore.shared.userID == ownerID }

    private init(listingID: UUID, asset: CaptureAsset) {
        self.listingID = listingID
        self.initialAsset = asset
        self.ownerID = AuthStore.shared.userID
        self.accountMatches = ownerID != nil
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
        accountObserver = AuthStore.shared.$userID.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.accountMatches = self.isCurrentOwner
            if !self.accountMatches {
                self.task?.cancel()
                self.operationID = UUID()
                self.quoteID = UUID()
                self.isBusy = false
                self.task = nil
                self.quote = nil
            }
        }
    }

    func loadQuote(model: AppModel, listing: Listing) async {
        guard Config.useLiveBackend, isCurrentOwner else { return }
        let request = UUID(); quoteID = request
        do {
            guard await AuthStore.shared.ensureSession() else { return }
            try checkSession()
            let serverID = try await model.ensureServerListing(listing)
            try checkSession()
            let value = try await model.api.reflectionQuote(listingID: serverID)
            try checkSession()
            guard quoteID == request else { return }
            quote = value
        } catch is CancellationError { }
        catch { if isCurrentOwner && quoteID == request { self.error = error.localizedDescription } }
    }

    func start(clips: [ReflectionClip], model: AppModel, listing: Listing) {
        guard !isBusy else { return }
        launch {
            guard await AIConsent.shared.ensureGranted(), await AuthStore.shared.ensureSession(),
                  let owner = AuthStore.shared.userID else { return }
            try self.checkSession()
            let serverID = try await model.ensureServerListing(listing)
            try self.checkSession()
            if self.work == nil || self.work?.cancellationConfirmed == true {
                let quote = try await model.api.reflectionQuote(listingID: serverID)
                try self.checkSession()
                self.quote = quote
                guard quote.available, !clips.isEmpty, clips.count <= quote.remainingClips,
                      Self.valid(clips: clips, duration: self.source.durationS, maximum: min(4.8, quote.maxClipSeconds)),
                      clips.reduce(0, { $0 + $1.durationS }) <= quote.maximumSeconds else {
                    throw APIError.server(status: 402, code: "quota_exceeded", message: "Select fewer intervals to fit your available AI clips and this video's edit limit.")
                }
                let bytes = FileStore.fileSize(self.source.localURL)
                guard bytes > 0, Double(FileStore.freeSpaceBytes()) > Double(bytes) * 3 + 300_000_000 else {
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
            do {
                try await self.preserveOriginal()
                try self.checkOwner()
                try await self.process(model: model)
            } catch let failure as ReflectionVideo.Failure {
                try self.checkOwner()
                await self.refundUnusableResult(model: model, reason: failure.localizedDescription)
            } catch ProcessingFailure.providerFailed(let reason) {
                try self.checkOwner()
                await self.refundUnusableResult(model: model, reason: reason)
            } catch let failure as APIError where failure.status == 400 || failure.status == 402 {
                // A definitive clip rejection or exhausted batch budget cannot
                // produce a complete edit. Return earlier clips in this batch
                // too; network/auth failures and rate limits remain resumable.
                try self.checkOwner()
                await self.refundUnusableResult(model: model, reason: failure.localizedDescription)
            }
        }
    }

    func cancel(model: AppModel) {
        guard isCurrentOwner, let saved = work, !saved.applied else { return }
        // Preempt late work even if the phone cannot write its journal. The
        // server's idempotent tombstone must still be requested in that case.
        task?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        work?.cancellationRequested = true
        do { try checkpoint() } catch { self.error = "Saving the cancellation locally failed; requesting server cancellation. \(error.localizedDescription)" }
        task = nil
        isBusy = true
        task = Task { @MainActor in
            await ReflectionOperation.$id.withValue(operationID) {
                do {
                    try await self.confirmCancellation(model: model, batchID: saved.id)
                } catch is CancellationError { }
                catch {
                    if self.operationID == operationID && self.isCurrentOwner {
                        self.error = "Cancellation is not confirmed. Retry cancellation to return the edit's AI clips. \(error.localizedDescription)"
                    }
                }
                if self.operationID == operationID {
                    self.isBusy = false
                    self.task = nil
                }
            }
        }
    }

    func accept(model: AppModel, completion: @escaping (CaptureAsset) -> Void) {
        guard isCurrentOwner, !isBusy, let saved = work, saved.result != nil, !saved.cancellationRequested else { return }
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
                try self.checkOwner()
                guard receipt.provenance.recorded, receipt.provenance.id != nil else {
                    throw APIError.server(status: 503, code: "upstream", message: "The edit's disclosure could not be saved. Retry before using the result.")
                }
                self.work?.disclosure = receipt.disclosure
                self.work?.applied = true
                try self.checkpoint()
            }
            try self.checkOwner()
            guard let result = self.work?.result else { throw ReflectionVideo.Failure.exportFailed }
            guard model.listings.contains(where: { $0.id == self.listingID }),
                  model.assets[self.listingID] == nil || model.assets[self.listingID]?.id == saved.source.id
                    || model.assets[self.listingID]?.id == result.id else {
                throw APIError.server(status: 409, code: "conflict", message: "This listing's video changed while the edit was running. The saved original and edit are kept; choose which video to use before replacing it.")
            }
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
                try checkOwner()
                work?.pieces[i].inputPath = FileStore.relativePath(for: output)
                try checkpoint()
            }
            if work?.pieces[i].assetID == nil, let path = work?.pieces[i].inputPath {
                let id = try await upload(FileStore.url(fromRelativePath: path), serverID: saved.serverListingID)
                try checkOwner()
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
                try checkOwner()
                work?.pieces[i].job = job
                try checkpoint()
            }
            guard let job = work?.pieces[i].job else { throw APIError.decoding }
            if work?.pieces[i].outputPath == nil {
                let remote = try await poll(job, api: model.api)
                try checkOwner()
                let output = saved.directory.appendingPathComponent("output-\(clip.id.uuidString)-\(UUID().uuidString).mp4")
                let (temporary, response) = try await URLSession.shared.download(from: remote)
                try checkOwner()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https" else { throw APIError.badResponse(502) }
                try FileManager.default.moveItem(at: temporary, to: output)
                let probe = await MediaImporter.probe(url: output)
                try checkOwner()
                guard probe.hasVideoTrack, probe.isPlayable, FileStore.fileSize(output) > 0 else {
                    throw ReflectionVideo.Failure.noVideo
                }
                guard probe.duration.isFinite, abs(probe.duration - clip.durationS) <= 1 / max(1, saved.source.fps) + 0.001 else {
                    throw ReflectionVideo.Failure.changedDuration
                }
                let originalRatio = Double(saved.source.width) / Double(max(1, saved.source.height))
                let alteredRatio = Double(probe.width) / Double(max(1, probe.height))
                guard originalRatio > 0, alteredRatio > 0, abs(alteredRatio / originalRatio - 1) < 0.01 else {
                    throw ReflectionVideo.Failure.changedFraming
                }
                work?.pieces[i].outputPath = FileStore.relativePath(for: output)
                try checkpoint()
            }
        }
        try checkOwner()
        if work?.resultPath == nil {
            message = "Putting the edited intervals back into your video…"
            let output = saved.directory.appendingPathComponent("edited-\(UUID().uuidString).mp4")
            let replacements = try (work?.pieces ?? []).map { piece -> (ReflectionClip, URL) in
                guard let path = piece.outputPath else { throw ReflectionVideo.Failure.noVideo }
                return (piece.clip, FileStore.url(fromRelativePath: path))
            }
            try await ReflectionVideo.splice(source: saved.source.localURL, replacements: replacements, destination: output)
            try checkOwner()
            var result: CaptureAsset
            do {
                result = try await MediaImporter.makeAsset(from: output, isDrone: saved.source.isDrone, deleteOnFailure: false)
            } catch is CancellationError { throw CancellationError() }
            catch { throw ReflectionVideo.Failure.exportFailed }
            try checkOwner()
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
            let status = try await api.aiVideoStatus(job)
            try checkOwner()
            switch status {
            case .completed(let url):
                guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw APIError.invalidURL }
                return url
            case .failed(let message): throw ProcessingFailure.providerFailed(message)
            case .processing: try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw APIError.server(status: 503, code: "upstream", message: "This edit is still waiting. Retry to check the same jobs, or cancel to return your AI clips.")
    }

    private func upload(_ url: URL, serverID: UUID) async throws -> String {
        let probe = await MediaImporter.probe(url: url)
        try checkOwner()
        guard probe.hasVideoTrack, probe.isPlayable, probe.duration > 0, FileStore.fileSize(url) > 0 else {
            throw ReflectionVideo.Failure.noVideo
        }
        try checkOwner()
        // role original is photo-only in the existing upload contract. Both
        // complete videos use render; apply resolves their distinct asset IDs.
        let id = try await UploadManager.shared.upload(fileURL: url, listingID: serverID, role: "render",
            metadata: UploadMetadata(durationS: probe.duration, fps: probe.fps, width: probe.width,
                height: probe.height, bytes: FileStore.fileSize(url)))
        try checkOwner()
        return id
    }

    private enum ProcessingFailure: Error { case providerFailed(String) }

    private static func valid(clips: [ReflectionClip], duration: Double, maximum: Double) -> Bool {
        guard duration.isFinite, duration > 0, maximum.isFinite, maximum > 0, maximum < 5,
              Set(clips.map(\.id)).count == clips.count else { return false }
        var end = 0.0
        for clip in clips.sorted(by: { $0.startS < $1.startS }) {
            guard clip.startS.isFinite, clip.endS.isFinite, clip.startS >= end,
                  clip.endS <= duration, clip.durationS > 0, clip.durationS <= maximum else { return false }
            end = clip.endS
        }
        return true
    }

    /// Own a complete immutable original before the first provider request.
    /// The original capture remains untouched, even after accepting an edit.
    private func preserveOriginal() async throws {
        try checkOwner()
        guard let saved = work else { throw CancellationError() }
        if saved.source.localURL.deletingLastPathComponent().standardizedFileURL == saved.directory.standardizedFileURL {
            guard FileStore.fileSize(saved.source.localURL) > 0 else { throw ReflectionVideo.Failure.noVideo }
            return
        }
        let original = saved.source.localURL
        let destination = saved.directory.appendingPathComponent("original-\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension.isEmpty ? "mov" : original.pathExtension)
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: original, to: destination)
        }.value
        try checkOwner()
        guard FileStore.fileSize(destination) > 0, FileStore.fileSize(destination) == FileStore.fileSize(original) else {
            throw ReflectionVideo.Failure.noVideo
        }
        work?.source.localURL = destination
        work?.sourcePath = FileStore.relativePath(for: destination)
        try checkpoint()
    }

    private func refundUnusableResult(model: AppModel, reason: String) async {
        do {
            try checkOwner()
            guard let saved = work, !saved.applied else { return }
            work?.cancellationRequested = true
            do { try checkpoint() }
            catch is CancellationError { throw CancellationError() }
            catch { self.error = "The local journal could not be saved; requesting the refund from the server." }
            try await confirmCancellation(model: model, batchID: saved.id)
            if work?.cancellationConfirmed == true {
                let receiptWarning = error.map { " \($0)" } ?? ""
                error = "\(reason) This edit's AI clips were returned. Your original is unchanged.\(receiptWarning)"
            }
        } catch is CancellationError { }
        catch {
            if isCurrentOwner, ReflectionOperation.id == operationID {
                self.error = "\(reason) Returning the edit's AI clips is not confirmed. Retry cancellation. \(error.localizedDescription)"
            }
        }
    }

    private func confirmCancellation(model: AppModel, batchID: UUID) async throws {
        try checkOwner()
        do {
            try await model.api.cancelReflectionBatch(batchID)
            try checkOwner()
            work?.cancellationConfirmed = true
            message = "Cancelled. The original is unchanged and this edit uses no AI clips."
            error = nil
            do { try checkpoint() }
            catch is CancellationError { throw CancellationError() }
            catch { self.error = "The server confirmed cancellation and returned the AI clips, but its receipt could not be saved on this phone. \(error.localizedDescription)" }
        } catch let failure as APIError where failure.status == 409 {
            // Apply may have committed before its response was lost. The server
            // cannot refund an applied batch. Recover that exact receipt, but
            // never change the selected local video after the user chose Cancel.
            try checkOwner()
            guard let original = work?.originalServerAssetID, let altered = work?.resultServerAssetID else { throw failure }
            let receipt = try await model.api.applyReflectionBatch(batchID, originalAssetID: original, alteredAssetID: altered)
            try checkOwner()
            guard receipt.provenance.recorded, receipt.provenance.id != nil else { throw APIError.decoding }
            work?.disclosure = receipt.disclosure
            work?.applied = true
            work?.cancellationRequested = false
            work?.cancellationConfirmed = false
            message = "The server had already accepted this edit, so its AI clips could not be returned. Your selected video is unchanged. You can review and use the saved edit."
            error = nil
            do { try checkpoint() }
            catch is CancellationError { throw CancellationError() }
            catch { self.error = "The server's accepted-edit receipt could not be saved on this phone. \(error.localizedDescription)" }
        }
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        guard isCurrentOwner else { throw CancellationError() }
        if let current = ReflectionOperation.id, current != operationID { throw CancellationError() }
    }
    private func checkOwner() throws {
        try checkSession()
        guard let work, ownerID == work.ownerID else { throw CancellationError() }
    }
    private func checkpoint() throws { try checkOwner(); try work?.save() }
    private func launch(_ operation: @escaping @MainActor () async throws -> Void) {
        guard isCurrentOwner, !isBusy else { return }
        error = nil
        isBusy = true
        let operationID = UUID()
        self.operationID = operationID
        task = Task { @MainActor in
            await ReflectionOperation.$id.withValue(operationID) {
                do { try self.checkSession(); try await operation() }
                catch is CancellationError { }
                catch {
                    if self.operationID == operationID && self.isCurrentOwner { self.error = error.localizedDescription }
                }
                if self.operationID == operationID {
                    self.isBusy = false
                    self.task = nil
                }
            }
        }
    }
}
