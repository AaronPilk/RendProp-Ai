import SwiftUI
import WebKit

/// WKWebView wrapping the scroll-scrub player. Three modes:
///  1. remoteURL   — a published share page
///  2. localAsset  — the user's OWN recorded/imported walkthrough, scrubbed by
///                   the real player with their room tags as chapters
///  3. fallback    — the bundled demo (sample listings, or a real listing that
///                   has no video yet)
///
/// Every in-app page is rendered from the bundled `player/index.html` through
/// ONE template pass (`renderTemplate`), so the demo and the local preview can
/// never drift apart: the same chip, agent card (tap-to-call / tap-to-email),
/// per-type copy, "Preview — form disabled" marker and the explicit
/// "video unavailable" state. The raw template (house, Sarah Mitchell, a 404
/// `demo.mp4`) is never loaded as-is (audit F-B-03).
struct PlayerWebView: UIViewRepresentable {
    var remoteURL: URL? = nil
    var localVideoURL: URL? = nil
    var roomTags: [RoomTag] = []
    var listing: Listing? = nil
    var agent: AgentCard = .current
    /// True ONLY when a real video enhancement (declutter/restage) was applied
    /// to this tour, so the MLS "Virtually staged" chip matches the hosted page.
    /// No such pipeline exists today (decision A5) — callers leave it false.
    var virtuallyStaged: Bool = false

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
                  let preview = Self.localPreviewHTML(videoURL: localVideoURL, roomTags: roomTags,
                                                      listing: listing, agent: agent,
                                                      staged: virtuallyStaged) {
            // Read grant = the ONE folder holding the HTML + video.
            webView.loadFileURL(preview.html, allowingReadAccessTo: preview.dir)
        } else if let demo = Self.demoHTML(listing: listing, agent: agent) {
            // Sample tours: the bundled demo REWRITTEN for the current business
            // type — a gym's sample never shows "Living Room" or "Book a showing".
            // When demo.mp4 isn't in the build the page says so explicitly.
            webView.loadFileURL(demo.html, allowingReadAccessTo: demo.dir)
        } else {
            // The template itself couldn't be read or written (bundle damaged,
            // disk full). Say so — never a blank black card.
            webView.loadHTMLString(Self.unavailableHTML, baseURL: nil)
        }
        return webView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Keeps every link tap OUT of the 460pt player: the webview is the tour,
    /// nothing else. Tapped http(s) links (watermark, agent socials, Zillow,
    /// the deep-link CTA) open in Safari; tel:/mailto: go to the system
    /// handler. Without this, target="_blank" links are silently dead (no
    /// UIDelegate → no window) and a plain link would hijack the player into
    /// browsing inside the card.
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

        // target="_blank" (watermark, social row, Zillow, CTA): never spawn a
        // child webview — open externally and keep the tour where it was.
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

    // MARK: - Demo (sample tours / real listings without a video yet)

