import Foundation
import Combine
import UIKit
import AVFoundation

/// Reel execution and its visible result belong to the app, not a sheet.
/// Closing Reel Studio releases playback/recording only. The paid request and
/// exact ordered source JPEGs remain in the existing durable recovery records.
@MainActor
final class ReelWorkQueue: ObservableObject {
    static let shared = ReelWorkQueue()
    @Published private(set) var jobs: [ReelWorkJob] = []
    private var observations: [UUID: AnyCancellable] = [:]
    private var sceneObservers: [NSObjectProtocol] = []
    private var sceneIsActive = UIApplication.shared.applicationState == .active
    private var holdsIdleTimer = false

    private init() {
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true),
                               (UIApplication.willResignActiveNotification, false)] {
            sceneObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateScreenAwakeHold(isActive: active); if !active { PropertyVideoJobRunner.shared.suspendForeground() } }
            })
        }
    }

    /// One app-wide hold covers active work even after its editor is closed.
    /// Paused/background/cancelled work releases only this queue's own hold.
    func updateScreenAwakeHold(isActive: Bool? = nil) {
        if let isActive { sceneIsActive = isActive }
        let wanted = sceneIsActive && jobs.contains {
            $0.running && !$0.paused && $0.isContextCurrent && $0.task?.isCancelled != true
        }
        guard wanted != holdsIdleTimer else { return }
        holdsIdleTimer = wanted
        if wanted { IdleTimer.hold() } else { IdleTimer.release() }
    }

    /// Erasure waits for interrupted paid-request cleanup before removing files.
    /// A replacement account's job created during that wait is left alone.
    func cancelForLocalDataErasure() async {
        let outgoing = jobs
        try? await PropertyVideoJobCancellation.shared.request(reason: "local_data_erasure")
        for job in outgoing { job.cancel() }
        for job in outgoing { await job.task?.value }
        let outgoingIDs = Set(outgoing.map(\.id))
        for job in outgoing { job.clearErasedState(); observations.removeValue(forKey: job.id) }
        jobs.removeAll { outgoingIDs.contains($0.id) }
        updateScreenAwakeHold()
    }

    func job(for listing: Listing) -> ReelWorkJob {
        let scope = ReelWorkJob.Scope.current(listingID: listing.id)
        if let existing = jobs.first(where: { $0.scope == scope }) { return existing }
        let job = ReelWorkJob(scope: scope, title: listing.address.isEmpty ? "Your reel" : listing.address)
        jobs.append(job)
        observations[job.id] = job.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return job
    }
    var visibleJobs: [ReelWorkJob] {
        jobs.filter { $0.isContextCurrent && !$0.bannerDismissed && ($0.running || $0.isServerRendering || $0.paused || $0.phase == .done || $0.phase == .failed) }
    }
    var currentJob: ReelWorkJob? { visibleJobs.first(where: { $0.running || $0.isServerRendering || $0.paused }) ?? visibleJobs.last }
    func dismissResult(listingID: UUID) { visibleJobs.first(where: { $0.listingID == listingID })?.dismissResult() }
    func reconcileIdentity() {
        PropertyVideoJobCancellation.shared.consentWasRevoked()
        for job in jobs where !job.isContextCurrent { job.cancel() }
    }
    func restoreServerJobs(model: AppModel) {
        guard let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)), let org = WorkspaceContext.selectedOrgID,
              let api = model.api as? PropertyVideoJobsAPI else { return }
        for listing in model.listings where !listing.isSample && listing.cloudUnavailable != true {
            guard let serverID = listing.serverID else { continue }
            let context = PropertyVideoJobContext(localListingID: listing.id, listingID: serverID, actorID: actor, orgID: org)
            guard FileManager.default.fileExists(atPath: PropertyVideoJobStore.url(context: context, documents: FileStore.documents).path) else { continue }
            PropertyVideoJobRunner.shared.restore(work: job(for: listing), model: model, api: api, context: context)
        }
    }
    func resumeForeground() {
        PropertyVideoJobCancellation.shared.retryPending()
        reconcileIdentity()
        for job in jobs { job.resumeForeground() }
        PropertyVideoJobRunner.shared.resumeForeground()
    }
}

