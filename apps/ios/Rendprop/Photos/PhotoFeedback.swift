import Foundation

// Optional "Useful / Needs work" feedback on one exact AI photo output, and the
// separate outcome signals the owner's report keeps apart from it.
// Client contract: docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md §4.
//
// Nothing in this file changes a photo, a review flag, a listing selection or a
// publication safeguard, and nothing here can start a generation or any other
// paid call. Feedback is written to this phone first and sent later.

enum PhotoFeedback {
    enum Verdict: String, Codable, CaseIterable, Sendable {
        case useful
        case needsWork = "needs_work"
    }

    /// The owner scope's reasons, in its order. Raw values are the wire strings.
    /// The first six are property-fidelity defects; style preference is taste.
    enum Reason: String, Codable, CaseIterable, Identifiable, Sendable {
        case changedPermanentFeatures = "changed_permanent_features"
        case movedOrChangedAppliance = "moved_or_changed_appliance"
        case blockedDoorwayOrOpening = "blocked_doorway_or_opening"
        case inconsistentFurnitureBetweenViews = "inconsistent_furniture_between_views"
        case visibleVisualArtifacts = "visible_visual_artifacts"
        case requestedEditIncomplete = "requested_edit_incomplete"
        case personalStylePreference = "personal_style_preference"
        case other

        var id: String { rawValue }
        var label: String {
            switch self {
            case .changedPermanentFeatures: return "Changed permanent property features"
            case .movedOrChangedAppliance: return "Moved or changed an appliance"
            case .blockedDoorwayOrOpening: return "Blocked a doorway or opening"
            case .inconsistentFurnitureBetweenViews: return "Inconsistent furniture between views"
            case .visibleVisualArtifacts: return "Visible visual artifacts"
            case .requestedEditIncomplete: return "Requested edit was incomplete"
            case .personalStylePreference: return "Personal style preference"
            case .other: return "Other"
            }
        }
    }

    /// Outcomes that are not opinions. Selection, export and publication do not
    /// mean a photo was good; the report counts them on their own axis.
    enum Signal: String, Codable, CaseIterable, Sendable {
        case accuracyAck = "accuracy_ack"
        case manualSelection = "manual_selection"
        case automaticSelection = "automatic_selection"
        case export
        case publication
    }

    enum SignalDetail: String, Codable, CaseIterable, Sendable {
        case stagingReview = "staging_review"
        case customReview = "custom_review"
        case gallerySave = "gallery_save"
        case listingSelection = "listing_selection"
        case kitExport = "kit_export"
        case download
        case publishedTour = "published_tour"
    }

    enum Failure: Error, Equatable {
        case incomplete, unavailable
    }

    enum Route: Equatable, Sendable {
        case feedback, signal
        var pathSegments: [String] {
            switch self {
            case .feedback: return ["photo-feedback"]
            case .signal: return ["photo-feedback", "signal"]
            }
        }
    }

    /// Raw HTTP answer. Error bodies are kept: a 409 feedback_exists carries the
    /// client key this phone has to adopt (contract §4.1).
    struct Reply: Equatable, Sendable {
        let status: Int
        let data: Data
    }

    static let platform = "ios"
    /// The server bounds `note` with Postgres `length`, which counts code points.
    static let maxNoteScalars = 500

    /// The exact output version feedback and signals attach to. Only a version
    /// whose `media_provenance` row was recorded qualifies; legacy, imported and
    /// on-phone versions stay unknown instead of being bound to a guessed row.
    struct Output: Equatable, Hashable, Sendable {
        let provenanceID: String
        /// Sent only when the saved version carries the delivered bytes' hash.
        /// Local history does not record one today, so current versions send
        /// none; it is never recomputed from a later read of the local file.
        let outputSHA256: String?

