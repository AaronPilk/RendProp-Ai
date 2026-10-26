import Foundation

// Public property websites are for buyers and remain in their browser.
// The AASA excludes /f/, /u/ and /a/. The native URL entry checks the same
// boundary first because installed devices may still cache older AASA rules.
// Explicit rendprop:// tour/portfolio links and account-bound push routes
// retain their existing in-app viewer; HTTPS team invites retain Join.

/// `Identifiable` so the root scene can present it with
/// `fullScreenCover(item:)`. The id is the link itself in string form: two
/// taps on the SAME link are the same presentation, two taps on different
/// links re-present.
enum DeepLink: Equatable, Identifiable {
    case tour(slug: String)
    case portfolio(handle: String)
    /// A team invite, carrying its own code. Added 13 Sep 2026 on the owner's
    /// beta feedback: "A user would find it difficult to go to settings and
    /// put in the code. People are idiots this ux and process needs to be
    /// easier for a user to do." He was right — the old path was find
    /// Settings, find Team, find Join a team, then hand-type twelve
    /// characters, four hundred times over for a brokerage.
    case join(code: String)

    var id: String {
        switch self {
        case .tour(let slug):        return "f:\(slug)"
        case .portfolio(let handle): return "a:\(handle)"
        case .join(let code):        return "join:\(code)"
        }
    }

    /// The hosts this app answers for. MUST stay in lockstep with the
    /// `applinks:` entries in Rendprop.entitlements and with the AASA the
    /// Worker serves (services/edge/tour-host/src/index.ts) — a host in the
    /// entitlement that this rejects is a link that opens the app and then
    /// does nothing, which is worse than not handling it at all.
    static let hosts: Set<String> = ["rendprop.com", "www.rendprop.com"]

