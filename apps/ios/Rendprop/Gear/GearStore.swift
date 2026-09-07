import Foundation
import SwiftUI
import UIKit

// MARK: - Gear we recommend (Amazon Associates)
//
// A short, remote list of filming gear — gimbals, microphones, lights, tripods,
// wide lenses, storage — each linking to Amazon with Rendprop's Associates tag,
// so a person can buy the right kit and the owner earns the referral. The
// catalog is `Config.gearCatalogURL` (services/edge/tour-host/public/gear.json,
// served as a static asset at rendprop.com/gear.json); nothing about it is
// compiled into the app except the shape below and an offline sample for the
// UI walk. docs/GEAR-STORE.md has the whole story.
//
// AMAZON'S RULES this type is built around (Associates Operating Agreement,
// checked 6 Sep 2026):
//
//   • Free to reach. Every Gear entry point is visible to a signed-out, free
//     user — never behind the paywall or sign-in. Nothing here reads
//     AuthStore or the plan.
//   • Never in a WebView. `open(_:)` hands the link to `UIApplication.shared`
//     — Safari, or the Amazon app via its universal link — so the click is
//     attributed on Amazon's side. There is no in-app browser for Amazon.
//   • No prices, ratings, stock or "tracking". The catalog has no field for
//     any of these and the UI shows none.
//   • The disclosure "As an Amazon Associate, Rendprop earns from qualifying
//     purchases." is carried by the catalog and pinned at the top of GearView.
//   • The mobile app is approved separately in Associates Central, after it is
//     live in the App Store — which is why the section ships HIDDEN:
//     `isAvailable` is false until the owner flips `enabled`, sets the tag and
//     fills in at least one ASIN, all in the remote file, no release needed.
//
// PRIVACY: the only thing analytics ever sees is the catalog's own item id
// (a slug like "dji-osmo-mobile") and where the list was opened from.

// MARK: Wire models — mirror public/gear.json exactly

struct GearCatalog: Equatable {
    /// Schema version. The app only accepts `GearCatalog.supportedVersion`.
    var version: Int
    /// Master switch. false = every Gear entry point stays hidden.
    var enabled: Bool
    /// Amazon Associates tracking id (`rendprop-20` style). Empty = hidden.
    var associatesTag: String
    /// The Operating Agreement sentence, shown verbatim.
    var disclosure: String
    var categories: [GearCategory]
    var items: [GearItem]

    static let supportedVersion = 1
    static let defaultDisclosure = "As an Amazon Associate, Rendprop earns from qualifying purchases."
}

struct GearCategory: Equatable, Identifiable {
    let id: String
    let title: String
    /// One plain sentence: why this kind of gear matters for a walkthrough.
    let why: String
}

struct GearItem: Equatable, Identifiable {
    /// Stable slug; the only thing analytics records about an item.
    let id: String
    /// A `GearCategory.id`. Items whose category is not declared are dropped.
    let category: String
    let name: String
    /// What the gear does for filming a walkthrough — not a review, no price.
    let blurb: String
    /// Amazon ASIN — 10 letters/digits from the product URL's `/dp/<ASIN>`.
    /// Empty until the owner fills it in; an item with no valid ASIN is never
    /// shown, so the catalog can be completed gradually.
    let asin: String
    /// `for` in the JSON: `SpaceType` raw values this item applies to. Empty =
    /// every business type.
    let spaceTypes: [String]

    /// The ASIN normalised to what Amazon expects, or nil when it is empty or
    /// malformed (a malformed remote value must produce a hidden item, never a
    /// broken link).
    var validASIN: String? { GearStore.normalizedASIN(asin) }
    var hasASIN: Bool { validASIN != nil }

    func applies(to type: SpaceType) -> Bool {
        spaceTypes.isEmpty || spaceTypes.contains(type.rawValue)
    }
}

// Decoding lives in extensions so the structs keep their memberwise
// initialisers (used by the UI-walk sample below). Every field is optional on
// the wire with a safe default — a half-filled catalog decodes to a hidden
// section, not to a decode error that hides an unrelated fix.
//
// Keys are spelled out (no `.convertFromSnakeCase`): `for` is a Swift keyword
// and `associates_tag` is the only other snake-case key.
extension GearCatalog: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version, enabled, disclosure, categories, items
        case associatesTag = "associates_tag"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version       = try c.decodeIfPresent(Int.self,    forKey: .version) ?? 0
        enabled       = try c.decodeIfPresent(Bool.self,   forKey: .enabled) ?? false
        associatesTag = try c.decodeIfPresent(String.self, forKey: .associatesTag) ?? ""
        let text      = try c.decodeIfPresent(String.self, forKey: .disclosure) ?? ""
        disclosure    = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GearCatalog.defaultDisclosure : text
        categories    = try c.decodeIfPresent([GearCategory].self, forKey: .categories) ?? []
        items         = try c.decodeIfPresent([GearItem].self, forKey: .items) ?? []
    }
}

