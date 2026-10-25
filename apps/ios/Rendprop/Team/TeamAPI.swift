import Foundation

/// Display-only compatibility contract for the private owner-testing grant.
/// Other large caps stay finite, and zero/negative values keep their usual meaning.
/// The server remains the authority for every allowance and paid operation.
enum WorkspaceAllowanceDisplay {
    static let ownerTestingUnlimitedCap = Int(Int32.max)

    static func isUnlimitedTesting(cap: Int, plan: String?, source: String? = nil) -> Bool {
        cap == ownerTestingUnlimitedCap && plan?.lowercased() == "team" &&
            (source == nil || source?.lowercased() == "manual")
    }

    static func value(used: Int?, cap: Int, plan: String?, source: String? = nil) -> String {
        if isUnlimitedTesting(cap: cap, plan: plan, source: source) {
            return "\(used ?? 0) used · Unlimited"
        }
        return cap > 0 ? "\(used ?? 0) of \(cap)" : "Not included"
    }
}

// Seats: the app half of services/supabase/functions/team.
//
// DELIBERATELY NOT ON THE `APIClient` PROTOCOL. Every method added there must
// also be added to MockAPIClient, which the XCUITest screenshot walk runs
// against, so a protocol change is a change to the screenshot walk too. Seats
// are a self-contained corner of Settings that no other screen calls, so this
// talks to the edge function directly with the same four lines of auth every
// other direct caller uses (AuthStore.adoptAnonymousWork). ~40 lines of
// boilerplate against zero blast radius on a 520k-line file we have to ship.
//
// THE ONE APP STORE RULE THIS FILE MUST KEEP: nothing here may link out to buy
// anything. Guideline 3.1.1 makes an external purchase link an instant
// rejection, and the seat count is exactly the place a "buy more seats" button
// wants to appear. When the team is full, the only route offered is the
// existing StoreKit paywall.

struct TeamSummary: Decodable, Sendable {
    let orgId: String
    var actorId: String? = nil
    var contentOrgId: String? = nil
    let orgName: String?
    let plan: String?
    /// Optional on older /team responses. A present nonmanual source cannot
    /// claim the private testing grant even when its numeric cap matches.
    let planSource: String?
    let accessMode: String?
    let canManage: Bool
    let seats: Seats
    let members: [Member]
    let invites: [Invite]

    var isPrivateTesting: Bool { accessMode == "private_testing" }
    var accessLabel: String { isPrivateTesting ? "Private testing accounts" : "Private agent accounts" }
    var accessExplanation: String {
        isPrivateTesting
            ? "Each tester keeps their own homes, tours and leads private from other testers. The Team owner can manage authorized testers’ listings."
            : "Each agent keeps their own listings, tours and leads. The Team owner can switch between authorized agents’ listings; invited agents see only their own."
    }

    var hasUnlimitedTestingSeats: Bool {
        WorkspaceAllowanceDisplay.isUnlimitedTesting(cap: seats.allowed, plan: plan, source: planSource)
    }

    var seatUsageLabel: String {
        if hasUnlimitedTestingSeats {
            return WorkspaceAllowanceDisplay.value(used: seats.used, cap: seats.allowed, plan: plan, source: planSource)
        }
        return "\(seats.used) of \(seats.allowed)"
    }

    struct Seats: Decodable, Sendable {
        let used: Int
        let allowed: Int
        var isFull: Bool { used >= allowed }
        var remaining: Int { max(0, allowed - used) }
    }

    struct Member: Decodable, Sendable, Identifiable {
        let userId: String
        let role: String
        let name: String?
        let email: String?
        let isYou: Bool
        let accessMode: String?
        var id: String { userId }
        var isPrivateTesting: Bool { accessMode == "private_testing" }

        /// What to show as the person's name. An invited agent who signed in
        /// with Apple and withheld their name has neither, so the role is the
        /// honest fallback — never a raw uuid.
        var displayName: String {
            if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            if let e = email?.trimmingCharacters(in: .whitespaces), !e.isEmpty { return e }
            return roleLabel
        }
        var roleLabel: String {
            if isPrivateTesting { return "Private testing account" }
            switch role {
            case "owner":     return "Owner"
            case "admin":     return "Admin"
            case "marketing": return "Marketing"
            default:          return "Agent"
            }
        }
        var removalExplanation: String {
            isPrivateTesting
                ? "Their testing access ends. Their private homes, tours and leads stay in their own account."
                : "\(displayName)’s Team plan access ends. Their private listings, tours and leads remain in their own account."
        }
    }

    struct Invite: Decodable, Sendable, Identifiable {
        let id: String
        let email: String?
        let role: String
        let expiresAt: String?

        var emailLabel: String {
            let e = email?.trimmingCharacters(in: .whitespaces) ?? ""
            return e.isEmpty ? "Invite link" : e
        }
        /// "Expires in 6 days". Nil when the server's timestamp can't be read —
        /// a display detail must never be the reason a row fails to draw.
        var expiryLabel: String? {
            guard let date = TeamAPI.parseTimestamp(expiresAt) else { return nil }
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            if days < 0 { return "Expired" }
            if days == 0 { return "Expires today" }
            return "Expires in \(days) day\(days == 1 ? "" : "s")"
        }
    }
}

