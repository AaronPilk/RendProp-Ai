import Foundation

/// Central app configuration + feature flags.
/// Phase 2 features are stubbed behind flags — see docs/MASTER-BUILD-PROMPT.md.
enum Config {
    // MARK: - Backend (Supabase + Cloudflare) — see docs/BACKEND-ARCHITECTURE.md §2

    /// Supabase project root, e.g. https://<project-ref>.supabase.co
    /// Source of truth for both the API (`/functions/v1`) and Auth (`/auth/v1`).
    /// Reads Info.plist key `RENDPROP_SUPABASE_URL` (inject via a build setting /
    /// xcconfig) if present, otherwise the constant below.
    /// TODO: replace <project-ref> with the real Supabase project ref (runbook §6.1).
    static let supabaseURL: URL? = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "RENDPROP_SUPABASE_URL") as? String,
           !s.isEmpty, let u = URL(string: s) { return u }
        return URL(string: "https://ymgqpbnjpztwjsyvceld.supabase.co")   // dedicated RendProp project (Pro)
    }()

    /// Supabase Edge Functions base — the API surface LiveAPIClient talks to
    /// (`.../functions/v1/listings`, `/uploads`, `/renders`, `/me`, …).
    /// nil only if `supabaseURL` is unset → LiveAPIClient.init? fails → Mock.
    static var apiBaseURL: URL? { supabaseURL?.appendingPathComponent("functions/v1") }

    /// Supabase **anon** (publishable) key — sent as the `apikey` header on every
    /// request. Public by design; RLS enforces access. This is NOT the
    /// service-role key (that stays server-side only — architecture §4).
    /// Reads Info.plist `RENDPROP_SUPABASE_ANON_KEY` if present, else the constant.
    /// TODO: paste the project's anon key (runbook §6.1).
    static let supabaseAnonKey: String = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "RENDPROP_SUPABASE_ANON_KEY") as? String,
           !s.isEmpty { return s }
        // Supabase anon key (public by design; RLS enforces access).
        return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InltZ3FwYm5qcHp0d2pzeXZjZWxkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzk5OTAsImV4cCI6MjEwMjgxNTk5MH0.oUknRmqxoRGWPaYJCaOudGaXwe5w4tfKqqZ9cAPbfW0"
    }()

    /// Master switch. false = MockAPIClient (fully offline dev).
    /// true = LiveAPIClient against Supabase (LIVE). The backend (edge functions +
    /// schema) is deployed on project ymgqpbnjpztwjsyvceld. Going live still needs
    /// the operator to set function secrets (R2 + provider keys), enable a public
    /// URL on the rendprop-renders bucket, and turn on Apple auth — see
    /// services/supabase/DEPLOYMENT.md. Until then, owner calls will error (expected).
    static let useLiveBackend = true

    /// Builds the active API client from `useLiveBackend`. Falls back to Mock if
    /// the live client can't be constructed (e.g. no base URL). Single source of
    /// truth so AppModel and UploadManager stay in sync.
    static func makeAPIClient() -> APIClient {
        if useLiveBackend, let live = LiveAPIClient() { return live }
        return MockAPIClient()
    }

    enum UploadMode: String, CaseIterable, Identifiable {
        case simulate   // no network: chunk-reads the file from disk, realistic progress
        case direct     // presigned PUT/multipart (R2/S3-style) via background URLSession
        case tus        // TODO: TUSKit path — enable when a tus server exists (master spec 4.4)

        var id: String { rawValue }
        var label: String {
            switch self {
            case .simulate: return "Simulate (offline dev)"
            case .direct:   return "Direct (presigned URL)"
            case .tus:      return "tus (resumable server)"
            }
        }
    }

    static var uploadMode: UploadMode {
        UploadMode(rawValue: UserDefaults.standard.string(forKey: "uploadMode") ?? "") ?? .simulate
    }

    /// Warn before uploading files larger than this over cellular.
    static let cellularWarnBytes: Int64 = 500_000_000

    // Phase 2 flags — keep false until wired (master spec Parts 4.5, 9, 18)
    // enableAuth now means: Sign in with Apple → Supabase Auth (apple provider) →
    // JWT held by AuthStore. false = dev stub (always "signed in", no token).
    // Live requires auth: owner edge functions need a Supabase JWT, which comes
    // from Sign in with Apple. Gating is at PUBLISH time only — capture + on-device
    // render stay usable offline. Needs the "Sign in with Apple" capability +
    // entitlement and the Apple provider enabled in Supabase Auth before publish
    // will actually succeed (DEPLOYMENT.md).
    static let enableAuth = true       // Sign in with Apple → Supabase; tokens in Keychain
    static let enableIAP  = false      // TODO: StoreKit 2 consumable credits + subs
    static let enablePush = false      // TODO: APNs render-ready / lead-received
    static let showTutorials = false   // flip on once tutorial videos are filmed (no "coming soon" placeholders ship)
}
