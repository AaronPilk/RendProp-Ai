import Foundation
import UIKit
import UserNotifications
import CryptoKit

/// One explicit edit intent. A lost response never authorizes a new request key.
/// The exact request and immutable source hashes survive app/background interruption.
struct PendingPhotoEdit: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        let owner: String
        let workspace: UUID?
        let listingID: UUID
    }
    struct Source: Codable, Equatable, Sendable {
        let parentID: String
        let sourceID: String
        let edit: String
        let style: String?
        let prompt: String?
        let space: String
        let stagingReferenceID: String?
        let parentSHA256: String
        let sourceSHA256: String
        let originalSHA256: String?
        let referenceSHA256: String?
    }
    struct Request: Codable, Equatable, Sendable {
        let imageBase64: String
        let mime: String
        let edit: String
        let style: String?
        let prompt: String?
        let stagingReferenceBase64: String?
        let stagingReferenceMime: String?
        let spaceType: String?
        let listingServerID: UUID?
        let label: String?
        let originalAssetID: String?
        let idempotencyKey: String

        init(_ value: AIPhotoEditRequest, key: String) {
            imageBase64 = value.imageBase64; mime = value.mime; edit = value.edit
            style = value.style; prompt = value.prompt
            stagingReferenceBase64 = value.stagingReferenceBase64
            stagingReferenceMime = value.stagingReferenceMime; spaceType = value.spaceType
            listingServerID = value.listingServerID; label = value.label
            originalAssetID = value.originalAssetID; idempotencyKey = key
        }
        var value: AIPhotoEditRequest {
            var value = AIPhotoEditRequest(imageBase64: imageBase64, mime: mime, edit: edit)
            value.style = style; value.prompt = prompt
            value.stagingReferenceBase64 = stagingReferenceBase64
            value.stagingReferenceMime = stagingReferenceMime; value.spaceType = spaceType
            value.listingServerID = listingServerID; value.label = label
            value.originalAssetID = originalAssetID; value.idempotencyKey = idempotencyKey
            return value
        }
    }
    enum Failure: LocalizedError {
        case unreadable, differentIntent, changedReceipt
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The saved photo request could not be read. No new edit was started. Contact support before trying again."
            case .differentIntent: return "An earlier photo edit is still unconfirmed. Recover it, or explicitly forget its request before starting a different edit."
            case .changedReceipt: return "The saved photo request changed. No new edit was started. Reopen this property before retrying."
            }
        }
    }
    let schema: Int
    let context: Context
    let source: Source
    let request: Request
    let requestSHA256: String
    let versionID: String
    let createdAt: Date
    private static let maximumBytes = 32 * 1024 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func encodeReceipt<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func file(_ context: Context) -> URL {
        let key = "photo.request.\(context.owner).\(context.workspace?.uuidString ?? "local").\(context.listingID)"
        return FileStore.documents.appendingPathComponent("photo-requests", isDirectory: true)
            .appendingPathComponent(digest(Data(key.utf8)) + ".json")
    }
    static func exists(_ context: Context) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file(context).path)) != nil
    }
    static func load(_ context: Context) throws -> Self? {
        let target = file(context)
        guard exists(context) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= maximumBytes
        else { throw Failure.unreadable }
        let data = try Data(contentsOf: target)
        guard let saved = try? JSONDecoder().decode(Self.self, from: data), saved.schema == 1,
              saved.context == context, UUID(uuidString: saved.request.idempotencyKey) != nil,
              saved.versionID.range(of: #"^[0-9]{15}-[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil,
              saved.request.edit == saved.source.edit, saved.request.style == saved.source.style,
              saved.request.prompt == saved.source.prompt, saved.request.spaceType == saved.source.space,
              saved.requestSHA256 == digest(try encodeReceipt(saved.request))
        else { throw Failure.unreadable }
        return saved
    }
    init(context: Context, source: Source, request: AIPhotoEditRequest) throws {
        schema = 1; self.context = context; self.source = source
        self.request = Request(request, key: UUID().uuidString)
        requestSHA256 = Self.digest(try Self.encodeReceipt(self.request))
        versionID = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString
        createdAt = Date()
    }
    func saveBeforeDispatch() throws {
        guard !Self.exists(context) else { throw Failure.changedReceipt }
        let target = Self.file(context), parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw Failure.unreadable }
        let data = try Self.encodeReceipt(self)
        guard data.count <= Self.maximumBytes else { throw Failure.unreadable }
        try data.write(to: target, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try Self.load(context) == self else { throw Failure.changedReceipt }
    }
    func clear() throws {
        guard try Self.load(context) == self else { throw Failure.changedReceipt }
        try FileManager.default.removeItem(at: Self.file(context))
    }
}

