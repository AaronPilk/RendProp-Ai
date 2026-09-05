import Foundation

// MARK: - "Test all keys" — wire models + client (GET /admin/providers/probe)
//
// The owner console has always been able to say whether an API key is SET. It
// has never been able to say whether one WORKS — and those are different
// questions with the same answer on screen, which is the worst kind of
// dashboard. `GET /admin/providers/probe` makes one $0, read-only call per
// vendor (a list / credits / status endpoint, never a generation) and reports
// what each one actually said.
//
// Server: services/supabase/functions/admin/probe.ts — that file holds the
// endpoint table, a doc URL per vendor, and the bad-key status code each one
// was verified against. Route + shape: docs/LAUNCH-CONTRACT.md § Key probe.
//
// New-file rule (docs/handoff/A-detail.md §5 and COMMON.md): nobody edits
// `Networking/APIClient.swift`, so this ships as `protocol AdminProbeAPI` +
// `extension LiveAPIClient` + `extension MockAPIClient`, and the console calls
// it through `model.api as? AdminProbeAPI`. A build whose client does not
// conform draws an honest "not in this app build" row instead of a broken
// button — same pattern as `AdminRoutingAPI` in SettingsView.swift.
//
// NOTHING HERE EVER RENDERS A CREDENTIAL, because the server never sends one:
// `envNames` are NAMES, `message` has already been redacted and truncated to 80
// characters server-side, and `detail` carries scalars (credits, characters)
// only.

// MARK: Scalars

/// One `detail` value. The server promises a string or a number and nothing
/// else; anything unexpected decodes as text rather than failing the whole
/// report, because one odd field must never cost the owner the other twelve
/// rows.
enum AdminProbeScalar: Decodable, Hashable, Sendable {
    case text(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? single.decode(Bool.self) {
            self = .text(value ? "yes" : "no")
            return
        }
        if let value = try? single.decode(String.self) {
            self = .text(value)
            return
        }
        self = .text("—")
    }

    /// Grouped for humans: 142000 reads "142,000", 4.5 reads "4.5".
    var display: String {
        switch self {
        case .text(let value):
            return value
        case .number(let value):
            return AdminProbeFormat.number(value)
        }
    }
}

// MARK: Results

/// One vendor's answer. Every field is optional and defaulted: the console must
/// keep drawing against an older or newer server build, and an unknown
/// `errorClass` falls through to the neutral branch rather than crashing.
struct AdminProbeResult: Decodable, Hashable, Sendable {
    /// Matches the provider `key` in `GET /admin/providers` where one exists.
    var key: String? = nil
    /// Every env var this probe needs is set to a non-empty value.
    var configured: Bool? = nil
    /// true = the vendor authenticated the key · false = it did not, or we
    /// couldn't reach it · nil = NOT TESTABLE. nil is never drawn as a pass.
    var ok: Bool? = nil
    var latencyMs: Int? = nil
    /// "auth" | "network" | "rate_limit" | "other".
    var errorClass: String? = nil
    /// Plain words: what was called, and what a pass proves.
    var how: String? = nil
    /// Already redacted and capped at 80 characters by the server.
    var message: String? = nil
    /// Credits / quota worth knowing. Scalars only.
    var detail: [String: AdminProbeScalar]? = nil
    /// Env var NAMES. Never a value — the server has none to send.
    var envNames: [String]? = nil
    var doc: String? = nil

    var displayName: String { AdminProbeText.providerName(key) }
    var envList: [String] { envNames ?? [] }

    /// The single state this row is in. Everything on screen keys off this.
    var state: AdminProbeState {
        if configured == false { return .notSet }
        guard let ok else { return .notTestable }
        if ok { return .working }
        switch (errorClass ?? "").lowercased() {
        case "auth":       return .wrongKey
        case "network":    return .unreachable
        case "rate_limit": return .rateLimited
        default:           return .otherFailure
        }
    }

