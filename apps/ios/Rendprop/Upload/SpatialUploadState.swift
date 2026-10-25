import Foundation

/// The journal is a receipt of work, not a progress animation. In particular,
/// `sending` after a process death means "ask the server", never "PUT again".
struct SpatialUploadRecord: Codable, Identifiable, Sendable {
    /// Rooms this phone may be uploading at once. It bounds the journal and the
    /// background session; it is NOT a lifetime count — finished rooms are
    /// pruned, so the 33rd room ever scanned is not refused.
    static let liveRoomLimit = 32
    /// Fresh tickets a single frame may buy after the server retired its
    /// reservation (48 h). Beyond this something is systematically wrong and
    /// the owner is told so instead of the phone buying tickets forever.
    static let maximumReissues = 5

    enum Phase: String, Codable, Sendable { case pending, ticketed, sending, uploaded, attached }
    struct Frame: Codable, Sendable {
        let imagePath: String
        let sidecarPath: String
        let bytes: Int64
        let sha256: String
        var ticketID: String?
        var putURL: URL?
        var phase: Phase = .pending
        var taskID: Int?
        var reconciliations = 0
        /// How many times this frame's reservation died and a new ticket was
        /// bought. Optional so journals written before the field decode.
        var reissues: Int?
        var reissueCount: Int { reissues ?? 0 }
    }
    let id: UUID
    let ownerID: String
    let listingLocalID: UUID
    let listingID: UUID
    let captureID: UUID
    let roomLabel: String
    let allowCellular: Bool
    var jobID: UUID?
    var frames: [Frame]
    var queued = false
    var failure: String?
    // Optional for existing journal compatibility. A paused/cancelled room must
    // not be revived by a delayed OS callback or by relaunching the app.
    var pausedByUser: Bool?
    var isUserPaused: Bool { pausedByUser == true }
    /// `/start` answered 503 "not configured": every photo is on the server
    /// and nothing on this phone can fix it. The screen shows the honest
    /// disabled state instead of a Resume button that fails the same way.
    var serviceUnavailable: Bool?
    var isServiceUnavailable: Bool { serviceUnavailable == true }
    /// The failure can never be retried into success (the capture failed
    /// verification, or the server refused the request as such). The screen
    /// offers to clear the record; a fresh enqueue of the same capture may
    /// replace it instead of being deduplicated into the dead record.
    var terminal: Bool?
    var isTerminalFailure: Bool { terminal == true && failure != nil }

    var bytesTotal: Int64 { frames.reduce(0) { $0 + $1.bytes } }
    var bytesConfirmed: Int64 { frames.filter { $0.phase == .attached }.reduce(0) { $0 + $1.bytes } }
    var confirmedCount: Int { frames.filter { $0.phase == .attached }.count }
    var uploadProgress: Double { bytesTotal > 0 ? Double(bytesConfirmed) / Double(bytesTotal) : 0 }
    /// Every frame is attached to the job — the only state in which the
    /// server can have taken the room and the local photos are redundant.
    var isFullyConfirmed: Bool { !frames.isEmpty && confirmedCount == frames.count }
    var taskPrefix: String { "spatial:\(id.uuidString):" }

    /// `Idempotency-Key` for this frame's `POST /uploads`. The first ticket
    /// keeps the historical key so an in-flight journal replays the same
    /// asset; a reissue after a dead reservation needs a NEW key, because the
    /// server answers a replayed key for an expired reservation with 409
    /// instead of a fresh asset.
    func ticketKey(index: Int) -> String {
        let base = "spatial:\(id.uuidString):\(index)"
        let reissues = frames.indices.contains(index) ? frames[index].reissueCount : 0
        return reissues == 0 ? base : base + ":r\(reissues)"
    }

    /// A ticketed frame whose PUT capability is spent (server window ≤ 1 h)
    /// must renew before any transfer; a PUT with an expired signature is a
    /// wasted transfer and a manual Resume.
    func needsRenewal(index: Int, at now: Date = Date()) -> Bool {
        guard frames.indices.contains(index), frames[index].ticketID != nil,
              frames[index].phase == .ticketed else { return false }
        return !SpatialUploadRecovery.capabilityIsUsable(frames[index].putURL, at: now)
    }

