import Foundation
import UIKit
import AVFoundation

/// Foreground status/download only. Provider generation and composition belong
/// to the durable server worker after the enqueue acknowledgment.
@MainActor final class PropertyVideoJobRunner {
    static let shared = PropertyVideoJobRunner()
    private struct Watch {
        let work: ReelWorkJob
        let model: AppModel
        let api: PropertyVideoJobsAPI
        let context: PropertyVideoJobContext
        let revision: UInt64
        let consentRevision: UInt64
    }
    private var watches: [UUID: Watch] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var resuming: Set<UUID> = []

    private func requireCurrent(_ watch: Watch) throws {
        try Task.checkCancellation()
        guard watch.context.isCurrent, AuthStore.shared.syncSessionRevision == watch.revision,
              AIConsent.shared.revocationRevision == watch.consentRevision,
              watch.work.scope.isCurrent,
              watch.model.listings.contains(where: { $0.id == watch.context.localListingID && $0.serverID == watch.context.listingID && $0.cloudUnavailable != true }) else {
            throw PropertyVideoJobStore.Failure.identityChanged
        }
    }
    func enqueue(_ saved: PropertyVideoSavedJob, work: ReelWorkJob, model: AppModel, api: PropertyVideoJobsAPI) async throws {
        let watch = Watch(work: work, model: model, api: api, context: saved.context,
            revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)
        try requireCurrent(watch)
        watches[work.id] = watch
        work.adoptServerJob(saved)
        // The caller saved the exact operation before this POST. An uncertain
        // transport result remains saved and is retried only with the same ID.
        let reply: PropertyVideoJobReply
        do { reply = try await api.enqueuePropertyVideo(saved.request, context: saved.context) }
        catch let refusal as PropertyVideoCapacityRefusal {
            try requireCurrent(watch)
            guard saved.reply == nil, refusal.provesNoAdmission(for: saved.request) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
            var rejected = saved; rejected.capacityRefusal = refusal
            try PropertyVideoJobStore.save(rejected, documents: FileStore.documents)
            work.serverJob = rejected
            work.statusText = "This video couldn't start. Edit your photos or check your plan."
            throw refusal
        }
        try requireCurrent(watch)
        var accepted = saved; accepted.reply = try reply.checked(request: saved.request)
        try PropertyVideoJobStore.save(accepted, documents: FileStore.documents)
        work.adoptServerJob(accepted)
        watches[work.id] = watch
        schedule(watch)
    }
    func restore(work: ReelWorkJob, model: AppModel, api: PropertyVideoJobsAPI, context: PropertyVideoJobContext) {
        do {
            guard let saved = try PropertyVideoJobStore.load(context: context, documents: FileStore.documents) else { return }
            if saved.wasRefusedBeforeAdmission {
                work.serverJob = saved; work.phase = .failed
                work.failure = AIFailure(saved.capacityRefusal!, title: "Adjust your video setup")
                return
            }
            // A reviewed/downloaded master is ordinary retained local media.
            if let path = saved.localOutputRelativePath,
               let record = try? ListingVideoStore.load(for: FileStore.url(fromRelativePath: path)),
               record.ownerID?.lowercased() == context.actorID.uuidString.lowercased(), record.workspaceID == context.orgID,
               record.serverListingID == context.listingID {
                work.serverJob = saved
                work.reelURL = FileStore.url(fromRelativePath: path); work.lastReel = work.reelURL
                work.originalPhotoMotionShots = saved.reply?.result?.originalPhotoCount ?? 0
                work.phase = .done
                return
            }
            work.adoptServerJob(saved)
            let watch = Watch(work: work, model: model, api: api, context: context,
                revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)
            watches[work.id] = watch
            schedule(watch)
        } catch {
            work.phase = .failed; work.failure = AIFailure(error, title: "Check the saved video job")
        }
    }
    func resumeForeground() {
        for watch in watches.values where watch.context.isCurrent {
            if let previous = tasks[watch.work.id] {
                Task { [weak self] in await previous.value; self?.schedule(watch) }
            } else { schedule(watch) }
        }
    }
    func suspendForeground() {
        for task in tasks.values { task.cancel() }
    }
    func checkNow(_ work: ReelWorkJob) { if let watch = watches[work.id] { schedule(watch) } }
    func resume(_ work: ReelWorkJob) async {
        guard let watch = watches[work.id], let saved = work.serverJob,
              saved.reply?.mayResume == true, resuming.insert(work.id).inserted else { return }
        defer { resuming.remove(work.id) }
        do {
            try requireCurrent(watch)
            work.phase = .generating; work.failure = nil
            work.statusText = "Resuming this saved video. Finished clips will be reused."
            let reply = try await watch.api.resumePropertyVideoJob(saved)
            try requireCurrent(watch)
            var updated = saved; updated.reply = try reply.checked(request: saved.request, previous: saved.reply)
            try PropertyVideoJobStore.save(updated, documents: FileStore.documents)
            work.serverJob = updated
            if reply.isTerminal && reply.state != "ready" {
                work.phase = .failed; work.failure = AIFailure(PropertyVideoStopped(message: reply.message ?? "This saved video still needs attention."), title: "Couldn't resume the saved video")
            } else { work.adoptServerJob(updated); schedule(watch) }
        } catch {
            guard watch.context.isCurrent else { return }
            work.phase = .failed; work.failure = AIFailure(error, title: "Couldn't resume the saved video")
        }
    }
    func cancel(_ work: ReelWorkJob) async {
        guard let watch = watches[work.id], let saved = work.serverJob else { return }
        if saved.wasRefusedBeforeAdmission {
            work.phase = .failed; work.statusText = "This operation was closed before video generation. Edit the setup instead."
            return
        }
        do {
            try requireCurrent(watch)
            guard saved.reply != nil else {
                // Resolve an uncertain enqueue with its same operation before
                // cancellation. Never forget work that may already be paid.
                try await enqueue(saved, work: work, model: watch.model, api: watch.api)
                return await cancel(work)
            }
            let reply = try await watch.api.cancelPropertyVideoJob(saved)
            try requireCurrent(watch)
            var updated = saved; updated.reply = reply
            try PropertyVideoJobStore.save(updated, documents: FileStore.documents)
            work.serverJob = updated
            if reply.state == "ready" { schedule(watch); return }
            tasks[work.id]?.cancel(); work.phase = .failed
            work.failure = AIFailure(PropertyVideoStopped(), title: "Video stopped")
            work.statusText = "Future clip requests were stopped. Work already dispatched may still be charged."
        } catch { work.failure = AIFailure(error, title: "Couldn't confirm cancellation") }
    }
    private func schedule(_ watch: Watch) {
        guard tasks[watch.work.id] == nil, UIApplication.shared.applicationState == .active else { return }
        guard watch.work.serverJob?.wasRefusedBeforeAdmission != true else { return }
        // The first enqueue is owned by work.task. Reopen/resume must not race
        // it with another POST while its acknowledgment is still being retained.
        if watch.work.running && watch.work.serverJob?.reply == nil {
            watch.work.afterCurrentOperation { [weak self] in self?.schedule(watch) }
            return
        }
        tasks[watch.work.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[watch.work.id] = nil }
            do {
                try requireCurrent(watch)
                guard var saved = try PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents) else { return }
                if saved.reply == nil {
                    let reply = try await watch.api.enqueuePropertyVideo(saved.request, context: saved.context)
                    try requireCurrent(watch)
                    saved.reply = reply; try PropertyVideoJobStore.save(saved, documents: FileStore.documents)
                }
                while UIApplication.shared.applicationState == .active {
                    try requireCurrent(watch)
                    let reply = try await watch.api.propertyVideoJob(saved)
                    try requireCurrent(watch)
                    saved.reply = try reply.checked(request: saved.request, previous: saved.reply)
                    try PropertyVideoJobStore.save(saved, documents: FileStore.documents)
                    watch.work.serverJob = saved
                    watch.work.totalClips = reply.sourceCount
                    watch.work.completedClips = reply.completedSources ?? 0
                    watch.work.statusText = Self.status(reply)
                    if reply.state == "ready" {
                        try await retainReady(saved, watch: watch)
                        return
                    }
                    if reply.isTerminal {
                        watch.work.phase = .failed
                        watch.work.failure = AIFailure(PropertyVideoStopped(message: reply.state == "cancelled" ? "You stopped this video. Saved photos are unchanged." : "The saved job needs attention. No new video request was started."), title: "Video needs attention")
                        return
                    }
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                }
            } catch is CancellationError { return }
            catch let refusal as PropertyVideoCapacityRefusal {
                guard watch.context.isCurrent,
                      var rejected = try? PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents),
                      rejected.reply == nil, refusal.provesNoAdmission(for: rejected.request) else { return }
                rejected.capacityRefusal = refusal
                do { try PropertyVideoJobStore.save(rejected, documents: FileStore.documents) }
                catch { watch.work.failure = AIFailure(error, title: "Couldn't retain the saved refusal"); return }
                watch.work.serverJob = rejected; watch.work.phase = .failed
                watch.work.failure = AIFailure(refusal, title: "Adjust your video setup")
            }
            catch {
                guard watch.context.isCurrent else { return }
                // Network loss only pauses local status checks. The server job
                // continues; Check status/reopen reads the same operation.
                watch.work.statusText = "Your request is saved. Reopen or check status to reconnect; rendering continues after server acceptance."
                watch.work.failure = AIFailure(error, title: "Couldn't refresh video status")
            }
        }
    }
    private func retainReady(_ saved: PropertyVideoSavedJob, watch: Watch) async throws {
        guard let result = saved.reply?.result else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try result.check(request: saved.request)
        try requireCurrent(watch)
        watch.work.statusText = "Your video is ready — downloading for review…"
        let temporary = try await PropertyVideoJobHTTP.download(result, requireCurrent: { try self.requireCurrent(watch) })
        defer { try? FileManager.default.removeItem(at: temporary) }
        try requireCurrent(watch)
        let directory = FileStore.documents.appendingPathComponent("reels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(watch.context.localListingID.uuidString)-server-\(saved.request.operationID.uuidString).mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            guard try ListingVideoStore.digest(output) == result.sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
        let record: ListingVideoRecord
        if let retained = try? ListingVideoStore.load(for: output), retained.sha256 == result.sha256 { record = retained }
        else {
            record = try await ListingVideoPreparation.retain(output: output, listingID: watch.context.localListingID,
                ownerID: watch.context.actorID.uuidString.lowercased(), workspaceID: watch.context.orgID,
                serverListingID: watch.context.listingID, purpose: saved.request.purpose == "listing" ? .listing : .socialMedia,
                sources: result.sources, includesOpeningClip: false, brandingPolicy: result.brandingPolicy, music: result.music)
        }
        try requireCurrent(watch)
        guard record.width == result.width, record.height == result.height, abs(record.durationS - result.durationS) <= 0.1,
              record.bytes == result.bytes, record.sha256 == result.sha256 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try ListingVideoStore.retainServerAssets(record, outputAssetID: result.assetID.uuidString.lowercased(),
            posterAssetID: result.posterAssetID.uuidString.lowercased(), documents: FileStore.documents)
        try OriginalPhotoMotion.saveSummary(count: result.originalPhotoCount, for: output)
        var retained = saved; retained.localOutputRelativePath = FileStore.relativePath(for: output)
        try PropertyVideoJobStore.save(retained, documents: FileStore.documents)
        if record.canSelectForWebsite {
            try await watch.model.selectWebsiteVideo(record, for: watch.context.localListingID, onlyIfUnselected: true)
            try requireCurrent(watch)
        }
        watch.work.serverJob = retained
        watch.work.originalPhotoMotionShots = result.originalPhotoCount
        watch.work.reelURL = output; watch.work.lastReel = output
        watch.work.setPlaybackPlayer(AVPlayer(url: output)); watch.work.phase = .done
        watch.work.statusText = "Ready to review. Publishing is your choice."
        ReelCompletionNotice.post(success: true, identity: watch.work.noticeIdentity,
            listingID: watch.context.localListingID, jobID: watch.work.id)
    }
    static func status(_ reply: PropertyVideoJobReply) -> String {
        switch reply.state {
        case "queued": return "Your video is queued. You can leave the app."
        case "generating": return "Creating photo \(min(reply.sourceCount, (reply.completedSources ?? 0) + 1)) of \(reply.sourceCount)…"
        case "quality_review": return "Checking the property stays true to your photos…"
        case "composing": return "Putting your video together…"
        case "ready": return "Ready to download and review."
        default: return "Your saved video needs attention."
        }
    }
}

private struct PropertyVideoStopped: Error, LocalizedError {
    var message = "Future clip requests were stopped. Work already dispatched may still be charged."
    var errorDescription: String? { message }
}