@MainActor
final class ReelWorkJob: ObservableObject, Identifiable {
    struct Scope: Hashable {
        let listingID: UUID
        let owner: String?
        let revision: UInt64
        let workspace: UUID?
        let consentRevision: UInt64
        @MainActor static func current(listingID: UUID) -> Self {
            Self(listingID: listingID, owner: AuthStore.shared.userID,
                 revision: AuthStore.shared.syncSessionRevision, workspace: WorkspaceContext.selectedOrgID,
                 consentRevision: AIConsent.shared.revocationRevision)
        }
        @MainActor var isCurrent: Bool {
            owner == AuthStore.shared.userID && revision == AuthStore.shared.syncSessionRevision
                && workspace == WorkspaceContext.selectedOrgID && AIConsent.shared.isGranted
                && consentRevision == AIConsent.shared.revocationRevision
        }
    }
    enum Phase { case setup, generating, stitching, done, failed, paused }
    /// Options are copied before execution. A dismissed sheet is never consulted
    /// when the same paid batch resumes after an OS execution-time expiration.
    struct Configuration {
        let extras: [URL]
        let captions: ReelTitleCard?
        let voice: Voiceover?
        let captionStyle: CaptionStyle
        let shotStyle: ReelComposer.ShotCaptionStyle
        let transition: ReelComposer.Transition
        var aspect: String? = nil
    }
    let id = UUID()
    let scope: Scope
    let title: String
    var listingID: UUID { scope.listingID }
    @Published var phase: Phase = .setup
    @Published var completedClips = 0
    @Published var originalPhotoMotionShots = 0
    @Published var totalClips = 0
    @Published var clipIssues: [ReelClipIssue] = []
    @Published var statusText = ""
    @Published var reelURL: URL?
    @Published var failure: AIFailure?
    @Published var lastReel: URL?
    @Published var parkedClips: PendingReelClips?
    @Published var pendingRequest: PendingReelRequest?
    @Published var pendingBatch: PendingReelBatch?
    @Published var serverJob: PropertyVideoSavedJob?
    var isServerRendering: Bool { serverJob != nil && phase == .generating }
    func adoptServerJob(_ saved: PropertyVideoSavedJob) {
        serverJob = saved; totalClips = saved.request.sources.count; phase = .generating; paused = false
        statusText = saved.reply.map(PropertyVideoJobRunner.status) ?? "Your request is saved. Checking server acceptance…"
        noticeIdentity = PushManager.currentIdentity
        endBackgroundHold(); ReelWorkQueue.shared.updateScreenAwakeHold()
    }
    @Published var unreadableBatch = false
    @Published var recoveredRetryRequestID: String?
    @Published var unreadablePendingContext: PendingReelRequest.Context?
    @Published private(set) var paused = false { didSet { ReelWorkQueue.shared.updateScreenAwakeHold() } }
    @Published private(set) var running = false { didSet { ReelWorkQueue.shared.updateScreenAwakeHold() } }
    @Published private(set) var bannerDismissed = false
    var player: AVPlayer?
    var isPresented = false
    /// A dismissed studio keeps its URL, not a decoded playback session.
    func setPlaybackPlayer(_ value: AVPlayer?) {
        player?.pause()
        player = isPresented ? value : nil
    }
    var configuration: Configuration?
    private(set) var task: Task<Void, Never>?
    private var operationID: UUID?
    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid
    private var backgroundHoldOperation: UUID?
    private var resumeWaiting = false
    private var resumeAction: (() -> Void)?
    private var followUp: (() -> Void)?
    private var identityCheck: (() -> Bool)?
    private(set) var noticeIdentity: PushAccountIdentity?