    /// Forget a dead reservation so the next pump buys a fresh ticket for the
    /// SAME frame. Returns false when the frame has already been reissued too
    /// often; the caller then reports it instead of looping.
    @discardableResult mutating func reissueTicket(index: Int) -> Bool {
        guard frames.indices.contains(index), frames[index].phase != .attached,
              frames[index].reissueCount < Self.maximumReissues else { return false }
        frames[index].ticketID = nil
        frames[index].putURL = nil
        frames[index].taskID = nil
        frames[index].phase = .pending
        frames[index].reconciliations = 0
        frames[index].reissues = frames[index].reissueCount + 1
        return true
    }

    /// What the screen last learned about this record's server job.
    enum ServerView { case unknown, missing, job(SpatialJob) }
    /// What the coordinator should do with the record.
    enum Retention: Equatable {
        /// Still has upload work, or the owner may resume it.
        case keep
        /// The server has the whole room: free the local photos, then forget.
        case cleanUpAndForget
        /// Nothing left to do here; the local files are NOT touched.
        case forget
    }

    /// Pure retention rule, so pruning is testable without the coordinator.
    /// Local photos are only ever released when every frame was confirmed AND
    /// the job moved past uploading; a record is never cleaned up "on the way
    /// in", and a cancelled-but-resumable room keeps everything.
    func retention(captureExists: Bool, server: ServerView) -> Retention {
        let releasable: Retention = isFullyConfirmed ? .cleanUpAndForget : .forget
        if queued { return releasable }
        guard captureExists else { return .forget }
        switch server {
        case .unknown:
            return .keep
        case .missing:
            // The server no longer lists a job we created: nothing to upload to.
            return jobID == nil ? .keep : .forget
        case .job(let job):
            switch job.status {
            case .uploading: return .keep
            case .queued, .processing, .review, .ready: return releasable
            case .failed: return job.canResume ? .keep : releasable
            }
        }
    }

    /// iOS can redeliver an old task callback after launch recovery scheduled a
    /// replacement. The frame index alone is not authority to finish that newer
    /// task; correlate the persisted OS task identifier as well.
    @discardableResult mutating func acceptTransportReceipt(index: Int, taskID: Int, success: Bool) -> Bool {
        guard frames.indices.contains(index), frames[index].taskID == taskID,
              frames[index].phase == .sending else { return false }
        frames[index].taskID = nil
        if success { frames[index].phase = .uploaded }
        return true
    }

    func validated() throws -> Self {
        guard UUID(uuidString: ownerID) != nil, !roomLabel.isEmpty, roomLabel.utf8.count <= 80,
              (20...400).contains(frames.count), Set(frames.map(\.imagePath)).count == frames.count,
              Set(frames.map(\.sidecarPath)).count == frames.count else { throw SpatialClientError.unreadableJournal }
        for frame in frames {
            guard frame.imagePath.range(of: #"^images/[0-9]{6}\.jpg$"#, options: .regularExpression) != nil,
                  frame.sidecarPath.range(of: #"^frames/[0-9]{6}\.json$"#, options: .regularExpression) != nil,
                  (1...(32 * 1024 * 1024)).contains(frame.bytes),
                  frame.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw SpatialClientError.unreadableJournal
            }
            if frame.phase != .pending, frame.ticketID == nil { throw SpatialClientError.unreadableJournal }
            guard (0...3).contains(frame.reconciliations),
                  (0...Self.maximumReissues).contains(frame.reissueCount) else { throw SpatialClientError.unreadableJournal }
            if let url = frame.putURL, url.scheme != "https" || url.host == nil || url.user != nil || url.password != nil {
                throw SpatialClientError.unreadableJournal
            }
        }
        guard bytesTotal <= 2 * 1024 * 1024 * 1024 else { throw SpatialClientError.unreadableJournal }
        return self
    }
}
