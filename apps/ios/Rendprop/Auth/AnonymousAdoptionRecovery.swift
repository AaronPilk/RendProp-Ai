import Foundation

/// One durable Keychain item, written before replacing the anonymous session.
/// The locally decoded JWT only binds retries; Auth verifies both identities.
/// No credential is logged, stored in defaults, or installed as the active
/// session while refreshing the source. A different account can never inherit
/// a pending transfer merely by signing in on the same phone.
@MainActor
final class AnonymousAdoptionRecovery {
    struct Pending: Codable, Equatable {
        let version: Int
        let operationID: UUID
        let sourceUserID: UUID
        let destinationUserID: UUID
        var sourceAccessToken: String
        var sourceRefreshToken: String?
    }
    enum RecoveryError: Error { case invalidIdentity, storage, conflict, malformed }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let read: () throws -> String?
    private let write: (String) -> Bool
    private let remove: () -> Bool
    private let send: Transport
    private let apiBase: URL
    private let authBase: URL
    private let anonKey: String
    private let changed: (String?) -> Void
    private let prepareLocal: (Pending) -> Bool
    private let finishLocal: (Pending, UUID) -> Bool
    private var running = false

    init(apiBase: URL, authBase: URL, anonKey: String,
         read: @escaping () throws -> String?, write: @escaping (String) -> Bool,
         remove: @escaping () -> Bool, send: @escaping Transport,
         changed: @escaping (String?) -> Void = { _ in },
         prepareLocal: @escaping (Pending) -> Bool = { _ in false },
         finishLocal: @escaping (Pending, UUID) -> Bool = { _, _ in false }) {
        self.apiBase = apiBase; self.authBase = authBase; self.anonKey = anonKey
        self.read = read; self.write = write; self.remove = remove
        self.send = send; self.changed = changed
        self.prepareLocal = prepareLocal; self.finishLocal = finishLocal
    }

