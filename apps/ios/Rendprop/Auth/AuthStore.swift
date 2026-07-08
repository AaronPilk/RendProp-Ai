import Foundation

/// Dev stub — always "signed in".
/// TODO Phase 2 (master spec Part 4.5): Sign in with Apple + email/phone OTP,
/// JWT + refresh in Keychain, org/roles. Gated by Config.enableAuth.
final class AuthStore: ObservableObject {
    @Published var isSignedIn = true
    let userName = "Dev Agent"
    let orgName = "Rendprop Dev"
}