    /// A buyer URL accidentally delivered by cached universal-link rules is
    /// opened unchanged in the default browser. Never forward another host,
    /// credentials, an unexpected port, a custom scheme or an account route.
    static func publicWebsiteURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              hosts.contains((url.host ?? "").lowercased()),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2, ["f", "u", "a", "property"].contains(parts[0]) else { return nil }
        return url
    }

    /// Derive only a buyer-facing presentation URL from an already-published
    /// server link. Its token is unchanged; stored canonical URLs, publication
    /// receipts, API identities and the MLS-unbranded URL are never modified.
    static func buyerWebsiteURL(from canonical: URL, address: String? = nil) -> URL? {
        guard publicWebsiteURL(canonical) != nil else { return nil }
        let parts = canonical.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard (parts.count == 2 && ["f", "property"].contains(parts[0]))
                || (parts.count == 3 && parts[0] == "property"
                    && parts[1].range(of: "^[a-z0-9][a-z0-9-]{0,119}$", options: .regularExpression) != nil),
              let token = parts.last,
              token.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else { return nil }
        let descriptor = address.map(propertyAddressSlug) ?? (parts.count == 3 ? parts[1] : "")
        components.path = "/property/" + (descriptor.isEmpty ? "" : descriptor + "/") + token
        return components.url
    }

    /// Address spelling is presentation only. The same publication token and
    /// unbranded renderer remain authoritative; stored server receipts stay exact.
    static func unbrandedWebsiteURL(from canonical: URL, address: String) -> URL? {
        guard publicWebsiteURL(canonical) != nil else { return nil }
        let parts = canonical.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard (parts.count == 2 || (parts.count == 3
                && parts[1].range(of: "^[a-z0-9][a-z0-9-]{0,119}$", options: .regularExpression) != nil)),
              parts[0] == "u", let token = parts.last,
              token.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else { return nil }
        let descriptor = propertyAddressSlug(address)
        components.path = "/u/" + (descriptor.isEmpty ? "" : descriptor + "/") + token
        return components.url
    }

    /// Matches tour-host's propertyAddressSlug, including its UTF-16 input
    /// bound and compatibility decomposition. Never use this as a lookup key.
    static func propertyAddressSlug(_ address: String) -> String {
        let bounded = String(decoding: address.utf16.prefix(500), as: UTF16.self)
        let decomposed = bounded.decomposedStringWithCompatibilityMapping
        let unmarked = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter {
            !(0x0300...0x036f).contains($0.value)
        }))
        let normalized = unmarked.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(normalized.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Parse an incoming URL. nil for anything this app has no screen for, and
    /// the caller then hands it back to the system — never swallow a URL you
    /// cannot honour.
    static func parse(_ url: URL) -> DeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "rendprop",
              url.user == nil, url.password == nil,
              scheme != "https" || url.port == nil || url.port == 443 else { return nil }
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
        case "f": return .tour(slug: value)
        case "a": return .portfolio(handle: value)
        // NORMALISED HERE, not at the point of use. A code travels through a
        // mail client, a web page and a clipboard before it reaches this line,
        // so it can arrive with or without dashes and in any case. Everything
        // downstream should only ever see one shape. A code that is not
        // exactly twelve alphanumerics is not a code, and returning nil hands
        // the URL back to the system rather than opening the app onto an
        // error.
        case "join":
            let bare = value.uppercased().filter { $0.isLetter || $0.isNumber }
            guard bare.count == 12 else { return nil }
            let a = bare.prefix(4), b = bare.dropFirst(4).prefix(4), c = bare.suffix(4)
            return .join(code: "\(a)-\(b)-\(c)")
        // "u" IS DELIBERATELY NOT HERE, and this is not an omission.
        //
        // /u/<slug> is the URL an agent puts in an MLS field precisely because
        // the MLS forbids agent branding and contact capture on it. Handing it
        // to the app wrapped it in a Rendprop nav bar, a share button and a
        // "Message the agent" bar: the PAGE stayed compliant and the frame
        // around it did not. An unbranded link behaving like a plain web page
        // every single time it is tapped is not a limitation, it is the whole
        // feature. Returning nil hands the URL back to the system, which opens
        // Safari — exactly right.
        default:  return nil
        }
    }

    /// The page this link shows, on the same host the Worker serves. Built
    /// rather than carried so a link that arrived with tracking parameters,
    /// a `www.` host or a trailing slash still loads one canonical page.
    var pageURL: URL? {
        switch self {
        case .tour(let slug):
            return URL(string: "https://rendprop.com/f/\(escaped(slug))")
        case .portfolio(let handle):
            return URL(string: "https://rendprop.com/a/\(escaped(handle))")
        // An invite is handled entirely in-app. There is no page to fall back
        // to, and sending someone to the web version of the link they just
        // opened IN the app would be a loop.
        case .join:
            return nil
        }
    }

    /// The slug a lead is posted against (`POST /leads {slug,…}`), or nil for a
    /// portfolio, which is not one listing and cannot take a lead.
    var leadSlug: String? {
        if case .tour(let slug) = self { return slug }
        return nil
    }

    private func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}


/// Incoming links wait for the current capture, edit, purchase or share screen.
/// Exact repeats coalesce; a bounded burst is reported instead of silently lost.
enum NativeIncomingRoute: Equatable {
    case link(DeepLink)
    case leads
    case pushPermission
    case invalidLink
}
struct NativeIncomingQueue: Equatable {
    private(set) var routes: [NativeIncomingRoute] = []
    private(set) var overflowed = false
    static let limit = 32

    @discardableResult mutating func enqueue(_ route: NativeIncomingRoute) -> Bool {
        if routes.contains(route) { return true }
        guard routes.count < Self.limit else { overflowed = true; return false }
        routes.append(route)
        return true
    }
    mutating func takeNext(canPresent: Bool) -> NativeIncomingRoute? {
        guard canPresent else { return nil }
        if !routes.isEmpty { return routes.removeFirst() }
        if overflowed { overflowed = false; return .invalidLink }
        return nil
    }
    var hasPending: Bool { !routes.isEmpty || overflowed }
}
