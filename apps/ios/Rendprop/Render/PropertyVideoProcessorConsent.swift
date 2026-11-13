import Foundation
import Combine

/// A separate permission. The generic v3 AI grant never authorizes this processor.
struct PropertyVideoProcessorContract: Codable, Equatable, Sendable {
    let token: String
    let disclosureRevision: String
    let processors: [String]
    let profiles: [String]
    enum CodingKeys: String, CodingKey {
        case token, disclosureRevision = "disclosure_revision", processors, profiles
    }
    static let known = Self(token: "property-video-jobs-v2", disclosureRevision: "rendprop-property-video-kie-20261016-r1",
        processors: ["kie"], profiles: ["kie-kling3-4k-steady-v1"])
    static let copySHA256 = "11d500972be541f0c34f1ccd96f1a2d79d15c9827a4a010e934ca6b534f9ef9c"
    static let title = "Allow Kie to make your video clips?"
    static let body = "Rendprop may send the property photos you select and camera-motion instructions to Kie (kie.ai). Kie’s terms allow submitted content to be used to operate and improve its services, and do not expressly rule out AI model training. Choose Allow only if you agree to that processing. Your saved originals stay unchanged."
    static let allowLabel = "Allow and continue"
    static let declineLabel = "Not now"
    var isKnown: Bool { self == Self.known }
    static func decodePublished(_ data: Data) throws -> Self {
        guard data.count <= 8192, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["token", "disclosure_revision", "processors", "profiles"] else { throw PropertyVideoProcessorFailure.unknownDisclosure }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isKnown else { throw PropertyVideoProcessorFailure.unknownDisclosure }
        return value
    }
}

struct PropertyVideoProcessorSnapshot: Codable, Equatable, Sendable {
    let actorID: UUID
    let orgID: UUID
    let contract: PropertyVideoProcessorContract
    let copySHA256: String
    let acceptedAt: Date
    func matches(_ context: PropertyVideoJobContext) -> Bool {
        actorID == context.actorID && orgID == context.orgID && contract.isKnown &&
        copySHA256 == PropertyVideoProcessorContract.copySHA256 && acceptedAt.timeIntervalSince1970.isFinite
    }
}

enum PropertyVideoProcessorFailure: Error, LocalizedError {
    case unknownDisclosure, permissionRequired, declined, unknownSavedAuthority, operationPending
    var errorDescription: String? {
        switch self {
        case .unknownDisclosure: return "The video processor disclosure couldn't be verified. No new video, script or voice request was started. Try again after updating Rendprop."
        case .permissionRequired: return "Allow the named video processor before starting more paid work."
        case .declined: return "No new video, script or voice request was started."
        case .unknownSavedAuthority: return "This saved video's processor permission couldn't be verified. Status and cancellation remain available; no new clips were requested."
        case .operationPending: return "The server hasn't confirmed this saved request yet. Check its status or cancel it before starting another video."
        }
    }
}

/// No session counter is durable authority. Account/library and the exact copy
/// are retained; the current session is checked again by the network boundary.
@MainActor final class PropertyVideoProcessorConsent: ObservableObject {
    static let shared = PropertyVideoProcessorConsent()
    static let storageKey = "property-video.processor-permission.r1"
    @Published private(set) var askingContext: PropertyVideoJobContext?
    @Published private(set) var revision: UInt64 = 0
    private var waiter: CheckedContinuation<PropertyVideoProcessorSnapshot?, Never>?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func grant(for context: PropertyVideoJobContext) -> PropertyVideoProcessorSnapshot? {
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 16384,
              let grants = try? JSONDecoder().decode([PropertyVideoProcessorSnapshot].self, from: data), grants.count <= 32,
              grants.allSatisfy({ $0.contract.isKnown && $0.copySHA256 == PropertyVideoProcessorContract.copySHA256 }) else { return nil }
        return grants.first { $0.matches(context) }
    }
    func permits(_ snapshot: PropertyVideoProcessorSnapshot, context: PropertyVideoJobContext) -> Bool {
        snapshot.matches(context) && grant(for: context)?.contract == snapshot.contract
    }
    func ensure(_ contract: PropertyVideoProcessorContract, context: PropertyVideoJobContext) async throws -> PropertyVideoProcessorSnapshot {
        guard contract.isKnown, context.isCurrent else { throw PropertyVideoProcessorFailure.unknownDisclosure }
        if let saved = grant(for: context) { return saved }
        guard waiter == nil else { throw PropertyVideoProcessorFailure.permissionRequired }
        let epoch = revision
        let result = await withCheckedContinuation { continuation in
            waiter = continuation; askingContext = context
        }
        guard epoch == revision, context.isCurrent, let result, permits(result, context: context) else { throw PropertyVideoProcessorFailure.declined }
        return result
    }
    /// Called only by the visible Allow button for this exact known copy.
    func allow() {
        guard let context = askingContext, context.isCurrent else { decline(); return }
        let value = PropertyVideoProcessorSnapshot(actorID: context.actorID, orgID: context.orgID,
            contract: .known, copySHA256: PropertyVideoProcessorContract.copySHA256, acceptedAt: Date())
        var grants: [PropertyVideoProcessorSnapshot] = []
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 16384,
           let old = try? JSONDecoder().decode([PropertyVideoProcessorSnapshot].self, from: data) {
            grants = old.filter { $0.contract.isKnown && !($0.actorID == context.actorID && $0.orgID == context.orgID) }
        }
        guard grants.count < 32 else { decline(); return }
        grants.append(value)
        guard let data = try? JSONEncoder().encode(grants), data.count <= 16384 else { decline(); return }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else { decline(); return }
        finish(value)
    }
    func decline() { finish(nil) }
    func revoke() {
        revision &+= 1
        defaults.removeObject(forKey: Self.storageKey)
        finish(nil)
        PropertyVideoJobCancellation.shared.processorWasRevoked()
    }
    private func finish(_ value: PropertyVideoProcessorSnapshot?) {
        let pending = waiter; waiter = nil; askingContext = nil; pending?.resume(returning: value)
    }
}

/// Only prospective create/resume calls may attach these headers. No operator
/// grant, arbitrary revision or client-supplied processor field is accepted.
enum PropertyVideoPaidAuthorization {
    case legacy
    case processor(PropertyVideoProcessorSnapshot)
    @MainActor func headers(context: PropertyVideoJobContext) throws -> [String: String] {
        guard context.isCurrent else { throw PropertyVideoProcessorFailure.permissionRequired }
        switch self {
        case .legacy: return ["x-rendprop-ai-consent": "property-video-jobs-v1"]
        case .processor(let snapshot):
            guard PropertyVideoProcessorConsent.shared.permits(snapshot, context: context) else { throw PropertyVideoProcessorFailure.permissionRequired }
            return ["x-rendprop-ai-consent": snapshot.contract.token, "x-rendprop-ai-consent-disclosure": snapshot.contract.disclosureRevision]
        }
    }
}
