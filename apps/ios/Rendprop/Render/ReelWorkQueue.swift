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
        let job = ReelWorkJob(scope: scope, title: listing.address.isEmpty ? "Your video" : listing.address)
        jobs.append(job)
        observations[job.id] = job.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return job
    }
    /// Retained results stay available to an exact notification/review intent
    /// even when their historical completion is no longer a global HUD event.
    var reviewableJobs: [ReelWorkJob] {
        jobs.filter { $0.isContextCurrent && ($0.running || $0.isServerRendering || $0.paused || $0.phase == .done || $0.phase == .failed) }
    }
    var visibleJobs: [ReelWorkJob] {
        reviewableJobs.filter { !$0.bannerDismissed && !$0.isReadyBannerSuppressed }
    }
    var currentJob: ReelWorkJob? { visibleJobs.first(where: { $0.running || $0.isServerRendering || $0.paused }) ?? visibleJobs.last }
    func dismissResult(jobID: UUID) { visibleJobs.first(where: { $0.id == jobID })?.dismissResult() }
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
        var sourceMode: String? = nil
    }
    let id = UUID()
    private(set) var activityStartedAt: Date?
    private(set) var activityOperationID = UUID()
    let scope: Scope
    let title: String
    var listingID: UUID { scope.listingID }
    @Published var phase: Phase = .setup {
        didSet {
            guard oldValue != phase else { return }
            readyBannerCheckID = UUID(); readyBannerCheckPending = false
            bannerDismissed = false
            if phase != .done { restoredRetainedResult = false }
            if phase == .done { reconcileReadyBannerDismissal() }
        }
    }
    @Published var completedClips = 0
    @Published var originalPhotoMotionShots = 0
    @Published var totalClips = 0
    @Published var clipIssues: [ReelClipIssue] = []
    @Published var statusText = ""
    @Published var reelURL: URL? {
        didSet {
            guard oldValue != reelURL else { return }
            readyOutputDidChange()
        }
    }
    @Published var failure: AIFailure?
    @Published var lastReel: URL? {
        didSet {
            guard reelURL == nil, oldValue != lastReel else { return }
            readyOutputDidChange()
        }
    }
    @Published var parkedClips: PendingReelClips?
    @Published var pendingRequest: PendingReelRequest?
    @Published var pendingBatch: PendingReelBatch?
    @Published var serverJob: PropertyVideoSavedJob?
    @Published var isCheckingServerStatus = false
    @Published var lastServerStatusCheck: Date?
    @Published var serverStatusCheckNote: String?
    var usesPhotoMotion: Bool { serverJob?.request.isPhotoMotion ?? (configuration?.sourceMode == PhotoMotionContract.mode) }
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
    @Published private(set) var running = false {
        didSet {
            ReelWorkQueue.shared.updateScreenAwakeHold()
            guard oldValue != running else { return }
            readyBannerCheckID = UUID(); readyBannerCheckPending = false
            if !running, phase == .done { reconcileReadyBannerDismissal() }
        }
    }
    @Published private(set) var bannerDismissed = false
    @Published private(set) var restoredRetainedResult = false
    @Published private(set) var readyBannerCheckPending = false
    var isReadyBannerSuppressed: Bool {
        phase == .done && !running && !paused && (restoredRetainedResult || readyBannerCheckPending)
    }

    /// Opening already-retained media is review, not another completion event.
    /// Re-restoring the same freshly completed result preserves its current HUD.
    func restoreRetainedResult(at output: URL, originalPhotoCount: Int) {
        let historical = restoredRetainedResult || phase != .done || (reelURL ?? lastReel) != output
        reelURL = output; lastReel = output
        originalPhotoMotionShots = originalPhotoCount
        restoredRetainedResult = historical
        phase = .done
    }
    private func readyOutputDidChange() {
        readyBannerCheckID = UUID(); readyBannerCheckPending = false
        bannerDismissed = false; restoredRetainedResult = false
        if phase == .done { reconcileReadyBannerDismissal() }
    }
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
    private struct ReadyBannerReceipt: Codable {
        let path: String
        let sha256: String
    }
    private var readyBannerCheckID = UUID()

    /// Session renewal creates a fresh queue scope. A dismissed result remains
    /// dismissed only for this actor/library/listing and these exact file bytes.
    /// Hashing happens off the main actor, never in SwiftUI's banner body.
    private var readyBannerStorageKey: String? {
        guard let owner = scope.owner.flatMap(UUID.init(uuidString:)) else { return nil }
        return "reel.ready-banner.v1.\(owner.uuidString.lowercased()).\(scope.workspace?.uuidString.lowercased() ?? "local").\(listingID.uuidString.lowercased())"
    }
    private func reconcileReadyBannerDismissal(persist: Bool = false) {
        readyBannerCheckID = UUID(); readyBannerCheckPending = false
        guard phase == .done, !running, !paused, isContextCurrent,
              let key = readyBannerStorageKey, let output = reelURL ?? lastReel, output.isFileURL else { return }
        let saved = UserDefaults.standard.data(forKey: key).flatMap { bytes -> ReadyBannerReceipt? in
            guard bytes.count <= 4096 else { return nil }
            return try? JSONDecoder().decode(ReadyBannerReceipt.self, from: bytes)
        }
        guard persist || saved?.path == output.standardizedFileURL.path else { return }
        // Suppress synchronously while an existing exact-path receipt is
        // checked. A failed hash releases suppression; it never hides new work.
        readyBannerCheckPending = !persist
        let checkID = readyBannerCheckID
        Task { @MainActor [weak self] in
            let digest = await Task.detached(priority: .utility) {
                guard let before = try? FileManager.default.attributesOfItem(atPath: output.path),
                      before[.type] as? FileAttributeType == .typeRegular,
                      let count = before[.size] as? NSNumber, count.int64Value > 0,
                      let modified = before[.modificationDate] as? Date,
                      let fileID = before[.systemFileNumber] as? NSNumber,
                      let sha = try? ListingVideoStore.digest(output),
                      let after = try? FileManager.default.attributesOfItem(atPath: output.path),
                      after[.type] as? FileAttributeType == .typeRegular,
                      after[.size] as? NSNumber == count, after[.systemFileNumber] as? NSNumber == fileID,
                      after[.modificationDate] as? Date == modified else { return nil as String? }
                return sha
            }.value
            guard let self, self.readyBannerCheckID == checkID else { return }
            self.readyBannerCheckPending = false
            guard self.phase == .done,
                  !self.running, !self.paused, self.isContextCurrent,
                  (self.reelURL ?? self.lastReel) == output, let digest,
                  digest.utf8.count == 64 else { return }
            if persist {
                guard self.bannerDismissed,
                      let bytes = try? JSONEncoder().encode(ReadyBannerReceipt(path: output.standardizedFileURL.path, sha256: digest)),
                      bytes.count <= 4096 else { return }
                UserDefaults.standard.set(bytes, forKey: key)
            } else if saved?.sha256 == digest {
                self.bannerDismissed = true
            }
        }
    }

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
        activityStartedAt = Date(); activityOperationID = UUID()
        identityCheck = identityIsCurrent; resumeAction = resume
        followUp = nil; paused = false; bannerDismissed = false; restoredRetainedResult = false; running = true
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
        readyBannerCheckID = UUID(); readyBannerCheckPending = false; restoredRetainedResult = false
        if let key = readyBannerStorageKey { UserDefaults.standard.removeObject(forKey: key) }
        player?.pause(); player = nil; configuration = nil
        reelURL = nil; lastReel = nil; parkedClips = nil; pendingRequest = nil; pendingBatch = nil; serverJob = nil
        isCheckingServerStatus = false; lastServerStatusCheck = nil; serverStatusCheckNote = nil
        unreadablePendingContext = nil; recoveredRetryRequestID = nil; unreadableBatch = false
        resumeAction = nil; followUp = nil; identityCheck = nil; noticeIdentity = nil
        phase = .setup; statusText = ""; failure = nil; clipIssues = []
    }
    func dismissResult() {
        guard !running, !paused, !isServerRendering, isContextCurrent,
              phase == .done || phase == .failed else { return }
        bannerDismissed = true
        if phase == .done { reconcileReadyBannerDismissal(persist: true) }
    }

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

