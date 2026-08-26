import SwiftUI
import UIKit

// MARK: - Background URLSession bridge
// iOS relaunches the app for background-upload events; the completion handler
// must be stored here and called after the session delegate drains its events.
final class BackgroundSessionBridge {
    static let shared = BackgroundSessionBridge()
    var completionHandler: (() -> Void)?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundSessionBridge.shared.completionHandler = completionHandler
        _ = UploadManager.shared // recreate the background session so events are delivered
    }
}

// MARK: - App state
@MainActor
final class AppModel: ObservableObject {
    // Every mutation auto-saves to disk (see `persist()`), so a listing, its video,
    // and its rendered tour all survive an app kill. `isRestoring` suppresses saves
    // while we're loading the snapshot back in.
    @Published var listings: [Listing] = []           { didSet { persist() } }
    @Published var renders: [UUID: Render] = [:]       { didSet { persist() } } // listingID → render
    @Published var assets: [UUID: CaptureAsset] = [:]  { didSet { persist() } } // listingID → recorded/imported video

    struct RenderedTour {
        let url: URL
        let durationS: Double
        let speedFactor: Double
    }
    @Published var tours: [UUID: RenderedTour] = [:]   { didSet { persist() } } // listingID → rendered tour

    // Mock by default (offline dev); LiveAPIClient when Config.useLiveBackend.
    let api: APIClient = Config.makeAPIClient()

    private var hasLoaded = false
    private var isRestoring = false

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        // 1. Restore the user's real listings/assets/tours from disk.
        isRestoring = true
        let saved = PersistentStore.load()
        listings = saved.listings
        assets = saved.assets
        tours = saved.tours
        renders = saved.renders
        isRestoring = false

