import Foundation

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
    let orgName: String?
    let plan: String?
    let canManage: Bool
    let seats: Seats
    let members: [Member]
    let invites: [Invite]

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
        var id: String { userId }

        /// What to show as the person's name. An invited agent who signed in
        /// with Apple and withheld their name has neither, so the role is the
        /// honest fallback — never a raw uuid.
        var displayName: String {
            if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            if let e = email?.trimmingCharacters(in: .whitespaces), !e.isEmpty { return e }
            return roleLabel
        }
        var roleLabel: String {
            switch role {
            case "owner":     return "Owner"
            case "admin":     return "Admin"
            case "marketing": return "Marketing"
            default:          return "Agent"
            }
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
}

struct TeamJoined: Decodable, Sendable {
    let ok: Bool
    let orgId: String
    let orgName: String?
    let role: String?
}

enum TeamAPI {

    /// The server's own words, which are written for a person. A route that
    /// can say "your plan includes 3 seats and 3 are taken" must be allowed to
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

    private static func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        guard let base = Config.apiBaseURL else {
            throw Failure(status: 0, code: nil, message: "Rendprop isn't configured for the network yet.")
        }
        guard let token = await AuthStore.validAccessToken() else {
            throw Failure(status: 401, code: "unauthorized",
                          message: "This iPhone hasn't reached Rendprop yet. Check your connection and try again.")
        }
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
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure(status: 0, code: nil,
                          message: "Couldn't reach Rendprop. Check your connection and try again.")
        }
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

    static func summary() async throws -> TeamSummary {
        try decode(try await request("", method: "GET"))
    }

    static func invite(email: String?, role: String = "agent") async throws -> TeamInviteCreated {
        var body: [String: Any] = ["role": role]
        if let email, !email.trimmingCharacters(in: .whitespaces).isEmpty {
            body["email"] = email.trimmingCharacters(in: .whitespaces)
        }
        // Throws rather than falling back: an invite whose code failed to
        // decode would hand the owner an empty code to read out, and a seat
        // would sit held by an invite nobody can use.
        return try decode(try await request("invites", method: "POST", body: body))
    }

    static func revoke(inviteId: String) async throws {
        _ = try await request("invites/\(inviteId)", method: "DELETE")
    }

    static func remove(userId: String) async throws {
        _ = try await request("members/\(userId)", method: "DELETE")
    }

    static func join(code: String) async throws -> TeamJoined {
        try decode(try await request("accept", method: "POST", body: ["code": code]))
    }
}