    static func identity(_ token: String) -> (id: UUID, anonymous: Bool)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 4096 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let bytes = Data(base64Encoded: text),
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let subject = json["sub"] as? String, let id = UUID(uuidString: subject),
              let anonymous = json["is_anonymous"] as? Bool else { return nil }
        return (id, anonymous)
    }

    func pending() throws -> Pending? {
        guard let raw = try read() else { return nil }
        guard raw.utf8.count <= 16384, let bytes = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(Pending.self, from: bytes), value.version == 1,
              value.sourceUserID != value.destinationUserID,
              let identity = Self.identity(value.sourceAccessToken), identity.anonymous,
              identity.id == value.sourceUserID,
              (value.sourceRefreshToken?.utf8.count ?? 0) < 4096 else { throw RecoveryError.malformed }
        return value
    }

    private func save(_ value: Pending) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 16384, let raw = String(data: bytes, encoding: .utf8), write(raw) else {
            throw RecoveryError.storage
        }
    }

    /// This must finish successfully BEFORE AuthStore overwrites either token.
    /// Preserve an earlier operation; never silently evict another workspace.
    func prepare(sourceAccess: String, sourceRefresh: String?, destinationAccess: String) throws {
        guard let source = Self.identity(sourceAccess), source.anonymous,
              let destination = Self.identity(destinationAccess), !destination.anonymous,
              source.id != destination.id else { throw RecoveryError.invalidIdentity }
        if var prior = try pending() {
            guard prior.sourceUserID == source.id, prior.destinationUserID == destination.id else {
                throw RecoveryError.conflict
            }
            // A crash before applying the destination can leave this source
            // active; its ordinary auto-refresh may since have rotated tokens.
            // Preserve the operation but capture those newest credentials.
            if prior.sourceAccessToken != sourceAccess || prior.sourceRefreshToken != sourceRefresh {
                prior.sourceAccessToken = sourceAccess
                prior.sourceRefreshToken = sourceRefresh
                try save(prior)
            }
            guard prepareLocal(prior) else { throw RecoveryError.storage }
            return
        }
        let value = Pending(version: 1, operationID: UUID(), sourceUserID: source.id,
                         destinationUserID: destination.id, sourceAccessToken: sourceAccess,
                         sourceRefreshToken: sourceRefresh)
        try save(value)
        guard prepareLocal(value) else { throw RecoveryError.storage }
        changed("Your original workspace is waiting to be connected to this account.")
    }

    private func request(_ url: URL, body: [String: Any], bearer: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct Receipt: Decodable {
        let ok: Bool; let adopted: Bool; let operation_id: UUID
        let source_user_id: UUID; let destination_user_id: UUID; let org_id: UUID
    }
    private struct SourceSession: Decodable {
        let access_token: String; let refresh_token: String
    }

    /// At most one source refresh and two adoption requests per invocation.
    /// A caller generation guard fences logout/account-switch during any await;
    /// a late result must not clear recovery or refresh another account's UI.
    func retry(destinationAccess: String, isCurrent: @escaping () -> Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            guard var value = try pending() else { changed(nil); return }
            guard let destination = Self.identity(destinationAccess), !destination.anonymous,
                  destination.id == value.destinationUserID, isCurrent() else {
                changed("A workspace transfer is saved for another account. Sign in to that account to retry.")
                return
            }
            changed("Connecting your original workspace…")
            for attempt in 0...1 {
                guard !Task.isCancelled, isCurrent() else { return }
                let req = try request(apiBase.appendingPathComponent("adopt"), body: [
                    "anonymous_token": value.sourceAccessToken,
                    "operation_id": value.operationID.uuidString.lowercased(),
                    "source_user_id": value.sourceUserID.uuidString.lowercased(),
                    "destination_user_id": value.destinationUserID.uuidString.lowercased(),
                ], bearer: destinationAccess)
                let (data, response) = try await send(req)
                guard !Task.isCancelled, isCurrent() else { return }
                if (200..<300).contains(response.statusCode),
                   let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                   receipt.ok, receipt.adopted, receipt.operation_id == value.operationID,
                   receipt.source_user_id == value.sourceUserID,
                   receipt.destination_user_id == value.destinationUserID {
                    // The local metadata rebind and its confirmation marker
                    // must commit atomically before discarding source recovery.
                    guard finishLocal(value, receipt.org_id) else { throw RecoveryError.storage }
                    guard remove() else { throw RecoveryError.storage }
                    changed(nil)
                    return
                }
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if response.statusCode == 409, body?["adoption_state"] as? String == "source_session_expired",
                   attempt == 0, let refresh = value.sourceRefreshToken, !refresh.isEmpty {
                    var components = URLComponents(url: authBase.appendingPathComponent("token"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
                    let refreshRequest = try request(components.url!, body: ["refresh_token": refresh])
                    let (bytes, reply) = try await send(refreshRequest)
                    guard (200..<300).contains(reply.statusCode),
                          let session = try? JSONDecoder().decode(SourceSession.self, from: bytes),
                          let identity = Self.identity(session.access_token), identity.anonymous,
                          identity.id == value.sourceUserID, !session.refresh_token.isEmpty,
                          session.refresh_token.utf8.count < 4096 else {
                        guard !Task.isCancelled, isCurrent() else { return }
                        changed([400, 401, 403].contains(reply.statusCode)
                            ? "Your original workspace needs recovery help. Its saved handoff has not been discarded."
                            : "Workspace recovery is temporarily unavailable. The saved handoff will retry later.")
                        return
                    }
                    value.sourceAccessToken = session.access_token
                    value.sourceRefreshToken = session.refresh_token
                    // Refresh rotation happened remotely even if logout/switch
                    // occurred while waiting. Preserve that SAME pending source
                    // credential without touching the active session or its UI.
                    guard try pending()?.operationID == value.operationID else { return }
                    try save(value) // rotated credentials durable BEFORE another request
                    guard !Task.isCancelled, isCurrent() else { return }
                    continue
                }
                changed(response.statusCode == 409 && body?["adoption_state"] as? String == "source_session_expired"
                    ? "Your original workspace needs recovery help. Its saved handoff has not been discarded."
                    : "Your original workspace has not been confirmed. Its saved handoff will retry when this account reconnects.")
                return
            }
        } catch {
            if !Task.isCancelled, isCurrent() {
                changed("Your original workspace is still pending. Recovery details were not discarded; please reconnect to retry.")
            }
        }
    }
}