    /// "2,027 credits left · Tier: creator". Empty when there is nothing to say.
    var detailPhrase: String {
        guard let detail, !detail.isEmpty else { return "" }
        return detail
            .sorted { $0.key < $1.key }
            .map { AdminProbeText.detailPhrase(key: $0.key, value: $0.value) }
            .joined(separator: " · ")
    }
}

/// What one row means, in the owner's words rather than the vendor's.
enum AdminProbeState: Hashable, Sendable {
    case working
    case wrongKey
    case unreachable
    case rateLimited
    case otherFailure
    case notSet
    case notTestable

    var label: String {
        switch self {
        case .working:      return "Working"
        case .wrongKey:     return "Failed: wrong key"
        case .unreachable:  return "Failed: can't reach"
        case .rateLimited:  return "Rate limited"
        case .otherFailure: return "Failed"
        case .notSet:       return "Not set"
        case .notTestable:  return "Can't test"
        }
    }

    var isFailure: Bool {
        switch self {
        case .wrongKey, .unreachable, .rateLimited, .otherFailure: return true
        case .working, .notSet, .notTestable:                      return false
        }
    }
}

/// `GET /admin/providers/probe`.
struct AdminProbeReport: Decodable, Hashable, Sendable {
    var checkedAt: String? = nil
    var probeCount: Int? = nil
    var okCount: Int? = nil
    var failCount: Int? = nil
    var notProbeableCount: Int? = nil
    var results: [AdminProbeResult]? = nil
    /// False when the server could not remember this run (never fatal).
    var lastProbeRecorded: Bool? = nil

    var resultList: [AdminProbeResult] { results ?? [] }

    /// Failures first, then can't-test, then working — the owner opens this
    /// screen to find what is broken, so the broken thing is at the top.
    /// Sorted on (rank, original index) so ties keep the server's own order:
    /// `sorted(by:)` is not documented as stable, and a list that reshuffles
    /// itself between two identical runs reads as a bug.
    var sortedResults: [AdminProbeResult] {
        let indexed: [(offset: Int, element: AdminProbeResult)] = Array(resultList.enumerated())
        let ordered = indexed.sorted { lhs, rhs in
            let left = AdminProbeReport.rank(lhs.element.state)
            let right = AdminProbeReport.rank(rhs.element.state)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        return ordered.map { $0.element }
    }

    private static func rank(_ state: AdminProbeState) -> Int {
        switch state {
        case .wrongKey:     return 0
        case .otherFailure: return 1
        case .unreachable:  return 2
        case .rateLimited:  return 3
        case .notTestable:  return 4
        case .notSet:       return 5
        case .working:      return 6
        }
    }
}

/// The `last_probe` block on `GET /admin/providers` — when the keys were last
/// actually tested. nil until the owner has pressed the button once.
struct AdminProbeLastRun: Decodable, Hashable, Sendable {
    var at: String? = nil
    var okCount: Int? = nil
    var failCount: Int? = nil
}

/// Only the one field this file needs from `GET /admin/providers`. Decoding the
/// whole inventory again would duplicate `AdminProvidersReport`, which lives in
/// `Networking/APIClient.swift` and is not ours to change. HANDOFF-P4.md
/// carries the one-line addition that lets the integrator delete this.
private struct AdminProvidersLastProbeEnvelope: Decodable {
    var lastProbe: AdminProbeLastRun? = nil
}

// MARK: - The protocol

protocol AdminProbeAPI {
    /// `GET /admin/providers/probe` — runs every probe server-side. Slow by
    /// design (eleven vendors, 8 s ceiling each) and rate limited to 6/hour per
    /// admin; a 429 arrives as `APIError.server(status: 429, code:
    /// "rate_limited", …)` carrying a sentence the console shows verbatim.
    func adminProbeKeys() async throws -> AdminProbeReport