    /// Type-adapted demo: copies the bundled demo video into Caches once, then
    /// rewrites the player HTML around the CURRENT business type — its sample
    /// name/tagline, its area tags as chapters, and its call-to-action. When
    /// `demo.mp4` is not in the build, the page still renders (type-adapted)
    /// with an explicit "Sample video unavailable" stage.
    static func demoHTML(listing: Listing?, agent: AgentCard = .current) -> (html: URL, dir: URL)? {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("player-demo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var videoRef: String?
        if let demoVideo = Bundle.main.url(forResource: "demo", withExtension: "mp4", subdirectory: "player") {
            let videoCopy = dir.appendingPathComponent("demo.mp4")
            if !fm.fileExists(atPath: videoCopy.path) {
                try? fm.copyItem(at: demoVideo, to: videoCopy)
            }
            if fm.fileExists(atPath: videoCopy.path) { videoRef = "demo.mp4" }
        }

        let type = SpaceType.current

        // Chapters → this type's area tags, spread across the ~55 s demo.
        let tags = Array(type.quickTags.prefix(6))
        let step = 50.0 / Double(max(1, tags.count))
        let chapters = tags.enumerated().map { i, name in (t: Double(i) * step, label: name) }

        let ctx = TemplateContext(videoRef: videoRef,
                                  chapters: chapters,
                                  listing: listing,
                                  agent: agent,
                                  type: type,
                                  identityIsSample: listing?.isSample ?? true,
                                  staged: false)
        guard let html = renderTemplate(ctx) else { return nil }

        // One file per type AND identity (a real listing over the demo reel must
        // not overwrite the sample page, or vice versa).
        let suffix = (listing?.isSample ?? true) ? "" : "-\(listing?.id.uuidString.prefix(8) ?? "listing")"
        let out = dir.appendingPathComponent("demo-\(type.rawValue)\(suffix).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return (out, dir)
        } catch {
            return nil
        }
    }

    // MARK: - Local preview (the user's own video)

    /// Rewrites the bundled player around the user's own video:
    /// swaps the video source, injects their room tags as chapters, and fills
    /// in the listing card. Written beside the video file.
    /// NOTE: `roomTags` must already be in the VIDEO's timebase — callers
    /// rescale capture-time tags by the render's speedFactor (the same
    /// tMs/speedFactor mapping the publish path applies before the hosted
    /// player reads t_ms).
    /// Returns the HTML URL and the directory the webview may read (both files
    /// live in it). Nil only when the template can't be read/written.
    static func localPreviewHTML(videoURL: URL, roomTags: [RoomTag], listing: Listing?,
                                 agent: AgentCard = .current, staged: Bool = false) -> (html: URL, dir: URL)? {
        let fm = FileManager.default
        let location = previewLocation(for: videoURL)
        let videoRef: String? = fm.fileExists(atPath: videoURL.path) ? location.videoRef : nil

        let tags = roomTags.sorted { $0.tMs < $1.tMs }
        let chapters = tags.map { (t: $0.tSeconds, label: $0.name) }

        let ctx = TemplateContext(videoRef: videoRef,
                                  chapters: chapters,
                                  listing: listing,
                                  agent: agent,
                                  type: SpaceType.current,
                                  identityIsSample: listing?.isSample ?? false,
                                  staged: staged)
        guard let html = renderTemplate(ctx) else { return nil }

        let out = location.dir
            .appendingPathComponent("preview-\(videoURL.deletingPathExtension().lastPathComponent).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return (out, location.dir)
        } catch {
            return nil
        }
    }

    /// Where the preview page lives and what the `<video src>` points at.
    /// Videos already inside a subfolder (Recordings/, Imports/) get the page
    /// beside them. A video at the ROOT of Documents (`enhanced-<id>.mp4`,
    /// written by the AI-enhance path) would need a read grant on the WHOLE
    /// container, so it is hard-linked into `Documents/Previews/` and the grant
    /// is that one folder instead (audit F-B-28). Falls back to the wide grant
    /// only if the link can't be made.
    private static func previewLocation(for videoURL: URL) -> (videoRef: String, dir: URL) {
        let fm = FileManager.default
        let parent = videoURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path == FileStore.documents.standardizedFileURL.path else {
            return (videoURL.lastPathComponent, parent)
        }
        let previews = FileStore.documents.appendingPathComponent("Previews", isDirectory: true)
        try? fm.createDirectory(at: previews, withIntermediateDirectories: true)
        sweepStalePreviewLinks(in: previews)
        let link = previews.appendingPathComponent(videoURL.lastPathComponent)
        // Re-link every time: the enhanced file may have been replaced since
        // (a hard link keeps the OLD bytes alive otherwise).
        try? fm.removeItem(at: link)
        do {
            try fm.linkItem(at: videoURL, to: link)
            return (link.lastPathComponent, previews)
        } catch {
            return (videoURL.lastPathComponent, parent)
        }
    }

    /// Hard links whose original left the Documents root (listing deleted,
    /// enhanced file replaced) would keep multi-hundred-MB files alive — drop
    /// them, and the preview pages that pointed at them.
    private static func sweepStalePreviewLinks(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        var liveVideoBases = Set<String>()
        for url in items where !(url.lastPathComponent.hasPrefix("preview-") && url.pathExtension == "html") {
            let original = FileStore.documents.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: original.path) {
                liveVideoBases.insert(url.deletingPathExtension().lastPathComponent)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        for url in items where url.lastPathComponent.hasPrefix("preview-") && url.pathExtension == "html" {
            let base = String(url.deletingPathExtension().lastPathComponent.dropFirst("preview-".count))
            if !liveVideoBases.contains(base) { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Template rendering (shared by demo + local preview)

    private struct TemplateContext {
        /// Relative `<video src>` inside the page's folder; nil = no video → the
        /// page shows its explicit "unavailable" state.
        var videoRef: String?
        var chapters: [(t: Double, label: String)]
        var listing: Listing?
        var agent: AgentCard
        var type: SpaceType
        /// May the business type's SAMPLE identity fill gaps (name/tagline)?
        /// True for samples and for "no listing"; NEVER for a real listing, so a
        /// real venue with an empty tagline doesn't inherit the sample's line
        /// (audit F-B-16).
        var identityIsSample: Bool
        var staged: Bool
    }

    private static func renderTemplate(_ ctx: TemplateContext) -> String? {
        guard let template = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player"),
              var html = try? String(contentsOf: template, encoding: .utf8) else { return nil }

        // 1. Video source → the file next to the page, or the explicit missing
        //    state. Imports keep the user's original filename ("DJI clip #2.MOV"
        //    — a raw "#", space, "%" or quote breaks a relative src). Percent-
        //    encode for the URL (":" too, so the first segment can't parse as a
        //    scheme), then HTML-escape for the attribute.
        if let ref = ctx.videoRef {
            var srcAllowed = CharacterSet.urlPathAllowed
            srcAllowed.remove(charactersIn: ":&'")
            let encoded = ref.addingPercentEncoding(withAllowedCharacters: srcAllowed) ?? ref
            html = html.replacingOccurrences(of: "src=\"demo.mp4\"", with: "src=\"\(htmlEscape(encoded))\"")
        } else {
            html = html.replacingOccurrences(of: "src=\"demo.mp4\"", with: "data-src=\"\"")
            html = html.replacingOccurrences(of: "const VIDEO_MISSING = false;", with: "const VIDEO_MISSING = true;")
        }

        // 2. In-app flags: the form is inert here; the staging chip only when a
        //    real enhancement was applied (never from the extras card, F-B-02).
        html = html.replacingOccurrences(of: "const PREVIEW = false;", with: "const PREVIEW = true;")
        html = html.replacingOccurrences(of: "const VIRTUALLY_STAGED = false;",
                                         with: "const VIRTUALLY_STAGED = \(ctx.staged ? "true" : "false");")

        // 3. Chapters
        let chapterEntries = ctx.chapters.isEmpty
            ? "{ t: 0, label: '\(jsLabel(ctx.type.spaceNounCap))' }"
            : ctx.chapters.map { "{ t: \(String(format: "%.2f", max(0, $0.t))), label: '\(jsLabel($0.label))' }" }
                .joined(separator: ",\n    ")
        if let start = html.range(of: "const CHAPTERS = ["),
           let end = html.range(of: "];", range: start.upperBound..<html.endIndex) {
            html.replaceSubrange(start.lowerBound..<end.upperBound,
                                 with: "const CHAPTERS = [\n    \(chapterEntries)\n  ];")
        }

        // 4. Business-type copy (CTA, form sub, confirmation, "this home") —
        //    MUST run before the listing/agent swaps below: it matches full
        //    demo sentences that still contain "1247 Hillcrest Drive" and
        //    "Sarah will". Real estate is a no-op.
        html = adaptCopy(html, for: ctx.type)

        // 5. Listing chip (title, og tags, chip, and the lead-form copy all
        //    carry the demo's "1247 Hillcrest Drive" / "4 bd · 3 ba · 2,850 sqft"
        //    / "$1,175,000" — every occurrence is swapped, hidden when unset).
        let sample = ctx.type.sampleListings.first
        let name: String = {
            if let l = ctx.listing { return l.address.replacingOccurrences(of: " (Sample)", with: "") }
            if ctx.identityIsSample, let s = sample { return s.address.replacingOccurrences(of: " (Sample)", with: "") }
            return "Sample Tour"
        }()
        if ctx.type.showsPropertyDetails {
            if let l = ctx.listing {
                html = html.replacingOccurrences(of: "$1,175,000",
                                                 with: l.price.cents > 0 ? htmlEscape(l.price.formatted) : "")
                html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft", with: htmlEscape(metaText(for: l)))
            }
            // No listing at all → the demo home's own facts stay (it IS the demo).
        } else {
            let sub: String = {
                if let l = ctx.listing, let t = l.tagline?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
                if ctx.identityIsSample { return sample?.tagline ?? "" }
                return ""
            }()
            html = html.replacingOccurrences(of: "$1,175,000", with: "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft", with: htmlEscape(sub))
        }
        html = html.replacingOccurrences(of: "1247 Hillcrest Drive", with: htmlEscape(name))

        // 6. Agent / business card. Phone and email are real tel:/mailto:
        //    anchors, as on the hosted page (audit F-B-14).
        let demoBrokerage = "<div class=\"bk\">Demo Realty Group</div>"
        let demoContact = "<div class=\"contact\"><a href=\"tel:5550123456\">(555) 012-3456</a></div>"
        if ctx.agent.isSet {
            let agent = ctx.agent
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(agent.name))
            html = html.replacingOccurrences(of: demoBrokerage,
                                             with: "<div class=\"bk\">\(htmlEscape(agent.brokerage.trimmingCharacters(in: .whitespaces)))</div>")
            html = html.replacingOccurrences(of: demoContact,
                                             with: "<div class=\"contact\">\(contactAnchors(phone: agent.phone, email: agent.email))</div>")
            html = html.replacingOccurrences(of: "Sarah will", with: "\(htmlEscape(agent.firstName)) will")

            // Social row: website + Instagram + LinkedIn + TikTok (whichever are set)
            var socialLinks = [String]()
            if let u = agent.websiteURL   { socialLinks.append(anchor(u, agent.websiteDisplay.isEmpty ? "Website" : agent.websiteDisplay)) }
            if let u = agent.instagramURL { socialLinks.append(anchor(u, "Instagram")) }
            if let u = agent.linkedinURL  { socialLinks.append(anchor(u, "LinkedIn")) }
            if let u = agent.tiktokURL    { socialLinks.append(anchor(u, "TikTok")) }
            html = html.replacingOccurrences(of: "<!--SOCIAL-->", with: socialLinks.joined())

            // Avatar: the headshot (base64-embedded) if they added one — in-app
            // only; hosted pages show initials — otherwise their initials.
            if let b64 = agent.headshotBase64 {
                html = html.replacingOccurrences(
                    of: "<div class=\"avatar\">SM</div>",
                    with: "<div class=\"avatar\" style=\"background-image:url('data:image/jpeg;base64,\(b64)');background-size:cover;background-position:center\"></div>")
            } else {
                html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(agent.initials))<")
            }
        } else if let l = ctx.listing, !l.isSample {
            // REAL tour with no card set up: never show the fake demo agent on
            // the user's own listing — hide the identity row and neutralize the
            // copy ("Sarah will text you times" → "We'll text you times").
            html = html.replacingOccurrences(of: "<div class=\"agent\">",
                                             with: "<div class=\"agent\" style=\"display:none\">")
            html = html.replacingOccurrences(of: "Sarah will", with: "We'll")
        } else if ctx.type != .realEstate {
            // Sample/preview with no business card: show the BUSINESS's identity
            // — never the demo real-estate agent on a venue/gym/bar.
            let bizSub = (ctx.listing?.tagline ?? sample?.tagline ?? "").trimmingCharacters(in: .whitespaces)
            var bizPhone = ctx.listing?.detail("phone") ?? ""
            if bizPhone.isEmpty { bizPhone = sample?.detail("phone") ?? "" }
            html = html.replacingOccurrences(of: "Sarah Mitchell", with: htmlEscape(name))
            html = html.replacingOccurrences(of: demoBrokerage, with: "<div class=\"bk\">\(htmlEscape(bizSub))</div>")
            html = html.replacingOccurrences(of: demoContact,
                                             with: "<div class=\"contact\">\(contactAnchors(phone: bizPhone, email: ""))</div>")
            html = html.replacingOccurrences(of: ">SM<", with: ">\(htmlEscape(businessInitials(name)))<")
            html = html.replacingOccurrences(of: "Sarah will", with: "We'll")
        }
        // Real-estate sample without a card: the demo agent stays — it's a demo.

        // 7. Zillow (per-listing) — a secondary link under the booking form.
        //    Real estate only: a gym or bar never shows a Zillow link.
        if ctx.type == .realEstate, let z = ctx.listing?.zillowURLValue {
            let btn = "<a class=\"zillow-link\" href=\"\(htmlEscape(z.absoluteString))\" target=\"_blank\" rel=\"noopener\">↗ View on Zillow</a>"
            html = html.replacingOccurrences(of: "<!--ZILLOW-->", with: btn)
        }

        // 8. Deep-link CTA — mirrors the hosted player: when the owner set a
        //    reservation / booking / online-store link, the end card is that
        //    button instead of a lead form (audit F-B-14).
        if ctx.type != .realEstate, let l = ctx.listing, !l.isSample, let action = l.actionURL {
            let block = """
            <div class="ctablock">
              <h2>\(htmlEscape(ctx.type.ctaTitle))</h2>
              <p class="sub">\(htmlEscape(deepLinkSub(for: ctx.type)))</p>
              <a class="cta" href="\(htmlEscape(action.absoluteString))" target="_blank" rel="noopener">\(htmlEscape(ctx.type.ctaTitle)) ↗</a>
            </div>
            """
            if let start = html.range(of: "<form id=\"leadform\">"),
               let end = html.range(of: "</form>", range: start.upperBound..<html.endIndex) {
                html.replaceSubrange(start.lowerBound..<end.upperBound, with: block)
            }
        }
        html = html.replacingOccurrences(of: "<!--CTA-->", with: "")

        return html
    }

    /// Shown only when the template can't even be read/written.
    private static let unavailableHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{margin:0;background:#0b0d10;color:#f2f3f5;font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;text-align:center;padding:24px}
    b{display:block;font-size:16px;margin-bottom:6px}p{font-size:14px;line-height:1.45;color:rgba(242,243,245,.62);max-width:300px}</style></head>
    <body><p><b>Player unavailable</b>The tour page couldn't be prepared on this phone. Check free storage and try again.</p></body></html>
    """

    /// The listing chip's second line, hidden gracefully when unset: real
    /// estate shows only the parts that are > 0 (never "0 bd · 0 ba"), and
    /// non-property types show their tagline instead of beds/baths.
    private static func metaText(for listing: Listing) -> String {
        listing.spaceType.showsPropertyDetails ? listing.metaLine : (listing.tagline ?? "")
    }

    /// tel:/mailto: anchors for the card's contact row (empty → the row hides).
    private static func contactAnchors(phone: String, email: String) -> String {
        var parts = [String]()
        let p = phone.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty {
            if let tel = LeadRow.telURL(p) {
                parts.append("<a href=\"\(htmlEscape(tel.absoluteString))\">\(htmlEscape(p))</a>")
            } else {
                parts.append("<span>\(htmlEscape(p))</span>")
            }
        }
        let e = email.trimmingCharacters(in: .whitespaces)
        if !e.isEmpty, let mail = LeadRow.mailURL(e) {
            parts.append("<a href=\"\(htmlEscape(mail.absoluteString))\">\(htmlEscape(e))</a>")
        }
        return parts.joined()
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

    /// One line under the deep-link CTA (reservations / booking / store).
    private static func deepLinkSub(for type: SpaceType) -> String {
        switch type {
        case .venue:      return "Check dates and send an inquiry online."
        case .restaurant: return "Reserve a table online — it takes a minute."
        case .fitness:    return "Book online and pick a time that suits you."
        case .retail:     return "Shop online or plan your visit."
        default:          return "Everything you need is on our website."
        }
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