// MARK: - Scoped activity presentation (no execution or admission authority)
struct NativeActivityScope: Codable, Equatable {
    let actor: UUID?
    let library: UUID?
}
struct NativeActivityEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case photos, video, aerial, analysis, voice, tour }
    enum State: String, Codable {
        case working, waiting, attention, ready, failed, stopped
        var isActive: Bool { self == .working || self == .waiting || self == .attention }
    }
    let id: String
    let scope: NativeActivityScope
    let listingID: UUID
    var listingTitle: String
    let kind: Kind
    var state: State
    var stage: String
    var completed: Int?
    var total: Int?
    var startedAt: Date?
    var firstObservedAt: Date
    var progressToken: String? = nil
    var lastProgressAt: Date?
    var lastCheckedAt: Date? = nil
    var milestoneCompleted: Int? = nil
    var aerialProgressVersion: Int? = nil
    var checkFailed: Bool? = nil
    var expectsStatusChecks: Bool? = nil
    var countUnit: String? = nil
    var progressKind: String? = nil
    var isAerialAwaitingReview: Bool { kind == .aerial && progressToken == "ready_for_acceptance" }
    var generationProgress: NativeGenerationProgress {
        let terminalIncomplete = state == .failed || state == .stopped
        let measuredKind = kind == .aerial ? "aerial" : progressKind
        let stepTotal = NativeGenerationProgress.stepTotal(kind: measuredKind)
        let retainedMilestone = kind == .aerial
            ? NativeGenerationProgress.normalizedAerialMilestone(milestoneCompleted, version: aerialProgressVersion)
            : milestoneCompleted
        let steps = stepTotal.flatMap { NativeGenerationProgress.retained(previous: retainedMilestone,
            incoming: NativeGenerationProgress.steps(kind: measuredKind ?? "", phase: progressToken), incomplete: terminalIncomplete, total: $0) }
        let measured = completed.flatMap { value -> Int? in
            guard let total, total > 0, value >= 0, value <= total, !terminalIncomplete || value < total else { return nil }; return value
        }
        let useCounts = kind != .aerial && measured != nil
        let simpleReady = state == .ready && !useCounts && steps == nil
        return .init(completed: useCounts ? measured : simpleReady ? 1 : steps, total: useCounts ? total : simpleReady ? 1 : stepTotal,
            unit: useCounts ? (countUnit ?? (kind == .photos ? "photos attempted" : kind == .analysis ? "photos checked" : "clips complete")) : "steps complete",
            phase: stage, active: state == .working || state == .waiting, lastCheckedAt: lastCheckedAt,
            lastProgressAt: lastProgressAt, checksExpected: (expectsStatusChecks ?? (kind == .aerial)) && state.isActive && !isAerialAwaitingReview,
            checkFailed: checkFailed == true)
    }
    var orderingDate: Date { lastProgressAt ?? startedAt ?? firstObservedAt }
    var signature: String { "\(progressToken ?? stage)|\(completed ?? -1)|\(total ?? -1)" }
}
struct NativeActivityHistory: Codable {
    var entries: [NativeActivityEntry] = []
    func visible(scope: NativeActivityScope, listingIDs: Set<UUID>) -> [NativeActivityEntry] {
        entries.filter { $0.scope == scope && listingIDs.contains($0.listingID) }
    }
    /// A repeated poll is not progress. Existing job decoders and operation
    /// fences own validity; this history never authorizes a transition or retry.
    mutating func observe(_ incoming: NativeActivityEntry, now: Date) {
        if let index = entries.firstIndex(where: { $0.id == incoming.id && $0.scope == incoming.scope }) {
            let old = entries[index]
            var value = incoming
            value.firstObservedAt = old.firstObservedAt
            value.startedAt = old.startedAt ?? incoming.startedAt
            let previousMilestone = incoming.kind == .aerial
                ? NativeGenerationProgress.retained(
                    previous: NativeGenerationProgress.normalizedAerialMilestone(old.milestoneCompleted, version: old.aerialProgressVersion),
                    incoming: NativeGenerationProgress.steps(kind: "aerial", phase: old.progressToken),
                    incomplete: old.state == .failed || old.state == .stopped, total: NativeGenerationProgress.aerialTotal)
                : old.milestoneCompleted
            let incomingMilestone = incoming.kind == .aerial
                ? NativeGenerationProgress.normalizedAerialMilestone(incoming.milestoneCompleted, version: incoming.aerialProgressVersion)
                : incoming.milestoneCompleted
            let regressed = previousMilestone.flatMap { previous in incomingMilestone.map { $0 < previous } } ?? false
            value.lastProgressAt = old.signature == incoming.signature || regressed ? (old.lastProgressAt ?? incoming.lastProgressAt) : (incoming.lastProgressAt ?? now)
            value.milestoneCompleted = NativeGenerationProgress.retained(previous: previousMilestone,
                incoming: incomingMilestone, incomplete: incoming.state == .failed || incoming.state == .stopped, total: NativeGenerationProgress.stepTotal(kind: incoming.kind == .aerial ? "aerial" : incoming.progressKind) ?? 1)
            if incoming.kind == .aerial { value.aerialProgressVersion = NativeGenerationProgress.aerialProgressVersion }
            entries[index] = value
        } else { entries.append(incoming) }
        let active = entries.filter { $0.state.isActive }
        let recent = entries.filter { !$0.state.isActive }.sorted { $0.orderingDate > $1.orderingDate }.prefix(40)
        entries = active + recent
    }
}

