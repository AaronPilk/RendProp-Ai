import Foundation

/// Central app configuration + feature flags.
/// Phase 2 features are stubbed behind flags — see docs/MASTER-BUILD-PROMPT.md.
enum Config {
    // MARK: - Backend (Supabase + Cloudflare) — see docs/BACKEND-ARCHITECTURE.md §2

    /// Supabase project root, e.g. https://<project-ref>.supabase.co
    /// Source of truth for both the API (`/functions/v1`) and Auth (`/auth/v1`).
    /// Reads Info.plist key `RENDPROP_SUPABASE_URL` (inject via a build setting /
    /// xcconfig) if present, otherwise the constant below.
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
    static let supabaseAnonKey: String = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "RENDPROP_SUPABASE_ANON_KEY") as? String,
           !s.isEmpty { return s }
        // Supabase anon key (public by design; RLS enforces access).
        return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InltZ3FwYm5qcHp0d2pzeXZjZWxkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMzk5OTAsImV4cCI6MjEwMjgxNTk5MH0.oUknRmqxoRGWPaYJCaOudGaXwe5w4tfKqqZ9cAPbfW0"
    }()

    /// Master switch. false = MockAPIClient (fully offline dev — believable
    /// sample data, simulated uploads, AI features report "needs the live
    /// backend"). true = LiveAPIClient against the deployed Supabase project
    /// (edge functions + schema on ymgqpbnjpztwjsyvceld). Owner routes need a
    /// Supabase JWT from Sign in with Apple (`enableAuth`); the app gates only
    /// PUBLISH-time actions on it — capture and on-device render stay offline.
    static let useLiveBackend = true

    /// True when the app was launched by the automated UI walk
    /// (`RendpropUITests`, which passes `-uiTesting`). The walk exists to
    /// screenshot every screen, so it must never touch the live backend: no
    /// real customer, no real spend figure and no real share link can end up
    /// in a PNG the owner forwards to somebody. Read at launch only.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    /// Builds the active API client from `useLiveBackend`. Falls back to Mock if
    /// the live client can't be constructed (e.g. no base URL). Single source of
    /// truth so AppModel and UploadManager stay in sync.
    static func makeAPIClient() -> APIClient {
        // The UI walk is checked BEFORE the live client: `-uiTesting` always
        // means the offline mock, whatever `useLiveBackend` says.
        if isUITesting { return MockAPIClient() }
        if useLiveBackend, let live = LiveAPIClient() { return live }
        return MockAPIClient()
    }

    // NOTE: the old `UploadMode` / `uploadMode` (simulate | direct | tus) was dead
    // config — nothing read it. UploadManager keys off `useLiveBackend` alone:
    // live → the server-chosen single/multipart path, offline → simulate.

    /// Warn before uploading files larger than this over cellular.
    static let cellularWarnBytes: Int64 = 500_000_000

    /// Request timeout for the AI routes (`/ai-photo`, `/ai-video/*`). A Gemini
    /// photo edit routinely takes 20–60 s and the edge function itself allows
    /// ~150 s, so the default 60 s URLSession timeout cut real edits off.
    static let aiRequestTimeout: TimeInterval = 120

    /// Where a 402 (plan boundary) "Upgrade plan" CTA sends the user. Prices are
    /// shown ONLY on the web — never compiled into the app (App Store 3.1).
    ///
    /// STOREFRONT-GATED (App Store 3.1.1(a) / 3.1.3). An "Upgrade plan" button
    /// that opens rendprop.com is a call to action pointing at a purchasing
    /// mechanism other than in-app purchase. Since 1 May 2025 that is expressly
    /// permitted, with no entitlement, for apps on the UNITED STATES storefront
    /// — and it is still a rejection on every other storefront. So this returns
    /// nil off the US storefront (and while the storefront is still unknown),
    /// which makes every upgrade CTA in the app disappear rather than ship a
    /// violation. `Storefronts.shared.resolve()` runs once at launch from
    /// `RootTabView`. Nothing else in the app links to pricing — keep it that
    /// way: route any new CTA through this property.
    @MainActor
    static var pricingURL: URL? {
        guard Storefronts.shared.allowsExternalPurchaseLinks else { return nil }
        return URL(string: "https://rendprop.com/pricing")
    }

    // Phase 2 flags — keep false until wired (master spec Parts 4.5, 9, 18)
    // enableAuth now means: Sign in with Apple → Supabase Auth (apple provider) →
    // JWT held by AuthStore. false = dev stub (always "signed in", no token).
    // Live requires auth: owner edge functions need a Supabase JWT, which comes
    // from Sign in with Apple. Gating is at PUBLISH time only — capture + on-device
    // render stay usable offline. Needs the "Sign in with Apple" capability +
    // entitlement and the Apple provider enabled in Supabase Auth before publish
    // will actually succeed (DEPLOYMENT.md).
    static let enableAuth = true       // Sign in with Apple → Supabase; tokens in Keychain
    static let enableIAP  = true       // StoreKit 2 auto-renewable subscriptions (Purchases/) — read by nothing yet; documents the state
    static let enablePush = false      // TODO: APNs render-ready / lead-received
    static let showTutorials = false   // flip on once tutorial videos are filmed (no "coming soon" placeholders ship)
}
