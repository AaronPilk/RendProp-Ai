import Foundation

enum ProductionShotStatus: String, Codable, CaseIterable {
    case needed, captured, notNeeded = "not-needed"
    var title: String {
        switch self {
        case .needed: return "Still needed"
        case .captured: return "Captured — review footage"
        case .notNeeded: return "Not needed for this video"
        }
    }
}

/// An editing brief shared with Studio. "Captured" is the person's checklist
/// answer, never an upload receipt or an automated judgement about the footage.
struct ProductionPlan: Codable, Equatable {
    struct Shot: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var guidance: String
        var required: Bool
        var status: ProductionShotStatus
        var sourcePhotoIds: [String]
        var sourceVideoIds: [String]
        var notes: String
    }
    var schema: Int = 1
    var listingId: String
    var recipe: ProductionRecipe
    var presentation: ProductionPresentation
    var targetSeconds: Int
    var shots: [Shot]
    var notes: String

    static func starter(listingID: UUID, recipe: ProductionRecipe = .listingHighlight) -> Self {
        Self(listingId: listingID.uuidString.lowercased(), recipe: recipe,
             presentation: recipe == .listingHighlight ? .music : .voiceover,
             targetSeconds: 45,
             shots: ProductionGuidance.shots(for: recipe).map {
                 Shot(id: $0.id, title: $0.title, guidance: $0.instruction, required: $0.required,
                      status: .needed, sourcePhotoIds: [], sourceVideoIds: [], notes: "")
             }, notes: "")
    }

    /// Preserve completed work, sources and notes even when the next format
    /// doesn't need them. This is the same merge rule used by Studio.
    mutating func changeRecipe(_ recipe: ProductionRecipe) throws {
        _ = try checked()
        let prior = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        guard let listingID = UUID(uuidString: listingId) else { throw ProductionPlanError.invalidDocument }
        let next = Self.starter(listingID: listingID, recipe: recipe)
        let ids = Set(next.shots.map(\.id))
        let retained = shots.filter { !ids.contains($0.id) && ($0.status != .needed || !$0.notes.isEmpty || !$0.sourcePhotoIds.isEmpty || !$0.sourceVideoIds.isEmpty) }
            .map { shot in var optional = shot; optional.required = false; return optional }
        guard next.shots.count + retained.count <= 16 else { throw ProductionPlanError.invalidDocument }
        self.recipe = recipe
        shots = next.shots.map { template in
            guard var saved = prior[template.id] else { return template }
            saved.required = template.required
            return saved
        } + retained
    }

    var remainingCount: Int { shots.filter { $0.required && $0.status == .needed }.count }
    var capturedCount: Int { shots.filter { $0.status == .captured }.count }
    var linkedSourceCount: Int {
        Set(shots.flatMap { $0.sourcePhotoIds.map { "photo:\($0.lowercased())" } + $0.sourceVideoIds.map { "video:\($0.lowercased())" } }).count
    }

    func checked(listingID: UUID? = nil) throws -> Self {
        guard schema == 1, let parsed = UUID(uuidString: listingId), parsed.uuidString.lowercased() == listingId,
              listingID == nil || parsed == listingID,
              [30, 45, 60].contains(targetSeconds), !shots.isEmpty, shots.count <= 16, notes.utf16.count <= 2000,
              Set(shots.map(\.id)).count == shots.count else { throw ProductionPlanError.invalidDocument }
        for shot in shots {
            guard shot.id.range(of: "^[a-z0-9-]{1,48}$", options: .regularExpression) != nil,
                  !shot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  shot.title.utf16.count <= 120, shot.guidance.utf16.count <= 500, shot.notes.utf16.count <= 500,
                  Self.validSources(shot.sourcePhotoIds), Self.validSources(shot.sourceVideoIds) else { throw ProductionPlanError.invalidDocument }
        }
        return self
    }
    private static func validSources(_ ids: [String]) -> Bool {
        ids.count <= 12 && ids.allSatisfy { UUID(uuidString: $0)?.uuidString.lowercased() == $0 } && Set(ids).count == ids.count
    }
}

struct CloudProductionDocument: Decodable {
    let listing_id: UUID
    let revision: Int
    let payload: ProductionPlan
    func checked(listingID: UUID) throws -> Self {
        guard listing_id == listingID, revision > 0, revision < 2_147_483_647 else { throw ProductionPlanError.invalidDocument }
        _ = try payload.checked(listingID: listingID)
        return self
    }
}

protocol ProductionSyncAPI {
    func productionPlan(listingID: UUID, orgID: UUID) async throws -> CloudProductionDocument?
    func saveProductionPlan(_ plan: ProductionPlan, listingID: UUID, orgID: UUID, revision: Int) async throws -> CloudProductionDocument
}

enum ProductionPlanError: LocalizedError {
    case invalidDocument
    var errorDescription: String? { "This production plan couldn’t be read safely. Your saved draft has not been replaced." }
}

