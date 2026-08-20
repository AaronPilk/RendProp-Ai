import Foundation

/// Holds the Supabase session (JWT) for the app.
///
/// - When `Config.enableAuth == false` (dev): behaves like the old stub —
///   always "signed in", no token. LiveAPIClient simply sends no `Authorization`.
/// - When `Config.enableAuth == true`: Sign in with Apple → exchange the Apple
///   identity token with Supabase Auth (`/auth/v1/token?grant_type=id_token`) →
///   persist the JWT. LiveAPIClient reads `AuthStore.currentAccessToken` on
///   every request.
///
/// MVP token storage is UserDefaults. TODO: move to Keychain (secure, survives
/// backup rules) before shipping — see the persist helpers below.
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published var isSignedIn: Bool
    @Published var userName: String
    @Published var orgName: String

    private enum Keys {
        static let accessToken  = "auth.supabase.accessToken"
        static let refreshToken = "auth.supabase.refreshToken"
        static let userName     = "auth.userName"
        static let orgName      = "auth.orgName"
    }

    init() {
        let hasToken = UserDefaults.standard.string(forKey: Keys.accessToken) != nil
        // Dev stub stays "signed in"; real auth gates on a persisted token.
        self.isSignedIn = Config.enableAuth ? hasToken : true
        self.userName = UserDefaults.standard.string(forKey: Keys.userName) ?? "Dev Agent"
        self.orgName  = UserDefaults.standard.string(forKey: Keys.orgName)  ?? "Rendprop Dev"
    }

    // MARK: - Token access (read by LiveAPIClient, any thread)

    /// Current Supabase JWT, or nil when signed out. Read at request-build time.
    /// TODO: back this with Keychain instead of UserDefaults.
    static var currentAccessToken: String? {
        UserDefaults.standard.string(forKey: Keys.accessToken)
    }

    private static func persistTokens(access: String, refresh: String?) {
        // TODO: Keychain. UserDefaults is fine for dev/TestFlight only.
        let d = UserDefaults.standard
        d.set(access, forKey: Keys.accessToken)
        if let refresh { d.set(refresh, forKey: Keys.refreshToken) }
    }

    private static func clearTokens() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.accessToken)
        d.removeObject(forKey: Keys.refreshToken)
    }

    // MARK: - Session lifecycle

    @MainActor
    private func applySession(accessToken: String, refreshToken: String?) {
        Self.persistTokens(access: accessToken, refresh: refreshToken)
        isSignedIn = true
    }

    @MainActor
    func signOut() {
        Self.clearTokens()
        isSignedIn = Config.enableAuth ? false : true
    }

    // MARK: - Sign in with Apple → Supabase

    /// Entry point for the Sign in with Apple button. Behind `enableAuth`.
    ///
    /// TODO (remaining real-flow wiring): present an `ASAuthorizationController`
    /// with `ASAuthorizationAppleIDProvider().createRequest()` (scopes: .fullName,
    /// .email; set a `nonce`), grab `credential.identityToken` in the delegate,
    /// then call `exchangeAppleIdentityToken(idToken:nonce:)`. The exchange +
    /// token persistence below are already implemented and tested-ready.
    func signInWithApple() async throws {
        guard Config.enableAuth else { return }         // dev stub: no-op
        // let idToken = <ASAuthorizationAppleIDCredential.identityToken as UTF-8>
        // let nonce   = <the nonce you attached to the request>
        // try await exchangeAppleIdentityToken(idToken: idToken, nonce: nonce)
        throw APIError.notConfigured                     // until the Apple credential flow is wired
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
        await applySession(accessToken: session.accessToken, refreshToken: session.refreshToken)
    }

    private struct SupabaseSession: Decodable {
        let accessToken: String
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }
}
