import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Holds the Supabase session (JWT) for the app.
///
/// - When `Config.enableAuth == false` (dev): behaves like the old stub —
///   always "signed in", no token. LiveAPIClient simply sends no `Authorization`.
/// - When `Config.enableAuth == true`: Sign in with Apple → exchange the Apple
///   identity token with Supabase Auth (`/auth/v1/token?grant_type=id_token`) →
///   persist the JWT. LiveAPIClient reads `AuthStore.currentAccessToken` on
///   every request.
///
/// Tokens live in the KEYCHAIN (kSecClassGenericPassword, AfterFirstUnlock,
/// ThisDeviceOnly). Sessions persisted by earlier builds in UserDefaults are
/// migrated on first read and removed from UserDefaults. Only the non-secret
/// expiry timestamp and display names stay in UserDefaults.
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published var isSignedIn: Bool
    @Published var userName: String
    @Published var orgName: String

    /// Strong ref to the in-flight Sign in with Apple coordinator — the delegate
    /// must outlive `performRequests()` until its callback fires.
    private var appleCoordinator: AppleSignInCoordinator?

    /// Single-flight guard so concurrent callers share one network refresh.
    @MainActor private var refreshInFlight: Task<Bool, Never>?
    /// Long-lived loop that refreshes the token shortly before each expiry.
    @MainActor private var autoRefreshTask: Task<Void, Never>?
    /// Foreground observer — refreshes on every return to the foreground (the
    /// token routinely expires while the app is suspended).
    private var foregroundObserver: NSObjectProtocol?

    private enum Keys {
        static let accessToken  = "auth.supabase.accessToken"
        static let refreshToken = "auth.supabase.refreshToken"
        static let expiresAt    = "auth.supabase.expiresAt"    // unix seconds
        static let userName     = "auth.userName"
        static let orgName      = "auth.orgName"
    }

    // MARK: - Keychain-backed secret storage

    /// Minimal generic-password Keychain wrapper. AfterFirstUnlock so the
    /// background auto-refresh loop can read tokens; ThisDeviceOnly so they
    /// never ride an unencrypted backup to another device.
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
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data,
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }

        static func set(_ key: String, _ value: String) {
            let data = Data(value.utf8)
            var query = baseQuery(key)
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(query as CFDictionary, nil)
            }
        }

        static func remove(_ key: String) {
            SecItemDelete(baseQuery(key) as CFDictionary)
        }
    }

    /// Keychain first; falls back to (and silently migrates from) the legacy
    /// UserDefaults slot so pre-Keychain sessions survive the update.
    private static func secret(_ key: String) -> String? {
        if let v = SecureStore.get(key) { return v }
        if let legacy = UserDefaults.standard.string(forKey: key) {
            SecureStore.set(key, legacy)
            UserDefaults.standard.removeObject(forKey: key)
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
        self.userName = UserDefaults.standard.string(forKey: Keys.userName) ?? "Dev Agent"
        self.orgName  = UserDefaults.standard.string(forKey: Keys.orgName)  ?? "Rendprop Dev"

        // Supabase access tokens expire (~1 h). LiveAPIClient reads
        // `currentAccessToken` SYNCHRONOUSLY at request-build time, so freshness
        // is maintained here instead: refresh shortly before every expiry while
        // the app runs, and immediately on each return to the foreground.
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
        _ = AuthStore.shared   // first touch arms the auto-refresh loop
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
        Self.persistTokens(access: accessToken, refresh: refreshToken, expiresAt: expiresAt)
        isSignedIn = true
        scheduleAutoRefresh()   // re-arm for the new expiry
    }

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

    // MARK: - Token refresh (Supabase access tokens expire ~1 h)

    /// Refresh the session when the access token has no recorded expiry (legacy
    /// session) or is within `leeway` seconds of expiring. Cheap to call often;
    /// no-ops while the token is comfortably valid. Returns false only when a
    /// refresh was needed and did not succeed.
    @MainActor
    @discardableResult
    func refreshIfNeeded(leeway: TimeInterval = 60) async -> Bool {
        guard Config.enableAuth, isSignedIn else { return true }   // dev stub / signed out
        guard Self.storedRefreshToken() != nil else {
            return true   // legacy session without a refresh token — nothing to do
        }
        if let expiry = Self.tokenExpiresAt, Date() < expiry.addingTimeInterval(-leeway) {
            return true   // comfortably fresh
        }
        if let inFlight = refreshInFlight { return await inFlight.value }
        let task = Task { await self.performRefresh() }
        refreshInFlight = task
        let ok = await task.value
        refreshInFlight = nil
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

    // MARK: - Sign in with Apple → Supabase

    /// Programmatic Sign in with Apple. Behind `enableAuth`. Generates a random
    /// nonce (+ its SHA256), presents an `ASAuthorizationController` for the
    /// Apple ID credential, then exchanges the identity token with Supabase
    /// (passing the RAW nonce — Supabase re-hashes and compares to the token's
    /// `nonce` claim). `SignInView` uses `SignInWithAppleButton` for the same
    /// exchange; this method is the equivalent entry point for non-SwiftUI call
    /// sites / re-auth.
    func signInWithApple() async throws {
        guard Config.enableAuth else { return }          // dev stub: no-op
        let raw = Self.randomNonceString()
        let hashed = Self.sha256(raw)
        let idToken = try await requestAppleIDToken(hashedNonce: hashed)
        try await exchangeAppleIdentityToken(idToken: idToken, nonce: raw)
    }

    /// Present the system Apple ID sheet and return the identity token (UTF-8).
    @MainActor
    private func requestAppleIDToken(hashedNonce: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce

            let coordinator = AppleSignInCoordinator { [weak self] result in
                self?.appleCoordinator = nil            // release after the callback
                continuation.resume(with: result)
            }
            self.appleCoordinator = coordinator          // keep alive until it fires
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
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

    /// Exchange an Apple identity token for a Supabase session, then persist it.
    /// This is the real network call — ready the moment `signInWithApple` can
    /// hand it an identity token.
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
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
        await applySession(accessToken: session.accessToken,
                           refreshToken: session.refreshToken,
                           expiresAt: session.expiryDate)
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

// MARK: - Sign in with Apple delegate
/// Bridges `ASAuthorizationController`'s delegate callbacks to a single Result
/// completion (delivered once). Also provides the presentation anchor.
private final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private let completion: (Result<String, Error>) -> Void
    private var didComplete = false

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            finish(.failure(APIError.notConfigured))
            return
        }
        finish(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let scene = active ?? scenes.first as? UIWindowScene
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