    /// The `last_probe` block from `GET /admin/providers`. nil when nothing has
    /// been tested yet, or when the server build predates the field.
    func adminLastKeyProbe() async throws -> AdminProbeLastRun?
}

// MARK: - Live

/// The probe waits on eleven third parties at once, so it needs a longer
/// deadline than an ordinary console read. Same mechanism `LiveAPIClient` uses
/// for `Config.aiRequestTimeout` — a `URLSessionConfiguration` with an explicit
/// `timeoutIntervalForRequest` — but its `aiSession` is private to that file,
/// so this is its own one-line session rather than a copy of the whole client.
enum AdminProbeTransport {
    /// Server ceiling is 8 s per probe, all concurrent, so ~10 s is the real
    /// worst case. 30 s is headroom, not patience.
    static let timeout: TimeInterval = 30

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 60)
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `{base}/admin/{path…}`, each segment appended separately so nothing can
    /// string-join its way out of the route.
    static func adminURL(_ segments: [String]) -> URL? {
        guard var url = Config.apiBaseURL else { return nil }
        url.appendPathComponent("admin")
        for segment in segments { url.appendPathComponent(segment) }
        return url
    }

    /// The same three headers every owner route carries. The bearer is fetched
    /// through `validAccessToken()`, which refreshes a stale JWT first.
    static func request(_ url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if Config.enableAuth, let token = await AuthStore.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Send, verify 2xx, otherwise map the server's `{error, code}` envelope
    /// through `LiveAPIClient.serverError` so a 401/403/429 classifies exactly
    /// as it does on every other admin route.
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveAPIClient.serverError(status: http.statusCode, data: data)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}

extension LiveAPIClient: AdminProbeAPI {
    func adminProbeKeys() async throws -> AdminProbeReport {
        guard let url = AdminProbeTransport.adminURL(["providers", "probe"]) else {
            throw APIError.badResponse(-1)
        }
        let request = await AdminProbeTransport.request(url)
        let data = try await AdminProbeTransport.send(request)
        return try AdminProbeTransport.decode(AdminProbeReport.self, from: data)
    }

