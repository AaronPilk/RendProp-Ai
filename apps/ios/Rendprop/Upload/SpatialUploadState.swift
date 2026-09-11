import Foundation

/// The journal is a receipt of work, not a progress animation. In particular,
/// `sending` after a process death means "ask the server", never "PUT again".
struct SpatialUploadRecord: Codable, Identifiable, Sendable {
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

    var bytesTotal: Int64 { frames.reduce(0) { $0 + $1.bytes } }
    var bytesConfirmed: Int64 { frames.filter { $0.phase == .attached }.reduce(0) { $0 + $1.bytes } }
    var confirmedCount: Int { frames.filter { $0.phase == .attached }.count }
    var uploadProgress: Double { bytesTotal > 0 ? Double(bytesConfirmed) / Double(bytesTotal) : 0 }
    var taskPrefix: String { "spatial:\(id.uuidString):" }

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
            guard (0...3).contains(frame.reconciliations) else { throw SpatialClientError.unreadableJournal }
            if let url = frame.putURL, url.scheme != "https" || url.host == nil || url.user != nil || url.password != nil {
                throw SpatialClientError.unreadableJournal
            }
        }
        guard bytesTotal <= 2 * 1024 * 1024 * 1024 else { throw SpatialClientError.unreadableJournal }
        return self
    }
}
