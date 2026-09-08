import Foundation

// Universal Links — turning a rendprop.com URL into somewhere to stand.
//
// THE DEFECT: there were no deep links AT ALL. No `apple-app-site-association`
// on the domain, no `com.apple.developer.associated-domains` entitlement, no
// URL handling in the app. Tapping a tour link on a phone that already had
// Rendprop installed opened Safari. The owner asked for the link to carry a
// buyer into the app and onto that agent's listing; the first honest answer is
// that the link did not reach the app under ANY circumstances.
//
// WHAT APPLE ACTUALLY SUPPORTS, since this shapes everything below. Universal
// Links solve the app-IS-installed case completely and are the only mechanism
// Apple blesses. There is NO native deferred deep linking: a link tapped
// before an install does not survive the App Store — Apple says so directly
// (developer forums 776156) and its own advice is smart banners plus your own
// server-side match. The industry's answer is IP fingerprinting, which is what
// Apple's anti-fingerprinting rules exist to stop and which iCloud Private
// Relay breaks anyway. So this file does the supported half properly, and the
// tour page carries the "already installed? open it here" affordance that
// makes the second tap land — a real 100% path instead of a probabilistic one.
//
// Two shapes, matching the Worker's routes and the AASA components:
//   https://rendprop.com/f/<slug>   a published tour (branded)
//   https://rendprop.com/u/<slug>   the MLS-unbranded twin of the same tour
//   https://rendprop.com/a/<handle> an agent's portfolio
//
// `/u/` deliberately resolves to the SAME viewer as `/f/`. The unbranded twin
// exists because an MLS forbids agent branding ON THE PAGE; it is not a
// different tour, and a buyer who taps one inside the app is not in an MLS
// context. The viewer loads whichever URL it was handed, so an unbranded link
// renders unbranded — the gate stays exactly where it was, on the page.

/// `Identifiable` so the root scene can present it with
/// `fullScreenCover(item:)`. The id is the link itself in string form: two
/// taps on the SAME link are the same presentation, two taps on different
/// links re-present.
enum DeepLink: Equatable, Identifiable {
    case tour(slug: String, unbranded: Bool)
    case portfolio(handle: String)

    var id: String {
        switch self {
        case .tour(let slug, let unbranded): return "\(unbranded ? "u" : "f"):\(slug)"
        case .portfolio(let handle):         return "a:\(handle)"
        }
    }

    /// The hosts this app answers for. MUST stay in lockstep with the
    /// `applinks:` entries in Rendprop.entitlements and with the AASA the
    /// Worker serves (services/edge/tour-host/src/index.ts) — a host in the
    /// entitlement that this rejects is a link that opens the app and then
    /// does nothing, which is worse than not handling it at all.
    static let hosts: Set<String> = ["rendprop.com", "www.rendprop.com"]

    /// Parse an incoming URL. nil for anything this app has no screen for, and
    /// the caller then hands it back to the system — never swallow a URL you
    /// cannot honour.
    static func parse(_ url: URL) -> DeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "rendprop" else { return nil }
        // rendprop://f/<slug> — the custom scheme, kept for the clipboard
        // hand-off and for anything that cannot present an https link.
        let host = (url.host ?? "").lowercased()
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if scheme == "rendprop" {
            if !host.isEmpty { parts.insert(host, at: 0) }
        } else {
            guard hosts.contains(host) else { return nil }
        }
        guard parts.count >= 2 else { return nil }
        let kind = parts[0].lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128 else { return nil }
        switch kind {
        case "f": return .tour(slug: value, unbranded: false)
        case "u": return .tour(slug: value, unbranded: true)
        case "a": return .portfolio(handle: value)
        default:  return nil
        }
    }

    /// The page this link shows, on the same host the Worker serves. Built
    /// rather than carried so a link that arrived with tracking parameters,
    /// a `www.` host or a trailing slash still loads one canonical page.
    var pageURL: URL? {
        switch self {
        case .tour(let slug, let unbranded):
            return URL(string: "https://rendprop.com/\(unbranded ? "u" : "f")/\(escaped(slug))")
        case .portfolio(let handle):
            return URL(string: "https://rendprop.com/a/\(escaped(handle))")
        }
    }

    /// The slug a lead is posted against (`POST /leads {slug,…}`), or nil for a
    /// portfolio, which is not one listing and cannot take a lead.
    var leadSlug: String? {
        if case .tour(let slug, _) = self { return slug }
        return nil
    }

    private func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