/// Recovery is separate from the cloud receipt: a persisted draft is still
/// labelled unsynced until its exact contents have been accepted by the server.
enum ProductionPlanCache {
    struct PendingWrite: Codable, Equatable {
        var plan: ProductionPlan
        var revision: Int
    }
    struct Draft: Codable, Equatable {
        var plan: ProductionPlan
        var revision: Int
        var dirty: Bool
        var pendingWrite: PendingWrite? = nil
    }
    private static func key(owner: String, listingID: UUID) -> String {
        "production-plan.\(owner).\(listingID.uuidString.lowercased())"
    }
    static func load(owner: String, listingID: UUID, defaults: UserDefaults = .standard) throws -> Draft? {
        guard let data = defaults.data(forKey: key(owner: owner, listingID: listingID)) else { return nil }
        let draft = try JSONDecoder().decode(Draft.self, from: data)
        _ = try draft.plan.checked()
        guard draft.revision >= 0, draft.revision < 2_147_483_647 else { throw ProductionPlanError.invalidDocument }
        if let pending = draft.pendingWrite {
            _ = try pending.plan.checked()
            guard pending.revision == draft.revision, pending.plan.listingId == draft.plan.listingId else { throw ProductionPlanError.invalidDocument }
        }
        return draft
    }
    static func save(_ draft: Draft, owner: String, listingID: UUID, defaults: UserDefaults = .standard) throws {
        _ = try draft.plan.checked()
        guard draft.revision >= 0, draft.revision < 2_147_483_647 else { throw ProductionPlanError.invalidDocument }
        if let pending = draft.pendingWrite {
            _ = try pending.plan.checked()
            guard pending.revision == draft.revision, pending.plan.listingId == draft.plan.listingId else { throw ProductionPlanError.invalidDocument }
        }
        let data = try JSONEncoder().encode(draft)
        defaults.set(data, forKey: key(owner: owner, listingID: listingID))
    }
    static func remove(listingID: UUID, defaults: UserDefaults = .standard) {
        let suffix = ".\(listingID.uuidString.lowercased())"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("production-plan.") && key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Pure acknowledgement rules shared by normal replies and lost-reply
/// reconciliation. Later local edits keep their contents and become the next
/// revision; an unrelated remote version can never acknowledge this attempt.
enum ProductionPlanAcknowledgement {
    static func accepts(_ document: CloudProductionDocument, attempt: ProductionPlanCache.Draft) -> Bool {
        document.revision == attempt.revision + 1 && document.payload == attempt.plan &&
            document.listing_id == UUID(uuidString: attempt.plan.listingId)
    }
    static func apply(_ document: CloudProductionDocument, attempt: ProductionPlanCache.Draft,
                      current: ProductionPlanCache.Draft) throws -> ProductionPlanCache.Draft {
        guard accepts(document, attempt: attempt), current.revision == attempt.revision,
              current.plan.listingId == attempt.plan.listingId else { throw ProductionPlanError.invalidDocument }
        return .init(plan: current.plan, revision: document.revision, dirty: current.plan != attempt.plan)
    }
}

/// Only new upload receipts and explicit phone assignments are local intents.
/// An old library row must never reassert a link removed or moved in Studio.
struct ProductionVideoLink: Equatable {
    let entryID: UUID
    let assetID: String?
    var shotID: String?
    let uploaded: Bool
    var pending: Bool

    static func applying(_ links: [Self], to original: ProductionPlan) -> (plan: ProductionPlan, acknowledged: Set<UUID>, blocked: Bool) {
        var plan = original
        var acknowledged = Set<UUID>()
        var blocked = false
        for link in links where link.uploaded && link.pending {
            guard let asset = link.assetID?.lowercased(), UUID(uuidString: asset) != nil else { continue }
            if let shotID = link.shotID {
                guard let destination = plan.shots.firstIndex(where: { $0.id == shotID }),
                      plan.shots[destination].sourceVideoIds.contains(asset) || plan.shots[destination].sourceVideoIds.count < 12 else {
                    blocked = true; continue
                }
            }
            for index in plan.shots.indices { plan.shots[index].sourceVideoIds.removeAll { $0.caseInsensitiveCompare(asset) == .orderedSame } }
            if let destination = plan.shots.firstIndex(where: { $0.id == link.shotID }) { plan.shots[destination].sourceVideoIds.append(asset) }
            acknowledged.insert(link.entryID)
        }
        return (plan, acknowledged, blocked)
    }

    static func reconciling(_ current: [Self], pullSnapshot: [Self], remote: ProductionPlan) -> [Self] {
        let beforePull = Dictionary(uniqueKeysWithValues: pullSnapshot.filter(\.uploaded).map { ($0.entryID, $0) })
        return current.map { link in
            // Keep a new receipt or assignment that arrived while GET awaited.
            guard beforePull[link.entryID] == link, let asset = link.assetID else { return link }
            var accepted = link
            accepted.shotID = remote.shots.first { $0.sourceVideoIds.contains { $0.caseInsensitiveCompare(asset) == .orderedSame } }?.id
            accepted.pending = false
            return accepted
        }
    }
}
