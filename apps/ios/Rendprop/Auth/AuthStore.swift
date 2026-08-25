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
/// MVP token storage is UserDefaults. TODO: move to Keychain (secure, survives
/// backup rules) before shipping — see the persist helpers below.
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published var isSignedIn: Bool
    @Published var userName: String
    @Published var orgName: String

    /// Strong ref to the in-flight Sign in with Apple coordinator — the delegate
    /// must outlive `performRequests()` until its callback fires.
    private var appleCoordinator: AppleSignInCoordinator?

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