        // 2. Append fresh sample listings for the CURRENT business type
        //    (never persisted; a venue owner sees a venue, not a house).
        for sample in SpaceType.current.sampleListings
        where !listings.contains(where: { $0.isSample && $0.address == sample.address }) {
            listings.append(sample)
        }
    }

    /// Swap the seeded samples when the business type changes, so the home
    /// screen instantly reflects the new industry. Real listings untouched;
    /// samples are never persisted, so this is safe.
    func reseedSamples() {
        listings.removeAll { $0.isSample }
        listings.append(contentsOf: SpaceType.current.sampleListings)
    }

    func add(_ listing: Listing) {
        listings.insert(listing, at: 0)   // persists via didSet
    }

    func setStatus(_ status: Listing.Status, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].status = status       // persists via didSet
    }

    /// Mutate a listing in place (e.g. re-syncing draft details from the New
    /// Listing form). No-ops if the listing is gone.
    func modify(_ id: UUID, _ mutate: (inout Listing) -> Void) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&listings[i])              // persists via didSet
    }

    func setSold(_ sold: Bool, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].soldAt = sold ? Date() : nil   // persists via didSet
    }

    func setZillow(_ url: String, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        listings[i].zillowURL = trimmed.isEmpty ? nil : trimmed
    }

    func setMainPhoto(_ relPath: String?, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].mainPhotoRelPath = relPath
    }

    func setCoordinate(lat: Double, lon: Double, for id: UUID) {
        guard let i = listings.firstIndex(where: { $0.id == id }) else { return }
        listings[i].latitude = lat
        listings[i].longitude = lon
    }

    // MARK: - Cloud publish (local-first + cloud-publish, contract §4)

    /// Return the server listing id for a local listing, creating the server
    /// listing on first publish and adopting its id as the listing's server
    /// identity (persisted). All later server calls for this listing use it.
    func ensureServerListing(_ listing: Listing) async throws -> UUID {
        let localID = listing.id
        if let existing = listings.first(where: { $0.id == localID })?.serverID {
            return existing
        }
        // Sync using the freshest local copy (address/details may have changed).
        let live = listings.first(where: { $0.id == localID }) ?? listing
        let created = try await api.createListing(live)
        let serverID = created.id
        if let i = listings.firstIndex(where: { $0.id == localID }) {
            listings[i].serverID = serverID   // persists via didSet
        }
        return serverID
    }

    /// Publish the app's ON-DEVICE render as the hosted tour (contract §2.7):
    /// ensure a server listing → upload the scrub-master mp4 (role=render) →
    /// POST /renders/publish-app with room-tag chapters → persist the REAL slug
    /// on the listing. Returns the published tour (slug + share URL).
    func publishTour(listing: Listing,
                     renderOutputURL: URL,
                     durationS: Double,
                     speedFactor: Double,
                     roomTags: [RoomTag],
                     enhancements: Enhancements,
                     tier: Render.Tier) async throws -> PublishedTour {
        // 1. Adopt (or create) the server listing identity.
        let serverID = try await ensureServerListing(listing)

        // 2. Upload the rendered mp4 to the PUBLIC renders bucket; get server assetID.
        let bytes = FileStore.fileSize(renderOutputURL)
        let meta = UploadMetadata(durationS: durationS, bytes: bytes)
        let assetID = try await UploadManager.shared.upload(
            fileURL: renderOutputURL, listingID: serverID, role: "render", metadata: meta)

        // 3. Room tags → tap-to-jump chapters, sorted by time.
        // Room tags are timed against the ORIGINAL capture, but the published mp4
        // is retimed by `speedFactor` (a 2× walk halves timestamps). Rescale to the
        // RENDERED timeline so the public player's dots (which read t_ms against the
        // rendered duration_s — see tour-host player.ts) land exactly where the
        // in-app preview shows them (FlythroughDetailView.playbackTags does the
        // same tMs / speedFactor mapping).
        let sf = speedFactor > 0 ? speedFactor : 1.0
        let chapters: [[String: Any]] = roomTags
            .sorted { $0.tMs < $1.tMs }
            .enumerated()
            .map { idx, tag in
                ["label": tag.name, "t_ms": Int((Double(tag.tMs) / sf).rounded()), "sort": idx]
            }

        // 4. Publish. "Virtually staged" when any AI enhancement altered the space.
        let staged = enhancements.isActive
        let published = try await api.publishApp(
            listingID: serverID, assetID: assetID, durationS: durationS,
            speedFactor: speedFactor, staged: staged, tier: tier,
            enhancements: enhancements, chapters: chapters)

        // 5. Persist the REAL server slug/URL onto the local listing (never fabricated).
        if let i = listings.firstIndex(where: { $0.id == listing.id }) {
            listings[i].shareSlug = published.slug
            listings[i].shareURL = published.shareURL   // persists via didSet
        }
        return published
    }

    private func persist() {
        guard !isRestoring else { return }
        PersistentStore.save(listings: listings, assets: assets, tours: tours, renders: renders)
    }
}

// MARK: - Persistence
// Lives here (not a standalone file) so it's always in the build target — a new
// .swift file only compiles if xcodegen re-adds it, and a stale project silently
// drops it. Disk-backed snapshot of the user's real data (listings, their
// recorded/imported assets, and rendered tours) so nothing is lost on relaunch.
// File paths are stored RELATIVE to Documents (iOS changes the container base
// between launches/reinstalls) and rebuilt on load; missing-file entries drop.
enum PersistentStore {

    private static var fileURL: URL {
        FileStore.documents.appendingPathComponent("rendprop-state.json")
    }

    // fileprivate (not private) so the tolerant-decoding extensions at the
    // bottom of this file can name these nested types.
    fileprivate struct PersistedAsset: Codable {
        var id: UUID
        var relPath: String
        var motionRelPath: String?
        var durationS: Double
        var fps: Double
        var width: Int
        var height: Int
        var bytes: Int64
        var isDrone: Bool
        var roomTags: [RoomTag]
    }

    fileprivate struct PersistedTour: Codable {
        var relPath: String
        var durationS: Double
        var speedFactor: Double
    }

    fileprivate struct PersistedState: Codable {
        var listings: [Listing] = []
        var assets: [UUID: PersistedAsset] = [:]
        var tours: [UUID: PersistedTour] = [:]
        var renders: [UUID: Render] = [:]
    }

