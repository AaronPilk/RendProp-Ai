import Foundation

/// Central app configuration + feature flags.
/// Phase 2 features are stubbed behind flags — see docs/MASTER-BUILD-PROMPT.md.
enum Config {
    /// Real-network regression tests use a disposable simulator and localhost.
    /// These switches do not exist in Release and cannot point at a remote host.
    static var isSessionNetworkTesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-sessionNetworkTesting")
#else
        false
#endif
    }

    static var sessionTestRun: String {
#if DEBUG
        ProcessInfo.processInfo.environment["RENDP_TEST_RUN"] ?? "isolated"
#else
        ""
#endif
    }

    static var sessionTestURL: URL? {
#if DEBUG
        guard isSessionNetworkTesting,
              let raw = ProcessInfo.processInfo.environment["RENDP_TEST_URL"],
              let url = URL(string: raw), url.scheme == "http",
              url.host == "127.0.0.1", url.user == nil, url.password == nil else { return nil }
        return url
#else
        return nil
#endif
    }
    // MARK: - Backend (Supabase + Cloudflare) — see docs/BACKEND-ARCHITECTURE.md §2

    /// Supabase project root, e.g. https://<project-ref>.supabase.co
    /// Source of truth for both the API (`/functions/v1`) and Auth (`/auth/v1`).
    /// Reads Info.plist key `RENDPROP_SUPABASE_URL` (inject via a build setting /
    /// xcconfig) if present, otherwise the constant below.
    static let supabaseURL: URL? = {
        if isSessionNetworkTesting { return sessionTestURL }
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
        if isSessionNetworkTesting { return "local-fixture-public-key" }
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

    /// Store-screenshot seeding, UI walk only: `-ui.seedPhotosDir <dir>` names a
    /// folder of JPEG/PNG files the AI Photo Studio imports into an EMPTY real
    /// project the first time it opens, exactly as if the person had picked
    /// them - the system photo picker runs out of process and cannot be driven
    /// by XCUITest. Nil unless the app was launched by the walk (`-uiTesting`)
    /// with the argument; production launches never read it. No AI runs.
    /// `-ui.sampleLeads` (store screenshots only): the offline mock answers the
    /// Leads inbox with three invented leads. Off for every other walk, so the
    /// per-industry checks still see the honest empty inbox.
    static var uiTestSampleLeads: Bool {
        isUITesting && ProcessInfo.processInfo.arguments.contains("-ui.sampleLeads")
    }

    static var uiTestSeedPhotoURLs: [URL] {
        guard isUITesting else { return [] }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-ui.seedPhotosDir"), i + 1 < args.count else { return [] }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted()
            .filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
            .prefix(4)
            .map { dir.appendingPathComponent($0) }
    }

    /// `-ui.guideState <0-5>` (screenshots only): forces `FirstProjectGuide`'s
    /// progress to exactly N of 5 steps done, so every card state can be
    /// captured on demand — the real signals it normally reads (a captured
    /// video, room tags, a render, a share link) are otherwise slow to set up
    /// from a clean simulator. nil outside `-uiTesting`, or when the arg is
    /// missing/unparseable.
    static var uiTestGuideState: Int? {
        guard isUITesting else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-ui.guideState"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// `-ui.planBanner <trial|ending|ended|paid>` (screenshots only): forces
    /// Home's plan banner into one state. The banner otherwise draws only from
    /// a live `/me`, which the mock cannot answer — so without this it can
    /// never be photographed, and a thing nobody has looked at is a thing
    /// nobody has checked. nil outside `-uiTesting` or when the arg is missing.
    static var uiTestPlanBanner: String? {
        guard isUITesting else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-ui.planBanner"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Builds the active API client from `useLiveBackend`. Falls back to Mock if
    /// the live client can't be constructed (e.g. no base URL). Single source of
    /// truth so AppModel and UploadManager stay in sync.
    static func makeAPIClient() -> APIClient {
        if isSessionNetworkTesting, let live = LiveAPIClient() { return live }
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

    /// The "Gear we recommend" catalog (Amazon Associates links) — a static
    /// JSON file the tour-host Worker serves from `public/gear.json`
    /// (services/edge/tour-host). Remote so the owner can add ASINs, flip
    /// `enabled` or pull the section without an app release. `GearStore`
    /// fetches it, caches it on disk, and hides every Gear entry point until
    /// the file says `enabled: true` with a tag and at least one ASIN. Under
    /// `-uiTesting` the store never fetches this; it uses an inline sample.
    /// See docs/GEAR-STORE.md.
    static let gearCatalogURL = URL(string: "https://rendprop.com/gear.json")!

    /// RETIRED — always nil, on every storefront. Do not revive it.
    ///
    /// This used to return rendprop.com/pricing on the US storefront so a 402
    /// could offer a secondary "See plans on the web" link. That was defensible
    /// while there was no other way to pay. There now is: `Purchases/` sells the
    /// plans with StoreKit 2 on every storefront, and rendprop.com/pricing has no
    /// checkout — so the link bought the app nothing and cost it an external
    /// purchase CTA sitting next to an in-app purchase, which is exactly the
    /// shape App Review reads as steering (3.1.1 / 3.1.3). Every upgrade path in
    /// the app now opens the in-app paywall via `PaywallRouter`.
    ///
    /// Kept as a property, and kept nil, so that any future call site inherits
    /// "no external purchase CTA" instead of re-introducing one.
    @MainActor
    static var pricingURL: URL? { nil }

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