    init(scope: Scope, title: String) { self.scope = scope; self.title = title }
    var isContextCurrent: Bool { scope.isCurrent && (identityCheck?() ?? true) }
    /// Only finished, retained photos count. Stitching is a separate stage;
    /// 100% is reserved for a finished video that has actually been saved.
    var fraction: Double {
        if phase == .done { return 1 }
        guard totalClips > 0 else { return 0 }
        return min(1, Double(max(0, min(completedClips - clipIssues.count, totalClips))) / Double(totalClips))
    }
    var percent: Int { phase == .done ? 100 : min(99, Int((fraction * 100).rounded(.down))) }

    @discardableResult
    func start(identityIsCurrent: @escaping () -> Bool, resume: @escaping () -> Void,
               operation: @escaping @MainActor () async -> Void) -> Bool {
        guard task == nil, scope.isCurrent, identityIsCurrent() else {
            if task == nil { phase = .setup }
            return false
        }
        identityCheck = identityIsCurrent; resumeAction = resume
        followUp = nil; paused = false; bannerDismissed = false; running = true
        noticeIdentity = PushManager.currentIdentity
        let operationID = UUID(); self.operationID = operationID
        beginBackgroundHold()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation()
            guard self.operationID == operationID else { return }
            self.task = nil; self.running = false; self.operationID = nil
            self.endBackgroundHold()
            guard self.isContextCurrent else { self.resumeAction = nil; self.followUp = nil; self.identityCheck = nil; return }
            if self.paused { self.phase = .paused; return }
            let next = self.followUp; self.followUp = nil
            if let next { self.resumeAction = nil; self.identityCheck = nil; next(); return }
            self.resumeAction = nil; self.identityCheck = nil
            if self.serverJob == nil && (self.phase == .generating || self.phase == .stitching) { self.phase = .setup }
            if self.phase == .done || self.phase == .failed {
                ReelCompletionNotice.post(success: self.phase == .done, identity: self.noticeIdentity,
                    listingID: self.listingID, jobID: self.id)
            }
        }
        return true
    }
    func afterCurrentOperation(_ action: @escaping () -> Void) { followUp = action }
    func cancel() {
        paused = false; resumeAction = nil; followUp = nil
        task?.cancel(); endBackgroundHold()
        if task == nil { identityCheck = nil }
        ReelWorkQueue.shared.updateScreenAwakeHold()
    }
    func clearErasedState() {
        player?.pause(); player = nil; configuration = nil
        reelURL = nil; lastReel = nil; parkedClips = nil; pendingRequest = nil; pendingBatch = nil; serverJob = nil
        unreadablePendingContext = nil; recoveredRetryRequestID = nil; unreadableBatch = false
        resumeAction = nil; followUp = nil; identityCheck = nil; noticeIdentity = nil
        phase = .setup; statusText = ""; failure = nil; clipIssues = []
    }
    func dismissResult() { guard !running, !paused else { return }; bannerDismissed = true }

    /// iOS gives finite extra execution time. Stop local polling/composition on
    /// expiry, keep all paid receipts, and resume this same approved batch when
    /// the foreground returns. This does not promise execution after process kill.
    private func beginBackgroundHold() {
        guard backgroundHold == .invalid else { return }
        let operation = UUID(); backgroundHoldOperation = operation
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: "rendprop.reel") { [weak self] in
            guard let self, self.backgroundHoldOperation == operation else { return }
            guard self.running, self.phase != .done, self.phase != .failed else { self.endBackgroundHold(); return }
            self.paused = true; self.phase = .paused
            self.statusText = "Paused by iPhone. Open this listing's Reel Studio to continue the saved reel."
            self.task?.cancel()
            self.endBackgroundHold()
        }
    }
    private func endBackgroundHold() {
        let hold = backgroundHold; backgroundHold = .invalid; backgroundHoldOperation = nil
        guard hold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(hold)
    }
    func resumeForeground() {
        guard UIApplication.shared.applicationState == .active, paused, !resumeWaiting,
              isContextCurrent, resumeAction != nil else { return }
        resumeWaiting = true
        let previous = task
        Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.resumeWaiting = false
            guard self.paused, self.isContextCurrent, UIApplication.shared.applicationState == .active,
                  let resume = self.resumeAction else { return }
            self.paused = false; self.phase = .setup
            resume()
        }
    }
}
