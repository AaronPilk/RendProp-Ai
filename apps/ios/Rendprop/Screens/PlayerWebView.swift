import SwiftUI
import WebKit

/// WKWebView wrapping the scroll-scrub player. Three modes:
///  1. remoteURL   — a published share page
///  2. localAsset  — the user's OWN recorded/imported walkthrough, scrubbed by
///                   the real player with their room tags as chapters
///  3. fallback    — the bundled demo (sample listings only)
struct PlayerWebView: UIViewRepresentable {
    var remoteURL: URL? = nil
    var localVideoURL: URL? = nil
    var roomTags: [RoomTag] = []
    var listing: Listing? = nil
    var agent: AgentCard = .current

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if let remoteURL {
            webView.load(URLRequest(url: remoteURL))
        } else if let localVideoURL,
                  let html = Self.localPreviewHTML(videoURL: localVideoURL, roomTags: roomTags, listing: listing, agent: agent) {
            // HTML sits next to the video so one read grant covers both.
            webView.loadFileURL(html, allowingReadAccessTo: localVideoURL.deletingLastPathComponent())
        } else if let demo = Self.demoHTML(listing: listing, agent: agent) {
            // Sample tours: the bundled demo REWRITTEN for the current business
            // type — a gym's sample never shows "Living Room" or "Book a showing".
            webView.loadFileURL(demo.html, allowingReadAccessTo: demo.dir)
        } else if let index = Bundle.main.url(forResource: "index",
                                              withExtension: "html",
                                              subdirectory: "player") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        return webView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Keeps every link tap OUT of the 460pt player: the webview is the tour,
    /// nothing else. Tapped http(s) links (watermark, agent socials, Zillow)
    /// open in Safari; tel:/mailto: go to the system handler. Without this,
    /// target="_blank" links are silently dead (no UIDelegate → no window) and
    /// a plain link would hijack the player into browsing inside the card.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // Any tapped link leaves the app. The player itself only ever
            // loads file:// (bundled/local preview) or the initial remote
            // share page — both arrive as .other, never .linkActivated.
            if let url, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // Script/redirect to a non-web scheme (tel:, mailto:, maps:, …):
            // WKWebView can't render these — hand off and stay on the tour.
            let scheme = url?.scheme?.lowercased() ?? ""
            if let url, !scheme.isEmpty,
               !["http", "https", "file", "about", "blob", "data"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target="_blank" (watermark, social row, Zillow): never spawn a child
        // webview — open externally and keep the tour where it was.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }

    /// Type-adapted demo: copies the bundled demo video into Caches once, then
    /// rewrites the player HTML around the CURRENT business type — its sample
    /// name/tagline, its area tags as chapters, and its call-to-action.
    static func demoHTML(listing: Listing?, agent: AgentCard = .current) -> (html: URL, dir: URL)? {
        guard let template = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player"),
              let demoVideo = Bundle.main.url(forResource: "demo", withExtension: "mp4", subdirectory: "player"),
              var html = try? String(contentsOf: template, encoding: .utf8) else { return nil }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("player-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoCopy = dir.appendingPathComponent("demo.mp4")
        if !FileManager.default.fileExists(atPath: videoCopy.path) {
            try? FileManager.default.copyItem(at: demoVideo, to: videoCopy)
        }
        guard FileManager.default.fileExists(atPath: videoCopy.path) else { return nil }

        let type = SpaceType.current

        // Chapters → this type's area tags, spread across the 55s demo.
        let tags = Array(type.quickTags.prefix(6))
        let step = 50.0 / Double(max(1, tags.count))
        let chapterEntries = tags.isEmpty
            ? "{ t: 0, label: '\(type.spaceNounCap)' }"
            : tags.enumerated().map { i, name in
                "{ t: \(String(format: "%.1f", Double(i) * step)), label: '\(jsLabel(name))' }"
              }.joined(separator: ",\n    ")
        if let start = html.range(of: "const CHAPTERS = ["),
           let end = html.range(of: "];", range: start.upperBound..<html.endIndex) {
            html.replaceSubrange(start.lowerBound..<end.upperBound,
                                 with: "const CHAPTERS = [\n    \(chapterEntries)\n  ];")
        }

        // Listing chip → this type's sample identity (or the tapped listing's).
        let sample = type.sampleListings.first
        let name = (listing?.address ?? sample?.address ?? "Sample Tour")
            .replacingOccurrences(of: " (Sample)", with: "")
        let sub = listing?.subtitleLine.isEmpty == false
            ? listing!.subtitleLine
            : (sample?.tagline ?? "")
        if type != .realEstate {
            // Copy adaptation FIRST — it matches full demo sentences ("See 1247
            // Hillcrest Drive in person — Sarah will text you times.") that the
            // address swap below would otherwise break byte-for-byte.
            html = adaptCopy(html, for: type)
            html = html.replacingOccurrences(of: "$1,175,000", with: "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft", with: htmlEscape(sub))
        }
        html = html.replacingOccurrences(of: "1247 Hillcrest Drive", with: htmlEscape(name))
        if type == .realEstate, let listing, !listing.isSample {
            // A REAL home shown over the demo reel (its own video not ready yet):
            // never keep the demo $1,175,000 / 4 bd · 3 ba — use the listing's values.
            html = html.replacingOccurrences(of: "$1,175,000",
                                             with: listing.price.cents > 0 ? htmlEscape(listing.price.formatted) : "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft",
                                             with: htmlEscape(metaText(for: listing)))
        }

        // Agent card (same treatment as real tours).
        if agent.isSet {
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(agent.name))
            html = html.replacingOccurrences(of: "Skyway Realty Group · (555) 012-3456",
                                             with: htmlEscape(agent.brokerageLine))
            html = html.replacingOccurrences(of: "Sarah will", with: "\(htmlEscape(agent.firstName)) will")
            if let b64 = agent.headshotBase64 {
                html = html.replacingOccurrences(
                    of: "<div class=\"avatar\">SM</div>",
                    with: "<div class=\"avatar\" style=\"background-image:url('data:image/jpeg;base64,\(b64)');background-size:cover;background-position:center\"></div>")
            } else {
                html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(agent.initials))<")
            }
        } else if let listing, !listing.isSample {
            // Real listing, no profile card yet: never show the fake demo agent
            // on the user's own tour — hide the identity row and neutralize the
            // copy ("Sarah will text you times" → "We'll text you times").
            html = html.replacingOccurrences(of: "<div class=\"agent\">",
                                             with: "<div class=\"agent\" style=\"display:none\">")
            html = html.replacingOccurrences(of: "Sarah will", with: "We'll")
        } else if type != .realEstate {
            // Sample tour, no business card yet: show the sample BUSINESS's
            // identity — never the demo real-estate agent on a venue/gym/bar.
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(name))
            html = html.replacingOccurrences(of: "Skyway Realty Group · (555) 012-3456",
                                             with: htmlEscape(sub))
            html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(businessInitials(name)))<")
        }

        let out = dir.appendingPathComponent("demo-\(type.rawValue).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return (out, dir)
        } catch {
            return nil
        }
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Rewrites the bundled player around the user's own video:
    /// swaps the video source, injects their room tags as chapters, and fills
    /// in the listing card. Written beside the video file.
    /// NOTE: `roomTags` must already be in the VIDEO's timebase — callers
    /// rescale capture-time tags by the render's speedFactor (the same
    /// tMs/speedFactor mapping the publish path applies before the hosted
    /// player reads t_ms).
    static func localPreviewHTML(videoURL: URL, roomTags: [RoomTag], listing: Listing?, agent: AgentCard = .current) -> URL? {
        guard let template = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player"),
              var html = try? String(contentsOf: template, encoding: .utf8) else { return nil }

        // 1. Video source → the user's file (same directory as the HTML).
        //    Imports keep the user's original filename ("DJI clip #2.MOV" —
        //    a raw "#", space, "%" or quote breaks a relative src). Percent-
        //    encode for the URL (":" too, so the first segment can't parse as
        //    a scheme), then HTML-escape for the attribute.
        var srcAllowed = CharacterSet.urlPathAllowed
        srcAllowed.remove(charactersIn: ":&'")
        let videoRef = videoURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: srcAllowed) ?? videoURL.lastPathComponent
        html = html.replacingOccurrences(of: "src=\"demo.mp4\"",
                                         with: "src=\"\(htmlEscape(videoRef))\"")

        // 2. Chapters → their room tags
        let tags = roomTags.sorted { $0.tMs < $1.tMs }
        let chapterEntries = tags.isEmpty
            ? "{ t: 0, label: '\(SpaceType.current.spaceNounCap)' }"
            : tags.map { tag -> String in
                "{ t: \(String(format: "%.2f", tag.tSeconds)), label: '\(jsLabel(tag.name))' }"
              }.joined(separator: ",\n    ")
        if let start = html.range(of: "const CHAPTERS = ["),
           let end = html.range(of: "];", range: start.upperBound..<html.endIndex) {
            html.replaceSubrange(start.lowerBound..<end.upperBound,
                                 with: "const CHAPTERS = [\n    \(chapterEntries)\n  ];")
        }

        // 3. Business-type copy (CTA, form sub, confirmation, "this home") —
        //    MUST run before the listing/agent swaps below: it matches full
        //    demo sentences that still contain "1247 Hillcrest Drive" and
        //    "Sarah will". Real estate is a no-op.
        html = adaptCopy(html, for: SpaceType.current)

        // 4. Listing card → real details (title, og tags, chip, and the
        //    lead-form copy all carry the demo's "1247 Hillcrest Drive" /
        //    "4 bd · 3 ba · 2,850 sqft" / "$1,175,000" — every occurrence is
        //    swapped for the listing's real values, hidden when unset).
        if let listing {
            html = html.replacingOccurrences(of: "$1,175,000",
                                             with: listing.price.cents > 0 ? htmlEscape(listing.price.formatted) : "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft",
                                             with: htmlEscape(metaText(for: listing)))
            html = html.replacingOccurrences(of: "1247 Hillcrest Drive", with: htmlEscape(listing.address))
        }

        // 5. Agent card → the agent's own details when they've set one up.
        //    Without one, SAMPLE tours keep the demo agent (Sarah Mitchell) so
        //    they look complete — but a REAL listing hides it (see else below).
        if agent.isSet {
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(agent.name))
            html = html.replacingOccurrences(of: "Skyway Realty Group · (555) 012-3456",
                                             with: htmlEscape(agent.brokerageLine))

            // Social row: website + Instagram + LinkedIn + TikTok (whichever are set)
            var socialLinks = [String]()
            if let u = agent.websiteURL   { socialLinks.append(anchor(u, agent.websiteDisplay.isEmpty ? "Website" : agent.websiteDisplay)) }
            if let u = agent.instagramURL { socialLinks.append(anchor(u, "Instagram")) }
            if let u = agent.linkedinURL  { socialLinks.append(anchor(u, "LinkedIn")) }
            if let u = agent.tiktokURL    { socialLinks.append(anchor(u, "TikTok")) }
            html = html.replacingOccurrences(of: "<!--SOCIAL-->", with: socialLinks.joined())

            // Avatar: the agent's headshot (base64-embedded) if they added one,
            // otherwise their initials.
            if let b64 = agent.headshotBase64 {
                html = html.replacingOccurrences(
                    of: "<div class=\"avatar\">SM</div>",
                    with: "<div class=\"avatar\" style=\"background-image:url('data:image/jpeg;base64,\(b64)');background-size:cover;background-position:center\"></div>")
            } else {
                html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(agent.initials))<")
            }

            html = html.replacingOccurrences(of: "Sarah will", with: "\(htmlEscape(agent.firstName)) will")
        } else if listing?.isSample == false {
            // REAL tour with no profile card set up: never show the fake demo
            // agent ("Sarah Mitchell") on the user's own listing — hide the
            // identity row and neutralize the copy ("Sarah will text you times"
            // → "We'll text you times", ditto the confirmation message).
            html = html.replacingOccurrences(of: "<div class=\"agent\">",
                                             with: "<div class=\"agent\" style=\"display:none\">")
            html = html.replacingOccurrences(of: "Sarah will", with: "We'll")
        } else if SpaceType.current != .realEstate {
            // Sample/preview with no business card set up: show the BUSINESS's
            // identity — never the demo real-estate agent on a venue/gym/bar.
            let biz = (listing?.address ?? SpaceType.current.sampleListings.first?.address ?? "Our space")
                .replacingOccurrences(of: " (Sample)", with: "")
            let line = listing?.tagline ?? SpaceType.current.sampleListings.first?.tagline ?? ""
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(biz))
            html = html.replacingOccurrences(of: "Skyway Realty Group · (555) 012-3456",
                                             with: htmlEscape(line))
            html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(businessInitials(biz)))<")
        }

        // Zillow (per-listing) — a secondary link under the booking form.
        // Real estate only: a gym or bar never shows a Zillow link.
        if SpaceType.current == .realEstate, let z = listing?.zillowURLValue {
            let btn = "<a class=\"zillow-link\" href=\"\(htmlEscape(z.absoluteString))\" target=\"_blank\" rel=\"noopener\">↗ View on Zillow</a>"
            html = html.replacingOccurrences(of: "<!--ZILLOW-->", with: btn)
        }

        let out = videoURL.deletingLastPathComponent()
            .appendingPathComponent("preview-\(videoURL.deletingPathExtension().lastPathComponent).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    /// The listing chip's second line, hidden gracefully when unset: real
    /// estate shows only the parts that are > 0 (never "0 bd · 0 ba"), and
    /// non-property types show their tagline instead of beds/baths.
    private static func metaText(for listing: Listing) -> String {
        guard listing.spaceType.showsPropertyDetails else { return listing.tagline ?? "" }
        var parts: [String] = []
        if listing.beds > 0 { parts.append("\(listing.beds) bd") }
        if listing.baths > 0 {
            let baths = listing.baths.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(listing.baths)) : String(listing.baths)
            parts.append("\(baths) ba")
        }
        if listing.sqft > 0 { parts.append("\(listing.sqft.formatted()) sqft") }
        return parts.joined(separator: " · ")
    }

    /// Real-estate-specific lead-form copy → the business type's own wording
    /// (mirrors the hosted player's formSub in tour-host/src/player.ts so an
    /// in-app preview reads like the published page). MUST run before the
    /// address/agent substitutions — it matches the demo sentences verbatim.
    private static func adaptCopy(_ html: String, for type: SpaceType) -> String {
        guard type != .realEstate else { return html }
        let sub: String
        switch type {
        case .venue:      sub = "Tell us about your event and we'll follow up with availability."
        case .restaurant: sub = "Request a table and we'll confirm shortly."
        case .fitness:    sub = "Leave your details and we'll get you set up."
        case .retail:     sub = "Get deals and updates in your inbox."
        default:          sub = "Leave your details and we'll be in touch."
        }
        var out = html
        out = out.replacingOccurrences(
            of: "See 1247 Hillcrest Drive in person — Sarah will text you times.",
            with: htmlEscape(sub))
        out = out.replacingOccurrences(
            of: "Sarah will reach out shortly to set up your showing.",
            with: "Thanks — expect a reply shortly.")
        out = out.replacingOccurrences(of: "Book a showing", with: htmlEscape(type.ctaTitle))
        out = out.replacingOccurrences(of: "this home", with: "this \(type.spaceNoun)")
        return out
    }

    /// "IO" from "Iron & Oak Strength Co." — first letter of the first and
    /// last words, same shape as AgentCard.initials.
    private static func businessInitials(_ name: String) -> String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.count > 1 ? (parts[parts.count - 1].first.map(String.init) ?? "") : ""
        let combined = (first + last).uppercased()
        return combined.isEmpty ? "•" : combined
    }

    /// Chapter labels land inside a single-quoted JS string in an inline
    /// <script>: strip quote/backslash (string breakout) and angle brackets
    /// (a "</script>" in a custom room name would terminate the block).
    private static func jsLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "")
         .replacingOccurrences(of: "\\", with: "")
         .replacingOccurrences(of: "<", with: "")
         .replacingOccurrences(of: ">", with: "")
    }

    /// Escape values before injecting into HTML so names with & < > " can't
    /// break the markup.
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func anchor(_ url: URL, _ label: String) -> String {
        "<a href=\"\(htmlEscape(url.absoluteString))\" target=\"_blank\" rel=\"noopener\">\(htmlEscape(label))</a>"
    }
}
