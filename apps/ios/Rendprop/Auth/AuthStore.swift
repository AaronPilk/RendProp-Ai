import Foundation
import CryptoKit
import Security
import UIKit
import os

/// Holds the Supabase session (JWT) for the app.
///
/// - When `Config.enableAuth == false` (dev): behaves like the old stub —
///   always "signed in", no token. LiveAPIClient simply sends no `Authorization`.
/// - When `Config.enableAuth == true`: Sign in with Apple (the `SignInView`
///   sheet in Screens/RenderStatusView.swift, using `SignInWithAppleButton`) →
///   exchange the Apple identity token with Supabase Auth
///   (`/auth/v1/token?grant_type=id_token`) → persist the JWT. LiveAPIClient
///   refreshes via `validAccessToken()` right before every request.
///
/// Tokens live in the KEYCHAIN (kSecClassGenericPassword, AfterFirstUnlock,
/// ThisDeviceOnly). Sessions persisted by earlier builds in UserDefaults are
/// migrated on first read and removed from UserDefaults. Only the non-secret
/// expiry timestamp, the account id (JWT `sub`) and display names stay in
/// UserDefaults.
///
/// Account switches: the JWT `sub` is persisted; when a DIFFERENT account signs
/// in, `onAccountChanged` fires so the app can drop per-account state
/// (`serverID`/`shareSlug`/`shareURL` on listings belong to the old org).
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published var isSignedIn: Bool
    /// The person's name (from Apple's one-time `fullName`, or the server's
    /// profile name). Empty when unknown — the UI shows "Signed in with Apple".
    @Published var displayName: String
    /// Legacy alias of `displayName` (older screens read/assign it). Assigning
    /// either keeps both in sync and persists.
    @Published var userName: String {
        didSet {
            if userName != displayName { setDisplayName(userName) }
        }
    }
    @Published var orgName: String
    /// Supabase user id (JWT `sub`) of the current/last session. Non-secret.
    @Published private(set) var userID: String?

    /// Fired (main thread) when a DIFFERENT account signs in than the one that
    /// last used this device — the app clears per-account listing state.
    var onAccountChanged: (() -> Void)?

    /// Single-flight guard so concurrent callers share one network refresh.
    @MainActor private var refreshInFlight: Task<Bool, Never>?
    /// Long-lived loop that refreshes the token shortly before each expiry.
    @MainActor private var autoRefreshTask: Task<Void, Never>?
    /// Foreground observer — refreshes on every return to the foreground (the
    /// token routinely expires while the app is suspended).
    private var foregroundObserver: NSObjectProtocol?

    private static let log = Logger(subsystem: "com.rendprop.app", category: "auth")

    private enum Keys {
        static let accessToken  = "auth.supabase.accessToken"
        static let refreshToken = "auth.supabase.refreshToken"
        static let expiresAt    = "auth.supabase.expiresAt"    // unix seconds
        static let userID       = "auth.supabase.userID"       // JWT sub (non-secret)
        static let userName     = "auth.userName"              // display name (Apple fullName / profile)
        static let orgName      = "auth.orgName"
    }

    // MARK: - Keychain-backed secret storage

    /// Minimal generic-password Keychain wrapper. AfterFirstUnlock so the
    /// background auto-refresh loop can read tokens; ThisDeviceOnly so they
    /// never ride an unencrypted backup to another device. Write failures are
    /// LOGGED (status code only — never a value): a silently failed write left
    /// the previous rotated refresh token in place, which then 400'd on the
    /// next refresh and forced a sign-out.
    private enum SecureStore {
        private static let service = "com.rendprop.app.auth"

        private static func baseQuery(_ key: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: key]
        }

        static func get(_ key: String) -> String? {
            var query = baseQuery(key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            guard status == errSecSuccess,
                  let data = out as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                if status != errSecItemNotFound {
                    AuthStore.log.error("Keychain read failed for \(key, privacy: .public): \(Int(status))")
                }
                return nil
            }
            return str
        }

        @discardableResult
        static func set(_ key: String, _ value: String) -> Bool {
            let data = Data(value.utf8)
            var query = baseQuery(key)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(query as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    // Lost the add/update race — update the item that appeared.
                    status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
                }
            }
            if status != errSecSuccess {
                AuthStore.log.error("Keychain write failed for \(key, privacy: .public): \(Int(status))")
                return false
            }
            return true
        }

        static func remove(_ key: String) {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                AuthStore.log.error("Keychain delete failed for \(key, privacy: .public): \(Int(status))")
            }
        }
    }

    /// Keychain first; falls back to (and silently migrates from) the legacy
    /// UserDefaults slot so pre-Keychain sessions survive the update.
    private static func secret(_ key: String) -> String? {
        if let v = SecureStore.get(key) { return v }
        if let legacy = UserDefaults.standard.string(forKey: key) {
            if SecureStore.set(key, legacy) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return legacy
        }
        return nil
    }

    static func storedAccessToken() -> String? { secret(Keys.accessToken) }
    private static func storedRefreshToken() -> String? { secret(Keys.refreshToken) }

    init() {
        let hasToken = Self.storedAccessToken() != nil
        // Dev stub stays "signed in"; real auth gates on a persisted token.
        self.isSignedIn = Config.enableAuth ? hasToken : true
        let storedName = UserDefaults.standard.string(forKey: Keys.userName) ?? ""
        // The pre-audit placeholder "Dev Agent" must never surface as a name.
        let name = storedName == "Dev Agent" ? "" : storedName
        self.displayName = name
        self.userName = name
        let storedOrg = UserDefaults.standard.string(forKey: Keys.orgName) ?? ""
        self.orgName = storedOrg == "Rendprop Dev" ? "" : storedOrg
        self.userID = UserDefaults.standard.string(forKey: Keys.userID)

        // Supabase access tokens expire (~1 h). Freshness: LiveAPIClient awaits
        // `validAccessToken()` before every request, and this store also
        // refreshes shortly before every expiry while the app runs and
        // immediately on each return to the foreground.
        if Config.enableAuth {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshIfNeeded() }
            }
            Task { @MainActor [weak self] in self?.scheduleAutoRefresh() }
        }
    }

    // MARK: - Token access (read by LiveAPIClient, any thread)

    /// Current Supabase JWT, or nil when signed out. Read at request-build time.
    /// May be STALE right at launch — `validAccessToken()` is the async accessor
    /// that guarantees freshness. Backed by the Keychain.
    static var currentAccessToken: String? {
        // First touch arms the auto-refresh loop. This accessor is called from
        // URLSession / cooperative-pool contexts (LiveAPIClient.makeRequest),
        // so the singleton is constructed ON MAIN — `init` sets @Published
        // state and registers a main-queue observer, neither of which belongs
        // on a background thread (audit F-E-24). The token read below is a
        // static Keychain lookup and does not need the instance, so nothing
        // waits for that hop.
        if Thread.isMainThread {
            _ = AuthStore.shared
        } else {
            DispatchQueue.main.async { _ = AuthStore.shared }
        }
        return storedAccessToken()
    }

    /// Unix-time expiry of the current access token. Nil for sessions persisted
    /// before expiry tracking existed (they self-heal on the first refresh).
    static var tokenExpiresAt: Date? {
        let t = UserDefaults.standard.double(forKey: Keys.expiresAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Async accessor: refreshes first when the token is near/past expiry, then
    /// returns the (now valid) JWT. Prefer this over `currentAccessToken`
    /// anywhere that can `await`.
    static func validAccessToken() async -> String? {
        await shared.refreshIfNeeded()
        return storedAccessToken()
    }

    private static func persistTokens(access: String, refresh: String?, expiresAt: Date?) {
        SecureStore.set(Keys.accessToken, access)
        if let refresh { SecureStore.set(Keys.refreshToken, refresh) }
        // Expiry is non-secret scheduling metadata — UserDefaults is fine.
        if let expiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: Keys.expiresAt)
        }
    }

    private static func clearTokens() {
        SecureStore.remove(Keys.accessToken)
        SecureStore.remove(Keys.refreshToken)
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.accessToken)    // legacy slots, belt-and-braces
        d.removeObject(forKey: Keys.refreshToken)
        d.removeObject(forKey: Keys.expiresAt)
    }

    // MARK: - Session lifecycle

    @MainActor
    private func applySession(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        // Account-switch detection BEFORE persisting: the JWT `sub` identifies
        // the Supabase user. A different `sub` than the last one on this device
        // means the cached serverID/shareSlug/shareURL on listings belong to a
        // different org — the app clears them via `onAccountChanged`.
        if let sub = Self.jwtSubject(accessToken) {
            let previous = UserDefaults.standard.string(forKey: Keys.userID)
            let switched = (previous != nil && previous != sub)
            UserDefaults.standard.set(sub, forKey: Keys.userID)
            userID = sub
            if switched {
                // The old account's name must not label the new one.
                displayName = ""
                userName = ""
                orgName = ""
                UserDefaults.standard.removeObject(forKey: Keys.userName)
                UserDefaults.standard.removeObject(forKey: Keys.orgName)
                onAccountChanged?()
            }
        }
        Self.persistTokens(access: accessToken, refresh: refreshToken, expiresAt: expiresAt)
        isSignedIn = true
        scheduleAutoRefresh()   // re-arm for the new expiry
    }

    /// Sign out: drop the session (tokens + expiry) and stop refreshing. The
    /// display name and account id stay so re-signing into the SAME account
    /// keeps its listings' server ids; a different account triggers
    /// `onAccountChanged` on its first session.
    @MainActor
    func signOut() {
        // Cancel any in-flight refresh FIRST — otherwise a refresh that resolves
        // after sign-out would call applySession and re-persist tokens, silently
        // signing the user back in (audit 2026-08-26).
        refreshInFlight?.cancel()
        refreshInFlight = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        Self.clearTokens()
        isSignedIn = Config.enableAuth ? false : true
    }

    /// Remember the person's name (Apple returns `fullName` ONLY on the first
    /// authorization — it must be captured then). Persists locally, and when
    /// the org's public brand kit has no name yet, seeds it best-effort so the
    /// hosted tour card never has to fall back to an email (audit A14).
    /// Call on the main thread (mutates `@Published` state).
    func setDisplayName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "Dev Agent" else { return }
        if displayName != trimmed { displayName = trimmed }
        if userName != trimmed { userName = trimmed }
        UserDefaults.standard.set(trimmed, forKey: Keys.userName)
        guard Config.useLiveBackend, Config.enableAuth else { return }
        Task.detached(priority: .utility) { await Self.seedBrandNameIfUnset(trimmed) }
    }

    /// Server identity from `GET /me` (profile name / org name). Fills gaps
    /// only — never overwrites a name the user gave, and never shows an email.
    @MainActor
    func applyServerIdentity(userName serverUserName: String?, orgName serverOrgName: String?) {
        if displayName.isEmpty,
           let n = serverUserName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty, !n.contains("@") {
            displayName = n
            userName = n
            UserDefaults.standard.set(n, forKey: Keys.userName)
        }
        if let o = serverOrgName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !o.isEmpty, !o.contains("@"), o != orgName {
            orgName = o
            UserDefaults.standard.set(o, forKey: Keys.orgName)
        }
    }

    /// PATCH `/me/brand {name}` when neither the local card nor the server brand
    /// kit has a name. The card editor's own sync always wins later.
    private static func seedBrandNameIfUnset(_ name: String) async {
        let cardIsSet = await MainActor.run { AgentCard.current.isSet }
        guard !cardIsSet else { return }
        let api = Config.makeAPIClient()
        guard let me = try? await api.me() else { return }
        let existing = me.brandName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existing.isEmpty else { return }
        try? await api.updateBrand(["name": name])
    }

    // MARK: - Token refresh (Supabase access tokens expire ~1 h)

    /// Refresh the session when the access token has no recorded expiry (legacy
    /// session) or is within `leeway` seconds of expiring. Cheap to call often;
    /// no-ops while the token is comfortably valid. Returns false only when a
    /// refresh was needed and did not succeed. A session with NO refresh token
    /// whose access token has expired is dead — it signs out (it used to stay
    /// "signed in" forever with a token every request rejected).
    @MainActor
    @discardableResult
    func refreshIfNeeded(leeway: TimeInterval = 60) async -> Bool {
        guard Config.enableAuth, isSignedIn else { return true }   // dev stub / signed out
        guard Self.storedRefreshToken() != nil else {
            if let expiry = Self.tokenExpiresAt, Date() >= expiry {
                signOut()
                return false
            }
            return true   // legacy session without a refresh token, not yet expired
        }
        if let expiry = Self.tokenExpiresAt, Date() < expiry.addingTimeInterval(-leeway) {
            return true   // comfortably fresh
        }
        return await runRefresh()
    }

    /// Refresh NOW regardless of the recorded expiry — used after a 401 (the
    /// server disagreed with our clock/expiry). Single-flight with
    /// `refreshIfNeeded`. Signs out when there is nothing to refresh with.
    @MainActor
    @discardableResult
    func forceRefresh() async -> Bool {
        guard Config.enableAuth, isSignedIn else { return true }
        guard Self.storedRefreshToken() != nil else {
            signOut()
            return false
        }
        return await runRefresh()
    }

    @MainActor
    private func runRefresh() async -> Bool {
        if let inFlight = refreshInFlight { return await inFlight.value }
        let task = Task { await self.performRefresh() }
        refreshInFlight = task
        let ok = await task.value
        if refreshInFlight == task { refreshInFlight = nil }
        return ok
    }

    /// POST auth/v1/token?grant_type=refresh_token, persisting the ROTATED
    /// tokens (Supabase rotates the refresh token on every use). A definitive
    /// 4xx (revoked/expired refresh token) signs the user out so the publish
    /// gate re-prompts; network errors keep the session for a later retry.
    private func performRefresh() async -> Bool {
        guard let refreshToken = Self.storedRefreshToken(),
              let authBase = Config.supabaseURL?.appendingPathComponent("auth/v1"),
              !Config.supabaseAnonKey.isEmpty,
              var comps = URLComponents(url: authBase.appendingPathComponent("token"),
                                        resolvingAgainstBaseURL: false) else { return false }
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let tokenURL = comps.url else { return false }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if Task.isCancelled { return false }   // signed out while refreshing — never resurrect
            if (200..<300).contains(http.statusCode),
               let session = try? JSONDecoder().decode(SupabaseSession.self, from: data) {
                await applySession(accessToken: session.accessToken,
                                   refreshToken: session.refreshToken ?? refreshToken,
                                   expiresAt: session.expiryDate)
                return true
            }
            if [400, 401, 403].contains(http.statusCode) {
                await signOut()   // refresh token revoked/expired — session is dead
            }
            return false
        } catch {
            return false          // offline/transient — keep tokens, retry later
        }
    }

    /// (Re)start the background loop: sleep until ~2 min before expiry, refresh,
    /// repeat. Replaced whenever a new session is applied; cancelled on sign-out.
    @MainActor
    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard Config.enableAuth,
              Self.storedRefreshToken() != nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait: TimeInterval
                if let expiry = Self.tokenExpiresAt {
                    wait = max(60, expiry.timeIntervalSinceNow - 120)
                } else {
                    wait = 5   // legacy session: learn the expiry right away
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { return }
                // Leeway > the 120 s pre-wake so the wake actually refreshes.
                let ok = await self.refreshIfNeeded(leeway: 150)
                if !ok {   // offline/transient failure — back off before retrying
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Nonce (shared with SignInView)

    /// A cryptographically-random nonce string (raw form kept for the exchange).
    static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms) != errSecSuccess {
                randoms = randoms.map { _ in UInt8.random(in: 0...255) }   // fallback (rare)
            }
            for random in randoms where remaining > 0 {
                let idx = Int(random)
                if idx < charset.count {
                    result.append(charset[idx])
                    remaining -= 1
                }
            }
        }
        return result
    }

    /// Lowercase-hex SHA256 of `input` — the value sent as the request `nonce`.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `sub` claim of a JWT (Supabase user id), decoded WITHOUT verifying
    /// the signature — it only keys local per-account state; the server
    /// verifies the token on every request.
    static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// TN3194: POST the Apple authorizationCode to the backend, which exchanges
    /// it for a refresh token stored for later revocation (account deletion).
    /// Fire-and-forget: any failure is silent — the sweeper reports unrevoked
    /// grants server-side, and sign-in must never block on this.
    static func submitAppleAuthorizationCode(_ code: String) async {
        guard Config.useLiveBackend,
              let url = Config.apiBaseURL?.appendingPathComponent("me/apple-code"),
              let token = await AuthStore.validAccessToken() else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["authorization_code": code])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Exchange an Apple identity token for a Supabase session, then persist it.
    /// `nonce` is the RAW nonce whose SHA256 was put on the Apple request —
    /// GoTrue re-hashes and compares it to the token's `nonce` claim. Throws
    /// `APIError.server` with GoTrue's own message on a rejected exchange.
    func exchangeAppleIdentityToken(idToken: String, nonce: String? = nil) async throws {
        guard let authBase = Config.supabaseURL?.appendingPathComponent("auth/v1"),
              !Config.supabaseAnonKey.isEmpty else {
            throw APIError.notConfigured
        }
        guard var comps = URLComponents(url: authBase.appendingPathComponent("token"),
                                        resolvingAgainstBaseURL: false) else {
            throw APIError.notConfigured
        }
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        guard let tokenURL = comps.url else { throw APIError.notConfigured }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        var body: [String: Any] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.authError(status: http.statusCode, data: data)
        }
        guard let session = try? JSONDecoder().decode(SupabaseSession.self, from: data) else {
            throw APIError.decoding
        }
        await applySession(accessToken: session.accessToken,
                           refreshToken: session.refreshToken,
                           expiresAt: session.expiryDate)
    }

    /// GoTrue error bodies vary (`{error, error_description}`, `{msg}`,
    /// `{message}`, `{error_code}`) — pick the human one.
    private static func authError(status: Int, data: Data) -> APIError {
        struct GoTrueError: Decodable {
            let error: String?
            let errorDescription: String?
            let msg: String?
            let message: String?
            let errorCode: String?
            enum CodingKeys: String, CodingKey {
                case error, msg, message
                case errorDescription = "error_description"
                case errorCode = "error_code"
            }
        }
        let env = try? JSONDecoder().decode(GoTrueError.self, from: data)
        let message = [env?.errorDescription, env?.msg, env?.message, env?.error]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return .server(status: status, code: env?.errorCode,
                       message: message ?? "Sign-in was rejected (status \(status)). Please try again.")
    }

    private struct SupabaseSession: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?     // seconds until expiry
        let expiresAt: Double?     // absolute unix seconds (newer GoTrue)
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
        }

        /// Prefer the absolute `expires_at`; else derive from `expires_in`.
        var expiryDate: Date? {
            if let at = expiresAt { return Date(timeIntervalSince1970: at) }
            if let inS = expiresIn { return Date().addingTimeInterval(inS) }
            return nil
        }
    }
}