    func adminLastKeyProbe() async throws -> AdminProbeLastRun? {
        guard let url = AdminProbeTransport.adminURL(["providers"]) else {
            throw APIError.badResponse(-1)
        }
        let request = await AdminProbeTransport.request(url)
        let data = try await AdminProbeTransport.send(request)
        let envelope = try AdminProbeTransport.decode(
            AdminProvidersLastProbeEnvelope.self, from: data)
        return envelope.lastProbe
    }
}

// MARK: - Mock

extension MockAPIClient: AdminProbeAPI {
    /// A deliberately MIXED offline report, so the UI walk (P5) photographs every
    /// state this screen can be in: working with a quota, working without one,
    /// a wrong key, an unreachable vendor, a rate limit, a key that isn't set,
    /// and one that cannot be tested at all.
    func adminProbeKeys() async throws -> AdminProbeReport {
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // feel like a real test

        let results: [AdminProbeResult] = [
            AdminProbeResult(
                key: "gemini", configured: true, ok: true, latencyMs: 212,
                how: "GET generativelanguage.googleapis.com/v1beta/models?pageSize=1 — lists model names only, generates nothing",
                envNames: ["GEMINI_API_KEY"]),
            AdminProbeResult(
                key: "fal", configured: true, ok: true, latencyMs: 341,
                how: "GET api.fal.ai/v1/models?limit=1 — model index, no generation",
                detail: ["modelsVisible": .number(1)],
                envNames: ["FAL_KEY"]),
            AdminProbeResult(
                key: "anthropic", configured: true, ok: true, latencyMs: 268,
                how: "GET api.anthropic.com/v1/models?limit=1 — model metadata, zero tokens billed",
                envNames: ["ANTHROPIC_API_KEY"]),
            AdminProbeResult(
                key: "openai", configured: true, ok: true, latencyMs: 305,
                how: "GET api.openai.com/v1/models?limit=1 — lists model ids, generates nothing",
                envNames: ["OPENAI_API_KEY"]),
            AdminProbeResult(
                key: "elevenlabs", configured: true, ok: false, latencyMs: 380,
                errorClass: "auth",
                how: "GET api.elevenlabs.io/v1/user/subscription — your own plan and character quota, generates no audio",
                message: "Rejected the key (HTTP 401)",
                envNames: ["ELEVENLABS_API_KEY"]),
            AdminProbeResult(
                key: "kie", configured: false, ok: nil,
                how: "GET api.kie.ai/api/v1/chat/credit — remaining credits, generates nothing",
                message: "Not set, so there is nothing to test",
                envNames: ["KIE_API_KEY"]),
            AdminProbeResult(
                key: "higgsfield", configured: true, ok: true, latencyMs: 452,
                how: "GET api.higgsfield.ai/requests/{unknown-id}/status — 404 means the key authenticated",
                message: "Signed in (the test request id is deliberately unknown)",
                envNames: ["HIGGSFIELD_API_KEY_ID", "HIGGSFIELD_API_KEY_SECRET"]),
            AdminProbeResult(
                key: "worldlabs", configured: true, ok: true, latencyMs: 511,
                how: "GET api.worldlabs.ai/marble/v1/credits — remaining credits, builds no world",
                detail: ["creditsLeft": .number(2027)],
                envNames: ["WORLDLABS_API_KEY"]),
            AdminProbeResult(
                key: "cloudflare_r2", configured: true, ok: true, latencyMs: 129,
                how: "Signed ListObjectsV2 (max-keys=1) on the uploads bucket — moves no bytes",
                detail: ["bucket": .text("rendprop-uploads")],
                envNames: ["CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]),
            AdminProbeResult(
                key: "cloudflare_stream", configured: true, ok: false, latencyMs: 8000,
                errorClass: "network",
                how: "GET api.cloudflare.com/client/v4/accounts/{id}/stream?per_page=1 — lists at most one video",
                message: "No answer in 8 seconds",
                envNames: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_STREAM_TOKEN"]),
            AdminProbeResult(
                key: "ghl", configured: true, ok: true, latencyMs: 240,
                how: "GET services.leadconnectorhq.com/locations/{id} — reads the CRM location, creates no contact",
                envNames: ["GHL_API_KEY", "GHL_LOCATION_ID"]),
            AdminProbeResult(
                key: "turnstile", configured: true, ok: true, latencyMs: 98,
                how: "POST siteverify with a token that was never issued — anything but \"invalid-input-secret\" means the secret is right",
                message: "Secret accepted (the test token was expected to fail)",
                envNames: ["TURNSTILE_SECRET_KEY"]),
            AdminProbeResult(
                key: "apple", configured: true, ok: true, latencyMs: 3,
                how: "Imports the .p8 private key. Apple has no free test endpoint: signing in needs a real person",
                message: "Private key parses. Signing in still needs a real person",
                envNames: ["APPLE_TEAM_ID", "APPLE_CLIENT_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY_P8"]),
        ]

        return AdminProbeReport(
            checkedAt: AdminProbeFormat.iso(Date()),
            probeCount: results.count,
            okCount: results.filter { $0.ok == true }.count,
            failCount: results.filter { $0.ok == false }.count,
            notProbeableCount: results.filter { $0.ok == nil }.count,
            results: results,
            lastProbeRecorded: true)
    }

    func adminLastKeyProbe() async throws -> AdminProbeLastRun? {
        AdminProbeLastRun(
            at: AdminProbeFormat.iso(Date().addingTimeInterval(-12 * 60)),
            okCount: 10,
            failCount: 2)
    }
}

// MARK: - Copy helpers
//
// Plain `String`s built OUTSIDE any SwiftUI body. SettingsView.swift has a
// type-checker-timeout history; nothing assembled here is ever handed to the
// view solver as an expression.

enum AdminProbeText {
    /// Provider key → the name the owner would use. `AdminText.pretty` alone
    /// renders "fal" as "Fal" and "ghl" as "Ghl", so the ones that matter get a
    /// real entry and anything new still reads as words rather than a slug.
    static let providerNames: [String: String] = [
        "gemini":            "Google Gemini",
        "fal":               "fal.ai",
        "openai":            "OpenAI",
        "anthropic":         "Anthropic (Claude)",
        "elevenlabs":        "ElevenLabs voices",
        "kie":               "KIE.ai",
        "higgsfield":        "Higgsfield",
        "worldlabs":         "World Labs (3D)",
        "cloudflare_r2":     "Cloudflare R2 storage",
        "cloudflare_stream": "Cloudflare Stream video",
        "ghl":               "GoHighLevel CRM",
        "turnstile":         "Cloudflare Turnstile",
        "apple":             "Sign in with Apple",
    ]

    static func providerName(_ key: String?) -> String {
        let slug = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return "Unnamed service" }
        return providerNames[slug] ?? AdminText.pretty(slug)
    }

    /// One `detail` entry as a phrase. `JSONDecoder.convertFromSnakeCase`
    /// rewrites dictionary keys too, so `characters_left` arrives as
    /// `charactersLeft` — both spellings are accepted so this keeps working
    /// whichever way the decoder is configured.
    static func detailPhrase(key: String, value: AdminProbeScalar) -> String {
        let amount = value.display
        switch normalize(key) {
        case "credits left", "credits":     return amount + " credits left"
        case "characters left":             return amount + " characters left"
        case "models visible":              return amount + " models visible"
        case "videos visible":              return amount + " videos visible"
        case "tier":                        return "Plan: " + amount
        case "bucket":                      return "Bucket " + amount
        case let other:                     return amount + " " + other
        }
    }

    /// "charactersLeft" and "characters_left" both become "characters left".
    static func normalize(_ key: String) -> String {
        var out = ""
        for character in key {
            if character == "_" || character == "-" {
                out.append(" ")
            } else if character.isUppercase && !out.isEmpty && out.last != " " {
                out.append(" ")
                out.append(Character(character.lowercased()))
            } else {
                out.append(Character(character.lowercased()))
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// "212 ms" / "1.4 s". nil when the server sent no timing.
    static func latency(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds >= 0 else { return nil }
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }

    /// The caption under one row: latency, then quota, then the server's own
    /// (already redacted) sentence.
    static func caption(_ result: AdminProbeResult) -> String {
        var parts: [String] = []
        if let latency = latency(result.latencyMs) { parts.append(latency) }
        let detail = result.detailPhrase
        if !detail.isEmpty { parts.append(detail) }
        if let message = trimmed(result.message) { parts.append(message) }
        if parts.isEmpty, let envs = trimmedList(result.envList) { parts.append("Env " + envs) }
        return parts.joined(separator: " · ")
    }

    /// The headline over the list, in counts a person can read at a glance.
    static func summary(_ report: AdminProbeReport) -> String {
        let ok = report.okCount ?? report.resultList.filter { $0.ok == true }.count
        let failed = report.failCount ?? report.resultList.filter { $0.ok == false }.count
        let untested = report.notProbeableCount ?? report.resultList.filter { $0.ok == nil }.count
        if failed == 0 && untested == 0 { return "All \(ok) keys are working" }
        var parts: [String] = ["\(ok) working"]
        if failed > 0 { parts.append("\(failed) failed") }
        if untested > 0 { parts.append("\(untested) not tested") }
        return parts.joined(separator: " · ")
    }

    /// "Last tested 12 min ago: 9 ok, 1 failed". nil when never tested.
    static func lastTested(_ run: AdminProbeLastRun?) -> String? {
        guard let run, let date = AdminProbeFormat.date(run.at) else { return nil }
        var line = "Last tested " + Formatters.relative(date)
        let ok = run.okCount
        let failed = run.failCount
        if let ok, let failed {
            line += ": \(ok) ok, \(failed) failed"
        } else if let ok {
            line += ": \(ok) ok"
        }
        return line
    }

    static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func trimmedList(_ values: [String]) -> String? {
        let cleaned = values.compactMap { trimmed($0) }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }
}

enum AdminProbeFormat {
    /// Grouped integers ("142,000"); up to one decimal otherwise ("4.5").
    static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    /// Tolerant of Supabase's fractional seconds, like `LiveAPIClient.parseDate`.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
