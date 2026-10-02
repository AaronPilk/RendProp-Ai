import Foundation
import UIKit
import UserNotifications

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

    func edit(_ p: EnhancedPhoto, edit: String, style: String?, prompt: String?, batch: Bool) async throws {
        try requireUnsentWork()
        let api = model.api
        let directory = EnhancedPhoto.directory(for: listing.id)
        let prior = p.originalURL == p.enhancedURL ? nil : p.originalURL.lastPathComponent
        let parent = try PhotoVersionHistory.trackExisting(id: p.id, imageFile: p.enhancedURL.lastPathComponent,
                                                           priorFile: prior, directory: directory)
        let sourceVersion = try PhotoVersionHistory.source(for: parent.id, edit: edit, directory: directory)
        guard let b64 = await AIImagePrep.jpegBase64(at: directory.appendingPathComponent(sourceVersion.imageFile),
                                                   maxDimension: 2048, quality: 0.9) else {
            throw AIImagePrep.error("Couldn't read that photo.")
        }
        try requireUnsentWork()
        let wasMain = model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath
            == FileStore.relativePath(for: p.enhancedURL)
        var serverID: UUID?
        var originalAssetID: String?
        if !listing.isSample {
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
        request.listingServerID = serverID
        request.label = PhotoStudioView.provenanceLabel(edit: edit, style: style, space: space)
        request.originalAssetID = originalAssetID; request.idempotencyKey = UUID().uuidString
        // Preparation can suspend. Recheck the original grant at the actual
        // provider boundary; revoke followed by grant cannot revive this batch.
        try requireUnsentWork()
        let result = try await api.aiPhotoEdit(request)
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
        let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString
        let version = try PhotoVersionHistory.saveEdit(jpeg: jpeg, id: id, parentID: parent.id,
            sourceID: sourceVersion.id, edit: edit, style: style, disclosure: result.disclosure,
            provenanceID: result.provenanceID, provenanceRecorded: result.provenanceRecorded,
            directory: directory, originalAssetID: originalAssetID, serverListingID: serverID?.uuidString)
        let output = directory.appendingPathComponent(version.imageFile)
        if wasMain && !version.effects.contains("stage")
            && model.listings.first(where: { $0.id == listing.id })?.mainPhotoRelPath == FileStore.relativePath(for: p.enhancedURL) {
            model.setMainPhoto(FileStore.relativePath(for: output), for: listing.id)
        }
        Analytics.track("ai_photo_edit", ["task": edit, "ok": "true", "batch": batch ? "true" : "false"])
        if !listing.isSample { FirstProjectGuide.recordAIPhotoEditCompleted() }
        if let provenanceID = result.provenanceID, let serverID {
            try requireIdentity()
            await model.attachAlteredPhotoForDisclosure(provenanceID: provenanceID,
                                                       listingServerID: serverID, fileURL: output)
            try requireIdentity()
        }
    }

    func start(title: String, photos: [EnhancedPhoto], edit: String, style: String?, prompt: String?) -> Bool {
        guard consentIsCurrent else { return false }
        var background: UIBackgroundTaskIdentifier = .invalid
        let queue = PhotoWorkQueue.shared
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let started = queue.start(listingID: listing.id, title: title, photoIDs: photos.map(\.id),
            identityIsCurrent: { self.identityIsCurrent }, stopOnError: { error in
                let failure = AIFailure(error)
                return failure.isQuota || failure.isUnauthorized
            }, process: { id in
                guard let photo = byID[id] else { throw PhotoVersionHistory.Failure.missingImage }
                try await self.edit(photo, edit: edit, style: style, prompt: prompt, batch: photos.count > 1)
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