extension GearCategory: Decodable {
    private enum CodingKeys: String, CodingKey { case id, title, why }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        why   = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
    }
}

extension GearItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, category, name, blurb, asin
        case spaceTypes = "for"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        category   = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        name       = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        blurb      = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        asin       = try c.decodeIfPresent(String.self, forKey: .asin) ?? ""
        spaceTypes = try c.decodeIfPresent([String].self, forKey: .spaceTypes) ?? []
    }
}

// MARK: - The store

/// Loads the remote catalog once per launch (and again after six hours),
/// keeps the last good copy on disk, and answers the one question every entry
/// point asks: `isAvailable`. Same shape as `Storefronts` / `AIConsent` —
/// a main-actor singleton the views observe.
@MainActor
final class GearStore: ObservableObject {
    static let shared = GearStore()

    /// The catalog in effect: the last successful fetch, else the disk copy,
    /// else nil. Under `-uiTesting` it is the inline sample and never changes.
    @Published private(set) var catalog: GearCatalog?
    @Published private(set) var isRefreshing = false

    private static let cacheFileName = "gear-catalog.json"
    /// How long a fetched (or failed) catalog is trusted before another try.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let requestTimeout: TimeInterval = 20

    private var lastAttempt: Date?
    private var inFlight: Task<Void, Never>?

    private init() {
        if Config.isUITesting {
            // The UI walk screenshots every screen offline: a visible, filled
            // list with a fake tag, and no network call — ever.
            catalog = GearCatalog.uiTestSample
        } else {
            catalog = Self.readCache()
            // First access is Home's first render (GearHomeLink), so the
            // section can appear on the same launch the owner enables it.
            // Throttled; a failure keeps the disk copy and tries again later.
            Task { await refreshIfNeeded() }
        }
    }

    // MARK: Availability

    /// The gate every entry point uses. True only when the remote file says
    /// `enabled`, carries a usable tag, and at least one item has a valid
    /// ASIN — so the shipped file (disabled, empty tag, empty ASINs) hides
    /// everything, and so does a catalog that failed to load.
    var isAvailable: Bool {
        guard let catalog, catalog.enabled, associatesTag != nil else { return false }
        return catalog.items.contains { $0.hasASIN && !$0.category.isEmpty }
    }

    /// The Operating Agreement sentence. Never empty.
    var disclosure: String { catalog?.disclosure ?? GearCatalog.defaultDisclosure }

    /// The tag, validated, or nil when it is missing or not a tag.
    var associatesTag: String? {
        catalog.flatMap { Self.normalizedTag($0.associatesTag) }
    }

    // MARK: Refresh

    /// Fetch if this launch has not tried recently. Safe to call from any
    /// screen's `.task`; concurrent callers share one request.
    func refreshIfNeeded() async {
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        await refresh()
    }

    /// Fetch now (pull-to-refresh). Never throws; a failure keeps what we had.
    func refresh() async {
        guard !Config.isUITesting else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performRefresh() async {
        lastAttempt = Date()
        isRefreshing = true
        defer { isRefreshing = false }

        // Always go to the origin: the file is edited in place and the phone
        // keeps its own copy on disk, so URLCache would only add staleness.
        var request = URLRequest(url: Config.gearCatalogURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard let decoded = Self.decode(data) else { return }   // wrong version / not JSON: ignore
            catalog = decoded
            Self.writeCache(data)
        } catch {
            // Offline, DNS, timeout: the disk copy (or nothing) stands. This
            // must never surface — nobody opened Gear to see a network error.
        }
    }

    /// Strict on the version, lenient on everything else (see the Decodable
    /// extensions). nil = not a catalog this build understands.
    static func decode(_ data: Data) -> GearCatalog? {
        guard let catalog = try? JSONDecoder().decode(GearCatalog.self, from: data),
              catalog.version == GearCatalog.supportedVersion else { return nil }
        return catalog
    }

    // MARK: Links

    /// Exactly 10 ASCII letters/digits, uppercased — what a `/dp/<ASIN>` path
    /// carries. Anything else (blank, a pasted URL, a typo) is nil.
    static func normalizedASIN(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard s.count == 10, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return s
    }

    /// An Associates tracking id (`rendprop-20`): letters, digits, `-`, `_`,
    /// `.`; non-empty and short. Anything else is nil, which hides the section
    /// rather than sending clicks with a mangled tag.
    static func normalizedTag(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 64,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
        else { return nil }
        return s
    }

    /// `https://www.amazon.com/dp/<ASIN>?tag=<tag>` — the plain Associates
    /// link form. Built with URLComponents so the tag is query-encoded; the
    /// ASIN is already restricted to path-safe characters. nil when the item
    /// has no valid ASIN or the catalog has no valid tag.
    func url(for item: GearItem) -> URL? {
        guard let tag = associatesTag, let asin = item.validASIN else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.amazon.com"
        components.path = "/dp/\(asin)"
        components.queryItems = [URLQueryItem(name: "tag", value: tag)]
        return components.url
    }

    /// Open the item on Amazon — in Safari or the Amazon app (universal link),
    /// never in an in-app web view. Records the item id only — see the file
    /// header's PRIVACY note; `category` is deliberately left out even though
    /// it is not identifying, so this event carries exactly what it promises.
    func open(_ item: GearItem) {
        guard let url = url(for: item) else { return }
        Analytics.track("gear_item_tapped", ["item": item.id])
        Haptics.selection()
        UIApplication.shared.open(url)
    }

    // MARK: Filtering

    /// One category and the items shown under it for a business type.
    struct Section: Identifiable {
        let category: GearCategory
        let items: [GearItem]
        var id: String { category.id }
    }

    /// Items a business type sees: a valid ASIN, and `for` empty or naming it.
    func items(for type: SpaceType) -> [GearItem] {
        (catalog?.items ?? []).filter { $0.hasASIN && $0.applies(to: type) }
    }

    /// Categories in catalog order, each with its visible items; a category
    /// with nothing to show for this type is left out, as is an item whose
    /// category id is not declared.
    func sections(for type: SpaceType) -> [Section] {
        guard let catalog else { return [] }
        let visible = items(for: type)
        return catalog.categories.compactMap { category in
            let items = visible.filter { $0.category == category.id }
            return items.isEmpty ? nil : Section(category: category, items: items)
        }
    }

    // MARK: Disk cache (Caches/ — the system may purge it; the next launch refetches)

    private static var cacheURL: URL {
        FileStore.caches.appendingPathComponent(cacheFileName)
    }

    private static func readCache() -> GearCatalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return decode(data)
    }

