import Foundation
import Combine

@MainActor final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    @Published private(set) var snapshot: WorkspaceContext.Snapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSwitching = false
    @Published private(set) var errorMessage: String?
    private var loadedOwner: UUID?
    private var operation: UUID?
    var selected: WorkspaceMembership? { snapshot?.selected }
    var workspaces: [WorkspaceMembership] { snapshot?.workspaces ?? [] }
    var displayName: String { selected?.displayName ?? "Choose a workspace" }

    init() { snapshot = WorkspaceContext.current; loadedOwner = WorkspaceContext.owner() }

    /// Membership refresh does not let another device silently retarget this
    /// device. A removed selection becomes an explicit choice, never a fallback.
    func refresh() async {
        guard Config.useLiveBackend, let owner = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        if loadedOwner != owner { snapshot = WorkspaceContext.read(owner: owner); loadedOwner = owner }
        let op = UUID(); operation = op; isLoading = true
        let revision = AuthStore.shared.syncSessionRevision
        defer { if operation == op { isLoading = false } }
        do {
            let data = try await request(path: "workspaces", method: "GET", body: nil, owner: owner, revision: revision)
            struct Response: Decodable { let active_org_id: UUID?; let workspaces: [WorkspaceMembership] }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard operation == op else { return }
            let previous = WorkspaceContext.read(owner: owner)
            let selection = previous.map { prior in result.workspaces.contains(where: { $0.id == prior.selectedOrgID }) ? prior.selectedOrgID : nil } ?? result.active_org_id
            try apply(.init(selectedOrgID: selection, workspaces: result.workspaces), owner: owner)
            errorMessage = nil
        } catch {
            guard operation == op, AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner else { return }
            errorMessage = UserFacingError.message(error, fallback: "Couldn't load your workspaces. Your saved work is safe; try again when connected.")
        }
    }

    func select(_ membership: WorkspaceMembership) async -> Bool {
        guard !isSwitching, let owner = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              workspaces.contains(membership) else { return false }
        if selected?.id == membership.id { return true }
        isSwitching = true; operation = UUID()
        let revision = AuthStore.shared.syncSessionRevision
        defer { isSwitching = false }
        do {
            let bytes = try await request(path: "workspace", method: "POST", body: ["org_id": membership.id.uuidString.lowercased()], owner: owner, revision: revision)
            struct Response: Decodable { let org_id: UUID }
            guard try JSONDecoder().decode(Response.self, from: bytes).org_id == membership.id else { throw CloudSyncError.invalidResponse }
            try apply(.init(selectedOrgID: membership.id, workspaces: workspaces), owner: owner)
            errorMessage = nil
            return true
        } catch {
            guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner else { return false }
            errorMessage = UserFacingError.message(error, fallback: "Couldn't switch workspaces. Your current workspace is unchanged.")
            return false
        }
    }

    private func apply(_ value: WorkspaceContext.Snapshot, owner: UUID) throws {
        let previous = WorkspaceContext.read(owner: owner)?.selectedOrgID
        guard WorkspaceContext.save(value, owner: owner) else { throw CloudSyncError.invalidResponse }
        snapshot = value; loadedOwner = owner
        if previous != value.selectedOrgID {
            AuthStore.shared.workspaceDidChange()
            AuthStore.shared.orgName = value.selected?.displayName ?? ""
            NotificationCenter.default.post(name: .rendpropWorkspaceChanged, object: nil)
            NotificationCenter.default.post(name: .rendpropPlanChanged, object: nil)
        }
    }

    private func request(path: String, method: String, body: [String: Any]?, owner: UUID, revision: UInt64) async throws -> Data {
        guard let base = Config.apiBaseURL, let token = await AuthStore.validAccessToken() else { throw APIError.notConfigured }
        guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }
        var req = URLRequest(url: base.appendingPathComponent("me").appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw LiveAPIClient.serverError(status: http.statusCode, data: data) }
        return data
    }
}
