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

    func edit(_ p: EnhancedPhoto, edit: String, style: String?, prompt: String?, batch: Bool,
              stagingReferenceID: String? = nil, progress: ((PhotoWorkQueue.Phase) -> Void)? = nil) async throws {
        try requireUnsentWork()
        progress?(.preparing)
        let api = model.api
        let directory = EnhancedPhoto.directory(for: listing.id)
        guard p.enhancedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw PhotoVersionHistory.Failure.changedVersion
        }
        var referenceBase64: String?
        if let stagingReferenceID {
            guard edit == "stage" else { throw PhotoVersionHistory.Failure.reviewRequired }
            let reference = try PhotoVersionHistory.stagingReference(id: stagingReferenceID, directory: directory)
            referenceBase64 = await AIImagePrep.jpegBase64(at: directory.appendingPathComponent(reference.imageFile),
                                                         maxDimension: 1024, quality: 0.85, maxBytes: 200_000)
            guard referenceBase64 != nil else { throw PhotoVersionHistory.Failure.missingImage }
            try requireUnsentWork()
        }
        let prior = p.originalURL == p.enhancedURL ? nil : p.originalURL.lastPathComponent
        let requested = try PhotoVersionHistory.trackExisting(id: p.id, imageFile: p.enhancedURL.lastPathComponent,
                                                           priorFile: prior, directory: directory)
        let context = try PhotoVersionHistory.editContext(for: requested.id, edit: edit, directory: directory)
        let parent = context.parent, sourceVersion = context.source
        guard let b64 = await AIImagePrep.jpegBase64(at: directory.appendingPathComponent(sourceVersion.imageFile),
                                                   maxDimension: 2048, quality: 0.9,
                                                   maxBytes: referenceBase64 == nil ? 1_000_000 : 800_000) else {
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
                progress?(.uploading)
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
        var pending: PhotoPendingEdit.Saved?
        if let owner, let workspace {
            pending = try PhotoPendingEdit.begin(request,
                identity: .init(actor: owner, library: workspace, listing: listing.id, sourceVersion: sourceVersion.id),
                directory: directory)
            request = pending!.request
        } else {
            guard listing.isSample else { throw CloudSyncError.identityChanged }
            request.idempotencyKey = UUID().uuidString
        }
        // Preparation can suspend. Recheck the original grant at the actual
        // provider boundary; revoke followed by grant cannot revive this batch.
        try requireUnsentWork()
        if let stagingReferenceID {
            _ = try PhotoVersionHistory.stagingReference(id: stagingReferenceID, directory: directory)
        }
        progress?(.generatingAndChecking)
        let result: AIPhotoEditResult
        do { result = try await api.aiPhotoEdit(request) }
        catch {
            // A definite admission refusal or final private review releases
            // only the local request slot. A closed review may already cost an
            // allowance; only the next explicit user edit starts a new attempt.
            // Unknown/pending/active holds keep the exact saved operation.
            if let failure = error as? APIError,
               failure.isValidation || failure.isQuota || failure.code == "photo_quality_refused"
                    || (failure.status == 422 && failure.code == "photo_quality_closed"),
               let pending { try? PhotoPendingEdit.finish(pending) }
            throw error
        }
        // This request was already sent. Keep its returned edit under the same
        // account/workspace; consent revocation fences the next unsent photo.
        try requireIdentity()
        progress?(.checkingReturnedImage)
        let raw = try await Task.detached(priority: .userInitiated) {
            guard let raw = Data(base64Encoded: result.imageBase64), UIImage(data: raw) != nil else {
                throw AIImagePrep.error("The AI didn't return an image. Try again.")
            }
            return raw
        }.value
        let imageExtension: String
        if raw.starts(with: [0xFF, 0xD8, 0xFF]) { imageExtension = "jpg" }
        else if raw.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { imageExtension = "png" }
        else if raw.count >= 12, raw.prefix(4) == Data("RIFF".utf8), raw.dropFirst(8).prefix(4) == Data("WEBP".utf8) { imageExtension = "webp" }
        else { throw AIImagePrep.error("The returned image format could not be saved. Your paid request is retained.") }
        try requireIdentity()
        progress?(.saving)
        let id = String(format: "%015d", Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString
        let version = try PhotoVersionHistory.saveEdit(jpeg: raw, id: id, parentID: parent.id,
            sourceID: sourceVersion.id, edit: edit, style: style, disclosure: result.disclosure,
            provenanceID: result.provenanceID, provenanceRecorded: result.provenanceRecorded,
            directory: directory, originalAssetID: request.originalAssetID, serverListingID: request.listingServerID?.uuidString,
            stagingReferenceID: stagingReferenceID, stagingBrief: edit == "stage" ? prompt : nil,
            imageExtension: imageExtension)
        let output = directory.appendingPathComponent(version.imageFile)
        // Observed by optional photo feedback (Notification.Name.rendpropPhotoEditSaved)
        // to note an automatic listing selection; it cannot change this edit.
        NotificationCenter.default.post(name: Notification.Name("rendprop.photoEditSaved"), object: nil,
                                        userInfo: ["directory": directory, "versionID": version.id])
        if let pending { try? PhotoPendingEdit.finish(pending) }
        if wasMain && version.canAutomaticallySelectForListing
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

    func start(title: String, photos: [EnhancedPhoto], edit: String, style: String?, prompt: String?,
               stagingReferenceID: String? = nil) -> Bool {
        guard consentIsCurrent else { return false }
        var background: UIBackgroundTaskIdentifier = .invalid
        let queue = PhotoWorkQueue.shared
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let started = queue.start(listingID: listing.id, title: title, photoIDs: photos.map(\.id),
            identityIsCurrent: { self.identityIsCurrent }, stopOnError: { error in
                Task { @MainActor in Analytics.trackAIFailure("photo_edit", step: edit, error: error) }
                let failure = AIFailure(error)
                // A busy or held saved review keeps its exact paid request.
                // Stop unsent photos instead of buying more pending edits.
                let savedReview = ["photo_quality_pending", "photo_quality_hold", "photo_quality_closed"].contains((error as? APIError)?.code ?? "")
                // A refused or unreachable generation service fails every photo
                // the same way; stop instead of uploading N more to fail N times.
                return savedReview || failure.isQuota || failure.isUnauthorized || failure.isServiceUnavailable || failure.isTrialCapacityUnavailable
                    || (error as? APIError)?.isPhotoPromptRefusal == true
            }, process: { id in
                guard let photo = byID[id] else { throw PhotoVersionHistory.Failure.missingImage }
                guard let jobID = queue.visibleJob?.id else { throw CloudSyncError.identityChanged }
                try await self.edit(photo, edit: edit, style: style, prompt: prompt, batch: photos.count > 1,
                                    stagingReferenceID: stagingReferenceID, progress: { phase in
                    queue.report(phase, jobID: jobID, photoID: id)
                })
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
            if let owner = self.owner { content.userInfo = ["recipient_user_id": owner] }
            try? await center.add(UNNotificationRequest(identifier: "photo-work.\(job.id.uuidString)",
                                                       content: content, trigger: nil))
        }
    }
}