/// A captured account/workspace and immutable listing own every asynchronous edit.
/// No View state is read by work that continues after the screen is dismissed.
@MainActor
final class PhotoEditService {
    private let model: AppModel
    private let listing: Listing
    private let space: SpaceType
    private let owner = AuthStore.shared.userID
    private let revision = AuthStore.shared.syncSessionRevision
    private let workspace = WorkspaceContext.selectedOrgID
    private let consentRevision = AIConsent.shared.revocationRevision

    init(model: AppModel, listing: Listing, space: SpaceType) {
        self.model = model; self.listing = listing; self.space = space
    }
    var identityIsCurrent: Bool {
        AuthStore.shared.userID == owner && AuthStore.shared.syncSessionRevision == revision
            && WorkspaceContext.selectedOrgID == workspace
            && model.listings.contains { $0.id == listing.id && $0.cloudUnavailable != true }
    }
    private func requireIdentity() throws {
        try Task.checkCancellation()
        guard identityIsCurrent else { throw CloudSyncError.identityChanged }
    }
    private var consentIsCurrent: Bool {
        AIConsent.shared.isGranted && AIConsent.shared.revocationRevision == consentRevision
    }
    private func requireUnsentWork() throws {
        try requireIdentity()
        guard consentIsCurrent else { throw CancellationError() }
    }

