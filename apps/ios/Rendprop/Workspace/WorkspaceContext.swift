import Foundation

struct WorkspaceMembership: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String?
    let role: String
    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Workspace" : value
    }
    var roleLabel: String {
        switch role { case "owner": return "Owner"; case "admin": return "Admin"; case "marketing": return "Marketing"; default: return "Agent" }
    }
}

/// Non-secret, account-scoped routing metadata. Every request captures this
/// before awaiting auth; a subsequent selection never rewrites that request.
enum WorkspaceContext {
    struct Snapshot: Codable, Equatable {
        var selectedOrgID: UUID?
        var workspaces: [WorkspaceMembership]
        var selected: WorkspaceMembership? { workspaces.first { $0.id == selectedOrgID } }
    }
    static func owner(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: "auth.supabase.userID").flatMap(UUID.init(uuidString:))
    }
    static func key(_ owner: UUID) -> String { "workspace.selection.v1." + owner.uuidString.lowercased() }
    static func read(owner: UUID, defaults: UserDefaults = .standard) -> Snapshot? {
        guard let bytes = defaults.data(forKey: key(owner)), let value = try? JSONDecoder().decode(Snapshot.self, from: bytes),
              Set(value.workspaces.map(\.id)).count == value.workspaces.count else { return nil }
        return value
    }
    @discardableResult static func save(_ value: Snapshot, owner: UUID, defaults: UserDefaults = .standard) -> Bool {
        guard Set(value.workspaces.map(\.id)).count == value.workspaces.count,
              value.selectedOrgID == nil || value.selected != nil,
              let bytes = try? JSONEncoder().encode(value) else { return false }
        defaults.set(bytes, forKey: key(owner))
        guard defaults.synchronize() else { return false }
        return read(owner: owner, defaults: defaults) == value
    }
    static var current: Snapshot? { owner().flatMap { read(owner: $0) } }
    static var selectedOrgID: UUID? { current?.selected?.id }
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