    private static func writeCache(_ data: Data) {
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - UI-walk sample (`-uiTesting` only)

extension GearCatalog {
    /// What the screenshot walk sees: enabled, a FAKE tag and FAKE ASINs, so
    /// the list renders with every row. The walk never taps a row, and this
    /// value is never used outside `Config.isUITesting`. Wording mirrors
    /// public/gear.json so the screenshots match what ships.
    static let uiTestSample = GearCatalog(
        version: supportedVersion,
        enabled: true,
        associatesTag: "uitest-20",
        disclosure: defaultDisclosure,
        categories: [
            GearCategory(id: "gimbal", title: "Gimbals",
                         why: "Rendprop steadies handheld footage in the render, so a gimbal is optional — it mostly smooths the doorway turns and stair climbs that are hardest to keep level by hand."),
            GearCategory(id: "mic", title: "Microphones",
                         why: "The tour itself plays silent. A mic is for the voiceover you record on reels and for talking-to-camera intros; a USB-C or Bluetooth mic connected to the phone is used automatically."),
            GearCategory(id: "light", title: "Lights",
                         why: "The first tip is still lights on and blinds open. A small battery LED covers the rooms that have no window — bathrooms, closets, basements, back-of-house."),
            GearCategory(id: "tripod", title: "Tripods",
                         why: "The walkthrough is filmed walking, so a tripod is for everything else: the still photos you bring into the photo studio and a fixed-frame intro clip for a reel."),
        ],
        items: [
            GearItem(id: "dji-osmo-mobile", category: "gimbal", name: "DJI Osmo Mobile (phone gimbal)",
                     blurb: "A folding three-axis phone gimbal. Keeps the phone upright and level through turns and doorways while you walk.",
                     asin: "B0UITEST01", spaceTypes: []),
            GearItem(id: "insta360-flow", category: "gimbal", name: "Insta360 Flow (phone gimbal)",
                     blurb: "A compact phone gimbal with a built-in grip and stand. Same job: a level, steady walk through the space.",
                     asin: "B0UITEST02", spaceTypes: []),
            GearItem(id: "rode-wireless-go", category: "mic", name: "RØDE Wireless GO (wireless microphone)",
                     blurb: "A clip-on wireless microphone with a receiver that connects to the phone. For recording a voiceover or speaking to camera away from the phone.",
                     asin: "B0UITEST03", spaceTypes: []),
            GearItem(id: "dji-mic", category: "mic", name: "DJI Mic (wireless microphone)",
                     blurb: "A wireless microphone kit with a phone receiver. For voiceovers and on-camera speech in your reels.",
                     asin: "B0UITEST04", spaceTypes: []),
            GearItem(id: "aputure-amaran-led", category: "light", name: "Aputure amaran (LED light)",
                     blurb: "Battery-friendly bi-colour LED lights. Lifts a windowless room so it reads the way the rest of the space does.",
                     asin: "B0UITEST05", spaceTypes: []),
            GearItem(id: "joby-gorillapod", category: "tripod", name: "JOBY GorillaPod (flexible phone tripod)",
                     blurb: "A flexible tripod that wraps around a rail or stands on a counter. Holds the phone still for photos and fixed-frame clips.",
                     asin: "B0UITEST06", spaceTypes: []),
        ]
    )
}