    func edit(_ p: EnhancedPhoto, edit: String, style: String?, prompt: String?, batch: Bool,
              stagingReferenceID: String? = nil) async throws {
        try requireUnsentWork()
        let api = model.api
        let directory = EnhancedPhoto.directory(for: listing.id)
        guard p.enhancedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw PhotoVersionHistory.Failure.changedVersion
        }
        guard let owner else { throw CloudSyncError.identityChanged }
        let context = PendingPhotoEdit.Context(owner: owner, workspace: workspace, listingID: listing.id)
        let existing = try PendingPhotoEdit.load(context)
        var referenceBase64: String?
        if let stagingReferenceID {
            guard edit == "stage" else { throw PhotoVersionHistory.Failure.reviewRequired }
            let reference = try PhotoVersionHistory.stagingReference(id: stagingReferenceID, directory: directory)
            referenceBase64 = await AIImagePrep.jpegBase64(at: directory.appendingPathComponent(reference.imageFile),
                                                         maxDimension: 1024, quality: 0.85)
            guard referenceBase64 != nil else { throw PhotoVersionHistory.Failure.missingImage }
            try requireUnsentWork()
        }
        let prior = p.originalURL == p.enhancedURL ? nil : p.originalURL.lastPathComponent
        let parent = try PhotoVersionHistory.trackExisting(id: p.id, imageFile: p.enhancedURL.lastPathComponent,
                                                           priorFile: prior, directory: directory)
        let history = try PhotoVersionHistory.load(directory: directory)
        let sourceVersion: PhotoVersionHistory.Version
        if let existing, history.versions[existing.versionID] != nil {
            // Saving makes the parent superseded. A matching completed intent
            // may finish its bookkeeping without treating that as a new edit.
            guard existing.source.parentID == parent.id,
                  !history.hiddenFamilies.contains(parent.familyID),
                  let retainedSource = history.versions[existing.source.sourceID]
            else { throw PendingPhotoEdit.Failure.changedReceipt }
            sourceVersion = retainedSource
        } else {
            sourceVersion = try PhotoVersionHistory.source(for: parent.id, edit: edit, directory: directory)
        }
        guard let b64 = await AIImagePrep.jpegBase64(at: directory.appendingPathComponent(sourceVersion.imageFile),
                                                   maxDimension: 2048, quality: 0.9) else {
            throw AIImagePrep.error("Couldn't read that photo.")
        }
        try requireUnsentWork()
        let wasMain = model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
            == FileStore.relativePath(for: p.enhancedURL)
        let source = PendingPhotoEdit.Source(parentID: parent.id, sourceID: sourceVersion.id,
            edit: edit, style: style, prompt: prompt, space: space.rawValue,
            stagingReferenceID: stagingReferenceID,
            parentSHA256: PendingPhotoEdit.digest(try Data(contentsOf: p.enhancedURL)),
            sourceSHA256: PendingPhotoEdit.digest(try Data(contentsOf: directory.appendingPathComponent(sourceVersion.imageFile))),
            originalSHA256: try parent.originalFile.map { PendingPhotoEdit.digest(try Data(contentsOf: directory.appendingPathComponent($0))) },
            referenceSHA256: referenceBase64.map { PendingPhotoEdit.digest(Data($0.utf8)) })
        if let existing, existing.source != source { throw PendingPhotoEdit.Failure.differentIntent }
        var serverID: UUID?
        var originalAssetID: String?
        if let existing {
            serverID = existing.request.listingServerID
            originalAssetID = existing.request.originalAssetID
        } else if !listing.isSample {
            serverID = await model.serverListingIDForCompliance(listing.id)
            try requireUnsentWork()
            if let serverID, parent.originalVerified, let original = parent.originalFile {
                originalAssetID = await model.publishOriginalForDisclosure(
                    listingServerID: serverID, fileURL: directory.appendingPathComponent(original))
                try requireUnsentWork()
            }
        }
        var request = AIPhotoEditRequest(imageBase64: b64, mime: "image/jpeg", edit: edit)
        request.style = style; request.prompt = prompt; request.spaceType = space.rawValue
        request.stagingReferenceBase64 = referenceBase64
        request.stagingReferenceMime = referenceBase64 == nil ? nil : "image/jpeg"
        request.listingServerID = serverID
        request.label = PhotoStudioView.provenanceLabel(edit: edit, style: style, space: space)
        request.originalAssetID = originalAssetID
        let pending = try existing ?? PendingPhotoEdit(context: context, source: source, request: request)
        if existing == nil { try pending.saveBeforeDispatch() }
        // Preparation can suspend. Recheck the original grant at the actual
        // provider boundary; revoke followed by grant cannot revive this batch.
        try requireUnsentWork()
        if let stagingReferenceID {
            _ = try PhotoVersionHistory.stagingReference(id: stagingReferenceID, directory: directory)
        }
        let version: PhotoVersionHistory.Version
        if let saved = try PhotoVersionHistory.load(directory: directory).versions[pending.versionID] {
            guard saved.parentID == parent.id, saved.sourceID == sourceVersion.id,
                  saved.edit == edit, saved.style == style,
                  saved.originalAssetID == originalAssetID, saved.serverListingID == serverID?.uuidString,
                  FileStore.fileSize(directory.appendingPathComponent(saved.imageFile)) > 0
            else { throw PendingPhotoEdit.Failure.changedReceipt }
            version = saved // The prior local commit succeeded; never submit it again.
        } else {
        let result = try await api.aiPhotoEdit(pending.request.value)
        // This request was already sent. Keep its returned edit under the same
        // account/workspace; consent revocation fences the next unsent photo.
        try requireIdentity()
        let jpeg = try await Task.detached(priority: .userInitiated) {
            guard let raw = Data(base64Encoded: result.imageBase64), let image = UIImage(data: raw),
                  let jpeg = image.jpegData(compressionQuality: 0.97) else {
                throw AIImagePrep.error("The AI didn't return an image. Try again.")
            }
            return jpeg
        }.value
        try requireIdentity()
        version = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: pending.versionID, parentID: parent.id,
            sourceID: sourceVersion.id, edit: edit, style: style, disclosure: result.disclosure,
            provenanceID: result.provenanceID, provenanceRecorded: result.provenanceRecorded,
            directory: directory, originalAssetID: originalAssetID, serverListingID: serverID?.uuidString,
            stagingReferenceID: stagingReferenceID, stagingBrief: edit == "stage" ? prompt : nil)
        }
        try requireIdentity()
        try pending.clear() // Only after the image and immutable version are durably saved.
        let output = directory.appendingPathComponent(version.imageFile)
        if wasMain && !version.effects.contains("stage")
            && model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath == FileStore.relativePath(for: p.enhancedURL) {
            model.setMainPhoto(FileStore.relativePath(for: output), for: listing.id)
        }
        Analytics.track("ai_photo_edit", ["task": edit, "ok": "true", "batch": batch ? "true" : "false"])
        if !listing.isSample { FirstProjectGuide.recordAIPhotoEditCompleted() }
        if let provenanceID = version.provenanceID, let serverID {
            try requireIdentity()
            await model.attachAlteredPhotoForDisclosure(provenanceID: provenanceID,
                                                       listingServerID: serverID, fileURL: output)
            try requireIdentity()
        }
    }

    func start(title: String, photos: [EnhancedPhoto], edit: String, style: String?, prompt: String?,
               stagingReferenceID: String? = nil) -> Bool {
        guard consentIsCurrent else { return false }
        var background: UIBackgroundTaskIdentifier = .invalid
        let queue = PhotoWorkQueue.shared
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let started = queue.start(listingID: listing.id, title: title, photoIDs: photos.map(\.id),
            identityIsCurrent: { self.identityIsCurrent }, stopOnError: { error in
                let failure = AIFailure(error)
                return failure.isQuota || failure.isUnauthorized || (error is PendingPhotoEdit.Failure)
            }, process: { id in
                guard let photo = byID[id] else { throw PhotoVersionHistory.Failure.missingImage }
                try await self.edit(photo, edit: edit, style: style, prompt: prompt, batch: photos.count > 1,
                                    stagingReferenceID: stagingReferenceID)
            }, completion: { result in
                if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
                IdleTimer.release()
                self.notify(result)
            })
        if started {
            IdleTimer.hold()
            background = UIApplication.shared.beginBackgroundTask(withName: "rendprop.photo-edit") {
                Task { @MainActor in
                    queue.cancel()
                    if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
                }
            }
        }
        return started
    }

    private func notify(_ job: PhotoWorkQueue.Job) {
        guard identityIsCurrent, !job.interrupted else { return }
        Task { @MainActor in
            // The app's account preferences also govern local completions.
            // Missing/unavailable preferences fail closed; this never asks for
            // system permission or bypasses a muted render category.
            guard let api = self.model.api as? NotificationPrefsAPI else { return }
            let preferences: NotificationPrefs?
            do { preferences = try await api.notificationPrefs() }
            catch { return }
            guard self.identityIsCurrent, let preferences,
                  preferences.enabled, preferences.renders else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard self.identityIsCurrent, settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = job.failures.isEmpty ? "Your photos are ready" : "Photo edits finished with an issue"
            content.body = "\(job.title): \(job.done) of \(job.total) photos changed. Open Rendprop to review them."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "photo-work.\(job.id.uuidString)",
                                                       content: content, trigger: nil))
        }
    }
}