    static func save(listings: [Listing],
                     assets: [UUID: CaptureAsset],
                     tours: [UUID: AppModel.RenderedTour],
                     renders: [UUID: Render]) {
        var state = PersistedState()
        state.listings = listings.filter { !$0.isSample }
        let realIDs = Set(state.listings.map { $0.id })

        for (id, a) in assets where realIDs.contains(id) {
            state.assets[id] = PersistedAsset(
                id: a.id,
                relPath: FileStore.relativePath(for: a.localURL),
                motionRelPath: a.motionSidecarURL.map { FileStore.relativePath(for: $0) },
                durationS: a.durationS, fps: a.fps, width: a.width, height: a.height,
                bytes: a.bytes, isDrone: a.isDrone, roomTags: a.roomTags)
        }
        for (id, t) in tours where realIDs.contains(id) {
            state.tours[id] = PersistedTour(
                relPath: FileStore.relativePath(for: t.url),
                durationS: t.durationS, speedFactor: t.speedFactor)
        }
        state.renders = renders.filter { realIDs.contains($0.key) }

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch { /* non-fatal: files are safe, only this snapshot is lost */ }
    }

    struct Loaded {
        var listings: [Listing] = []
        var assets: [UUID: CaptureAsset] = [:]
        var tours: [UUID: AppModel.RenderedTour] = [:]
        var renders: [UUID: Render] = [:]
    }

    static func load() -> Loaded {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return Loaded()
        }
        var out = Loaded()
        out.listings = state.listings

        for (id, a) in state.assets {
            let localURL = FileStore.url(fromRelativePath: a.relPath)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            out.assets[id] = CaptureAsset(
                id: a.id, localURL: localURL,
                motionSidecarURL: a.motionRelPath.map { FileStore.url(fromRelativePath: $0) },
                durationS: a.durationS, fps: a.fps, width: a.width, height: a.height,
                bytes: a.bytes, isDrone: a.isDrone, roomTags: a.roomTags)
        }
        for (id, t) in state.tours {
            let url = FileStore.url(fromRelativePath: t.relPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out.tours[id] = AppModel.RenderedTour(url: url, durationS: t.durationS, speedFactor: t.speedFactor)
        }
        let ids = Set(out.listings.map { $0.id })
        out.renders = state.renders.filter { ids.contains($0.key) }
        return out
    }
}

// MARK: - Tolerant decoding for persisted snapshots
// The snapshot decode used to be all-or-nothing: ONE missing key or one bad
// entry anywhere (a field added by a newer/older build, an unknown enum raw
// value) threw, load() returned empty, and every listing "vanished" on update.
// These inits decode field-by-field with safe defaults, and the top-level state
// salvages each collection independently — a poisoned renders map can no longer
// take the listings down with it. Extensions keep the memberwise inits that
// save() uses; encoding stays synthesized, so the JSON shape is unchanged.
extension PersistentStore.PersistedAsset {
    enum CodingKeys: String, CodingKey {
        case id, relPath, motionRelPath, durationS, fps, width, height, bytes, isDrone, roomTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        relPath       = try c.decode(String.self, forKey: .relPath)   // useless without a path
        motionRelPath = try c.decodeIfPresent(String.self, forKey: .motionRelPath)
        durationS     = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        fps           = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        width         = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height        = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        bytes         = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        isDrone       = try c.decodeIfPresent(Bool.self, forKey: .isDrone) ?? false
        // Losing chapters beats losing the video: salvage what decodes.
        roomTags      = ((try? c.decodeIfPresent([RoomTag].self, forKey: .roomTags)) ?? nil) ?? []
    }
}

extension PersistentStore.PersistedTour {
    enum CodingKeys: String, CodingKey { case relPath, durationS, speedFactor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relPath     = try c.decode(String.self, forKey: .relPath)     // useless without a path
        durationS   = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        speedFactor = try c.decodeIfPresent(Double.self, forKey: .speedFactor) ?? 1
    }
}

