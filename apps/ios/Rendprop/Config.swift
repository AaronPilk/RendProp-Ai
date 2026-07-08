import Foundation

/// Central app configuration + feature flags.
/// Phase 2 features are stubbed behind flags — see docs/MASTER-BUILD-PROMPT.md.
enum Config {
    /// Point at services/api when it exists. nil = fully offline dev (MockAPIClient).
    static let apiBaseURL: URL? = nil

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
    static let enableAuth = false      // TODO: Sign in with Apple + Keychain
    static let enableIAP  = false      // TODO: StoreKit 2 consumable credits + subs
    static let enablePush = false      // TODO: APNs render-ready / lead-received
}