enum NativeActivityCategory: String, CaseIterable, Identifiable {
    case active, ready, attention, history
    var id: String { rawValue }
    var title: String {
        switch self { case .active: return "Active"; case .ready: return "Ready"; case .attention: return "Needs attention"; case .history: return "History" }
    }
    func contains(_ state: NativeActivityEntry.State) -> Bool {
        switch self {
        case .active: return state == .working || state == .waiting
        case .ready: return state == .ready
        case .attention: return state == .attention || state == .failed
        case .history: return state == .ready || state == .failed || state == .stopped
        }
    }
}
struct NativeActivityListingGroup: Identifiable {
    let id: UUID
    let title: String
    var entries: [NativeActivityEntry]
}
enum NativeActivityCatalog {
    static func scoped(_ entries: [NativeActivityEntry], scope: NativeActivityScope, search: String = "") -> [NativeActivityEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { $0.scope == scope && (query.isEmpty || $0.listingTitle.localizedCaseInsensitiveContains(query)) }
    }
    static func count(_ category: NativeActivityCategory, entries: [NativeActivityEntry]) -> Int {
        entries.filter { category.contains($0.state) }.count
    }
    static func defaultCategory(entries: [NativeActivityEntry]) -> NativeActivityCategory {
        NativeActivityCategory.allCases.first { count($0, entries: entries) > 0 } ?? .active
    }
    static func groups(_ entries: [NativeActivityEntry], category: NativeActivityCategory) -> [NativeActivityListingGroup] {
        let ordered = entries.filter { category.contains($0.state) }.sorted { $0.orderingDate > $1.orderingDate }
        var groups: [NativeActivityListingGroup] = []
        for entry in ordered {
            if let index = groups.firstIndex(where: { $0.id == entry.listingID }) { groups[index].entries.append(entry) }
            else { groups.append(.init(id: entry.listingID, title: entry.listingTitle, entries: [entry])) }
        }
        return groups
    }
}
struct NativeActivityPresentationState {
    var category: NativeActivityCategory?
    var detail: NativeActivityEntry?
    private(set) var pendingReview: NativeActivityEntry?
    func selectedCategory(entries: [NativeActivityEntry]) -> NativeActivityCategory {
        category ?? NativeActivityCatalog.defaultCategory(entries: entries)
    }
    func permitsForegroundRefresh(reviewingID: String?) -> Bool {
        pendingReview == nil && reviewingID == nil
    }
    @discardableResult mutating func showDetail(_ entry: NativeActivityEntry, scope: NativeActivityScope) -> Bool {
        guard entry.scope == scope, pendingReview == nil else { return false }
        detail = entry; return true
    }
    func resolvedDetail(entries: [NativeActivityEntry], scope: NativeActivityScope) -> NativeActivityEntry? {
        guard let detail, detail.scope == scope else { return nil }
        return entries.first { $0.id == detail.id && $0.scope == scope && $0.listingID == detail.listingID }
    }
    @discardableResult mutating func requestReview(_ entry: NativeActivityEntry, scope: NativeActivityScope) -> Bool {
        guard let detail, detail.id == entry.id, detail.listingID == entry.listingID,
              detail.scope == scope, entry.scope == scope else { return false }
        pendingReview = entry; self.detail = nil; return true
    }
    mutating func takeReview(entries: [NativeActivityEntry], scope: NativeActivityScope) -> NativeActivityEntry? {
        defer { pendingReview = nil }
        guard let saved = pendingReview, saved.scope == scope else { return nil }
        return entries.first { $0.id == saved.id && $0.scope == scope && $0.listingID == saved.listingID }
    }
    mutating func reset() { category = nil; detail = nil; pendingReview = nil }
}