        init?(provenanceID: String?, outputSHA256: String? = nil) {
            guard let raw = provenanceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = UUID(uuidString: raw) else { return nil }
            self.provenanceID = id.uuidString.lowercased()
            if let hash = outputSHA256?.lowercased(), PhotoFeedback.isSHA256(hash) {
                self.outputSHA256 = hash
            } else {
                self.outputSHA256 = nil
            }
        }

        init?(version: PhotoVersionHistory.Version) {
            guard version.provenanceRecorded else { return nil }
            self.init(provenanceID: version.provenanceID)
        }
    }

    /// One person's opinion, normalized so equal opinions compare equal:
    /// reasons in scope order without duplicates, and no reasons or note for
    /// "Useful".
    struct Draft: Equatable, Sendable {
        let verdict: Verdict
        let reasons: [Reason]
        let note: String?

        init(verdict: Verdict, reasons: [Reason] = [], note: String? = nil) {
            self.verdict = verdict
            if verdict == .useful {
                self.reasons = []
                self.note = nil
            } else {
                let chosen = Set(reasons)
                self.reasons = Reason.allCases.filter { chosen.contains($0) }
                self.note = PhotoFeedback.boundedNote(note)
            }
        }

        /// "Needs work" needs at least one reason (contract §4.1).
        var isComplete: Bool { verdict == .useful || !reasons.isEmpty }
    }

    /// What a 200 says the server now holds for this output.
    struct Receipt: Equatable, Sendable {
        let provenanceID: String
        let revision: Int
        let revisionCount: Int?
        let content: Draft?
        let state: String?
    }

    enum FeedbackOutcome: Equatable, Sendable {
        case accepted(Receipt)
        /// 409 feedback_exists: another key already holds this person's opinion.
        case adopt(clientKey: String, revision: Int?, revisionCount: Int?, content: Draft?)
        /// 409 feedback_revision_conflict: same revision, different content.
        case bumpRevision
        /// Offline, 401, 429 or 5xx. Same body and key next time.
        case retryLater
        /// The output is gone, access is refused or the request can never be
        /// valid. The value is a short reason for diagnostics only.
        case drop(String)
    }

    enum SignalOutcome: Equatable, Sendable {
        case delivered, retryLater
        case drop(String)
    }

    /// One recorded outcome event for one output.
    struct SignalEvent: Hashable, Sendable {
        let signal: Signal
        let detail: SignalDetail?
    }

    // MARK: Keys and bounds

    private static let keyScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_-")
    private static let hexScalars = CharacterSet(charactersIn: "0123456789abcdef")

    /// Random, generated once per output and account, then stored with the
    /// queued item. Never derived from the time or from the output id.
    static func newClientKey() -> String { "ios-" + UUID().uuidString.lowercased() }

    /// `^[A-Za-z0-9:_-]{8,128}$`
    static func isClientKey(_ value: String) -> Bool {
        (8...128).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy { keyScalars.contains($0) }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy { hexScalars.contains($0) }
    }

