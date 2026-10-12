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
        jobs.filter { $0.isContextCurrent && !$0.bannerDismissed && ($0.running || $0.paused || $0.phase == .done || $0.phase == .failed) }
    }
    var currentJob: ReelWorkJob? { visibleJobs.first(where: { $0.running || $0.paused }) ?? visibleJobs.last }
    func dismissResult(listingID: UUID) { visibleJobs.first(where: { $0.listingID == listingID })?.dismissResult() }
    func reconcileIdentity() {
        for job in jobs where !job.isContextCurrent { job.cancel() }
    }
    func resumeForeground() {
        reconcileIdentity()
        for job in jobs { job.resumeForeground() }
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
    @Published var unreadableBatch = false
    @Published var recoveredRetryRequestID: String?
    @Published var unreadablePendingContext: PendingReelRequest.Context?
    @Published private(set) var paused = false
    @Published private(set) var running = false
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
    private var noticeIdentity: PushAccountIdentity?

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
            if self.phase == .generating || self.phase == .stitching { self.phase = .setup }
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
            self.statusText = "Paused by iPhone. Open Rendprop to continue the saved reel."
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