@MainActor final class NativeActivityStore: ObservableObject {
    static let shared = NativeActivityStore()
    @Published private(set) var history = NativeActivityHistory()
    @Published private(set) var storageUnavailable = false
    private weak var model: AppModel?
    private var subscriptions: [AnyCancellable] = []
    private var loadedScope: NativeActivityScope?
    private var refreshOffset = 0
    private var refreshing = false
    private var refreshGeneration = UUID()
    @Published private(set) var stoppingIDs: Set<String> = []
    @Published private var connectionFailures: Set<String> = []
    private var liveLocalRevisions: [String: UInt64] = [:]
    private var liveLocalIDs: Set<String> = []
    private var localStops: [String: () -> Void] = [:]
    static var currentScope: NativeActivityScope {
        .init(actor: AuthStore.shared.userID.flatMap(UUID.init(uuidString:)), library: WorkspaceContext.selectedOrgID)
    }
    var entries: [NativeActivityEntry] {
        guard let model else { return [] }
        let scope = Self.currentScope
        let available = Set(model.listings.filter { !$0.isSample && $0.cloudUnavailable != true && model.isInSelectedWorkspace($0) }.map(\.id))
        return history.visible(scope: scope, listingIDs: available).map { entry in
            var value = entry
            if entry.state.isActive {
                let live: Bool
                switch entry.kind {
                case .photos: live = PhotoWorkQueue.shared.visibleJob.map { "photo:\($0.id)" == entry.id && $0.running } == true
                case .video: live = ReelWorkQueue.shared.reviewableJobs.contains { Self.reelID($0) == entry.id }
                case .tour: live = model.renderCoordinator.activityID(entry.listingID) == entry.id && model.renderCoordinator.activityScopes[entry.listingID] == scope
                case .analysis, .voice: live = liveLocalIDs.contains(entry.id) && liveLocalRevisions[entry.id] == AIConsent.shared.revocationRevision
                case .aerial: live = true // The visible tab checks its exact saved server request by GET.
                }
                if !live {
                    value.state = .attention; value.stage = "Saved work needs checking. Open its listing to review."
                }
                if connectionFailures.contains(entry.id) {
                    value.state = .attention; value.checkFailed = true; value.stage = "Could not check status. Last confirmed: " + entry.stage
                }
            }
            return value
        }.sorted {
            if $0.state.isActive != $1.state.isActive { return $0.state.isActive }
            return $0.orderingDate > $1.orderingDate
        }
    }
    private func storageURL(_ scope: NativeActivityScope) -> URL {
        FileStore.documents.appendingPathComponent("activity/\(scope.actor?.uuidString ?? "local")/\(scope.library?.uuidString ?? "local").json")
    }
    func attach(model: AppModel) {
        guard self.model !== model else { synchronize(); return }
        self.model = model
        let sources = [PhotoWorkQueue.shared.objectWillChange.eraseToAnyPublisher(), ReelWorkQueue.shared.objectWillChange.eraseToAnyPublisher(), model.renderCoordinator.objectWillChange.eraseToAnyPublisher()]
        subscriptions = sources.map { source in source.sink { [weak self] _ in Task { @MainActor in await Task.yield(); self?.synchronize() } } }
        subscriptions.append(NotificationCenter.default.publisher(for: .init("rendpropAerialOpeningJournalChanged")).sink { [weak self] _ in Task { @MainActor in self?.synchronize() } })
        synchronize()
    }
    func synchronize() {
        let scope = Self.currentScope
        if loadedScope != scope {
            loadedScope = scope; history = .init(); liveLocalIDs = []; liveLocalRevisions = [:]; localStops = [:]; connectionFailures = []; refreshGeneration = UUID(); storageUnavailable = false
            if let data = try? Data(contentsOf: storageURL(scope)), data.count <= 262144,
               let saved = try? JSONDecoder().decode(NativeActivityHistory.self, from: data), saved.entries.count <= 240 {
                history.entries = saved.entries.filter { $0.scope == scope }
            }
        }
        guard let model else { return }
        if let job = PhotoWorkQueue.shared.visibleJob {
            let state: NativeActivityEntry.State = job.running ? (job.stopRequested ? .waiting : .working) : job.interrupted ? .stopped : job.failures.isEmpty ? .ready : .failed
            observe(id: "photo:\(job.id)", listingID: job.listingID, kind: .photos, state: state,
                    stage: job.running ? (job.stopRequested ? "Stopping remaining edits" : job.phase?.title ?? "Preparing photo") : "\(job.done) of \(job.total) photos saved",
                    completed: job.done, total: job.total, countUnit: "photos saved", startedAt: job.startedAt, progressToken: job.running ? String(job.phase?.rawValue ?? -1) : "finished")
        }
        for job in ReelWorkQueue.shared.reviewableJobs {
            let state: NativeActivityEntry.State = job.phase == .done ? .ready : job.phase == .failed ? .failed : job.paused ? .waiting : job.serverStatusCheckNote != nil ? .attention : .working
            let stage: String
            switch job.phase {
            case .done: stage = "Video saved. Ready to review."
            case .failed: stage = "Video needs attention"
            default: stage = job.serverJob?.reply.map { PropertyVideoJobRunner.status($0) } ??
                (job.paused ? "Paused on this iPhone" : job.phase == .stitching ? "Finishing video" : "Checking saved video request")
            }
            observe(id: Self.reelID(job), listingID: job.listingID, kind: .video, state: state, stage: stage,
                    completed: job.usesPhotoMotion ? nil : job.completedClips, total: job.totalClips,
                    startedAt: job.serverJob?.createdAt ?? job.activityStartedAt, progressToken: job.serverJob?.reply?.state, lastCheckedAt: job.lastServerStatusCheck, progressKind: job.usesPhotoMotion ? "photo_motion" : "video", expectsStatusChecks: job.serverJob != nil)
        }
        for (listingID, job) in model.renderCoordinator.jobs {
            let state: NativeActivityEntry.State = job.isRunning ? .working : job.stage == .published || job.stage == .rendered ? .ready : job.stage == .cancelled ? .stopped : job.stage == .awaitingConnection ? .waiting : .failed
            let stage: String
            switch job.stage {
            case .rendering: stage = "Rendering tour"
            case .enhancing: stage = "Enhancing tour"
            case .publishing: stage = "Publishing tour"
            case .rendered: stage = "Tour saved"
            case .awaitingConnection: stage = "Waiting for connection"
            case .published: stage = "Tour published"
            case .publishFailed, .failed: stage = "Tour needs attention"
            case .cancelled: stage = "Tour stopped"
            }
            guard model.renderCoordinator.activityScopes[listingID] == scope else { continue }
            observe(id: model.renderCoordinator.activityID(listingID), listingID: listingID, kind: .tour, state: state, stage: stage, startedAt: model.renderCoordinator.activityStartedAt[listingID])
        }
        for listing in model.listings where !listing.isSample && listing.cloudUnavailable != true && model.isInSelectedWorkspace(listing) {
            guard let actor = scope.actor, let library = scope.library, let server = listing.serverID else { continue }
            let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: library)
            if let saved = try? AerialOpeningStore.load(context), saved.physicalOrgID == listing.serverOrgID { observeAerial(saved) }
        }
    }
    func registerStop(id: String, scope: NativeActivityScope, stop: @escaping () -> Void) {
        guard scope == Self.currentScope else { return }; localStops[id] = stop
    }
    func localStop(for entry: NativeActivityEntry) -> (() -> Void)? {
        guard entry.scope == Self.currentScope, liveLocalIDs.contains(entry.id), let action = localStops[entry.id] else { return nil }
        return { [weak self] in
            guard entry.scope == Self.currentScope, self?.liveLocalIDs.contains(entry.id) == true else { return }; action()
        }
    }
    static func reelID(_ job: ReelWorkJob) -> String { "reel:\(job.serverJob?.request.operationID ?? job.activityOperationID)" }
    func observe(id: String, listingID: UUID, kind: NativeActivityEntry.Kind, state: NativeActivityEntry.State,
                 stage: String, completed: Int? = nil, total: Int? = nil, countUnit: String? = nil, startedAt: Date? = nil, progressToken: String? = nil, lastCheckedAt: Date? = nil, confirmedProgressAt: Date? = nil, confirmedMilestones: Int? = nil, progressKind: String? = nil, expectsStatusChecks: Bool = false, scope: NativeActivityScope? = nil) {
        guard let model, let listing = model.listings.first(where: { $0.id == listingID }), !listing.isSample,
              listing.cloudUnavailable != true, model.isInSelectedWorkspace(listing), scope == nil || scope == Self.currentScope else { return }
        let scope = scope ?? Self.currentScope, now = Date()
        if kind == .analysis || kind == .voice {
            if state.isActive { liveLocalIDs.insert(id); liveLocalRevisions[id] = AIConsent.shared.revocationRevision } else { liveLocalIDs.remove(id); localStops.removeValue(forKey: id); liveLocalRevisions.removeValue(forKey: id) }
        }
        let old = history.entries.first { $0.id == id && $0.scope == scope }
        let entry = NativeActivityEntry(id: id, scope: scope, listingID: listingID, listingTitle: listing.address.isEmpty ? "Your listing" : listing.address,
            kind: kind, state: state, stage: stage, completed: completed, total: total, startedAt: startedAt,
            firstObservedAt: old?.firstObservedAt ?? now, progressToken: progressToken, lastProgressAt: confirmedProgressAt ?? old?.lastProgressAt, lastCheckedAt: lastCheckedAt, milestoneCompleted: confirmedMilestones ?? NativeGenerationProgress.steps(kind: kind == .aerial ? "aerial" : progressKind ?? "", phase: progressToken), aerialProgressVersion: kind == .aerial ? NativeGenerationProgress.aerialProgressVersion : nil, expectsStatusChecks: expectsStatusChecks, countUnit: countUnit, progressKind: progressKind)
        let previous = history
        history.observe(entry, now: now)
        guard previous.entries != history.entries else { return }
        do {
            let url = storageURL(scope); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history); guard data.count <= 262144 else { storageUnavailable = true; return }
            try data.write(to: url, options: .atomic); storageUnavailable = false
        } catch { storageUnavailable = true }
    }
    private func observeAerial(_ saved: AerialOpeningJournal) {
        guard saved.dispatched else { return } // A prepared quote is not a generation.
        let value = Self.aerialPresentation(state: saved.status?.state, stopping: saved.stopRequested, closed: saved.notAdmittedCancelled == true)
        observe(id: "aerial:\(saved.manifest.operationID)", listingID: saved.context.localListingID, kind: .aerial, state: value.0, stage: value.1,
                startedAt: saved.dispatchedAt, progressToken: saved.notAdmittedCancelled == true ? "not_admitted_cancelled" : saved.status?.state ?? "acceptance_unknown", lastCheckedAt: saved.lastStatusCheckedAt, confirmedProgressAt: saved.lastPhaseChangedAt, confirmedMilestones: saved.generationProgress().completed, expectsStatusChecks: true, scope: .init(actor: saved.context.actorID, library: saved.context.orgID))
    }
    static func aerialPresentation(state: String?, stopping: Bool, closed: Bool) -> (NativeActivityEntry.State, String) {
        if closed || state == "cancelled" { return (.stopped, "Opening stopped") }
        if state == "accepted" { return (.ready, "Opening saved") }
        if state == "ready_for_acceptance" { return (.attention, "Opening ready to review") }
        if state == "failed" || state == "ineligible" { return (.failed, "Opening needs attention") }
        if stopping { return (.waiting, "Waiting for stop confirmation") }
        switch state {
        case "queued_input": return (.waiting, "Waiting for processor · photo preparation")
        case "preparing_input": return (.working, "Preparing opening photo")
        case "queued_assessment": return (.waiting, "Waiting for processor · exterior check")
        case "checking_source": return (.working, "Checking exterior photo")
        case "queued_generation": return (.waiting, "Waiting for processor · opening generation")
        case "dispatching", "processing": return (.working, "Generating opening")
        case "queued_qualification": return (.waiting, "Waiting for processor · video preparation")
        case "qualifying": return (.working, "Preparing opening video")
        case "queued_quality": return (.waiting, "Waiting for processor · video checks")
        case "checking_quality": return (.working, "Checking opening video")
        case "ambiguous": return (.attention, "Saved request needs checking")
        default: return (.attention, "Checking saved request acceptance")
        }
    }
    /// Activity owns a foreground, tab-scoped GET loop only. It cannot submit,
    /// accept or cancel work. A simultaneous editor update wins this exact CAS.
    func suspendAerialRefresh() { refreshGeneration = UUID() }
    /// The existing device-wide wipe deletes Documents. Drop this memory cache
    /// in the same synchronous wipe so it cannot repersist the erased history.
    func eraseDeviceCache() {
        refreshGeneration = UUID(); history = .init(); loadedScope = nil
        liveLocalIDs = []; liveLocalRevisions = [:]; localStops = [:]
        connectionFailures = []; stoppingIDs = []; storageUnavailable = false
    }
    /// A user action reuses the existing scoped Stop endpoint. No generation,
    /// acceptance, resubmission or inferred cancellation is performed here.
    func stopAerial(_ entry: NativeActivityEntry) async {
        guard entry.kind == .aerial, !stoppingIDs.contains(entry.id), entry.scope == Self.currentScope, let model,
              let actor = entry.scope.actor, let library = entry.scope.library,
              let listing = model.listings.first(where: { $0.id == entry.listingID && model.isInSelectedWorkspace($0) }),
              !listing.isSample, listing.cloudUnavailable != true, let server = listing.serverID else { return }
        let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: library)
        guard var saved = try? AerialOpeningStore.load(context), saved.physicalOrgID == listing.serverOrgID,
              "aerial:\(saved.manifest.operationID)" == entry.id, saved.canStopUnfinishedRequest else { return }
        suspendAerialRefresh(); stoppingIDs.insert(entry.id); defer { stoppingIDs.remove(entry.id) }
        let revision = AuthStore.shared.syncSessionRevision, consentRevision = AIConsent.shared.revocationRevision
        do {
            saved.stopRequested = true; try AerialOpeningStore.save(saved); observeAerial(saved)
            let result = try await AerialOpeningService.cancel(saved)
            guard context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == revision,
                  AIConsent.shared.revocationRevision == consentRevision,
                  let current = model.listings.first(where: { $0.id == listing.id }), current.serverID == server,
                  current.serverOrgID == saved.physicalOrgID, current.cloudUnavailable != true,
                  try AerialOpeningStore.load(context) == saved else { return }
            var updated = saved
            if var result { result.previewURL = nil; updated.recordConfirmedStatus(result, at: Date()) }
            else { updated.notAdmittedCancelled = true }
            try AerialOpeningStore.save(updated); observeAerial(updated)
        } catch {
            if context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == revision {
                connectionFailures.insert(entry.id)
            }
        }
    }
    func refreshAerialStatuses() async {
        guard !refreshing, let model, let actor = Self.currentScope.actor, let library = Self.currentScope.library else { return }
        refreshing = true; defer { refreshing = false }
        let revision = AuthStore.shared.syncSessionRevision, consentRevision = AIConsent.shared.revocationRevision, generation = refreshGeneration
        var pending: [AerialOpeningJournal] = []
        for listing in model.listings where !listing.isSample && listing.cloudUnavailable != true && model.isInSelectedWorkspace(listing) {
            guard let server = listing.serverID else { continue }
            let context = PropertyVideoJobContext(localListingID: listing.id, listingID: server, actorID: actor, orgID: library)
            if let saved = try? AerialOpeningStore.load(context), saved.dispatched, saved.notAdmittedCancelled != true,
               saved.status?.isTerminal != true, saved.status?.state != "ready_for_acceptance", saved.physicalOrgID == listing.serverOrgID { pending.append(saved) }
        }
        guard !pending.isEmpty else { synchronize(); return }
        let offset = refreshOffset % pending.count
        let chosen = Array((pending + pending).dropFirst(offset).prefix(min(8, pending.count)))
        refreshOffset = (offset + chosen.count) % pending.count
        for saved in chosen {
            guard !Task.isCancelled, saved.context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == revision,
                  generation == refreshGeneration, AIConsent.shared.revocationRevision == consentRevision else { return }
            do {
                let result = try await AerialOpeningService.refresh(saved)
                guard !Task.isCancelled, saved.context.hasCurrentIdentity, AuthStore.shared.syncSessionRevision == revision,
                      generation == refreshGeneration, AIConsent.shared.revocationRevision == consentRevision,
                      let listing = model.listings.first(where: { $0.id == saved.context.localListingID }), listing.serverID == saved.context.listingID,
                      listing.serverOrgID == saved.physicalOrgID, listing.cloudUnavailable != true,
                      try AerialOpeningStore.load(saved.context) == saved else { continue }
                var updated = saved
                if var result { result.previewURL = nil; updated.recordConfirmedStatus(result, at: Date()) }
                else { updated.stopRequested = true; updated.notAdmittedCancelled = true }
                try AerialOpeningStore.save(updated); connectionFailures.remove("aerial:\(saved.manifest.operationID)"); observeAerial(updated)
            } catch {
                // A failed GET is not a failed generation and never resubmits.
                if !Task.isCancelled, generation == refreshGeneration, saved.context.hasCurrentIdentity,
                   AuthStore.shared.syncSessionRevision == revision, AIConsent.shared.revocationRevision == consentRevision {
                    connectionFailures.insert("aerial:\(saved.manifest.operationID)")
                }
                continue
            }
        }
    }
}
