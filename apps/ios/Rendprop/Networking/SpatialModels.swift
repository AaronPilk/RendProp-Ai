import Foundation
import CryptoKit

/// Capture poses carry their original mathematical field names. A JSON value
/// preserves those names (and point identifiers as strings) without converting
/// snake_case or rounding measured Float-derived coordinates a second time.
enum SpatialJSON: Codable, Equatable, Sendable {
    case object([String: SpatialJSON]), array([SpatialJSON]), string(String)
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([SpatialJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: SpatialJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct SpatialJob: Codable, Identifiable, Equatable, Sendable {
    enum PrivacyState: String, Codable, Sendable { case unreviewed, approved, excluded, redactionRequired = "redaction_required" }
    enum Status: String, Codable, Sendable {
        case uploading, queued, processing, review, ready, failed
        var title: String {
            switch self {
            case .uploading: return "Uploading room"
            case .queued: return "Waiting to generate"
            case .processing: return "Generating 3D walkthrough"
            case .review: return "Ready for your private review"
            case .ready: return "3D walkthrough ready"
            case .failed: return "Needs attention"
            }
        }
        var isGenerating: Bool { self == .queued || self == .processing }
    }
    let id: UUID
    let listingID: UUID
    let roomLabel: String
    let status: Status
    let progress: Double
    let failureCode: String?
    let viewerURL: URL?
    let shareURL: URL?
    let artifactRevision: UUID?
    let privacyState: PrivacyState
    let attemptNumber: Int
    let retryAfter: String?
    let canRetry: Bool
    let canCancel: Bool
    let canResume: Bool
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, status, progress
        case listingID = "listing_id", roomLabel = "room_label", failureCode = "failure_code"
        case viewerURL = "viewer_url", shareURL = "share_url", artifactRevision = "artifact_revision"
        case privacyState = "privacy_state"
        case attemptNumber = "attempt_number", retryAfter = "retry_after"
        case canRetry = "can_retry", canCancel = "can_cancel", canResume = "can_resume"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    /// Malformed progress is a broken response, never permission to display a
    /// fabricated success. All ready states still require the server's artifact.
    func validated() throws -> SpatialJob {
        guard progress.isFinite, (0...1).contains(progress), !roomLabel.isEmpty, (1...3).contains(attemptNumber) else {
            throw SpatialClientError.invalidResponse
        }
        for url in [viewerURL, shareURL].compactMap({ $0 }) {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw SpatialClientError.invalidResponse
            }
        }
        if status == .review || status == .ready {
            guard artifactRevision != nil else { throw SpatialClientError.invalidResponse }
        }
        if shareURL != nil, status != .ready || privacyState != .approved { throw SpatialClientError.invalidResponse }
        if canRetry, status != .failed || attemptNumber >= 3 { throw SpatialClientError.invalidResponse }
        if canCancel, status != .uploading && status != .queued { throw SpatialClientError.invalidResponse }
        if canResume, status != .failed || failureCode != "user_cancelled" { throw SpatialClientError.invalidResponse }
        return self
    }

    /// One retry key per observed failed attempt, including after a crash or a
    /// lost response. Changing screens cannot buy another cloud attempt. The
    /// backend still authorizes retries and charges under its own row lock.
    var retryOperationID: UUID {
        let input = "rendprop-spatial-retry-v1:\(id.uuidString.lowercased()):\(attemptNumber)"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// A fetched URL is not proof a model rendered. Only the main-frame native
/// bridge from this exact HTTPS origin may attest the expected scene/revision.
/// This is a local review UX gate, not a substitute for server authorization.
struct SpatialViewerExpectation {
    let sceneID: UUID
    let revision: UUID
    let url: URL

    func accepts(_ body: [String: Any], isMainFrame: Bool, scheme: String, host: String, port: Int) -> Bool {
        guard isMainFrame, scheme == "https", url.scheme == "https",
              host.lowercased() == url.host?.lowercased(), (port == 0 ? 443 : port) == (url.port ?? 443),
              body["type"] as? String == "spatial-ready",
              let scene = body["scene_id"] as? String, UUID(uuidString: scene) == sceneID,
              let artifact = body["artifact_revision"] as? String, UUID(uuidString: artifact) == revision
        else { return false }
        return true
    }
}

/// Capture completion may arrive after dismissal or an account switch. Bind
/// it at Scan time, before asynchronous archive verification, instead of
/// assigning whatever account happens to be signed in when it finishes.
struct SpatialCaptureHandoff: Identifiable {
    let id: UUID
    let ownerID: String?

    func accepts(presentationID: UUID?, currentOwner: String?) -> Bool {
        presentationID == id && currentOwner == ownerID
    }
}

struct SpatialCreateRequest: Codable, Sendable {
    let listingID: UUID
    let roomLabel: String
    let captureID: UUID
    let manifest: SpatialJSON
    enum CodingKeys: String, CodingKey {
        case manifest
        case listingID = "listing_id", roomLabel = "room_label", captureID = "capture_id"
    }
}

struct SpatialInput: Codable, Sendable {
    let ticketID: String
    let relativePath: String
    let frame: SpatialJSON
    enum CodingKeys: String, CodingKey {
        case frame
        case ticketID = "ticket_id", relativePath = "relative_path"
    }
}

struct SpatialReviewRequest: Codable, Sendable {
    let artifactRevision: UUID
    let approved: Bool
    let excludeRoom: Bool
    let redactions: [SpatialJSON]
    enum CodingKeys: String, CodingKey {
        case approved, redactions
        case artifactRevision = "artifact_revision", excludeRoom = "exclude_room"
    }
}

enum SpatialClientError: LocalizedError {
    case invalidResponse, noLiveService, accountChanged, unreadableJournal
    case invalidCapture, uploadUncertain, rejectedTransport, uploadPaused
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The 3D service returned an incomplete response. Your capture is still saved."
        case .noLiveService: return "Cloud generation is unavailable in this offline preview. No room was uploaded or generated."
        case .accountChanged: return "This capture belongs to another workspace. Upload is paused and your files are preserved."
        case .unreadableJournal: return "Saved upload recovery data could not be read. Your captures are preserved; no upload was restarted."
        case .invalidCapture: return "This room capture could not be verified. Your saved files are unchanged."
        case .uploadUncertain: return "The server has not confirmed this photo yet. Tap Resume upload to check again; your capture is safe."
        case .rejectedTransport: return "The upload service rejected this photo. Your capture is saved; retry after reconnecting."
        case .uploadPaused: return "Upload is stopped on this phone. Your capture is saved. Resume the room below when you are ready."
        }
    }
}
