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
///
/// That template pass, and every byte of file I/O around it, lives in
/// `PlayerPage` at the bottom of this file and runs OFF the main actor. This
/// type does nothing but configure a webview and load whatever `PlayerPage`
/// hands back (build-9 lag report).
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
            // Nothing to prepare — the page is already on the network.
            webView.load(URLRequest(url: remoteURL))
            return webView
        }

        // BUILD-9 LAG REPORT. Every other mode renders the bundled template into
        // a file and loads that file, and all of it used to happen right here,
        // synchronously, on the main thread: a 38 KB `String(contentsOf:)`, ~40
        // full-string `replacingOccurrences` passes over it, a
        // `Documents/Previews/` sweep (a directory listing plus a `fileExists`
        // per entry plus deletes), a `removeItem` + `linkItem`, and an atomic
        // write (temp file + rename). Nothing in that chain touches UIKit, and
        // `.id(playerRefresh)` in FlythroughDetailView tears this view down and
        // rebuilds it — so the room tagger's dismissal paid the whole bill
        // again, usually to produce the same bytes that were already on disk.
        //
        // It is prepared off the main actor now, and the load is SEQUENCED after
        // the file exists rather than raced against it: `loadFileURL` is only
        // ever called with a page `PlayerPage` has finished writing. The webview
        // is already black, so the frame or two before the page arrives looks
        // exactly like the frame or two WKWebView spends parsing it anyway.
        let request = PlayerPageRequest(localVideoURL: localVideoURL,
                                        roomTags: roomTags,
                                        listing: listing,
                                        agent: agent,
                                        staged: virtuallyStaged)
        Task { @MainActor in
            guard let page = await PlayerPage.prepare(request) else {
                // The template itself couldn't be read or written (bundle damaged,
                // disk full). Say so — never a blank black card.
                webView.loadHTMLString(Self.unavailableHTML, baseURL: nil)
                return
            }
            // Read grant = the ONE folder holding the HTML + video.
            webView.loadFileURL(page.html, allowingReadAccessTo: page.dir)
        }
        return webView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Deliberately empty, and it must stay cheap: SwiftUI calls this on every
    /// update of the parent screen (every scroll of the detail view, every
    /// `@State` change on it), and this player is 460pt of the screen. The page
    /// is not rebuilt from here — `FlythroughDetailView` bumps `.id(playerRefresh)`
    /// when the tour's inputs change, which builds a fresh view and runs
    /// `makeUIView` again. `PlayerPage` memoises the render, so that rebuild is
    /// free when nothing the page depends on actually moved.
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

    // MARK: - Hosted demo

    /// The hosted demo tour — Rendprop's own published sample at
    /// `rendprop.com/f/estate-demo`, the one real tour every install can play
    /// without a bundled `demo.mp4`. Home's "See it in action" card and every
    /// non-real-estate sample play it (industry review P1-6). `embed=1` is the
    /// flythrough hero alone: no end card, no lead form, no listing sections.
    /// Optional because `URL(string:)` is, never force-unwrapped; a nil simply
    /// falls back to the bundled sample player below.
    static let hostedDemoURL = URL(string: "https://rendprop.com/f/estate-demo")
    static let hostedDemoEmbedURL = URL(string: "https://rendprop.com/f/estate-demo?embed=1")

    /// The embed for a given business type. Real estate plays the demo as the
    /// listing it is. Every other type asks the Worker (`&space=<type>`) to
    /// present the same footage as a "Sample tour" — no "$4,250,000 · 5 bd ·
    /// 6 ba" chip, no demo brokerage — so a venue, bar, store or gym owner's
    /// first screen never shows a home listing. One walkthrough at launch; a
    /// per-industry demo set is the follow-up. Older Workers ignore the param.
    static func hostedDemoEmbedURL(for type: SpaceType) -> URL? {
        guard type != .realEstate, let base = hostedDemoEmbedURL else { return hostedDemoEmbedURL }
        return URL(string: base.absoluteString + "&space=" + type.rawValue) ?? base
    }

    /// True when the sample walkthrough (`player/demo.mp4`, a folder-reference
    /// resource that git ignores) shipped in this build. With it, a venue /
    /// bar / store / gym sample plays the bundled, type-adapted player — its
    /// own name and tagline on the chip, its own area tags as chapters, its
    /// own identity on the card — instead of the hosted home listing. Without
    /// it (a CI build), the hosted demo is the fallback (industry review P1-6).
    ///
    /// Read from a `body` (Home's sample card, the detail screen's tour
    /// section), so the bundle probe behind it is done ONCE per process rather
    /// than per layout pass — the answer is fixed at build time (build-9 lag
    /// report).
    static var bundledDemoAvailable: Bool { PlayerPage.bundledDemoVideo != nil }

    /// Shown only when the template can't even be read/written.
    private static let unavailableHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{margin:0;background:#0b0d10;color:#f2f3f5;font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;text-align:center;padding:24px}
    b{display:block;font-size:16px;margin-bottom:6px}p{font-size:14px;line-height:1.45;color:rgba(242,243,245,.62);max-width:300px}</style></head>
    <body><p><b>Player unavailable</b>The tour page couldn't be prepared on this phone. Check free storage and try again.</p></body></html>
    """
}

// MARK: - Page preparation (everything below here is OFF the main actor)

/// One prepared player page: the HTML to load and the folder the webview may
/// read (both files live in it).
private struct PreparedPage: Sendable {
    var html: URL
    var dir: URL
    /// The video file the page's `<video src>` points at, when it is a file we
    /// manage (the hard link in `Previews/`, the demo copy in Caches). Recorded
    /// so the housekeeping sweep can never delete it under a live player.
    var video: URL?
}

/// What `makeUIView` hands the builder. All value types, so the whole request
/// crosses to a background executor without a data race.
private struct PlayerPageRequest: Sendable {
    var localVideoURL: URL?
    var roomTags: [RoomTag]
    var listing: Listing?
    var agent: AgentCard
    var staged: Bool
}

/// Everything that turns the bundled template into a page on disk.
///
/// A FILE-SCOPE enum, deliberately NOT a member of `PlayerWebView`:
/// `UIViewRepresentable` is a `@MainActor` protocol, so a type that conforms to
/// it infers main-actor isolation for its members — statics included. That is
/// the trap that made `GearStore.normalizedASIN` a compile error only the Mac
/// build caught. None of this touches UIKit or SwiftUI, so none of it belongs
/// on the main actor, and putting it in its own non-isolated namespace means no
/// future edit can quietly drag it back on (build-9 lag report).
private enum PlayerPage {

    // MARK: Immutable, process-wide

    /// The bundled `player/index.html`, read ONCE per process. It ships inside
    /// the signed .app and cannot change while the app is running, so re-reading
    /// 38 KB per player — and again per `playerRefresh` bump — was pure waste.
    /// `static let` is initialised lazily under `swift_once`; every touch of it
    /// happens inside the detached task below, so the read never lands on the
    /// main thread.
    ///
    /// A read that fails stays failed for the process. That is the honest
    /// answer: this is a resource inside the app bundle, so a failure means a
    /// damaged install, not a condition that clears itself — and the caller
    /// already has an explicit "Player unavailable" page for it.
    static let template: String? = {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "player") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// `player/demo.mp4` — a folder-reference resource, either in this build or
    /// not, for the life of the process. Probed once instead of per player.
    static let bundledDemoVideo: URL? =
        Bundle.main.url(forResource: "demo", withExtension: "mp4", subdirectory: "player")

    // MARK: Entry point

    /// The page for `request`, prepared off the main actor.
    ///
    /// `Task.detached` rather than a bare `nonisolated func`: a non-isolated
    /// `async` function's executor is a moving target across language modes and
    /// build settings (Swift 6.2's approachable-concurrency default runs one on
    /// the CALLER's actor), and this work must land on a background thread under
    /// every one of them. It is also the pattern already shipping in
    /// `AIImagePrep` and `ListingMediaItem.scan`, so there is one way of getting
    /// off the main actor in this app, not two.
    static func prepare(_ request: PlayerPageRequest) async -> PreparedPage? {
        await Task.detached(priority: .userInitiated) { () -> PreparedPage? in
            // Exactly build 9's fall-through order. A local video whose page
            // cannot be prepared still drops to the type-adapted demo; only a
            // template that can be neither read nor written gives up entirely.
            if let videoURL = request.localVideoURL,
               let preview = PlayerPage.localPreviewHTML(videoURL: videoURL,
                                                         roomTags: request.roomTags,
                                                         listing: request.listing,
                                                         agent: request.agent,
                                                         staged: request.staged) {
                PlayerPage.scheduleHousekeeping()
                return preview
            }
            // Sample tours: the bundled demo REWRITTEN for the current business
            // type — a gym's sample never shows "Living Room" or "Book a showing".
            // When demo.mp4 isn't in the build the page says so explicitly.
            if let demo = PlayerPage.demoHTML(listing: request.listing, agent: request.agent) {
                PlayerPage.scheduleHousekeeping()
                return demo
            }
            return nil
        }.value
    }

    // MARK: - Demo (sample tours / real listings without a video yet)

    /// Type-adapted demo: copies the bundled demo video into Caches once, then
    /// rewrites the player HTML around the CURRENT business type — its sample
    /// name/tagline, its area tags as chapters, and its call-to-action. When
    /// `demo.mp4` is not in the build, the page still renders (type-adapted)
    /// with an explicit "Sample video unavailable" stage.
    static func demoHTML(listing: Listing?, agent: AgentCard = .current) -> PreparedPage? {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("player-demo", isDirectory: true)

        let type = SpaceType.current

        // Chapters → this type's area tags, spread across the ~55 s demo.
        let tags = Array(type.quickTags.prefix(6))
        let step = 50.0 / Double(max(1, tags.count))
        let chapters = tags.enumerated().map { i, name in (t: Double(i) * step, label: name) }

        // One file per type AND identity (a real listing over the demo reel must
        // not overwrite the sample page, or vice versa).
        let suffix = (listing?.isSample ?? true) ? "" : "-\(listing?.id.uuidString.prefix(8) ?? "listing")"
        let out = dir.appendingPathComponent("demo-\(type.rawValue)\(suffix).html")
        let videoCopy = dir.appendingPathComponent("demo.mp4")

        let key = Key(kind: "demo",
                      videoPath: out.path,
                      videoStamp: bundledDemoVideo == nil ? "none" : "bundled",
                      chapters: chapters.map { "\($0.t)|\($0.label)" },
                      listing: listing,
                      agentFields: agent.brandFields,
                      headshotStamp: stamp(AgentCard.headshotURL),
                      type: type,
                      identityIsSample: listing?.isSample ?? true,
                      staged: false,
                      locale: Locale.current.identifier)
        if let hit = store.hit(slot: out.path, key: key) { return hit }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var videoRef: String?
        if let demoVideo = bundledDemoVideo {
            if !fm.fileExists(atPath: videoCopy.path) {
                try? fm.copyItem(at: demoVideo, to: videoCopy)
            }
            if fm.fileExists(atPath: videoCopy.path) { videoRef = "demo.mp4" }
        }

        let ctx = TemplateContext(videoRef: videoRef,
                                  chapters: chapters,
                                  listing: listing,
                                  agent: agent,
                                  type: type,
                                  identityIsSample: listing?.isSample ?? true,
                                  staged: false)
        guard let html = renderTemplate(ctx) else { return nil }

        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let managedVideo: URL? = videoRef == nil ? nil : videoCopy
        let page = PreparedPage(html: out, dir: dir, video: managedVideo)
        store.record(slot: out.path, key: key, page: page)
        return page
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
    ///
    /// MEMOISED (build-9 lag report). `.id(playerRefresh)` rebuilds the whole
    /// view, so this ran end to end every time the room tagger closed —
    /// including the times it closed with nothing changed, which is most of
    /// them, and including the hard-link dance and the atomic write. `Key`
    /// carries every input the rendered bytes depend on, so an unchanged bump is
    /// now a dictionary lookup and a handful of `stat`s: no sweep, no re-link,
    /// no substitution passes, no write. When something DID change, the full
    /// render runs — off the main actor, from the already-read template.
    static func localPreviewHTML(videoURL: URL, roomTags: [RoomTag], listing: Listing?,
                                 agent: AgentCard = .current, staged: Bool = false) -> PreparedPage? {
        let fm = FileManager.default
        let type = SpaceType.current
        // Stat'd once and used for both the key and `videoRef`. Build 9 asked
        // after `previewLocation`; hard-linking the file cannot change whether
        // the ORIGINAL exists, so the answer is the same either side of it.
        let hasVideo = fm.fileExists(atPath: videoURL.path)

        let tags = roomTags.sorted { $0.tMs < $1.tMs }
        let chapters = tags.map { (t: $0.tSeconds, label: $0.name) }

        let key = Key(kind: "preview",
                      videoPath: videoURL.standardizedFileURL.path,
                      videoStamp: hasVideo ? stamp(videoURL) : "none",
                      chapters: tags.map { "\($0.tMs)|\($0.name)" },
                      listing: listing,
                      agentFields: agent.brandFields,
                      headshotStamp: stamp(AgentCard.headshotURL),
                      type: type,
                      identityIsSample: listing?.isSample ?? false,
                      staged: staged,
                      locale: Locale.current.identifier)
        if let hit = store.hit(slot: key.videoPath, key: key) { return hit }

        let location = previewLocation(for: videoURL)
        let videoRef: String? = hasVideo ? location.videoRef : nil

        let ctx = TemplateContext(videoRef: videoRef,
                                  chapters: chapters,
                                  listing: listing,
                                  agent: agent,
                                  type: type,
                                  identityIsSample: listing?.isSample ?? false,
                                  staged: staged)
        guard let html = renderTemplate(ctx) else { return nil }

        let out = location.dir
            .appendingPathComponent("preview-\(videoURL.deletingPathExtension().lastPathComponent).html")
        do {
            try html.write(to: out, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let page = PreparedPage(html: out,
                                dir: location.dir,
                                video: videoRef.map { location.dir.appendingPathComponent($0) })
        store.record(slot: key.videoPath, key: key, page: page)
        return page
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
        // The stale-link sweep used to run HERE, in the creation path, on the
        // main thread, before any player could appear. It is housekeeping —
        // see `scheduleHousekeeping()` (build-9 lag report).
        let link = previews.appendingPathComponent(videoURL.lastPathComponent)
        // Re-link every time: the enhanced file may have been replaced since
        // (a hard link keeps the OLD bytes alive otherwise). The memo above
        // does not weaken that — a replaced original has a new size/mtime, so
        // `Key.videoStamp` changes and this runs again.
        try? fm.removeItem(at: link)
        do {
            try fm.linkItem(at: videoURL, to: link)
            return (link.lastPathComponent, previews)
        } catch {
            return (videoURL.lastPathComponent, parent)
        }
    }

    // MARK: - Housekeeping

    /// Sweep the stale preview hard links at most once every `housekeepingGap`,
    /// at `.utility`, on a background executor — never in the path a player is
    /// waiting on.
    ///
    /// Kicked off after a page has been prepared (so the page about to be shown
    /// is already recorded as live, below) and never awaited: the load does not
    /// wait for the bin men. A gap rather than once-per-launch because the links
    /// are the only thing keeping a deleted listing's video bytes on disk —
    /// `FileStore.deleteListingFiles` removes the preview page BESIDE the video,
    /// not the hard link in `Previews/` — so a long session still has to reap.
    static func scheduleHousekeeping() {
        guard store.claimHousekeeping(gap: housekeepingGap) else { return }
        Task.detached(priority: .utility) {
            let previews = FileStore.documents.appendingPathComponent("Previews", isDirectory: true)
            guard FileManager.default.fileExists(atPath: previews.path) else { return }
            PlayerPage.sweepStalePreviewLinks(in: previews, keeping: PlayerPage.store.livePaths)
        }
    }

    /// Hard links whose original left the Documents root (listing deleted,
    /// enhanced file replaced) would keep multi-hundred-MB files alive — drop
    /// them, and the preview pages that pointed at them.
    ///
    /// `keeping` is every page this process has prepared and not superseded. A
    /// player on screen holds its HTML and its hard-linked video open, and the
    /// "does the original still exist?" test alone does NOT protect them:
    /// deleting a listing removes the original while its player is still up, and
    /// build 9 would then delete both files under it — a black stage and a dead
    /// scrub bar. Anything we have handed to a webview is off limits.
    ///
    /// The price of that, stated plainly: a listing deleted while its page is
    /// still in the memo keeps its hard link (and so the video's bytes) until
    /// that entry is evicted — eight more tours — or the app is relaunched.
    /// Deleting bytes out from under a player on screen is a broken product;
    /// reaping a few minutes late is a full disk at worst.
    private static func sweepStalePreviewLinks(in dir: URL, keeping live: Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        var liveVideoBases = Set<String>()
        for url in items where !(url.lastPathComponent.hasPrefix("preview-") && url.pathExtension == "html") {
            let original = FileStore.documents.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: original.path) || live.contains(url.standardizedFileURL.path) {
                liveVideoBases.insert(url.deletingPathExtension().lastPathComponent)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        for url in items where url.lastPathComponent.hasPrefix("preview-") && url.pathExtension == "html" {
            let base = String(url.deletingPathExtension().lastPathComponent.dropFirst("preview-".count))
            if !liveVideoBases.contains(base), !live.contains(url.standardizedFileURL.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Memo

    /// Every input the rendered HTML depends on. `renderTemplate` is a pure
    /// function of the template (fixed for the process) and a `TemplateContext`,
    /// so equal keys mean byte-identical HTML — that equality is the whole basis
    /// for reusing the file already on disk.
    ///
    /// Two of these fields are not in any struct the caller passes, and the memo
    /// would be a correctness bug without them:
    ///  • `videoStamp` — the AI-enhance path REPLACES `enhanced-<id>.mp4` in
    ///    place, same URL, different bytes (that is why `previewLocation`
    ///    re-links every time).
    ///  • `headshotStamp` — `renderTemplate` reads the agent's headshot off disk
    ///    and base64-embeds it; `AgentCard` itself never mentions the file.
    /// `locale` is there because `Listing.metaLine` groups digits through
    /// `Int.formatted()`, which follows the device locale (`Money.formatted` is
    /// pinned to en_US and does not).
    struct Key: Hashable {
        var kind: String
        var videoPath: String
        var videoStamp: String
        var chapters: [String]
        var listing: Listing?
        var agentFields: [String: String]
        var headshotStamp: String
        var type: SpaceType
        var identityIsSample: Bool
        var staged: Bool
        var locale: String
    }

    private struct Entry {
        var key: Key
        var page: PreparedPage
    }

    /// "<size>-<mtime>" for a file whose BYTES the page depends on but whose
    /// identity no struct carries. "none" when it isn't there.
    static func stamp(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "none" }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    /// Process-wide memo of the pages already written, plus the housekeeping
    /// latch.
    ///
    /// A lock-guarded box rather than an `actor`: every caller is already inside
    /// `Task.detached`, so an actor would buy nothing but a suspension point per
    /// player — and `livePaths` has to be readable from the sweep without one.
    /// Same shape as `RenderEngine.CancelFlag`.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        /// Insertion order, so a phone with a hundred listings can't grow this
        /// without bound. Small on purpose: a handful of players are alive at
        /// once (Home's sample, the detail screen, a sheet), and an evicted
        /// entry costs one re-render, never a wrong page.
        private var order: [String] = []
        private var lastHousekeeping: Date?
        private let capacity = 8

        /// A hit only when the key matches AND the files are still there:
        /// `player-demo/` lives in Caches, which iOS evicts whenever it likes,
        /// and `Previews/` is swept. The file checks are outside the lock —
        /// they are syscalls, and nothing else needs to wait behind them.
        func hit(slot: String, key: Key) -> PreparedPage? {
            lock.lock()
            let entry = entries[slot]
            lock.unlock()
            guard let entry, entry.key == key else { return nil }
            let fm = FileManager.default
            guard fm.fileExists(atPath: entry.page.html.path) else { return nil }
            if let video = entry.page.video, !fm.fileExists(atPath: video.path) { return nil }
            return entry.page
        }

        func record(slot: String, key: Key, page: PreparedPage) {
            lock.lock()
            if entries[slot] == nil { order.append(slot) }
            entries[slot] = Entry(key: key, page: page)
            while order.count > capacity {
                let oldest = order.removeFirst()
                entries[oldest] = nil
            }
            lock.unlock()
        }

        /// Every file a prepared page points at — what the sweep must not touch.
        var livePaths: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            var out = Set<String>()
            for entry in entries.values {
                out.insert(entry.page.html.standardizedFileURL.path)
                if let video = entry.page.video { out.insert(video.standardizedFileURL.path) }
            }
            return out
        }

        /// True at most once per `gap` — the sweep's latch. The first call in a
        /// launch always wins, so the reaping still happens promptly on a cold
        /// start; after that it is a background chore on a timer.
        func claimHousekeeping(gap: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if let last = lastHousekeeping, now.timeIntervalSince(last) < gap { return false }
            lastHousekeeping = now
            return true
        }
    }

    private static let store = Store()

    /// How rarely the stale-link sweep may run. Five minutes: often enough that
    /// a deleted listing's bytes go back to the user inside one session, rare
    /// enough that it is nowhere near the path a player is waiting on.
    private static let housekeepingGap: TimeInterval = 300

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

    /// UNCHANGED from build 9 apart from where the template comes from: the same
    /// substitutions, in the same order, producing the same bytes. The anchors
    /// below are a contract with `Resources/player/index.html` and the two have
    /// drifted before (H-web.md §5), so this is the one part of the file the lag
    /// work was not allowed to touch.
    private static func renderTemplate(_ ctx: TemplateContext) -> String? {
        guard var html = template else { return nil }

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

    /// The listing chip's second line, hidden gracefully when unset: real
    /// estate shows only the parts that are > 0 (never "0 bd · 0 ba"), and
    /// non-property types show their tagline instead of beds/baths.
    private static func metaText(for listing: Listing) -> String {
        listing.spaceType.showsPropertyDetails ? listing.metaLine : (listing.tagline ?? "")
    }

    /// `LeadRow.telURL` / `LeadRow.mailURL`, copied verbatim.
    ///
    /// NOT a rewrite and not an improvement — the same digits filter, the same
    /// leading "+", the same `>= 3` floor, the same query-allowed encoding — so
    /// the anchors this file renders stay byte-for-byte what build 9 rendered.
    /// It is a copy only because `LeadRow` is a `View`: conforming to SwiftUI's
    /// `@MainActor` protocol isolates its statics to the main actor, and this
    /// render deliberately no longer runs there. `GearStore.normalizedASIN` had
    /// the identical problem and the identical one-word fix.
    ///
    /// THE REAL FIX IS ONE WORD IN SOMEONE ELSE'S FILE: mark both of
    /// `LeadRow.telURL` / `LeadRow.mailURL` `nonisolated` (they are pure string
    /// checks with no state, exactly like `normalizedASIN`) and delete this
    /// pair. Whoever owns `SettingsView.swift` next should do it — two copies of
    /// a phone-number rule is precisely the drift H-web.md §5 is about.
    private static func telURL(_ phone: String) -> URL? {
        var digits = phone.filter { $0.isNumber }
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { digits = "+" + digits }
        guard digits.count >= 3 else { return nil }
        return URL(string: "tel:\(digits)")
    }

    private static func mailURL(_ email: String) -> URL? {
        let allowed = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        return URL(string: "mailto:\(allowed)")
    }

    /// tel:/mailto: anchors for the card's contact row (empty → the row hides).
    private static func contactAnchors(phone: String, email: String) -> String {
        var parts = [String]()
        let p = phone.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty {
            if let tel = telURL(p) {
                parts.append("<a href=\"\(htmlEscape(tel.absoluteString))\">\(htmlEscape(p))</a>")
            } else {
                parts.append("<span>\(htmlEscape(p))</span>")
            }
        }
        let e = email.trimmingCharacters(in: .whitespaces)
        if !e.isEmpty, let mail = mailURL(e) {
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
