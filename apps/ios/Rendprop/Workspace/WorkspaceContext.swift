import Foundation

struct WorkspaceMembership: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String?
    let role: String
    var accessMode: String? = nil
    var libraryOwnerUserID: UUID? = nil
    var billingOrgID: UUID? = nil
    var canRead: Bool? = nil
    var canWrite: Bool? = nil
    var canManageSubscription: Bool? = nil
    enum CodingKeys: String, CodingKey {
        case id, name, role
        case accessMode = "access_mode", libraryOwnerUserID = "library_owner_user_id"
        case billingOrgID = "billing_org_id", canRead = "can_read", canWrite = "can_write"
        case canManageSubscription = "can_manage_subscription"
    }
    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Listing library" : value
    }
    var roleLabel: String {
        switch role { case "owner": return "Owner"; case "team_owner": return "Team owner"; case "admin": return "Admin"; case "marketing": return "Marketing"; default: return "Agent" }
    }
}

/// Server-declared library access is separate from subscription sponsorship.
/// A private library's ordinary owner role never grants access to other agents.
struct WorkspaceDirectory: Codable, Equatable, Sendable {
    let actorID: UUID
    let ownOrgID: UUID
    let billingOrgID: UUID
    let canSwitchAgentLibraries: Bool
    var activeOrgID: UUID
    let workspaces: [WorkspaceMembership]
    enum CodingKeys: String, CodingKey {
        case actorID = "actor_id", ownOrgID = "own_org_id", billingOrgID = "billing_org_id"
        case canSwitchAgentLibraries = "can_switch_agent_libraries"
        case activeOrgID = "active_org_id", workspaces
    }
    func checked(actor: UUID) -> Self? {
        guard actorID == actor, !workspaces.isEmpty, workspaces.count <= 10_000,
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.contains(where: { $0.id == activeOrgID }),
              workspaces.contains(where: { $0.id == ownOrgID && $0.accessMode == "own" && $0.libraryOwnerUserID == actor }),
              workspaces.allSatisfy({ member in
                  guard member.canRead == true, member.billingOrgID != nil,
                        member.canWrite != nil, member.canManageSubscription != nil else { return false }
                  if member.accessMode == "own" {
                      return member.role == "owner" && member.libraryOwnerUserID == actor
                  }
                  return canSwitchAgentLibraries && member.accessMode == "team_owner"
                      && member.role == "team_owner" && member.libraryOwnerUserID != nil
                      && member.libraryOwnerUserID != actor && member.canManageSubscription == false
              }), selectionChoices.contains(where: { $0.id == activeOrgID }) else { return nil }
        return self
    }
    func selecting(_ org: UUID) -> Self? {
        guard workspaces.contains(where: { $0.id == org }) else { return nil }
        var copy = self; copy.activeOrgID = org
        return copy
    }
    var ownLibrary: WorkspaceMembership? { workspaces.first { $0.id == ownOrgID } }
    var selectionChoices: [WorkspaceMembership] {
        canSwitchAgentLibraries ? workspaces : ownLibrary.map { [$0] } ?? []
    }
    /// A fresh default-directory response may recover an old shared-Team
    /// selection. An explicit switch still has to match an offered row.
    func refreshedSelection(previous: UUID?) -> UUID {
        if let previous, selectionChoices.contains(where: { $0.id == previous }) { return previous }
        return canSwitchAgentLibraries ? activeOrgID : ownOrgID
    }
}

enum WorkspaceEntryPresentation: Equatable {
    case hidden, switchAgent, reconnect
    static func mode(canSwitch: Bool, choices: Int, selected: Bool, showsRecovery: Bool) -> Self {
        if canSwitch && choices > 1 { return .switchAgent }
        return showsRecovery && !selected ? .reconnect : .hidden
    }
}

/// Non-secret, account-scoped routing metadata. Every request captures this
/// before awaiting auth; a subsequent selection never rewrites that request.
enum WorkspaceContext {
    struct Snapshot: Codable, Equatable {
        var selectedOrgID: UUID?
        var workspaces: [WorkspaceMembership]
        var directory: WorkspaceDirectory? = nil
        var selected: WorkspaceMembership? { workspaces.first { $0.id == selectedOrgID } }
    }
    static func owner(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: "auth.supabase.userID").flatMap(UUID.init(uuidString:))
    }
    static func key(_ owner: UUID) -> String { "workspace.selection.v1." + owner.uuidString.lowercased() }
    static func read(owner: UUID, defaults: UserDefaults = .standard) -> Snapshot? {
        guard let bytes = defaults.data(forKey: key(owner)), let value = try? JSONDecoder().decode(Snapshot.self, from: bytes),
              Set(value.workspaces.map(\.id)).count == value.workspaces.count,
              value.selectedOrgID == nil || value.selected != nil,
              value.directory.map({ $0.checked(actor: owner) != nil && $0.workspaces == value.workspaces && $0.activeOrgID == value.selectedOrgID }) ?? true else { return nil }
        return value
    }
    @discardableResult static func save(_ value: Snapshot, owner: UUID, defaults: UserDefaults = .standard) -> Bool {
        guard Set(value.workspaces.map(\.id)).count == value.workspaces.count,
              value.selectedOrgID == nil || value.selected != nil,
              value.directory.map({ $0.checked(actor: owner) != nil && $0.workspaces == value.workspaces && $0.activeOrgID == value.selectedOrgID }) ?? true,
              let bytes = try? JSONEncoder().encode(value) else { return false }
        defaults.set(bytes, forKey: key(owner))
        guard defaults.synchronize() else { return false }
        return read(owner: owner, defaults: defaults) == value
    }
    static var current: Snapshot? { owner().flatMap { read(owner: $0) } }
    static var selectedOrgID: UUID? { current?.selected?.id }
    /// This is a routing hint only. Purchases still obtain fresh server billing
    /// authority, and persisted transaction bindings keep their original org.
    static var billingOrgID: UUID? {
        guard let owner = owner(), let current = read(owner: owner) else { return nil }
        return current.directory?.checked(actor: owner)?.billingOrgID ?? current.selected?.id
    }
    /// Serving can be funded by a Team or an isolated testing grant. It does
    /// not change the account's stable subscription purchase destination.
    static var servingOrgID: UUID? { current?.selected?.billingOrgID ?? selectedOrgID }
    /// Legacy branding is migrated once into the first confirmed workspace.
    static var storagePrefix: String {
        guard let owner = owner() else { return "" }
        let org = selectedOrgID?.uuidString.lowercased() ?? "unselected"
        return "workspace.\(owner.uuidString.lowercased()).\(org)."
    }
}

extension Notification.Name {
    static let rendpropWorkspaceChanged = Notification.Name("rendprop.workspaceChanged")
}

/// Non-secret industry preferences belong to the account. Appearance remains
/// a device preference, and transaction recovery bindings are not erased here.
enum AccountLocalPreferences {
    private static let allowedSpaces = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"]
    static func activate(previous: UUID?, next: UUID, defaults: UserDefaults = .standard) {
        if let previous, let raw = defaults.string(forKey: "space.type"), allowedSpaces.contains(raw) {
            defaults.set(raw, forKey: "account.space.type.v1." + previous.uuidString.lowercased())
        }
        let saved = defaults.string(forKey: "account.space.type.v1." + next.uuidString.lowercased())
        defaults.set(saved.flatMap { allowedSpaces.contains($0) ? $0 : nil } ?? "real_estate", forKey: "space.type")
    }
    static func eraseDeviceCache(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix("workspace.selection.v1.") || key.hasPrefix("workspace.") || key.hasPrefix("account.space.type.v1.") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "space.type")
    }
}