    static func boundedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxNoteScalars))
        let bounded = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    // MARK: Wire bodies (contract §4.1, §4.2)

    static func feedbackBody(_ record: PhotoFeedbackStore.FeedbackRecord) -> [String: Any] {
        var output: [String: Any] = ["provenance_id": record.provenanceID]
        if let hash = record.outputSHA256 { output["output_sha256"] = hash }
        var body: [String: Any] = [
            "output": output,
            "client_key": record.clientKey,
            "revision": record.revision,
            "verdict": record.verdict.rawValue,
            "reasons": record.reasons.map(\.rawValue),
            "platform": platform
        ]
        if let note = record.note { body["note"] = note }
        return body
    }

    static func signalBody(_ record: PhotoFeedbackStore.SignalRecord) -> [String: Any] {
        var body: [String: Any] = [
            "output": ["provenance_id": record.provenanceID],
            "client_key": record.clientKey,
            "signal": record.signal.rawValue,
            "platform": platform
        ]
        if let detail = record.detail { body["detail"] = detail.rawValue } else { body["detail"] = NSNull() }
        return body
    }

    // MARK: Replies (contract §4.5, §4.6)

    static func classifyFeedback(_ reply: Reply, sent: PhotoFeedbackStore.FeedbackRecord) -> FeedbackOutcome {
        let body = object(reply.data)
        switch reply.status {
        case 200..<300:
            let fallback = Receipt(provenanceID: sent.provenanceID, revision: sent.revision,
                                   revisionCount: nil, content: nil, state: nil)
            guard let body else { return .accepted(fallback) }
            if let echoed = body["provenance_id"] as? String {
                // Never let an answer about another image settle this one.
                guard UUID(uuidString: echoed)?.uuidString.lowercased() == sent.provenanceID else {
                    return .drop("provenance_mismatch")
                }
            }
            return .accepted(Receipt(provenanceID: sent.provenanceID,
                                     revision: positiveInt(body["revision"]) ?? sent.revision,
                                     revisionCount: positiveInt(body["revision_count"]),
                                     content: draft(in: body),
                                     state: body["state"] as? String))
        case 409:
            let code = errorCode(body)
            if code == "feedback_exists" {
                guard let body, let key = first("client_key", in: body, as: String.self), isClientKey(key) else {
                    return .drop("feedback_exists_without_key")
                }
                let details = detailObjects(body)
                return .adopt(clientKey: key,
                              revision: details.lazy.compactMap { positiveInt($0["revision"]) }.first,
                              revisionCount: details.lazy.compactMap { positiveInt($0["revision_count"]) }.first,
                              content: details.lazy.compactMap { draft(in: $0) }.first)
            }
            if code == "feedback_revision_conflict" { return .bumpRevision }
            return .drop(code ?? "conflict")
        case 401, 429, 500...599:
            return .retryLater
        case 404 where errorCode(body) != "output_not_found":
            // Only output_not_found refuses this output (§4.6.5). Any other 404
            // is the route itself missing, e.g. a gateway 404 before the
            // function is deployed, so the item waits instead of being lost.
            return .retryLater
        case 400...499:
            return .drop(errorCode(body) ?? "http_\(reply.status)")
        default:
            return .retryLater
        }
    }

    static func classifySignal(_ reply: Reply) -> SignalOutcome {
        let code = errorCode(object(reply.data))
        switch reply.status {
        case 200..<300: return .delivered
        case 401, 429, 500...599: return .retryLater
        case 404 where code != "output_not_found": return .retryLater
        case 400...499: return .drop(code ?? "http_\(reply.status)")
        default: return .retryLater
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The shared envelope is `{ ...details, error, code }`; a nested
    /// `{ error: { code } }` is read too.
    private static func errorCode(_ body: [String: Any]?) -> String? {
        if let code = body?["code"] as? String { return code }
        if let nested = body?["error"] as? [String: Any], let code = nested["code"] as? String { return code }
        return nil
    }

    private static func detailObjects(_ body: [String: Any]) -> [[String: Any]] {
        var objects = [body]
        for key in ["existing", "feedback", "error", "details", "data"] {
            if let nested = body[key] as? [String: Any] { objects.append(nested) }
        }
        return objects
    }

    private static func first<T>(_ key: String, in body: [String: Any], as type: T.Type) -> T? {
        for object in detailObjects(body) {
            if let value = object[key] as? T { return value }
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 1, double <= 1_000_000, double.rounded() == double else { return nil }
        return number.intValue
    }

    private static func draft(in object: [String: Any]) -> Draft? {
        guard let raw = object["verdict"] as? String, let verdict = Verdict(rawValue: raw) else { return nil }
        let reasons = ((object["reasons"] as? [String]) ?? []).compactMap(Reason.init(rawValue:))
        let draft = Draft(verdict: verdict, reasons: reasons, note: object["note"] as? String)
        return draft.isComplete ? draft : nil
    }

    // MARK: Review and selection facts on this phone

    /// Persisted review/selection facts for one exact version. Read only; the
    /// review screen's own actions are what change them.
    struct LocalOutcome: Equatable, Sendable {
        let stagingReviewed: Bool
        let customReviewed: Bool
        let selectedForListing: Bool
    }

    static func localOutcome(versionID: String, directory: URL) -> (version: PhotoVersionHistory.Version, outcome: LocalOutcome)? {
        guard let index = try? PhotoVersionHistory.load(directory: directory),
              let version = index.versions[versionID] else { return nil }
        let outcome = LocalOutcome(stagingReviewed: version.effects.contains("stage") && version.stagingReviewed == true,
                                   customReviewed: version.customReviewed == true,
                                   selectedForListing: index.isSelectedForListing(versionID))
        return (version, outcome)
    }

    /// Signals implied by a change the person made on this phone. A cloud
    /// listing's selection lives on the server; its selection signal is
    /// recorded where that request succeeds, not from the local index.
    static func transitionSignals(from old: LocalOutcome, to new: LocalOutcome, cloudListing: Bool) -> [SignalEvent] {
        var events: [SignalEvent] = []
        if !old.stagingReviewed && new.stagingReviewed { events.append(.init(signal: .accuracyAck, detail: .stagingReview)) }
        if !old.customReviewed && new.customReviewed { events.append(.init(signal: .accuracyAck, detail: .customReview)) }
        if !cloudListing && !old.selectedForListing && new.selectedForListing {
            events.append(.init(signal: .manualSelection, detail: .listingSelection))
        }
        return events
    }

    /// The version a just-saved edit put on the listing through the existing
    /// automatic rule (`canAutomaticallySelectForListing`), or nil.
    static func automaticallySelectedVersion(versionID: String, directory: URL) -> PhotoVersionHistory.Version? {
        guard let index = try? PhotoVersionHistory.load(directory: directory),
              let version = index.versions[versionID],
              version.canAutomaticallySelectForListing, index.isSelectedForListing(versionID) else { return nil }
        return version
    }
}

extension Notification.Name {
    /// Posted by `PhotoEditService` right after an AI edit is saved, with
    /// `userInfo["directory"]` (URL) and `userInfo["versionID"]` (String).
    /// PhotoEditService spells the same string inline.
    static let rendpropPhotoEditSaved = Notification.Name("rendprop.photoEditSaved")
}

/// The `photo-feedback` edge function. Answers are returned raw, error bodies
/// included; thrown errors are transport, cancellation or account changes.
protocol PhotoFeedbackAPI: AnyObject {
    @MainActor func photoFeedbackExchange(_ route: PhotoFeedback.Route, body: [String: Any],
                                          libraryOrgID: UUID, actorID: String) async throws -> PhotoFeedback.Reply
}

/// One durable queue file per account in Application Support/PhotoFeedback.
/// Every operation reads the file fresh under one lock and nothing is cached
/// in memory, so clearing this phone's data (which empties Application
/// Support) also clears the queue.
final class PhotoFeedbackStore: @unchecked Sendable {
    struct FeedbackRecord: Codable, Equatable, Sendable {
        let provenanceID: String
        let outputSHA256: String?
        var clientKey: String
        /// The library selected when the opinion was recorded. Sent as its
        /// header on every retry; a later library switch never retargets it.
        let libraryOrgID: UUID
        var revision: Int
        var verdict: PhotoFeedback.Verdict
        var reasons: [PhotoFeedback.Reason]
        var note: String?
        /// The current `revision` was accepted by the server.
        var delivered: Bool
        var serverRevisionCount: Int?
        var changedAt: Date
        var attempts: Int
        var nextAttemptAt: Date?

        var content: PhotoFeedback.Draft { PhotoFeedback.Draft(verdict: verdict, reasons: reasons, note: note) }

        var isValid: Bool {
            UUID(uuidString: provenanceID)?.uuidString.lowercased() == provenanceID
                && PhotoFeedback.isClientKey(clientKey) && revision >= 1 && attempts >= 0
                && (outputSHA256.map(PhotoFeedback.isSHA256) ?? true)
                && content.reasons == reasons && content.note == note && content.isComplete
        }
    }

    enum SignalState: String, Codable, Sendable {
        case pending, delivered, dropped
    }

    struct SignalRecord: Codable, Equatable, Sendable {
        let provenanceID: String
        let signal: PhotoFeedback.Signal
        let detail: PhotoFeedback.SignalDetail?
        var clientKey: String
        let libraryOrgID: UUID
        var state: SignalState
        let createdAt: Date
        var attempts: Int
        var nextAttemptAt: Date?

        /// One event per output, signal and detail from this phone; repeating
        /// an action never adds a second row.
        var dedupeKey: String { Self.dedupeKey(provenanceID: provenanceID, signal: signal, detail: detail) }
        static func dedupeKey(provenanceID: String, signal: PhotoFeedback.Signal, detail: PhotoFeedback.SignalDetail?) -> String {
            provenanceID + "|" + signal.rawValue + "|" + (detail?.rawValue ?? "-")
        }

        var isValid: Bool {
            UUID(uuidString: provenanceID)?.uuidString.lowercased() == provenanceID
                && PhotoFeedback.isClientKey(clientKey) && attempts >= 0
        }
    }

    enum Work: Equatable, Sendable {
        case feedback(FeedbackRecord)
        case signal(SignalRecord)
    }

    enum DeliveryResult: Equatable, Sendable {
        /// Nothing due is left.
        case idle
        /// A transient failure or the per-pass budget stopped the pass.
        case deferred
        /// The account or library changed, or the task was cancelled.
        case interrupted
    }

    private struct Snapshot: Codable {
        var schema: Int
        var actorID: String
        var feedback: [FeedbackRecord]
        var signals: [SignalRecord]
    }

    static let maxFeedbackRecords = 2_000
    static let maxSignalRecords = 4_000
    /// Unsent items older than this are dropped quietly.
    static let pendingLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maxFileBytes = 8 * 1024 * 1024

    private static let lock = NSLock()
    let directory: URL

    init(directory: URL) { self.directory = directory }

    static var standardDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("PhotoFeedback", isDirectory: true)
    }

    /// Account ids are UUIDs; anything else cannot own a queue.
    static func normalizedActor(_ actor: String?) -> String? {
        actor.flatMap { UUID(uuidString: $0) }?.uuidString.lowercased()
    }

    static func backoff(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, attempts - 1))), 60 * 60)
    }

    // MARK: Reads

    func feedback(provenanceID: String, actor: String) -> FeedbackRecord? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return nil }
        return read(file, actor: actor).feedback.first { $0.provenanceID == provenanceID }
    }

    func signals(actor: String) -> [SignalRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return [] }
        return read(file, actor: actor).signals
    }

    /// Unsent items for this account and library, oldest first.
    func dueWork(actor: String, library: UUID, now: Date, ignoringBackoff: Bool) -> [Work] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return [] }
        let snapshot = read(file, actor: actor)
        func due(_ next: Date?) -> Bool { ignoringBackoff || (next ?? .distantPast) <= now }
        let feedback = snapshot.feedback
            .filter { !$0.delivered && $0.libraryOrgID == library && due($0.nextAttemptAt) }
            .map { (Work.feedback($0), $0.changedAt) }
        let signals = snapshot.signals
            .filter { $0.state == .pending && $0.libraryOrgID == library && due($0.nextAttemptAt) }
            .map { (Work.signal($0), $0.createdAt) }
        return (feedback + signals).sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    /// When the earliest postponed item for this account and library is due.
    func nextAttempt(actor: String, library: UUID) -> Date? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return nil }
        let snapshot = read(file, actor: actor)
        let dates = snapshot.feedback.filter { !$0.delivered && $0.libraryOrgID == library }.map { $0.nextAttemptAt ?? .distantPast }
            + snapshot.signals.filter { $0.state == .pending && $0.libraryOrgID == library }.map { $0.nextAttemptAt ?? .distantPast }
        return dates.min()
    }

    // MARK: Writes

    /// Stores the opinion before anything is sent. The same opinion again is
    /// a no-op; a different one bumps `revision` and replaces the unsent body
    /// for this output. The client key never changes here and never moves to
    /// another output.
    @discardableResult
    func record(_ draft: PhotoFeedback.Draft, output: PhotoFeedback.Output, library: UUID,
                actor: String, now: Date = Date()) throws -> FeedbackRecord {
        guard draft.isComplete else { throw PhotoFeedback.Failure.incomplete }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { throw PhotoFeedback.Failure.unavailable }
        var snapshot = read(file, actor: actor)
        if let index = snapshot.feedback.firstIndex(where: { $0.provenanceID == output.provenanceID }) {
            var existing = snapshot.feedback[index]
            if existing.content == draft { return existing }
            existing.revision += 1
            existing.verdict = draft.verdict
            existing.reasons = draft.reasons
            existing.note = draft.note
            existing.delivered = false
            existing.attempts = 0
            existing.nextAttemptAt = nil
            existing.changedAt = now
            snapshot.feedback[index] = existing
            try write(snapshot, to: file, now: now)
            return existing
        }
        let created = FeedbackRecord(provenanceID: output.provenanceID, outputSHA256: output.outputSHA256,
                                     clientKey: PhotoFeedback.newClientKey(), libraryOrgID: library, revision: 1,
                                     verdict: draft.verdict, reasons: draft.reasons, note: draft.note,
                                     delivered: false, serverRevisionCount: nil, changedAt: now,
                                     attempts: 0, nextAttemptAt: nil)
        snapshot.feedback.append(created)
        try write(snapshot, to: file, now: now)
        return created
    }

    /// Queues one outcome event. Returns false when this output already has
    /// it (sent, pending or refused), so repeating an action adds nothing.
    @discardableResult
    func recordSignal(_ signal: PhotoFeedback.Signal, detail: PhotoFeedback.SignalDetail?, output: PhotoFeedback.Output,
                      library: UUID, actor: String, now: Date = Date()) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { throw PhotoFeedback.Failure.unavailable }
        var snapshot = read(file, actor: actor)
        let key = SignalRecord.dedupeKey(provenanceID: output.provenanceID, signal: signal, detail: detail)
        guard !snapshot.signals.contains(where: { $0.dedupeKey == key }) else { return false }
        snapshot.signals.append(SignalRecord(provenanceID: output.provenanceID, signal: signal, detail: detail,
                                             clientKey: PhotoFeedback.newClientKey(), libraryOrgID: library,
                                             state: .pending, createdAt: now, attempts: 0, nextAttemptAt: nil))
        try write(snapshot, to: file, now: now)
        return true
    }

    /// Applies one answer to the item that was sent. Nothing happens when that
    /// item was meanwhile removed, wiped or re-keyed.
    @discardableResult
    func apply(_ outcome: PhotoFeedback.FeedbackOutcome, to sent: FeedbackRecord, actor: String,
               now: Date = Date()) -> FeedbackRecord? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return nil }
        var snapshot = read(file, actor: actor)
        guard let index = snapshot.feedback.firstIndex(where: { $0.provenanceID == sent.provenanceID }),
              snapshot.feedback[index].clientKey == sent.clientKey else { return nil }
        var current = snapshot.feedback[index]
        switch outcome {
        case .accepted(let receipt):
            if current.revision == sent.revision {
                if receipt.revision > current.revision, let held = receipt.content {
                    // The server already holds a newer opinion for this output;
                    // an older revision never replaces it (contract §4.1).
                    current.verdict = held.verdict
                    current.reasons = held.reasons
                    current.note = held.note
                }
                current.revision = max(current.revision, receipt.revision)
                current.delivered = true
            } else {
                // Changed on this phone after this revision left: the newer one
                // goes next and must outrank what the server holds.
                current.revision = max(current.revision, receipt.revision + 1)
            }
            current.serverRevisionCount = receipt.revisionCount ?? current.serverRevisionCount
            current.attempts = 0
            current.nextAttemptAt = nil
        case .adopt(let key, let revision, let revisionCount, let content):
            // A key equal to ours, or one this phone already uses for another
            // output, can never be adopted for this one.
            guard PhotoFeedback.isClientKey(key), key != current.clientKey,
                  !snapshot.feedback.contains(where: { $0.clientKey == key && $0.provenanceID != current.provenanceID }) else {
                snapshot.feedback.remove(at: index)
                try? write(snapshot, to: file, now: now)
                return nil
            }
            current.clientKey = key
            if let content, let revision, content == current.content {
                current.revision = revision
                current.delivered = true
            } else {
                // Contract §4.6.7: resend above the stored revision. Using the
                // larger of revision and revision_count (and never going below
                // this phone's own counter) keeps the change from being replayed
                // away as an older revision.
                current.revision = max(revision ?? 0, revisionCount ?? 0, current.revision) + 1
                current.delivered = false
            }
            current.serverRevisionCount = revisionCount ?? current.serverRevisionCount
            current.attempts = 0
            current.nextAttemptAt = nil
        case .bumpRevision:
            current.revision += 1
            current.delivered = false
            current.nextAttemptAt = nil
        case .retryLater:
            current.attempts += 1
            current.nextAttemptAt = now.addingTimeInterval(Self.backoff(attempts: current.attempts))
        case .drop:
            snapshot.feedback.remove(at: index)
            try? write(snapshot, to: file, now: now)
            return nil
        }
        snapshot.feedback[index] = current
        try? write(snapshot, to: file, now: now)
        return current
    }

    func apply(_ outcome: PhotoFeedback.SignalOutcome, to sent: SignalRecord, actor: String, now: Date = Date()) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let actor = Self.normalizedActor(actor), let file = fileURL(actor: actor) else { return }
        var snapshot = read(file, actor: actor)
        guard let index = snapshot.signals.firstIndex(where: { $0.dedupeKey == sent.dedupeKey && $0.clientKey == sent.clientKey }),
              snapshot.signals[index].state == .pending else { return }
        switch outcome {
        case .delivered:
            snapshot.signals[index].state = .delivered
            snapshot.signals[index].nextAttemptAt = nil
        case .retryLater:
            snapshot.signals[index].attempts += 1
            snapshot.signals[index].nextAttemptAt = now.addingTimeInterval(Self.backoff(attempts: snapshot.signals[index].attempts))
        case .drop:
            // Kept as a marker so the same event is not queued again.
            snapshot.signals[index].state = .dropped
            snapshot.signals[index].nextAttemptAt = nil
        }
        try? write(snapshot, to: file, now: now)
    }

    // MARK: Delivery

    /// One delivery pass, oldest item first. `send` performs the exchange and
    /// `isCurrent` re-checks the account and library after every await; an
    /// answer that arrives after a change is not applied. The pass stops at
    /// the first transient failure, so an offline phone makes one attempt.
    @MainActor
    func deliver(actor: String, library: UUID, ignoringBackoff: Bool, budget: Int = 50,
                 now: () -> Date = { Date() }, isCurrent: () -> Bool,
                 send: (PhotoFeedback.Route, [String: Any], UUID) async throws -> PhotoFeedback.Reply,
                 progress: () -> Void = {}) async -> DeliveryResult {
        var remaining = budget
        while remaining > 0 {
            guard isCurrent(), !Task.isCancelled else { return .interrupted }
            guard let work = dueWork(actor: actor, library: library, now: now(), ignoringBackoff: ignoringBackoff).first else {
                return .idle
            }
            remaining -= 1
            switch work {
            case .feedback(let record):
                let outcome: PhotoFeedback.FeedbackOutcome
                do {
                    let reply = try await send(.feedback, PhotoFeedback.feedbackBody(record), record.libraryOrgID)
                    guard isCurrent() else { return .interrupted }
                    outcome = PhotoFeedback.classifyFeedback(reply, sent: record)
                } catch {
                    guard isCurrent(), !(error is CancellationError) else { return .interrupted }
                    outcome = .retryLater
                }
                apply(outcome, to: record, actor: actor, now: now())
                progress()
                if outcome == .retryLater { return .deferred }
            case .signal(let record):
                let outcome: PhotoFeedback.SignalOutcome
                do {
                    let reply = try await send(.signal, PhotoFeedback.signalBody(record), record.libraryOrgID)
                    guard isCurrent() else { return .interrupted }
                    outcome = PhotoFeedback.classifySignal(reply)
                } catch {
                    guard isCurrent(), !(error is CancellationError) else { return .interrupted }
                    outcome = .retryLater
                }
                apply(outcome, to: record, actor: actor, now: now())
                progress()
                if outcome == .retryLater { return .deferred }
            }
        }
        return .deferred
    }

    // MARK: File

    private func fileURL(actor: String) -> URL? {
        guard directory.isFileURL, let id = Self.normalizedActor(actor) else { return nil }
        return directory.appendingPathComponent("feedback-" + id + ".json")
    }

    /// A missing, oversized or unreadable file is an empty queue. Feedback is
    /// optional, so a damaged file never blocks the review screen.
    private func read(_ file: URL, actor: String) -> Snapshot {
        let empty = Snapshot(schema: 1, actorID: actor, feedback: [], signals: [])
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
              decoded.schema == 1, decoded.actorID == actor else { return empty }
        var snapshot = decoded
        var outputs = Set<String>(), events = Set<String>(), keys = Set<String>()
        snapshot.feedback = snapshot.feedback.filter { $0.isValid && outputs.insert($0.provenanceID).inserted && keys.insert($0.clientKey).inserted }
        snapshot.signals = snapshot.signals.filter { $0.isValid && events.insert($0.dedupeKey).inserted }
        return snapshot
    }

    private func write(_ snapshot: Snapshot, to file: URL, now: Date) throws {
        var snapshot = snapshot
        let cutoff = now.addingTimeInterval(-Self.pendingLifetime)
        snapshot.feedback.removeAll { !$0.delivered && $0.changedAt < cutoff }
        for index in snapshot.signals.indices where snapshot.signals[index].state == .pending && snapshot.signals[index].createdAt < cutoff {
            snapshot.signals[index].state = .dropped
            snapshot.signals[index].nextAttemptAt = nil
        }
        snapshot.feedback = Self.capped(snapshot.feedback, limit: Self.maxFeedbackRecords, settled: { $0.delivered }, date: { $0.changedAt })
        snapshot.signals = Self.capped(snapshot.signals, limit: Self.maxSignalRecords, settled: { $0.state != .pending }, date: { $0.createdAt })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maxFileBytes else { throw PhotoFeedback.Failure.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        // A feedback queue is worthless on a restored device.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = file
        try? target.setResourceValues(values)
    }

    /// Oldest settled entries go first; unsent ones only when settled ones
    /// alone cannot bring the list under its limit. Order is preserved.
    private static func capped<T>(_ items: [T], limit: Int, settled: (T) -> Bool, date: (T) -> Date) -> [T] {
        guard items.count > limit else { return items }
        let ranked = items.indices.sorted { a, b in
            let settledA = settled(items[a]), settledB = settled(items[b])
            if settledA != settledB { return settledA }
            return date(items[a]) < date(items[b])
        }
        let removed = Set(ranked.prefix(items.count - limit))
        return items.indices.filter { !removed.contains($0) }.map { items[$0] }
    }
}