extension PersistentStore.PersistedState {
    enum CodingKeys: String, CodingKey { case listings, assets, tours, renders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each collection is salvaged independently (`try?`): if one is
        // malformed, only it degrades to empty — the rest still load.
        listings = ((try? c.decodeIfPresent([Listing].self, forKey: .listings)) ?? nil) ?? []
        assets   = ((try? c.decodeIfPresent([UUID: PersistentStore.PersistedAsset].self,
                                            forKey: .assets)) ?? nil) ?? [:]
        tours    = ((try? c.decodeIfPresent([UUID: PersistentStore.PersistedTour].self,
                                            forKey: .tours)) ?? nil) ?? [:]
        renders  = ((try? c.decodeIfPresent([UUID: Render].self, forKey: .renders)) ?? nil) ?? [:]
    }
}

// MARK: - Entry

/// App appearance — System follows iOS; Light/Dark force a scheme.
/// Stored raw in @AppStorage("appearance"); every Theme token is adaptive, so
/// switching re-themes the whole app instantly.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil       // follow the device
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@main
struct RendpropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var uploads = UploadManager.shared
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    RootTabView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(model)
            .environmentObject(uploads)
            .tint(Theme.accent)
            // System / Light / Dark — set in Settings → Appearance. nil = follow iOS.
            .preferredColorScheme((Appearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        }
    }
}

// MARK: - Root tab bar
// First tab wears the current business type's identity (Homes/Venues/Places/
// Stores/Studios/Spaces + matching icon) and re-renders live on type change.
struct RootTabView: View {
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeDashboardView(goToListings: { tab = 1 }) }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            HomeListingsView()
                .tabItem {
                    Label("\(SpaceType.current.spaceNounCap)s",
                          systemImage: SpaceType.current.systemImage)
                }
                .tag(1)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
    }
}

