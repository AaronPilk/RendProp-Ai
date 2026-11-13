import Foundation
import Network
import UIKit

/// The account and library a feedback item belongs to.
struct PhotoFeedbackContext: Equatable, Sendable {
    let actor: String
    let library: UUID
}

/// Records optional photo feedback and outcome signals for exact AI outputs and
/// sends them when the phone can. Recording happens after the action it
/// describes and never waits for, blocks or changes that action; nothing here
/// calls an AI provider or starts a generation.
@MainActor
final class PhotoFeedbackQueue: ObservableObject {
    static let shared = PhotoFeedbackQueue()

    /// Bumped when stored feedback changes, so the review control redraws.
    @Published private(set) var changeCount = 0
    @Published private(set) var isOnline = true

    private let store: PhotoFeedbackStore?
    private var api: PhotoFeedbackAPI?
    private var started = false
    private var flushing = false
    /// A pass requested while one runs; the value is its `ignoringBackoff`.
    private var queuedPass: Bool?
    private var retry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()

    private init() {
        store = PhotoFeedbackStore.standardDirectory.map { PhotoFeedbackStore(directory: $0) }
    }

    // MARK: Lifecycle

    /// Called at launch (and again harmlessly on first use). Sends what an
    /// earlier session left queued, then retries when the app returns to the
    /// foreground, the network comes back or the selected library changes.
    func start() {
        guard !started else { return }
        started = true
        api = Config.makeAPIClient() as? PhotoFeedbackAPI
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PhotoFeedbackQueue.shared.flush(ignoringBackoff: true) }
        })
        observers.append(center.addObserver(forName: .rendpropWorkspaceChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in PhotoFeedbackQueue.shared.flush(ignoringBackoff: true) }
        })
        // No queue: delivered on the posting thread right after the save, so
        // the selection read is the one that save made.
        observers.append(center.addObserver(forName: .rendpropPhotoEditSaved, object: nil, queue: nil) { note in
            PhotoFeedbackQueue.recordAutomaticSelection(note)
        })
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in PhotoFeedbackQueue.shared.networkChanged(online: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.rendprop.photo-feedback.network"))
        flush(ignoringBackoff: true)
    }

    /// The signed-in, identified account and its selected library, or nil.
    nonisolated static func currentContext() -> PhotoFeedbackContext? {
        guard let actor = PhotoFeedbackStore.normalizedActor(AuthStore.shared.userID), AuthStore.shared.isIdentified,
              let library = WorkspaceContext.selectedOrgID else { return nil }
        return PhotoFeedbackContext(actor: actor, library: library)
    }

    // MARK: Explicit feedback

    /// Only an output with a recorded provenance row, viewed by a signed-in
    /// account in a library it may write to, can take feedback.
    func canRecord(_ version: PhotoVersionHistory.Version) -> Bool {
        store != nil && PhotoFeedback.Output(version: version) != nil && Self.currentContext() != nil
            && WorkspaceContext.current?.selected?.canWrite != false
    }

    func savedFeedback(for version: PhotoVersionHistory.Version) -> PhotoFeedbackStore.FeedbackRecord? {
        guard let store, let output = PhotoFeedback.Output(version: version),
              let context = Self.currentContext() else { return nil }
        return store.feedback(provenanceID: output.provenanceID, actor: context.actor)
    }

    /// Saves the opinion on this phone first, then tries to send it. nil when
    /// it could not be saved; nothing else on the screen depends on it.
    @discardableResult
    func submit(_ draft: PhotoFeedback.Draft, for version: PhotoVersionHistory.Version) -> PhotoFeedbackStore.FeedbackRecord? {
        start()
        guard draft.isComplete, canRecord(version), let store,
              let output = PhotoFeedback.Output(version: version), let context = Self.currentContext(),
              let saved = try? store.record(draft, output: output, library: context.library, actor: context.actor) else { return nil }
        didRecord()
        return saved
    }

    // MARK: Outcome signals

    /// Queues one event for an exact output. Versions without recorded
    /// provenance are skipped; an event this phone already queued is not
    /// queued again.
    func recordSignal(_ signal: PhotoFeedback.Signal, detail: PhotoFeedback.SignalDetail?,
                      for version: PhotoVersionHistory.Version?) {
        guard let version, let store, let output = PhotoFeedback.Output(version: version),
              let context = Self.currentContext(),
              (try? store.recordSignal(signal, detail: detail, output: output,
                                       library: context.library, actor: context.actor)) == true else { return }
        start()
        didRecord()
    }

    /// Review checks and a local listing choice the person made on the review
    /// screen since `baseline`, read back from saved history. Returns the new
    /// baseline. The first call for a version only takes the baseline.
    func recordLocalChanges(versionID: String, directory: URL, since baseline: PhotoFeedback.LocalOutcome?,
                            cloudListing: Bool) -> PhotoFeedback.LocalOutcome? {
        guard let current = PhotoFeedback.localOutcome(versionID: versionID, directory: directory) else { return baseline }
        if let baseline {
            for event in PhotoFeedback.transitionSignals(from: baseline, to: current.outcome, cloudListing: cloudListing) {
                recordSignal(event.signal, detail: event.detail, for: current.version)
            }
        }
        return current.outcome
    }

    /// A cloud listing choice the server accepted. On a published listing the
    /// chosen photo is live, so it also counts as published.
    func recordListingSelection(of version: PhotoVersionHistory.Version?, stagingAcknowledged: Bool,
                                customAcknowledged: Bool, listingIsLive: Bool) {
        if stagingAcknowledged { recordSignal(.accuracyAck, detail: .stagingReview, for: version) }
        if customAcknowledged { recordSignal(.accuracyAck, detail: .customReview, for: version) }
        recordSignal(.manualSelection, detail: .listingSelection, for: version)
        if listingIsLive { recordSignal(.publication, detail: .publishedTour, for: version) }
    }

    /// `PhotoExportSheet` finished an export. Originals-only exports carry no
    /// AI output; withheld custom edits were not exported.
    static func recordExport(_ photos: [EnhancedPhoto], originalsOnly: Bool, listingPackage: Bool) {
        guard !originalsOnly else { return }
        for photo in photos {
            guard let version = photo.savedVersion, !version.needsCustomReview else { continue }
            shared.recordSignal(.export, detail: listingPackage ? .kitExport : .download, for: version)
        }
    }

    /// A publish or republish of this listing succeeded. The published gallery
    /// is the cloud selection, which the publish itself refreshes; wait briefly
    /// for that refresh rather than guessing from local choices.
    func recordPublication(listingID: UUID, model: AppModel) {
        guard let context = Self.currentContext() else { return }
        Task { @MainActor in
            for attempt in 0..<30 {
                guard PhotoFeedbackQueue.currentContext() == context, !Task.isCancelled else { return }
                if let projection = model.cloudPhotoProjection(for: listingID), !projection.pending {
                    let index = try? PhotoVersionHistory.load(directory: EnhancedPhoto.directory(for: listingID))
                    for id in projection.selectedVersionIDs.sorted() {
                        PhotoFeedbackQueue.shared.recordSignal(.publication, detail: .publishedTour, for: index?.versions[id])
                    }
                    return
                }
                if attempt < 29 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
    }

    /// `PhotoEditService` saved an edit; record it only if the existing
    /// automatic rule put that exact version on the listing.
    nonisolated static func recordAutomaticSelection(_ note: Notification) {
        guard let directory = note.userInfo?["directory"] as? URL,
              let versionID = note.userInfo?["versionID"] as? String,
              let version = PhotoFeedback.automaticallySelectedVersion(versionID: versionID, directory: directory),
              let output = PhotoFeedback.Output(version: version),
              let context = currentContext(), let folder = PhotoFeedbackStore.standardDirectory,
              (try? PhotoFeedbackStore(directory: folder).recordSignal(.automaticSelection, detail: .listingSelection,
                    output: output, library: context.library, actor: context.actor)) == true else { return }
        Task { @MainActor in PhotoFeedbackQueue.shared.didRecord() }
    }

    // MARK: Delivery

    private func didRecord() {
        changeCount &+= 1
        flush()
    }

    /// Sends what is due, one pass at a time. A request during a pass runs one
    /// more pass afterwards. Failures stay quiet and are retried later with the
    /// same keys.
    func flush(ignoringBackoff: Bool = false) {
        if flushing {
            queuedPass = (queuedPass ?? false) || ignoringBackoff
            return
        }
        guard isOnline || ignoringBackoff, let store, let api, let context = Self.currentContext() else { return }
        flushing = true
        retry?.cancel()
        retry = nil
        let revision = AuthStore.shared.syncSessionRevision
        Task { @MainActor in
            let result = await store.deliver(actor: context.actor, library: context.library, ignoringBackoff: ignoringBackoff,
                isCurrent: { PhotoFeedbackQueue.currentContext() == context && AuthStore.shared.syncSessionRevision == revision },
                send: { route, body, library in
                    try await api.photoFeedbackExchange(route, body: body, libraryOrgID: library, actorID: context.actor)
                },
                progress: { PhotoFeedbackQueue.shared.changeCount &+= 1 })
            self.flushing = false
            if let again = self.queuedPass {
                self.queuedPass = nil
                self.flush(ignoringBackoff: again)
            } else if result == .deferred {
                self.scheduleRetry(context: context)
            }
        }
    }

    private func scheduleRetry(context: PhotoFeedbackContext) {
        guard let store, let due = store.nextAttempt(actor: context.actor, library: context.library) else { return }
        let delay = min(max(due.timeIntervalSinceNow, 5), 60 * 60)
        retry?.cancel()
        retry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            PhotoFeedbackQueue.shared.flush()
        }
    }

    private func networkChanged(online: Bool) {
        let regained = online && !isOnline
        isOnline = online
        if regained { flush(ignoringBackoff: true) }
    }
}