struct TeamInviteCreated: Decodable, Sendable {
    let id: String
    let email: String?
    let role: String
    let code: String
    let expiresAt: String?
    /// Queue acceptance is not email delivery; absent on older deployments.
    let emailQueued: Bool?
}

struct TeamJoined: Decodable, Sendable {
    let ok: Bool
    let orgId: String
    let orgName: String?
    let role: String?
    let accessMode: String?
    let teamName: String?

    var confirmationMessage: String {
        if accessMode == "private_testing" {
            return "\(teamName ?? "The team") provides your testing access. Your homes, tours and leads stay private in your own workspace. Other people's listings are not added to your account."
        }
        return "You’ve joined \(teamName ?? orgName ?? "the Team") while keeping your own listings, tours and leads. Only the Team owner can switch between authorized agents’ listings."
    }
}

enum TeamAPI {

    /// The server's own words, which are written for a person. A route that
    /// can say "your plan includes 2 seats and 2 are taken" must be allowed to
    /// say it — a generic "something went wrong" here would hide the one fact
    /// the owner needs.
    struct Failure: LocalizedError {
        let status: Int
        let code: String?
        let message: String
        var errorDescription: String? { message }
        /// The team is full. The caller offers the paywall, never a web link.
        var isSeatLimit: Bool { code == "quota_exceeded" || status == 402 }
        /// The caller is an anonymous session and must sign in with Apple.
        var needsIdentity: Bool { status == 403 && message.contains("Sign in with Apple") }
    }

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Postgres sends fractional seconds; ISO8601DateFormatter needs to be
        // told, and older rows may not have them. Try both rather than losing
        // the row.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }

    @MainActor private static func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        let actor = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision
        let org = WorkspaceContext.selectedOrgID
        guard org != nil || path == "accept" else { throw CloudSyncError.identityChanged }
        guard let base = Config.apiBaseURL else {
            throw Failure(status: 0, code: nil, message: "Rendprop isn't configured for the network yet.")
        }
        guard let token = await AuthStore.validAccessToken() else {
            throw Failure(status: 401, code: "unauthorized",
                          message: "This iPhone hasn't reached Rendprop yet. Check your connection and try again.")
        }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }
        var url = base.appendingPathComponent("team")
        for part in path.split(separator: "/") where !part.isEmpty {
            url.appendPathComponent(String(part))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let org { req.setValue(org.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id") }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure(status: 0, code: nil,
                          message: "Couldn't reach Rendprop. Check your connection and try again.")
        }
        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else { throw CloudSyncError.identityChanged }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct ErrDTO: Decodable { let error: String?; let code: String? }
            let dto = try? JSONDecoder().decode(ErrDTO.self, from: data)
            throw Failure(status: status, code: dto?.code,
                          message: dto?.error ?? "Something went wrong (\(status)).")
        }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder()
        // convertFromSnakeCase ONLY — no explicit CodingKeys anywhere in this
        // file. The two are mutually exclusive: the strategy rewrites the JSON
        // key to camelCase and then matches it against CodingKey.stringValue,
        // so a snake_case CodingKey can never match. That combination is what
        // silently broke the coach for weeks.
        d.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try d.decode(T.self, from: data)
        } catch {
            throw Failure(status: 200, code: nil,
                          message: "Rendprop sent something this version can't read. Update the app and try again.")
        }
    }

    @MainActor static func summary() async throws -> TeamSummary {
        let actor = AuthStore.shared.userID, content = WorkspaceContext.selectedOrgID
        let billing = WorkspaceContext.billingOrgID
        let result: TeamSummary = try decode(try await request("", method: "GET"))
        guard let content, let billing, UUID(uuidString: result.orgId) == billing,
              result.actorId == actor, result.contentOrgId.flatMap(UUID.init(uuidString:)) == content,
              WorkspaceContext.selectedOrgID == content, WorkspaceContext.billingOrgID == billing else { throw CloudSyncError.identityChanged }
        return result
    }

    @MainActor static func invite(email: String?, role: String = "agent") async throws -> TeamInviteCreated {
        var body: [String: Any] = ["role": role]
        if let email, !email.trimmingCharacters(in: .whitespaces).isEmpty {
            body["email"] = email.trimmingCharacters(in: .whitespaces)
        }
        // Throws rather than falling back: an invite whose code failed to
        // decode would hand the owner an empty code to read out, and a seat
        // would sit held by an invite nobody can use.
        return try decode(try await request("invites", method: "POST", body: body))
    }

    @MainActor static func revoke(inviteId: String) async throws {
        _ = try await request("invites/\(inviteId)", method: "DELETE")
    }

    @MainActor static func remove(userId: String) async throws {
        _ = try await request("members/\(userId)", method: "DELETE")
    }

    @MainActor static func join(code: String) async throws -> TeamJoined {
        try decode(try await request("accept", method: "POST", body: ["code": code]))
    }
}