// MARK: - Home dashboard
// The real "home" tab is a SHOWROOM, not a brochure: an animated hero, the LIVE
// demo tour you can scrub right here, and one bold gradient card per feature
// that jumps straight into it. Orient in three seconds, playing in five.
// Inlined here so it stays in the build target.
struct HomeDashboardView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var goToListings: () -> Void = {}

    @State private var revealed = false          // staggers the sections in on first appear
    @State private var showAerial = false        // aerial intro sheet from the showroom

    private var noun: String { SpaceType.current.spaceNoun }          // home / venue / space …
    private var customer: String { SpaceType.current.customerNoun }   // buyers / guests …

    /// The seeded demo listing for the current business type — powers the live
    /// sample tour on Home. nil only for the instant before `model.load()`.
    private var demoListing: Listing? {
        model.listings.first(where: { $0.isSample })
    }
    /// The user's own most recent listing for this industry (never a sample).
    private var firstRealListing: Listing? {
        model.listings.first(where: { !$0.isSample && $0.belongsToCurrentType })
    }
    /// Best listing to open a feature on: the user's own, else the demo.
    private var heroListing: Listing? { firstRealListing ?? demoListing }

    /// The hosted demo listing page (real estate only). The Home card shows just
    /// the flythrough hero (?embed=1); "Open the full demo tour" opens the whole
    /// auto-generated listing microsite — exactly what buyers get from a shared
    /// link. Other business types keep the bundled sample player.
    private var estateDemoEmbedURL: URL? {
        SpaceType.current == .realEstate
            ? URL(string: "https://rendprop.com/f/estate-demo?embed=1") : nil
    }
    private var estateDemoFullURL: URL? {
        SpaceType.current == .realEstate
            ? URL(string: "https://rendprop.com/f/estate-demo") : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heroCard
                    .modifier(Reveal(index: 0, on: revealed))
                demoSection
                    .modifier(Reveal(index: 1, on: revealed))
                showroomSection
                    .modifier(Reveal(index: 2, on: revealed))
                howItWorksSection
                    .modifier(Reveal(index: 3, on: revealed))
                // Tutorials are hidden until the videos are filmed — no "coming
                // soon" placeholder ships to App Review (2.1). Flip the flag once
                // tutorialSlot destinations play real content.
                if Config.showTutorials {
                    tutorialsSection
                        .modifier(Reveal(index: 4, on: revealed))
                }
                partnersSection
                    .modifier(Reveal(index: 5, on: revealed))
                listingsShortcut
                    .modifier(Reveal(index: 6, on: revealed))
            }
            .padding()
            // The whole tab re-themes when the business type changes (top-left menu).
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: spaceTypeRaw)
        }
        .background(Theme.bg)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Top-left: the business-type switcher — the app's identity control.
            // Picking one re-themes the ENTIRE app (Home, samples, copy, fields).
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    ForEach(SpaceType.allCases) { type in
                        Button {
                            guard type != SpaceType.current else { return }
                            spaceTypeRaw = type.rawValue
                            model.reseedSamples()
                            Haptics.selection()
                        } label: {
                            Label(type.displayName, systemImage: type.systemImage)
                            if type == SpaceType.current {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: SpaceType.current.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(SpaceType.current.displayName)
                            .font(.rpCaption.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.accentSoft, in: Capsule())
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .task { await model.load() }        // idempotent — seeds the demo tour for this tab
        .onAppear { revealed = true }
        .sheet(isPresented: $showAerial) {
            if let l = heroListing {
                AerialIntroSheet(listing: l)
                    .environmentObject(model)
            }
        }
    }

    // MARK: Hero — animated gradient billboard

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RENDPROP")
                .font(.caption.weight(.bold)).kerning(3)
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Shoot it on your phone.\nShow it like a film.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("A walkthrough video goes in. A drone-style tour comes out — with AI photos, reels, and a link \(customer) scroll like it's social.")
                .font(.rpBody)
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            NavigationLink { NewListingView() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.viewfinder")
                    Text("Create a tour").fontWeight(.semibold)
                }
                .font(.rpBody)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color.white, in: Capsule())
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(ScalePressStyle())
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(animatedHeroBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)
    }

    /// Slow, subtle motion: the purple→indigo wash drifts a few degrees of hue
    /// while a soft highlight orbits. Alive, never distracting; 20fps cap.
    private var animatedHeroBackground: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            // Reduce Motion freezes the drift/hue-shift to a calm static wash.
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [Color(red: 109/255, green: 40/255, blue: 217/255),
                             Theme.accent,
                             Color(red: 79/255, green: 70/255, blue: 229/255)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [Color.white.opacity(0.22), Color.clear],
                    center: UnitPoint(x: 0.5 + 0.42 * cos(t / 5), y: 0.35 + 0.3 * sin(t / 4)),
                    startRadius: 8, endRadius: 260)
            }
            .hueRotation(.degrees(sin(t / 6) * 10))
        }
    }

    // MARK: Live demo — the real scroll-scrub player, right on Home

    @ViewBuilder private var demoSection: some View {
        if let demo = demoListing {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("See it in action")
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let url = estateDemoEmbedURL {
                            PlayerWebView(remoteURL: url)   // hosted estate flythrough
                        } else {
                            PlayerWebView(listing: demo)    // bundled sample (other types)
                        }
                    }
                        .id(spaceTypeRaw)   // demo re-renders when the business type changes
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(Theme.border)
                        )
                    Label("Live demo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(Color.white)
                        .padding(10)
                        .allowsHitTesting(false)
                }
                Label("Scroll inside the video — this is the tour your \(customer) get.",
                      systemImage: "arrow.up.arrow.down")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                NavigationLink {
                    if let url = estateDemoFullURL {
                        // The full hosted listing microsite — flythrough → the
                        // whole auto-built landing page buyers scroll.
                        PlayerWebView(remoteURL: url)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Demo listing page")
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        FlythroughDetailView(listing: demo)
                    }
                } label: {
                    HStack {
                        Label("Open the full demo tour", systemImage: "play.rectangle.fill")
                            .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    .padding(14)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(ScalePressStyle())
            }
        }
    }

    // MARK: Feature showroom — every headline feature, one tap in

    private var showroomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Everything Rendprop does")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink { NewListingView() } label: {
                    featureTile("Drone Tour", "Walk it once — glide forever",
                                "video.fill", RPGradient.drone, ai: true)
                }
                .buttonStyle(ScalePressStyle())

                NavigationLink { AIPhotoStudioView() } label: {
                    featureTile("AI Photo Studio", "Twilight · blue sky · staging",
                                "wand.and.stars", RPGradient.photo, ai: true)
                }
                .buttonStyle(ScalePressStyle())

                reelTile
                floorPlanTile

                Button {
                    if heroListing != nil { showAerial = true }
                } label: {
                    featureTile("Aerial Intro", "A cinematic opening shot",
                                "airplane.departure", RPGradient.aerial, ai: true)
                }
                .buttonStyle(ScalePressStyle())

                NavigationLink { AgentCardEditorView() } label: {
                    featureTile(SpaceType.current.profileCardName, "You, on every tour you send",
                                "person.text.rectangle.fill", RPGradient.agent)
                }
                .buttonStyle(ScalePressStyle())
            }
            shareLeadsBanner
        }
    }

    /// Reel Studio starts from a listing's photos — with no real listing yet,
    /// the card routes to Listings to create one (and says so honestly).
    @ViewBuilder private var reelTile: some View {
        if let real = firstRealListing {
            NavigationLink { PhotoStudioView(listing: real) } label: {
                featureTile("Reel Studio", "Photos → one social video",
                            "film.stack", RPGradient.reel, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        } else {
            Button { goToListings() } label: {
                featureTile("Reel Studio", "Create a \(noun) first",
                            "film.stack", RPGradient.reel, ai: true)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    /// Floor plans attach to a listing too — same honest fallback.
    @ViewBuilder private var floorPlanTile: some View {
        if let real = firstRealListing {
            NavigationLink { FloorPlanView(listing: real) } label: {
                featureTile("Floor Plans", "Scan in 3D or upload",
                            "cube.transparent", RPGradient.plan)
            }
            .buttonStyle(ScalePressStyle())
        } else {
            Button { goToListings() } label: {
                featureTile("Floor Plans", "Create a \(noun) first",
                            "cube.transparent", RPGradient.plan)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    /// Wide banner: the payoff — every tour is a share link that captures leads.
    private var shareLeadsBanner: some View {
        NavigationLink {
            if let l = heroListing {
                FlythroughDetailView(listing: l)
            } else {
                NewListingView()
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share & Leads").font(.rpHeadline).foregroundStyle(Color.white)
                    Text("Every tour is one link — your card on it, a lead form built in.")
                        .font(.rpCaption).foregroundStyle(Color.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.rpCaption.weight(.bold)).foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RPGradient.share)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
    }

    /// One showroom tile: signature gradient, white hierarchical icon, name,
    /// a short promise, and an AI badge where AI does the work.
    private func featureTile(_ title: String, _ promise: String, _ icon: String,
                             _ gradient: LinearGradient, ai: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white)
                Spacer()
                if ai { AIPill() }
            }
            Spacer(minLength: 10)
            Text(title)
                .font(.rpHeadline)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(promise)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .background(gradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: How it works — three steps, one card

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("How it works")
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Film", "Walk the \(noun) slowly on the 0.5× wide lens — or upload a clip.")
                step(2, "Enhance", "Rendprop renders the glide tour; add AI photos and staging.")
                step(3, "Share", "One link, QR, or export — \(customer) scroll to explore.")
            }
            .card()
        }
    }

    // MARK: Tutorials — honest "coming soon" slots (no fake videos)

    private var tutorialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tutorials").font(.rpKicker).foregroundStyle(Theme.inkDim)
                Text("COMING SOON")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(0.5)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: Capsule())
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            VStack(spacing: 10) {
                tutorialSlot("figure.walk", "Shoot the perfect walkthrough", "2 min")
                tutorialSlot("wand.and.stars", "Get the most from AI edits", "3 min")
            }
        }
    }

    private var listingsShortcut: some View {
        Button(action: goToListings) {
            HStack {
                Label("My \(SpaceType.current.spaceNounCap.lowercased())s",
                      systemImage: SpaceType.current.systemImage)
                    .font(.rpHeadline).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            .padding(16)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
    }

    // MARK: More from us — the Pilk.ai family, quietly cross-promoted

    private var partnersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("More from us")
            VStack(spacing: 10) {
                partnerRow("Pilk.ai", "Custom sites, apps & AI marketing systems",
                           "sparkles", "https://pilk.ai/")
                partnerRow("Wholesale Mortgage Lending", "Get your buyers pre-approved fast",
                           "banknote", "https://wsmlending.com/")
                partnerRow("Tract", "The real estate system we built",
                           "map", "https://tractrealestate.com/")
            }
        }
    }

    private func partnerRow(_ name: String, _ sub: String, _ icon: String, _ urlString: String) -> some View {
        Link(destination: URL(string: urlString) ?? URL(string: "https://pilk.ai/")!) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.rpHeadline).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(sub).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ScalePressStyle())
    }

    // MARK: Small pieces

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.rpKicker).foregroundStyle(Theme.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.rpHeadline).foregroundStyle(Color.white)
                .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.ink)
                Text(sub).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func tutorialSlot(_ icon: String, _ title: String, _ len: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.inkDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rpHeadline).foregroundStyle(Theme.inkDim)
                Text("\(len) · not filmed yet").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Spacer()
            Image(systemName: icon).foregroundStyle(Theme.inkDim)
        }
        .padding(14)
        .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Shared visual language
