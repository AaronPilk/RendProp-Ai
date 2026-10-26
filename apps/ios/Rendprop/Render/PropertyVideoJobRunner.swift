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
        let operationID: UUID
        let revision: UInt64
        let consentRevision: UInt64
    }
    private var watches: [UUID: Watch] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var resuming: Set<UUID> = []
    private var taskIDs: [UUID: UUID] = [:]
    // Only explicit Back-to-setup records resolved presentation retirement.
    // No journal, accepted request, retained media or server work is removed.
    private var retiredPresentations: [UUID: [UUID: PropertyVideoJobContext]] = [:]

    private func requireIdentity(_ watch: Watch) throws {
        try Task.checkCancellation()
        guard watch.context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == watch.revision,
              AIConsent.shared.revocationRevision == watch.consentRevision,
              watch.work.scope.owner.flatMap(UUID.init(uuidString:)) == watch.context.actorID,
              watch.work.scope.workspace == watch.context.orgID,
              watch.model.listings.contains(where: { $0.id == watch.context.localListingID && $0.serverID == watch.context.listingID && $0.cloudUnavailable != true }) else {
            throw PropertyVideoJobStore.Failure.identityChanged
        }
    }
    private func isRetired(_ saved: PropertyVideoSavedJob, work: ReelWorkJob) -> Bool {
        retiredPresentations[work.id]?[saved.request.operationID] == saved.context
    }
    private func requireCurrent(_ watch: Watch) throws {
        try requireIdentity(watch)
        guard watches[watch.work.id]?.operationID == watch.operationID,
              watches[watch.work.id]?.context == watch.context,
              retiredPresentations[watch.work.id]?[watch.operationID] != watch.context else { throw CancellationError() }
    }
    private func detach(_ watch: Watch) {
        guard watches[watch.work.id]?.operationID == watch.operationID,
              watches[watch.work.id]?.context == watch.context else { return }
        watches.removeValue(forKey: watch.work.id)
        taskIDs.removeValue(forKey: watch.work.id)
        tasks.removeValue(forKey: watch.work.id)?.cancel()
        watch.work.isCheckingServerStatus = false
    }
    private func attach(_ watch: Watch) throws {
        try requireIdentity(watch)
        guard retiredPresentations[watch.work.id]?[watch.operationID] != watch.context else { throw CancellationError() }
        if let old = watches[watch.work.id], old.operationID != watch.operationID || old.context != watch.context {
            guard !resuming.contains(watch.work.id) else { throw PropertyVideoProcessorFailure.operationPending }
            detach(old)
        }
        watches[watch.work.id] = watch
    }
    @discardableResult
    func retireResolvedPresentation(_ work: ReelWorkJob, saved: PropertyVideoSavedJob, model: AppModel) -> Bool {
        guard work.serverJob == saved, saved.mayReplaceAfterResolution,
              work.phase == .failed || work.phase == .done,
              work.isContextCurrent, saved.context.hasCurrentIdentity,
              work.listingID == saved.context.localListingID,
              model.listings.contains(where: { $0.id == saved.context.localListingID && $0.serverID == saved.context.listingID && $0.cloudUnavailable != true }),
              work.scope.owner.flatMap(UUID.init(uuidString:)) == saved.context.actorID,
              work.scope.workspace == saved.context.orgID, !resuming.contains(work.id) else { return false }
        if let watch = watches[work.id] {
            guard watch.operationID == saved.request.operationID, watch.context == saved.context,
                  (try? requireCurrent(watch)) != nil else { return false }
            detach(watch)
        } else if tasks[work.id] != nil { return false }
        retiredPresentations[work.id, default: [:]][saved.request.operationID] = saved.context
        work.isCheckingServerStatus = false
        work.serverStatusCheckNote = nil
        return true
    }

    /// A durable no-admission closure is a resolved local presentation, even
    /// after a cold launch has discarded the in-memory retirement map.
    private func presentClosedOperation(_ saved: PropertyVideoSavedJob, watch: Watch) throws -> Bool {
        let error: Error, title: String, message: String
        if saved.wasRefusedBeforeAdmission {
            error = saved.capacityRefusal!; title = "Adjust your video setup"
            message = "This video couldn't start. Edit your photos or check your plan."
        } else if saved.reply == nil, saved.abandoned?.matches(saved.request) == true {
            message = "This saved request was closed before video generation."
            error = PropertyVideoStopped(message: message); title = "Video request closed"
        } else { return false }
        try requireCurrent(watch)
        guard saved.context == watch.context, saved.request.operationID == watch.operationID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        detach(watch)
        watch.work.adoptServerJob(saved); watch.work.phase = .failed
        watch.work.statusText = message; watch.work.serverStatusCheckNote = nil
        watch.work.failure = AIFailure(error, title: title)
        return true
    }

    /// A new explicit read/cancel may reattach the same durable actor/library
    /// after renewal or withdrawal. Existing in-flight work keeps its old epoch.
    private func readWatch(_ old: Watch) throws -> Watch {
        let current = Watch(work: old.work, model: old.model, api: old.api, context: old.context, operationID: old.operationID,
            revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)
        try requireCurrent(current)
        watches[old.work.id] = current
        return current
    }
    func enqueue(_ saved: PropertyVideoSavedJob, work: ReelWorkJob, model: AppModel, api: PropertyVideoJobsAPI) async throws {
        let watch = Watch(work: work, model: model, api: api, context: saved.context, operationID: saved.request.operationID,
            revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)
        try requireIdentity(watch)
        guard saved.stopRequested != true, saved.abandoned == nil, !resuming.contains(work.id) else { throw PropertyVideoProcessorFailure.operationPending }
        try attach(watch)
        work.adoptServerJob(saved)
        // The caller saved the exact operation before this POST. An uncertain
        // transport result remains saved; recovery reads this exact operation.
        let reply: PropertyVideoJobReply
        do { reply = try await api.enqueuePropertyVideo(saved) }
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
        var restoring: Watch?
        do {
            guard let saved = try PropertyVideoJobStore.load(context: context, documents: FileStore.documents),
                  !isRetired(saved, work: work) else { return }
            let watch = Watch(work: work, model: model, api: api, context: context, operationID: saved.request.operationID,
                revision: AuthStore.shared.syncSessionRevision, consentRevision: AIConsent.shared.revocationRevision)
            restoring = watch
            try attach(watch)
            if try presentClosedOperation(saved, watch: watch) { return }
            // A reviewed/downloaded master is ordinary retained local media.
            if let path = saved.localOutputRelativePath,
               let record = try? ListingVideoStore.load(for: FileStore.url(fromRelativePath: path)),
               record.ownerID?.lowercased() == context.actorID.uuidString.lowercased(), record.workspaceID == context.orgID,
               record.serverListingID == context.listingID {
                detach(watch)
                work.serverJob = saved
                work.restoreRetainedResult(at: FileStore.url(fromRelativePath: path),
                    originalPhotoCount: saved.reply?.result?.originalPhotoCount ?? 0)
                return
            }
            work.adoptServerJob(saved)
            schedule(watch)
        } catch is CancellationError { return }
        catch {
            guard context.hasCurrentIdentity, work.isContextCurrent else { return }
            if let restoring, (try? requireCurrent(restoring)) == nil { return }
            work.phase = .failed; work.failure = AIFailure(error, title: "Check the saved video job")
        }
    }
    func resumeForeground() {
        for old in Array(watches.values) where old.context.hasCurrentIdentity {
            guard let watch = try? readWatch(old) else { continue }
            if let previous = tasks[watch.work.id] {
                Task { [weak self] in await previous.value; self?.schedule(watch) }
            } else { schedule(watch) }
        }
    }
    func suspendForeground() {
        for task in tasks.values { task.cancel() }
    }
    func checkNow(_ work: ReelWorkJob) {
        guard let old = watches[work.id], let watch = try? readWatch(old) else { return }
        work.isCheckingServerStatus = true
        work.serverStatusCheckNote = nil
        // Preserve a current download. A stale watcher is cancelled and fully
        // retires before the fresh identity-only read starts.
        if let previous = tasks[work.id], old.revision != watch.revision || old.consentRevision != watch.consentRevision {
            previous.cancel()
            Task { [weak self] in await previous.value; self?.schedule(watch) }
        } else { schedule(watch) }
    }
    func resume(_ work: ReelWorkJob) async {
        guard let old = watches[work.id], let watch = try? readWatch(old),
              resuming.insert(work.id).inserted else { return }
        defer { resuming.remove(work.id) }
        do {
            try requireCurrent(watch)
            guard let saved = try PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents),
                  saved.request == work.serverJob?.request, saved.reply?.mayResume == true else { throw PropertyVideoProcessorFailure.operationPending }
            guard saved.stopRequested != true else { throw PropertyVideoProcessorFailure.operationPending }
            if !saved.request.isPhotoMotion {
                guard await AIConsent.shared.ensureGranted() else { throw PropertyVideoProcessorFailure.declined }
            }
            try requireCurrent(watch)
            if saved.request.isPhotoMotion {
                guard saved.reply?.resumeConsentToken == "photo-motion-v1" else { throw PropertyVideoProcessorFailure.unknownSavedAuthority }
            } else if saved.reply?.resumeConsentToken == "property-video-jobs-v2" {
                _ = try await PropertyVideoProcessorConsent.shared.ensure(.known, context: saved.context)
                try requireCurrent(watch)
            } else if saved.reply?.resumeConsentToken != "property-video-jobs-v1" {
                throw PropertyVideoProcessorFailure.unknownSavedAuthority
            }
            guard let current = try PropertyVideoJobStore.load(context: saved.context, documents: FileStore.documents),
                  current.request == saved.request, current.stopRequested != true else { throw PropertyVideoProcessorFailure.operationPending }
            work.phase = .generating; work.failure = nil
            work.statusText = "Resuming this saved video. Finished clips will be reused."
            let reply = try await watch.api.resumePropertyVideoJob(saved)
            try requireCurrent(watch)
            var updated = saved; updated.reply = try reply.checked(request: saved.request, previous: saved.reply)
            try PropertyVideoJobStore.save(updated, documents: FileStore.documents)
            work.serverJob = updated
            if reply.isTerminal && reply.state != "ready" {
                work.phase = .failed; work.failure = AIFailure(PropertyVideoStopped(message: reply.boundedAttentionMessage ?? "This saved video still needs attention."), title: "Couldn't resume the saved video")
            } else { work.adoptServerJob(updated); schedule(watch) }
        } catch {
            guard (try? requireCurrent(watch)) != nil else { return }
            work.phase = .failed; work.failure = AIFailure(error, title: "Couldn't resume the saved video")
        }
    }
    func cancel(_ work: ReelWorkJob) async {
        guard let old = watches[work.id], let watch = try? readWatch(old),
              let saved = try? PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents),
              saved.request == work.serverJob?.request else { return }
        if saved.wasRefusedBeforeAdmission {
            work.phase = .failed; work.statusText = "This operation was closed before video generation. Edit the setup instead."
            return
        }
        do {
            try requireCurrent(watch)
            var stopped = saved
            stopped.stopRequested = true
            try PropertyVideoJobStore.save(stopped, documents: FileStore.documents)
            work.serverJob = stopped
            if stopped.reply == nil {
                // GET first; only an explicit abandon resolves an unaccepted
                // operation. An accepted winner is cancelled below, never replayed.
                stopped = try await reconcile(stopped, watch: watch, abandon: true)
                if stopped.abandoned != nil || stopped.wasRefusedBeforeAdmission {
                    tasks[work.id]?.cancel(); work.phase = .failed
                    work.statusText = "This saved request was closed before video generation."
                    work.failure = AIFailure(PropertyVideoStopped(message: work.statusText), title: "Video request closed")
                    return
                }
            }
            let reply = try await watch.api.cancelPropertyVideoJob(stopped)
            try requireCurrent(watch)
            var updated = stopped; updated.reply = try reply.checked(request: stopped.request, previous: stopped.reply)
            try PropertyVideoJobStore.save(updated, documents: FileStore.documents)
            work.serverJob = updated
            if reply.state == "ready" { try await retainReady(updated, watch: watch); return }
            tasks[work.id]?.cancel(); work.phase = .failed
            work.failure = AIFailure(PropertyVideoStopped(), title: "Video stopped")
            work.statusText = "Future clip requests were stopped. Work already dispatched may still be charged."
        } catch {
            guard (try? requireCurrent(watch)) != nil else { return }
            work.failure = AIFailure(error, title: "Couldn't confirm cancellation")
        }
    }
    private func reconcile(_ saved: PropertyVideoSavedJob, watch: Watch, abandon: Bool) async throws -> PropertyVideoSavedJob {
        var current = saved
        var lookup = try await watch.api.propertyVideoOperation(current, abandon: false).checked(request: current.request)
        try requireCurrent(watch)
        if lookup.job == nil, !lookup.operationClosed, abandon {
            lookup = try await watch.api.propertyVideoOperation(current, abandon: true).checked(request: current.request)
            try requireCurrent(watch)
        }
        if let job = lookup.job { current.reply = try job.checked(request: current.request, previous: current.reply) }
        else if let closure = lookup.abandonment { current.abandoned = closure }
        else if lookup.operationClosed, lookup.closedReason == "capacity_refused" {
            current.capacityRefusal = .init(operationID: current.request.operationID, listingID: current.request.listingID,
                selectedLibraryOrgID: current.request.expectedOrgID, status: 402, code: "capacity_refused", operationClosed: true,
                message: "This saved video was not admitted. Edit the setup or check your plan.", observedAt: Date())
        } else { throw PropertyVideoProcessorFailure.operationPending }
        try PropertyVideoJobStore.save(current, documents: FileStore.documents)
        watch.work.serverJob = current
        return current
    }
    private func schedule(_ watch: Watch) {
        guard (try? requireCurrent(watch)) != nil,
              tasks[watch.work.id] == nil, UIApplication.shared.applicationState == .active else { return }
        guard watch.work.serverJob?.wasRefusedBeforeAdmission != true, watch.work.serverJob?.abandoned == nil else { return }
        // The first enqueue is owned by work.task. Reopen/resume must not race
        // it with another POST while its acknowledgment is still being retained.
        if watch.work.running && watch.work.serverJob?.reply == nil {
            watch.work.afterCurrentOperation { [weak self] in self?.schedule(watch) }
            return
        }
        let taskID = UUID()
        taskIDs[watch.work.id] = taskID
        tasks[watch.work.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskIDs[watch.work.id] == taskID {
                    self.tasks[watch.work.id] = nil
                    self.taskIDs[watch.work.id] = nil
                    watch.work.isCheckingServerStatus = false
                }
            }
            do {
                try requireCurrent(watch)
                guard var saved = try PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents),
                      saved.request.operationID == watch.operationID else { return }
                if saved.stopRequested == true { await cancel(watch.work); return }
                if saved.reply == nil { saved = try await reconcile(saved, watch: watch, abandon: false) }
                if try presentClosedOperation(saved, watch: watch) { return }
                guard saved.reply != nil else { throw PropertyVideoProcessorFailure.operationPending }
                while UIApplication.shared.applicationState == .active {
                    try requireCurrent(watch)
                    let reply = try await watch.api.propertyVideoJob(saved)
                    try requireCurrent(watch)
                    saved.reply = try reply.checked(request: saved.request, previous: saved.reply)
                    try PropertyVideoJobStore.save(saved, documents: FileStore.documents)
                    watch.work.serverJob = saved
                    watch.work.lastServerStatusCheck = Date()
                    watch.work.isCheckingServerStatus = false
                    watch.work.serverStatusCheckNote = nil
                    watch.work.totalClips = reply.sourceCount
                    watch.work.completedClips = reply.renderedSourceCount
                    watch.work.statusText = Self.status(reply)
                    if reply.state == "ready" {
                        try await retainReady(saved, watch: watch)
                        return
                    }
                    if reply.isTerminal {
                        watch.work.phase = .failed
                        watch.work.failure = AIFailure(PropertyVideoStopped(message: reply.state == "cancelled" ? "You stopped this video. Saved photos are unchanged." : (reply.boundedAttentionMessage ?? "The saved job needs attention. No new video request was started.")), title: "Video needs attention")
                        return
                    }
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                }
            } catch is CancellationError { return }
            catch let refusal as PropertyVideoCapacityRefusal {
                guard (try? requireCurrent(watch)) != nil,
                      var rejected = try? PropertyVideoJobStore.load(context: watch.context, documents: FileStore.documents),
                      rejected.request.operationID == watch.operationID, rejected.reply == nil, refusal.provesNoAdmission(for: rejected.request) else { return }
                rejected.capacityRefusal = refusal
                do { try PropertyVideoJobStore.save(rejected, documents: FileStore.documents) }
                catch { watch.work.failure = AIFailure(error, title: "Couldn't retain the saved refusal"); return }
                watch.work.serverJob = rejected; watch.work.phase = .failed
                watch.work.failure = AIFailure(refusal, title: "Adjust your video setup")
            }
            catch {
                guard (try? requireCurrent(watch)) != nil else { return }
                // Network loss only pauses local status checks. The server job
                // continues; Check status/reopen reads the same operation.
                watch.work.statusText = "Your request is saved. Reopen or check status to reconnect; rendering continues after server acceptance."
                watch.work.serverStatusCheckNote = "Couldn't refresh just now. Your saved request is kept; try again."
                watch.work.failure = AIFailure(error, title: "Couldn't refresh video status")
            }
        }
    }
    private func retainReady(_ saved: PropertyVideoSavedJob, watch: Watch) async throws {
        guard let result = saved.reply?.result else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        try result.check(request: saved.request)
        if let opening = result.opening, let reply = saved.reply {
            _ = try opening.checked(actorID: saved.context.actorID, physicalOrgID: reply.orgID,
                selectedLibraryOrgID: saved.context.orgID, listingID: saved.context.listingID, aspect: saved.request.aspect)
        }
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
                sources: result.sources, includesOpeningClip: result.opening != nil, brandingPolicy: result.brandingPolicy, music: result.music,
                sourceMode: result.sourceMode, compositionProfile: result.compositionProfile, fps: result.fps, totalFrames: result.totalFrames, sourceMotions: result.sourceMotions, opening: result.opening)
        }
        try requireCurrent(watch)
        guard record.opening == result.opening, record.hasValidMotionIdentity, record.sourceMode == result.sourceMode, record.compositionProfile == result.compositionProfile,
              (record.fps == result.fps || (!saved.request.isPhotoMotion && record.fps == nil)), record.totalFrames == result.totalFrames, record.sourceMotions == result.sourceMotions, record.width == result.width, record.height == result.height, abs(record.durationS - result.durationS) <= 0.1,
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
        if reply.sourceMode == PhotoMotionContract.mode {
            switch reply.state {
            case "queued": return "Preparing Photo motion…"
            case "generating": return "Rendering your video…"
            case "quality_review": return "Checking your Photo motion video…"
            case "composing": return "Finishing your video…"
            case "ready": return "Ready to download and review."
            default: return "Your saved Photo motion video needs attention."
            }
        }
        switch reply.state {
        case "queued": return "Your video is queued. You can leave the app."
        case "generating": return "Animating your photos · \(min(reply.sourceCount, max(0, reply.completedSources ?? 0))) of \(reply.sourceCount) finished"
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
