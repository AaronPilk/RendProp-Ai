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
                "{ t: \(String(format: "%.1f", Double(i) * step)), label: '\(name.replacingOccurrences(of: "'", with: ""))' }"
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
        html = html.replacingOccurrences(of: "1247 Hillcrest Drive", with: htmlEscape(name))
        if type != .realEstate {
            html = html.replacingOccurrences(of: "$1,175,000", with: "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft", with: htmlEscape(sub))
            html = html.replacingOccurrences(of: "this home", with: "this \(type.spaceNoun)")
            html = html.replacingOccurrences(of: "Book a showing", with: htmlEscape(type.ctaTitle))
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
    static func localPreviewHTML(videoURL: URL, roomTags: [RoomTag], listing: Listing?, agent: AgentCard = .current) -> URL? {
        guard let template = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player"),
              var html = try? String(contentsOf: template, encoding: .utf8) else { return nil }

        // 1. Video source → the user's file (same directory as the HTML)
        html = html.replacingOccurrences(of: "src=\"demo.mp4\"",
                                         with: "src=\"\(videoURL.lastPathComponent)\"")

        // 2. Chapters → their room tags
        let tags = roomTags.sorted { $0.tMs < $1.tMs }
        let chapterEntries = tags.isEmpty
            ? "{ t: 0, label: 'Home' }"
            : tags.map { tag -> String in
                let safe = tag.name
                    .replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\\", with: "")
                return "{ t: \(String(format: "%.2f", tag.tSeconds)), label: '\(safe)' }"
              }.joined(separator: ",\n    ")
        if let start = html.range(of: "const CHAPTERS = ["),
           let end = html.range(of: "];", range: start.upperBound..<html.endIndex) {
            html.replaceSubrange(start.lowerBound..<end.upperBound,
                                 with: "const CHAPTERS = [\n    \(chapterEntries)\n  ];")
        }

        // 3. Listing card → real details
        if let listing {
            html = html.replacingOccurrences(of: "$1,175,000",
                                             with: listing.price.cents > 0 ? listing.price.formatted : "")
            html = html.replacingOccurrences(of: "4 bd · 3 ba · 2,850 sqft", with: listing.metaLine)
            html = html.replacingOccurrences(of: "1247 Hillcrest Drive", with: listing.address)
        }

        // 4. Agent card → the agent's own details. Only when they've set one up;
        //    otherwise the demo agent (Sarah Mitchell) stays so sample tours
        //    still look complete.
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
        }

        // Call-to-action + copy adapt to the business type (real estate keeps
        // "Book a showing"; a bar becomes "Book a table", "this home" → "this bar").
        if SpaceType.current != .realEstate {
            html = html.replacingOccurrences(of: "Book a showing", with: htmlEscape(SpaceType.current.ctaTitle))
            html = html.replacingOccurrences(of: "this home", with: "this \(SpaceType.current.spaceNoun)")
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
