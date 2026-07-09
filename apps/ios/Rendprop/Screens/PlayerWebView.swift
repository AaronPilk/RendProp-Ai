import SwiftUI
import WebKit

/// WKWebView wrapping the scroll-scrub player. Three modes:
///  1. remoteURL   — a published share page
///  2. localAsset  — the user's OWN recorded/imported walkthrough, scrubbed by
///                   the real player with their room tags as chapters
///  3. fallback    — the bundled demo (sample listings only)
struct PlayerWebView: UIViewRepresentable {
    var remoteURL: URL? = nil
    var localAsset: CaptureAsset? = nil
    var listing: Listing? = nil

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
        } else if let localAsset,
                  let html = Self.localPreviewHTML(for: localAsset, listing: listing) {
            // HTML sits next to the video so one read grant covers both.
            webView.loadFileURL(html, allowingReadAccessTo: localAsset.localURL.deletingLastPathComponent())
        } else if let index = Bundle.main.url(forResource: "index",
                                              withExtension: "html",
                                              subdirectory: "player") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Rewrites the bundled player around the user's own video:
    /// swaps the video source, injects their room tags as chapters, and fills
    /// in the listing card. Written beside the video file.
    static func localPreviewHTML(for asset: CaptureAsset, listing: Listing?) -> URL? {
        guard let template = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player"),
              var html = try? String(contentsOf: template, encoding: .utf8) else { return nil }

        // 1. Video source → the user's file (same directory as the HTML)
        html = html.replacingOccurrences(of: "src=\"demo.mp4\"",
                                         with: "src=\"\(asset.localURL.lastPathComponent)\"")

        // 2. Chapters → their room tags
        let tags = asset.roomTags.sorted { $0.tMs < $1.tMs }
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

        let out = asset.localURL.deletingLastPathComponent()
            .appendingPathComponent("preview-\(asset.id.uuidString.prefix(8)).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