// Gradients, press feedback, and reveal animation used by Home, the listing
// toolbox, onboarding, and the photo studio. Inlined here (not a new file) per
// the new-file-not-in-target rule.

/// Feature-card gradients — one signature wash per feature, reused everywhere
/// that feature appears, so the color IS the feature.
enum RPGradient {
    static let drone  = LinearGradient(
        colors: [Color(red: 124/255, green: 58/255,  blue: 237/255),
                 Color(red: 67/255,  green: 56/255,  blue: 202/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photo  = LinearGradient(
        colors: [Color(red: 249/255, green: 115/255, blue: 22/255),
                 Color(red: 236/255, green: 72/255,  blue: 153/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let reel   = LinearGradient(
        colors: [Color(red: 20/255,  green: 184/255, blue: 166/255),
                 Color(red: 59/255,  green: 130/255, blue: 246/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let plan   = LinearGradient(
        colors: [Color(red: 34/255,  green: 197/255, blue: 94/255),
                 Color(red: 13/255,  green: 148/255, blue: 136/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let aerial = LinearGradient(
        colors: [Color(red: 14/255,  green: 165/255, blue: 233/255),
                 Color(red: 99/255,  green: 102/255, blue: 241/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let agent  = LinearGradient(
        colors: [Color(red: 236/255, green: 72/255,  blue: 153/255),
                 Color(red: 244/255, green: 63/255,  blue: 94/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let share  = LinearGradient(
        colors: [Color(red: 245/255, green: 158/255, blue: 11/255),
                 Color(red: 234/255, green: 88/255,  blue: 12/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let rooms  = LinearGradient(
        colors: [Color(red: 139/255, green: 92/255,  blue: 246/255),
                 Color(red: 124/255, green: 58/255,  blue: 237/255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Crisp press-down for any card-shaped button. A near-critically-damped
/// spring (no visible overshoot) reads as a quick ease-out while staying
/// interruptible for rapid taps — a toy-like bounce on a discrete tap is
/// exactly the kind of motion Apple's own controls avoid.
struct ScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: configuration.isPressed)
    }
}

/// Small "AI" badge for AI-powered feature cards (sits on gradient tiles).
struct AIPill: View {
    var body: some View {
        Text("AI")
            .font(.system(size: 10, weight: .heavy))
            .kerning(0.5)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.22), in: Capsule())
            .foregroundStyle(Color.white)
    }
}

/// Staggered fade-up on first appear — flip `on` once and each indexed section
/// springs in with a small cascade. Honors Reduce Motion: the vertical travel
/// is dropped for a plain staggered fade so nothing slides for those users.
struct Reveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 18)
            .animation(.spring(response: 0.55, dampingFraction: 0.85)
                        .delay(Double(index) * 0.07), value: on)
    }
}
