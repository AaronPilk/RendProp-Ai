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
    private var verifiedDirectory: WorkspaceDirectory?
    private var verifiedRevision: UInt64?
    var selected: WorkspaceMembership? {
        // Cached delegated rows never reopen another person's cards. Only a
        // fresh directory from this actor and session enables delegation.
        if let directory = currentDirectory { return directory.workspaces.first { $0.id == snapshot?.selectedOrgID } }
        guard let owner = loadedOwner, owner == WorkspaceContext.owner(),
              let member = snapshot?.selected, member.accessMode == "own", member.libraryOwnerUserID == owner else { return nil }
        return member
    }
    private var currentDirectory: WorkspaceDirectory? {
        guard let owner = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)), owner == loadedOwner,
              verifiedRevision == AuthStore.shared.syncSessionRevision else { return nil }
        return verifiedDirectory?.checked(actor: owner)
    }
    var workspaces: [WorkspaceMembership] { currentDirectory?.workspaces ?? [] }
    var selectionChoices: [WorkspaceMembership] { currentDirectory?.selectionChoices ?? [] }
    var canSwitchAgentLibraries: Bool { currentDirectory?.canSwitchAgentLibraries == true }
    func canViewLibrary(_ org: UUID) -> Bool {
        if let directory = currentDirectory { return directory.selectionChoices.contains { $0.id == org } }
        return selected?.id == org
    }
    var displayName: String { selected?.displayName ?? "Choose a listing library" }

    init() { snapshot = WorkspaceContext.current; loadedOwner = WorkspaceContext.owner() }

    /// Preserve an authorized local selection. A fresh default directory can
    /// recover a removed shared-Team selection into this actor's private library.
    func refresh() async {
        guard Config.useLiveBackend, let owner = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        if loadedOwner != owner {
            snapshot = WorkspaceContext.read(owner: owner); loadedOwner = owner
            verifiedDirectory = nil; verifiedRevision = nil
        }
        let op = UUID(); operation = op; isLoading = true
        let revision = AuthStore.shared.syncSessionRevision
        defer { if operation == op { isLoading = false } }
        do {
            let data = try await request(path: "workspaces", method: "GET", body: nil, owner: owner, revision: revision)
            guard let result = try JSONDecoder().decode(WorkspaceDirectory.self, from: data).checked(actor: owner)
                else { throw CloudSyncError.invalidResponse }
            guard operation == op else { return }
            let previous = WorkspaceContext.read(owner: owner)
            let selection = result.refreshedSelection(previous: previous?.selectedOrgID)
            guard let directory = result.selecting(selection) else { throw CloudSyncError.invalidResponse }
            try apply(.init(selectedOrgID: selection, workspaces: result.workspaces, directory: directory), owner: owner)
            verifiedDirectory = directory; verifiedRevision = AuthStore.shared.syncSessionRevision
            errorMessage = nil
        } catch {
            guard operation == op, AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner else { return }
            if Self.isAuthorityFailure(error) { invalidateAuthority(owner: owner) }
            errorMessage = UserFacingError.message(error, fallback: "Couldn't load your listing libraries. Your saved work is safe; try again when connected.")
        }
    }

    func select(_ membership: WorkspaceMembership) async -> Bool {
        guard !isSwitching, let owner = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)),
              let directory = currentDirectory, directory.selectionChoices.contains(membership) else { return false }
        if selected?.id == membership.id { return true }
        isSwitching = true; operation = UUID()
        let revision = AuthStore.shared.syncSessionRevision
        defer { isSwitching = false }
        do {
            let bytes = try await request(path: "workspace", method: "POST", body: ["org_id": membership.id.uuidString.lowercased()], owner: owner, revision: revision)
            struct Response: Decodable { let org_id: UUID }
            guard try JSONDecoder().decode(Response.self, from: bytes).org_id == membership.id else { throw CloudSyncError.invalidResponse }
            guard let selection = directory.selecting(membership.id) else { throw CloudSyncError.invalidResponse }
            try apply(.init(selectedOrgID: membership.id, workspaces: selection.workspaces, directory: selection), owner: owner)
            verifiedDirectory = selection; verifiedRevision = AuthStore.shared.syncSessionRevision
            errorMessage = nil
            return true
        } catch {
            guard AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == owner else { return false }
            if Self.isAuthorityFailure(error) { invalidateAuthority(owner: owner) }
            errorMessage = UserFacingError.message(error, fallback: "Couldn't switch listing libraries. Your current library is unchanged.")
            return false
        }
    }

    /// A permission/deletion refusal or malformed authority response revokes
    /// cached delegation immediately. Transport failures retain own offline work.
    static func isAuthorityFailure(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let cloud = error as? CloudSyncError, case .invalidResponse = cloud { return true }
        if let api = error as? APIError {
            switch api {
            case .decoding: return true
            case .badResponse(let status): return status < 0 || [400, 401, 403, 404, 409, 410].contains(status)
            case .server(let status, _, _): return [400, 401, 403, 404, 409, 410].contains(status)
            default: break
            }
        }
        return false
    }

    private func invalidateAuthority(owner: UUID) {
        let hadAuthority = verifiedDirectory != nil || snapshot?.selectedOrgID != nil
        verifiedDirectory = nil; verifiedRevision = nil
        let ownRows = (snapshot?.workspaces ?? []).filter { $0.accessMode == "own" && $0.libraryOwnerUserID == owner }
        let disconnected = WorkspaceContext.Snapshot(selectedOrgID: nil, workspaces: ownRows)
        _ = WorkspaceContext.save(disconnected, owner: owner)
        snapshot = disconnected
        if hadAuthority {
            AuthStore.shared.workspaceDidChange()
            AuthStore.shared.orgName = ""
            NotificationCenter.default.post(name: .rendpropWorkspaceChanged, object: nil)
            NotificationCenter.default.post(name: .rendpropPlanChanged, object: nil)
        }
    }

    private func apply(_ value: WorkspaceContext.Snapshot, owner: UUID) throws {
        let previousSnapshot = WorkspaceContext.read(owner: owner)
        let previous = previousSnapshot?.selectedOrgID
        guard WorkspaceContext.save(value, owner: owner) else { throw CloudSyncError.invalidResponse }
        snapshot = value; loadedOwner = owner
        if previous != value.selectedOrgID || previousSnapshot?.directory != value.directory {
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
