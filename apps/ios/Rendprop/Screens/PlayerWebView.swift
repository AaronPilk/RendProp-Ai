import SwiftUI
import WebKit

/// WKWebView wrapping the bundled scroll-scrub player (apps/web/player).
/// The same player that powers the public share link — brand continuity.
struct PlayerWebView: UIViewRepresentable {
    /// Load a remote share URL instead of the bundled demo when provided.
    var remoteURL: URL? = nil

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
        } else if let index = Bundle.main.url(forResource: "index",
                                              withExtension: "html",
                                              subdirectory: "player") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
