import Foundation
import Combine
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Independent originals for an editing project. Never replaces the single
/// walkthrough in AppModel.assets and never removes a Photos-library original.
@MainActor final class ProductionVideoLibrary: ObservableObject {
    static let shared = ProductionVideoLibrary()
    struct Context: Hashable {
        let owner: String
        let listingID: UUID
        var key: String { "\(owner)|\(listingID.uuidString.lowercased())" }
    }
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let filename: String
        let name: String
        let duration: Double
        let fps: Double
        let width: Int
        let height: Int
        let bytes: Int64
        var shotID: String?
        var serverListingID: UUID?
        var assetID: String?
        var uploadStarted: Bool?
        var linkPending: Bool?
        var uploaded = false
        var failure: String?
        var link: ProductionVideoLink {
            .init(entryID: id, assetID: assetID, shotID: shotID, uploaded: uploaded, pending: linkPending == true)
        }
        var metadata: UploadMetadata {
            UploadMetadata(durationS: duration, fps: fps, width: width, height: height,
                           isDrone: false, hasGyro: false, bytes: bytes)
        }
    }
    @Published private(set) var groups: [String: [Entry]] = [:]
    @Published private(set) var activeContext: Context?
    @Published private(set) var activeEntry: UUID?
    @Published private(set) var storageError: String?
    private var observation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var contexts: [String: Context] = [:]
    private var completionHandlers: [String: () -> Void] = [:]

    private init() {
        observation = UploadManager.shared.$state.sink { [weak self] state in
            // The existing upload engine publishes on its main-thread control
            // path. Persist the ticket identity before a later queue item starts.
            self?.observe(state)
        }
    }

    nonisolated static func directory(_ context: Context) -> URL {
        FileStore.documents.appendingPathComponent("ProductionVideos", isDirectory: true)
            .appendingPathComponent(DirectUploader.sha256Hex(context.owner), isDirectory: true)
            .appendingPathComponent(context.listingID.uuidString.lowercased(), isDirectory: true)
    }
    func file(_ entry: Entry, context: Context) -> URL { Self.directory(context).appendingPathComponent(entry.filename) }
    func entries(_ context: Context) -> [Entry] { groups[context.key] ?? [] }

    func cancelForPropertyDeletion(_ listingID: UUID) {
        let removed = contexts.values.filter { $0.listingID == listingID }
        let paths = Set(removed.flatMap { context in entries(context).map { FileStore.relativePath(for: file($0, context: context)) } })
        if activeContext?.listingID == listingID { task?.cancel() }
        for context in removed { contexts.removeValue(forKey: context.key); groups.removeValue(forKey: context.key); completionHandlers[context.key] = nil }
        if let state = UploadManager.shared.state, state.status != .done, paths.contains(state.filePath) {
            UploadManager.shared.cancel()
        }
    }

    func load(_ context: Context) throws {
        contexts[context.key] = context
        if groups[context.key] == nil {
            let manifest = Self.directory(context).appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                let data = try Data(contentsOf: manifest)
                guard data.count < 1_000_000 else { throw ProductionPlanError.invalidDocument }
                let saved = try JSONDecoder().decode([Entry].self, from: data)
                guard saved.count <= 100, Set(saved.map(\.id)).count == saved.count,
                      saved.allSatisfy({ entry in
                          entry.filename == entry.id.uuidString.lowercased() + "." + URL(fileURLWithPath: entry.filename).pathExtension &&
                          ["mov", "mp4", "m4v"].contains(URL(fileURLWithPath: entry.filename).pathExtension) &&
                          entry.bytes > 0 && entry.duration.isFinite && entry.duration > 0 &&
                          (entry.assetID.map { UUID(uuidString: $0) != nil } ?? true)
                      }) else { throw ProductionPlanError.invalidDocument }
                groups[context.key] = saved
            } else { groups[context.key] = [] }
        }
        observe(UploadManager.shared.state)
    }

    func importFile(_ url: URL, name: String, context: Context) async throws {
        try load(context)
        guard entries(context).count < 100 else { throw LibraryError.full }
        let asset = try await MediaImporter.makeAsset(from: url, isDrone: false, deleteOnFailure: false)
        guard contexts[context.key] == context else { throw CancellationError() }
        // Another picker may finish while metadata loading suspends this call.
        // Recheck on the main actor before the move/append transaction.
        guard entries(context).count < 100 else { throw LibraryError.full }
        let id = UUID()
        let ext = url.pathExtension.lowercased()
        guard ["mov", "mp4", "m4v"].contains(ext) else { throw LibraryError.unsupported }
        let entry = Entry(id: id, filename: "\(id.uuidString.lowercased()).\(ext)", name: String(name.prefix(160)),
                          duration: asset.durationS, fps: asset.fps, width: asset.width, height: asset.height, bytes: asset.bytes)
        let directory = Self.directory(context)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaImporter.excludeFromBackup(directory)
        let destination = file(entry, context: context)
        // The picker already made a private persistent copy. Moving that copy
        // costs no second video-sized allocation and never touches Photos.
        try FileManager.default.moveItem(at: url, to: destination)
        var next = entries(context); next.append(entry)
        do { try persist(next, context: context) }
        catch {
            // Keep the copied video even when a full disk prevents the index
            // write. Its path is unique and the original is also still in Photos.
            storageError = "A clip was copied but its library record couldn’t be saved. Free some storage before importing again."
            throw error
        }
    }

    func assign(_ entryID: UUID, shotID: String?, context: Context) throws {
        var next = entries(context)
        guard let index = next.firstIndex(where: { $0.id == entryID }) else { return }
        next[index].shotID = shotID
        next[index].linkPending = true
        try persist(next, context: context)
    }

    func acknowledgeLinks(_ ids: Set<UUID>, context: Context) throws {
        guard !ids.isEmpty else { return }
        var next = entries(context)
        for index in next.indices where ids.contains(next[index].id) { next[index].linkPending = false }
        try persist(next, context: context)
    }

    func reconcileLinks(remote: ProductionPlan, pullSnapshot: [ProductionVideoLink], context: Context) throws {
        var next = entries(context)
        let reconciled = ProductionVideoLink.reconciling(next.map(\.link), pullSnapshot: pullSnapshot, remote: remote)
        for index in next.indices {
            next[index].shotID = reconciled[index].shotID
            next[index].linkPending = reconciled[index].pending
        }
        if next != entries(context) { try persist(next, context: context) }
    }

    func uploadAll(context: Context, serverListingID: UUID, api: APIClient, identity: String, onUploaded: @escaping () -> Void) {
        guard task == nil else { return }
        activeContext = context
        completionHandlers[context.key] = onUploaded
        task = Task {
            defer { task = nil; activeContext = nil; activeEntry = nil }
            for entry in entries(context) where !entry.uploaded {
                guard self.identityMatches(context: context, identity: identity) else { return }
                activeEntry = entry.id
                do {
                    let upload = UploadManager.shared
                    // Never replace another failed upload: it owns resumable
                    // parts and its reservation until its user handles it.
                    if let state = upload.state, state.status != .done,
                       state.filePath != FileStore.relativePath(for: file(entry, context: context)) {
                        throw UploadManager.UploadError.busy
                    }
                    var next = entries(context)
                    guard let index = next.firstIndex(where: { $0.id == entry.id }) else { return }
                    if let originalListing = next[index].serverListingID, originalListing != serverListingID { throw ProductionPlanError.invalidDocument }
                    let priorAttempt = next[index].uploadStarted == true
                    let engineOwnsTicket = upload.state?.filePath == FileStore.relativePath(for: file(entry, context: context)) &&
                        upload.state?.listingID == serverListingID && upload.state?.role == "capture" && upload.state?.status != .done
                    if priorAttempt && next[index].assetID == nil && !engineOwnsTicket { throw LibraryError.missingTransferState }
                    next[index].serverListingID = serverListingID; next[index].failure = nil; next[index].uploadStarted = true
                    try persist(next, context: context)
                    // A process may have died after the server completed but
                    // before the view saved its receipt. Ask about that exact
                    // ticket before considering another upload.
                    if let reserved = next[index].assetID, !engineOwnsTicket {
                        let ticket = try await api.renewUpload(assetID: reserved)
                        guard identityMatches(context: context, identity: identity) else { return }
                        guard ticket.assetID.caseInsensitiveCompare(reserved) == .orderedSame else { throw ProductionPlanError.invalidDocument }
                        if ticket.uploaded == true {
                            try recordReceipt(entry.id, assetID: reserved, context: context)
                            onUploaded()
                            continue
                        }
                        // The engine normally retains every unfinished ticket.
                        // Without its multipart receipt state, silently making
                        // another reservation could duplicate this upload.
                        throw LibraryError.missingTransferState
                    }
                    let assetID = try await upload.upload(fileURL: file(entry, context: context), listingID: serverListingID,
                        listingLocalID: nil, role: "capture", metadata: entry.metadata)
                    guard identityMatches(context: context, identity: identity) else { return }
                    try recordReceipt(entry.id, assetID: assetID, context: context)
                    onUploaded()
                } catch {
                    var next = entries(context)
                    if let index = next.firstIndex(where: { $0.id == entry.id }) {
                        next[index].failure = error.localizedDescription
                        do { try persist(next, context: context) }
                        catch { storageError = "Upload progress couldn’t be saved. Your video originals are still on this iPhone." }
                    }
                    return // The first error stops the bounded sequential queue.
                }
            }
        }
    }

    private func identityMatches(context: Context, identity: String) -> Bool {
        !Task.isCancelled && AuthStore.shared.isIdentified && AuthStore.shared.userID == context.owner &&
            "\(context.owner):\(AuthStore.shared.syncSessionRevision)" == identity
    }

    private func observe(_ state: UploadManager.State?) {
        guard let state, let serverID = state.listingID, state.role == "capture", let assetID = state.assetID,
              UUID(uuidString: assetID) != nil else { return }
        for context in contexts.values where context.owner == AuthStore.shared.userID {
            var next = entries(context)
            guard let index = next.firstIndex(where: {
                $0.serverListingID == serverID && FileStore.relativePath(for: file($0, context: context)) == state.filePath
            }) else { continue }
            next[index].assetID = assetID
            if state.status == .done, state.mode != "simulate" {
                if !next[index].uploaded && next[index].shotID != nil { next[index].linkPending = true }
                next[index].uploaded = true; next[index].failure = nil
            }
            if state.status == .failed { next[index].failure = state.failureMessage ?? "Upload needs another try. Your original is safe." }
            if next != entries(context) {
                do {
                    try persist(next, context: context)
                    if next[index].uploaded { completionHandlers[context.key]?() }
                }
                catch { storageError = "Upload progress couldn’t be saved. Your video originals are still on this iPhone." }
            }
        }
    }

    private func recordReceipt(_ id: UUID, assetID: String, context: Context) throws {
        guard UUID(uuidString: assetID) != nil, Config.useLiveBackend else { throw ProductionPlanError.invalidDocument }
        var next = entries(context)
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw ProductionPlanError.invalidDocument }
        if !next[index].uploaded && next[index].shotID != nil { next[index].linkPending = true }
        next[index].assetID = assetID; next[index].uploaded = true; next[index].failure = nil
        try persist(next, context: context)
    }

    private func persist(_ entries: [Entry], context: Context) throws {
        let directory = Self.directory(context)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaImporter.excludeFromBackup(directory)
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("library.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        groups[context.key] = entries
    }

    enum LibraryError: LocalizedError {
        case full, unsupported, missingTransferState
        var errorDescription: String? {
            switch self {
            case .full: return "This property already has 100 imported clips. Use Studio to organize the footage before importing more."
            case .unsupported: return "Choose a MOV, MP4 or M4V video. Your original is still in Photos."
            case .missingTransferState: return "This upload’s saved transfer state is unavailable. Your original is safe. Check uploaded files in Studio before starting another copy."
            }
        }
    }

    nonisolated static func removeLocalCopies(listingID: UUID) {
        let root = FileStore.documents.appendingPathComponent("ProductionVideos", isDirectory: true)
        guard let owners = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for owner in owners {
            try? FileManager.default.removeItem(at: owner.appendingPathComponent(listingID.uuidString.lowercased(), isDirectory: true))
        }
    }
}

/// Photos exports originals one at a time via file URLs. No video is loaded
/// into Data and the picker never changes the main walkthrough recording.
struct ProductionVideoPicker: UIViewControllerRepresentable {
    let onStart: () -> Void
    let onFile: (URL, String) async -> Void
    let onFinish: () -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos; config.selectionLimit = 12
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ProductionVideoPicker
        init(parent: ProductionVideoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            parent.onStart()
            Task { @MainActor in
                defer { parent.onFinish() }
                for result in results.prefix(12) {
                    do {
                        let url: URL = try await withCheckedThrowingContinuation { continuation in
                            result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                                guard let url else { continuation.resume(throwing: error ?? MediaImporter.ImportError.copyFailed); return }
                                let destination = MediaImporter.uniqueImportURL(originalName: url.lastPathComponent)
                                do {
                                    try FileManager.default.copyItem(at: url, to: destination)
                                    continuation.resume(returning: destination)
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                        await parent.onFile(url, result.itemProvider.suggestedName ?? "Imported video")
                    } catch { parent.onError("A video couldn’t be imported. \(error.localizedDescription) Your original is still in Photos.") }
                }
            }
        }
    }
}
